--- === FortiVPNAuto ===
---
--- Auto-connect a FortiGate SSL-VPN (SAML SSO) whenever you join an untrusted
--- Wi-Fi network, and tear it down when you return to a trusted one.
---
--- Dials with `openfortivpn --saml-login` (no FortiClient GUI). SAML SSO + MFA
--- happen in your default browser. Cert pinning lives in the openfortivpn
--- config; this Spoon only watches Wi-Fi and drives connect/disconnect.
---
--- Usage in ~/.hammerspoon/init.lua:
---     hs.loadSpoon("FortiVPNAuto")
---     spoon.FortiVPNAuto:configure({
---       trustedSSIDs = { "airuc-secure" },
---       binPath      = "/opt/homebrew/bin/openfortivpn",
---     })
---     spoon.FortiVPNAuto:start()
---
--- Requires:
---   * openfortivpn >= 1.21         (brew install openfortivpn)
---   * /etc/sudoers.d/fortivpn-auto (NOPASSWD for the exact dial invocation)
---   * ~/.config/openfortivpn/config (gateway, port, pinned trusted-cert)
---   * Location Services granted to Hammerspoon (macOS 14+ gates SSID reads)
---
--- Logs to ~/Library/Logs/fortivpn-auto.log.

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "FortiVPNAuto"
obj.version  = "1.0.1"
obj.author   = "Tahsin Rahit"
obj.homepage = "https://github.com/rahit/fortivpn-auto"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

-- ── Configuration (override via :configure{...} before :start()) ─────────────
obj.trustedSSIDs    = {}                              -- SSIDs where NO VPN runs
obj.binPath         = "/opt/homebrew/bin/openfortivpn"
obj.configPath      = nil                             -- default: ~/.config/openfortivpn/config
obj.sudoPath        = "/usr/bin/sudo"
obj.captiveURL      = "http://captive.apple.com/hotspot-detect.html"
obj.logFile         = nil                             -- default: ~/Library/Logs/fortivpn-auto.log
obj.maxRetries      = 3
obj.retryDelay      = 30                              -- seconds between connect retries
obj.startDelay      = 3                               -- seconds after SSID change (DHCP settle)
obj.requestLocation = true                            -- trigger Location Services prompt on start
obj.keepaliveInterval = 0                             -- ping every N s to dodge an idle timeout (0=off)
obj.keepaliveHost     = ""                            -- "" = ping the tunnel's gateway peer
obj.reconnectGrace    = 180                           -- s of ACTIVE downtime before forcing re-login (must be >> persistent interval)
obj.monitorInterval   = 20                            -- s between health/keepalive checks

-- ── State glyphs ─────────────────────────────────────────────────────────────
local STATE_GLYPHS = {
  idle       = "VPN ⏸",
  trusted    = "VPN 🏛",
  probing    = "VPN ⋯",
  connecting = "VPN ⟳",
  connected  = "VPN ✓",
  failed     = "VPN ✗",
}

-- ── Helpers ──────────────────────────────────────────────────────────────────
function obj:configure(opts)
  for k, v in pairs(opts or {}) do self[k] = v end
  return self
end

function obj:_resolvePaths()
  local home = os.getenv("HOME")
  self.configPath = self.configPath or (home .. "/.config/openfortivpn/config")
  self.logFile    = self.logFile    or (home .. "/Library/Logs/fortivpn-auto.log")
end

function obj:_log(msg)
  if not self._logHandle then
    self._logHandle = io.open(self.logFile, "a")
  end
  if self._logHandle then
    self._logHandle:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), msg))
    self._logHandle:flush()
  end
  print(msg)
end

function obj:_notify(title, message)
  hs.notify.new({ title = title, informativeText = message, withdrawAfter = 6 }):send()
end

function obj:_currentSSID() return hs.wifi.currentNetwork() end

function obj:_isTrusted(ssid) return ssid ~= nil and self._trusted[ssid] == true end

function obj:_locationAuthorized()
  if not (hs.location and hs.location.authorizationStatus) then return true end
  local s = hs.location.authorizationStatus()
  return s == "authorizedAlways" or s == "authorized"
end

function obj:_setState(s)
  self._state = s
  self:_log("state -> " .. s)
  self:_updateMenubar()
end

function obj:_updateMenubar()
  if not self._menubar then return end
  self._menubar:setTitle(STATE_GLYPHS[self._state] or "VPN ?")
  self._menubar:setMenu({
    { title = "State: " .. (self._state or "?"), disabled = true },
    { title = "SSID:  " .. (self:_currentSSID() or "<none>"), disabled = true },
    { title = "-" },
    { title = "Force connect",    fn = function() self:_forceConnect() end },
    { title = "Force disconnect", fn = function() self:_disconnect("manual") end },
    { title = "-" },
    { title = "Show log",      fn = function() hs.task.new("/usr/bin/open", nil, { "-a", "Console", self.logFile }):start() end },
    { title = "Reload config", fn = function() hs.reload() end },
  })
end

-- ── VPN control ──────────────────────────────────────────────────────────────
function obj:_probeInternet(callback)
  self:_setState("probing")
  hs.http.asyncGet(self.captiveURL, nil, function(status, body, _)
    callback(status == 200 and body ~= nil and body:find("Success") ~= nil)
  end)
end

function obj:_scheduleRetry(reason)
  self._retryCount = self._retryCount + 1
  if self._retryCount > self.maxRetries then
    self:_log("retry budget exhausted (" .. reason .. ")")
    self:_notify("VPN failed", "Gave up after " .. self.maxRetries ..
                 " tries. Will retry on next network change.")
    self:_setState("failed")
    return
  end
  self:_log(string.format("retry %d/%d in %ds (%s)",
            self._retryCount, self.maxRetries, self.retryDelay, reason))
  self:_notify("VPN retry " .. self._retryCount .. "/" .. self.maxRetries,
               "Retrying in " .. self.retryDelay .. "s (" .. reason .. ")")
  self._retryTimer = hs.timer.doAfter(self.retryDelay, function()
    self._retryTimer = nil
    self:_attemptConnect()
  end)
end

function obj:_startVpnTask()
  self:_setState("connecting")
  self:_log("launching: sudo -n " .. self.binPath .. " -c " .. self.configPath .. " --saml-login")
  self._taskGen = (self._taskGen or 0) + 1
  local gen = self._taskGen   -- identity of THIS task; lets a stale exitCb no-op
  self._everConnected = false -- per-task: reached "up" yet? (gates the watchdog)
  local samlOpened = false

  local function streamCb(_, stdout, stderr)
    if stdout and #stdout > 0 then
      for line in stdout:gmatch("[^\r\n]+") do
        self:_log("vpn: " .. line)
        if not samlOpened then
          -- Exclude quotes from the class: openfortivpn wraps the URL in
          -- single quotes, and a greedy [^%s] would swallow the trailing '.
          local url = line:match("(https?://[^%s'\"]*saml[^%s'\"]*)")
          if url then
            samlOpened = true
            self:_log("opening SAML URL in browser: " .. url)
            hs.urlevent.openURL(url)
          end
        end
        if line:find("Tunnel is up and running") then
          self:_setState("connected")
          self._retryCount = 0
          self._everConnected = true
          self._downTicks = 0
          self:_notify("VPN connected", "Routing through " .. (self._gatewayLabel or "the VPN") .. ".")
        elseif line:find("Gateway certificate validation failed") then
          self:_notify("VPN cert rotated",
                       "Gateway cert digest changed. Run ./refresh-cert.sh (see README).")
        end
      end
    end
    if stderr and #stderr > 0 then
      for line in stderr:gmatch("[^\r\n]+") do self:_log("vpn-err: " .. line) end
    end
    return true
  end

  local function exitCb(exitCode, _, _)
    if gen ~= self._taskGen then return end  -- superseded (e.g. force-reconnect) — ignore this exit
    self:_log(string.format("openfortivpn exited (code=%d)", exitCode or -1))
    self._vpnTask = nil
    self:_stopMonitor()
    if self._state == "connected" then
      self:_setState("failed"); self:_scheduleRetry("tunnel dropped")
    elseif self._state == "connecting" or self._state == "probing" then
      self:_setState("failed"); self:_scheduleRetry("auth or connect failed")
    end
  end

  self._vpnTask = hs.task.new(self.sudoPath, exitCb, streamCb,
    { "-n", self.binPath, "-c", self.configPath, "--saml-login" })
  self._vpnTask:start()
  self:_startMonitor()
end

function obj:_disconnect(reason)
  reason = reason or "unknown"
  self:_log("disconnect requested: " .. reason)
  if self._retryTimer then self._retryTimer:stop(); self._retryTimer = nil end
  if self._startTimer then self._startTimer:stop(); self._startTimer = nil end
  if self._vpnTask then self._vpnTask:terminate(); self._vpnTask = nil end
  self:_stopMonitor()
  self:_setState(self:_isTrusted(self:_currentSSID()) and "trusted" or "idle")
end

function obj:_attemptConnect()
  self:_probeInternet(function(reachable)
    if not reachable then
      self:_notify("Captive portal?", "Sign in via browser, then I'll retry.")
      self:_scheduleRetry("captive portal")
      return
    end
    self:_startVpnTask()
  end)
end

function obj:_forceConnect()
  self._retryCount = 0
  if self._vpnTask then self:_disconnect("force-reconnect") end
  self:_attemptConnect()
end

function obj:_onWifiChange()
  local ssid = self:_currentSSID()
  self:_log("SSID event: " .. (ssid or "<nil>"))

  if self._retryTimer then self._retryTimer:stop(); self._retryTimer = nil end
  if self._startTimer then self._startTimer:stop(); self._startTimer = nil end
  self._retryCount = 0

  if not ssid then
    if not self:_locationAuthorized() then
      self:_log("SSID is nil AND Location Services is not authorized for Hammerspoon. " ..
                "On macOS 14+ the SSID can't be read without it — grant via System Settings → " ..
                "Privacy & Security → Location Services → Hammerspoon, then reload.")
    else
      self:_log("SSID is nil — treating as no Wi-Fi")
    end
    if self._vpnTask then self:_disconnect("no wifi") end
    self:_setState("idle")
    return
  end

  if self:_isTrusted(ssid) then
    if self._vpnTask then self:_disconnect("on trusted ssid") end
    self:_setState("trusted")
    return
  end

  if self._vpnTask then
    self:_log("non-trusted SSID changed; openfortivpn already running — letting it reconnect")
    return
  end
  self:_log("non-trusted SSID — connecting in " .. self.startDelay .. "s")
  self._startTimer = hs.timer.doAfter(self.startDelay, function()
    self._startTimer = nil
    self:_attemptConnect()
  end)
end

-- ── Connection monitor: keepalive + stuck-tunnel watchdog ────────────────────
-- One timer. While ppp0 is up it sends a keepalive ping (defeats an idle
-- timeout). If ppp0 stays down past reconnectGrace AFTER we'd connected — which
-- is exactly how openfortivpn's --persistent loop looks when the SAML cookie
-- has expired (it retries a dead cookie forever, silently, with no re-prompt) —
-- we restart the process to force a fresh browser login.
function obj:_startMonitor()
  if self._monitorTimer then return end
  self._downTicks = 0
  self._monitorTimer = hs.timer.doEvery(self.monitorInterval, function() self:_monitorTick() end)
end

function obj:_stopMonitor()
  if self._monitorTimer then self._monitorTimer:stop(); self._monitorTimer = nil end
  self._downTicks = 0
end

function obj:_monitorTick()
  hs.task.new("/sbin/ifconfig", function(code, out, _)
    if code == 0 then
      self._downTicks = 0
      local peer = out and out:match("inet%s+%S+%s+%-%->%s+(%S+)")
      if peer then self._peer = peer end
      if (self.keepaliveInterval or 0) > 0 then
        local now = os.time()
        if (now - (self._lastPing or 0)) >= self.keepaliveInterval then
          self._lastPing = now
          local target = (self.keepaliveHost ~= "" and self.keepaliveHost) or self._peer
          if target then
            hs.task.new("/sbin/ping", nil, { "-c", "1", "-t", "3", target }):start()
          end
        end
      end
    elseif self._everConnected and self._vpnTask then
      -- Count only AWAKE ticks (hs.timer pauses during sleep). This survives a
      -- long sleep/outage without a false-fire: openfortivpn gets real awake
      -- time to recover its still-valid cookie before we decide the session is
      -- actually dead (stuck retrying an expired cookie) and force a fresh login.
      self._downTicks = (self._downTicks or 0) + 1
      local threshold = math.max(1, math.floor(self.reconnectGrace / self.monitorInterval))
      if self._downTicks >= threshold then
        self:_log(string.format(
          "tunnel down ~%ds of active time — session likely expired; restarting for a fresh login",
          self._downTicks * self.monitorInterval))
        self._downTicks = 0
        self:_forceConnect()
      end
    end
  end, { "ppp0" }):start()
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────
function obj:start()
  self:_resolvePaths()

  self._trusted = {}
  for _, s in ipairs(self.trustedSSIDs) do self._trusted[s] = true end

  self._state = "idle"; self._vpnTask = nil; self._retryCount = 0
  self._startTimer = nil; self._retryTimer = nil; self._taskGen = 0
  self._monitorTimer = nil; self._downTicks = 0; self._everConnected = false
  self._lastPing = 0; self._peer = nil

  -- macOS 14+ gates Wi-Fi SSID reads behind Location Services. Trigger the
  -- authorization prompt once; without it hs.wifi.currentNetwork() returns nil.
  if self.requestLocation and hs.location and not self:_locationAuthorized() then
    self:_log("requesting Location Services authorization (required to read Wi-Fi SSID on macOS 14+)")
    pcall(function() hs.location.start() end)
  end

  self._menubar = hs.menubar.new()
  self:_updateMenubar()
  self._wifiWatcher = hs.wifi.watcher.new(function() self:_onWifiChange() end)
  self._wifiWatcher:start()
  self:_onWifiChange()  -- evaluate current network at load

  self:_log("== " .. self.name .. " " .. self.version .. " loaded ==")
  hs.alert.show(self.name .. " loaded")
  return self
end

function obj:stop()
  if self._retryTimer then self._retryTimer:stop(); self._retryTimer = nil end
  if self._startTimer then self._startTimer:stop(); self._startTimer = nil end
  if self._wifiWatcher then self._wifiWatcher:stop(); self._wifiWatcher = nil end
  if self._vpnTask then self._vpnTask:terminate(); self._vpnTask = nil end
  self:_stopMonitor()
  if self._menubar then self._menubar:delete(); self._menubar = nil end
  self:_log("== " .. self.name .. " stopped ==")
  if self._logHandle then self._logHandle:close(); self._logHandle = nil end
  return self
end

return obj

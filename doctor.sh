#!/usr/bin/env bash
#
# doctor.sh — read-only diagnostics for fortivpn-auto. Changes nothing.
# Reports every known failure mode in plain language.
#
#   ./doctor.sh             health check
#   ./doctor.sh --dry-run   + gateway reachability & captive-portal probe (no VPN dial)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

PASS=0; WARNS=0; FAILS=0
pass()  { ok "$*";   PASS=$((PASS+1)); }
flag()  { warn "$*"; WARNS=$((WARNS+1)); }
bad()   { err "$*";  FAILS=$((FAILS+1)); }

# Honor an OPENFORTIVPN_BIN override if a vpn.conf is sitting here.
OVERRIDE=""
if [ -f "$HERE/vpn.conf" ]; then
  OVERRIDE="$( ( source "$HERE/vpn.conf" 2>/dev/null; printf '%s' "${OPENFORTIVPN_BIN:-}" ) || true )"
fi

cfg_get() { grep -E "^$1[[:space:]]*=" "$OFV_CONFIG" 2>/dev/null | head -1 | sed -E "s/^$1[[:space:]]*=[[:space:]]*//"; }

banner
say "doctor — read-only health check"
echo >&2

# ── macOS ────────────────────────────────────────────────────────────────────
OSVER="$(sw_vers -productVersion 2>/dev/null || echo '?')"
MAJ="${OSVER%%.*}"
pass "macOS $OSVER"
if [ "${MAJ:-0}" -ge 14 ] 2>/dev/null; then
  flag "macOS 14+: reading the Wi-Fi SSID needs Location Services. Hammerspoon must have it (see below)."
fi

# ── Homebrew ─────────────────────────────────────────────────────────────────
if PREFIX="$(brew_prefix 2>/dev/null)"; then pass "Homebrew at $PREFIX"; else bad "Homebrew not found."; fi

# ── openfortivpn ─────────────────────────────────────────────────────────────
BIN="$(resolve_ofv_bin "$OVERRIDE" 2>/dev/null || true)"
if [ -z "$BIN" ]; then
  bad "openfortivpn not found (brew install openfortivpn)."
else
  VER="$(ofv_version "$BIN")"
  if ver_ge_1_21 "$VER"; then pass "openfortivpn $VER at $BIN"
  else bad "openfortivpn $VER too old (need >= 1.21). brew upgrade openfortivpn"; fi
fi

# ── Hammerspoon ──────────────────────────────────────────────────────────────
if [ -d "$HS_APP" ]; then pass "Hammerspoon installed"; else bad "Hammerspoon not installed (brew install --cask hammerspoon)."; fi
if pgrep -xq Hammerspoon; then pass "Hammerspoon is running"; else flag "Hammerspoon is not running — the watcher only works while it's up."; fi
if [ -d "$SPOON_DST" ]; then pass "Spoon installed at $SPOON_DST"; else bad "Spoon missing at $SPOON_DST (re-run install.sh)."; fi
if hs_block_present; then pass "loader block present in $HS_INIT"; else flag "no managed loader block in $HS_INIT (re-run install.sh, or wire it manually)."; fi

# ── openfortivpn config + cert pin ───────────────────────────────────────────
if [ -f "$OFV_CONFIG" ]; then
  PERM="$(stat -f '%Lp' "$OFV_CONFIG" 2>/dev/null || echo '?')"
  [ "$PERM" = "600" ] && pass "config $OFV_CONFIG (mode 600)" || flag "config mode is $PERM (expected 600): chmod 600 $OFV_CONFIG"
  HOST="$(cfg_get host)"; PORT="$(cfg_get port)"; PINNED="$(cfg_get trusted-cert)"
  if [ -n "$HOST" ] && [ -n "$PORT" ]; then
    pass "gateway $HOST:$PORT"
    spin_capture LIVE "checking pinned cert against the live gateway…" fetch_live_cert "$HOST" "$PORT"
    if [ -z "$LIVE" ]; then
      flag "couldn't reach $HOST:$PORT to compare cert (offline / captive portal?)."
    elif [ "$LIVE" = "$PINNED" ]; then
      pass "pinned cert matches the live gateway"
    else
      bad "PINNED CERT MISMATCH — gateway cert rotated. Run ./refresh-cert.sh"
      printf '      pinned: %s\n      live:   %s\n' "$PINNED" "$LIVE" >&2
    fi
  else
    bad "config missing host/port — re-run install.sh"
  fi
else
  bad "no openfortivpn config at $OFV_CONFIG (run install.sh)."
fi

# ── sudoers NOPASSWD grant (no dial, no password prompt) ─────────────────────
if [ -n "${BIN:-}" ] && [ -f "$OFV_CONFIG" ]; then
  if sudo -n -l "$BIN" -c "$OFV_CONFIG" --saml-login >/dev/null 2>&1; then
    pass "NOPASSWD sudoers grant is active for the dial command"
  else
    flag "couldn't confirm the NOPASSWD grant (inactive, or listing needs a password). Check $SUDOERS_FILE"
  fi
fi

# ── LaunchAgent ──────────────────────────────────────────────────────────────
if launchctl print "gui/$(id -u)/$LA_LABEL" >/dev/null 2>&1; then
  pass "LaunchAgent loaded ($LA_LABEL)"
elif [ -f "$PLIST" ]; then
  flag "LaunchAgent plist exists but isn't loaded: launchctl bootstrap gui/\$(id -u) $PLIST"
else
  flag "no LaunchAgent (installed with --no-agent?). Hammerspoon won't relaunch automatically."
fi

# ── Location Services hint (SSID readability from this shell) ─────────────────
WIFI_DEV="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')"
WIFI_DEV="${WIFI_DEV:-en0}"
SSID_SUMMARY="$(ipconfig getsummary "$WIFI_DEV" 2>/dev/null | awk -F' SSID : ' '/ SSID : /{print $2; exit}')"
if [ -n "$SSID_SUMMARY" ]; then
  if [ "$SSID_SUMMARY" = "<redacted>" ]; then
    say "FYI: this shell sees SSID as <redacted> (no Location Services). Confirm Hammerspoon can read it: HS Console → hs.wifi.currentNetwork() should return your SSID, not nil."
  else
    say "FYI: current SSID readable here as '$SSID_SUMMARY'. HS Console → hs.wifi.currentNetwork() should return it too (not nil)."
  fi
fi

# ── Dry-run connectivity probes (no dial) ────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ] && [ -f "$OFV_CONFIG" ]; then
  echo >&2; say "dry-run probes (no VPN dial):"
  H="$(cfg_get host)"; P="$(cfg_get port)"
  if /usr/bin/nc -z -G 5 "$H" "$P" 2>/dev/null; then pass "gateway TCP $H:$P reachable"
  else flag "gateway $H:$P not reachable on TCP (no internet, captive portal, or egress block)."; fi
  BODY="$(curl -sS -m 5 http://captive.apple.com/hotspot-detect.html 2>/dev/null || true)"
  if printf '%s' "$BODY" | grep -q Success; then pass "no captive portal in the way"
  else flag "looks like a captive portal — sign in via browser first."; fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo >&2
result_bar "$PASS" "$WARNS" "$FAILS"
say "summary: ${C_GRN}$PASS ok${C_NC} · ${C_YLW}$WARNS warn${C_NC} · ${C_RED}$FAILS fail${C_NC}"
[ "$FAILS" -eq 0 ]

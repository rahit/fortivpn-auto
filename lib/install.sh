#!/usr/bin/env bash
#
# install.sh — set up fortivpn-auto on macOS. Idempotent and non-clobbering:
# safe to re-run; backs up (never overwrites) your openfortivpn config and
# Hammerspoon init.lua; installs sudoers only via validated visudo.
#
# Usage (via the dispatcher):
#   fortivpn-auto install --preset ucalgary
#   fortivpn-auto install --config /path/to/vpn.conf [--no-agent]

set -euo pipefail
ROOT="${FVA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=common.sh
source "$ROOT/lib/common.sh"

INSTALL_AGENT=1
CONFIG_PATH="vpn.conf"

usage() {
  cat >&2 <<EOF
fortivpn-auto installer

  --preset NAME    use presets/NAME.conf (e.g. --preset ucalgary)
  --config PATH    use a specific config file (default: ./vpn.conf)
  --no-agent       don't install/launch the LaunchAgent (you'll launch
                   Hammerspoon manually and can enable supervision later)
  -h, --help       this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --preset) [ $# -ge 2 ] || die "--preset needs a name"; CONFIG_PATH="$ROOT/presets/$2.conf"; shift 2 ;;
    --config) [ $# -ge 2 ] || die "--config needs a path"; CONFIG_PATH="$2"; shift 2 ;;
    --no-agent) INSTALL_AGENT=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "fortivpn-auto is macOS-only."

banner
load_config "$CONFIG_PATH"
say "config:  $CONFIG_PATH"
say "gateway: $GATEWAY_HOST:$GATEWAY_PORT"
say "trusted: ${TRUSTED_SSIDS[*]}"
echo >&2
STEP_TOTAL=9; [ "$INSTALL_AGENT" -eq 0 ] && STEP_TOTAL=8

# ── 1. Homebrew ──────────────────────────────────────────────────────────────
step "checking Homebrew"
PREFIX="$(brew_prefix 2>/dev/null || true)"
[ -n "$PREFIX" ] || die "Homebrew not found. Install it from https://brew.sh and re-run (we don't auto-install it — it needs admin and edits your shell profile)."
ok "Homebrew at $PREFIX"

# ── 2. openfortivpn (>= 1.21) ────────────────────────────────────────────────
step "checking openfortivpn (need >= 1.21)"
BIN="$(resolve_ofv_bin "$OPENFORTIVPN_BIN" || true)"
if [ -z "$BIN" ]; then
  say "not found — installing via Homebrew..."
  brew install openfortivpn
  BIN="$(resolve_ofv_bin "$OPENFORTIVPN_BIN" || true)"
  [ -n "$BIN" ] || die "openfortivpn still not found after install."
fi
VER="$(ofv_version "$BIN")"
ver_ge_1_21 "$VER" || die "openfortivpn $VER is too old (need >= 1.21 for --saml-login). Run: brew upgrade openfortivpn"
ok "openfortivpn $VER at $BIN"

# ── 3. Hammerspoon ───────────────────────────────────────────────────────────
step "checking Hammerspoon"
if [ ! -d "$HS_APP" ]; then
  say "not found — installing cask..."
  brew install --cask hammerspoon
fi
[ -x "$HS_BIN" ] || die "Hammerspoon present but binary missing at $HS_BIN"
ok "Hammerspoon at $HS_APP"

# ── 4. Cert pin (live fetch unless pinned in config) ─────────────────────────
step "pinning gateway certificate"
if [ -n "$TRUSTED_CERT" ]; then
  DIGEST="$TRUSTED_CERT"
  ok "using cert digest pinned in config"
else
  spin_capture DIGEST "fetching live cert from $GATEWAY_HOST:$GATEWAY_PORT…" \
    fetch_live_cert "$GATEWAY_HOST" "$GATEWAY_PORT" || true
  [ -n "$DIGEST" ] || die "Could not retrieve the gateway certificate (no network, or a captive portal is in the way). Refusing to continue without a pin — we never use --insecure-ssl."
  ok "pinned live cert: $DIGEST"
fi

# ── 5. openfortivpn config (600, backed up) ──────────────────────────────────
step "writing openfortivpn config"
mkdir -p "$OFV_CONFIG_DIR"
B="$(backup_file "$OFV_CONFIG" || true)"
[ -n "$B" ] && warn "backed up existing config -> $B"
{
  echo "# Managed by fortivpn-auto. Edit vpn.conf and re-run install.sh instead."
  echo "host = $GATEWAY_HOST"
  echo "port = $GATEWAY_PORT"
  echo "trusted-cert = $DIGEST"
  [ -n "$REALM" ] && echo "realm = $REALM"
} > "$OFV_CONFIG"
chmod 600 "$OFV_CONFIG"
ok "wrote $OFV_CONFIG (chmod 600)"

# ── 6. Spoon ─────────────────────────────────────────────────────────────────
step "installing Hammerspoon Spoon"
mkdir -p "$HS_DIR/Spoons"
rm -rf "$SPOON_DST"
cp -R "$ROOT/Spoons/$SPOON_NAME.spoon" "$SPOON_DST"
ok "installed Spoon -> $SPOON_DST"

# ── 7. init.lua loader block (sentinel-guarded, backed up, idempotent) ───────
step "wiring loader into init.lua"
mkdir -p "$HS_DIR"
if [ -f "$HS_INIT" ]; then
  B="$(backup_file "$HS_INIT" || true)"
  [ -n "$B" ] && warn "backed up existing init.lua -> $B"
fi
remove_hs_block   # drop any prior managed block so re-runs don't stack
SSID_LUA="$(lua_ssid_table "${TRUSTED_SSIDS[@]}")"
{
  [ -f "$HS_INIT" ] && echo ""
  echo "$HS_BLOCK_BEGIN"
  echo 'hs.loadSpoon("FortiVPNAuto")'
  echo 'spoon.FortiVPNAuto:configure({'
  echo "  trustedSSIDs = $SSID_LUA,"
  echo "  binPath      = \"$BIN\","
  echo "  configPath   = \"$OFV_CONFIG\","
  echo '})'
  echo 'spoon.FortiVPNAuto:start()'
  echo "$HS_BLOCK_END"
} >> "$HS_INIT"
ok "wired loader into $HS_INIT (managed block)"

# ── 8. sudoers (validated install, never raw cp) ─────────────────────────────
step "installing scoped sudoers grant"
if [[ "$BIN" == *" "* || "$OFV_CONFIG" == *" "* ]]; then
  die "a space in the openfortivpn path or config path can't be safely argument-matched in sudoers ($BIN | $OFV_CONFIG). Use a space-free path (set OPENFORTIVPN_BIN)."
fi
SUDO_USER_NAME="$(id -un)"
RULE="$SUDO_USER_NAME ALL=(root) NOPASSWD: $BIN -c $OFV_CONFIG --saml-login"
SUDOERS_TMP="$(mktemp "${TMPDIR:-/tmp}/fortivpn-auto.sudoers.XXXXXX")"
{
  echo "# Managed by fortivpn-auto. Grants passwordless sudo for ONLY this exact"
  echo "# openfortivpn invocation, so Hammerspoon can dial without nagging."
  echo "$RULE"
} > "$SUDOERS_TMP"
chmod 644 "$SUDOERS_TMP"

say "sudo will prompt — validating with visudo first (a bad file is never installed)..."
if ! sudo visudo -cf "$SUDOERS_TMP"; then
  rm -f "$SUDOERS_TMP"
  die "visudo rejected the sudoers file — nothing installed."
fi
sudo install -m 0440 -o root -g wheel "$SUDOERS_TMP" "$SUDOERS_FILE"
rm -f "$SUDOERS_TMP"
ok "installed $SUDOERS_FILE"

if sudo -n -l "$BIN" -c "$OFV_CONFIG" --saml-login >/dev/null 2>&1; then
  ok "NOPASSWD grant verified (sudo -l, no VPN dial)"
else
  warn "couldn't confirm the NOPASSWD grant. Ensure $SUDOERS_FILE references: $BIN"
fi

# ── 9. LaunchAgent (supervise Hammerspoon) ───────────────────────────────────
if [ "$INSTALL_AGENT" -eq 1 ]; then
  step "installing LaunchAgent (auto-start + crash-restart)"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LA_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$HS_BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LA_LABEL" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    ok "LaunchAgent loaded (Hammerspoon starts now + at login, with crash-restart)"
  else
    warn "LaunchAgent written to $PLIST but bootstrap failed. Load it with:"
    warn "  launchctl bootstrap gui/\$(id -u) $PLIST"
  fi
else
  say "skipped LaunchAgent (--no-agent). Launch Hammerspoon yourself when ready."
fi

# ── Next steps ───────────────────────────────────────────────────────────────
cat >&2 <<EOF

${C_GRN}✦ install complete.${C_NC} two manual permission grants left (macOS gatekeeps these),
then you're locked in:

  1. open Hammerspoon. grant ${C_CYN}Accessibility${C_NC} + ${C_CYN}Notifications${C_NC} if asked.
  2. ${C_CYN}Location Services${C_NC} — non-negotiable on macOS 14+ (it's how the SSID is read).
     the Spoon pops the prompt on load → click Allow. no prompt? open the
     Hammerspoon Console and run:  hs.location.start()
     then flip Hammerspoon on under System Settings → Privacy & Security →
     Location Services.

sanity check anytime:   ./doctor.sh
vibe check the dial:    leave trusted Wi-Fi (hotspot) → browser SSO → menubar VPN ✓
cert rotated (rare):    ./refresh-cert.sh
nuke it all:            ./uninstall.sh
EOF

#!/usr/bin/env bash
#
# uninstall.sh — reverse what install.sh did. Prompts before anything
# destructive. Leaves Homebrew formulae alone unless you opt in.
#
#   ./uninstall.sh            interactive
#   ./uninstall.sh --yes      assume yes to file removals (keeps brew formulae)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

yes_or_ask() { [ "$ASSUME_YES" -eq 1 ] || confirm "$1"; }

[ "$(uname -s)" = "Darwin" ] || die "macOS-only."

banner
say "uninstalling fortivpn-auto"

# ── 1. LaunchAgent ───────────────────────────────────────────────────────────
if [ -f "$PLIST" ]; then
  say "Removing LaunchAgent..."
  launchctl bootout "gui/$(id -u)/$LA_LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  ok "removed $PLIST"
else
  say "No LaunchAgent found."
fi

# ── 2. init.lua managed block ────────────────────────────────────────────────
if hs_block_present; then
  B="$(backup_file "$HS_INIT" || true)"
  [ -n "$B" ] && say "backed up init.lua -> $B"
  remove_hs_block
  ok "removed managed loader block from $HS_INIT"
else
  say "No managed block in init.lua."
fi

# ── 3. Spoon ─────────────────────────────────────────────────────────────────
if [ -d "$SPOON_DST" ]; then
  rm -rf "$SPOON_DST"
  ok "removed $SPOON_DST"
fi

# ── 4. sudoers ───────────────────────────────────────────────────────────────
if [ -e "$SUDOERS_FILE" ]; then
  say "Removing $SUDOERS_FILE — sudo will prompt."
  sudo rm -f "$SUDOERS_FILE"
  ok "removed sudoers grant"
else
  say "No sudoers grant found."
fi

# ── 5. openfortivpn config (optional — holds your cert pin) ───────────────────
if [ -e "$OFV_CONFIG" ]; then
  if yes_or_ask "Remove $OFV_CONFIG (your gateway + pinned cert)?"; then
    rm -f "$OFV_CONFIG"
    ok "removed $OFV_CONFIG"
  else
    say "kept $OFV_CONFIG"
  fi
fi

# ── 6. Homebrew formulae (opt-in) ────────────────────────────────────────────
if command -v brew >/dev/null 2>&1; then
  if [ "$ASSUME_YES" -eq 0 ] && confirm "Also 'brew uninstall openfortivpn'?"; then
    brew uninstall openfortivpn || true
  fi
  if [ "$ASSUME_YES" -eq 0 ] && confirm "Also 'brew uninstall --cask hammerspoon'? (removes ALL your Hammerspoon config use)"; then
    brew uninstall --cask hammerspoon || true
  fi
fi

say "Done. If Hammerspoon is still running, quit it (or it'll keep watching until you do)."
say "Note: macOS Location Services / Accessibility entries for Hammerspoon are not removed by this script — clear them in System Settings if you want."

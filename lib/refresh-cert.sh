#!/usr/bin/env bash
#
# refresh-cert.sh — re-pin the gateway's SSL cert after it rotates.
# FortiGate EV certs typically renew yearly; a connect then fails with
# "Gateway certificate validation failed". This fetches the live digest and
# updates the pin in ~/.config/openfortivpn/config (after a backup).

set -euo pipefail
ROOT="${FVA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=common.sh
source "$ROOT/lib/common.sh"

banner
[ -f "$OFV_CONFIG" ] || die "no config at $OFV_CONFIG — run: fortivpn-auto install"

field() { grep -E "^$1[[:space:]]*=" "$OFV_CONFIG" | head -1 | sed -E "s/^$1[[:space:]]*=[[:space:]]*//;s/[[:space:]]+\$//"; }
HOST="$(field host)"; PORT="$(field port)"; PINNED="$(field trusted-cert)"
[ -n "$HOST" ] && [ -n "$PORT" ] || die "config is missing host/port."

say "Fetching live cert from $HOST:$PORT ..."
LIVE="$(fetch_live_cert "$HOST" "$PORT")"
[ -n "$LIVE" ] || die "couldn't retrieve the live cert (offline, or a captive portal is in the way)."

if [ "$LIVE" = "$PINNED" ]; then
  ok "pin already current: $LIVE"
  exit 0
fi

warn "certificate has rotated:"
printf '      pinned: %s\n      live:   %s\n' "$PINNED" "$LIVE" >&2
confirm "Update the pin to the live cert?" || { say "left unchanged."; exit 0; }

B="$(backup_file "$OFV_CONFIG" || true)"
[ -n "$B" ] && say "backed up -> $B"
sed -i '' -E "s|^trusted-cert[[:space:]]*=.*|trusted-cert = $LIVE|" "$OFV_CONFIG"
ok "re-pinned. Reconnect (menubar → Force connect) to pick up the new cert."

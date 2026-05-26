# lib/common.sh — shared helpers for fortivpn-auto.
# Sourced by install.sh / uninstall.sh / doctor.sh / refresh-cert.sh.
# No side effects on source; callers set their own `set` options.

# ── Identity / paths ─────────────────────────────────────────────────────────
APP_NAME="fortivpn-auto"
FVA_VERSION="1.0.0"
LA_LABEL="io.github.rahit.fortivpn-auto"
SPOON_NAME="FortiVPNAuto"

HS_APP="/Applications/Hammerspoon.app"
HS_BIN="$HS_APP/Contents/MacOS/Hammerspoon"
HS_DIR="$HOME/.hammerspoon"
HS_INIT="$HS_DIR/init.lua"
SPOON_DST="$HS_DIR/Spoons/$SPOON_NAME.spoon"

OFV_CONFIG_DIR="$HOME/.config/openfortivpn"
OFV_CONFIG="$OFV_CONFIG_DIR/config"

SUDOERS_FILE="/etc/sudoers.d/fortivpn-auto"
PLIST="$HOME/Library/LaunchAgents/$LA_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/fortivpn-auto.log"

HS_BLOCK_BEGIN="-- >>> fortivpn-auto (managed -- do not edit between markers) >>>"
HS_BLOCK_END="-- <<< fortivpn-auto (managed) <<<"

# ── Logging (to stderr, so command substitution of helpers stays clean) ──────
if [ -t 2 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_CYN=$'\033[0;36m'; C_DIM=$'\033[2m'; C_NC=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_DIM=""; C_NC=""
fi
say()  { printf '%s==>%s %s\n' "$C_CYN" "$C_NC" "$*" >&2; }
ok()   { printf '%s ✓%s %s\n'  "$C_GRN" "$C_NC" "$*" >&2; }
warn() { printf '%s !%s %s\n'  "$C_YLW" "$C_NC" "$*" >&2; }
err()  { printf '%s ✗%s %s\n'  "$C_RED" "$C_NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

confirm() { local a; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }

# ── Toolchain detection ──────────────────────────────────────────────────────
brew_prefix() {
  if command -v brew >/dev/null 2>&1; then brew --prefix
  elif [ -x /opt/homebrew/bin/brew ]; then echo /opt/homebrew
  elif [ -x /usr/local/bin/brew ]; then echo /usr/local
  else return 1; fi
}

# Resolve the openfortivpn binary: explicit override > PATH > brew prefix > MacPorts.
resolve_ofv_bin() {
  local override="${1:-}"
  if [ -n "$override" ]; then echo "$override"; return 0; fi
  if command -v openfortivpn >/dev/null 2>&1; then command -v openfortivpn; return 0; fi
  local p; p="$(brew_prefix 2>/dev/null || true)"
  [ -n "$p" ] && [ -x "$p/bin/openfortivpn" ] && { echo "$p/bin/openfortivpn"; return 0; }
  [ -x /opt/local/bin/openfortivpn ] && { echo /opt/local/bin/openfortivpn; return 0; }
  return 1
}

ofv_version() { "$1" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

# openfortivpn >= 1.21 is required for --saml-login.
ver_ge_1_21() {
  local v="${1:-0.0}" maj min
  maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
  [ "${maj:-0}" -gt 1 ] || { [ "${maj:-0}" -eq 1 ] && [ "${min:-0}" -ge 21 ]; }
}

# ── Cert pinning ─────────────────────────────────────────────────────────────
# Live SHA-256 fingerprint of the gateway cert: lowercase, colons stripped.
fetch_live_cert() {
  # Bound the TLS handshake: a filtered port would otherwise hang s_client for
  # ~75s (BSD openssl has no -timeout). nc gives us a 5s reachability cap first.
  /usr/bin/nc -z -G 5 "$1" "$2" 2>/dev/null || return 1
  echo | openssl s_client -connect "$1:$2" -servername "$1" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | awk -F= 'NF==2 {gsub(":","",$2); print tolower($2)}'
}

# ── Config ───────────────────────────────────────────────────────────────────
load_config() {
  local f="$1"
  [ -f "$f" ] || die "config not found: $f  — use 'fortivpn-auto install --preset NAME' or '--config PATH' (template: $ROOT/vpn.conf.example)"
  # Pre-declare so `set -u` is safe even if the file omits optionals.
  TRUSTED_SSIDS=(); TRUSTED_CERT=""; OPENFORTIVPN_BIN=""; REALM=""
  START_DELAY=""; RETRY_DELAY=""; MAX_RETRIES=""
  # shellcheck disable=SC1090
  source "$f"
  : "${GATEWAY_HOST:?GATEWAY_HOST missing in $f}"
  : "${GATEWAY_PORT:?GATEWAY_PORT missing in $f}"
  [ "${#TRUSTED_SSIDS[@]}" -gt 0 ] || die "TRUSTED_SSIDS is empty in $f — set at least your home/secure SSID"
}

# Render a Lua list literal from the given args: { "a", "b" }
lua_ssid_table() {
  local out="{ " s
  for s in "$@"; do
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    out+="\"$s\", "
  done
  printf '%s}' "$out"
}

# ── File helpers ─────────────────────────────────────────────────────────────
# Timestamped backup; echoes the backup path (so callers can report it).
backup_file() {
  [ -e "$1" ] || return 0
  local b; b="$1.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$1" "$b" && echo "$b"
}

# -e is required: the marker starts with "--", which grep would treat as options.
hs_block_present() { [ -f "$HS_INIT" ] && grep -qF -e "$HS_BLOCK_BEGIN" "$HS_INIT"; }

# Strip our managed block (between markers, inclusive) from ~/.hammerspoon/init.lua.
remove_hs_block() {
  [ -f "$HS_INIT" ] || return 0
  awk -v b="$HS_BLOCK_BEGIN" -v e="$HS_BLOCK_END" '
    $0==b { skip=1 }
    skip==0 { print }
    $0==e { skip=0 }
  ' "$HS_INIT" > "$HS_INIT.tmp" && mv "$HS_INIT.tmp" "$HS_INIT"
}

# ── Pretty output: banner, progress bar, spinner, result graph ───────────────
# All TTY-gated where it matters, so piped / CI output stays clean.

banner() {
  printf '\n%s' "$C_CYN" >&2
  cat >&2 <<'ART'
  ┌───────────────────────────────────────────────┐
  │  fortivpn-auto   ·   wifi flips → vpn rips  ⚡   │
  └───────────────────────────────────────────────┘
ART
  printf '%s' "$C_NC" >&2
}

# Step progress bar:  [████░░░░░]  4/9  message
STEP_N=0
STEP_TOTAL=9
step() {
  STEP_N=$((STEP_N + 1))
  local i bar=""
  for ((i = 1; i <= STEP_TOTAL; i++)); do
    if [ "$i" -le "$STEP_N" ]; then bar+="█"; else bar+="░"; fi
  done
  printf '%s[%s]%s %s%d/%d%s  %s\n' "$C_CYN" "$bar" "$C_NC" "$C_DIM" "$STEP_N" "$STEP_TOTAL" "$C_NC" "$1" >&2
}

# Run a quiet, value-returning command behind a spinner; assign stdout to $1.
# Falls back to a plain run when stderr isn't a TTY.
spin_capture() {
  local __var="$1" __msg="$2"; shift 2
  local __out __ec=0; __out="$(mktemp)"
  if [ -t 2 ]; then
    "$@" >"$__out" 2>/dev/null &
    local __pid=$! i=0
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    while kill -0 "$__pid" 2>/dev/null; do
      printf '\r%s%s%s %s' "$C_CYN" "${frames[i++ % 10]}" "$C_NC" "$__msg" >&2
      sleep 0.08
    done
    wait "$__pid"; __ec=$?
    printf '\r\033[K' >&2
  else
    "$@" >"$__out" 2>/dev/null || __ec=$?
  fi
  printf -v "$__var" '%s' "$(cat "$__out")"
  rm -f "$__out"
  return "$__ec"
}

# Stacked colour bar for the doctor summary: $1 ok, $2 warn, $3 fail.
result_bar() {
  local p="$1" w="$2" f="$3" i out=""
  for ((i = 0; i < p; i++)); do out+="${C_GRN}█${C_NC}"; done
  for ((i = 0; i < w; i++)); do out+="${C_YLW}█${C_NC}"; done
  for ((i = 0; i < f; i++)); do out+="${C_RED}█${C_NC}"; done
  printf '  %s\n' "$out" >&2
}

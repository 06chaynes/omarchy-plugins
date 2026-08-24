#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/settings"
STATE_FILE="$STATE_DIR/hue.json"
CACERT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/hue_bridge_cacert.pem"
DEVICETYPE="${PHILIPS_HUE_DEVICETYPE:-philips#omarchy-hue}"
DEVICETYPE="${DEVICETYPE//[^a-zA-Z0-9#_-]/}"

BRIDGE_IP="${1:-}"

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m::\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m::\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m::\033[0m %s\n' "$*"; }

prompt_exit() {
  local code=$?
  echo ""
  if [[ $code -ne 0 ]]; then
    err "Pairing was not completed."
  fi
  read -r -p "Press Enter to close..." </dev/tty 2>/dev/null || true
}
trap prompt_exit EXIT

valid_ip() {
  local ip="$1"
  local IFS='.'
  read -r -a parts <<< "$ip"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
}

discover_bridge() {
  local response ip
  response=$(curl -fsS --max-time 5 https://discovery.meethue.com/ 2>/dev/null || true)
  [[ -z "$response" ]] && return 1
  ip=$(python3 -c "
import json, sys
d = json.load(sys.stdin)
ips = [x.get('internalipaddress', '') for x in d if x.get('internalipaddress')]
print(ips[0] if ips else '')
" <<<"$response")
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip"
}

fetch_bridge_id() {
  local ip="$1" bridge_id
  bridge_id=$(CACERT="$CACERT" TARGET_IP="$ip" python3 - <<'PY' 2>/dev/null || true
import json, os, ssl, sys, urllib.request
cacert = os.environ.get("CACERT", "")
target = os.environ.get("TARGET_IP", "")
ctx = ssl.create_default_context(cafile=cacert)
ctx.check_hostname = False
try:
    with urllib.request.urlopen("https://%s/api/config" % target, timeout=5, context=ctx) as r:
        d = json.load(r)
        bid = d.get("bridgeid", "")
        bid = bid.lower() if bid else ""
        if all(c in "0123456789abcdef" for c in bid) and len(bid) == 16:
            print(bid)
except Exception:
    pass
PY
  )
  printf '%s\n' "$bridge_id"
}

try_pair() {
  local ip="$1" bridge_id="$2" response username
  response=$(curl -fsS --max-time 5 --cacert "$CACERT" \
    --resolve "${bridge_id}:443:${ip}" \
    -X POST -H "Content-Type: application/json" \
    -d "{\"devicetype\":\"$DEVICETYPE\"}" "https://${bridge_id}/api" 2>/dev/null || true)
  username=$(python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for item in d:
        if isinstance(item, dict) and 'success' in item and 'username' in item['success']:
            u = item['success']['username']
            if len(u) >= 16 and all(c.isalnum() or c in '-_' for c in u):
                print(u)
            break
except Exception:
    pass
" <<<"$response")
  if [[ -n "$username" ]]; then
    printf '%s\n' "$username"
    return 0
  fi
  return 1
}

if [[ -f "$STATE_FILE" ]] && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('bridgeIp') else 1)" "$STATE_FILE" 2>/dev/null; then
  info "Existing config found at $STATE_FILE."
  info "Re-pairing will replace the current username."
fi

local_ip=""
if [[ -n "$BRIDGE_IP" ]]; then
  local_ip="$BRIDGE_IP"
else
  info "Discovering Philips Hue bridge on local network..."
  local_ip=$(discover_bridge) || true
  if [[ -z "$local_ip" ]]; then
    read -r -p "Couldn't discover bridge automatically. Enter its IP address: " local_ip </dev/tty
  fi
fi

if [[ -z "$local_ip" ]]; then
  err "No bridge IP provided. Aborting."
  exit 1
fi

if ! valid_ip "$local_ip"; then
  err "Invalid IP address: $local_ip"
  exit 1
fi

info "Connecting to bridge at $local_ip..."

bridge_id=$(fetch_bridge_id "$local_ip")
if [[ -z "$bridge_id" ]]; then
  err "Could not fetch bridge ID from $local_ip. Ensure the bridge is powered on and connected."
  exit 1
fi
ok "Found Bridge ID: ${bridge_id:0:8}***"

echo ""
info ">> PRESS THE LINK BUTTON ON YOUR HUE BRIDGE NOW <<"
info "Waiting for button press (up to 60 seconds)..."

username=""
timeout_secs=60
start_time=$(date +%s)

while true; do
  current_time=$(date +%s)
  elapsed=$(( current_time - start_time ))
  remaining=$(( timeout_secs - elapsed ))

  if (( remaining <= 0 )); then
    break
  fi

  if username=$(try_pair "$local_ip" "$bridge_id"); then
    break
  fi

  printf "\r\033[K\033[1;34m::\033[0m Waiting for link button press... (%ds remaining)" "$remaining"
  sleep 1.5
done
echo ""

if [[ -z "$username" ]]; then
  err "Pairing timed out. The link button was not detected within $timeout_secs seconds."
  exit 1
fi

ok "Bridge link verified! Received authentication token."

mkdir -p "$STATE_DIR"
printf '%s\n%s\n%s\n' "$local_ip" "$bridge_id" "$username" | python3 -c "
import json, os, sys
bridge_ip, bridge_id, username = sys.stdin.read().splitlines()[:3]
fd = os.open('''$STATE_FILE''', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump({'bridgeIp': bridge_ip, 'bridgeId': bridge_id, 'username': username}, f, indent=2)
    f.write('\n')
" 2>/dev/null || {
  rm -f "$STATE_FILE" 2>/dev/null
  printf '%s\n%s\n%s\n' "$local_ip" "$bridge_id" "$username" | python3 -c "
import json, os, sys
bridge_ip, bridge_id, username = sys.stdin.read().splitlines()[:3]
fd = os.open('''$STATE_FILE''', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump({'bridgeIp': bridge_ip, 'bridgeId': bridge_id, 'username': username}, f, indent=2)
    f.write('\n')
"
}
ok "Saved credentials to $STATE_FILE"

if [[ ! -f "$CACERT" ]]; then
  warn "CA cert not found at $CACERT. Cannot verify bridge connection."
  exit 0
fi

info "Verifying connection and fetching lights..."
light_count=$(python3 "$(dirname -- "${BASH_SOURCE[0]}")/hue-api.py" verify 2>/dev/null || true)
if [[ -n "$light_count" ]]; then
  ok "Connected successfully! Found $light_count light(s)."
else
  warn "Config saved, but lights could not be listed yet. The panel will retry automatically."
fi

ok "All done! Your Hue lights should now appear in the bar panel."

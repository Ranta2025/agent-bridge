# shellcheck shell=bash
# State helpers shared by the bridge scripts. Requires BRIDGE (the bridge directory).
BRIDGE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${BRIDGE:-${BRIDGE_DIR:?BRIDGE_DIR not set}}"
export BRIDGE_DIR="$BRIDGE"
PY="${BRIDGE_PYTHON:-python3}"
STATE_DIR="$BRIDGE/state"

# Current epoch. BRIDGE_NOW (tests) freezes the clock; bsleep then advances a virtual offset instead of sleeping.
now() {
  if [[ -n "${BRIDGE_NOW:-}" ]]; then
    local off=0
    [[ -f "$BRIDGE/.vclock" ]] && off="$(<"$BRIDGE/.vclock")"
    echo $((BRIDGE_NOW + ${off:-0}))
  else
    date +%s
  fi
}

bsleep() {
  if [[ -n "${BRIDGE_NOW:-}" ]]; then
    local off=0
    [[ -f "$BRIDGE/.vclock" ]] && off="$(<"$BRIDGE/.vclock")"
    echo $((${off:-0} + $1)) >"$BRIDGE/.vclock"
  else
    sleep "$1"
  fi
}

# Run a state.py command.
st() { "$PY" -I "$BRIDGE_LIB/state.py" "$@"; }

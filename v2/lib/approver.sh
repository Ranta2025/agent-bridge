# shellcheck shell=bash
# Scoped auto-approver: answers opencode's permission dialog ("Allow once") only while a bridge job is active for it.
# Requires state.sh, herdr.sh. The decision lives in approver.py + approver.policy; this file reads the pane and acts.

approver_policy() {
  if [[ -n "${APPROVER_POLICY:-}" ]]; then echo "$APPROVER_POLICY"
  elif [[ -f "$BRIDGE/approver.policy" ]]; then echo "$BRIDGE/approver.policy"
  else echo "$DEFAULT_BRIDGE/approver.policy"
  fi
}

# Mode: on (default) | dry (log would_approve, send nothing) | off.
approve_mode() {
  local m=""
  [[ -f "$BRIDGE/approver.mode" ]] && m="$(tr -d '[:space:]' <"$BRIDGE/approver.mode")"
  case "$m" in on | off | dry) echo "$m" ;; *) echo on ;; esac
}

# Read the pane and evaluate it into EV: "none" or "dialog<TAB>allow|refuse<TAB>sig<TAB>tool<TAB>target<TAB>reason".
approve_eval() { # target
  local cwd screen
  cwd="$(pane_path "$1")"
  screen="$(read_pane "$1" 40 2>/dev/null)" || true
  EV="$(printf '%s\n' "$screen" | "$PY" -I "$BRIDGE_LIB/approver.py" evaluate --cwd "${cwd:-$PWD}" --policy "$(approver_policy)")" || EV=none
}

# approve-once prints what it did; tick and watch stay silent.
approve_say() { [[ -z "${APPROVE_SAY:-}" ]] || echo "$*"; }

# One decision for one job. Sends at most one Enter per attempt, two attempts per dialog, and nothing else.
approve_job() { # id mode
  local id="$1" mode="$2" repo t decision sig tool target reason seen try
  repo="$(st get "$id" repo)"
  t="$(task_target "$id" 2>/dev/null)" || return 0
  ( same_project "$t" "$repo" ) >/dev/null 2>&1 || return 0
  exec 9>"$STATE_DIR/.approve.opencode.lock"
  flock -n 9 || return 0
  approve_eval "$t"
  if [[ "$EV" == none ]]; then st approve-clear "$id"; return 0; fi
  IFS=$'\t' read -r _ decision sig tool target reason <<<"$EV"
  seen="$(st approve-seen "$id")"
  [[ "$sig" != "$seen" ]] || return 0   # this very dialog was already handled or flagged
  if [[ "$decision" == unrecognised ]]; then
    st approve-record "$id" approval_unrecognised opencode "$tool" "$target" "$reason" "$sig"
    approve_say "UNRECOGNISED $id: $reason: $target"
    return 0
  fi
  if [[ "$decision" != allow ]]; then
    st approve-record "$id" approval_refused opencode "$tool" "$target" "$reason" "$sig"
    approve_say "REFUSE $id: $reason [$tool: $target]"
    return 0
  fi
  if [[ "$mode" == dry ]]; then
    st approve-record "$id" would_approve opencode "$tool" "$target" "$reason" "$sig"
    approve_say "ALLOW (dry: nothing typed) $id: $reason [$tool: $target]"
    return 0
  fi
  for try in 1 2; do
    send_enter "$t"
    bsleep "${APPROVE_WAIT_S:-1}"
    approve_eval "$t"
    if [[ "$EV" == none || "$(cut -f3 <<<"$EV")" != "$sig" ]]; then
      st approve-record "$id" auto_approved opencode "$tool" "$target" "$reason" "$sig"
      approve_say "ALLOW $id: $reason [$tool: $target]"
      return 0
    fi
  done
  st approve-record "$id" approval_failed opencode "$tool" "$target" "the dialog did not close after 2 tries" "$sig"
  approve_say "FAILED $id: the dialog did not close after 2 tries [$tool: $target]"
}

# For every opencode job in sent|working whose pane is in the same project.
approve_pass() {
  local mode id agent
  mode="$(approve_mode)"
  [[ "$mode" != off ]] || return 0
  while IFS=$'\t' read -r id agent; do
    [[ "$agent" == opencode ]] || continue
    ( approve_job "$id" "$mode" ) || true
  done < <(st list-active)
}

cmd_approve_once() { APPROVE_SAY=1 approve_pass; }

cmd_approve() {
  local sub="${1:-}"
  case "$sub" in
    on | off) echo "$sub" >"$BRIDGE/approver.mode"; echo "auto-approver: $sub" ;;
    dry | dry-run) echo dry >"$BRIDGE/approver.mode"; echo "auto-approver: dry" ;;
    status)
      if [[ "${2:-}" == --json ]]; then
        "$PY" -c 'import json,sys;print(json.dumps({"mode":sys.argv[1],"policy":sys.argv[2]}))' "$(approve_mode)" "$(approver_policy)"
      else
        echo "mode: $(approve_mode)"
        echo "policy: $(approver_policy)"
      fi ;;
    test)
      shift
      "$PY" -I "$BRIDGE_LIB/approver.py" decide --cwd "${APPROVER_CWD:-$PWD}" --policy "$(approver_policy)" "$@" ;;
    *) echo 'usage: bridge.sh approve on|off|dry|status [--json] | test "<tool>|<target>"' >&2; return 2 ;;
  esac
}

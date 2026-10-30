# shellcheck shell=bash
# Bridge commands. Requires state.sh and herdr.sh.

die() { echo "$*" >&2; exit 1; }

msg_for() {
  echo "[bridge $1] Lee y ejecuta las instrucciones de $BRIDGE/inbox/$1.md. Al terminar (o si te bloqueas) escribe tu reporte final en $BRIDGE/outbox/$1.md; ese archivo es la señal de fin para Claude Code. Mantén tu lista de TODO visible (herramienta todowrite): crea al empezar una tarea por unidad de trabajo, marca la actual como in_progress y las terminadas como completed a medida que avanzas."
}

# True when the repo has uncommitted changes to tracked files.
dirty() { [[ -n "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" ]]; }

# Write state + legacy .sent, then send the prompt. Does not wait for confirmation.
deliver() {
  local id="$1" agent="$2" repo="$3" t="${4:-}" base title
  [[ -n "$t" ]] || t="$(target_of "$agent" "$repo")"
  same_project "$t" "$repo"
  base="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  title="$(st task-title "$id")"
  st mark-sent "$id" "$agent" "$repo" "$base" "$title"
  st set "$id" "pane=$t"
  own_task "$t" "$id"
  echo "$agent $(now)" >"$BRIDGE/inbox/$id.sent"   # read by the Claude Code mod (agent, sent at)
  submit "$t" "$(msg_for "$id")"
  echo "sent $id to $agent ($(mux) $t)"
}

# One locked, idempotent evaluation of a task (delivery, completion, stall...).
tick_task() {
  local id="$1"
  (
    flock -w 30 9 || exit 1
    local agent ast act pane
    agent="$(st get "$id" agent)"
    pane="$(st get "$id" pane 2>/dev/null || true)"; [[ "$pane" != null ]] || pane=""   # one agent of the kind per task
    ast="$(agent_status "$agent" "$(st get "$id" repo)" "$pane")"
    act="$(st tick "$id" "$ast")"
    if [[ "$act" == reprompt ]]; then submit "$(task_target "$id")" "$(msg_for "$id")"; fi
    if [[ "$act" != none ]]; then echo "$id: $act"; fi
  ) 9>"$STATE_DIR/.$id.tick.lock"
}

# Wait until a freshly sent task is picked up (working) or declared undelivered.
confirm_delivery() {
  local id="$1" s
  while :; do
    tick_task "$id" || true
    s="$(st get "$id" state)"
    [[ "$s" == sent ]] || break
    bsleep "${CONFIRM_POLL_S:-2}"
  done
  if [[ "$s" == undelivered ]]; then
    echo "undelivered: $id was not picked up by $(st get "$id" agent) after $(st get "$id" deliver_tries) prompt(s)" >&2
    return 6
  fi
  return 0
}

cmd_new() {
  local id="" repo="$PWD" title=""
  while (($#)); do
    case "$1" in
      --repo) repo="${2:?--repo needs a path}"; shift 2 ;;
      --title) title="${2:?--title needs text}"; shift 2 ;;
      -*) die "unknown flag $1" ;;
      *) id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || die "usage: bridge.sh new <id> [--repo R] [--title T]"
  st check-id "$id"
  [[ ! -e "$BRIDGE/inbox/$id.md" ]] || die "inbox/$id.md already exists"
  local tpl="$TEMPLATES/task.md"
  [[ -f "$tpl" ]] || die "missing template $tpl"
  st render "$tpl" "$id" "${title:-TODO-replace-title}" "$repo" >"$BRIDGE/inbox/$id.md"
  echo "created $BRIDGE/inbox/$id.md"
}

cmd_lint() { st lint "${1:?usage: bridge.sh lint <id>}"; }

cmd_send() {
  local force=0 dry=0 queue=0 confirm=1 parallel=0 args=()
  while (($#)); do
    case "$1" in
      --force) force=1 ;;
      --dry-run) dry=1 ;;
      --queue) queue=1 ;;
      --parallel) parallel=1 ;;
      --no-confirm) confirm=0 ;;
      --*) echo "unknown flag $1" >&2; return 2 ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  local agent="${args[0]:-}" id="${args[1]:-}" repo="${args[2]:-}"
  [[ -n "$agent" && -n "$id" ]] || { echo "usage: bridge.sh send <agent> <id> [repo] [--force] [--dry-run] [--queue] [--parallel]" >&2; return 2; }
  st check-id "$id"
  local task="$BRIDGE/inbox/$id.md"
  [[ -f "$task" ]] || { echo "missing $task" >&2; return 1; }
  if [[ -z "$repo" ]]; then repo="$(st task-repo "$id")"; fi
  : "${repo:=$PWD}"
  if ((!force)); then st lint "$id" >/dev/null || { st lint "$id" >&2 || true; return 5; }; fi
  reap_owned   # a finished agent the bridge opened is closed first: a new task never reuses a dirty context
  local t="" need_open=0 sel src=0
  sel="$(select_pane "$agent" "$repo" "$parallel" "$id")" || src=$?
  if ((src == 3 && queue)); then   # the cap of bridge-opened agents: queue it
    if ((dry)); then echo "dry-run: would queue $id for $agent (agent limit reached)"; return 0; fi
    st enqueue "$id" "$agent" "$repo" "$(st task-title "$id")" "$force"
    echo "queued $id for $agent (agent limit reached)"
    return 0
  fi
  ((src == 0)) || return "$src"
  if [[ "$sel" == open ]]; then need_open=1; else t="${sel#pane }"; same_project "$t" "$repo"; fi
  if st exists "$id"; then
    local cur
    cur="$(st get "$id" state)"
    case "$cur" in
      queued | sent | working | stalled) echo "task $id is already $cur (use resend or cancel)" >&2; return 3 ;;
    esac
  fi
  local busy=""
  if ((!need_open)); then   # nothing is busy when the agent is not open
    busy="$(st agent-busy "$agent" "$repo" "$t")"
    if [[ -z "$busy" && "$(agent_status "$agent" "$repo" "$t")" == working ]]; then busy="the agent is working"; fi
  fi
  if [[ -n "$busy" ]]; then
    if ((queue)); then
      if ((dry)); then echo "dry-run: would queue $id for $agent (busy: $busy)"; return 0; fi
      st enqueue "$id" "$agent" "$repo" "$(st task-title "$id")" "$force"
      echo "queued $id for $agent (busy: $busy)"
      return 0
    fi
    echo "agent $agent is busy ($busy); use --queue to queue $id" >&2
    return 3
  fi
  if ((!force && !parallel)) && dirty "$repo"; then   # --parallel in a busy worktree always meets its dirty tree
    echo "$repo has uncommitted changes; commit them or use --force" >&2
    return 4
  fi
  if ((dry)); then
    if ((need_open)); then echo "dry-run: would open a new $agent workspace for $repo"; else echo "dry-run: would send $id to $agent ($t) in $repo"; fi
    return 0
  fi
  if ((need_open)); then t="$(open_agent "$agent" "$repo")"; same_project "$t" "$repo"; fi
  deliver "$id" "$agent" "$repo" "$t"
  watcher_start
  if ((confirm)); then confirm_delivery "$id"; fi
}

cmd_resend() {
  local id="${1:?usage: bridge.sh resend <id>}"
  st exists "$id" || die "no state for $id"
  local cur agent repo busy
  cur="$(st get "$id" state)"
  case "$cur" in
    undelivered | stalled | failed | cancelled) ;;
    *) die "cannot resend $id: it is $cur (only undelivered, stalled, failed or cancelled tasks)" ;;
  esac
  agent="$(st get "$id" agent)"
  repo="$(st get "$id" repo)"
  reap_owned
  local sel t
  sel="$(select_pane "$agent" "$repo" 0 "$id")" || return $?
  if [[ "$sel" == open ]]; then t="$(open_agent "$agent" "$repo")"; else t="${sel#pane }"; fi
  busy="$(st agent-busy "$agent" "$repo" "$t")"
  if [[ -n "$busy" && "$busy" != "$id" ]]; then echo "agent $agent is busy with $busy" >&2; return 3; fi
  if [[ "$(agent_status "$agent" "$repo" "$t")" == working ]]; then echo "agent $agent is working" >&2; return 3; fi
  deliver "$id" "$agent" "$repo" "$t"
  watcher_start
  confirm_delivery "$id"
}

cmd_cancel() {
  local id="${1:?usage: bridge.sh cancel <id>}"
  st exists "$id" || die "no state for $id"
  local cur agent
  cur="$(st get "$id" state)"
  case "$cur" in
    queued) ;;
    sent | working | stalled)
      agent="$(st get "$id" agent)"
      send_esc "$agent" "$(st get "$id" repo)" || echo "warning: could not reach $agent to send Esc" >&2 ;;
    *) die "cannot cancel $id: it is already $cur" ;;
  esac
  st transition "$id" cancelled "cancelled by user"
  reap_owned
  echo "cancelled $id"
}

# Start the oldest queued task of every agent that is free. Serialised by a lock so two tickers never double-send.
start_queued() {
  (
    flock -n 9 || exit 0
    local id agent repo force ast
    reap_owned
    while IFS=$'\t' read -r id agent repo force; do
      [[ -n "$id" ]] || continue
      (
        local sel pane=""
        sel="$(select_pane "$agent" "$repo" 0 "$id" 2>/dev/null)" || exit 0   # no agent can take it yet (cap, no pane)
        if [[ "$sel" != open ]]; then
          pane="${sel#pane }"
          ast="$(agent_status "$agent" "$repo" "$pane")"
          if [[ "$ast" == missing || "$ast" == working ]]; then exit 0; fi
        fi
        if [[ "$force" != 1 ]] && dirty "$repo"; then
          if [[ "$(st get "$id" note)" != *dirty* ]]; then
            st set "$id" "note=waiting: uncommitted changes (dirty working tree) in $repo"
            st log "$id" blocked '{"reason":"dirty working tree"}'
          fi
          exit 0
        fi
        if [[ "$sel" == open ]]; then pane="$(open_agent "$agent" "$repo")" || exit 0; fi   # a new workspace
        deliver "$id" "$agent" "$repo" "$pane" >/dev/null
        echo "$id: started from queue"
        tick_task "$id" >/dev/null || true   # picks up an immediate start; later ticks confirm or retry
      ) || true
    done < <(st next-queued)
  ) 9>"$STATE_DIR/.queue.lock"
}

# One idempotent pass over every open task, then start queued work.
cmd_tick() {
  local id agent
  while IFS=$'\t' read -r id agent; do
    [[ -n "$id" ]] || continue
    tick_task "$id" || true
  done < <(st list-open)
  reap_owned
  start_queued
  approve_pass || true
  guard_pass || true
}

# Memory guard. A runaway test run once grew a node process to 4.8 GB and the kernel killed the user's desktop, so
# on every tick any process working inside the repository of an open task (any worktree of it) that holds more than
# BRIDGE_MAX_CHILD_MB (default 2048, 0 disables) is stopped: SIGTERM, then SIGKILL, and logged as mem_guard_kill.
# The agents and the terminal themselves are never touched.
guard_pass() {
  local limit="${BRIDGE_MAX_CHILD_MB:-2048}" id agent repo rid pid rss comm cwd kb
  ((limit > 0)) || return 0
  local -A ids=() owner=()
  while IFS=$'\t' read -r id agent; do
    [[ -n "$id" ]] || continue
    repo="$(st get "$id" repo)"
    [[ -n "$repo" ]] || continue
    rid="$(repo_id "$repo")"
    [[ -n "$rid" ]] || continue
    ids["$rid"]=1
    owner["$rid"]="$id"
  done < <(st list-open)
  ((${#ids[@]} > 0)) || return 0
  kb=$((limit * 1024))
  while read -r pid rss comm; do
    ((rss > kb)) || continue
    case "$comm" in opencode | claude | herdr | ghostty | docker | dockerd | containerd | containerd-shim*) continue ;; esac
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ -n "$cwd" ]] || continue
    rid="$(repo_id "$cwd")"
    [[ -n "$rid" && -n "${ids[$rid]:-}" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.3
    kill -KILL "$pid" 2>/dev/null || true
    printf '{"ts": %s, "id": "%s", "event": "mem_guard_kill", "data": {"pid": %s, "comm": "%s", "rss_mb": %s, "limit_mb": %s, "cwd": "%s"}}\n' \
      "$(now)" "${owner[$rid]}" "$pid" "$comm" "$((rss / 1024))" "$limit" "$cwd" >>"$BRIDGE/log.jsonl"
    echo "mem guard: stopped $comm (pid $pid, $((rss / 1024)) MB > ${limit} MB) in $cwd" >&2
  done < <(ps -eo pid=,rss=,comm=)
}

cmd_watch() {
  local every=5 idle=0 i=0 max="${BRIDGE_WATCH_MAX:-0}" quiet_since=""
  while (($#)); do
    case "$1" in
      --until-idle) idle="${2:?--until-idle needs seconds}"; shift 2 ;;
      *) every="$1"; shift ;;
    esac
  done
  while :; do
    cmd_tick || true
    i=$((i + 1))
    if ((max > 0 && i >= max)); then break; fi
    if ((idle > 0)); then
      # Stops by itself once no task has been open for `idle` seconds.
      if [[ -z "$(st list-open)" ]]; then
        [[ -n "$quiet_since" ]] || quiet_since="$(now)"
        # A finished task whose agent is still writing keeps the watcher alive (up to BRIDGE_REAP_WAIT_S, 300) so the
        # workspace the bridge opened for it is still closed.
        if (($(now) - quiet_since >= idle)) && { ! has_owned || (($(now) - quiet_since >= ${BRIDGE_REAP_WAIT_S:-300})); }; then break; fi
      else
        quiet_since=""
      fi
    fi
    bsleep "$every"
  done
}

# The background watcher: ticks every few seconds, which is what answers the permission dialogs the policy allows
# (and confirms deliveries). `send` and `resend` start it, so the orchestrator never has to remember to.
watcher_pid() {
  local p
  [[ -f "$BRIDGE/watch.pid" ]] || return 1
  p="$(<"$BRIDGE/watch.pid")"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && echo "$p"
}

watcher_start() {
  [[ "${BRIDGE_NO_WATCHER:-}" == 1 ]] && return 0
  watcher_pid >/dev/null && return 0
  setsid nohup "$SELF" watch "${WATCH_EVERY_S:-4}" --until-idle "${WATCH_IDLE_S:-120}" >>"$BRIDGE/watch.log" 2>&1 </dev/null &
  echo $! >"$BRIDGE/watch.pid"
}

cmd_watcher() {
  local p
  case "${1:-status}" in
    start) BRIDGE_NO_WATCHER=0 watcher_start; if p="$(watcher_pid)"; then echo "watcher running (pid $p)"; else echo "watcher not started" >&2; return 1; fi ;;
    status) if p="$(watcher_pid)"; then echo "watcher running (pid $p)"; else echo "watcher not running"; return 1; fi ;;
    stop) if p="$(watcher_pid)"; then kill "$p" 2>/dev/null || true; rm -f "$BRIDGE/watch.pid"; echo "watcher stopped"; else echo "watcher not running"; fi ;;
    *) die "usage: bridge.sh watcher start|status|stop" ;;
  esac
}

cmd_progress() {
  [[ $# -ge 3 ]] || die 'usage: bridge.sh progress <id> <done> <total> "<text>"'
  st exists "$1" || die "no state for $1"
  st progress "$@"
}

cmd_stage() {
  [[ $# -ge 2 ]] || die "usage: bridge.sh stage <id> verified|reviewed|recorded|merged [note]"
  st exists "$1" || die "no state for $1"
  st stage "$@"
}

cmd_wait() {
  local id="" timeout=0
  while (($#)); do
    case "$1" in
      --timeout) timeout="${2:?--timeout needs seconds}"; shift 2 ;;
      -*) die "unknown flag $1" ;;
      *) id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || die "usage: bridge.sh wait <id> [--timeout S]"
  st check-id "$id"
  local start s
  start="$(now)"
  while :; do
    if st exists "$id"; then
      cmd_tick >/dev/null 2>&1 || true   # keeps the state fresh even if nothing else is ticking
      s="$(st get "$id" state)"
      case "$s" in
        done) bsleep 2; cat "$BRIDGE/outbox/$id.md" 2>/dev/null; return 0 ;;
        failed) cat "$BRIDGE/outbox/$id.md" 2>/dev/null || true; echo "task $id failed: $(st get "$id" note)" >&2; return 1 ;;
        cancelled) echo "task $id was cancelled" >&2; return 3 ;;
        undelivered) echo "task $id was undelivered: the agent never started it" >&2; return 4 ;;
      esac
    elif [[ -s "$BRIDGE/outbox/$id.md" ]]; then
      bsleep 2
      cat "$BRIDGE/outbox/$id.md"
      return 0
    fi
    if ((timeout > 0 && $(now) - start >= timeout)); then echo "timeout waiting for $id" >&2; return 124; fi
    bsleep "${POLL_S:-10}"
  done
}

cmd_ls() { st ls "$@"; }
cmd_stats() { st stats "$@"; }
cmd_eta() { [[ $# -ge 1 ]] || die "usage: bridge.sh eta <id> [--json]"; st eta "$@"; }
cmd_clean() { st clean "$@"; }

cmd_status() {
  [[ $# -ge 1 ]] || die "usage: bridge.sh status <id>"
  st get "$1" | "$PY" -m json.tool
}

cmd_show() {
  [[ $# -ge 1 ]] || die "usage: bridge.sh show <id>"
  cmd_status "$1"
  echo "--- pane of $(st get "$1" agent) ---"
  read_pane "$(task_target "$1")" "${2:-15}" || echo "(agent pane not reachable)"
}

cmd_doctor() {
  local rc=0 d a id agent ast
  ok() { echo "ok: $*"; }
  warn() { echo "WARN: $*"; }
  err() { echo "ERROR: $*"; rc=1; }
  local have_py=1
  if command -v "$PY" >/dev/null 2>&1; then ok "python3 ($(command -v "$PY"))"; else err "python3 not found (set BRIDGE_PYTHON or install it)"; have_py=0; fi
  local have_mux=1
  if [[ "${BRIDGE_MUX:-}" == tmux ]]; then
    if command -v tmux >/dev/null 2>&1; then ok "tmux"; else err "tmux not found"; have_mux=0; fi
  elif command -v "$HERDR" >/dev/null 2>&1; then ok "herdr ($(command -v "$HERDR"))"
  else err "herdr not found (set BRIDGE_HERDR or use BRIDGE_MUX=tmux)"; have_mux=0
  fi
  for d in inbox outbox state; do
    if [[ -d "$BRIDGE/$d" && -w "$BRIDGE/$d" ]]; then ok "directory $d"; else err "directory not writable: $BRIDGE/$d"; fi
  done
  if ((have_mux)); then
    for a in gentle opencode; do
      ast="$(agent_status "$a")"
      if [[ "$ast" != missing ]]; then ok "agent $a ($ast)"
      elif [[ -n "$(panes_of_kind "$a")" ]]; then ok "agent $a (open, but not in the repository of the current directory)"
      else warn "agent $a not found (open it in the project it will work on)"; fi
    done
  fi
  if ((have_py && have_mux)); then
    while IFS=$'\t' read -r id agent; do
      [[ -n "$id" ]] || continue
      if [[ "$(agent_status "$agent" "$(st get "$id" repo)")" == missing ]]; then warn "orphan task $id: its agent '$agent' is gone but the task is still open"; fi
    done < <(st list-open)
  fi
  return "$rc"
}

# Import legacy inbox/<id>.sent + outbox/<id>.md pairs into state/ (read-only on inbox/outbox).
cmd_migrate() { st migrate; }

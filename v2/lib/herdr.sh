# shellcheck shell=bash
# Multiplexer access (herdr by default, tmux with BRIDGE_MUX=tmux). Needs: BRIDGE, PY (state.sh).
HERDR="${BRIDGE_HERDR:-herdr}"

mux() {
  if [[ -n "${BRIDGE_MUX:-}" ]]; then echo "$BRIDGE_MUX"
  elif command -v "$HERDR" >/dev/null 2>&1; then echo herdr   # herdr is the default; force tmux with BRIDGE_MUX=tmux
  elif [[ -n "${TMUX:-}" ]]; then echo tmux
  else echo "neither herdr nor tmux found" >&2; exit 1
  fi
}

# Kind of agent as the multiplexer reports it (gentle is pi).
agent_kind() { case "$1" in gentle) echo pi ;; *) echo "$1" ;; esac; }

# Candidate panes of an agent: "pane<TAB>cwd" lines. Panes are never identified by a global name, only by kind + directory.
panes_of_kind() { # agent
  local kind
  kind="$(agent_kind "$1")"
  case "$(mux)" in
    tmux)
      tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}	#{pane_current_path}	#{pane_current_command}	#{pane_title}' |
        awk -F'\t' -v a="$1" '
          a == "gentle"   && $4 ~ /^π/       { print $1 "\t" $2 }
          a == "opencode" && $3 ~ /opencode/ { print $1 "\t" $2 }' ;;
    herdr)
      "$HERDR" agent list 2>/dev/null | "$PY" -c '
import json,sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("agent")==sys.argv[1]:
        print(a["pane_id"] + "\t" + (a.get("cwd") or ""))' "$kind" 2>/dev/null || true ;;
  esac
}

# The pane of <agent> that works on <repo> (default: the repository of the current directory): the same git
# repository, preferring the very same worktree. Never another project's pane.
target_of() { # agent [repo]
  local agent="$1" repo="${2-$PWD}" want top pane cwd got best="" exact="" line
  if [[ -z "$repo" ]]; then
    # A task with no recorded repository (imported from the old inbox/outbox): the only pane of that kind, if unique.
    local only
    only="$(panes_of_kind "$agent" | cut -f1)"
    if [[ -n "$only" && "$(wc -l <<<"$only")" == 1 ]]; then echo "$only"; return 0; fi
    echo "the task has no repository and $agent is not open exactly once; cannot choose its pane" >&2
    exit 1
  fi
  want="$(repo_id "$repo")"
  if [[ -z "$want" ]]; then
    echo "$repo is not a git repository; cannot choose the $agent pane for it." >&2
    echo "run 'git init' there, or give the git repository the task is for ('send <agent> <id> <repo>'; 'new <id> --repo <repo>')" >&2
    exit 1
  fi
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
  local others=()
  while IFS=$'\t' read -r pane cwd; do
    [[ -n "$pane" ]] || continue
    got=""
    [[ -z "$cwd" ]] || got="$(repo_id "$cwd")"
    if [[ -n "$got" && "$got" == "$want" ]]; then
      [[ -n "$best" ]] || best="$pane"
      if [[ -z "$exact" && "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" == "$top" ]]; then exact="$pane"; fi
    else
      others+=("'$cwd'")
    fi
  done < <(panes_of_kind "$agent")
  if [[ -n "${exact:-$best}" ]]; then echo "${exact:-$best}"; return 0; fi
  if ((${#others[@]})); then
    echo "no $agent pane is open in '$top' (the task is for $repo); $agent is open in ${others[*]}: refusing to use another project's pane." >&2
  else
    echo "no $agent pane is open (the task is for $repo)." >&2
  fi
  echo "open $agent in $repo (herdr pane split --current --direction right --cwd $repo) or pass the right repo ('send <agent> <id> <repo>')" >&2
  exit 1
}

# The pane of a task: the one recorded at delivery while it still sits in the task's repository, else the one of its repo.
task_target() { # id
  local id="$1" pane repo agent cwd
  repo="$(st get "$id" repo 2>/dev/null || true)"
  agent="$(st get "$id" agent 2>/dev/null || true)"
  pane="$(st get "$id" pane 2>/dev/null || true)"
  if [[ -n "$pane" && "$pane" != null && "$(mux)" == herdr ]]; then
    cwd="$(pane_path "$pane")"
    if [[ -n "$cwd" && "$(repo_id "$cwd")" == "$(repo_id "$repo")" ]]; then echo "$pane"; return 0; fi
  fi
  target_of "$agent" "$repo"
}

read_pane() {
  local t="$1" n="$2"
  case "$(mux)" in
    tmux) tmux capture-pane -p -t "$t" ;;
    herdr) "$HERDR" agent read "$t" --source recent-unwrapped --lines "$n" ;;
  esac | { grep -v '^[[:space:]]*$' || true; } | tail -n "$n"
}

pane_path() {
  local t="$1"
  case "$(mux)" in
    tmux) tmux display -p -t "$t" '#{pane_current_path}' ;;
    herdr) "$HERDR" agent get "$t" 2>/dev/null |
      "$PY" -c 'import json,sys;print(json.load(sys.stdin)["result"]["agent"].get("cwd",""))' 2>/dev/null || true ;;
  esac
}

repo_id() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true; }

# The agent must be open in the same project (same git repository; any of its worktrees).
same_project() {
  local t="$1" repo="$2" path want got
  want="$(repo_id "$repo")"
  [[ -n "$want" ]] || {
    echo "$repo is not a git repository; refusing to send." >&2
    echo "run 'git init' there, or give the git repository the task is for ('send <agent> <id> <repo>'; 'new <id> --repo <repo>')" >&2
    exit 1; }
  path="$(pane_path "$t")"
  [[ -n "$path" ]] || { echo "cannot read the agent's directory; refusing to send" >&2; exit 1; }
  got="$(repo_id "$path")"
  [[ "$got" == "$want" ]] || {
    local there
    there="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$there" ]]; then
      echo "the agent is open in '$path' (repo $there), but the task is for $repo: refusing to send." >&2
    else
      echo "the agent is open in '$path' (not a git repository), but the task is for $repo: refusing to send." >&2
    fi
    echo "open the agent in $repo (herdr pane split --current --direction right --cwd $repo) or give the right repo: 'send <agent> <id> <repo>' (a task made with 'new <id> --repo <repo>' already carries it)" >&2
    exit 1; }
}

submit() {
  local t="$1" msg="$2"
  case "$(mux)" in
    tmux)
      tmux send-keys -t "$t" -l "$msg"
      sleep 0.5
      tmux send-keys -t "$t" Enter
      ;;
    herdr) "$HERDR" agent prompt "$t" "$msg" >/dev/null ;;
  esac
}

# Status of an agent: idle|working|blocked|done|unknown|missing (tmux cannot tell: unknown).
agent_status() { # agent [repo [pane]]
  case "$(mux)" in
    herdr)
      local out st t="${3:-}"
      [[ -n "$t" ]] || t="$(target_of "$1" "${2-$PWD}" 2>/dev/null)" || { echo missing; return 0; }
      out="$("$HERDR" agent get "$t" 2>/dev/null)" || { echo missing; return 0; }
      st="$(printf '%s' "$out" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["result"]["agent"].get("agent_status","unknown"))' 2>/dev/null || echo unknown)"
      # opencode frees its turn on purpose while background sub-agents work (bg-agents plugin): that is still work.
      if [[ "$1" == opencode && "$st" == idle ]] && oc_children_running; then st=working; fi
      echo "$st" ;;
    *) echo unknown ;;
  esac
}

# True when the bg-agents registry lists a running child that showed activity in the last 15 minutes.
oc_children_running() {
  local reg="${OC_BG_REGISTRY:-$HOME/.local/state/opencode-bg/registry.json}"
  [[ -f "$reg" ]] || return 1
  "$PY" - "$reg" "$(now)" <<'PY' 2>/dev/null
import json, sys
reg, now = sys.argv[1], int(sys.argv[2])
data = json.load(open(reg))
kids = data.get("children", data) if isinstance(data, dict) else data
for c in kids if isinstance(kids, list) else []:
    last = (c.get("lastActivity") or c.get("started") or 0) / 1000
    if c.get("state") == "running" and now - last <= 900:
        sys.exit(0)
sys.exit(1)
PY
}

# Send Escape to the agent (interrupts its current turn).
send_esc() { # agent [repo]
  local t
  t="$(target_of "$1" "${2-$PWD}")" || return 1
  case "$(mux)" in
    tmux) tmux send-keys -t "$t" Escape ;;
    herdr) "$HERDR" agent send-keys "$t" esc >/dev/null ;;
  esac
}

# Press Enter in the agent pane (the only key the auto-approver ever sends).
send_enter() {
  case "$(mux)" in
    tmux) tmux send-keys -t "$1" Enter ;;
    herdr) "$HERDR" agent send-keys "$1" enter >/dev/null ;;
  esac
}

# --- agents the bridge opens itself (herdr only) ------------------------------------------------------------------
# When no pane of the agent is open in the task's repository, `send` and the queue starter open one in a NEW herdr
# workspace (never a split) and close that workspace again once its task has ended, so each task starts with a clean
# context. Panes are recorded in state/owned/<pane>; an agent the user opened is never in there, hence never closed.
OWNED_DIR="$STATE_DIR/owned"

owned_file() { echo "$OWNED_DIR/${1//:/_}"; }

# Value of <key> in an owned file (empty when absent).
owned_get() { # file key
  [[ -f "$1" ]] || return 0
  { rg -m1 "^$2=" "$1" || true; } | sd "^$2=" ''
}

# Set <key> in an owned file (replaces the previous value).
owned_set() { # file key value
  local f="$1" tmp
  tmp="$(mktemp "$f.XXXXXX")"
  { { rg -v "^$2=" "$f" || true; }; echo "$2=$3"; } >"$tmp"
  mv "$tmp" "$f"
}

# True when <pane> is an agent the bridge opened and its task has already ended (it only waits to be closed).
owned_ended() { # pane
  local f id s
  f="$(owned_file "$1")"
  [[ -f "$f" ]] || return 1
  id="$(owned_get "$f" task)"
  [[ -n "$id" ]] || return 1
  st exists "$id" || return 0
  s="$(st get "$id" state)"
  case "$s" in done | failed | cancelled | undelivered) return 0 ;; *) return 1 ;; esac
}

# Record that <pane> now carries <id> (only when the bridge opened that pane).
own_task() { # pane id
  local f
  f="$(owned_file "$1")"
  [[ -f "$f" ]] || return 0
  owned_set "$f" task "$2"
}

auto_open_enabled() { [[ "$(mux)" == herdr && "${BRIDGE_AUTO_OPEN:-1}" != 0 ]]; }

# "pane<TAB>cwd" of every pane of <agent> that works in the project of <repo> (any of its worktrees).
candidates_of() { # agent repo
  local want pane cwd
  want="$(repo_id "$2")"
  while IFS=$'\t' read -r pane cwd; do
    [[ -n "$pane" && -n "$cwd" && "$(repo_id "$cwd")" == "$want" ]] && printf '%s\t%s\n' "$pane" "$cwd"
  done < <(panes_of_kind "$1")
}

# How many agents the bridge opened are alive (files in state/owned).
owned_count() { [[ -d "$OWNED_DIR" ]] && fd -t f . "$OWNED_DIR" 2>/dev/null | wc -l || echo 0; }

# Which agent takes a task for <repo>. Prints "pane <id>" (reuse it) or "open" (open a new workspace); returns 3 with a
# message when the global cap blocks the opening, 7 when --parallel is refused for overlapping surfaces, and 1 with the
# usual target_of error when no pane can be chosen (auto-open off, tmux, other agents or a repo that is not git).
#   1. a FREE pane of the project (idle and not reserved by an open task) is reused, preferring the same worktree;
#   2. none free: a separate worktree opens another agent; the same worktree does not (one writer per worktree: the
#      busy pane is returned so send reports it busy or queues), unless <parallel> is 1 and the surfaces are disjoint;
#   3. at most BRIDGE_MAX_AGENTS (3) agents opened by the bridge exist at once.
select_pane() { # agent repo [parallel] [task-id]
  local agent="$1" repo="$2" parallel="${3:-0}" id="${4:-}" top pane cwd free="" exact="" first="" st_ conflict=0 b
  if ! auto_open_enabled || [[ "$agent" != gentle && "$agent" != opencode ]] || [[ -z "$repo" || -z "$(repo_id "$repo")" ]]; then
    pane="$(target_of "$agent" "$repo")" || return 1
    echo "pane $pane"; return 0
  fi
  top="$(git -C "$repo" rev-parse --show-toplevel)"; top="$(realpath "$top")"
  while IFS=$'\t' read -r pane cwd; do
    [[ -n "$pane" ]] || continue
    owned_ended "$pane" && continue   # a finished agent the bridge opened only waits to be closed: never reuse its context
    [[ -n "$first" ]] || first="$pane"
    st_="$(agent_status "$agent" "$repo" "$pane")"
    if [[ "$st_" == idle && -z "$(st agent-busy "$agent" "$repo" "$pane")" ]]; then
      [[ -n "$free" ]] || free="$pane"
      [[ -n "$exact" || "$(realpath "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")")" != "$top" ]] || exact="$pane"
    elif [[ "$(realpath "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")")" == "$top" ]]; then
      conflict=1   # a busy agent already works in this very worktree
      [[ -n "$exact" ]] || first="$pane"
    fi
  done < <(candidates_of "$agent" "$repo")
  if [[ -n "${exact:-$free}" ]]; then echo "pane ${exact:-$free}"; return 0; fi
  while IFS= read -r b; do [[ "$b" != "$top" ]] || conflict=1; done < <(st busy-worktrees "$agent" "$repo")
  if ((conflict)); then
    if ((!parallel)) && [[ -n "$first" ]]; then echo "pane $first"; return 0; fi   # same worktree: send reports it busy or queues
    if ((parallel)) && [[ -n "$id" ]] && ! b="$(st overlap "$id" "$repo")"; then
      echo "refusing --parallel: the allowed edit surfaces of $id overlap those of a task already working in $top:" >&2
      echo "$b" >&2
      return 7
    fi
  fi
  if (($(owned_count) >= ${BRIDGE_MAX_AGENTS:-3})); then
    echo "$(owned_count) agent(s) opened by the bridge are already alive (limit BRIDGE_MAX_AGENTS=${BRIDGE_MAX_AGENTS:-3}; each uses roughly 0.3 to 0.7 GB)" >&2
    return 3
  fi
  echo open
}

# Wait until the agent of kind <kind> in <pane> is idle.
wait_agent_idle() { # kind pane
  local deadline
  deadline=$(($(now) + ${BRIDGE_OPEN_TIMEOUT_S:-90}))
  while :; do
    "$HERDR" agent list 2>/dev/null | "$PY" -c '
import json,sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("agent")==sys.argv[1] and a.get("pane_id")==sys.argv[2] and a.get("agent_status")=="idle":
        sys.exit(0)
sys.exit(1)' "$1" "$2" 2>/dev/null && return 0
    (($(now) < deadline)) || return 1
    bsleep 2
  done
}

# Open <agent> in a new herdr workspace rooted at the top of <repo>; print its pane id once it is idle.
open_agent() { # agent repo
  local agent="$1" repo="$2" top cmd out pane ws kind f
  top="$(git -C "$repo" rev-parse --show-toplevel)"
  case "$agent" in
    gentle) cmd="${BRIDGE_GENTLE_CMD:-gentle-shell}" ;;
    *) cmd="${BRIDGE_OPENCODE_CMD:-opencode}" ;;
  esac
  kind="$(agent_kind "$agent")"
  out="$("$HERDR" workspace create --cwd "$top" --label "$agent-$(basename "$top")" --no-focus)" ||
    { echo "could not open a $agent workspace in $top" >&2; return 1; }
  pane="$(printf '%s' "$out" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])' 2>/dev/null || true)"
  ws="$(printf '%s' "$out" | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["result"]["root_pane"]["workspace_id"])' 2>/dev/null || true)"
  [[ -n "$pane" && -n "$ws" ]] || { echo "herdr did not report the pane of the new $agent workspace" >&2; return 1; }
  mkdir -p "$OWNED_DIR"
  f="$(owned_file "$pane")"
  printf 'pane=%s\nworkspace=%s\nagent=%s\nrepo=%s\nopened=%s\n' "$pane" "$ws" "$agent" "$top" "$(now)" >"$f"
  if ! "$HERDR" pane run "$pane" "$cmd" >/dev/null 2>&1 || ! wait_agent_idle "$kind" "$pane"; then
    "$HERDR" workspace close "$ws" >/dev/null 2>&1 || true
    rm -f "$f"
    echo "$agent did not become idle in the new workspace $ws within ${BRIDGE_OPEN_TIMEOUT_S:-90}s; closed it" >&2
    return 1
  fi
  echo "opened $agent in a new herdr workspace ($ws, pane $pane) for $top" >&2
  echo "$pane"
}

# Close the workspaces the bridge opened whose task has ended and whose agent is no longer working, so the next task
# starts clean. An owned pane that never received a task is closed once it is older than BRIDGE_OWNED_GRACE_S (180, longer than the 90 s opening timeout),
# which only protects a pane that `send` has just opened. Only recorded workspaces are ever closed.
reap_owned() {
  [[ -d "$OWNED_DIR" ]] || return 0
  local f pane ws id s ast opened
  for f in "$OWNED_DIR"/*; do
    [[ -f "$f" ]] || continue
    pane="$(owned_get "$f" pane)"; ws="$(owned_get "$f" workspace)"; id="$(owned_get "$f" task)"
    [[ -n "$pane" && -n "$ws" ]] || { rm -f "$f"; continue; }
    if [[ -z "$id" ]]; then
      opened="$(owned_get "$f" opened)"
      (($(now) - ${opened:-0} >= ${BRIDGE_OWNED_GRACE_S:-180})) || continue
    else
      if st exists "$id"; then s="$(st get "$id" state)"; else s=done; fi
      case "$s" in done | failed | cancelled | undelivered) ;; *) continue ;; esac
      ast="$("$HERDR" agent get "$pane" 2>/dev/null |
        "$PY" -c 'import json,sys;print(json.load(sys.stdin)["result"]["agent"].get("agent_status","unknown"))' 2>/dev/null || echo missing)"
      [[ "$ast" != working ]] || continue
    fi
    # Forget the workspace only once it is really gone: a failed close is retried by the next tick, unless the user
    # already closed it (then herdr no longer lists it and the record would stay forever).
    if "$HERDR" workspace close "$ws" >/dev/null 2>&1 || ! workspace_exists "$ws"; then rm -f "$f"; fi
  done
}

# True when herdr still lists workspace <id>.
workspace_exists() { # id
  "$HERDR" workspace list 2>/dev/null | "$PY" -c '
import json,sys
sys.exit(0 if any(w.get("workspace_id")==sys.argv[1] for w in json.load(sys.stdin)["result"]["workspaces"]) else 1)' "$1" 2>/dev/null
}

# True when some pane the bridge opened is still waiting to be closed.
has_owned() { [[ -d "$OWNED_DIR" ]] && [[ -n "$(fd -t f . "$OWNED_DIR" 2>/dev/null | head -1)" ]]; }

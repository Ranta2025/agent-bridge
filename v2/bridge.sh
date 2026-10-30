#!/usr/bin/env bash
# Local bridge: Claude Code -> an agent TUI (gentle-shell / opencode) in another pane.
# herdr is the default multiplexer (agents are named automatically on first use); tmux with BRIDGE_MUX=tmux.
set -euo pipefail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SELF_DIR="$(dirname "$SELF")"
if [[ -d "$SELF_DIR/lib" ]]; then
  LIB="$SELF_DIR/lib"; DEFAULT_BRIDGE="$(dirname "$SELF_DIR")"   # running from v2/
else
  LIB="$SELF_DIR/v2/lib"; DEFAULT_BRIDGE="$SELF_DIR"             # installed at the bridge root
fi
BRIDGE="${BRIDGE_DIR:-$DEFAULT_BRIDGE}"
export BRIDGE BRIDGE_DIR="$BRIDGE"
TEMPLATES="${BRIDGE_TEMPLATES:-$DEFAULT_BRIDGE/templates}"   # templates ship with the scripts, not with the data dir
mkdir -p "$BRIDGE/inbox" "$BRIDGE/outbox" "$BRIDGE/state"
# shellcheck source=lib/state.sh
source "$LIB/state.sh"
# shellcheck source=lib/herdr.sh
source "$LIB/herdr.sh"
# shellcheck source=lib/cmds.sh
source "$LIB/cmds.sh"
# shellcheck source=lib/approver.sh
source "$LIB/approver.sh"

usage() {
  cat <<'USAGE'
bridge.sh <command> [args]     (bridge.sh help prints the full guide)
  pane <agent> | peek <agent> [lines]
  new <id> [--repo R] [--title T] | lint <id>
  send <agent> <id> [repo] [--force] [--dry-run] [--queue] [--parallel] [--no-confirm]
  resend <id> | cancel <id>
  tick | watch [seconds] | approve on|off|dry|status|test | approve-once
  progress <id> <done> <total> "<text>" | stage <id> verified|reviewed|recorded|merged [note]
  wait <id> [--timeout S]
  ls [--json] | status <id> | show <id> [lines] | stats [--json] | eta <id> [--json]
  clean [--days N] [--dry-run] | migrate | doctor | help
USAGE
}

help_text() {
  cat <<'HELP'
bridge.sh - hand tasks from Claude Code to an agent TUI (gentle | opencode) and follow them.

USAGE
  bridge.sh <command> [args]

TASK FILES
  new <id> [--repo R] [--title T]    create inbox/<id>.md from templates/task.md (R defaults to the cwd)
  lint <id>                          validate it: no TODO-replace left, relative "Allowed edit surfaces",
                                     a Report section, a sub-agents instruction, the outbox report path.
                                     Exit 0 valid, 1 with errors on stderr.

SENDING AND CONTROL
  send <agent> <id> [repo] [flags]   lint, check the repo tree, deliver, confirm the agent started.
        --force       skip lint and the dirty-tree check
        --dry-run     show what would happen and change nothing
        --queue       if the agent is busy, keep the task queued (tick starts it when the agent is free)
        --parallel    same worktree as a busy agent: open another one if the allowed edit surfaces are disjoint
        --no-confirm  send once and return without waiting for the agent to start
        herdr: when no free agent of that kind is open in the repo, one is opened in a NEW workspace and closed when
        its task ends (clean context per task); agents you opened are reused and never closed. A busy agent never
        blocks a separate worktree; the same worktree needs --parallel; BRIDGE_MAX_AGENTS caps the agents opened.
        exit: 0 ok | 1 missing inbox file | 2 bad usage | 3 agent busy, limit reached or task already open
              4 dirty tree | 5 lint failed | 6 undelivered after the retries | 7 --parallel surfaces overlap
  resend <id>                        resend an undelivered, stalled, failed or cancelled task (attempts + 1)
        exit: 0 ok | 1 no state or not resendable | 3 agent busy or limit reached | 6 undelivered again
  cancel <id>                        send Esc to the agent, mark the task cancelled, free the queue (exit 1 if already finished)
  progress <id> <done> <total> "<text>"   called by the delegated agent after each unit of work
  stage <id> verified|reviewed|recorded|merged [note]   called by the orchestrator at each step

FOLLOWING
  tick                               one idempotent pass: confirm deliveries, detect done / failed /
                                     stalled, start queued work
  watch [seconds] [--until-idle S]   tick in a loop (default 5 s); with --until-idle it stops S seconds after the last open task
  watcher start|status|stop          the background watcher `send`/`resend` start for you: it answers the permission dialogs
                                     approver.policy allows, so an agent never waits for a click (BRIDGE_NO_WATCHER=1 disables it;
                                     WATCH_EVERY_S=4 and WATCH_IDLE_S=120 tune it; log in watch.log)
  wait <id> [--timeout S]            block until the task ends and print its report.
        exit: 0 done | 1 failed | 3 cancelled | 4 undelivered | 124 timeout
  ls [--json]                        table (or stable JSON) of every task, newest first
  status <id>                        state JSON of one task
  show <id> [lines]                  state plus the last lines of the agent pane
  peek <agent> [lines]               last lines of the agent pane (default 20)
  pane <agent>                       print the pane of <agent> in the current repo (kind + repository, never another project)
  stats [--json]                     durations, success rate and retries per agent and kind
  eta <id> [--json]                  remaining time from similar finished tasks (or the reported progress)

AUTO-APPROVER (opencode permission dialog, only while a bridge job is active)
  approve on|off|dry                 switch the mode (persisted in approver.mode; default on)
  approve status [--json]            mode and policy file
  approve test "<tool>|<target>"     print the policy decision, no keys: ALLOW / REFUSE <reason> (exit 0 / 1)
  approve test --file <capture>      the same for a saved pane capture (ALLOW | REFUSE | UNRECOGNISED)
  approve-once                       one pass: for each opencode job in sent|working whose pane is in this
                                     project, answer the dialog with Enter ("Allow once") if approver.policy
                                     allows it; otherwise leave it untouched and flag it. tick/watch do this too.
        dry = log would_approve and send nothing | off = do nothing. Never "Always allow". See approver.policy.

MAINTENANCE
  clean [--days N] [--dry-run]       archive finished tasks older than N days (default 7) into archive/
  migrate                            import legacy v1 inbox/outbox items into state/ (read-only on them)
  doctor                             check herdr, python3, directories, named agents and orphan tasks.
                                     Exit 0 fine (WARN allowed), 1 with ERROR.
  help | -h | --help                 this guide

STATES
  queued -> sent -> working -> done | failed
  side states: undelivered (never started), stalled (idle > STALL_S, no report), cancelled
  open = sent, working, stalled (the agent is busy); finished = done, failed, cancelled, undelivered
  done / failed come from outbox/<id>.md: its "Status:" line decides (blocked, partial, failed -> failed).

ENVIRONMENT
  BRIDGE_DIR        data directory (default: the folder of bridge.sh)
  BRIDGE_TEMPLATES  templates directory (default: ./templates next to the scripts)
  BRIDGE_HERDR      herdr executable (default: herdr); tests point it to tests/fake_herdr
  BRIDGE_MUX        force the multiplexer: herdr | tmux (default: herdr if found, else tmux inside $TMUX)
  BRIDGE_PYTHON     python3 executable
  DELIVER_S         seconds to wait per delivery attempt (30; 3 attempts in total)
  STALL_S           idle seconds before a task becomes stalled (180)
  POLL_S            seconds between checks in wait (10)
  CONFIRM_POLL_S    seconds between checks while send confirms the delivery (2)
  APPROVER_POLICY   policy file (default: approver.policy in BRIDGE_DIR, else next to the scripts)
  APPROVE_WAIT_S    seconds to wait after Enter before checking the dialog closed (1)
  BRIDGE_MAX_CHILD_MB  memory guard: each tick stops any process in an open task's repository above this many MB (2048; 0 off)
  BRIDGE_AUTO_OPEN  0 disables opening/closing agents in new herdr workspaces (default 1)
  BRIDGE_GENTLE_CMD / BRIDGE_OPENCODE_CMD   command run in the new workspace (gentle-shell / opencode)
  BRIDGE_OPEN_TIMEOUT_S  seconds to wait for an opened agent to be idle (90)
  BRIDGE_MAX_AGENTS agents opened by the bridge alive at once (3; each uses roughly 0.3 to 0.7 GB)
  BRIDGE_REAP_WAIT_S  how long the watcher waits for a busy finished agent to be closed (300)
  BRIDGE_OWNED_GRACE_S  age after which an opened pane that never got a task is closed (180: longer than BRIDGE_OPEN_TIMEOUT_S, so a pane being opened is never reaped)
  BRIDGE_NO_WATCHER 1 stops send/resend from starting the background watcher
  WATCH_EVERY_S     seconds between ticks of the background watcher (4)
  WATCH_IDLE_S      idle seconds after which the background watcher exits (120)
  APPROVER_CWD      directory approve test resolves the roots from (default: the cwd)
  OC_BG_REGISTRY    bg-agents registry; a running child makes an idle opencode count as working
                    (default: ~/.local/state/opencode-bg/registry.json)
  BRIDGE_NOW        fixed epoch for tests; BRIDGE_WATCH_MAX stops watch after N passes

Exit code 2 and the short usage: unknown command.
HELP
}

cmd="${1:-}"
shift || true
case "$cmd" in
  pane) target_of "${1:?usage: bridge.sh pane <agent> [repo]}" "${2:-$PWD}" ;;
  peek) read_pane "$(target_of "${1:?usage: bridge.sh peek <agent> [lines]}" "$PWD")" "${2:-20}" ;;
  new | lint | send | resend | cancel | tick | watch | watcher | progress | stage | wait | ls | status | show | stats | eta | clean | doctor | migrate | approve | approve-once) "cmd_${cmd//-/_}" "$@" ;;
  help | -h | --help) help_text ;;
  *) usage; exit 2 ;;
esac

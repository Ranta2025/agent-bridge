# Agent bridge: Claude Code to delegated agents

`bridge.sh` hands a task written as a markdown file from Claude Code to an agent TUI (`gentle` = gentle-shell, or `opencode`) running in another herdr pane, confirms the agent received it, and follows it until the agent writes its report. Only bash, python3 and herdr are needed (tmux works in a reduced mode, see Known limitations). This README is the single reference: `bridge.sh help` mirrors its commands, flags, states and environment variables.

Contents: 1 Purpose, 2 Quick start, 3 Task lifecycle, 4 Agent selection and lifecycle, 5 Watcher and approver, 6 RAM guards, 7 Environment variables, 8 Commands and exit codes, 9 Invariants, 10 Files and directories, 11 The task file, 12 Companions (dock, opencode plugin, tools), 13 Tests, 14 Known limitations, 15 Troubleshooting.

## 0. Install
```bash
git clone https://github.com/Ranta2025/agent-bridge.git ~/.bridge
cd ~/.bridge && timeout 600 bash tests/run.sh   # optional: 197 tests against a fake herdr, no real agents
./bridge.sh doctor
```
Requires bash, python3 and [herdr](https://herdr.dev) (or tmux in a reduced mode). The bridge keeps its runtime state (`inbox/`, `outbox/`, `state/`, `log.jsonl`) next to the script; those paths are git-ignored. Licensed under MIT.

## 1. Purpose
- Deliver a task and **confirm the agent picked it up** (with retries).
- Know the **state** of every task at any time: queued, sent, working, done, failed, stalled, undelivered, cancelled.
- Receive **progress** (`U2/5`), new commits, ETA and workflow stages.
- **Cancel**, **resend**, queue (one writer per worktree) and keep an auditable log (`log.jsonl`).
- Never depend on a process in memory: every command reads `state/`, decides and writes.

## 2. Quick start
Run from the bridge directory (`BRIDGE_DIR`, by default the folder that holds `bridge.sh`). Flow: `new`, edit, `lint`, `send`, `wait`.

### Ejemplos
(The heading keeps its original name because `tests/t_b08.sh` extracts every fenced block of this section and runs it with the fake herdr, so the examples cannot drift from the code.)
```bash
./bridge.sh new F12-T01 --repo ~/work/app --title "Ranking card"
$EDITOR inbox/F12-T01.md                 # replace every TODO-replace
./bridge.sh lint F12-T01
./bridge.sh send gentle F12-T01 --dry-run
./bridge.sh send gentle F12-T01          # waits up to 30 s per attempt for the agent to start
./bridge.sh progress F12-T01 1 3 "U1 tests"   # called by the delegated agent, not by you
./bridge.sh wait F12-T01 --timeout 3600 && ./bridge.sh stage F12-T01 verified "tests OK"
./bridge.sh ls
./bridge.sh status F12-T01
./bridge.sh eta F12-T01 --json
./bridge.sh stats
./bridge.sh clean --days 14 --dry-run
```
Auto-approver (opencode only, only while a bridge task is active):
```bash
./bridge.sh approve status
./bridge.sh approve test "bash|git status"
./bridge.sh approve dry
./bridge.sh approve on
./bridge.sh approve-once
```
Queue, cancel and resend (with the agent busy, `--queue` keeps the task waiting and `tick` starts it when the agent is free):
```bash
./bridge.sh new F12-T02 --repo ~/work/app
$EDITOR inbox/F12-T02.md
./bridge.sh send gentle F12-T02 --queue
./bridge.sh cancel F12-T02
./bridge.sh resend F12-T02
```
Inspect and diagnose:
```bash
./bridge.sh peek gentle 30
./bridge.sh show F12-T02
./bridge.sh doctor
./bridge.sh help
```

### Ayuda y autocompletado
`./bridge.sh help` (or `-h`, `--help`) prints the full guide and exits 0. No arguments or an unknown command prints the short usage and exits 2. Fish completions live outside this repository in `~/.config/fish/completions/bridge.fish` (commands, flags, agents, `stage` names, task ids read from `state/`); `tests/t_b08.sh` checks them when the file exists.

## 3. Task lifecycle
States: `queued`, `sent`, `working`, `done`, `failed`, `stalled`, `undelivered`, `cancelled`. Open states (the agent is considered busy): `sent`, `working`, `stalled`. Terminal: `done`, `failed`, `cancelled`, `undelivered`.

| From | To | What causes it |
| --- | --- | --- |
| (none) | `sent` | `send` delivers the prompt (state and `inbox/<id>.sent` are written first). |
| (none) | `queued` | `send --queue` when the agent is busy or the `BRIDGE_MAX_AGENTS` cap blocks opening one. |
| `queued` | `sent` | `tick`/`watch` (the queue starter): the oldest queued task of an (agent, project) pair starts when that pair has no open task, an agent can take it and, unless the task was queued with `--force`, the repository has no uncommitted changes to tracked files. |
| `queued` | `cancelled` | `cancel`. |
| `sent` | `working` | `tick` sees the agent `working`, or its status `unknown` (tmux cannot tell). |
| `sent` | `sent` (retry) | `DELIVER_S` (30 s) passed without work, the agent is not `missing` and fewer than 3 prompts were sent: `tick` sends the prompt again (`attempts` + 1). |
| `sent` | `undelivered` | `DELIVER_S` passed and the agent is `missing` or 3 prompts were already sent. |
| `working` | `stalled` | The agent is neither `working` nor `missing`/`unknown`, and it has been that way for `STALL_S` (180 s) counted from the first tick that saw it idle. Only `working` tasks stall; `sent` never does. |
| `stalled` | `working` | `tick` sees the agent `working` again (`resumed`). |
| `sent`, `working`, `stalled` | `done` / `failed` | `tick` finds a non-empty `outbox/<id>.md`. The report always wins over every other signal. The first `Status:` (or `Estado:`) line decides, by its leading word: a success word (done, ok, complete, completed, finished, success, passed, or the Spanish listo, hecho, completado, terminado, exitoso) makes the task `done` even if the rest of the line mentions failures (`Status: done, 0 failures`); a failure word (blocked, partial, fail, incomplete, or the Spanish bloqueado, parcial, fallo, incompleto) makes it `failed`. Any other leading word falls back to searching the whole line for a failure word. A report with no status line is `done`. |
| `sent`, `working`, `stalled`, `queued` | `cancelled` | `cancel` (sends Esc to the agent first unless the task is only queued). |
| `undelivered`, `stalled`, `failed`, `cancelled` | `sent` | `resend` (`attempts` + 1, same history). `send` on an existing finished task does the same. |

`resend` refuses `done`, `queued`, `sent` and `working`. A report left by an earlier attempt is renamed `outbox/<id>.attempt<N>.md`. The agent reports progress with `bridge.sh progress <id> <done> <total> "<unit>"`; that does not change the state, but the progress shows in `ls`. When a task finishes without failing, its progress is completed to `total/total`.

Workflow stages are separate from states: `sent` is recorded automatically, and the orchestrator marks `verified`, `reviewed`, `recorded`, `merged` with `stage`. `ls` shows the latest stage reached.

## 4. Agent selection and lifecycle
The agent is chosen by **kind and repository**, never by a global name: `gentle` is herdr kind `pi`, `opencode` is `opencode`. A pane is a candidate when its directory is in the same git repository as the task (same `git --git-common-dir`, any worktree). The repository of a task is `send`'s third argument, else the `bridge:repo=` line of the task file (`new --repo`), else the cwd. `pane` and `peek` use the repository of the current directory. The chosen pane is stored in `state/<id>.json` (`pane`) and used by `tick`, `show` and the approver.

Selection when sending (herdr, `gentle` or `opencode`, repository is git):
1. A **free** pane is reused: `idle` in herdr and no open task sent to it. The pane in the very same worktree is preferred. A pane the bridge opened whose task already ended is never reused.
2. If none is free, a task for **another worktree** opens a new agent. For the **same worktree** the busy pane is returned, so `send` exits 3 (or queues with `--queue`): one writer per worktree.
3. `send --parallel` allows a second agent in the same worktree only if the `## Allowed edit surfaces` of the task do not overlap those of any open task there; otherwise `send` exits 7 and names the overlap. `--parallel` also skips the clean-tree check.
4. At most `BRIDGE_MAX_AGENTS` (3) agents opened by the bridge exist at once (each uses roughly 0.3 to 0.7 GB). At the cap, `send` exits 3, or queues with `--queue`.

**Opening.** The bridge runs `herdr workspace create --cwd <repo top> --label <agent>-<repo> --no-focus` (always a **new workspace**, never a split), runs `gentle-shell` / `opencode` in it (`BRIDGE_GENTLE_CMD`, `BRIDGE_OPENCODE_CMD`) and waits for `idle` up to `BRIDGE_OPEN_TIMEOUT_S` (90 s); if that fails it closes the workspace and the command fails. Each agent it opens is recorded in `state/owned/<pane>` (`pane`, `workspace`, `agent`, `repo`, `opened`, and `task` once a task is sent to it). `BRIDGE_AUTO_OPEN=0`, tmux, an unknown agent name or a non-git repository disable opening: `send` then fails with a message saying where the agent is open and how to open it.

**Reaping.** Every `tick`, `send`, `resend`, `cancel` and queue start runs the reaper. It closes a recorded workspace when its task is `done`, `failed`, `cancelled` or `undelivered` (or the task no longer exists) **and** the agent is no longer `working`; a failed close is retried on the next tick, and the record is dropped once herdr no longer lists the workspace. A recorded pane that never received a task is closed after `BRIDGE_OWNED_GRACE_S` (60 s); the grace only protects a pane that `send` has just opened. The watcher stays alive while a recorded pane waits to be closed, up to `BRIDGE_REAP_WAIT_S` (300 s).

**Never closed:** an agent the user opened. Only workspaces recorded in `state/owned/` are ever closed. Read-only commands (`pane`, `peek`, `show`, `status`, `ls`) never open or close anything.

## 5. Watcher and approver
**Watcher.** `send` and `resend` start a background `bridge.sh watch 4 --until-idle 120` (via `setsid nohup`, pid in `watch.pid`, output in `watch.log`) unless one is already alive or `BRIDGE_NO_WATCHER=1`. Each pass is a `tick`: it evaluates every open task, reaps, starts queued tasks, runs the approver and the memory guard. It exits by itself once no task has been open for `WATCH_IDLE_S` (120 s), later if a recorded agent still waits to be closed (`BRIDGE_REAP_WAIT_S`). `watcher start|status|stop` controls it by hand; `watch [seconds] [--until-idle S]` runs the loop in the foreground (default 5 s, no stop). `wait` also ticks on every poll, and the Claude Code dock ticks every 5 s, so none of these is required for normal use; `tick` is idempotent and atomic, so they coexist.

**Approver** (opencode only). opencode asks for permission mid-task and its permissions cannot be opened only for the bridge, so on each tick the bridge reads the opencode pane (read-only: `herdr agent read ... --source recent-unwrapped --lines 40`) and, **only for a task of that agent in state `sent` or `working` whose pane is in the same project**, answers the dialog itself with a single `enter` ("Allow once" is preselected). It never chooses "Always allow" and never types anything else. With no bridge task, or a pane in another project, it does nothing, so hand-driven opencode keeps asking.

Decision (`approver.policy`, plain text, versioned; `APPROVER_POLICY` points to another file):
- Only the tools `bash`, `edit`, `write`, `read`, `list`, `external_directory` can be approved, and only when every target is inside a root: `root-project` (the git repository of the pane and all its worktrees, resolved on each decision from the pane cwd), `root-bridge-io` (only `$BRIDGE_DIR/inbox` and `outbox`, plus `$BRIDGE_DIR/bridge.sh` and `v2/bridge.sh` as executables) and `root /tmp`. Siblings, parents and `~` are outside. Any other tool type (webfetch, subagent, glob, grep, MCP...) is not approved.
- **Never auto-approved** (the dialog is left untouched and flagged, NEVER rules beat any root): `git push*`, `git reset --hard*`, `git rebase*`, `git clean*`, `git checkout -- *`, `git branch -D*`, anything with `--force`, `sudo*`, `ssh|scp|sftp|rsync`, `curl|wget ... | sh|bash`, `adb shell input*`, `docker system prune*`, `docker volume rm*`, and any path under `~/.ssh`, `~/.config/gh`, `~/.claude`, `~/.config/opencode`, `secrets/`, `.env*`, `*.keystore`. `git commit` and `git add` are allowed. Rules apply to every segment of a compound command (`&&`, `||`, `;`, `|`, `&`, newlines, `$(...)`, backticks, parentheses outside quotes), also after `sudo`, `xargs` or `bash -c`, ignoring quotes; they are strict on purpose (`echo "git push"` is refused). Heredoc bodies are data, except that a command whose terminator is not visible is refused as truncated (with the one exception of `git commit ... <<MSG`). Commands over 8 lines (heredoc body excluded) or ending in `…` are refused; wrapped rows are read both with and without a space at each break, and every reading must be allowed.
- An unrecognised dialog (header and options but unknown kind) is not touched and logged as `approval_unrecognised`.
- One action per dialog: after `enter` it waits `APPROVE_WAIT_S` (1 s), re-reads the pane and checks the dialog changed; it retries once, then logs `approval_failed` and leaves it. A lock stops `watch` and `approve-once` answering at once. Each distinct dialog (text signature) counts once.
- Modes in `approver.mode`: `on` (default when the file is absent), `dry` (logs `would_approve`, sends nothing), `off`. `approve test "<tool>|<target>"` prints `ALLOW <reason>` or `REFUSE <reason>` without keys; `approve test --file <capture>` evaluates a saved pane capture.
- Every decision goes to `log.jsonl` (`auto_approved`, `approval_refused`, `approval_failed`, `approval_unrecognised`, `would_approve`) and updates `approvals`, `refusals` and `approval` in the task state; `ls --json` exposes `approvals`, `refusals`, `approval_pending`, `approval_sig`, `approval_tool`, `approval_target`.
- Limits: detection follows a real opencode v2.0.21 capture of a bash dialog with a heredoc (`tests/fixtures/`); Edit, Read and external-directory dialogs rest on the binary's component code. If opencode changes its texts the detector stops recognising dialogs and does nothing (it fails towards "ask"). `edit` only checks the title path; shell variables inside paths are not resolved.

## 6. RAM guards
- **Agent cap:** `BRIDGE_MAX_AGENTS` (see section 4).
- **Memory guard:** every `tick` stops (SIGTERM, then SIGKILL after 0.3 s) any process whose cwd is inside the repository (any worktree) of an open task and whose RSS exceeds `BRIDGE_MAX_CHILD_MB` (2048; `0` disables). It never touches `opencode`, `claude`, `herdr`, `ghostty`, `docker`, `dockerd`, `containerd` or `containerd-shim*`. Each kill is logged as `mem_guard_kill` and printed to stderr. It exists because an unbounded `node --test` once grew to 4.8 GB and took down the desktop.
- The task template also tells the agent to run tests under `timeout` and a memory cap and never to run two test processes in parallel.

## 7. Environment variables
| Variable | Default | Meaning |
| --- | --- | --- |
| `BRIDGE_DIR` | folder of `bridge.sh` (parent of `v2/` when run from `v2/`) | Data directory (inbox, outbox, state, log). |
| `BRIDGE_TEMPLATES` | `templates/` next to the scripts | Template directory used by `new`. |
| `BRIDGE_HERDR` | `herdr` | herdr executable; tests point it to `tests/fake_herdr`. |
| `BRIDGE_MUX` | auto: herdr if found, else tmux when `$TMUX` is set | Force `herdr` or `tmux`. |
| `BRIDGE_PYTHON` | `python3` | Python executable. |
| `DELIVER_S` | 30 | Seconds per delivery attempt (3 prompts in total). |
| `STALL_S` | 180 | Idle seconds before a `working` task becomes `stalled`. |
| `POLL_S` | 10 | Seconds between checks in `wait`. |
| `CONFIRM_POLL_S` | 2 | Seconds between checks while `send` confirms the delivery. |
| `BRIDGE_AUTO_OPEN` | 1 | `0` disables opening and closing agents in new herdr workspaces. |
| `BRIDGE_GENTLE_CMD` | `gentle-shell` | Command run in a workspace opened for `gentle`. |
| `BRIDGE_OPENCODE_CMD` | `opencode` | Command run in a workspace opened for `opencode`. |
| `BRIDGE_OPEN_TIMEOUT_S` | 90 | Seconds to wait for an opened agent to become idle. |
| `BRIDGE_MAX_AGENTS` | 3 | Agents opened by the bridge alive at once. |
| `BRIDGE_REAP_WAIT_S` | 300 | How long the watcher waits for a finished, still busy agent to be closed. |
| `BRIDGE_OWNED_GRACE_S` | 180 | Age after which an opened pane that never got a task is closed. |
| `BRIDGE_NO_WATCHER` | unset | `1` stops `send`/`resend` from starting the background watcher. |
| `WATCH_EVERY_S` | 4 | Seconds between ticks of the background watcher. |
| `WATCH_IDLE_S` | 120 | Idle seconds after which the background watcher exits. |
| `BRIDGE_MAX_CHILD_MB` | 2048 | Memory guard threshold per process (`0` disables). |
| `APPROVER_POLICY` | `approver.policy` in `BRIDGE_DIR`, else next to the scripts | Policy file. |
| `APPROVER_CWD` | current directory | Working directory `approve test` resolves roots from. |
| `APPROVE_WAIT_S` | 1 | Seconds to wait after Enter before checking the dialog closed. |
| `OC_BG_REGISTRY` | `~/.local/state/opencode-bg/registry.json` | bg-agents registry; a running child there makes an idle opencode count as `working`. |
| `BRIDGE_NOW` | unset | Fixed epoch for tests (sleeping advances a virtual clock). |
| `BRIDGE_WATCH_MAX` | 0 | Stop `watch` after N passes (tests). |

## 8. Commands and exit codes
Unless listed otherwise a command exits 0 on success and 1 on a failure reported on stderr. Usage errors exit 2.

| Command | What it does | Exit codes |
| --- | --- | --- |
| `pane <agent>` / `peek <agent> [lines]` | Pane id / last lines (default 20) of the agent in the repository of the cwd. | 0; 1 no pane in that repository |
| `new <id> [--repo R] [--title T]` | Create `inbox/<id>.md` from the template (R defaults to the cwd). | 0; 1 exists, bad id or unknown flag |
| `lint <id>` | Validate the task (section 11); prints a warning when `todowrite` is not mentioned. | 0 valid; 1 errors on stderr |
| `send <agent> <id> [repo] [--force] [--dry-run] [--queue] [--parallel] [--no-confirm]` | Lint, select or open an agent, check the tree, deliver, confirm the start. `--force` skips lint and the dirty-tree check; `--dry-run` changes nothing; `--no-confirm` sends once and returns without waiting. | 0 sent and confirmed, queued, or dry run; 1 no `inbox/<id>.md`, or no pane could be chosen; 2 bad usage or unknown flag; 3 agent busy, `BRIDGE_MAX_AGENTS` reached, or task already open; 4 uncommitted changes to tracked files; 5 lint failed; 6 undelivered after the retries; 7 `--parallel` surfaces overlap |
| `resend <id>` | Resend an `undelivered`, `stalled`, `failed` or `cancelled` task. | 0; 1 no state or not resendable; 3 agent busy or cap reached; 6 undelivered again |
| `cancel <id>` | Send Esc to the agent, mark `cancelled`, free the queue. | 0; 1 no state or already terminal |
| `tick` | One idempotent pass: evaluate open tasks, reap, start queued tasks, approver, memory guard. | 0 |
| `watch [seconds] [--until-idle S]` | `tick` in a loop (default 5 s); `--until-idle` stops S seconds after the last open task. | 0 |
| `watcher start\|status\|stop` | Control the background watcher. | 0; 1 `start` failed or `status` not running |
| `approve on\|off\|dry\|status [--json]\|test "<tool>\|<target>"` | Switch or inspect the approver (section 5). | 0; `test` 1 REFUSE; 2 bad usage |
| `approve-once` | One approver pass, printing `ALLOW`/`REFUSE`/`UNRECOGNISED` per dialog. | 0 |
| `progress <id> <done> <total> "<text>"` | Called by the delegated agent. | 0; 1 no state; 2 bad numbers |
| `stage <id> verified\|reviewed\|recorded\|merged [note]` | Called by the orchestrator at each workflow step. | 0; 1 no state; 2 unknown stage |
| `wait <id> [--timeout S]` | Block until the task ends and print its report. | 0 done; 1 failed (report and note printed); 3 cancelled; 4 undelivered; 124 timeout |
| `ls [--json]` | Table or JSON (`{"version":1,"now":..,"tasks":[..]}`) of every task, newest first. | 0 |
| `status <id>` / `show <id> [lines]` | State JSON / state plus the last lines of the agent pane (default 15). | 0; 1 no state |
| `stats [--json]` / `eta <id> [--json]` | Durations and success rates per agent and kind / estimate from the median of similar tasks. | 0 |
| `clean [--days N] [--dry-run]` | Move tasks finished more than N days ago (default 7) to `archive/`. | 0; 2 bad argument |
| `doctor` | Check python3, the multiplexer, directories, agents and orphan tasks. | 0 fine (WARN allowed); 1 any ERROR |
| `migrate` | Import legacy `inbox/<id>.sent` and `outbox/<id>.md` pairs into `state/` (read-only on them). | 0 |
| `help` / `-h` / `--help` | Full guide. | 0 |

## 9. Invariants
- **One writer per worktree.** A busy agent never receives a second task for the same worktree; `--parallel` is the only exception and requires disjoint surfaces. The busy lock is per pane: two sessions of one agent in one project take one task each.
- **Never close what the bridge did not open.** Only `state/owned/` records are closed; a pane the user opened is never recorded.
- **Never use another project's pane.** `send` refuses when the pane's repository differs from the task's.
- **Idempotent ticks.** `tick` takes a per-task lock (`state/.<id>.tick.lock`), writes state atomically (temp file plus `mv`) and can run from the dock, `watch`, `wait` and the watcher at once. The queue starter holds its own lock so two tickers never send the same task.
- **Report wins.** A non-empty `outbox/<id>.md` ends a task regardless of what the pane shows.
- **Approver scope.** Only `enter`, only for opencode tasks in `sent`/`working` in the same project, never "Always allow".
- **Legacy compatibility.** `inbox/<id>.sent` keeps its v1 format `"<agent> <epoch>"`.

## 10. Files and directories
| Path | Content |
| --- | --- |
| `bridge.sh`, `v2/bridge.sh` | CLI entry points. They differ only in their help text (see Known limitations); `tests/` run `v2/bridge.sh`. |
| `v2/lib/` | `cmds.sh` (commands), `herdr.sh` (multiplexer, agent selection, opening and reaping), `state.sh` (helpers), `state.py` (state machine, lint, stats), `approver.sh` and `approver.py` (auto-approver). |
| `inbox/<id>.md` | The task given to the agent. `inbox/<id>.sent` is `"<agent> <epoch>"`. Runtime data, not versioned. |
| `outbox/<id>.md` | The agent's final report; **existing and non-empty is the end signal**. Earlier attempts: `<id>.attempt<N>.md`. Not versioned. |
| `state/<id>.json` | Task state, written atomically. `state/owned/<pane>` records agents the bridge opened. `state/.*.lock` are lock files. Not versioned. |
| `log.jsonl` | One line per event: `{"ts":..,"id":..,"event":..,"data":{..}}`. Not versioned. |
| `archive/` | Finished tasks moved by `clean`. Not versioned. |
| `watch.log`, `watch.pid` | Output and pid of the background watcher. Runtime files, not versioned. |
| `templates/task.md` | Template for `new`. |
| `approver.policy` | Approver policy (versioned). `approver.mode`: `on`/`dry`/`off`, local, not versioned. |
| `tools/rdd.py` | Manual helper that runs the native RDD review flow of `gentle-ai` on the HEAD commit of a worktree (`rdd.py preflight\|grant <worktree> <base-ref>`). Not used by the bridge. |
| `docs/` | Notes on the opencode bg-agents plugin (Spanish). |
| `tests/` | Test suite with a fake herdr (`tests/fake_herdr`). |
| `PLAN.md` | Historical design plan. |

## 11. The task file
`new` copies `templates/task.md`: working rules (act as orchestrator, delegate to sub-agents, one writer, conventional commits without attribution, RAM caps), `## Context`, `## Allowed edit surfaces`, `## Verification` and `## Report`. Replace every `TODO-replace`.

`lint` requires: no `TODO-replace` left; a non-empty `## Allowed edit surfaces` of repository-relative paths (no absolute or `~`, no `.`, `*`, `**`, `**/*`, and no `..`); a `## Report` (or `## Reporte`) section; a mention of sub-agents; the report path `outbox/<id>.md`. It only **warns** (exit stays 0) when the task does not mention `todowrite`. Older tasks without those sections need `send --force`.

The prompt sent to the agent (`msg_for` in `v2/lib/cmds.sh`) points to `inbox/<id>.md`, names `outbox/<id>.md` as the end signal and asks for a visible TODO list. The agent reports progress with `bridge.sh progress <id> <done> <total> "<unit>"` after each unit and writes the report with a first status line such as `Status: done`, `Status: partial` or `Status: blocked`, then commits, verification evidence (`<command>: <result>`) and what is pending.

## 12. Companions
- **Claude Code `agent-dock` mod** (`~/.claude/my-mods/mods/agent-dock/`, outside this repository; its own documentation is `/dock ayuda`). It shows the tasks and agents in a side panel: it reads `bridge.sh ls --json` about every 2 s (falling back to `inbox/*.sent` when that fails), runs `bridge.sh tick` every 5 s, and offers `/dock` commands (`ls`, `ver`, `estado`, `reenviar`, `cancelar`, `cola`, `log`, `archivar`, `aprobar`, ...) that call `bridge.sh`. It reads the agents with `herdr agent list|read` only and never sends keys itself.
- **opencode `bg-agents` plugin** (`~/.config/opencode/bg-agents/`): background sub-agents, a registry the dock reads and a `todowrite` that mirrors into `bridge.sh progress`. opencode 2.0.21 has no `todowrite` of its own, so without the plugin the TODO-list request of the task has no effect. See `docs/opencode-bg-agents.md`.
- **`tools/rdd.py`**: see section 10.

## 13. Tests
```bash
timeout 600 bash tests/run.sh [name-filter]   # CLI with the fake herdr, about 3 minutes, 197 tests
```
The suite never touches real agents: it sets `BRIDGE_DIR` and `BRIDGE_HERDR` to a sandbox and `tests/fake_herdr`, and `BRIDGE_NOW` simulates the clock. It also checks that every command is in `help` and this README, that every state is documented, that the README examples run, and the fish completions.

## 14. Known limitations
- **Reap versus open race (closed).** A pane the bridge just opened is recorded without a task until `send` delivers to it. `BRIDGE_OWNED_GRACE_S` (180 s) is deliberately longer than `BRIDGE_OPEN_TIMEOUT_S` (90 s), so a watcher tick cannot close a pane that is still being opened. Keep that inequality if you change either value.
- **tmux.** Agents are never opened or closed automatically; agent status is always `unknown`, so a task moves to `working` on the first tick and never becomes `stalled` or `undelivered` (a dead agent is only noticed through a missing report). The mux is chosen by `BRIDGE_MUX`, else herdr when found, else tmux inside `$TMUX`; after a context compaction `$HERDR_ENV`/`$TMUX` may be lost, so set `BRIDGE_MUX`.
- The dirty-tree check looks only at tracked files and is skipped by `--force` and `--parallel`.
- `bridge.sh` at the root is a copy of `v2/bridge.sh` with an older help text (no `--parallel`, exit 7 or the auto-open variables); its behaviour is identical because both source `v2/lib`.
- A `done` task can only be re-run with `send`, not `resend`.
- The `stalled` threshold needs ticks: with no watcher, dock or `wait` running, nothing evaluates the task.
- The approver reads at most the last 40 pane lines; a dialog that scrolls can hide part of a diff.

## 15. Troubleshooting
- **"no opencode pane is open in ..." / `peek` fails:** no pane of that agent in the task's repository. `send` normally opens one; with `BRIDGE_AUTO_OPEN=0` or tmux open it yourself (`herdr pane split --current --direction right --cwd <repo>`) and run `./bridge.sh doctor`.
- **"not a git repository":** `git init` there or pass the right repository (`send <agent> <id> <repo>`, or `new <id> --repo <repo>`).
- **`undelivered`:** the agent did not start after 3 prompts (30 s each). Look at its pane (`peek`, `show`): it may sit in a dialog or have unsent text. Clear it and `./bridge.sh resend <id>`.
- **`stalled`:** idle more than 180 s with no report. If it is still working the next tick returns it to `working`; otherwise `resend` or `cancel`.
- **`send` exits 3 / 4 / 5 / 7:** busy or cap reached (use `--queue` or wait) / commit or discard tracked changes, or `--force` / fix what `lint` says / change the surfaces or use another worktree.
- **`failed` although the work succeeded:** the report's `Status:` line starts with a failure word such as "partial", or with an unrecognised word followed by one. Start the line with a success word (`Status: done, ...`) or resend.
- **Still `working` after the agent finished:** `outbox/<id>.md` is missing or empty.
- **Tidy up:** `./bridge.sh clean --days 7 --dry-run` lists what would be archived.

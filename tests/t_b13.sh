# B13 - the bridge always watches the agent it handed a task to: `send` starts a background watcher that answers the
# permission dialogs the policy allows (the orchestrator no longer has to remember to run `watch`), and the watcher
# stops by itself when no task is open.

test_watch_stops_by_itself_when_no_task_is_open() {
  br watch 1 --until-idle 5
  rc_is 0
  [[ -z "$(st_list_open)" ]] || fail "no task should be open"
}
st_list_open() { python3 -I "$ST" list-open 2>/dev/null; }

test_watch_keeps_going_while_a_task_is_open() {
  mk_task B13-1
  br send opencode B13-1 "$REPO" --no-confirm
  rc_is 0
  export BRIDGE_WATCH_MAX=3
  br watch 1 --until-idle 5
  rc_is 0
  [[ -n "$(st_list_open)" ]] || fail "the task is still open: the watcher must not have closed it"
}

test_watcher_start_is_idempotent_and_can_be_stopped() {
  unset BRIDGE_NOW BRIDGE_NO_WATCHER
  export WATCH_IDLE_S=600
  br watcher start
  rc_is 0
  local first
  first="$(<"$BRIDGE_DIR/watch.pid")"
  kill -0 "$first" || fail "the watcher is not running"
  br watcher start
  [[ "$(<"$BRIDGE_DIR/watch.pid")" == "$first" ]] || fail "a second watcher was started"
  br watcher status
  rc_is 0
  contains "$OUT" "$first"
  br watcher stop
  rc_is 0
  sleep 0.3
  ! kill -0 "$first" 2>/dev/null || fail "the watcher is still running after stop"
  br watcher status
  rc_is 1
}

test_send_starts_the_watcher() {
  unset BRIDGE_NOW BRIDGE_NO_WATCHER
  export WATCH_IDLE_S=600
  mk_task B13-2
  br send opencode B13-2 "$REPO" --no-confirm
  rc_is 0
  [[ -s "$BRIDGE_DIR/watch.pid" ]] || fail "send did not start the watcher"
  kill -0 "$(<"$BRIDGE_DIR/watch.pid")" || fail "the watcher is not running"
  br watcher stop
}

test_dry_run_and_the_kill_switch_start_nothing() {
  unset BRIDGE_NOW
  mk_task B13-3
  BRIDGE_NO_WATCHER= br send opencode B13-3 "$REPO" --dry-run
  [[ ! -e "$BRIDGE_DIR/watch.pid" ]] || fail "dry-run started a watcher"
  BRIDGE_NO_WATCHER=1 br send opencode B13-3 "$REPO" --no-confirm
  [[ ! -e "$BRIDGE_DIR/watch.pid" ]] || fail "BRIDGE_NO_WATCHER=1 must start nothing"
}

test_the_task_template_tells_the_agent_it_only_implements() {
  br new B13-4 --repo "$REPO"
  rc_is 0
  local body
  body="$(<"$BRIDGE_DIR/inbox/B13-4.md")"
  contains "$body" "only implement"
  contains "$body" "push"
}

# The memory guard: a runaway test run once ate 4.8 GB and the kernel killed the user's desktop. Every tick stops
# any process working inside the repository of an open task that holds more than BRIDGE_MAX_CHILD_MB.
hog() { # dir mb -> pid in $HOGPID; touches every page so the memory is really resident
  ( cd "$1" && python3 -c "import time; x = bytearray($2 * 1024 * 1024)
for i in range(0, len(x), 4096): x[i] = 1
time.sleep(120)" >/dev/null 2>&1 & echo $! >"$T/hog.pid" )
  HOGPID="$(<"$T/hog.pid")"
  local n=0
  while ((n < 50)) && (($(awk '/VmRSS/ {print $2}' "/proc/$HOGPID/status" 2>/dev/null || echo 0) < $2 * 1000)); do sleep 0.1; n=$((n + 1)); done
}

test_the_guard_stops_a_runaway_process_in_the_task_repository() {
  mk_task B13-5
  br send opencode B13-5 "$REPO" --no-confirm
  rc_is 0
  hog "$REPO" 150
  export BRIDGE_MAX_CHILD_MB=100
  br tick
  sleep 0.5
  ! kill -0 "$HOGPID" 2>/dev/null || { kill -9 "$HOGPID" 2>/dev/null; fail "the runaway process is still alive"; }
  contains "$(<"$BRIDGE_DIR/log.jsonl")" "mem_guard_kill"
}

test_the_guard_leaves_other_directories_and_small_processes_alone() {
  mk_task B13-6
  br send opencode B13-6 "$REPO" --no-confirm
  rc_is 0
  mkdir -p "$T/elsewhere"
  hog "$T/elsewhere" 150
  local other="$HOGPID"
  export BRIDGE_MAX_CHILD_MB=100
  br tick
  sleep 0.5
  kill -0 "$other" 2>/dev/null || fail "a process outside the task repository was stopped"
  kill -9 "$other" 2>/dev/null
  hog "$REPO" 150
  export BRIDGE_MAX_CHILD_MB=0
  br tick
  sleep 0.3
  kill -0 "$HOGPID" 2>/dev/null || fail "BRIDGE_MAX_CHILD_MB=0 must disable the guard"
  kill -9 "$HOGPID" 2>/dev/null
}

test_ls_json_tells_the_pane_each_task_was_sent_to() {
  mk_task B13-7
  br send opencode B13-7 "$REPO" --no-confirm
  rc_is 0
  br ls --json
  rc_is 0
  contains "$OUT" '"pane": "wS:p1"'
}

# Two sessions of the same agent in one project work in parallel: the busy lock is per pane, not per agent kind.
test_two_panes_of_one_agent_in_one_project_take_a_task_each() {
  git -C "$REPO" worktree add -q "$T/wt" -b wt2
  fh_add opencode wS:p2 opencode "$T/wt" idle
  mk_task B13-8
  br send opencode B13-8 "$REPO" --no-confirm
  rc_is 0
  mk_task B13-9
  br send opencode B13-9 "$T/wt" --no-confirm
  rc_is 0
  contains "$OUT" "wS:p2"
  br status B13-9
  contains "$OUT" '"pane": "wS:p2"'
  mk_task B13-10
  br send opencode B13-10 "$T/wt" --no-confirm
  rc_is 3
  contains "$OUT" "busy"
}

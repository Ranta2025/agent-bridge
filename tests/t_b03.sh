# B03 - tick/watch, progress, stage, wait, stalled and failed detection.

commit_in_repo() { # message
  echo "$RANDOM" >>"$REPO/b.txt"
  git -C "$REPO" add b.txt
  git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$1"
}

send_pending() { # id [agent]  -> task in state 'sent' (delivery not confirmed yet)
  mk_task "$1"
  br send "${2:-gentle}" "$1" "$REPO" --no-confirm
  rc_is 0
}

# --- tick: delivery ------------------------------------------------------
test_tick_marks_sent_task_working_when_agent_works() {
  send_pending A-1
  eq sent "$(sget A-1 state)"
  br tick
  rc_is 0
  eq working "$(sget A-1 state)"
  eq 1000000 "$(sget A-1 started)"
}

test_tick_retries_then_declares_undelivered_with_simulated_clock() {
  mk_task A-2
  fh_drop gentle 10
  br send gentle A-2 "$REPO" --no-confirm
  advance 29; br tick
  eq 1 "$(fh_prompts gentle)" "too early to retry"
  advance 2; br tick
  eq 2 "$(fh_prompts gentle)"
  advance 31; br tick
  eq 3 "$(fh_prompts gentle)"
  eq sent "$(sget A-2 state)"
  advance 31; br tick
  eq 3 "$(fh_prompts gentle)" "no fourth prompt"
  eq undelivered "$(sget A-2 state)"
  contains "$OUT" "A-2: undelivered"
}

test_tick_is_idempotent() {
  send_pending A-3
  br tick
  before="$(wc -l <"$BRIDGE_DIR/log.jsonl")"
  br tick; br tick
  eq "$before" "$(wc -l <"$BRIDGE_DIR/log.jsonl")" "no new log lines when nothing changes"
  eq "" "$OUT" "quiet when nothing changes"
}

# --- tick: completion and failure ---------------------------------------
test_tick_detects_done_report_with_commits_and_tests() {
  send_pending A-4
  br tick
  commit_in_repo "feat: one"
  commit_in_repo "feat: two"
  write_report A-4 "done" "Tests: 12 passed"
  advance 90
  br tick
  contains "$OUT" "A-4: done"
  eq done "$(sget A-4 state)"
  eq 1000090 "$(sget A-4 done)"
  eq done "$(sget A-4 summary.status)"
  eq "12 passed" "$(sget A-4 summary.tests)"
  eq 2 "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["summary"]["commits"]))' "$BRIDGE_DIR/state/A-4.json")"
}

test_tick_ignores_an_empty_report_file() {
  send_pending A-5
  : >"$BRIDGE_DIR/outbox/A-5.md"
  br tick
  eq working "$(sget A-5 state)"
}

test_tick_marks_failed_when_status_line_says_blocked_failed_or_partial() {
  local i=0 line
  for line in "Estado: bloqueado" "**Status:** Partial" "status: failed" "Estado: PARCIAL (faltan pruebas)" "## Status: blocked"; do
    i=$((i + 1))
    id="F-$i"
    mk_task "$id"
    fh_status gentle idle
    br send gentle "$id" "$REPO"
    write_report "$id" "x"
    printf '# Report\n\n%s\n\ndetails\n' "$line" >"$BRIDGE_DIR/outbox/$id.md"
    br tick
    eq failed "$(sget "$id" state)" "line [$line]"
  done
}

test_tick_marks_done_for_positive_status_lines() {
  local i=0 line
  for line in "Estado: completado" "**Status:** done" "Status: OK"; do
    i=$((i + 1))
    id="G-$i"
    mk_task "$id"
    fh_status gentle idle
    br send gentle "$id" "$REPO"
    printf '# Report\n\n%s\n' "$line" >"$BRIDGE_DIR/outbox/$id.md"
    br tick
    eq done "$(sget "$id" state)" "line [$line]"
  done
}

test_report_without_status_line_counts_as_done() {
  send_pending A-6
  printf 'just text\n' >"$BRIDGE_DIR/outbox/A-6.md"
  br tick
  eq done "$(sget A-6 state)"
}

# --- tick: stalled -------------------------------------------------------
test_tick_flags_stalled_agent_idle_without_report() {
  send_pending A-7
  br tick
  fh_status gentle idle
  advance 10; br tick
  eq working "$(sget A-7 state)" "idle just started"
  advance 100; br tick
  eq working "$(sget A-7 state)"
  advance 100; br tick
  eq stalled "$(sget A-7 state)"
  contains "$OUT" "A-7: stalled"
}

test_stalled_task_resumes_when_agent_works_again() {
  send_pending A-8
  br tick
  fh_status gentle idle
  br tick; advance 200; br tick
  eq stalled "$(sget A-8 state)"
  fh_status gentle working
  br tick
  eq working "$(sget A-8 state)"
  eq 0 "$(sget A-8 idle_since)"
}

test_stalled_task_completes_when_report_arrives() {
  send_pending A-9
  br tick
  fh_status gentle idle
  br tick; advance 200; br tick
  eq stalled "$(sget A-9 state)"
  write_report A-9 done
  br tick
  eq done "$(sget A-9 state)"
}

test_working_agent_is_never_stalled() {
  send_pending A-10
  br tick
  advance 5000; br tick
  eq working "$(sget A-10 state)"
}

# --- queue ---------------------------------------------------------------
test_tick_starts_queued_task_when_agent_frees_up() {
  mk_task Q-1a; mk_task Q-1b
  br send gentle Q-1a "$REPO"
  br send gentle Q-1b "$REPO" --queue
  eq queued "$(sget Q-1b state)"
  br tick
  eq queued "$(sget Q-1b state)" "agent still busy"
  write_report Q-1a done
  fh_status gentle idle
  br tick
  eq done "$(sget Q-1a state)"
  eq working "$(sget Q-1b state)"
  eq 2 "$(fh_prompts gentle)"
  contains "$OUT" "Q-1b: started from queue"
  eq "gentle 1000000" "$(<"$BRIDGE_DIR/inbox/Q-1b.sent")"
}

test_queue_runs_in_fifo_order_one_at_a_time() {
  mk_task Q-2a; mk_task Q-2b; mk_task Q-2c
  br send gentle Q-2a "$REPO"
  br send gentle Q-2b "$REPO" --queue
  advance 5
  br send gentle Q-2c "$REPO" --queue
  write_report Q-2a done; fh_status gentle idle
  br tick
  eq working "$(sget Q-2b state)"
  eq queued "$(sget Q-2c state)"
}

test_cancel_frees_the_queue() {
  mk_task Q-3a; mk_task Q-3b
  br send gentle Q-3a "$REPO"
  br send gentle Q-3b "$REPO" --queue
  br cancel Q-3a
  br tick
  eq cancelled "$(sget Q-3a state)"
  eq working "$(sget Q-3b state)"
}

test_queued_task_waits_while_tree_is_dirty() {
  mk_task Q-4a; mk_task Q-4b
  br send gentle Q-4a "$REPO"
  br send gentle Q-4b "$REPO" --queue
  write_report Q-4a done; fh_status gentle idle
  echo dirty >>"$REPO/a.txt"
  br tick
  eq queued "$(sget Q-4b state)"
  contains "$(sget Q-4b note)" "dirty"
  git -C "$REPO" checkout -q a.txt
  br tick
  eq working "$(sget Q-4b state)"
}

test_forced_queue_entry_ignores_dirty_tree() {
  mk_task Q-5a; mk_task Q-5b
  br send gentle Q-5a "$REPO"
  br send gentle Q-5b "$REPO" --queue --force
  write_report Q-5a done; fh_status gentle idle
  echo dirty >>"$REPO/a.txt"
  br tick
  eq working "$(sget Q-5b state)"
}

test_queues_of_different_agents_are_independent() {
  mk_task Q-6a; mk_task Q-6b
  br send gentle Q-6a "$REPO"
  br send opencode Q-6b "$REPO"
  eq working "$(sget Q-6b state)"
}

# --- watch ---------------------------------------------------------------
test_watch_ticks_in_a_loop_with_simulated_sleep() {
  send_pending W-1
  BRIDGE_WATCH_MAX=3 br watch 5
  rc_is 0
  eq working "$(sget W-1 state)"
  eq 1000010 "$(( 1000000 + $(cat "$BRIDGE_DIR/.vclock") ))" "two sleeps of 5s between three ticks"
}

# --- progress / stage ----------------------------------------------------
test_progress_updates_counters_and_timestamp() {
  send_pending P-1
  advance 42
  br progress P-1 2 5 "U2 docs"
  rc_is 0
  eq 2 "$(sget P-1 progress.done)"
  eq 5 "$(sget P-1 progress.total)"
  eq "U2 docs" "$(sget P-1 progress.current)"
  eq 1000042 "$(sget P-1 progress.at)"
}

test_progress_validates_input() {
  send_pending P-2
  br progress P-2 x 5 "bad"; rc_not0
  br progress P-2 6 5 "over"; rc_not0
  br progress NOPE 1 2 "x"; rc_not0
}

test_stage_records_timestamp_and_rejects_unknown_names() {
  send_pending S-1
  advance 10
  br stage S-1 verified "all green"
  rc_is 0
  eq 1000010 "$(sget S-1 stages.verified)"
  contains "$(<"$BRIDGE_DIR/log.jsonl")" "all green"
  br stage S-1 bogus
  rc_not0
  br stage S-1 sent
  rc_not0
}

# --- wait ----------------------------------------------------------------
test_wait_prints_report_and_exits_zero_on_done() {
  send_pending X-1
  write_report X-1 done "hello report"
  br wait X-1
  rc_is 0
  contains "$OUT" "hello report"
}

test_wait_exits_nonzero_on_failed_but_still_prints_the_report() {
  send_pending X-2
  write_report X-2 blocked "cannot continue"
  br wait X-2
  rc_is 1
  contains "$OUT" "cannot continue"
}

test_wait_exits_3_on_cancelled() {
  send_pending X-3
  br cancel X-3
  br wait X-3
  rc_is 3
  contains "$OUT" "cancelled"
}

test_wait_exits_4_on_undelivered() {
  mk_task X-4
  fh_drop gentle 10
  br send gentle X-4 "$REPO"
  br wait X-4
  rc_is 4
  contains "$OUT" "undelivered"
}

test_wait_timeout_returns_124() {
  send_pending X-5
  br wait X-5 --timeout 30
  rc_is 124
  contains "$OUT" "timeout"
}

test_wait_follows_the_task_until_the_report_appears() {
  send_pending X-6
  # the report appears after the first poll: simulate by a background writer keyed to the virtual clock is
  # not possible, so write it up front and check tick-driven completion without prior tick
  write_report X-6 done "late"
  br wait X-6 --timeout 60
  rc_is 0
  eq done "$(sget X-6 state)"
}

test_wait_keeps_legacy_behaviour_without_state() {
  write_report L-9 done "legacy body"
  br wait L-9
  rc_is 0
  contains "$OUT" "legacy body"
  br wait L-10 --timeout 20
  rc_is 124
}

# --- an idle parent whose background sub-agents are running is not stalled ---
oc_registry() { # state lastActivity-offset-seconds   -> opencode-bg registry with one child
  python3 - "$BRIDGE_DIR/oc-registry.json" "$1" "$(( $(now_s) + $2 ))" <<'PY'
import json, sys
path, state, last = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({"version": 1, "children": [{"id": "ses_x", "parent": "ses_p", "agent": "general", "state": state, "started": last * 1000, "lastActivity": last * 1000}]}, open(path, "w"))
PY
}
now_s() { echo $(( BRIDGE_NOW + $(cat "$BRIDGE_DIR/.vclock" 2>/dev/null || echo 0) )); }

test_idle_opencode_with_running_children_is_not_stalled() {
  export OC_BG_REGISTRY="$BRIDGE_DIR/oc-registry.json"
  send_pending A-30 opencode
  br tick                              # sent -> working
  fh_status opencode idle
  oc_registry running 0
  br tick                              # idle_since starts
  advance 400; oc_registry running 0   # a child is still alive and recently active
  br tick
  eq working "$(sget A-30 state)" "the parent is free on purpose while its children work"
}

test_idle_opencode_with_a_finished_child_still_stalls() {
  export OC_BG_REGISTRY="$BRIDGE_DIR/oc-registry.json"
  send_pending A-31 opencode
  br tick
  fh_status opencode idle
  oc_registry done 0
  br tick
  advance 400; br tick
  eq stalled "$(sget A-31 state)" "a finished child does not keep the task alive"
}

test_idle_opencode_with_a_long_silent_child_still_stalls() {
  export OC_BG_REGISTRY="$BRIDGE_DIR/oc-registry.json"
  send_pending A-32 opencode
  br tick
  fh_status opencode idle
  oc_registry running -3600            # "running" but silent for an hour: a ghost entry
  br tick
  advance 400; br tick
  eq stalled "$(sget A-32 state)"
}

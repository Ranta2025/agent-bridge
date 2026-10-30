# B14 - the bridge opens the agent in a new herdr workspace when it is not open in the task's repository, and closes
# that workspace when the task ends (so each task starts with a clean context). Agents the user opened are never closed.

b14_setup() { # no agent open; auto-open on
  rm -rf "$FAKE_HERDR_DIR/agents"/*
  export BRIDGE_AUTO_OPEN=1
}
owned() { echo "$BRIDGE_DIR/state/owned/$1"; }
closed_ws() { [[ -f "$FAKE_HERDR_DIR/closed" ]] && tr '\n' ' ' <"$FAKE_HERDR_DIR/closed" || true; }
ws_count() { cat "$FAKE_HERDR_DIR/ws.count" 2>/dev/null || echo 0; }

test_send_without_an_agent_opens_a_new_workspace_and_delivers() {
  b14_setup
  mk_task B14-1
  br send gentle B14-1 "$REPO" --no-confirm
  rc_is 0
  contains "$OUT" "sent B14-1 to gentle"
  eq 1 "$(ws_count)"
  contains "$(<"$FAKE_HERDR_DIR/ws.log")" "--label gentle-repo"
  contains "$(<"$FAKE_HERDR_DIR/ws.log")" "--no-focus"
  contains "$(<"$FAKE_HERDR_DIR/ws.log")" "pane run w1:p1 gentle-shell"
  eq w1:p1 "$(sget B14-1 pane)"
  eq 1 "$(fh_prompts w1_p1)"
}

test_the_owned_file_records_the_pane_and_the_task() {
  b14_setup
  mk_task B14-2
  br send opencode B14-2 "$REPO" --no-confirm
  rc_is 0
  local f; f="$(<"$(owned w1_p1)")"
  contains "$f" "pane=w1:p1"
  contains "$f" "workspace=w1"
  contains "$f" "agent=opencode"
  contains "$f" "repo=$REPO"
  contains "$f" "task=B14-2"
  contains "$(<"$FAKE_HERDR_DIR/ws.log")" "pane run w1:p1 opencode"
}

test_a_finished_task_closes_its_workspace_on_the_next_tick() {
  b14_setup
  mk_task B14-3
  br send gentle B14-3 "$REPO" --no-confirm
  br tick
  eq working "$(sget B14-3 state)"
  br tick
  eq "" "$(closed_ws)" "the task is still open"
  has_file "$(owned w1_p1)"
  write_report B14-3 done
  fh_status w1_p1 idle
  br tick
  eq done "$(sget B14-3 state)"
  eq "w1 " "$(closed_ws)"
  no_file "$(owned w1_p1)"
  eq "" "$(fh_dir w1_p1)"
}

test_a_done_task_whose_agent_is_still_working_is_reaped_later() {
  b14_setup
  mk_task B14-4
  br send gentle B14-4 "$REPO" --no-confirm
  br tick
  write_report B14-4 done
  br tick
  eq done "$(sget B14-4 state)"
  eq "" "$(closed_ws)" "the agent is still writing"
  has_file "$(owned w1_p1)"
  fh_status w1_p1 idle
  br tick
  eq "w1 " "$(closed_ws)"
  no_file "$(owned w1_p1)"
}

test_a_pane_the_bridge_did_not_open_is_never_closed() {
  mk_task B14-5
  export BRIDGE_AUTO_OPEN=1
  br send gentle B14-5 "$REPO" --no-confirm
  rc_is 0
  eq wR:p1 "$(sget B14-5 pane)"
  write_report B14-5 done
  fh_status gentle idle
  br tick
  eq done "$(sget B14-5 state)"
  eq 0 "$(ws_count)"
  eq "" "$(closed_ws)"
  [[ -n "$(fh_dir gentle)" ]] || fail "the user's agent was closed"
  # even an owned file that points at the user's workspace is only closed through its own recorded workspace
  mkdir -p "$BRIDGE_DIR/state/owned"
  br tick
  eq "" "$(closed_ws)"
}

test_auto_open_disabled_keeps_the_old_error() {
  b14_setup
  export BRIDGE_AUTO_OPEN=0
  mk_task B14-6
  br send gentle B14-6 "$REPO" --no-confirm
  rc_not0
  contains "$OUT" "no gentle pane is open"
  eq 0 "$(ws_count)"
}

test_dry_run_says_it_would_open_and_opens_nothing() {
  b14_setup
  mk_task B14-7
  br send gentle B14-7 "$REPO" --dry-run
  rc_is 0
  contains "$OUT" "dry-run: would open a new gentle workspace for $REPO"
  eq 0 "$(ws_count)"
  no_file "$BRIDGE_DIR/state/B14-7.json"
}

test_open_timeout_closes_what_it_created_and_fails() {
  b14_setup
  export FAKE_HERDR_NO_START=1 BRIDGE_OPEN_TIMEOUT_S=10
  mk_task B14-8
  br send gentle B14-8 "$REPO" --no-confirm
  rc_not0
  contains "$OUT" "did not become idle"
  eq "w1 " "$(closed_ws)"
  [[ -z "$(fd -t f . "$BRIDGE_DIR/state/owned" 2>/dev/null)" ]] || fail "owned file left behind"
  no_file "$BRIDGE_DIR/state/B14-8.json"
}

test_a_second_task_opens_a_fresh_workspace() {
  b14_setup
  mk_task B14-9a
  br send gentle B14-9a "$REPO" --no-confirm
  br tick
  write_report B14-9a done
  fh_status w1_p1 idle
  br tick
  mk_task B14-9b
  br send gentle B14-9b "$REPO" --no-confirm
  rc_is 0
  eq 2 "$(ws_count)"
  eq "w1 " "$(closed_ws)"
  eq w2:p1 "$(sget B14-9b pane)"
  contains "$(<"$(owned w2_p1)")" "task=B14-9b"
}

test_a_queued_task_with_no_pane_opens_one() {
  b14_setup
  mk_task B14-10
  python3 -I "$ST" enqueue B14-10 gentle "$REPO" "" 0
  br tick
  eq 1 "$(ws_count)"
  eq w1:p1 "$(sget B14-10 pane)"
  contains "$(<"$(owned w1_p1)")" "task=B14-10"
}

test_a_pane_that_never_got_a_task_is_closed_after_the_grace_period() {
  b14_setup
  mkdir -p "$BRIDGE_DIR/state/owned"
  "$BRIDGE_HERDR" workspace create --cwd "$REPO" --label x >/dev/null
  "$BRIDGE_HERDR" pane run w1:p1 gentle-shell >/dev/null
  printf 'pane=w1:p1\nworkspace=w1\nagent=gentle\nrepo=%s\nopened=%s\n' "$REPO" 1000000 >"$(owned w1_p1)"
  br tick
  eq "" "$(closed_ws)" "too early: it may be opening"
  advance 100
  br tick
  eq "" "$(closed_ws)" "still inside the grace period (it must outlast the 90 s opening timeout)"
  advance 81
  br tick
  eq "w1 " "$(closed_ws)"
  no_file "$(owned w1_p1)"
}

test_watch_stays_alive_while_a_finished_owned_agent_is_still_busy() {
  b14_setup
  mk_task B14-12
  br send gentle B14-12 "$REPO" --no-confirm
  br tick
  write_report B14-12 done
  br tick
  eq done "$(sget B14-12 state)"
  has_file "$(owned w1_p1)"
  br watch 1 --until-idle 5
  rc_is 0
  eq "" "$(closed_ws)" "still busy: nothing closed"
  # the watcher gave up after the bounded wait; it did not exit at the plain idle limit
  [[ "$(($(cat "$BRIDGE_DIR/.vclock") ))" -ge 300 ]] || fail "watch exited before BRIDGE_REAP_WAIT_S"
}

test_a_finished_agent_the_bridge_opened_is_never_reused_even_if_closing_it_failed() {
  b14_setup
  mk_task B14-13a
  br send gentle B14-13a "$REPO" --no-confirm
  br tick
  write_report B14-13a done
  fh_status w1_p1 idle
  FAKE_HERDR_CLOSE_FAILS=1 br tick
  [[ -f "$(owned w1_p1)" ]] || fail "the finished owned agent should still be recorded"
  mk_task B14-13b
  FAKE_HERDR_CLOSE_FAILS=1 br send gentle B14-13b "$REPO" --no-confirm
  rc_is 0
  eq 2 "$(ws_count)"
  eq w2:p1 "$(sget B14-13b pane)"
}

test_a_workspace_the_user_already_closed_is_forgotten_even_if_close_fails() {
  b14_setup
  mk_task B14-14
  br send gentle B14-14 "$REPO" --no-confirm
  br tick
  write_report B14-14 done
  fh_status w1_p1 idle
  rm -rf "$FAKE_HERDR_DIR/workspaces/w1"   # the user closed it by hand
  FAKE_HERDR_CLOSE_FAILS=1 br tick
  [[ ! -f "$(owned w1_p1)" ]] || fail "a workspace that no longer exists must not stay recorded"
}

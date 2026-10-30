# B01 - state core and fake herdr.

test_fake_herdr_get_and_list_shapes() {
  run "$BRIDGE_HERDR" agent get gentle
  rc_is 0
  eq idle "$(echo "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["agent"]["agent_status"])')"
  run "$BRIDGE_HERDR" agent list
  eq 2 "$(echo "$OUT" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["result"]["agents"]))')"
  run "$BRIDGE_HERDR" agent get nobody
  rc_not0
}

test_fake_herdr_prompt_drop_keys_rename() {
  "$BRIDGE_HERDR" agent prompt gentle "hello" >/dev/null
  eq working "$(fh_dir gentle | xargs -I{} cat {}/status)"
  eq 1 "$(fh_prompts gentle)"
  fh_status gentle idle
  fh_drop gentle 1
  "$BRIDGE_HERDR" agent prompt gentle "lost" >/dev/null
  eq idle "$(cat "$(fh_dir gentle)/status")" "dropped prompt must not start work"
  "$BRIDGE_HERDR" agent prompt gentle "again" >/dev/null
  eq working "$(cat "$(fh_dir gentle)/status")"
  "$BRIDGE_HERDR" agent send-keys gentle esc >/dev/null
  eq idle "$(cat "$(fh_dir gentle)/status")"
  eq "esc " "$(fh_keys gentle)"
  "$BRIDGE_HERDR" agent rename wS:p1 oc2 >/dev/null
  run "$BRIDGE_HERDR" agent get oc2
  rc_is 0
}

test_state_mark_sent_writes_full_schema() {
  python3 -I "$ST" mark-sent T-1 gentle "$REPO" abc123 "A title"
  valid_json "$BRIDGE_DIR/state/T-1.json"
  keys="$(python3 -c 'import json,sys;print(",".join(json.load(open(sys.argv[1]))))' "$BRIDGE_DIR/state/T-1.json")"
  eq "id,agent,repo,base,state,title,kind,created,sent,started,done,attempts,deliver_tries,last_prompt,idle_since,force,progress,stages,summary,note,approvals,refusals,approval" "$keys"
  eq sent "$(sget T-1 state)"
  eq 1000000 "$(sget T-1 sent)"
  eq 1 "$(sget T-1 attempts)"
  eq T "$(sget T-1 kind)"
  eq 1000000 "$(sget T-1 stages.sent)"
}

test_state_set_get_dotted_keys_and_types() {
  python3 -I "$ST" mark-sent T-2 gentle "$REPO" abc ""
  python3 -I "$ST" set T-2 progress.done=2 progress.total=5 "progress.current=U2 docs" note=hello
  eq 2 "$(sget T-2 progress.done)"
  eq "U2 docs" "$(sget T-2 progress.current)"
  eq hello "$(sget T-2 note)"
  run python3 -I "$ST" set T-2 state=done
  rc_not0 "state must change through transition only"
}

test_state_write_is_atomic_when_killed_mid_write() {
  python3 -I "$ST" mark-sent T-3 gentle "$REPO" abc ""
  before="$(<"$BRIDGE_DIR/state/T-3.json")"
  BRIDGE_TEST_CRASH_BEFORE_REPLACE=1 run python3 -I "$ST" set T-3 note=half
  rc_is 9
  valid_json "$BRIDGE_DIR/state/T-3.json"
  eq "$before" "$(<"$BRIDGE_DIR/state/T-3.json")" "original survives a crash"
  python3 -I "$ST" set T-3 note=ok
  eq ok "$(sget T-3 note)"
}

test_transition_updates_state_and_appends_log() {
  python3 -I "$ST" mark-sent T-4 gentle "$REPO" abc ""
  advance 50
  python3 -I "$ST" transition T-4 working
  eq working "$(sget T-4 state)"
  python3 -I "$ST" transition T-4 done "finished"
  eq 1000050 "$(sget T-4 done)" "done stamped with simulated time"
  lines="$(wc -l <"$BRIDGE_DIR/log.jsonl" | tr -d ' ')"
  eq 3 "$lines" "created + 2 transitions"
  last="$(tail -n1 "$BRIDGE_DIR/log.jsonl")"
  eq done "$(echo "$last" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["to"])')"
  eq T-4 "$(echo "$last" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
  eq 1000050 "$(echo "$last" | python3 -c 'import json,sys;print(json.load(sys.stdin)["ts"])')"
}

test_invalid_transition_is_rejected() {
  python3 -I "$ST" mark-sent T-5 gentle "$REPO" abc ""
  python3 -I "$ST" transition T-5 done
  run python3 -I "$ST" transition T-5 working
  rc_not0
  eq done "$(sget T-5 state)"
}

test_every_log_line_is_valid_json() {
  python3 -I "$ST" mark-sent T-6 gentle "$REPO" abc ""
  python3 -I "$ST" log T-6 custom '{"x":1}'
  python3 -I "$ST" log T-6 other
  python3 -c 'import json,sys
for l in open(sys.argv[1]): json.loads(l)' "$BRIDGE_DIR/log.jsonl" || fail "bad log line"
}

test_rejects_unsafe_ids() {
  run python3 -I "$ST" mark-sent '../evil' gentle "$REPO" abc ""
  rc_not0
  no_file "$T/evil.json"
}

test_virtual_clock_sleep_advances_time() {
  # shellcheck source=/dev/null
  source "$ROOT/v2/lib/state.sh"
  eq 1000000 "$(now)"
  bsleep 7
  eq 1000007 "$(now)"
}

test_missing_state_reports_error() {
  run python3 -I "$ST" get NOPE state
  rc_not0
}

# B02 - new, lint, send (guards, delivery confirmation, queue), resend, cancel.

sent_state() { sget "$1" state; }

# --- lint ---------------------------------------------------------------
test_lint_accepts_a_valid_task() {
  mk_task L-1
  br lint L-1
  rc_is 0
}

test_lint_rejects_missing_surfaces_section() {
  mk_task L-2
  python3 - "$BRIDGE_DIR/inbox/L-2.md" <<'PY'
import sys,re
p=sys.argv[1]; t=open(p).read()
open(p,"w").write(t.replace("## Allowed edit surfaces","## Something else"))
PY
  br lint L-2
  rc_not0
  contains "$OUT" "Allowed edit surfaces"
}

test_lint_rejects_absolute_and_dot_surfaces() {
  mk_task L-3
  python3 - "$BRIDGE_DIR/inbox/L-3.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,"w").write(t.replace("a.txt\n","/etc/passwd\n.\n"))
PY
  br lint L-3
  rc_not0
  contains "$OUT" "/etc/passwd"
  contains "$OUT" "'.'"
}

test_lint_rejects_unreplaced_template_placeholder() {
  br new L-4 --repo "$REPO" --title "fresh"
  rc_is 0
  has_file "$BRIDGE_DIR/inbox/L-4.md"
  br lint L-4
  rc_not0
  contains "$OUT" "TODO"
}

test_lint_rejects_missing_subagent_instruction() {
  mk_task L-5
  python3 - "$BRIDGE_DIR/inbox/L-5.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,"w").write(t.replace("sub-agents","helpers"))
PY
  br lint L-5
  rc_not0
  contains "$OUT" "sub-agent"
}

test_lint_rejects_missing_report_path_and_section() {
  mk_task L-6
  python3 - "$BRIDGE_DIR/inbox/L-6.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,"w").write(t.replace("outbox/L-6.md","elsewhere.md"))
PY
  br lint L-6
  rc_not0
  contains "$OUT" "outbox/L-6.md"
  mk_task L-7
  python3 - "$BRIDGE_DIR/inbox/L-7.md" <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
open(p,"w").write(t.replace("## Report","## Notes"))
PY
  br lint L-7
  rc_not0
  contains "$OUT" "Report"
}

test_lint_missing_task_file() {
  br lint NOPE
  rc_not0
}

# --- new ----------------------------------------------------------------
test_new_creates_template_and_refuses_overwrite() {
  br new N-1 --repo "$REPO" --title "My title"
  rc_is 0
  body="$(<"$BRIDGE_DIR/inbox/N-1.md")"
  contains "$body" "# Task N-1 - My title"
  contains "$body" "bridge:repo=$REPO"
  contains "$body" "$BRIDGE_DIR/outbox/N-1.md"
  not_contains "$body" "{{"
  br new N-1
  rc_not0
}

# --- send ---------------------------------------------------------------
test_send_confirms_delivery_and_keeps_sent_file_format() {
  mk_task S-1
  br send gentle S-1 "$REPO"
  rc_is 0
  contains "$OUT" "sent S-1 to gentle"
  eq working "$(sent_state S-1)"
  eq 1 "$(sget S-1 attempts)"
  eq 1 "$(fh_prompts gentle)"
  eq "gentle 1000000" "$(<"$BRIDGE_DIR/inbox/S-1.sent")" "legacy .sent format"
  contains "$(<"$(fh_dir gentle)/prompts")" "[bridge S-1] Lee y ejecuta las instrucciones de $BRIDGE_DIR/inbox/S-1.md"
  eq "$(git -C "$REPO" rev-parse HEAD)" "$(sget S-1 base)"
  eq "sample" "$(sget S-1 title)"
}

test_send_retries_twice_then_marks_undelivered() {
  mk_task S-2
  fh_drop gentle 10
  br send gentle S-2 "$REPO"
  rc_is 6
  eq undelivered "$(sent_state S-2)"
  eq 3 "$(fh_prompts gentle)" "first prompt + 2 retries"
  eq 3 "$(sget S-2 attempts)"
  contains "$(<"$BRIDGE_DIR/log.jsonl")" '"to": "undelivered"'
}

test_send_delivered_on_first_retry() {
  mk_task S-3
  fh_drop gentle 1
  br send gentle S-3 "$REPO"
  rc_is 0
  eq working "$(sent_state S-3)"
  eq 2 "$(fh_prompts gentle)"
  eq 2 "$(sget S-3 attempts)"
}

test_send_refuses_when_agent_busy() {
  mk_task S-4
  fh_status gentle working
  br send gentle S-4 "$REPO"
  rc_is 3
  contains "$OUT" "--queue"
  no_file "$BRIDGE_DIR/state/S-4.json"
  eq 0 "$(fh_prompts gentle)"
}

test_send_queues_when_agent_has_an_open_task() {
  mk_task S-5a; mk_task S-5b
  br send gentle S-5a "$REPO"
  rc_is 0
  br send gentle S-5b "$REPO" --queue
  rc_is 0
  contains "$OUT" "queued S-5b"
  eq queued "$(sent_state S-5b)"
  eq 1 "$(fh_prompts gentle)" "queued task is not sent"
  no_file "$BRIDGE_DIR/inbox/S-5b.sent"
}

test_send_refuses_second_task_when_state_has_open_task_even_if_agent_looks_idle() {
  mk_task S-6a; mk_task S-6b
  br send gentle S-6a "$REPO"
  fh_status gentle idle
  br send gentle S-6b "$REPO"
  rc_is 3
  contains "$OUT" "S-6a"
}

test_send_refuses_dirty_tree_unless_forced() {
  mk_task S-7
  echo two >>"$REPO/a.txt"
  br send gentle S-7 "$REPO"
  rc_is 4
  contains "$OUT" "uncommitted"
  eq 0 "$(fh_prompts gentle)"
  br send gentle S-7 "$REPO" --force
  rc_is 0
  eq working "$(sent_state S-7)"
}

test_send_dry_run_changes_nothing() {
  mk_task S-8
  br send gentle S-8 "$REPO" --dry-run
  rc_is 0
  contains "$OUT" "dry-run"
  no_file "$BRIDGE_DIR/state/S-8.json"
  no_file "$BRIDGE_DIR/inbox/S-8.sent"
  eq 0 "$(fh_prompts gentle)"
}

test_send_runs_lint_first() {
  printf '# bad\n' >"$BRIDGE_DIR/inbox/S-9.md"
  br send gentle S-9 "$REPO"
  rc_is 5
  eq 0 "$(fh_prompts gentle)"
  no_file "$BRIDGE_DIR/state/S-9.json"
}

test_send_refuses_agent_in_another_project() {
  mk_task S-10
  other="$T/other"; git init -q "$other"
  fh_add gentle wR:p1 pi "$other" idle
  br send gentle S-10 "$REPO"
  rc_not0
  contains "$OUT" "another project's pane"
  eq 0 "$(fh_prompts gentle)"
}

test_send_unknown_agent_fails_cleanly() {
  mk_task S-11
  br send ghost S-11 "$REPO"
  rc_not0
  contains "$OUT" "no ghost pane is open"
}

test_send_removes_stale_report_of_an_untracked_task() {
  mk_task S-12
  write_report S-12 done
  br send gentle S-12 "$REPO"
  rc_is 0
  no_file "$BRIDGE_DIR/outbox/S-12.md"
}

test_send_rejects_already_queued_or_open_id() {
  mk_task S-13
  br send gentle S-13 "$REPO"
  br send opencode S-13 "$REPO"
  rc_is 3
  contains "$OUT" "already"
}

test_send_takes_repo_from_task_header_then_cwd() {
  mk_task S-14
  cd "$T" && br send gentle S-14
  rc_is 0
  eq "$REPO" "$(sget S-14 repo)"
}

# --- resend / cancel ----------------------------------------------------
test_resend_increments_attempts_and_keeps_history() {
  mk_task R-1
  fh_drop gentle 10
  br send gentle R-1 "$REPO"
  eq undelivered "$(sent_state R-1)"
  fh_drop gentle 0
  fh_status gentle idle
  br resend R-1
  rc_is 0
  eq 4 "$(sget R-1 attempts)"
  eq working "$(sent_state R-1)"
  lines="$(wc -l <"$BRIDGE_DIR/log.jsonl" | tr -d ' ')"
  [[ "$lines" -ge 6 ]] || fail "history kept in the log ($lines lines)"
}

test_resend_moves_the_failed_report_aside() {
  mk_task R-2
  br send gentle R-2 "$REPO"
  write_report R-2 blocked
  python3 -I "$ST" transition R-2 failed
  fh_status gentle idle
  br resend R-2
  rc_is 0
  no_file "$BRIDGE_DIR/outbox/R-2.md"
  has_file "$BRIDGE_DIR/outbox/R-2.attempt1.md"
}

test_resend_refuses_running_or_done_tasks() {
  mk_task R-3
  br send gentle R-3 "$REPO"
  br resend R-3
  rc_not0
  python3 -I "$ST" transition R-3 done
  br resend R-3
  rc_not0
}

test_resend_refuses_when_agent_is_busy() {
  mk_task R-4a; mk_task R-4b
  fh_drop gentle 10
  br send gentle R-4a "$REPO"
  eq undelivered "$(sent_state R-4a)"
  fh_drop gentle 0
  br send gentle R-4b "$REPO"
  br resend R-4a
  rc_is 3
}

test_cancel_sends_escape_and_marks_cancelled() {
  mk_task C-1
  br send gentle C-1 "$REPO"
  br cancel C-1
  rc_is 0
  eq "esc " "$(fh_keys gentle)"
  eq cancelled "$(sent_state C-1)"
  neq 0 "$(sget C-1 done)"
}

test_cancel_queued_task_does_not_touch_the_agent() {
  mk_task C-2a; mk_task C-2b
  br send gentle C-2a "$REPO"
  br send gentle C-2b "$REPO" --queue
  br cancel C-2b
  rc_is 0
  eq "" "$(fh_keys gentle)"
  eq cancelled "$(sent_state C-2b)"
  eq working "$(sent_state C-2a)"
}

test_cancel_rejects_finished_and_unknown_tasks() {
  mk_task C-3
  br send gentle C-3 "$REPO"
  python3 -I "$ST" transition C-3 done
  br cancel C-3
  rc_not0
  br cancel NOPE
  rc_not0
}

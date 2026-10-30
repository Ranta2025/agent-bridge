# B11 - the REAL opencode dialog: no title line, wrapped command rows, heredoc bodies, compound commands.

REAL="$TESTS/fixtures/opencode_permission_real_bash_heredoc.txt"

arm_job() { # id fixture  -> active opencode job whose pane shows the fixture; Enter clears the screen
  mk_task "$1"
  br send opencode "$1" "$REPO" --no-confirm
  oc_screen_file opencode "$2"
  on_enter opencode clear
}

test_real_capture_is_allowed() {
  br approve test --file "$REAL"
  rc_is 0
  contains "$OUT" "ALLOW"
}

test_approve_once_on_the_real_capture_prints_allow_and_presses_enter_once() {
  arm_job R-1 "$REAL"
  br approve-once
  rc_is 0
  contains "$OUT" "ALLOW"
  eq "enter " "$(fh_keys opencode)"
  eq 1 "$(log_count auto_approved)"
  contains "$(log_last auto_approved)" '"tool": "bash"'
  not_contains "$(log_last auto_approved)" 'unknown'
}

test_tick_approves_the_real_capture() {
  arm_job R-2 "$REAL"
  br tick
  eq "enter " "$(fh_keys opencode)"
}

test_real_shaped_fixtures_decide_as_expected() {
  F="$TESTS/fixtures"
  for f in real_commit_oneliner real_docker_compose real_rg_readonly real_heredoc_push_words; do
    br approve test --file "$F/$f.txt"
    rc_is 0 "$f"
    contains "$OUT" "ALLOW" "$f"
  done
  br approve test --file "$F/real_compound_push.txt"
  rc_is 1; contains "$OUT" "REFUSE"; contains "$OUT" "git push"
  br approve test --file "$F/real_cut_ellipsis.txt"
  rc_is 1; contains "$OUT" "REFUSE"; contains "$OUT" "truncated"
  br approve test --file "$F/real_heredoc_unterminated_cat.txt"
  rc_is 1; contains "$OUT" "REFUSE"; contains "$OUT" "truncated command"
}

test_heredoc_body_is_data_but_the_command_before_it_is_not() {
  mk_dlg() { printf '%s\n' "  ┃  △ Permission required" "  ┃" "  ┃  \$ $1" "$2" "  ┃" "  ┃  Allow once   Always allow   Reject   ctrl+f fullscreen  ⇆ select  enter confirm" >"$T/d.txt"; }
  # push words inside the body of a complete heredoc: allowed
  mk_dlg "git commit -q -F - <<'MSG'" "$(printf '  ┃  git push and sudo rm -rf / only words\n  ┃  MSG')"
  br approve test --file "$T/d.txt"; rc_is 0
  # the same words after the terminator are commands again
  mk_dlg "git commit -q -F - <<MSG" "$(printf '  ┃  hello\n  ┃  MSG\n  ┃  git push origin main')"
  br approve test --file "$T/d.txt"; rc_is 1; contains "$OUT" "git push"
  # a push BEFORE the marker on the same line
  mk_dlg "git push origin main && git commit -F - <<'MSG'" "$(printf '  ┃  x\n  ┃  MSG')"
  br approve test --file "$T/d.txt"; rc_is 1
  # <<- with tab-indented terminator
  mk_dlg "git commit -F - <<-MSG" "$(printf '  ┃  body\n  ┃  MSG')"
  br approve test --file "$T/d.txt"; rc_is 0
  # an unseen terminator on something that is not a commit message
  mk_dlg "cat <<'EOF' > /tmp/x.txt" "$(printf '  ┃  body')"
  br approve test --file "$T/d.txt"; rc_is 1; contains "$OUT" "truncated command"
}

test_compound_commands_need_every_part_to_pass() {
  for c in "cd /home/dev/work/app-worktrees/x && git status" "git add -A && git commit -q -m x" "ls | wc -l; echo done" \
    "bash server/tests/run.sh" "python3 -I -m unittest discover -s tests" "fd -e gd . /home/dev/work/app/app" "bat -p README.md" "eza -la" \
    "mkdir -p /tmp/a/b" "docker compose run --rm content-validator validate" "git log --oneline -3" "git diff --stat" \
    "/home/dev/work/app-worktrees/.bridge/bridge.sh progress F12-T03 1 3 \"U1\"" "/home/dev/work/app-worktrees/.bridge/bridge.sh stage F12-T03 verified"; do
    br approve test "bash|$c"; rc_is 0 "allow: $c"
  done
  for c in "cd /home/dev/work/app && git push" "git status && git push origin main" "git status || sudo reboot" "echo a; git reset --hard" \
    "cd /etc && ls" "cd ~ && ls" "ls | ssh host" "git status & git push" "echo \"\$(git push)\"" 'echo `git push`'; do
    br approve test "bash|$c"; rc_is 1 "refuse: $c"
  done
  # operators inside quotes do not split, and a quoted message without NEVER words is fine
  br approve test 'bash|git commit -q -m "fix: a && b; c | d"'; rc_is 0
}

test_wrapped_rows_are_rejoined_without_trusting_either_guess() {
  mk() { printf '%s\n' "  ┃  △ Permission required" "  ┃" "  ┃  $1" "  ┃  $2" "  ┃" "  ┃  Allow once   Always allow   Reject" >"$T/w.txt"; }
  # a path broken mid-token at the wrap width: joined without space it stays inside the roots
  a='$ git add /home/dev/work/app-worktrees/release/app/src/presentation/steps/'
  mk "$a" "inventory_step.gd"
  br approve test --file "$T/w.txt"; rc_is 0
  # "git pu" + "sh": the no-space reading is a push, so the request is refused
  b='$ cd /home/dev/work/app-worktrees/release && echo aaaaaaaaaaaaaaaaaaaaaaaa && git pu'
  mk "$b" "sh origin main"
  br approve test --file "$T/w.txt"; rc_is 1; contains "$OUT" "git push"
  # a wrap point that hides a path: no-space reading leaves the root
  c='$ ls /home/dev/work/app-worktrees/release/app/src/presentation/stepsssssssssssssssssssss /'
  mk "$c" "etc/passwd"
  br approve test --file "$T/w.txt"; rc_is 1
}

test_titles_are_optional_for_every_tool() {
  F="$TESTS/fixtures"
  br approve test --file "$F/real_edit_without_icon.txt"; rc_is 0; contains "$OUT" "ALLOW"
  br approve test --file "$F/real_read_path_only.txt"; rc_is 1; contains "$OUT" "outside"   # /etc/hosts
  for f in dialog_edit dialog_external dialog_bash dialog_narrow; do
    br approve test --file "$F/$f.txt"; rc_is 0 "$f"
  done
}

test_unrecognised_dialog_is_logged_with_its_rows_and_never_answered() {
  arm_job R-3 "$TESTS/fixtures/real_unrecognised.txt"
  br approve-once
  rc_is 0
  contains "$OUT" "UNRECOGNISED"
  eq "" "$(fh_keys opencode)" "nothing typed"
  eq 1 "$(log_count approval_unrecognised)"
  eq 0 "$(log_count approval_refused)"
  d="$(log_last approval_unrecognised)"
  contains "$d" "Frobnicate the widget"
  contains "$d" "Permission required"
  not_contains "$d" '"tool": "unknown"'
  eq true "$(sget R-3 approval.pending)"
  eq 0 "$(sget R-3 refusals)"
  br tick; br tick
  eq 1 "$(log_count approval_unrecognised)" "debounced"
  br ls --json
  contains "$OUT" '"approval_pending": true'
}

test_unknown_is_never_the_tool_of_a_recognisable_dialog() {
  arm_job R-4 "$TESTS/fixtures/real_compound_push.txt"
  br approve-once
  contains "$(log_last approval_refused)" '"tool": "bash"'
  eq 0 "$(log_count approval_unrecognised)"
  contains "$OUT" "REFUSE"
}

test_wide_gap_in_a_command_row_is_refused() {
  printf '%s\n' "  ┃  △ Permission required" "  ┃" "  ┃  \$ git status            && git push" "  ┃" "  ┃  Allow once   Always allow   Reject" >"$T/g.txt"
  br approve test --file "$T/g.txt"; rc_is 1
}

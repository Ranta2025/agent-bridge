# B12 - the bridge works from any project: the approver's root is the agent's own repository (and its worktrees),
# and `send` explains how to fix a project mismatch.

# The shipped policy without its fixed roots, so that the sandbox under /tmp does not hide a refusal.
proj_policy() {
  rg -v '^root /tmp' "$ROOT/approver.policy" >"$T/proj.policy"
  export APPROVER_POLICY="$T/proj.policy"
}
mk_repo() { # dir
  git init -q "$1"
  echo x >"$1/a.txt"
  git -C "$1" add a.txt
  git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init
}
at() { APPROVER_CWD="$1" br approve test "$2"; }   # cwd "tool|target"

test_project_root_allows_the_agents_repo_and_its_worktrees() {
  proj_policy
  mk_repo "$T/other"
  git -C "$T/other" worktree add -q "$T/other-wt" -b wt
  mkdir -p "$T/other/sub"
  for t in edit write read list; do
    at "$T/other" "$t|$T/other/src/a.ts"; rc_is 0 "$t in the repo"
    at "$T/other" "$t|$T/other-wt/src/a.ts"; rc_is 0 "$t in its worktree"
    at "$T/other-wt" "$t|$T/other/src/a.ts"; rc_is 0 "$t main checkout from a worktree"
    at "$T/other/sub" "$t|$T/other/src/a.ts"; rc_is 0 "$t from a subdirectory of the repo"
  done
  at "$T/other" "bash|cd $T/other-wt && git status && git commit -q -m x"; rc_is 0
  at "$T/other" "external_directory|$T/other-wt/*"; rc_is 0
}

test_project_root_refuses_paths_outside_the_project() {
  proj_policy
  mk_repo "$T/other"
  mkdir -p "$T/other2"
  for t in edit write read list; do
    at "$T/other" "$t|$T/other2/a.txt"; rc_is 1 "$t sibling with a common prefix"
    at "$T/other" "$t|$T/a.txt"; rc_is 1 "$t parent dir"
    at "$T/other" "$t|$T/other/../other2/a.txt"; rc_is 1 "$t dotdot escape"
    at "$T/other" "$t|~/Documentos/a.txt"; rc_is 1 "$t home"
    at "$T/other" "$t|/etc/hosts"; rc_is 1 "$t /etc"
  done
  at "$T/other" "bash|cat $T/other2/a.txt"; rc_is 1
  at "$T/other" "bash|cd /etc && ls"; rc_is 1
  at "$T/other" "external_directory|$T/*"; rc_is 1 "wider than the project"
}

test_project_root_keeps_every_never_rule() {
  proj_policy
  mk_repo "$T/other"
  at "$T/other" "bash|git push origin main"; rc_is 1
  at "$T/other" "bash|git status && git push"; rc_is 1
  at "$T/other" "bash|git reset --hard HEAD~1"; rc_is 1
  at "$T/other" "bash|rm -rf $T/other"; rc_is 1 "the root itself"
  at "$T/other" "read|$T/other/.env"; rc_is 1
  at "$T/other" "edit|$T/other/secrets/a.json"; rc_is 1
  at "$T/other" "write|$T/other/app.keystore"; rc_is 1
  at "$T/other" "read|~/.ssh/config"; rc_is 1
}

test_project_root_needs_a_git_repo() {
  proj_policy
  mkdir -p "$T/plain"
  at "$T/plain" "edit|$T/plain/a.txt"; rc_is 1 "a non-git cwd adds no root"
  at "$T/plain" "bash|ls $T/plain"; rc_is 1
  # explicit roots still apply there
  printf 'root /srv\nroot-project\ntool bash edit\n' >"$T/p2.policy"
  APPROVER_POLICY="$T/p2.policy" at "$T/plain" "bash|ls /srv/x"; rc_is 0
  APPROVER_POLICY="$T/p2.policy" at "$T/plain" "edit|$T/plain/a"; rc_is 1
}

test_bridge_inbox_and_outbox_are_allowed_from_any_project() {
  proj_policy
  mk_repo "$T/other"
  at "$T/other" "write|$BRIDGE_DIR/outbox/B12-1.md"; rc_is 0 "report"
  at "$T/other" "edit|$BRIDGE_DIR/outbox/B12-1.md"; rc_is 0
  at "$T/other" "read|$BRIDGE_DIR/inbox/B12-1.md"; rc_is 0 "task"
  at "$T/other" "list|$BRIDGE_DIR/inbox"; rc_is 0
  at "$T/other" "external_directory|$BRIDGE_DIR/outbox/*"; rc_is 0
  at "$T/other" "bash|cat $BRIDGE_DIR/inbox/B12-1.md"; rc_is 0
  at "$T/other" "bash|printf done > $BRIDGE_DIR/outbox/B12-1.md"; rc_is 0
  at "$T/other" "bash|$BRIDGE_DIR/bridge.sh progress B12-1 1 3 U1"; rc_is 0 "the bridge CLI"
  # nothing else of the data dir
  at "$T/other" "write|$BRIDGE_DIR/state/B12-1.json"; rc_is 1 "state"
  at "$T/other" "edit|$BRIDGE_DIR/approver.policy"; rc_is 1 "policy"
  at "$T/other" "write|$BRIDGE_DIR/approver.mode"; rc_is 1 "mode"
  at "$T/other" "read|$BRIDGE_DIR/log.jsonl"; rc_is 1 "log"
  at "$T/other" "write|$BRIDGE_DIR/outbox/../approver.policy"; rc_is 1 "dotdot"
  at "$T/other" "write|$BRIDGE_DIR/outbox2/x"; rc_is 1 "prefix"
  at "$T/other" "bash|rm -rf $BRIDGE_DIR/outbox"; rc_is 1 "the dir itself"
  at "$T/other" "bash|cat $BRIDGE_DIR/state/B12-1.json"; rc_is 1
  at "$T/other" "bash|$BRIDGE_DIR/other.sh"; rc_is 1 "only the CLI is executable"
}

test_send_explains_a_repo_mismatch() {
  mk_repo "$T/elsewhere"
  echo "$T/elsewhere" >"$(fh_dir opencode)/cwd"
  mk_task B12-2
  br send opencode B12-2 "$REPO" --no-confirm
  rc_not0 "the agent is in another repo"
  contains "$OUT" "no opencode pane is open in '$REPO'"
  contains "$OUT" "opencode is open in '$T/elsewhere'"
  contains "$OUT" "herdr pane split --current --direction right --cwd $REPO"
  contains "$OUT" "right repo"
  eq 0 "$(fh_prompts opencode)"
}

# Two opencode panes in two repositories: the bridge always uses the one of the task's project.
two_panes() {
  REPO_A="$T/repo-a"; REPO_B="$T/repo-b"
  mk_repo "$REPO_A"; mk_repo "$REPO_B"
  rm -rf "$FAKE_HERDR_DIR/agents"; mkdir -p "$FAKE_HERDR_DIR/agents"
  fh_add "" pA:p1 opencode "$REPO_A" idle
  fh_add "" pB:p1 opencode "$REPO_B" idle
}
task_for() { # id repo
  mk_task "$1"; sd "bridge:repo=[^ ]*" "bridge:repo=$2 " "$BRIDGE_DIR/inbox/$1.md"
}
pane_prompts() { local f="$FAKE_HERDR_DIR/agents/$1/prompts"; [[ -f "$f" ]] && wc -l <"$f" | tr -d ' ' || echo 0; }

test_send_uses_the_pane_of_the_tasks_repo() {
  two_panes
  task_for B12-4 "$REPO_B"
  br send opencode B12-4 "$REPO_B" --no-confirm; rc_is 0
  eq 1 "$(pane_prompts pB_p1)"; eq 0 "$(pane_prompts pA_p1)"
  eq pB:p1 "$(sget B12-4 pane)" "the pane is recorded in the task"
  echo idle >"$FAKE_HERDR_DIR/agents/pB_p1/status"
  task_for B12-5 "$REPO_A"
  br send opencode B12-5 "$REPO_A" --no-confirm; rc_is 0
  eq 1 "$(pane_prompts pA_p1)"; eq 1 "$(pane_prompts pB_p1)"
  eq pA:p1 "$(sget B12-5 pane)"
}

test_send_prefers_the_exact_worktree_and_accepts_another_one() {
  two_panes
  git -C "$REPO_A" worktree add -q "$T/wt-a" -b wta
  fh_add "" pW:p1 opencode "$T/wt-a" idle
  task_for B12-6 "$T/wt-a"
  br send opencode B12-6 "$T/wt-a" --no-confirm; rc_is 0
  eq 1 "$(pane_prompts pW_p1)"; eq 0 "$(pane_prompts pA_p1)"
  br cancel B12-6 >/dev/null
  task_for B12-7 "$REPO_A"
  br send opencode B12-7 "$REPO_A" --no-confirm; rc_is 0
  eq 1 "$(pane_prompts pA_p1)"
  # only the worktree pane left: it still serves the repository
  rm -rf "$FAKE_HERDR_DIR/agents/pA_p1"
  echo idle >"$FAKE_HERDR_DIR/agents/pW_p1/status"
  br cancel B12-7 >/dev/null; task_for B12-8 "$REPO_A"
  br send opencode B12-8 "$REPO_A" --no-confirm; rc_is 0
  eq 2 "$(pane_prompts pW_p1)"
}

test_send_without_a_pane_in_the_repo_fails_with_the_hint() {
  two_panes
  mk_repo "$T/repo-c"
  task_for B12-9 "$T/repo-c"
  br send opencode B12-9 "$T/repo-c" --no-confirm
  rc_not0
  contains "$OUT" "no opencode pane is open in '$T/repo-c'"
  contains "$OUT" "herdr pane split --current --direction right --cwd $T/repo-c"
  eq 0 "$(pane_prompts pA_p1)"; eq 0 "$(pane_prompts pB_p1)"
}

test_pane_and_peek_use_the_current_repo() {
  two_panes
  printf 'screen of B\n' >"$FAKE_HERDR_DIR/agents/pB_p1/screen"
  printf 'screen of A\n' >"$FAKE_HERDR_DIR/agents/pA_p1/screen"
  OUT="$(cd "$REPO_B" && "$CLI" pane opencode 2>&1)"; eq pB:p1 "$OUT"
  OUT="$(cd "$REPO_A" && "$CLI" peek opencode 2>&1)"; contains "$OUT" "screen of A"
  OUT="$(cd "$T" && "$CLI" pane opencode 2>&1)"; contains "$OUT" "not a git repository"
}

test_send_explains_a_directory_that_is_not_a_git_repo() {
  mkdir -p "$T/plain"
  mk_task B12-3
  br send opencode B12-3 "$T/plain" --no-confirm
  rc_not0
  contains "$OUT" "$T/plain is not a git repository"
  contains "$OUT" "git init"
  contains "$OUT" "--repo"
}

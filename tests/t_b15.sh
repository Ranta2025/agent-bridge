# B15 - several agents of one kind in one project: a free pane is reused, a busy one never blocks a separate worktree,
# the same worktree needs --parallel with disjoint surfaces, and BRIDGE_MAX_AGENTS caps the agents the bridge opens.

task_in() { # id repo surface...   (a task for <repo> with the given allowed edit surfaces)
  local id="$1" repo="$2"
  shift 2
  {
    printf '# Task %s - sample\n\n<!-- bridge:repo=%s -->\n\nWork with sub-agents when the work is large.\n\n## Allowed edit surfaces\n' "$id" "$repo"
    printf '%s\n' "$@"
    printf '\n## Report\nWrite your final report to %s/outbox/%s.md\n' "$BRIDGE_DIR" "$id"
  } >"$BRIDGE_DIR/inbox/$id.md"
}
mk_worktree() { git -C "$REPO" worktree add -q -b "$1" "$T/$1"; }
b15_busy_first() { # id  -> the first task running in a freshly opened agent of $REPO
  rm -rf "$FAKE_HERDR_DIR/agents"/*
  export BRIDGE_AUTO_OPEN=1
  task_in "$1" "$REPO" a.txt
  br send gentle "$1" "$REPO" --no-confirm
  rc_is 0
  br tick
  eq working "$(sget "$1" state)"
}

test_a_separate_worktree_opens_a_second_agent_while_the_first_is_busy() {
  mk_worktree wt1
  b15_busy_first B15-1a
  task_in B15-1b "$T/wt1" a.txt
  br send gentle B15-1b "$T/wt1" --no-confirm
  rc_is 0
  eq 2 "$(ws_count)"
  eq w1:p1 "$(sget B15-1a pane)"
  eq w2:p1 "$(sget B15-1b pane)"
}

test_the_same_worktree_is_refused_or_queued_without_parallel() {
  b15_busy_first B15-2a
  task_in B15-2b "$REPO" src/**
  br send gentle B15-2b "$REPO" --no-confirm --force
  eq 3 "$RC"
  contains "$OUT" "is busy"
  eq 1 "$(ws_count)"
  br send gentle B15-2b "$REPO" --no-confirm --force --queue
  rc_is 0
  contains "$OUT" "queued B15-2b"
  eq 1 "$(ws_count)"
}

test_parallel_with_disjoint_surfaces_opens_a_second_agent() {
  b15_busy_first B15-3a
  task_in B15-3b "$REPO" src/**
  br send gentle B15-3b "$REPO" --no-confirm --parallel
  rc_is 0
  eq 2 "$(ws_count)"
  eq w2:p1 "$(sget B15-3b pane)"
  contains "$(<"$(owned w2_p1)")" "task=B15-3b"
}

test_parallel_with_overlapping_surfaces_is_refused_naming_the_overlap() {
  b15_busy_first B15-4a
  task_in B15-4b "$REPO" a.txt
  br send gentle B15-4b "$REPO" --no-confirm --parallel
  eq 7 "$RC"
  contains "$OUT" "a.txt overlaps a.txt (task B15-4a)"
  eq 1 "$(ws_count)"
  task_in B15-4c "$REPO" "a.*"
  br send gentle B15-4c "$REPO" --no-confirm --parallel
  eq 7 "$RC"
  contains "$OUT" "a.* overlaps a.txt"
}

test_the_cap_refuses_or_queues_the_extra_agent() {
  mk_worktree wt1; mk_worktree wt2
  export BRIDGE_MAX_AGENTS=2
  b15_busy_first B15-5a
  task_in B15-5b "$T/wt1" a.txt
  br send gentle B15-5b "$T/wt1" --no-confirm
  rc_is 0
  task_in B15-5c "$T/wt2" a.txt
  br send gentle B15-5c "$T/wt2" --no-confirm
  eq 3 "$RC"
  contains "$OUT" "BRIDGE_MAX_AGENTS=2"
  eq 2 "$(ws_count)"
  br send gentle B15-5c "$T/wt2" --no-confirm --queue
  rc_is 0
  contains "$OUT" "queued B15-5c"
  eq queued "$(sget B15-5c state)"
  eq 2 "$(ws_count)"
}

test_a_free_user_opened_pane_is_preferred_over_opening() {
  export BRIDGE_AUTO_OPEN=1
  task_in B15-6 "$REPO" a.txt
  br send gentle B15-6 "$REPO" --no-confirm
  rc_is 0
  eq wR:p1 "$(sget B15-6 pane)"
  eq 0 "$(ws_count)"
  # the user's pane is now busy with B15-6: another task in a separate worktree opens a new agent, never touches wR
  mk_worktree wt1
  task_in B15-6b "$T/wt1" a.txt
  br send gentle B15-6b "$T/wt1" --no-confirm
  rc_is 0
  eq w1:p1 "$(sget B15-6b pane)"
  write_report B15-6 done
  fh_status gentle idle
  br tick
  eq "" "$(closed_ws)" "the user's pane is never closed"
  [[ -n "$(fh_dir gentle)" ]] || fail "the user's agent was closed"
}

py_overlap() { # a-entries b-entries (comma separated)  -> prints the overlapping pairs
  python3 -I -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("st", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.surfaces_overlap(sys.argv[2].split(","), sys.argv[3].split(",")))' "$ST" "$1" "$2"
}

test_surfaces_overlap_unit() {
  eq "[('a.txt', 'a.txt')]" "$(py_overlap a.txt a.txt)"
  eq "[]" "$(py_overlap a.txt b.txt)"
  eq "[('src/**', 'src/a.js')]" "$(py_overlap 'src/**' src/a.js)"
  eq "[('src/**', 'src/lib/*.js')]" "$(py_overlap 'src/**' 'src/lib/*.js')"
  eq "[]" "$(py_overlap 'src/**' 'docs/**')"
  eq "[]" "$(py_overlap 'src/a/*.js' 'src/b/*.js')"
  eq "[('*.md', 'docs/x.md')]" "$(py_overlap '*.md' docs/x.md)"
}

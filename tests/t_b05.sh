# B05 - migration of legacy inbox/outbox into state/, and compatibility of the installed bridge.sh.

legacy_fixture() {
  printf '# old task\n' >"$BRIDGE_DIR/inbox/M-1.md"; echo "gentle 999000" >"$BRIDGE_DIR/inbox/M-1.sent"
  printf '# Report\n\nEstado: completado\n' >"$BRIDGE_DIR/outbox/M-1.md"
  printf '# old task\n' >"$BRIDGE_DIR/inbox/M-2.md"; echo "gentle 999500" >"$BRIDGE_DIR/inbox/M-2.sent"
  printf '# old task\n' >"$BRIDGE_DIR/inbox/M-3.md"; echo "opencode 998000" >"$BRIDGE_DIR/inbox/M-3.sent"
  printf '# Report\n\nStatus: blocked\n' >"$BRIDGE_DIR/outbox/M-3.md"
  printf '# Report\n\nStatus: done\n' >"$BRIDGE_DIR/outbox/M-4.md"
  printf '# draft without send\n' >"$BRIDGE_DIR/inbox/M-5.md"
}

tree_sum() { (cd "$BRIDGE_DIR" && find inbox outbox -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }

require_v2_root() { # never execute the pre-swap script: it would talk to the real herdr
  rg -q 'v2/lib' "$ROOT/bridge.sh" 2>/dev/null || fail "root bridge.sh is not the v2 script yet"
  CLI="$ROOT/bridge.sh"
}

test_migrate_imports_legacy_items_without_touching_inbox_or_outbox() {
  legacy_fixture
  before="$(tree_sum)"
  br migrate
  rc_is 0
  contains "$OUT" "migrated 4"
  eq "$before" "$(tree_sum)" "inbox/outbox must be read only"
  eq done "$(sget M-1 state)"
  eq gentle "$(sget M-1 agent)"
  eq 999000 "$(sget M-1 sent)"
  eq working "$(sget M-2 state)"
  eq failed "$(sget M-3 state)"
  eq opencode "$(sget M-3 agent)"
  eq done "$(sget M-4 state)"
  eq unknown "$(sget M-4 agent)"
  no_file "$BRIDGE_DIR/state/M-5.json"
  contains "$(sget M-2 note)" "imported"
}

test_migrate_is_idempotent_and_keeps_existing_state() {
  legacy_fixture
  br migrate
  python3 -I "$ST" set M-1 note=mine
  br migrate
  contains "$OUT" "migrated 0"
  eq mine "$(sget M-1 note)"
}

test_migrated_running_task_is_never_reprompted() {
  legacy_fixture
  br migrate
  fh_status gentle working
  br tick
  eq 0 "$(fh_prompts gentle)"
  eq working "$(sget M-2 state)"
  fh_status gentle idle
  br tick
  advance 400
  br tick
  eq 0 "$(fh_prompts gentle)" "stalled tasks are reported, never resent automatically"
  eq stalled "$(sget M-2 state)"
}

test_migrated_tasks_show_up_in_ls_and_stats() {
  legacy_fixture
  br migrate
  br ls --json
  eq 4 "$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])["tasks"]))' "$OUT")"
  br stats --json
  eq 4 "$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["overall"]["n"])' "$OUT")"
}

# --- installed script keeps the legacy contract ----------------------------
test_installed_pane_and_peek() {
  require_v2_root
  OUT="$(cd "$REPO" && "$CLI" pane gentle 2>&1)"; RC=$?
  rc_is 0
  eq wR:p1 "$OUT"
  fh_screen gentle $'line one\n\nline two'
  OUT="$(cd "$REPO" && "$CLI" peek gentle 5 2>&1)"
  eq $'line one\nline two' "$OUT"
}

test_installed_send_keeps_signature_and_sent_file() {
  require_v2_root
  mk_task I-1
  br send gentle I-1 "$REPO"
  rc_is 0
  contains "$OUT" "sent I-1 to gentle (herdr wR:p1)"
  [[ "$(<"$BRIDGE_DIR/inbox/I-1.sent")" =~ ^gentle\ [0-9]+$ ]] || fail ".sent format"
  contains "$(<"$(fh_dir gentle)/prompts")" "$BRIDGE_DIR/outbox/I-1.md"
}

test_installed_send_defaults_repo_to_cwd() {
  require_v2_root
  printf '# plain\n' >"$BRIDGE_DIR/inbox/I-5.md"   # legacy task without lint sections
  cd "$REPO"
  br send gentle I-5 --force
  rc_is 0
}

test_installed_wait_blocks_until_report_then_prints_it() {
  require_v2_root
  write_report I-2 done "legacy wait body"
  br wait I-2
  rc_is 0
  contains "$OUT" "legacy wait body"
}

test_installed_script_without_args_prints_usage() {
  require_v2_root
  br
  rc_is 2
  contains "$OUT" "send <agent> <id>"
}

test_installed_script_rejects_missing_task() {
  require_v2_root
  br send gentle NOPE "$REPO"
  rc_not0
  contains "$OUT" "missing"
}

test_installed_script_resolves_libs_from_any_cwd() {
  require_v2_root
  cd /
  br ls --json
  rc_is 0
}

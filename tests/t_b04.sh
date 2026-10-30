# B04 - ls, status, show, stats, eta, clean, doctor.

# Finished task helper: mk_done id agent duration [final-state]
mk_done() {
  python3 -I "$ST" mark-sent "$1" "$2" "$REPO" "$(git -C "$REPO" rev-parse HEAD)" "title $1"
  python3 -I "$ST" transition "$1" working
  python3 -I "$ST" set "$1" started="$(( 1000000 + $(cat "$BRIDGE_DIR/.vclock" 2>/dev/null || echo 0) ))"
  advance "$3"
  python3 -I "$ST" transition "$1" "${4:-done}"
}

jpy() { python3 -c "import json,sys;d=json.loads(sys.argv[1]);print($2)" "$1"; }

# --- ls ------------------------------------------------------------------
test_ls_json_has_a_stable_schema() {
  mk_task J-1
  br send gentle J-1 "$REPO"
  br progress J-1 2 5 "U2 docs"
  br stage J-1 verified
  advance 60
  br ls --json
  rc_is 0
  eq "version,now,tasks" "$(jpy "$OUT" '",".join(d)')"
  eq 1 "$(jpy "$OUT" 'd["version"]')"
  eq 1000060 "$(jpy "$OUT" 'd["now"]')"
  eq "id,agent,state,title,kind,repo,pane,created,sent,started,done,age_s,duration_s,attempts,progress,stage,stages,commits,commit_count,note,approvals,refusals,approval_pending,approval_sig,approval_tool,approval_target" \
    "$(jpy "$OUT" '",".join(d["tasks"][0])')"
  eq "done,total,current,at" "$(jpy "$OUT" '",".join(d["tasks"][0]["progress"])')"
  eq "sent,verified,reviewed,recorded,merged" "$(jpy "$OUT" '",".join(d["tasks"][0]["stages"])')"
  eq working "$(jpy "$OUT" 'd["tasks"][0]["state"]')"
  eq 60 "$(jpy "$OUT" 'd["tasks"][0]["age_s"]')"
  eq verified "$(jpy "$OUT" 'd["tasks"][0]["stage"]')"
}

test_ls_json_orders_newest_first_and_counts_live_commits() {
  mk_task J-2a; mk_task J-2b
  br send gentle J-2a "$REPO"
  echo x >"$REPO/c.txt"; git -C "$REPO" add c.txt
  git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "feat: c"
  advance 10
  python3 -I "$ST" transition J-2a done
  fh_status gentle idle
  br send gentle J-2b "$REPO"
  rc_is 0
  br ls --json
  eq "J-2b,J-2a" "$(jpy "$OUT" '",".join(t["id"] for t in d["tasks"])')"
  eq 0 "$(jpy "$OUT" 'd["tasks"][0]["commit_count"]')"
}

test_ls_json_is_empty_list_without_tasks() {
  br ls --json
  rc_is 0
  eq 0 "$(jpy "$OUT" 'len(d["tasks"])')"
}

test_ls_table_shows_state_progress_and_stage() {
  mk_task J-3
  br send gentle J-3 "$REPO"
  br progress J-3 2 5 "U2 docs"
  br ls
  rc_is 0
  contains "$OUT" "ID"
  contains "$OUT" "J-3"
  contains "$OUT" "working"
  contains "$OUT" "2/5"
  contains "$OUT" "sent"
}

# --- status / show -------------------------------------------------------
test_status_prints_the_state_json() {
  mk_task K-1
  br send gentle K-1 "$REPO"
  br status K-1
  rc_is 0
  eq K-1 "$(jpy "$OUT" 'd["id"]')"
  eq working "$(jpy "$OUT" 'd["state"]')"
  br status NOPE
  rc_not0
}

test_show_adds_the_agent_pane() {
  mk_task K-2
  br send gentle K-2 "$REPO"
  fh_screen gentle "agent says hello"
  br show K-2
  rc_is 0
  contains "$OUT" '"state": "working"'
  contains "$OUT" "agent says hello"
}

# --- stats / eta ---------------------------------------------------------
test_stats_aggregates_by_agent_and_kind() {
  mk_done F1-T1 gentle 100
  mk_done F1-T2 gentle 200
  mk_done F2-T1 gentle 300
  mk_done F2-T2 gentle 50 failed
  mk_done F1-T3 opencode 40
  br stats --json
  rc_is 0
  eq 4 "$(jpy "$OUT" 'd["agents"]["gentle"]["n"]')"
  eq 3 "$(jpy "$OUT" 'd["agents"]["gentle"]["done"]')"
  eq 1 "$(jpy "$OUT" 'd["agents"]["gentle"]["failed"]')"
  eq 0.75 "$(jpy "$OUT" 'd["agents"]["gentle"]["success_rate"]')"
  eq 200 "$(jpy "$OUT" 'd["agents"]["gentle"]["median_duration_s"]')"
  eq 1 "$(jpy "$OUT" 'd["agents"]["opencode"]["done"]')"
  eq 3 "$(jpy "$OUT" 'd["kinds"]["F1"]["n"]')"
  eq 5 "$(jpy "$OUT" 'd["overall"]["n"]')"
  br stats
  contains "$OUT" "gentle"
  contains "$OUT" "75%"
}

test_stats_counts_retries() {
  mk_task Z-1
  fh_drop gentle 1
  br send gentle Z-1 "$REPO"
  br stats --json
  eq 1 "$(jpy "$OUT" 'd["agents"]["gentle"]["retries"]')"
}

test_stats_without_data() {
  br stats
  rc_is 0
  contains "$OUT" "no tasks"
}

test_eta_uses_median_of_similar_finished_tasks() {
  mk_done F1-T1 gentle 100
  mk_done F1-T2 gentle 300
  mk_task F1-T9
  fh_status gentle idle
  br send gentle F1-T9 "$REPO"
  advance 50
  br eta F1-T9 --json
  rc_is 0
  eq 150 "$(jpy "$OUT" 'd["remaining_s"]')" "median 200 minus 50 elapsed"
  eq median "$(jpy "$OUT" 'd["basis"]')"
}

test_eta_prefers_progress_when_reported() {
  mk_task E-1
  br send gentle E-1 "$REPO"
  advance 100
  br progress E-1 1 4 "one of four"
  br eta E-1 --json
  eq 300 "$(jpy "$OUT" 'd["remaining_s"]')"
  eq progress "$(jpy "$OUT" 'd["basis"]')"
}

test_eta_unknown_without_history() {
  mk_task E-2
  br send gentle E-2 "$REPO"
  br eta E-2 --json
  rc_is 0
  eq None "$(jpy "$OUT" 'd["remaining_s"]')"
  br eta E-2
  contains "$OUT" "unknown"
}

test_eta_for_finished_task_is_zero() {
  mk_done E-3 gentle 10
  br eta E-3 --json
  eq 0 "$(jpy "$OUT" 'd["remaining_s"]')"
}

# --- clean ---------------------------------------------------------------
test_clean_archives_only_finished_items_older_than_n_days() {
  mk_task C-old; mk_task C-new; mk_task C-open; mk_task C-q
  for id in C-old C-new; do
    python3 -I "$ST" mark-sent $id gentle "$REPO" abc ""
    echo "gentle 1" >"$BRIDGE_DIR/inbox/$id.sent"
    write_report $id done
    python3 -I "$ST" transition $id done
  done
  python3 -I "$ST" set C-old done=$(( 1000000 - 10*86400 ))
  python3 -I "$ST" mark-sent C-open opencode "$REPO" abc ""
  python3 -I "$ST" enqueue C-q gentle "$REPO" "" 0
  python3 -I "$ST" set C-open created=1 sent=1
  br clean --days 7
  rc_is 0
  contains "$OUT" "archived 1"
  no_file "$BRIDGE_DIR/state/C-old.json"
  no_file "$BRIDGE_DIR/inbox/C-old.md"
  no_file "$BRIDGE_DIR/inbox/C-old.sent"
  no_file "$BRIDGE_DIR/outbox/C-old.md"
  has_file "$BRIDGE_DIR/archive/state/C-old.json"
  has_file "$BRIDGE_DIR/archive/inbox/C-old.md"
  has_file "$BRIDGE_DIR/archive/outbox/C-old.md"
  has_file "$BRIDGE_DIR/state/C-new.json"
  has_file "$BRIDGE_DIR/state/C-open.json"
  has_file "$BRIDGE_DIR/state/C-q.json"
  has_file "$BRIDGE_DIR/inbox/C-new.md"
}

test_clean_dry_run_moves_nothing() {
  mk_done D-1 gentle 5
  python3 -I "$ST" set D-1 done=1
  br clean --days 1 --dry-run
  rc_is 0
  contains "$OUT" "D-1"
  has_file "$BRIDGE_DIR/state/D-1.json"
  no_file "$BRIDGE_DIR/archive"
}

test_clean_default_is_seven_days() {
  mk_done D-2 gentle 5
  python3 -I "$ST" set D-2 done=$(( 1000000 - 6*86400 ))
  br clean
  contains "$OUT" "archived 0"
  python3 -I "$ST" set D-2 done=$(( 1000000 - 8*86400 ))
  br clean
  contains "$OUT" "archived 1"
}

# --- doctor --------------------------------------------------------------
test_doctor_ok_with_fake_herdr() {
  br doctor
  rc_is 0
  contains "$OUT" "ok: herdr"
  contains "$OUT" "ok: python3"
  contains "$OUT" "ok: agent gentle"
}

test_doctor_reports_missing_herdr() {
  BRIDGE_HERDR=/nonexistent/herdr br doctor
  rc_is 1
  contains "$OUT" "ERROR: herdr not found"
}

test_doctor_reports_missing_python() {
  BRIDGE_PYTHON=no-such-python br doctor
  rc_is 1
  contains "$OUT" "ERROR: python3 not found"
}

test_doctor_warns_about_unnamed_agent_and_orphans() {
  mk_task O-1
  br send gentle O-1 "$REPO"
  rm -rf "$(fh_dir gentle)"
  br doctor
  contains "$OUT" "WARN: agent gentle"
  contains "$OUT" "WARN: orphan task O-1"
}

test_doctor_flags_unwritable_directory() {
  chmod 555 "$BRIDGE_DIR/outbox"
  br doctor
  chmod 755 "$BRIDGE_DIR/outbox"
  contains "$OUT" "outbox"
  [[ "$(id -u)" == 0 ]] || contains "$OUT" "ERROR: directory not writable"
}

# B08 - completeness: help, documentation in sync with the commands, completions, template and README examples.

FISH_COMPLETIONS="${BRIDGE_FISH_COMPLETIONS:-$HOME/.config/fish/completions/bridge.fish}"

# Every command the dispatcher accepts, one per line (read from the script itself, so a new command cannot be forgotten).
dispatched_commands() {
  { rg -o '^  (pane|peek)\)' "$ROOT/v2/bridge.sh" | tr -d ' )'
    rg '^  new \| ' "$ROOT/v2/bridge.sh" | sd '\) .*' '' | tr -d ' ' | tr '|' '\n'
  } | sort -u
}

test_help_prints_the_full_guide_and_exits_zero() {
  br help
  rc_is 0
  for word in "TASK FILES" "SENDING AND CONTROL" "FOLLOWING" "STATES" "ENVIRONMENT" "--no-confirm" "exit: 0 ok" "124 timeout" "STALL_S" "BRIDGE_DIR"; do
    contains "$OUT" "$word"
  done
  full="$OUT"
  br -h; rc_is 0; eq "$full" "$OUT" "-h"
  br --help; rc_is 0; eq "$full" "$OUT" "--help"
}

test_unknown_command_prints_the_short_usage_and_exits_two() {
  br frobnicate
  rc_is 2
  contains "$OUT" "bridge.sh help"
  not_contains "$OUT" "ENVIRONMENT"
}

test_every_command_is_in_help_readme_and_completions() {
  cmds="$(dispatched_commands)"
  [[ "$(wc -l <<<"$cmds")" -ge 20 ]] || fail "could not read the command list: $cmds"
  br help
  help="$OUT"
  while read -r c; do
    contains "$help" "  $c" "help lacks $c"
    rg -q -- "\`$c[ \`]" "$ROOT/README.md" || fail "README lacks $c"
    if [[ -f "$FISH_COMPLETIONS" ]]; then rg -q -- "-a $c " "$FISH_COMPLETIONS" || fail "completions lack $c"; fi
  done <<<"$cmds"
}

test_every_state_is_documented() {
  for s in queued sent working done failed stalled undelivered cancelled; do
    rg -q -- "\b$s\b" "$ROOT/README.md" || fail "README lacks state $s"
  done
  br help
  for s in queued sent working done failed stalled undelivered cancelled; do contains "$OUT" "$s"; done
}

test_template_asks_the_agent_to_report_progress() {
  rg -q 'bridge.sh progress \{\{ID\}\} <done> <total>' "$ROOT/templates/task.md" || fail "template lacks the progress call"
  br new P-1 --repo "$REPO" --title t
  rc_is 0
  contains "$(<"$BRIDGE_DIR/inbox/P-1.md")" "bridge.sh progress P-1 <done> <total>"
  contains "$(<"$BRIDGE_DIR/inbox/P-1.md")" "outbox/P-1.md"
}

# The README examples are executed as written (with the fake herdr and a sandbox repository).
test_readme_examples_run_as_written() {
  local line n=0 id
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n=$((n + 1))
    if [[ "$line" == '$EDITOR inbox/'* ]]; then
      id="${line#\$EDITOR inbox/}"; id="${id%%.md*}"
      mk_task "$id"
      continue
    fi
    [[ "$line" == ./bridge.sh* ]] || fail "unexpected README example line: $line"
    case "$line" in
      "./bridge.sh wait "*) id="$(awk '{print $3}' <<<"$line")"; write_report "$id" "done" "all green" ;;
      "./bridge.sh resend "*) fh_status gentle idle ;;
    esac
    cmd="${line//\~\/work\/app/$REPO}"
    cmd="${cmd//.\/bridge.sh/$CLI}"
    cmd="${cmd//\# */}"
    OUT="$(cd "$REPO" && eval "$cmd" 2>&1)"; RC=$?
    [[ "$RC" == 0 ]] || fail "README example failed (rc $RC): $line"
  done < <(awk '/^### Ejemplos/{on=1;next} /^### Ayuda y autocompletado/{on=0} on && /^```/{inb=!inb;next} on && inb' "$ROOT/README.md")
  ((n >= 15)) || fail "too few README example lines ($n)"
  eq working "$(sget F12-T02 state)" "cancel then resend delivers the task again"
  eq 1 "$(sget F12-T02 attempts)" "a queued task was never sent before"
}

test_fish_completions_offer_commands_agents_stages_and_ids() {
  command -v fish >/dev/null 2>&1 || { echo "skip: fish not installed"; return 0; }
  [[ -f "$FISH_COMPLETIONS" ]] || fail "missing $FISH_COMPLETIONS"
  mk_task C-1
  echo '{"id":"C-9","state":"done"}' >"$BRIDGE_DIR/state/C-9.json"
  comp() { fish -c "source '$FISH_COMPLETIONS'; complete -C '$1'" 2>/dev/null | sd '\x1b\[[0-9;?]*[A-Za-z]' ''; }
  contains "$(comp './bridge.sh ')" "doctor"
  contains "$(comp 'bridge.sh se')" "send"
  contains "$(comp './bridge.sh send ')" "opencode"
  contains "$(comp './bridge.sh send gentle C')" "C-1"
  contains "$(comp './bridge.sh status C')" "C-9"
  contains "$(comp './bridge.sh stage C-9 ')" "reviewed"
  contains "$(comp './bridge.sh send --')" "--queue"
  contains "$(comp './bridge.sh wait --')" "--timeout"
  contains "$(comp './bridge.sh clean --')" "--dry-run"
}

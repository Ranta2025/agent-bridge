# B10 - delegated agents are asked to keep a visible TODO list (opencode's todowrite tool).

TODO_ES='Mantén tu lista de TODO visible (herramienta todowrite): crea al empezar una tarea por unidad de trabajo, marca la actual como in_progress y las terminadas como completed a medida que avanzas.'
TODO_EN='Keep a visible TODO list with todowrite: one item per unit, mark the current one in_progress and finished ones completed as you go'

test_prompt_asks_for_a_visible_todo_list_on_one_line() {
  mk_task P-1
  br send gentle P-1 "$REPO" --no-confirm
  rc_is 0
  p="$(<"$(fh_dir gentle)/prompts")"
  contains "$p" "$TODO_ES"
  contains "$p" "[bridge P-1] Lee y ejecuta las instrucciones de $BRIDGE_DIR/inbox/P-1.md"
  contains "$p" "señal de fin para Claude Code."
  eq 1 "$(fh_prompts gentle)" "one prompt"
  eq 1 "$(wc -l <"$(fh_dir gentle)/prompts" | tr -d ' ')" "one line"
}

test_template_carries_the_todo_instruction_and_lints_clean() {
  br new T-1 --repo "$REPO" --title "x"
  contains "$(<"$BRIDGE_DIR/inbox/T-1.md")" "$TODO_EN"
  rg -q 'How to work' "$BRIDGE_DIR/inbox/T-1.md" || fail "no How to work section"
  sd 'TODO-replace-with-exact-relative-paths' 'a.txt' "$BRIDGE_DIR/inbox/T-1.md"
  sd 'TODO-replace: what to do, why, and where the plan lives.' 'ctx' "$BRIDGE_DIR/inbox/T-1.md"
  sd 'TODO-replace: the exact commands to run and what green means.' 'run it' "$BRIDGE_DIR/inbox/T-1.md"
  br lint T-1
  rc_is 0
  not_contains "$OUT" "warning"
}

test_lint_warns_without_failing_when_the_todo_line_is_missing() {
  mk_task W-1
  br lint W-1
  rc_is 0
  contains "$OUT" "warning"
  contains "$OUT" "todowrite"
  mk_task W-2 "$TODO_EN"
  br lint W-2
  rc_is 0
  not_contains "$OUT" "warning"
}

test_send_still_works_with_the_warning() {
  mk_task W-3
  br send gentle W-3 "$REPO" --no-confirm
  rc_is 0
  contains "$OUT" "sent W-3"
}

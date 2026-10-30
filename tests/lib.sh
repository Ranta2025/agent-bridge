# Test helpers (sourced by run.sh). Every test runs in its own subshell with a fresh sandbox.
# Assertions exit the subshell with status 1 on failure.

CLI="${BRIDGE_CLI:-$ROOT/v2/bridge.sh}"

setup_env() {
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  export BRIDGE_DIR="$T/bridge" FAKE_HERDR_DIR="$T/herdr" BRIDGE_HERDR="$TESTS/fake_herdr"
  export BRIDGE_AUTO_OPEN=0   # the older tests expect the plain error when no pane is open; t_b14 turns it on
  export BRIDGE_NOW=1000000 STALL_S=180 DELIVER_S=30
  unset BRIDGE_MUX TMUX BRIDGE_PYTHON BRIDGE_TEST_CRASH_BEFORE_REPLACE BRIDGE_WATCH_MAX || true
  # `send` starts a background watcher in real use; the sandbox must not leave processes behind (t_b13 tests it).
  export BRIDGE_NO_WATCHER=1
  mkdir -p "$BRIDGE_DIR"/{inbox,outbox,state}
  # The shipped policy resolves its roots from the agent's repository; the sandbox repos live under /tmp, so the
  # older tests (written against the original project paths) get those two roots explicitly. t_b12 tests the shipped roots.
  { cat "$ROOT/approver.policy"; printf 'root /home/dev/work/app\nroot /home/dev/work/app-worktrees\n'; } >"$T/legacy.policy"
  export APPROVER_POLICY="$T/legacy.policy"
  REPO="$T/repo"
  git init -q "$REPO"
  echo one >"$REPO/a.txt"
  git -C "$REPO" add a.txt
  git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init
  fh_add gentle wR:p1 pi "$REPO" idle
  fh_add opencode wS:p1 opencode "$REPO" idle
  ST="$ROOT/v2/lib/state.py"
}

# --- fake herdr control -------------------------------------------------
fh_add() { # name pane kind cwd status
  local d="$FAKE_HERDR_DIR/agents/${2//:/_}"
  mkdir -p "$d"
  echo "$1" >"$d/name"; echo "$2" >"$d/pane"; echo "$3" >"$d/agent"; echo "$4" >"$d/cwd"; echo "$5" >"$d/status"
}
fh_dir() { local d; for d in "$FAKE_HERDR_DIR"/agents/*/; do [[ "$(<"${d}name")" == "$1" ]] && { echo "${d%/}"; return; }; done; }
fh_status() { echo "$2" >"$(fh_dir "$1")/status"; }
fh_drop() { echo "$2" >"$(fh_dir "$1")/drop"; }
fh_prompts() { local f; f="$(fh_dir "$1")/prompts"; [[ -f "$f" ]] && wc -l <"$f" | tr -d ' ' || echo 0; }
fh_keys() { local f; f="$(fh_dir "$1")/keys"; [[ -f "$f" ]] && tr '\n' ' ' <"$f" || true; }
fh_screen() { printf '%s\n' "$2" >"$(fh_dir "$1")/screen"; }

# --- time ---------------------------------------------------------------
advance() { echo $(( $(cat "$BRIDGE_DIR/.vclock" 2>/dev/null || echo 0) + $1 )) >"$BRIDGE_DIR/.vclock"; }

# --- running the CLI ----------------------------------------------------
run() { OUT="$("$@" 2>&1)"; RC=$?; }  # never aborts; use rc/contains afterwards
br() { run "$CLI" "$@"; }

# A task file that passes lint.
mk_task() { # id [extra-line]
  cat >"$BRIDGE_DIR/inbox/$1.md" <<TASK
# Task $1 - sample

<!-- bridge:repo=$REPO -->

Work with sub-agents when the work is large.

## Allowed edit surfaces
a.txt
src/**

## Report
Write your final report to $BRIDGE_DIR/outbox/$1.md
${2:-}
TASK
}

write_report() { # id status-line [body]
  printf '# Report\n\nStatus: %s\n\n%s\n' "$2" "${3:-}" >"$BRIDGE_DIR/outbox/$1.md"
}

sget() { python3 -I "$ST" get "$@"; }

# --- assertions ---------------------------------------------------------
fail() { echo "FAIL: $*" >&2; echo "--- last output (rc=${RC:-?}) ---" >&2; echo "${OUT:-}" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "${3:-eq}: expected [$1] got [$2]"; }
neq() { [[ "$1" != "$2" ]] || fail "${3:-neq}: both [$1]"; }
contains() { [[ "$1" == *"$2"* ]] || fail "${3:-contains}: [$2] not found in [$1]"; }
not_contains() { [[ "$1" != *"$2"* ]] || fail "${3:-not_contains}: [$2] found in [$1]"; }
rc_is() { [[ "$RC" == "$1" ]] || fail "${2:-rc}: expected rc $1 got $RC"; }
rc_not0() { [[ "$RC" != 0 ]] || fail "${1:-rc}: expected non-zero rc"; }
has_file() { [[ -e "$1" ]] || fail "missing file $1"; }
no_file() { [[ ! -e "$1" ]] || fail "unexpected file $1"; }
valid_json() { python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$1" 2>/dev/null || fail "invalid JSON in $1"; }

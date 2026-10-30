#!/usr/bin/env bash
# Test runner: sources tests/t_*.sh and runs every function named test_* in its own subshell.
#   bash tests/run.sh [name-filter]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/tests"
export ROOT TESTS
# shellcheck source=lib.sh
source "$TESTS/lib.sh"
for f in "$TESTS"/t_*.sh; do
  # shellcheck source=/dev/null
  source "$f"
done

filter="${1:-}"
pass=0
fail=0
failed=()
while read -r fn; do
  [[ -z "$filter" || "$fn" == *"$filter"* ]] || continue
  log="$(mktemp)"
  if (
    set +e
    setup_env
    "$fn"
  ) >"$log" 2>&1; then
    pass=$((pass + 1))
    echo "ok   $fn"
  else
    fail=$((fail + 1))
    failed+=("$fn")
    echo "FAIL $fn"
    sed 's/^/     | /' "$log" | head -25
  fi
  rm -f "$log"
done < <(declare -F | awk '{print $3}' | rg '^test_' | sort)

echo "----"
echo "passed: $pass  failed: $fail"
((fail == 0))

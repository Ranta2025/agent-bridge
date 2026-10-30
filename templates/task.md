# Task {{ID}} - {{TITLE}}

<!-- bridge:repo={{REPO}} -->

You are the single writer for this task. Work only inside the repository above; do not change branch, push or merge.

## How to work
- Work as an orchestrator, never inline: you plan, coordinate and verify, and the work itself goes to sub-agents as in any normal job. Delegate reading and mapping to an explorer sub-agent, every implementation that touches two or more non-trivial files (or needs prior reading) to ONE writer sub-agent with exact files, tests and commands, and verification and review to sub-agents. In gentle-shell use `subagent_run` with `gentle-ai-explore` (map), `gentle-ai-worker` (WRITER: it edits code and runs focused tests; it does not commit, you commit after reading its diff) and `gentle-ai-verify` (read-only check); in opencode use `general` (writer) and `explore`. Using only the explorer and then writing the code yourself is NOT delegating. Only a mechanical, already-understood edit in a single file may be done by you directly. Keep a single writer at a time per worktree and read the sub-agent's result and diff before you tick anything.
- You only implement: write code, tests and docs, run the checks, and commit on this branch. Never push, merge, rebase, reset, create or delete branches or worktrees, run reviews, touch other repositories or system settings. If you need any of that (or anything big you cannot do from here), do not improvise: write it in your report as a request for the orchestrator and stop with `Status: partial`.
- Keep a visible TODO list with todowrite: one item per unit, mark the current one in_progress and finished ones completed as you go.
- Protect the machine's RAM (8 GB shared with the user's desktop): run every test with a time and memory cap, e.g. `timeout 60 node --max-old-space-size=512 --test <file>`, never an unbounded `node --test`. If a run prints nothing, hangs or gets killed, do NOT rerun it unchanged: bisect with `--test-name-pattern`, find the loop and fix it first. Docker runs one at a time, and never more than ONE sub-agent runs tests or builds at a time (several explorers or reviewers in parallel are fine; parallel test runs are not).
- Commit with Conventional Commits. Never add Co-Authored-By or any AI attribution.
- Report progress after every finished unit of work:
  `{{BRIDGE}}/bridge.sh progress {{ID}} <done> <total> "<current unit>"`

## Context
TODO-replace: what to do, why, and where the plan lives.

## Allowed edit surfaces
TODO-replace-with-exact-relative-paths

## Verification
TODO-replace: the exact commands to run and what green means.

## Report
Write the final report to `{{BRIDGE}}/outbox/{{ID}}.md` (that file is the end signal).
Its first lines must contain a status line such as `Status: done`, `Status: partial` or `Status: blocked`,
then the commits, the verification evidence (`<command>: <observed result>`) and anything left pending.

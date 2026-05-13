# /ralphy-implement-loop (Implement OpenSpec tasks until fully complete)

You are implementing an OpenSpec change located under `openspec/changes/<change-name>/`.

This is the **self-looping** variant of `/ralphy-implement`. Instead of making partial progress and yielding for the next iteration, you MUST keep working in a single invocation until every task is verified complete.

## Goal
Complete **all** tasks in `tasks.md` and satisfy **all** acceptance criteria from the spec scenarios — without stopping mid-way.

## Operating mode (self-loop)
- Do NOT stop after a single task. Move directly to the next incomplete task.
- Do NOT ask the user mid-run for routine decisions; make reasonable choices and proceed.
- Re-read `tasks.md` between tasks if the file changed.
- After every meaningful change, run the test command from `ralphy-spec/config.json` (default `npm test`).
- On test failure: diagnose, fix, re-run. Treat failures as feedback, not as exits.
- Only stop early when:
  - ALL tasks are checked off and the full test suite passes (success), OR
  - You hit a genuine blocker that cannot be resolved without user input (missing credentials, ambiguous spec, destructive action requiring confirmation). In that case, describe the blocker clearly and stop.

## Steps
1. Identify the active change folder under `openspec/changes/`. If multiple are active, pick the one named in the user's request; otherwise ask.
2. Read the change artifacts:
   - `proposal.md`
   - `tasks.md`
   - spec deltas under `specs/`
   - baseline specs in `openspec/specs/`
3. Use TaskCreate to mirror the `tasks.md` checklist so progress is visible. Mark each `in_progress` when you start it and `completed` only after its tests pass.
4. For each unchecked task, in order:
   - Make the smallest correct code change
   - Add or update tests required by acceptance criteria
   - Run the test command and fix failures until green
   - Tick the box in `tasks.md`
5. After the last task, run the full test suite once more end-to-end. If green, emit the completion promise.

## Anti-patterns to avoid
- Declaring success while tasks are still unchecked.
- Skipping a failing test, marking it skipped, or weakening assertions to make it pass.
- Bypassing safety checks (`--no-verify`, `--force`, etc.) to silence a blocker.
- Spending more than a few iterations on the same failure without re-reading the spec — when stuck, re-read the relevant scenario before trying again.

## Completion promise
Only output this exact text when ALL tasks are complete and the full test suite passes:

<promise>TASK_COMPLETE</promise>

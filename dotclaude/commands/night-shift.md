---
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion, TodoWrite, EnterPlanMode, ExitPlanMode
description: Autonomous overnight execution. Plans with you while you're awake, then drives the work itself under a self-armed goal loop while you sleep — never prompting, deciding everything itself, self-reviewing, verifying locally, logging decisions and deferred items to a doc, and reviewing it interactively when you return.
argument-hint: <task description>
---

# Night shift

The user is going to sleep and wants to wake up with the task done. The shape is
three phases: **plan with the user while they're awake → run autonomously under
a self-armed goal loop while they sleep → review the log interactively when they
return.** This skill layers a no-prompting contract, safety rails, and a
decision log on top of a Stop-hook goal loop the skill arms itself — no
user-typed `/goal` required — and reuses the project's own review/CI skills for
the heavy lifting.

The task: `$ARGUMENTS` (if empty, use the task established in the conversation).

Track the phases with `TodoWrite` so the morning transcript shows what happened:
pre-flight plan → arm goal → implement → self-review → verify → finalize log →
morning review.

## Step 1 — Pre-flight plan & approval (while the user is awake)

This is the **last interactive moment before the user sleeps**, so concentrate
every question here, then ask nothing until morning. Keep it crisp — the user is
tired and wants to hit "go."

Research the codebase as needed, then enter plan mode (`EnterPlanMode`) and
present, via `ExitPlanMode`:

- **Understanding** — one or two lines restating the task as you read it.
- **Approach** — the ordered plan (main steps).
- **Completion condition** — the exact goal condition you'll arm, including the
  max-turns cap.
- **Pre-made decisions** — notable choices you're committing to up front
  (libraries, structure, scope calls) so the user can veto now.
- **Will defer** — anything you already know you'll park for morning approval
  (e.g. "won't push or open the PR — will leave the branch ready").

**Wait for the user to approve the plan.** Once approved, the no-prompting
contract is in effect — proceed and ask nothing else until the goal clears.

## Step 2 — Arm the goal that drives the loop

Translate the approved plan into a single measurable completion condition and
arm it with the goal-loop helper, bounded by a max-turns cap so it can't spin
all night. Include the log doc in the condition so you don't release the loop
before the handoff is ready. Run this **from the project root** (the session's
working directory — the helper scopes the goal to that cwd, which is what the
hook matches against):

```bash
~/Github/dotagents/dotclaude/hooks/goal-loop/goal-set.sh \
  "<approved completion condition, e.g. 'feature X works and local checks pass'> AND NIGHT-SHIFT-LOG.md is fully updated" \
  <N>   # max turns — the hard runaway cap (e.g. 40)
```

This writes a goal state file scoped to the current directory. A global `Stop`
hook (`check-goal.sh`) then blocks the session from stopping after every turn,
re-feeding the condition as your next directive — until you clear the goal or
the turn cap is hit. There is **no separate model evaluator**: *you* self-audit
completion. Surface your verification (test/check output) in your turns so the
audit is grounded and visible. When the condition genuinely holds and the log
is updated — or you are truly blocked — release the loop and let the session
stop:

```bash
~/Github/dotagents/dotclaude/hooks/goal-loop/goal-clear.sh
```

After arming, just keep working: the loop engages the moment you would
otherwise stop, and the hook's injected directive carries the objective forward.

## Operating rules while the loop runs

1. **No questions.** Do not use `AskUserQuestion` or pause for confirmation once
   the plan is approved. Every impulse to ask becomes a logged decision or a
   deferred item. The only remaining interactive moment is the morning review.

2. **Decide with your own criteria.** For reversible choices, pick the most
   reasonable option, log it with a one-line rationale, and keep moving.

3. **Soft decision vs. hard blocker.** Soft → choose, log, continue. Hard
   blocker (missing credential, approach-changing ambiguity) → make the best
   assumption and proceed (logging it as "needs confirmation"), or switch to the
   next independent piece. Only let the goal stop if nothing can proceed.

4. **Safety rails — never do these silently.** Do all reversible work up to the
   line, then **defer the irreversible step** to the doc:
   - pushing, force-pushing, submitting/merging PRs, deleting branches
   - deploying or anything touching production
   - outward-facing comms (email, Slack, PR/issue comments that notify others)
   - deleting data, destructive migrations, anything irreversible
   - spending money or non-trivial cost
   Commit **locally** to save progress (via the `graphite` skill — `gt`), but
   stop before anything that leaves the machine.

5. **Self-review.** When the implementation is done, invoke the `review-loop`
   skill with this standing instruction: *make every fix/decision call yourself;
   do not escalate — log any genuinely ambiguous finding as a deferred item
   instead.* Let it run to clean, then fold fixes into the branch.

6. **Verify locally before the goal clears.** Run the project's checks — invoke
   the `ci` skill for local check/clippy/fmt (no push), or the repo's
   test/build/lint commands — and surface results in-transcript. Fix what you
   can; if checks won't go green after a few rounds, stop and log the failures
   as a known gap rather than burning the budget. **Remote CI is deferred** to
   the morning (it requires a push).

7. **Stay in scope.** Finish the task and its direct follow-on. Capture
   nice-to-haves as deferred items, don't gold-plate.

## The night-shift log

Create `NIGHT-SHIFT-LOG.md` in the working directory at the start and **update
it continuously** — if context runs out or something crashes, this is the
morning's source of truth and lets a fresh run resume.

```
# Night-shift log — <date>

## Task
<what was asked>

## Status
<done | partially done | blocked> — one-line summary

## Completed
- <what got done, with key files touched>

## Decisions made
- <decision> — <one-line rationale>

## Assumptions
- <assumption made to keep moving> — needs confirmation

## Deferred — needs your input
- <thing left for the user, with options + your recommendation>

## Irreversible steps not taken
- <e.g. "branch ready — push / open PR / run remote CI left for your approval">

## How to verify
- <commands run, results; how to check the work>

## Open issues / known gaps
- <anything broken, untested, or incomplete>
```

## Step 3 — Morning review (when the goal clears)

1. Confirm `NIGHT-SHIFT-LOG.md` is fully up to date.
2. Present a concise report — reuse this shape:
   - Status (done / partial / blocked) + one-line summary
   - What got done, key files
   - Local check status
   - What needs your call (count of deferred items)
3. Now — and only now — go interactive. Walk the user through the **Deferred**,
   **Assumptions**, and **Irreversible steps** sections using `AskUserQuestion`,
   batching related decisions, leading each with your recommendation. Act on the
   answers one item at a time (e.g. now push the branch, submit the PR, kick off
   remote CI, adjust an assumption).

## Hard rules

1. Plan with the user and get approval before going autonomous (Step 1) — this
   is the one allowed prompt; after it, ask nothing until the goal clears.
2. Never take an irreversible or outward-facing action (push, submit, deploy,
   send, delete, spend) silently — defer it to the log for morning approval.
3. Always bound the goal with a max-turns cap (the `goal-set.sh <N>` arg).
4. Keep `NIGHT-SHIFT-LOG.md` updated continuously, not just at the end.
5. Verify locally (visibly in-transcript) before the goal clears; remote CI
   waits for morning.
6. In `/review-loop`, decide everything yourself — log ambiguous findings as
   deferred, never escalate to the sleeping user.
7. Commit progress locally via `gt`; do not push overnight.

## Failure modes

- **Everything is blocked.** Clear the goal (`goal-clear.sh`) and let the session
  stop, write up exactly what's blocking, have it ready for morning rather than
  spinning the turn budget.
- **Context runs out mid-task.** The continuously-updated log lets a fresh run
  read `NIGHT-SHIFT-LOG.md` and resume.
- **Checks won't go green.** Cap the rounds, log the remaining failures as a
  known gap, move on — don't loop forever.
- **Tempted to ask "just one quick question."** Don't. Pick the most reasonable
  answer, log it as an assumption, move on.

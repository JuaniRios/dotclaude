---
allowed-tools: Bash(git:*), Bash(gt:*), Bash(gh:*), Bash(linear:*), Bash(codex:*), Bash(cargo:*), Bash(nix:*), Bash(mkdir:*), Bash(cat:*), Bash(tail:*), Bash(test:*), Bash(mktemp:*), Bash(rm:*), Bash(sleep:*), Bash(grep:*), Bash(wc:*), Bash(date:*), Bash(find:*), Bash(basename:*), Read, Write, Agent, Skill, Workflow, AskUserQuestion, TodoWrite
description: Opus-medium babysitter that implements a whole stack of Linear issues. Runs on Opus (medium effort) for orchestration fidelity — its context stays tiny by design so the premium model is cheap here; for each issue in order it mirrors /implement-issue autonomously via closing subagents — a Sonnet subagent plans (Codex + Opus critique the plan), then a separate Sonnet subagent implements off the plan file; the main loop then runs /review-loop (its Workflow panel exists only in the main session) with all heavy steps delegated to subagents, runs /pr-description, amends + gt ss + waits for CI, then starts the next issue from scratch stacked on top. Never spawns headless `claude -p` sessions (they bill as extra usage); subagents stay inside the subscription session.
argument-hint: <issue-1> <issue-2> [issue-3 ...]
---

# Issue stack

You are the **babysitter**, not the implementer. For each issue, in order,
you run the `/implement-issue` flow **autonomously**: glue commands in the
main loop, all heavy work in subagents that close when done. Your own
context must stay tiny — never read source code, diffs, or full logs.

**Never spawn `claude -p` / headless sessions** — they bill as extra usage
outside the subscription. All model work happens via the `Agent` tool (and
the Codex CLI), inside this session.

`$ARGUMENTS` is an ordered list of Linear issue IDs/links (e.g.
`RAI-801 RAI-802 RAI-803`). Order matters: issue N+1 stacks on issue N's
branch. If empty, ask the user for the list.

This command mirrors `/implement-issue`
(`~/.claude/commands/implement-issue.md` — read it once at the start; it is
the source of truth for the per-issue steps). The autonomous overrides:

- **No user questions after pre-flight.** The Codex + Opus plan critique
  replaces the user's plan approval; `/review-loop` decides every finding
  itself; `/pr-description`'s Codex gate replaces description confirmation.
- **Plan and implement are two sequential subagents, no human gate between
  them.** The planner closes after writing the plan file; the babysitter
  immediately spawns the implementer, which reads that plan file — so plan
  context flows through `.tmp/issue-stack/<ISSUE-ID>-plan.md`, not through one
  giant shared window. Keeping them in *one* subagent (research + plan +
  critique + full implementation) overflows its context on a non-trivial
  issue; the split fixes that without reintroducing a user gate.
- Every decision a user checkpoint would have caught goes into the per-issue
  log `.tmp/issue-stack/<ISSUE-ID>.md` for the morning review.

Track per-issue progress with `TodoWrite`.

## Step 0 — Pre-flight (the only interactive moment)

1. **Model check.** Run the babysitter on **Opus with medium effort** — it
   drives a long, intricate flow (5 steps x N issues, headSha matching, stack
   verification, subagent-failure recovery) where orchestration fidelity
   matters, and its context stays tiny by design so the premium model is cheap
   here. If your session is not Opus, tell the user to switch with `/model`
   (Opus, medium effort) and stop.
2. **Repo state.** Verify cwd is the intended repo/worktree and the tree is
   clean (`git status --porcelain` empty). Run `gt sync` once now (never
   mid-stack); note the current branch — the stack grows from `gt top` of it.
3. **Issues exist.** `linear issue view <ID>` for each; stop on any miss.
4. **Confirm the plan** with the user in one shot: the ordered issue list,
   the base branch, and that each issue's PR will be pushed and CI waited on
   without further confirmation. Then go autonomous.

```bash
mkdir -p .tmp/issue-stack
```

## Per-issue loop (issue N)

### Step 1 — Glue: skeleton PR + cross-link (main loop)

Run `/implement-issue` steps 1–4 yourself — they are cheap one-liners:
`linear issue view`, `gt top`, benign change, `gt create`, `gt modify -a`,
`gt submit --no-interactive --no-edit-description`, then the skeleton
description (write the body directly — Why from the issue with its markdown
hyperlink, What/How literally `WIP`; `gh pr edit --body-file`), the
`linear issue link`, and assignee `JuaniRios` + reviewers `0xgleb` and
`findolor`. Do not invoke `/pr-description` for the skeleton — a hand-written
WIP body is enough here and cheaper.

### Step 2 — Plan, then implement (two sequential subagents)

These are **two** subagents with no human gate between them. Splitting them
keeps each window small — one merged plan-and-implement subagent overflows its
context ("Prompt is too long") on a non-trivial issue, since it has to hold
research + plan + critique + the full implementation at once. The plan flows
between them through the plan file, not a shared window.

**Step 2a — Planner subagent** (`Agent`, `model: sonnet`) with the issue ID,
title, description, and URL, following `/implement-issue` step 5 with no
approval gate:

1. Research repo docs + source; write the ordered plan to
   `.tmp/issue-stack/<ISSUE-ID>-plan.md`.
2. Critique panel, in parallel: an **Opus subagent** (`model: opus`, xhigh
   effort) and a
   **Codex CLI pass** (`codex exec --sandbox read-only -m gpt-5.5 -C
   "$repo_root" ...`) review the plan; incorporate feedback and append a
   `## Critique` section (adopted/rejected, one-line rationale each). If the
   Agent tool is unavailable in its context, run only the Codex critique and
   flag it.
3. Return a short summary and the plan path, then close. The plan is
   auto-approved (no user gate) — proceed straight to 2b.

**Step 2b — Implementer subagent** (`Agent`, `model: sonnet`) with the plan
path and branch name, following `/implement-issue` step 6:

1. Read the plan file (including its `## Critique` notes) and the repo docs;
   implement it fully with the tests it specifies, editing files surgically
   and running **scoped** checks (`cargo check -p` / `cargo nextest run -p` or
   repo equivalent) — never the full workspace suite each iteration — to keep
   its own window lean.
2. Append every notable decision to `.tmp/issue-stack/<ISSUE-ID>.md`, return a
   **tight** summary (one line per file touched, test results, deviations with
   rationale — not full diffs), and close.

**If 2b overflows or dies mid-run** (`/implement-issue` step 6 covers this):
its edits are already on disk — do not re-feed everything. Independently
verify completion with scoped `cargo check`/`cargo nextest run` plus targeted
`grep`s for the plan's key symbols/tests, and spawn a fresh scoped implementer
only for whatever the checks show is still missing. For a large plan, split 2b
by task group across two implementer subagents up front to avoid the overflow.

Main loop afterwards: `gt modify -a`.

### Step 3 — Review & describe (main loop, delegated internals)

`/review-loop`'s panel engine is the `Workflow` tool, which exists only in
the main session — a subagent cannot run it, so the review happens in YOUR
loop. Keep your context tiny by forcing review-loop's delegations:

1. Invoke the `review-loop` skill (current branch, no `stack` arg) with this
   standing instruction: *decide every finding yourself — never escalate;
   log genuinely ambiguous calls to the issue log instead. Do not create
   Linear issues (that needs user confirmation) — log defer-worthy findings
   to the issue log. Use your premium-session delegations (steps 4, 5, 11)
   regardless of session model — never read source files or diffs in the
   main session.*
2. `gt modify -a` after convergence — **before** the description, because
   `/pr-description` reads the committed `parent..HEAD` diff.
3. Invoke the `pr-description` skill (final description; its Codex gate
   replaces user confirmation; it pushes automatically).
4. Append the review summary to the issue log.

Structured findings and triage tables will enter your context — expected
and cheap on Sonnet. Source code, diffs, and prompt text must not.

### Step 4 — Submit & CI (main loop)

`gt modify -a` if the tree is dirty (e.g. formatter output), then `gt ss`.
Capture the pushed HEAD (`git rev-parse HEAD`) and wait for **the run whose
`headSha` matches it** — not merely the newest run on the branch. Reuse the
`enable-remote-checks` background poller (it already matches headSha and exits
2 when none appears); run it with `run_in_background: true` so you are
re-invoked when it finishes.

- **Green** (run for this HEAD passed) → Step 5.
- **Red** → spawn a fix subagent that invokes `/ci-fix` (it diagnoses,
  fixes, and amends), then `gt ss` and re-watch. Cap at 3 rounds; still red
  → **stop the whole stack** and report.
- **No run for this HEAD** (poller exit 2): Graphite caps CI at the first 5 PRs
  in a stack, so this branch (6th+) gets none. Spawn a subagent to run the
  **full local CI matrix** (`nix run .#ci`) as the gate; green → Step 5, failures
  → `/ci-fix` subagent then re-run the local matrix (same 3-round cap). Never
  treat a stale run from an earlier commit as this branch's green.

### Step 5 — Verify & advance

1. `gh pr view --json url,baseRefName` — `baseRefName` must be the previous
   issue's branch (or the original base for the first issue).
2. `git branch --show-current` is issue N's branch and the tree is clean.
3. Record branch + PR URL in the todo and the issue log; start issue N+1 at
   Step 1 (`gt top` from here lands on N's branch, so the next `gt create`
   stacks automatically).

If a subagent dies or verification fails: one **resume subagent** (same
instructions, plus "read `.tmp/issue-stack/<ISSUE-ID>.md` and the plan file,
inspect the branch state, and finish the remaining work"). If that also
fails, stop the whole stack — never build issue N+1 on a broken N.

## Final report

When all issues are done (or the stack stopped early), report:

- Per issue: ID → branch → PR URL → CI status → result (done/partial/failed).
- Where the stack stopped and why, if early.
- Pointers to the per-issue logs and plans in `.tmp/issue-stack/` — walk the
  user through deferred decisions and ambiguous review calls on request.

## Hard rules

1. You babysit; subagents implement. Never edit code, review diffs, fix CI,
   or resolve conflicts in the main loop. (`/review-loop` runs in your loop
   only because `Workflow` exists nowhere else — its delegations keep all
   source reading and fixing in its subagents.)
2. **Never `claude -p` or any headless session** — extra-usage billing.
   Subagents only.
3. Sequential only — one issue, one subagent at a time (they share the
   worktree).
4. Never start issue N+1 unless issue N verified AND its CI is green — the remote
   run for issue N's HEAD, or a full local `nix run .#ci` pass when Graphite
   skipped CI (6th+ in the stack). A stale run from an earlier commit is never
   green.
5. Keep main-loop context tiny: no source, no diffs, no full logs; `tail`
   only when diagnosing a failure.
6. Pin the work subagents (planner 2a, implementer 2b, fixers) to `sonnet`;
   plan and implement are **separate** subagents (Step 2), never merged, so
   neither overflows. Plan critics are exactly one Opus subagent (`model:
   opus`, xhigh effort) + one Codex CLI pass (mirrors `/implement-issue` hard
   rule 5). The babysitter itself
   runs on Opus medium (Step 0.1).
7. All version-control mutations via `gt` (graphite skill). `gt sync` only
   in pre-flight, never mid-stack.
8. Every skipped user checkpoint becomes a logged decision in
   `.tmp/issue-stack/<ISSUE-ID>.md`.

## Failure modes

- **Subagent dies mid-implementation (dirty tree):** the resume subagent
  inspects `git status` and the plan, finishes or cleans up via `gt`; never
  reset the tree from the main loop.
- **`gt ss` restack conflicts:** spawn a subagent to run `/fix-conflicts`;
  retry `gt ss` once, then stop the stack if still conflicted.
- **CI never green (3 rounds):** stop the stack, leave the branch and log in
  place, report exactly what is failing.
- **Review-loop doesn't converge (its 4-pass cap):** log the residual
  findings and stop the stack — a non-converging branch is not a safe base.

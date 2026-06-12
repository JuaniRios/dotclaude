---
allowed-tools: Bash(gt:*), Bash(git:*), Bash(gh:*), Bash(linear:*), Bash(codex:*), Bash(mkdir:*), Bash(mktemp:*), Bash(cat:*), Bash(rm:*), Bash(test:*), Bash(basename:*), Bash(date:*), Bash(sleep:*), Bash(sed:*), Read, Write, Edit, Skill, Agent, AskUserQuestion, TodoWrite
description: Take a Linear issue from link to finished implementation — open a skeleton Graphite PR, cross-link Linear↔PR, plan via a Sonnet subagent critiqued by Codex + Fable, implement and review via closing subagents (keeps main-session context small), submit the stack, and get CI green.
argument-hint: <issue-link-or-number>
---

Drive a Linear issue end-to-end: read it, open a skeleton PR on top of the
stack, cross-link Linear and the PR, plan it via a subagent (critiqued by
Codex + Fable, approved by the user), implement and self-review via
subagents, submit the stack, and get CI green.

**Context discipline:** all heavy work (research, planning, implementation,
review, description) runs in subagents that close when done — the main
session holds only glue commands and user checkpoints. This is what keeps
long sessions cheap; never pull research or diffs into the main context.

`$ARGUMENTS` is the Linear issue link or number (e.g. `RAI-799` or a
`linear.app/...` URL). If empty, ask the user for it before doing anything.

Track the phases with `TodoWrite` so the user can see progress. The phases are:
read issue → open skeleton PR → cross-link → plan (subagent + critics) →
implement (subagent) → review & describe (subagent) → submit & CI → report.

---

## 1. Read the issue (`/linear-cli`)

Invoke the `linear-cli` skill. Resolve the issue ID from `$ARGUMENTS`
(strip a URL down to the `RAI-###` identifier) and read it:

```bash
linear issue view <ISSUE-ID>
```

Capture the **title**, **description/why**, and the **Linear URL**
(`linear issue url <ISSUE-ID>`). You'll need all three. If the issue can't be
found, stop and tell the user.

## 2. Open a skeleton PR on top of the stack (`/graphite`)

Invoke the `graphite` skill. All version-control mutations go through `gt`.

1. Sync and move to the top of the current stack so the new branch stacks on
   top:
   ```bash
   gt sync
   gt top
   ```
2. Derive a branch/PR name from the issue: `<issue-id-lowercased>-<kebab-title>`
   (e.g. `rai-799-terminalize-stuck-burning`). This is "the name of the problem".
3. Make a **benign change** — it only needs to produce a diff so the branch has
   a commit and a PR can open. A trailing newline or a `// WIP: <ISSUE-ID>`
   placeholder comment in a file you'll legitimately touch is fine; the real
   implementation replaces it later.
4. Create the branch and submit to open the PR:
   ```bash
   gt create <branch-name> -m "<issue-id>: <issue title>"
   gt modify -a
   gt submit --no-interactive --no-edit-description
   ```
5. Capture the PR number and URL:
   ```bash
   pr_num=$(gh pr view --json number --jq .number)
   pr_url=$(gh pr view --json url --jq .url)
   ```

## 3. Skeleton PR description with only "Why" (`/pr-description`)

Invoke the `pr-description` skill, instructing it this is a **WIP skeleton**:

- **Why**: filled in from the Linear issue (summarize the issue's motivation).
- **What** and **How**: literally `WIP`.
- The Linear issue **must** appear as a markdown hyperlink in the body —
  `[<ISSUE-ID>](<linear-url>)` — never a bare ID.

Approve the skeleton on the user's behalf (this is a WIP placeholder, not the
final description) so the flow isn't blocked, then let `pr-description` push it.

## 4. Cross-link Linear ↔ PR

1. The PR already links Linear (step 3). Now link the PR from the Linear issue:
   ```bash
   linear issue link <ISSUE-ID> "$pr_url"
   ```
2. Assign Juan and request reviews from gleb and findolor:
   ```bash
   gh pr edit "$pr_num" \
     --add-assignee JuaniRios \
     --add-reviewer 0xgleb \
     --add-reviewer findolor
   ```

Confirm both directions are linked before continuing.

## 5. Plan via a planner subagent (Codex + Fable critique)

Planning happens in a subagent that researches, drafts, gets critiqued, and
closes — only the refined plan returns to the main session.

```bash
mkdir -p .tmp/implement-issue
```

Spawn a **planner subagent** (`Agent`, `model: sonnet`) with the issue ID,
title, description, and URL, plus these instructions:

1. Read the repo's project docs (`CLAUDE.md`/`AGENTS.md`, `SPEC.md`, relevant
   `docs/`) and the relevant source code. Draft a concrete, ordered
   implementation plan (spec-first, tests per task) into
   `.tmp/implement-issue/<issue-id>-plan.md`.
2. Get two **independent plan critiques in parallel**:
   - A **Fable subagent** (`Agent`, `model: fable`): adversarial critique —
     simpler designs, conflicts with `SPEC.md`/repo conventions, missing test
     coverage, hidden coupling, steps that will not survive contact with the
     code.
   - A **Codex pass** (`Bash`): pipe the plan to
     `codex exec --sandbox read-only -m gpt-5.5 -C "$repo_root" "<critique
     prompt: same focus, plus 'what would a staff engineer push back on?'>"`.
   If the Agent tool is unavailable in the subagent's context, run only the
   Codex critique and flag the missing Fable pass in the report.
3. Incorporate the feedback into the plan file and append a `## Critique`
   section noting which points were adopted and which rejected (with one-line
   rationale each).
4. Return: the ordered plan steps, critique highlights, and the plan path.

Present the refined plan to the user and **wait for approval**
(`AskUserQuestion`: approve / adjust). Do not implement anything until the
plan is accepted. If the user asks for changes, update the plan file and
re-confirm.

## 6. Implement via an implementer subagent

Spawn an **implementer subagent** (`Agent`, `model: sonnet`) with the plan
path and these instructions: read the plan file (including the critique
notes) and the repo docs, implement the plan fully with the test coverage it
specifies, and run scoped verification per the repo's conventions (e.g.
`cargo check -p <crate>` + `cargo nextest run -p <crate>`), fixing what it
finds. It returns: files touched, test results, and any deviations from the
plan (with rationale). The subagent then closes — its research and diff
context dies with it.

Fold the work into the branch (this also replaces the benign change from
step 2):

```bash
gt modify -a
```

## 7. Review & describe via a review subagent

Spawn a **review subagent** that runs the whole quality pass and closes:

1. Invoke the `review-loop` skill (current branch, no `stack` argument) with
   this standing instruction: *decide most fix/decision calls yourself; for a
   finding that genuinely has no clear answer, do not ask — collect it in
   your report instead.*
2. After the loop converges, amend the fixes: `gt modify -a`. **This must
   happen before the description** — `/pr-description` reads the committed
   `parent..HEAD` diff, so unamended fixes would be invisible to it.
3. Invoke the `pr-description` skill for the **real** description: What and
   How from the actual diff, Why preserved from the Linear issue with its
   markdown hyperlink. It runs its own Codex gate and pushes automatically.
4. Return: review passes run, findings fixed/dismissed, ambiguous findings
   collected in step 1, and the final PR title.

If the subagent returned ambiguous findings, resolve them with the user now
(`AskUserQuestion`, batched). Apply any chosen fixes via a small Sonnet
subagent, then `gt modify -a` again.

## 8. Submit the stack & get CI green (`/ci-fix`)

Submit and wait for the GitHub CI run to finish:

```bash
gt ss
gh run list --branch "$(git branch --show-current)" --limit 1 \
  --json databaseId,status,conclusion
```

(If the stack is shared with someone else's upstack work, use `gt submit` on
current + downstack only — see the `graphite` skill.)

Poll until the run's `status` is `completed` (sleep ~30s between checks; report
progress). Then:

- **If it passed**: continue to step 9.
- **If it failed**: invoke the `ci-fix` skill to diagnose and fix locally. It
  amends via `gt modify -a` when done. Re-submit (`gt ss`) and re-poll. Repeat
  until CI is green (cap at a few rounds; if stuck, stop and report).

## 9. Report

Tell the user implementation is finished. Print:

- The Linear issue ID + URL.
- The PR number + Graphite URL (`gt pr`).
- CI status (green).
- A one-line summary of what was implemented.
- The plan path (`.tmp/implement-issue/<issue-id>-plan.md`) for the record.

## Hard rules

1. Never use raw `git` to mutate state — all commits/amends/submits go through
   `gt` (see the `graphite` skill).
2. Never implement before the user approves the plan in step 5.
3. The Linear issue must be a markdown hyperlink in the PR body, and the PR URL
   must be attached to the Linear issue — both directions, every time.
4. Assignee is `JuaniRios`; reviewers are `0xgleb` and `findolor`.
5. Heavy work (research, planning, implementation, review, description) runs
   in subagents that close when done — never in the main session. Pin the
   planner/implementer/review subagents to `sonnet`; the plan critics are
   exactly one Fable subagent + one Codex CLI pass.
6. The skeleton description (step 3) may be auto-approved since it's an
   explicit WIP placeholder; the final description is gated by
   `/pr-description`'s Codex review pass and pushed automatically — show the
   user the final title in the report.
7. In `/review-loop`, the subagent decides most findings itself — genuinely
   ambiguous ones come back as a report for the user, never as a mid-loop
   question.
8. Don't declare done until CI is actually green.

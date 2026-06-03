---
allowed-tools: Bash(gt:*), Bash(git:*), Bash(gh:*), Bash(linear:*), Bash(mktemp:*), Bash(cat:*), Bash(rm:*), Bash(test:*), Bash(basename:*), Bash(date:*), Bash(sleep:*), Bash(sed:*), Read, Write, Edit, Skill, Agent, AskUserQuestion, TodoWrite, EnterPlanMode, ExitPlanMode
description: Take a Linear issue from link to finished implementation — open a skeleton Graphite PR, cross-link Linear↔PR, plan with the user, implement, self-review, fix CI, and finalize the PR description.
argument-hint: <issue-link-or-number>
---

Drive a Linear issue end-to-end: read it, open a skeleton PR on top of the
stack, cross-link Linear and the PR, plan the work with the user, implement
it, self-review, get CI green, and finalize the PR description.

`$ARGUMENTS` is the Linear issue link or number (e.g. `RAI-799` or a
`linear.app/...` URL). If empty, ask the user for it before doing anything.

Track the phases with `TodoWrite` so the user can see progress. The phases are:
read issue → open skeleton PR → cross-link → plan → implement → review-loop →
CI → finalize.

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

## 5. Plan the implementation (plan mode)

Enter plan mode (`EnterPlanMode`). Research the codebase as needed and produce a
concrete, ordered implementation plan that satisfies the issue. Follow the
repo's `AGENTS.md`/`SPEC.md` conventions (spec-first, ordered tasks, tests pass
per task).

Present the plan via `ExitPlanMode` and **wait for the user to approve it**. Do
not implement anything until the plan is accepted.

## 6. Implement (`/graphite`)

Work through the approved plan to completion. When the work is finished, fold it
into the branch (this also replaces the benign change from step 2):

```bash
gt modify -a
```

## 7. Self-review (`/review-loop`)

Invoke the `review-loop` skill with this standing instruction:

> Make most fix/decision calls yourself — only stop to ask the user when a
> finding genuinely has no clear answer.

Let the loop run to completion (it auto-fixes and re-reviews until clean). When
it finishes, amend the fixes into the branch:

```bash
gt modify -a
```

## 8. Wait for CI, fix if red (`/ci-fix`)

Submit the latest state and wait for the GitHub CI run to finish:

```bash
gt submit --no-interactive --no-edit-description
gh run list --branch "$(git branch --show-current)" --limit 1 \
  --json databaseId,status,conclusion
```

Poll until the run's `status` is `completed` (sleep ~30s between checks; report
progress). Then:

- **If it passed**: continue to step 9.
- **If it failed**: invoke the `ci-fix` skill to diagnose and fix locally. It
  amends via `gt modify -a` when done. Re-submit and re-poll. Repeat until CI is
  green (cap at a few rounds; if stuck, stop and report).

## 9. Finalize the PR description (`/pr-description`)

Invoke the `pr-description` skill again — this time for the **real**
description. What and How are now filled from the actual diff; Why stays; the
Linear hyperlink is preserved. Let the user confirm the final description as
`pr-description` normally requires.

## 10. Report

Tell the user implementation is finished. Print:

- The Linear issue ID + URL.
- The PR number + Graphite URL (`gt pr`).
- CI status (green).
- A one-line summary of what was implemented.

## Hard rules

1. Never use raw `git` to mutate state — all commits/amends/submits go through
   `gt` (see the `graphite` skill).
2. Never implement before the user approves the plan in step 5.
3. The Linear issue must be a markdown hyperlink in the PR body, and the PR URL
   must be attached to the Linear issue — both directions, every time.
4. Assignee is `JuaniRios`; reviewers are `0xgleb` and `findolor`.
5. The skeleton description (step 3) may be auto-approved since it's an explicit
   WIP placeholder; the **final** description (step 9) requires explicit user
   confirmation.
6. In `/review-loop`, decide most findings yourself — only escalate genuinely
   ambiguous ones.
7. Don't declare done until CI is actually green.

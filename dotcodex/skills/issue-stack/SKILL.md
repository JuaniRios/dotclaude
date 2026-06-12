---
name: issue-stack
description: "Use when the user asks to implement a stack or ordered batch of Linear issues with minimal supervision, creating one Graphite branch/PR per issue and advancing only when each issue is verified."
---

# issue-stack

Codex-native port of the former Claude slash command `issue-stack`.

Implement an ordered stack of Linear issues. Each issue should become its own
independently reviewable Graphite branch/PR, with dependencies represented in
the stack order and Linear relations.

## Required Companion Skills

- `implement-issue` for the per-issue workflow.
- `linear-cli` for issue inspection and updates.
- `graphite` for all branch/commit/submit operations.
- `review-loop`, `pr-description`, and `ci-fix` as each issue reaches those
  phases.

## Inputs

The user must provide an ordered list of issue IDs/URLs or a Linear project that
can be resolved into an ordered set. If order is ambiguous, ask for the order
before starting.

## Workflow

1. Preflight the stack.
   - Resolve all issue IDs and titles.
   - Read dependencies and blockers:
     ```bash
     linear issue relation list <ISSUE_ID>
     ```
   - Verify the requested order does not contradict known blockers.
   - Check the repo and Graphite stack:
     ```bash
     git status --short
     gt log short
     ```
   - Stop if unrelated dirty changes would be touched.

2. Create a stack plan.
   - One branch/PR per issue.
   - Shared prerequisites go first.
   - Conflict-prone or integration-heavy work goes last.
   - Record the plan with `update_plan`.
   - Keep a session log under `.tmp/issue-stack/<timestamp>.md`.

3. Ask for one upfront confirmation if the stack will run autonomously. After
   confirmation, do not ask between issues unless blocked by ambiguity, failing
   external systems, or a risky irreversible action.

4. For each issue in order:
   - Follow the `implement-issue` workflow.
   - Keep changes scoped to that issue's branch.
   - Run targeted checks and required final checks according to the session
     policy.
   - Run review before submission for substantive code.
   - Submit with Graphite.
   - Poll CI for the current commit — the run whose `headSha` matches the pushed
     HEAD, not just the newest run on the branch. If no run appears for this HEAD
     (~90s), Graphite skipped CI for this branch (6th+ in the stack); run the
     full local CI matrix (`nix run .#ci`) as the gate instead.
   - Do not start the next issue until the current issue is submitted and its
     required checks are green (remote run for this HEAD, or the local matrix
     when Graphite skipped CI) — never a stale run from an earlier commit —
     unless the user explicitly authorizes parallel CI risk.

5. Handle failures.
   - If CI fails, use `ci-fix` and resubmit the same branch.
   - If an issue is blocked by missing information, record the blocker in the
     log, update Linear if appropriate, and stop rather than guessing.
   - If the stack order is wrong, explain the conflict and ask for the new order
     before moving branches.

6. Finish the stack.
   - Report each issue, branch, PR, CI status, and Linear status.
   - Note any skipped issue and the exact blocker.
   - Leave the working tree clean or explicitly report uncommitted files.

## Hard Rules

- Do not combine unrelated issues into one branch.
- Do not move to the next issue while the current branch has unresolved test,
  review, or CI failures.
- Do not use raw git mutations; use Graphite.
- Do not ask repeated checkpoint questions after the upfront autonomous-run
  confirmation.
- Keep the `.tmp/issue-stack` log out of git.

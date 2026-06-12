---
name: implement-issue
description: "Use when the user asks to implement a Linear issue end to end: inspect the issue, open a branch/PR with Graphite, plan, implement, review, submit, watch CI, and update Linear."
---

# implement-issue

Codex-native port of the former Claude slash command `implement-issue`.

Implement one Linear issue completely, from issue intake through submitted PR
and CI status. This workflow is intentionally structured because it touches
Linear, git/Graphite, GitHub, implementation, review, and CI.

## Required Companion Skills

Use these skills when their phase is reached:
- `linear-cli` for all Linear reads/writes.
- `graphite` for every version-control mutation.
- `pr-description` when drafting or updating the PR description.
- `review-loop` before final submission when there is code.
- `ci-fix` if GitHub CI fails.

## Inputs

The user should provide a Linear issue ID or URL. If they do not, ask for the
issue identifier and stop until they provide it.

## Workflow

1. Load the issue.
   ```bash
   linear issue view <ISSUE_ID>
   linear issue describe <ISSUE_ID>
   linear issue relation list <ISSUE_ID>
   ```
   Capture title, status, project, parent/children, blockers, acceptance
   criteria, and links.

2. Preflight the repo.
   - Read repository agent instructions and relevant docs before editing.
   - Check working tree status and stack shape:
     ```bash
     git status --short
     gt log short
     ```
   - If there are unrelated user changes that would be touched by the issue,
     stop and ask how to separate them.

3. Start or select the branch with Graphite.
   - If already on the correct issue branch, continue.
   - Otherwise use the repo's normal Graphite flow to create/check out the
     branch.
   - Mark the Linear issue In Progress when work starts.

4. Open or update a draft PR early when the repo workflow expects one.
   Use Graphite/GitHub through the available local tools. Link the PR to the
   Linear issue and add a WIP description that states the goal and current plan.

5. Build an implementation plan.
   - Read the code paths and tests relevant to the issue.
   - Produce a short plan with concrete steps.
   - Use `update_plan` to track progress.
   - If the issue requires a significant architecture decision not covered by
     existing docs, write an ADR and stop for user review before implementing.

6. Get plan approval when the solution is non-trivial or the issue leaves major
   choices open. Ask a concise plain-text question. Once approved, implement
   without repeated permission prompts.

7. Implement with tests.
   - Write or update tests before or alongside the behavior change.
   - Keep the diff scoped to the issue.
   - Follow the repository's docs, naming, and formatting conventions.
   - Use multi-agent tools for independent research or review only when they
     are available and useful; otherwise do the work locally.

8. Verify locally at the narrowest useful scope first. Run the repo's required
   final checks unless the user enabled a remote-checks policy for this session.
   Fix every failure that is in scope for the branch.

9. Run review.
   - Use `review-loop` for substantive code changes.
   - Address actionable findings.
   - Re-run targeted verification after fixes.

10. Update the PR.
    - Use `pr-description` to draft or refresh the PR title/body.
    - Ensure the Linear issue is linked.

11. Amend and submit with Graphite.
    ```bash
    gt add <files>
    gt modify
    gt submit --no-interactive --no-edit-description
    ```
    Use `gt create` instead of `gt modify` when creating the first commit for a
    new branch.

12. Watch CI for the pushed HEAD (the run whose `headSha` matches
    `git rev-parse HEAD`, not merely the newest run on the branch).
    - If CI passes, move the Linear issue to the appropriate done/review state
      according to repo instructions.
    - If CI fails, use `ci-fix`, amend with Graphite, resubmit, and keep
      watching the run for the new HEAD.
    - If no run ever appears for this HEAD (~90s), Graphite skipped CI for this
      branch (6th+ in the stack). Run the full local CI matrix (`nix run .#ci`)
      as the gate instead; never accept a stale run from an earlier commit.

13. Final report.
    Include the issue ID, branch, PR link, verification performed, CI status,
    and any follow-up risks.

## Hard Rules

- Never mutate git state with raw `git`; use Graphite.
- Never silently skip test coverage for changed logic.
- Never proceed past a material architecture decision without a recorded
  decision and user review.
- Do not include unrelated user changes in the commit.
- Keep Linear and PR status current as part of the work, not as a separate
  cleanup left to the user.

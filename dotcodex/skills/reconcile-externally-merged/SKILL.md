---
name: reconcile-externally-merged
description: "Use when the user asks to run the former Claude /reconcile-externally-merged workflow: Apply missing externally-merged labels to Graphite-landed closed PRs and audit the workflow that should have labelled them."
---

# reconcile-externally-merged

Codex adaptation of the Claude slash command `reconcile-externally-merged`.
Follow the workflow below, but use Codex-native tools and normal user questions
where the original mentions Claude-only mechanisms.

Compatibility notes:
- Treat `$ARGUMENTS` as the relevant arguments or intent from the user's
  request.
- Replace `AskUserQuestion` with a concise question to the user when a decision
  is required.
- Replace Claude `Agent` calls with Codex subagents only when the user
  explicitly asks for parallel agents; otherwise do the work locally.
- Ignore Claude `allowed-tools`, `argument-hint`, `TodoWrite`, and `Skill` tool
  references as tool-permission metadata.
- When the workflow mentions another slash command, use the corresponding Codex
  skill or follow that workflow directly.

Backstop the `externally-merged` PR label. Sweep recent `master` commits, apply
the label to Graphite-landed PRs that are closed-but-not-GitHub-merged and
missing it, then audit whether the `externally-merged.yaml` workflow fired and
succeeded.

Why this exists: Graphite's merge queue can land batched PRs by pushing squash
commits to `master` and closing the PRs instead of marking them merged. Linear
only treats a closed PR as merged when it carries the `externally-merged` label,
so linked issues can stay open without it. The CI workflow is supposed to apply
that label automatically on PR close; this workflow catches gaps and explains
why automation missed them.

Run from the repo root. `gh` auto-detects the repo. Default window is the past 7
days; if the user gives a number, use that many days instead.

## 1. Collect PRs referenced by recent master commits

Fetch `origin/master` first if it may be stale.

```bash
git log origin/master --since="<N> days ago" --first-parent \
  --pretty=format:'%H %s'
```

Extract the trailing `(#NNN)` from each commit subject. This is the
squash/merge convention identifying the PR that landed the commit. Ignore bare
`#NNN` mentions in commit bodies. Deduplicate PR numbers.

## 2. Classify each PR

For each PR:

```bash
gh pr view <N> --json number,state,merged,labels,title,headRefName,closedAt
```

Classify:

- `MERGED`: landed via native GitHub merge. No label needed; skip.
- `CLOSED`: Graphite closed it after pushing the squash commit.
  - Has `externally-merged`: record as OK.
  - Missing `externally-merged`: record as GAP for steps 3 and 4.
- `OPEN`: unexpected because a commit is on master while the PR is open. Record
  as anomaly and do not label.

## 3. Apply the label to gaps

For every GAP PR, apply the label without asking:

```bash
gh pr edit <N> --add-label externally-merged
```

If the label does not exist, create it to match the CI workflow's definition and
retry:

```bash
gh label create externally-merged \
  --color 6f42c1 \
  --description "Graphite MQ merged this PR; Linear should treat the close as a merge"
```

## 4. Audit why CI missed each gap

A GAP means the CI workflow either did not fire, did not match its guard, or
failed. For each GAP PR, find the workflow run for its head branch around close
time:

```bash
gh run list --workflow "Externally merged label" \
  --json databaseId,headBranch,event,status,conclusion,createdAt --limit 50
```

Match on `headRefName` from step 2. Then classify the cause:

- No run found: the `closed` event did not trigger or the branch was deleted
  before the run was retained. Check whether the PR was closed by someone other
  than `graphite-app[bot]` or whether its head ref started with `gtmq`, both of
  which may be intentionally skipped by the workflow guard.
- Run exists and `conclusion: success`, but label absent: the workflow likely
  no-opped because its Graphite marker check failed. Flag for investigation.
- Run exists and `conclusion: failure`: pull failing logs and report the failing
  step:

  ```bash
  gh run view <databaseId> --log-failed
  ```

Do not modify the workflow automatically. Report the cause and suggest a
concrete next step.

## 5. Report

Print a single summary table covering every PR in the window:

```markdown
| PR | State | Label before | Action | CI verdict |
|----|-------|--------------|--------|------------|
```

Then include:

- Labels applied: PRs newly labelled in step 3.
- CI investigation: for each gap, the step 4 cause and suggested next step.
- Anomalies: any `OPEN` PRs discovered from master commits.

If there were zero gaps and every closed PR already had the label, say so
explicitly.

## Hard rules

1. Only apply `externally-merged` to CLOSED PRs referenced by a squash commit on
   master. Never label OPEN or MERGED PRs.
2. Extract PR numbers from the commit subject's trailing `(#NNN)` only.
3. Apply labels automatically, but never modify CI workflow files or close/reopen
   PRs without explicit user instruction.
4. Always report the CI verdict for each gap. Applying the label silently hides
   broken automation.

## Failure modes

- `origin/master` stale: fetch `origin master` before collecting commits.
- `gh` not authenticated: stop and tell the user to run `gh auth login`.
- Label missing: create it as described, then retry.
- Branch deleted and no run found: report as "run not retained"; the label
  application still stands as the fix.

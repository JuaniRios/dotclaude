---
name: draft-release
description: "Use when the user asks to run the former Claude /draft-release workflow: Draft release notes by diffing the latest GitHub release against master, including Graphite-merged PRs resolved from commit trailers."
---

# draft-release

Codex adaptation of the Claude slash command `draft-release`. Follow the
workflow below, but use Codex-native tools and normal user questions where the
original mentions Claude-only mechanisms.

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

Draft release notes for the current repo covering everything that landed on
`master` since the latest published GitHub release. Output has two layers: a
plain-English summary anyone can read at the top, then a technical PR-by-PR
breakdown below.

Why this workflow exists: the repo merges through the Graphite merge queue,
which lands squashed commits on `master` but may leave the original PRs closed
instead of GitHub-merged. GitHub's built-in release-note generator only counts
PRs flagged as merged, so it can silently drop work. This workflow walks the
actual commits on `master` and resolves each commit's PR number from the commit
subject, so closed-but-landed PRs are still included.

Follow these steps precisely.

## 1. Orient on the repo and baseline

```bash
repo_root=$(git rev-parse --show-toplevel)
git fetch origin master --tags --quiet
last_tag=$(gh release view --json tagName --jq '.tagName')
head_sha=$(git rev-parse origin/master)
```

If `gh release view` fails because no releases exist, tell the user and ask
whether to use the very first commit as the baseline instead. Do not invent a
tag.

Print the baseline release tag, its date, and the `origin/master` head SHA being
diffed:

```bash
gh release view "$last_tag" --json publishedAt --jq '.publishedAt'
git rev-parse origin/master
```

Stop and ask if any of that looks wrong before drafting.

## 2. Collect the commits in range

```bash
git --no-pager log --no-merges --pretty=format:'%H%x09%s' "$last_tag"..origin/master
```

This is the authoritative work list: every commit that landed since the release,
regardless of PR merge state. If it is empty, report that there is nothing to
release since `$last_tag` and stop.

## 3. Resolve each commit to its PR

Graphite squash commits carry the PR number as a `(#NNN)` suffix in the subject,
for example:

```text
fix: reassert configured Raindex vault primaries (#831)
```

For each commit:

1. Extract the trailing `#NNN` from the subject.
2. Fetch the PR regardless of state:

   ```bash
   gh pr view <NNN> --json number,title,author,body,labels,url,state,mergedAt
   ```

3. If a commit has no `#NNN` suffix, keep it keyed by short SHA and subject. Do
   not drop it. Note in the output that it had no associated PR.

Batch these reads; do not ask the user between PRs. If `gh pr view` 404s, fall
back to the commit subject/body and flag the PR as unresolved.

## 4. Understand what each PR actually did

For each resolved PR, read its title, body, and labels to understand:

- What changed: the user-visible or behavioral effect.
- Why it was needed: bug fix, feature, infra, refactor.
- Risk or notes worth calling out: migrations, config changes, breaking
  changes, prod-affecting fixes.

Group related PRs by theme, such as "Hedging", "Rebalancing", "Infra/CI", or
"Tokenized equities". Infer themes from titles, labels, bodies, and the
conventional-commit prefix (`feat`, `fix`, `chore`, `refactor`, etc.).

## 5. Write the release notes

Write to:

```bash
"$repo_root"/.tmp/release-notes-<last_tag>-to-<head_short_sha>.md
```

Create `.tmp/` if missing. It is expected to be gitignored.

Use this structure:

```markdown
# Release notes: <last_tag> -> <new head>

_<N> PRs / <M> commits since <last_tag> (released <date>)._

## Summary

<3-8 plain-English bullets. No jargon, no PR numbers, no symbol names. Describe
what changed from a user/operator perspective. A non-engineer should understand
the impact of this release from this section alone.>

### Highlights

<Optional: 1-2 lines on the single most important change, if there is one.>

## Pull requests

<A flat list of every PR in this release with its author, in merge order. Build
this from the resolved commit -> PR mapping, never from GitHub's merge state.>

- **#NNN** <PR title> - _@author_
- **#NNN** <PR title> - _@author_
- **<short-sha>** <subject> (no associated PR)

## Technical changelog

### <Theme>

- **#NNN** <type>: <concise technical description of what the PR changed and why> - _@author_

### Uncategorized / direct commits

- **<short-sha>** <subject> (no associated PR)
```

Rules for the technical section:

- One bullet per PR, ordered by merge order within each theme.
- Lead with the PR number.
- Describe the change, not just the commit subject. Add the "why" when the title
  alone is opaque.
- Call out migrations, config/secret changes, and prod-affecting fixes
  explicitly with an inline bold tag such as `**migration**`, `**config**`, or
  `**prod**`.

## 6. Surface it

After writing the file:

- Print the Summary section verbatim in chat so the user can read it without
  opening the file.
- Print the file path.
- Print the counts and the baseline/head covered.

Do not create a GitHub release, push a tag, or run any mutating GitHub command.
This workflow only drafts notes for human review.

## Hard rules

1. Never trust GitHub's PR merge-state to build the work list. The work list is
   always the commit log `"$last_tag"..origin/master`; PRs are resolved from
   those commits.
2. Never drop a commit. Every commit in range appears in the output, under its
   PR if it has one or under direct commits if not.
3. Read every PR body you resolve. Do not summarize from title alone when the
   body has context.
4. Three-layer output is mandatory: non-technical summary first, flat pull
   request list second, technical breakdown third.
5. Write to `.tmp/` only. Never write release notes to a tracked path, create a
   GitHub release, or push a tag.

## Failure modes

- No releases exist: ask whether to baseline from the first commit; do not guess
  a tag.
- Empty commit range: report "nothing to release since `<tag>`" and stop.
- PR fetch 404 or fork PR: fall back to commit subject/body, flag it unresolved,
  and keep going.
- Commit with no `#NNN`: list it under direct commits with its short SHA.

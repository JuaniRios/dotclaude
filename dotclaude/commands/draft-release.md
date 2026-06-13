---
allowed-tools: Bash(gh:*), Bash(git:*), Bash(mkdir:*), Bash(test:*), Bash(date:*), Bash(wc:*), Bash(sort:*), Bash(grep:*), Bash(sed:*), Read, Write
description: Draft release notes by diffing the last GitHub release against master — a non-technical summary on top, then a technical PR-by-PR breakdown. Resolves PRs via commit trailers so graphite-merged (closed-not-merged) PRs are still captured.
argument-hint: (no args — baseline is the latest GitHub release)
---

Draft release notes for this repo covering everything that landed on `master`
since the last published GitHub release. Output is two layers: a plain-English
summary anyone can read at the top, then a technical, PR-by-PR breakdown below.

**Why this command exists:** the repo merges via the Graphite merge queue, which
lands squashed commits on `master` but leaves the original PRs marked **closed,
not merged** on GitHub. GitHub's built-in "Generate release notes" only counts
PRs flagged as *merged*, so it silently drops most of our work. This command
instead walks the actual commits on `master` and resolves each one's PR by
number, so closed-but-merged PRs are still included.

Follow these steps precisely.

## 1. Orient on the repo and baseline

```bash
repo_root=$(git rev-parse --show-toplevel)
git fetch origin master --tags --quiet
last_tag=$(gh release view --json tagName --jq '.tagName')
head_sha=$(git rev-parse origin/master)
```

If `gh release view` fails (no releases exist yet), tell the user and ask
whether to use the very first commit as the baseline instead. Do not invent a
tag.

Print: the baseline release tag, its date (`gh release view "$last_tag" --json
publishedAt --jq '.publishedAt'`), and the `origin/master` head SHA you're
diffing to. Stop and ask if any of that looks wrong.

## 2. Collect the commits in range

```bash
git --no-pager log --no-merges --pretty=format:'%H%x09%s' "$last_tag"..origin/master
```

This is the authoritative work list — every commit that landed since the
release, regardless of PR merge-state. If it's empty, report that there's
nothing to release since `$last_tag` and stop.

## 3. Resolve each commit to its PR

Graphite squash commits carry the PR number as a `(#NNN)` suffix in the subject
(e.g. `fix: reassert configured Raindex vault primaries (#831)`). For each
commit:

1. Extract the trailing `#NNN` from the subject.
2. Fetch the PR regardless of state (this is the crux — `gh pr view` returns
   closed-but-merged PRs that GitHub's release generator skips):

   ```bash
   gh pr view <NNN> --json number,title,author,body,labels,url,state,mergedAt
   ```

3. If a commit has **no** `#NNN` suffix (direct push, or hotfix), keep it in the
   list keyed by its short SHA and subject — do not drop it. Note in the output
   that it had no associated PR.

Batch these reads; don't ask the user between each PR. If a `gh pr view` 404s
(PR from a fork, or deleted), fall back to the commit subject/body and flag it.

## 4. Understand what each PR actually did

For each resolved PR, read its title, body, and labels to understand:
- **What** changed (the user-visible or behavioral effect).
- **Why** it was needed (bug fix, feature, infra, refactor).
- **Risk/notes** worth calling out (migrations, config changes, breaking
  changes, prod-affecting fixes).

Group related PRs by theme (e.g. "Hedging", "Rebalancing", "Infra/CI",
"Tokenized equities") — infer themes from titles, labels, and the conventional-
commit prefix (`feat`/`fix`/`chore`/`refactor`).

## 5. Write the release notes

Write to `"$repo_root"/.tmp/release-notes-<last_tag>-to-<head_short_sha>.md`
(create `.tmp/` if missing — it's gitignored). Structure:

```markdown
# Release notes: <last_tag> -> <new head>

_<N> PRs / <M> commits since <last_tag> (released <date>)._

## Summary

<3-8 plain-English bullets. No jargon, no PR numbers, no symbol names.
Describe what changed from a user/operator perspective: "The bot now recovers
automatically from X", "Fixed a bug where Y", "Added support for Z equity".
A non-engineer should understand the impact of this release from this section
alone.>

### Highlights

<Optional: 1-2 lines on the single most important change, if there is one.>

## Technical changelog

Grouped by theme. One line per PR:

### <Theme>
- **#NNN** <type>: <concise technical description of what the PR changed and
  why> — _@author_

### <Theme>
- ...

### Uncategorized / direct commits
- **<short-sha>** <subject> (no associated PR)
```

Rules for the technical section:
- One bullet per PR, ordered by merge order within each theme.
- Lead with the PR number so reviewers can click through.
- Describe the *change*, not just restate the commit subject — add the "why"
  when the title alone is opaque.
- Call out migrations, config/secret changes, and prod-affecting fixes
  explicitly (bold a `migration` / `config` / `prod` tag inline).

## 6. Surface it

After writing the file:
- Print the **Summary** section verbatim in chat so the user can read it
  without opening the file.
- Print the file path.
- Print the counts (PRs, commits) and the baseline/head it covered.

Do **not** create a GitHub release, push a tag, or run any mutating command.
This command only drafts notes for human review.

## Hard rules

1. **Never trust GitHub's PR merge-state to build the list.** The work list is
   always the commit log `"$last_tag"..origin/master`. PRs are resolved *from*
   those commits, never the other way around.
2. **Never drop a commit.** Every commit in range appears in the output — under
   its PR if it has one, under "direct commits" if not.
3. Read every PR body you resolve; don't summarize from the title alone when the
   body has context.
4. Two-layer output is mandatory: non-technical summary first, technical
   breakdown second.
5. Write to `.tmp/` only — never to a tracked path, and never create a GitHub
   release.

## Failure modes

- **No releases exist (`gh release view` fails):** ask whether to baseline from
  the first commit; don't guess a tag.
- **Empty commit range:** report "nothing to release since `<tag>`" and stop.
- **PR fetch 404 / fork PR:** fall back to commit subject + body, flag the
  bullet as unresolved, keep going.
- **Commit with no `#NNN`:** list under "direct commits" with its short SHA.

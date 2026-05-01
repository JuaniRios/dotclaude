---
allowed-tools: Bash(gh:*), Bash(git:*), Bash(codex:*), Bash(gemini:*), Bash(mkdir:*), Bash(wc:*), Bash(date:*), Bash(basename:*), Bash(test:*), Bash(grep:*), Read, Write, Agent, Skill
description: Cross-review a pull request by number or URL without checking it out. Runs three reviewers in parallel, aggregates, and starts a conversation so you can decide which findings (if any) to comment on the PR.
argument-hint: <pr-number | pr-url>
---

Cross-review a pull request that is **not** currently checked out. The PR
number or URL is passed in `$ARGUMENTS`. Use when you're reviewing someone
else's PR and want independent, three-model analysis before commenting.

Follow these steps precisely.

## 1. Parse the argument

`$ARGUMENTS` must be a PR number (e.g. `123`), a full GitHub URL
(`https://github.com/owner/repo/pull/123`), or an `owner/repo#123` shorthand.
If `$ARGUMENTS` is empty, use the PR associated with the current branch.

Normalize to `(owner, repo, number)` using `gh`:

```bash
pr_ref="$ARGUMENTS"

if [ -z "$pr_ref" ]; then
  # No argument — use the PR for the currently checked-out branch
  pr_json=$(gh pr view --json number,title,author,headRefName,baseRefName,url,body,headRepository,baseRepository,headRefOid,baseRefOid,state,isDraft,additions,deletions,changedFiles)
else
  case "$pr_ref" in
    https://github.com/*) ;;
    */*\#*)              ;;  # owner/repo#n
    [0-9]*)              ;;  # bare number (use current repo)
    *) echo "Unrecognized PR reference: $pr_ref"; exit 1 ;;
  esac
  pr_json=$(gh pr view "$pr_ref" --json number,title,author,headRefName,baseRefName,url,body,headRepository,baseRepository,headRefOid,baseRefOid,state,isDraft,additions,deletions,changedFiles)
fi
```

If `gh pr view` fails (e.g. no PR exists for the current branch), stop and
tell the user — they need to either pass a PR reference or check out a branch
that has an open PR.

Record the fields from the JSON: `number`, `title`, `author.login`,
`headRefName`, `baseRefName`, `url`, `body`, `headRefOid`, `baseRefOid`,
`state`, `isDraft`, `changedFiles`, `additions`, `deletions`, and the owner/name
of the head and base repos.

If the PR is closed, merged, or draft, warn the user and ask whether to
continue. Proceed only on explicit confirmation.

## 2. Prepare the workspace

```bash
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
ts=$(date +%Y-%m-%d_%H-%M-%S)
safe_branch=$(echo "<headRefName>" | tr '/' '_')
out_dir="$repo_root/claude-local-ctx/reviews/pr-${pr_number}-${ts}-${safe_branch}"
mkdir -p "$out_dir"
```

If `claude-local-ctx/` is not in `.gitignore`, ask the user for permission to
add it. Do not silently modify `.gitignore`.

## 3. Fetch the diff

Fetch the PR diff from GitHub — do not check out the PR:

```bash
gh pr diff "<pr-ref>" > "$out_dir/diff.patch"
gh pr view "<pr-ref>" --json files --jq '.files[] | "\(.additions)\t\(.deletions)\t\(.path)"' > "$out_dir/files.txt"
wc -l "$out_dir/diff.patch"
```

Refuse to proceed on an empty diff. Warn on diffs larger than 5000 lines and
ask whether to continue — reviewer quality degrades on huge diffs.

Also save the PR metadata and the author's description:

```bash
echo "$pr_json" > "$out_dir/pr.json"
```

## 4. Fetch the head ref for context

The reviewers need to read source files that the diff references, even if
they're not changed by the PR. Fetch the head ref into the local repo
without switching branches:

```bash
head_owner_repo="<owner>/<repo>"   # from headRepository.nameWithOwner
head_sha="<headRefOid>"

# If the PR is from a fork, add the fork as a remote
git remote add pr-review-head "https://github.com/${head_owner_repo}.git" 2>/dev/null || true
git fetch pr-review-head "$head_sha"

# Now reviewers can resolve paths at that commit via `git show $head_sha:<path>`
```

If the PR is on the same repo, skip the remote-add step; the fetch is enough.

In the reviewer prompt, tell each reviewer they can read any file at
`<head_sha>:<path>` via `git show` — they should not assume the working tree
matches the PR.

## 5. Load project context

```bash
find "$repo_root" -maxdepth 3 \( -name "CLAUDE.md" -o -name "AGENTS.md" \) \
  -not -path "*/node_modules/*" -not -path "*/target/*"
```

Keep only the paths. Reviewers will read them themselves.

## 6. Run cross-review

Invoke the `cross-review` skill's orchestration, with these overrides:

- **Scope** is the fetched diff at `$out_dir/diff.patch` (not `gt parent..HEAD`).
- **Repo root** is the local checkout (same as normal).
- **Reviewers** get the head SHA in their prompt so they can read source at
  that commit: "The PR was authored against commit `<head_sha>`. Read source
  files via `git show $head_sha:<path>` — the working tree does not match."
- **Aggregator** receives the PR metadata (title, author, description) as
  extra context alongside the reviews.

All three reviewers run in parallel in a single message (Opus via Agent, Codex
via `codex exec --sandbox read-only`, Gemini via `gemini -p --approval-mode plan`).
Save raw outputs to `$out_dir/raw-{opus,codex,gemini}.md`.

## 7. Aggregate with review-pr-specific output

The aggregator produces `$out_dir/review.md` — same format as the
`cross-review` skill, **except**:

- **No AI references anywhere in output.** No agent attribution, no
  "Found by:", no mention of models, reviewers, or cross-review. The
  terminal summary and any posted review must read like a normal human
  code review. Keep attribution only in `raw-*.md` for local audit.
- **Include the PR metadata at the top**: number, title, author, URL,
  head/base branches, SHA, files changed, additions/deletions.
- **Frame the "Overall assessment"** as advice to the *reviewer* (you, the
  user), not to the PR author — e.g., "This PR looks ready to merge
  pending X" or "I'd push back on Y before approving."

## 8. Print findings to the terminal

Print a compact summary, same format as `cross-review` but without agent
attribution on each finding:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PR #<n> — <title>
<author>  ·  <head>..<base>  ·  <N> files, +<add>/-<del> lines
<url>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▲ CRITICAL (count)
  1. <title>
     <file>:<line>  confidence: 95
     <one-line fix>
...

▽ Dismissed as invalid: <count>
▽ Dismissed as out-of-scope: <count>

Full report: <absolute path to review.md>
```

## 9. Enter the review conversation

After printing, **stay in the session**. Do not end the turn with a summary
— the user wants to have a conversation about the findings.

Say something like:

> Review saved to `<path>`. Let me know which findings you want to dig into,
> and when you're ready I can post comments on the PR.

Then wait. For any follow-up question:

- **"tell me more about #N"** — read the full finding from `review.md` and
  explain it in conversational form. Read the relevant source via
  `git show $head_sha:<path>` to confirm the claim yourself.
- **"is finding #N actually valid?"** — verify by reading the code at the
  head SHA. Report your independent read.
- **"draft a comment for #N"** — write a PR-comment-style message (concise,
  constructive, cite file/line, propose fix). Show it to the user and wait
  for approval.
- **"post"** or **"post as draft"** — create a **pending (draft) GitHub
  review** with inline comments. See "Posting a draft review" below.
  The user will inspect, edit, and submit from the GitHub UI — no
  per-comment text approval is needed here.
- **"post #N, #M"** — same as "post" but only include the listed findings.
- **"I'm done"** — summarize what was posted (if anything) and end the turn.

### Posting a draft review

When the user says "post" or "post as draft", create a **PENDING** GitHub
review with each finding as an inline comment on its file/line. This lets
the user go to the GitHub UI, inspect each comment, edit or delete as
needed, and click "Submit review" themselves.

**Step 1 — Build the comments JSON.** For each finding, create an inline
comment object. Use the finding's file path and line number from the
review.

**Comment tone rules:**
- Write like a human colleague leaving a quick review comment. Short,
  direct, conversational.
- No numbered prefixes like `#1`, `**#2 (HIGH)**`, etc. Just say what
  the issue is.
- No em dashes. Use commas, periods, or "because" instead.
- No bold severity labels in the comment body. If you want to signal
  severity, say something like "this should be fixed before merge" or
  "nit:" or "minor:".
- No bullet-point lists inside a single comment unless genuinely needed.
  Prefer short paragraphs.
- Keep each comment to 2-4 sentences. Say what's wrong, why it matters,
  and what to do about it.

```bash
# Build the review payload as a JSON file
review_json=$(mktemp -t pr-review.XXXXXX.json)
cat > "$review_json" <<'ENDJSON'
{
  "commit_id": "<head_sha>",
  "body": "<overall assessment — 2-3 sentences>",
  "comments": [
    {
      "path": "<file relative to repo root>",
      "line": <line number in NEW file>,
      "side": "RIGHT",
      "body": "<finding description + suggested fix>"
    }
  ]
}
ENDJSON
```

For findings that span a range, use `start_line` + `line`:
```json
{ "path": "src/foo.rs", "start_line": 10, "line": 15, "side": "RIGHT", "body": "..." }
```

**Step 2 — Post via the Reviews API.**

```bash
gh api repos/<owner>/<repo>/pulls/<pr-number>/reviews \
  --input "$review_json"
rm "$review_json"
```

**CRITICAL: Omit the `event` field entirely to create a PENDING review.**
The GitHub API does NOT accept `"event": "PENDING"` — it returns a 422.
Omitting `event` is what makes the review a draft.

This creates a draft review visible only to you (the reviewer) until
submitted. Tell the user:

> Draft review created with N inline comments. Go to <pr-url> to
> inspect, edit, or delete comments, then click "Submit review."

**CRITICAL: `line` must be a line present in the diff hunk, not any
arbitrary line in the file.** To find the right line number:
- Read the diff (`$out_dir/diff.patch`) and identify the `+`-side line
  number within the changed hunk that best matches the finding
- If the finding points to a line NOT in the diff, use the nearest
  changed line in the same file, or fall back to creating a top-level
  review comment instead of an inline one

**Step 3 — Handle findings without diff lines.** If a finding references
code that isn't in the diff (e.g., a missing test, a documentation issue),
include it in the review `body` (top-level comment) rather than as an
inline comment.

## Hard rules

1. Never check out the PR branch. Work off `gh pr diff` and `git show` at
   the head SHA.
2. `review.md` has no per-finding agent attribution. Keep attribution in
   `raw-*.md` only.
3. For draft reviews ("post" / "post as draft"), per-comment approval is
   NOT required — the GitHub UI is the approval mechanism. For immediate
   submissions (non-draft), never post without explicit user approval of
   the exact text.
4. Always use `--body-file` (or heredoc to a tempfile) for comment bodies.
5. Stay in the session after printing — this command is a conversation,
   not a one-shot.
6. If the PR is closed/merged/draft, ask before proceeding.
7. **Posted reviews must read like a human wrote them.** No AI references
   (models, agents, "cross-review", Claude, Codex, Gemini). No numbered
   finding prefixes (`#1`, `**#2 (HIGH)**`). No em dashes. No bold
   severity labels. No fancy formatting. Write short, direct comments
   like a colleague would. The `raw-*.md` and `review.md` on disk can
   use structured formatting (they're local), but anything posted to
   GitHub must be conversational and concise.

---
allowed-tools: Bash(gh:*), Bash(git:*), Bash(find:*), Bash(date:*), Bash(test:*), Bash(ls:*), Bash(jq:*), Bash(mktemp:*), Bash(cat:*), Bash(rm:*), Bash(wc:*), Read, Grep, Glob, Agent
description: Publish cross-review findings as a pending GitHub PR review with inline comments. Run after /review-pr.
argument-hint: [review-dir-path]
---

Publish findings from a cross-review report as a **pending** GitHub PR review
with inline comments. The user runs this after `/review-pr` to push findings
onto the PR for inspection on the Graphite dashboard.

## 1. Locate the review

If `$ARGUMENTS` is provided, treat it as the path to a review directory or
`review.md` file.

If `$ARGUMENTS` is empty, find the most recent review:

```bash
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
latest=$(ls -dt "$repo_root"/claude-local-ctx/reviews/pr-*/ 2>/dev/null | head -1)
```

If no review directory is found, stop and tell the user to run `/review-pr`
first.

Confirm the review file exists at `$latest/review.md`. Read it.

## 2. Extract PR metadata

From the review directory name, extract the PR number (e.g., `pr-534-...` ->
`534`). Verify the PR exists:

```bash
gh pr view <number> --json number,headRefOid,headRefName,baseRefName,url
```

Record the `headRefOid` (commit SHA) -- needed for the review API.

## 3. Parse findings

Read `review.md` and extract every finding that has:
- A `**File:**` line with `<path>:<line>` (or `<path>:<start>-<end>`)
- A severity level (from the `### [SEVERITY]` heading)

**Stop parsing** when you hit "Findings dismissed as invalid" or "Findings
dismissed as out-of-scope" sections. Skip everything from those sections
onward.

For each finding, extract:
- `path` -- relative file path
- `line` -- the line number (use start line if a range)
- `severity` -- HIGH, MEDIUM, LOW, NIT
- `title` -- the finding title from the heading
- `issue` -- the `**Issue:**` content
- `fix` -- the `**Recommended fix:**` content

## 4. Compose inline comments

For each finding, write a **concise, human-like** inline comment. Do NOT
copy the markdown verbatim. Transform each finding into a short review
comment that:

- Leads with what's wrong in 1-2 sentences
- Suggests the fix in 1-2 sentences
- Prefixes with a severity tag: `[high]`, `[medium]`, `[low]`, `[nit]`
- Reads like a human reviewer wrote it, not a report generator

Example transformation:

**From review.md:**
> `### [HIGH] Non-unique Svelte {#each} key in trade history panel`
> `**Issue:** The {#each} key is trade.filledAt + trade.symbol + trade.venue.
> Two rapid fills for the same symbol on the same venue at the same timestamp
> will produce duplicate keys...`
> `**Recommended fix:** Add a unique identifier to the Trade DTO...`

**Becomes inline comment:**
> `[high] This key can collide when two fills happen at the same
> timestamp for the same symbol/venue -- Svelte will silently skip
> rendering a row. Add a unique ID to the Trade DTO (e.g. aggregate ID
> or tx_hash:log_index) and use that as the key.`

## 5. Create a pending review

Build a JSON payload file with all comments:

```json
{
  "commit_id": "<headRefOid>",
  "body": "Cross-review findings -- <N> comments.",
  "comments": [
    {
      "path": "relative/file/path.rs",
      "line": 42,
      "body": "[high] Concise comment here."
    }
  ]
}
```

Write the JSON to a temp file and POST it:

```bash
payload=$(mktemp -t publish-review.XXXXXX.json)
# ... write JSON to $payload ...
gh api repos/{owner}/{repo}/pulls/{number}/reviews \
  --method POST \
  --input "$payload"
rm "$payload"
```

**CRITICAL:** Do NOT include an `event` field in the payload. Omitting
`event` creates the review in PENDING state. The user will inspect and
submit from the Graphite dashboard.

## 6. Verify and report

After the API call succeeds, print:

```
Review created on PR #<N> (PENDING -- not submitted)

  <count> inline comments:
    [severity] <path>:<line> -- <short title>
    ...

  Dashboard: <pr-url>

Go to Graphite to inspect, edit, and submit the review.
```

## Hard rules

1. The review MUST be created without an `event` field -- this keeps it
   pending. Never submit it.
2. Never copy markdown findings verbatim as comments. Rewrite them to be
   concise and human-readable.
3. Skip dismissed findings (invalid and out-of-scope sections).
4. Every comment must reference a specific file and line number. Skip
   findings that don't have a parseable `**File:** path:line`.
5. If the PR's head SHA has changed since the review was generated, warn the
   user and ask whether to proceed -- comments may land on wrong lines.
6. If the API call fails, show the error and the payload so the user can
   debug.

## Failure modes

- **No review.md found**: Tell the user to run `/review-pr` first.
- **PR not found or closed**: Stop and report.
- **Head SHA mismatch**: Warn and ask confirmation.
- **API rate limit**: Report the error, suggest waiting.
- **Finding without file/line**: Skip it, mention it was skipped in the
  summary.

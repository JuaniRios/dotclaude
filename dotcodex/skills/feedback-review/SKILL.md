---
name: feedback-review
description: "Use when the user asks to run the former Claude /feedback-review workflow: Triage and address PR feedback (CodeRabbit inline, out-of-diff, and human reviewer comments) on the current branch. Summarizes each comment with severity and agent opinion, asks which to implement, fixes chosen ones, and drafts replies for dismissed or differently-handled comments."
---

# feedback-review

Codex adaptation of the Claude slash command `feedback-review`. Follow the workflow below, but use Codex-native tools and normal user questions where the original mentions Claude-only mechanisms.

Compatibility notes:
- Treat `$ARGUMENTS` as the relevant arguments or intent from the user's request.
- Replace `AskUserQuestion` with a concise question to the user when a decision is required.
- Replace Claude `Agent` calls with Codex subagents only when the user explicitly asks for parallel agents; otherwise do the work locally.
- Ignore Claude `allowed-tools`, `argument-hint`, `TodoWrite`, and `Skill` tool references as tool-permission metadata.
- When the workflow mentions another slash command, use the corresponding Codex skill or follow that workflow directly.

Triage and address review feedback on the current branch's PR. Pulls all
pending review comments (CodeRabbit inline/out-of-diff and human), summarizes
them, collects decisions, implements fixes, and handles replies -- all in one
session.

Follow these steps precisely.

## 1. Identify the PR

```bash
pr_json=$(gh pr view --json number,title,url,headRefName,baseRefName,headRefOid,state,isDraft)
```

If no PR exists for the current branch, stop and tell the user.
Record `number`, `title`, `url`, `headRefName`, `headRefOid`.

If the PR is closed or merged, warn and ask whether to continue.

## 2. Fetch all review comments

**CRITICAL: Only fetch UNRESOLVED comment threads.** GitHub marks threads as
resolved when reviewers or authors resolve them. Resolved threads are done --
never include them in the triage.

Use the GraphQL API to get review threads with resolution status.

**CRITICAL: You MUST paginate.** PRs with active CodeRabbit reviews routinely
exceed 100 threads. Always include `pageInfo { hasNextPage endCursor }` in the
query and loop until `hasNextPage` is `false`. Merge all pages before filtering.

First page (no `$after` variable):

```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes {
            isResolved
            isOutdated
            comments(first: 50) {
              nodes {
                databaseId
                author { login }
                path
                line
                body
                createdAt
                url
              }
            }
          }
        }
      }
    }
  }
' -f owner='{owner}' -f repo='{repo}' -F pr={number}
```

Check `pageInfo.hasNextPage`. If `true`, fetch the next page by adding
`$after: String!` to the query variables and `after: $after` to
`reviewThreads(first: 100, after: $after)`, passing `-f after=<endCursor>`.
Repeat until `hasNextPage` is `false`. Merge all `nodes` arrays from every page
before proceeding.

**CRITICAL: Filter programmatically, not by reading raw JSON.** GraphQL
responses for large PRs routinely exceed 200KB and get persisted to files that
you cannot fully read in context. After fetching all pages, save each page's
output to a temp file and use a script to extract only unresolved, non-outdated
threads. Example:

```bash
# After saving each page to /tmp/pr-threads-page-*.json:
python3 -c "
import json, glob, sys
threads = []
for path in sorted(glob.glob('/tmp/pr-threads-page-*.json')):
    with open(path) as f:
        data = json.load(f)
    threads.extend(data['data']['repository']['pullRequest']['reviewThreads']['nodes'])
unresolved = [t for t in threads if not t['isResolved'] and not t['isOutdated']]
print(json.dumps(unresolved, indent=2))
" > /tmp/pr-unresolved-threads.json
```

Then read `/tmp/pr-unresolved-threads.json` to get the filtered list. Each
thread's first comment is the root; subsequent comments are replies.

Also fetch top-level issue comments (for non-inline discussion):

```bash
gh api repos/{owner}/{repo}/issues/{number}/comments \
  --paginate --jq '.[] | {id, user: .user.login, body, created_at, html_url}' \
  > /tmp/pr-issue-comments.json
```

Top-level comments matter for CodeRabbit: when it cannot attach a finding to
the PR diff, it often emits an "outside diff range" / "out-of-diff" finding in a
general PR comment instead of a review thread. Do not treat every CodeRabbit
top-level comment as a summary. Keep CodeRabbit issue comments that contain
actionable review sections such as "Potential issue", "Suggestion", "Outside diff
range", "out of diff", explicit file paths/line references, or wording that asks
for a code/config/doc change. Skip only boilerplate comments such as
walkthroughs, pre-merge checks, finishing touches, share/tips blocks, and merge
queue/status comments.

## 3. Filter to actionable feedback

From the **unresolved** threads and actionable top-level comments, keep only
**actionable feedback** -- comments that request a code change, flag a bug,
suggest an improvement, or ask a question that needs a response. Skip:

- Bot summary comments (CodeRabbit's top-level "walkthrough" posts, pre-merge
  checks, finishing touches, share/tips blocks)
- Pure praise / acknowledgement comments ("LGTM", "looks good", etc.)
- The PR author's own comments (unless they're self-review requesting changes)

For CodeRabbit top-level comments, split the comment into individual actionable
review items when it contains multiple findings. Preserve each item's comment
URL and any file/line text CodeRabbit provided. Mark the `file` field as
`general` only when CodeRabbit did not provide a path. These comments do not
have GitHub review-thread resolution status, so treat them as pending unless a
later reply clearly says the item was fixed, resolved, or superseded.

For each remaining comment, classify the **source**:

- **coderabbit** -- `author.login` contains "coderabbit" (case-insensitive)
- **human** -- any other user

Group threaded replies into conversations. The actionable item is the root
comment (first in thread); replies provide context.

## 4. Build the feedback summary

For each actionable comment, produce:

| Field | Description |
|---|---|
| `#` | Sequential number for this session |
| `source` | `coderabbit` or `human:<username>` |
| `file` | File path and line (if inline comment) |
| `request` | One-line summary of what the comment is asking for |
| `severity` | `critical` / `high` / `medium` / `low` / `nit` -- your assessment |
| `opinion` | Your honest assessment: `agree`, `partially agree`, or `disagree` with a brief reason |
| `effort` | `trivial` / `small` / `medium` / `large` -- estimated implementation effort |

To form your opinion, **read the relevant source code** at the referenced
file/line. Don't just parrot the comment -- independently evaluate whether the
suggestion improves the code, is correct, and is worth the effort.

## 5. Present the summary and collect decisions

Print a table:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PR #<N> -- Feedback triage (<M> actionable comments)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 #  | source        | sev    | opinion          | effort  | request
----+---------------+--------+------------------+---------+----------------------
 1  | coderabbit    | high   | agree            | small   | Add bounds check on index
 2  | human:alice   | medium | partially agree  | trivial | Rename variable for clarity
 3  | coderabbit    | low    | disagree         | medium  | Extract helper function
 4  | human:bob     | nit    | agree            | trivial | Fix typo in comment
```

Then collect decisions using `ask the user`. For each comment, offer:

- **"Fix as suggested"** -- implement exactly what the reviewer asked
- **"Fix differently"** -- implement but with a different approach (you'll ask how)
- **"Defer to issue"** -- don't implement now; create a Linear issue to track it
- **"Reply & skip"** -- don't implement; draft a reply explaining why
- **"Show details"** -- show the full comment thread and your analysis

Default recommendations based on your opinion:
- `agree` + `trivial`/`small` -> default "Fix as suggested"
- `agree` + `medium`/`large` -> default "Fix as suggested" (but flag the effort)
- `partially agree` -> default "Fix differently"
- `partially agree` + `large` effort -> consider defaulting "Defer to issue"
- `disagree` -> default "Reply & skip"

Batch up to 4 findings per `ask the user` call. If the user picks "Show
details", present the full comment thread and your analysis, then re-ask.

If the user picks "Fix differently", ask them how they want it fixed before
proceeding.

After collecting all decisions, print the consolidated plan:

```
Plan:
  Fix as suggested (2):  #1, #4
  Fix differently (1):   #2 -- "use snake_case instead of camelCase"
  Defer to issue (1):    #5
  Reply & skip (1):      #3
```

## 6. Implement fixes

For each "fix" decision (both "as suggested" and "differently"), in severity
order:

1. Announce which comment you're addressing.
2. Read the relevant source file(s).
3. Verify the comment is still applicable (code may have changed).
4. Apply the fix using `Edit`. Keep changes surgical.
5. Print a one-line summary of what changed.

After all fixes are applied:

1. Run the project's fast verification command (`cargo check -p <crate>` or
   equivalent from CLAUDE.md/AGENTS.md).
2. Report results. If something broke, fix it.

## 7. Commit and restack

After fixes pass verification, ask the user via `ask the user`:

> "Run `gt modify -a` and `gt ss` to amend the commit and restack the stack?"

Options: **"Yes (Recommended)"**, **"No, I'll handle it"**.

If yes, run:

```bash
gt modify -a
gt ss
```

Report the result. If restack has conflicts, tell the user and stop.

## 8. Create issues for deferred comments

For each "Defer to issue" decision, create a Linear issue using the `linear`
CLI. Follow the linear-cli skill's workflow:

1. Draft a markdown description to a tempfile with:
   - **Problem**: what the reviewer flagged and why it matters
   - **Proposed fix**: one-paragraph approach
   - **Context**: link to the PR and the specific comment URL
2. Show the draft title + description to the user and wait for approval.
3. Create the issue:
   ```bash
   linear issue create \
     --title "<concise title>" \
     --description-file "$tmp" \
     --team RAI \
     --priority <1-4 based on severity> \
     --no-interactive
   ```
4. Record the issue URL for the final summary.
5. Optionally post a reply on the PR comment thread referencing the issue
   (with user approval).

## 9. Handle comment replies

Ask the user via `ask the user`:

> "Post replies for skipped/fixed comments on GitHub?"

Options: **"Yes (Recommended)"**, **"Skip replies"**.

If no, skip to the summary step.

### Comments that were fixed

**CodeRabbit comments that were fixed:** No action needed. CodeRabbit
automatically detects resolved suggestions after push and marks them resolved.
Tell the user this.

**Human reviewer comments that were fixed:** For each one, post a reply on
the comment thread indicating it was addressed:

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --method POST \
  -f body="Fixed in <commit-sha>." \
  -F in_reply_to=<original-comment-id>
```

Show the user what you'll post before posting. Batch the confirmations -- show
all planned replies, ask once for approval, then post.

### Comments that were skipped ("Reply & skip")

For each skipped comment, draft a reply that:
- Acknowledges the reviewer's point
- Explains why you're not implementing it (or doing it differently)
- Is polite, concise, and constructive
- Matches the tone of the reviewer (technical for technical reviewers,
  conversational for conversational ones)

Present all draft replies to the user:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Draft replies for skipped comments
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[#3] coderabbit -- Extract helper function
  > Thanks for the suggestion. I've kept this inline since it's only used
  > once and extracting it would add indirection without reducing
  > complexity. Happy to revisit if this pattern shows up elsewhere.

[#5] human:alice -- Use a different data structure
  > Good point about the lookup performance. In practice this list stays
  > under 10 elements so the linear scan is fine here. If it grows,
  > I'll switch to a HashMap.
```

Ask the user to approve, edit, or skip each reply. Use `ask the user` with
options: "Send", "Edit", "Skip".

For approved replies, post them:

- **CodeRabbit comments:** Post as a reply in the thread. CodeRabbit will
  read the reply and may respond or resolve based on your explanation.
- **Human comments:** Post as a reply in the thread.

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --method POST \
  -f body="<approved reply text>" \
  -F in_reply_to=<original-comment-id>
```

## 10. Check for stacked PRs

After replies are handled (or skipped), check if there is a PR stacked on top
of the current one:

```bash
gh pr list --base "$(git branch --show-current)" --json number,title,headRefName --jq '.[0]'
```

If a stacked PR exists, ask via `ask the user`:

> "PR #<N> (<title>) is stacked on top. Run the feedback-review skill on it?"

Options: **"Yes, switch and review"**, **"No, stop here"**.

If yes, use the graphite skill to switch to that branch:

```bash
gt co <headRefName>
```

Then invoke `the feedback-review skill` via the `skill` tool to start the feedback
review on the next PR in the stack.

## 11. Summary

Print a final summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Feedback review complete -- PR #<N>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Fixed (3):
  #1  high   coderabbit   Add bounds check           (auto-resolves on push)
  #2  medium human:alice  Rename variable             -> replied: fixed in abc1234
  #4  nit    human:bob    Fix typo                    -> replied: fixed in abc1234

Deferred to issue (1):
  #5  medium coderabbit   Surface load failures       -> RAI-223

Replied & skipped (1):
  #3  low    coderabbit   Extract helper function     -> replied with explanation

Remaining:
  Push your changes. CodeRabbit comments will auto-resolve.
  Human reviewer comments have been replied to.
```

## Hard rules

1. Never post any comment or reply without explicit user approval of the
   exact text.
2. Never commit or push without explicit user approval -- the user controls
   version control. `gt modify -a` / `gt ss` are offered but never run without
   consent.
3. Always read the source code before forming your opinion on a comment.
   Don't assess blindly from the comment text alone.
4. Keep fixes surgical -- no scope creep or "while I'm here" cleanups.
5. Always verify comments are still applicable before implementing fixes --
   the code may have changed since the review.
6. For human reviewer replies about fixes, always include the commit SHA.
7. Stay in the session after the summary -- the user may want to adjust
   replies or fix more.

## Failure modes

- **No PR for current branch:** Stop and tell the user.
- **No actionable comments:** Print "No actionable feedback found" and exit.
- **Comment thread is already resolved:** Skip it, mention in summary.
- **API rate limit:** Report the error, suggest waiting.
- **Fix turns out larger than expected:** Stop, report, ask whether to
  continue, defer, or skip.
- **Post-fix verification fails:** Fix the breakage before moving to the next
  comment. Don't leave broken code.

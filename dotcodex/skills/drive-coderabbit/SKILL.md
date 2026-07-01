---
name: drive-coderabbit
description: "Use when the user asks to run the former Claude /drive-coderabbit workflow: Trigger CodeRabbit full reviews across a Graphite stack, wait for results, triage findings, then apply approved code fixes serially."
---

# drive-coderabbit

Codex adaptation of the Claude slash command `drive-coderabbit`. Follow the
workflow below, but use Codex-native tools and normal user questions where the
original mentions Claude-only mechanisms.

Compatibility notes:
- Treat `$ARGUMENTS` as the relevant arguments or intent from the user's
  request.
- Replace `AskUserQuestion` with a concise question to the user when a decision
  is required.
- Use Codex subagents only when the user explicitly asks for parallel agents or
  when this skill is invoked specifically to drive the stack in parallel. If the
  multi-agent tools are unavailable, run the wait/analysis phase serially and
  tell the user.
- Ignore Claude `allowed-tools`, `argument-hint`, `TodoWrite`, and `Skill` tool
  references as tool-permission metadata.
- When the workflow mentions another slash command, use the corresponding Codex
  skill or follow that workflow directly.

Trigger a fresh CodeRabbit review on every PR in the stack, wait for the reviews
concurrently when subagents are available, then apply the agreed code fixes and
amend the stack serially. This is the "I just pushed a stack; get CodeRabbit's
pass folded in without babysitting it" workflow.

Default scope is the whole stack: every branch from trunk to the top of the
current Graphite stack that has an open PR. If the user says `current`, limit to
the current branch and everything stacked above it.

Why two phases: Graphite mutates one shared worktree, so checkout, amend, and
restack must be serial. Waiting on CodeRabbit and analyzing findings is the slow
part and can fan out. Phase 1 waits/analyzes without git mutation; Phase 2
applies fixes bottom-up in one worktree.

The handle is `@coderabbitai` (bot login `coderabbitai[bot]`). A comment
addressed to `@coderabbit` does not trigger the bot. Always post:

```text
@coderabbitai full review
```

## 1. Load required skills

Use the `graphite` skill before any checkout, amend, submit, restack, or other
version-control mutation. Use the `feedback-review` workflow as the source of
truth for fetching and classifying review comments.

If using subagents for Phase 1, discover the available multi-agent tools with
`tool_search` before launching them.

## 2. Enumerate the stack's PRs

List open PRs authored by the current GitHub user:

```bash
gh pr list --author @me --state open \
  --json number,title,url,headRefName,baseRefName,isDraft
```

Build the ordered chain from base to head: start from the PR whose `baseRefName`
is trunk (`master` unless the repo clearly uses another trunk), then follow each
PR whose base is the previous PR's head. This bottom-up order is required for
Phase 2.

If the user requested `current`, get the current branch and keep only that branch
and PRs stacked above it:

```bash
git branch --show-current
```

If no open PR matches the current stack, stop and tell the user. Print the
ordered list of PRs before starting.

## 3. Phase 1 - trigger and analyze reviews

For each PR, perform the following without checking out, editing, committing, or
restacking. If subagents are available and appropriate, run one background
subagent per PR. Each subagent must be self-contained and must read branch files
with `git show <branch>:<path>`.

### Trigger

Record the trigger time, then request a full review:

```bash
TRIGGER_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh pr comment <N> --body "@coderabbitai full review"
```

### Wait for review, retrying through rate limits

Poll every 60 seconds, capped around 40 minutes per attempt. Only count
CodeRabbit activity with timestamp greater than `$TRIGGER_ISO`.

Done condition: a review by `coderabbitai[bot]` whose body contains
`Actionable comments posted:`:

```bash
gh api repos/{owner}/{repo}/pulls/<N>/reviews --paginate --jq \
  '[.[] | select(.user.login=="coderabbitai[bot]")
        | select(.submitted_at > "'"$TRIGGER_ISO"'")
        | select(.body | contains("Actionable comments posted:"))] | length'
```

`Actionable comments posted: 0` still means the review is complete.

Rate limit condition: an issue comment or review body by `coderabbitai[bot]`
after the trigger contains `Rate limit exceeded` or `before requesting another
review`. Fetch comments with:

```bash
gh api repos/{owner}/{repo}/issues/<N>/comments --paginate --jq \
  '.[] | select(.user.login=="coderabbitai[bot]")
       | select(.created_at > "'"$TRIGGER_ISO"'") | .body'
```

Parse the stated wait, sleep for that duration plus 30 seconds, re-post the
review request, reset `$TRIGGER_ISO`, and resume polling. Count retries.

If neither condition appears within the cap, return `status: "timeout"` for that
PR.

### Fetch and triage findings

Once done, fetch feedback exactly as the `feedback-review` skill describes:
unresolved, non-outdated review threads via paginated GraphQL, plus issue
comments and pull review bodies for out-of-diff findings.

Filter to actionable items only. For each item, read the referenced source with
`git show <branch>:<path>` and form an independent opinion:

- `agree`
- `partially agree`
- `disagree`

Do not parrot CodeRabbit. Record severity, effort, and a surgical fix plan.

Each PR's Phase 1 result should be JSON:

```json
{
  "pr": 0,
  "branch": "<branch>",
  "status": "reviewed|no_actionable|timeout|error",
  "rate_limit_retries": 0,
  "fixes": [
    {
      "file": "...",
      "locator": "fn/line",
      "finding": "...",
      "severity": "high",
      "change": "precise old->new or surgical instruction"
    }
  ],
  "replies": [
    {
      "file": "...",
      "finding": "...",
      "reason": "why disagree",
      "comment_url": "..."
    }
  ],
  "defers": [
    {
      "finding": "...",
      "reason": "large/out-of-scope",
      "comment_url": "..."
    }
  ],
  "notes": "anything the human should know"
}
```

`fixes` are agreed surgical code changes. `replies` are disagreements. `defers`
are partially agreed large or out-of-scope items. Do not post replies, create
issues, or mutate git in Phase 1.

## 4. Phase 2 - apply fixes serially, bottom-up

Record the starting branch. Then for each PR in bottom-up order with non-empty
`fixes`:

1. Check out the branch with Graphite:

   ```bash
   gt co <branch>
   ```

2. For each fix, in severity order, read the file and verify the finding is
   still applicable against the checked-out code.
3. Apply a surgical edit. Keep changes minimal; no scope creep.
4. Fast-verify with the relevant local check, usually `cargo check -p <crate>`
   when Rust files changed. Pick the crate from the touched files.
5. Amend the branch:

   ```bash
   gt modify -a
   ```

If `gt modify -a` triggers an upstack restack conflict, stop, return to a clean
state if possible, and tell the user to run the `fix-conflicts` workflow. Do not
guess at conflict resolution.

After all branches are amended, restack and submit the stack once:

```bash
gt ss
```

Return to the original branch with `gt co <original>`.

## 5. Report

Print one consolidated summary:

```text
drive-coderabbit - <K> PRs driven

PR #12 rai-1150  reviewed       fixed 3, deferred 1, skipped 1  (1 rate-limit retry)
PR #13 rai-1151  no_actionable
PR #14 rai-1152  reviewed       fixed 2                          -> amended + restacked
PR #15 rai-1160  timeout        CodeRabbit never completed - re-run later

Pushed: gt ss restacked the stack. CodeRabbit auto-resolves its own resolved
suggestions on push.

Needs your call:
  Replies to post: PR #12 #1 (disagree: extract helper) ...
  Defer to issue:  PR #12 #4 (large refactor) ...
```

`replies` and `defers` are report-only. Posting GitHub replies and creating
Linear issues are outward actions, so surface them for the user instead of doing
them unprompted.

## Hard rules

1. Always post `@coderabbitai full review`; never `@coderabbit`.
2. Phase 1 never mutates git. It reads with `git show <branch>:<path>` and
   returns a plan.
3. Git mutation is strictly serial and bottom-up. Never parallelize
   `gt modify` or `gt ss`.
4. Only count CodeRabbit activity after the trigger timestamp.
5. Verify each finding against checked-out code before editing.
6. Keep fixes surgical.
7. Never post replies or create Linear issues unprompted.
8. On restack conflict, stop and hand off to `fix-conflicts`.

## Failure modes

- No open PRs in the stack: stop and tell the user.
- CodeRabbit never completes: mark that PR `timeout`, skip its fixes, keep
  driving the rest, and surface it in the report.
- Persistent rate limiting: retry through stated waits until the attempt cap,
  then mark timeout.
- Local verification fails after a fix: fix the breakage before `gt modify`.
- Restack conflict: stop, report the branch, and hand to `fix-conflicts`.
- A Phase 1 worker returns `error`: surface its notes, skip its fixes, continue.

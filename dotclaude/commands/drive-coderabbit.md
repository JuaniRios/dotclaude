---
allowed-tools: Bash(gh:*), Bash(gt:*), Bash(git:*), Bash(jq:*), Bash(python3:*), Bash(date:*), Bash(mktemp:*), Bash(rm:*), Bash(test:*), Bash(cat:*), Bash(sleep:*), Bash(seq:*), Bash(cargo:*), Bash(grep:*), Bash(wc:*), Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
description: Drive CodeRabbit across an entire graphite stack in parallel — comment "@coderabbitai full review" on every PR, wait for each review (auto-retrying through rate limits), then autonomously address each PR's findings with feedback-review's judgment and amend the stack.
argument-hint: [current]
---

Trigger a fresh CodeRabbit review on every PR in the stack, wait for all of
them concurrently, then autonomously apply the findings and amend the stack.
This is the "I just pushed a stack, get CodeRabbit's pass folded in without
me babysitting it" button.

**Scope (default whole stack):** every branch from trunk to the top of the
current stack that has an open PR. Pass `current` to limit to the current
branch and everything stacked above it.

**Why two phases.** Graphite mutates one shared worktree, so the git work
(checkout, amend, restack) MUST be serial — concurrent `gt modify`/`gt ss`
corrupts the stack. The slow part is waiting on CodeRabbit (minutes per PR,
plus rate-limit waits of tens of minutes) and analyzing findings; that fans
out. So Phase 1 fans out the wait+analysis (no git mutation), Phase 2
serializes the fast git apply. This runs **autonomous, no prompts mid-run** —
you opted into letting it fix, amend, and restack on its own.

**The handle is `@coderabbitai`** (bot login `coderabbitai[bot]`). A comment
addressed to `@coderabbit` does NOT fire the bot. Always post
`@coderabbitai full review`.

Follow these steps precisely.

## 1. Enumerate the stack's PRs

Reconstruct the stack from base→head linkage (deterministic JSON, no `gt log`
parsing). List your open PRs and chain them from trunk upward:

```bash
gh pr list --author @me --state open \
  --json number,title,url,headRefName,baseRefName,isDraft
```

Build the ordered chain: start from the PR whose `baseRefName` is trunk
(`master`), then follow each PR whose base is the previous PR's head, up to the
top. This gives **bottom-up order**, which Phase 2 relies on.

- Default: keep the whole chain.
- `current` arg: keep only the current branch (`git branch --show-current`)
  and PRs stacked above it.

If no open PR matches the current stack, stop and tell the user. Print the
ordered list of PRs you're about to drive.

## 2. Phase 1 — fan out one background agent per PR

Launch the agents in a **single message** with multiple `Agent` calls,
`run_in_background: true`, so they run concurrently. Each agent is fully
self-contained (it does NOT share your context). Give each this prompt,
substituting the PR number and branch:

> You are driving CodeRabbit on PR #<N> (branch `<branch>`) of this repo. Do
> NOT check out, edit, commit, or restack anything — you only post a comment,
> wait, and produce an analysis. All git reads use `git show <branch>:<path>`.
>
> **1. Trigger.** Record the trigger time, then post the review request:
> ```bash
> TRIGGER_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
> gh pr comment <N> --body "@coderabbitai full review"
> ```
>
> **2. Wait for the review, retrying through rate limits.** Poll every 60s
> (cap ~40 min per attempt). On each poll check two things, only counting
> activity with timestamp > `$TRIGGER_ISO`:
>
> - **Done:** a review by `coderabbitai[bot]` whose body contains
>   `Actionable comments posted:`:
>   ```bash
>   gh api repos/{owner}/{repo}/pulls/<N>/reviews --paginate --jq \
>     '[.[] | select(.user.login=="coderabbitai[bot]")
>           | select(.submitted_at > "'"$TRIGGER_ISO"'")
>           | select(.body | contains("Actionable comments posted:"))] | length'
>   ```
>   `>= 1` means the review landed. (`Actionable comments posted: 0` still
>   counts as done — nothing to fix.)
> - **Rate limited:** an issue comment OR review body by `coderabbitai[bot]`
>   after the trigger containing `Rate limit exceeded` / `before requesting
>   another review`:
>   ```bash
>   gh api repos/{owner}/{repo}/issues/<N>/comments --paginate --jq \
>     '.[] | select(.user.login=="coderabbitai[bot]")
>          | select(.created_at > "'"$TRIGGER_ISO"'") | .body'
>   ```
>   Parse the wait ("wait X minutes and Y seconds" or "try again in X
>   minutes"), `sleep` that long + 30s, re-post `@coderabbitai full review`,
>   reset `$TRIGGER_ISO`, and resume polling. Count the retries.
>
> If neither appears within the cap, return `status: "timeout"`.
>
> **3. Fetch and triage findings.** Once done, fetch the feedback exactly the
> way the `/feedback-review` command does — read
> `~/Github/dotagents/dotclaude/commands/feedback-review.md` and follow its
> steps 2–4: unresolved, non-outdated review threads via the paginated GraphQL
> query, PLUS issue comments and pull review bodies (for out-of-diff
> findings). Filter to actionable items only. For each, read the referenced
> source with `git show <branch>:<path>` and form an honest opinion
> (`agree` / `partially agree` / `disagree`) with severity and effort — do not
> parrot CodeRabbit.
>
> **4. Return a fix plan** as JSON (this text IS your return value):
> ```json
> {
>   "pr": <N>, "branch": "<branch>", "status": "reviewed|no_actionable|timeout|error",
>   "rate_limit_retries": <int>,
>   "fixes":   [{"file":"...","locator":"fn/line","finding":"...","severity":"high","change":"precise old->new or surgical instruction"}],
>   "replies": [{"file":"...","finding":"...","reason":"why disagree","comment_url":"..."}],
>   "defers":  [{"finding":"...","reason":"large/out-of-scope","comment_url":"..."}],
>   "notes": "anything the human should know"
> }
> ```
> `fixes` = findings you `agree` with (surgical). `replies` = `disagree`.
> `defers` = `partially agree` + large/out-of-scope. Do NOT post replies,
> create issues, or touch git — that's the main session's job.

Collect every agent's JSON as they finish.

## 3. Phase 2 — apply fixes serially, bottom-up

Record the current branch so you can return to it. Then for each PR **in
bottom-up stack order** that has a non-empty `fixes` list:

1. `gt co <branch>`
2. For each fix, in severity order: read the file, **verify the finding is
   still applicable** (code may differ from the agent's read), apply a surgical
   `Edit`. Keep changes minimal — no scope creep.
3. Fast-verify: `cargo check -p <crate>` (pick the crate from the touched
   files; see CLAUDE.md). If it breaks, fix the breakage before moving on.
4. `gt modify -a` to amend this branch's commit.

If a `gt modify -a` triggers an upstack restack **conflict**, stop, return to a
clean state if possible, and tell the user to run `/fix-conflicts` — do NOT
guess at conflict resolution.

After all branches are amended, restack and submit the whole stack once:

```bash
gt ss
```

Then return to the original branch (`gt co <original>`).

## 4. Report

Print one consolidated summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
drive-coderabbit — <K> PRs driven
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PR #12 rai-1150  reviewed   fixed 3, deferred 1, skipped 1  (1 rate-limit retry)
PR #13 rai-1151  no_actionable
PR #14 rai-1152  reviewed   fixed 2                          → amended + restacked
PR #15 rai-1160  timeout    CodeRabbit never completed — re-run later

Pushed: gt ss restacked the stack. CodeRabbit auto-resolves its own
resolved suggestions on push.

Needs your call (not auto-actioned):
  Replies to post:  PR #12 #1 (disagree: extract helper) ...
  Defer to issue:   PR #12 #4 (large refactor) ...
```

`replies` and `defers` are **report-only** — posting GitHub replies and
creating Linear issues are outward actions, so surface them here for the user
to action (e.g. via `/feedback-review` on that one PR) rather than doing them
unprompted. Only code fixes + amend + restack are autonomous.

## Hard rules

1. Always post `@coderabbitai full review` (correct bot handle) — never
   `@coderabbit`.
2. Phase 1 agents NEVER mutate git (no checkout/edit/commit/restack) — they
   read via `git show <branch>:<path>` and return a plan. Only the main
   session mutates git, and only in Phase 2.
3. Git mutation is strictly serial and bottom-up. Never parallelize
   `gt modify`/`gt ss` — it corrupts the stack.
4. Only count CodeRabbit activity with a timestamp after the trigger — never
   mistake a stale prior review for the new one.
5. Verify each finding is still applicable against the checked-out code before
   editing. Keep fixes surgical.
6. Never post replies or create Linear issues unprompted — surface them in the
   report for the user.
7. On a restack conflict, stop and hand off to `/fix-conflicts`. Do not guess.

## Failure modes

- **No open PRs in the stack:** Stop and tell the user.
- **CodeRabbit never completes (timeout):** Mark that PR `timeout`, skip its
  fixes, keep driving the rest, surface it in the report.
- **Persistent rate limiting:** Keep retrying through the stated waits; if it
  exceeds the per-attempt cap repeatedly, report it as `timeout` and move on.
- **`cargo check` fails after a fix:** Fix the breakage before `gt modify`.
  Never amend broken code.
- **Restack conflict:** Stop, report which branch, hand to `/fix-conflicts`.
- **An agent returns `error`:** Surface its `notes`, skip its fixes, continue.

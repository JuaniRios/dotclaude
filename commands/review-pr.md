---
allowed-tools: Bash(gh:*), Bash(git:*), Bash(codex:*), Bash(mkdir:*), Bash(wc:*), Bash(date:*), Bash(basename:*), Bash(test:*), Bash(grep:*), Read, Write, Agent, Skill
description: Cross-review a pull request by number or URL without checking it out. Runs five reviewers in parallel (2x Opus, Sonnet, 2x Codex gpt-5.5), aggregates, and starts a conversation so you can decide which findings (if any) to comment on the PR.
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

## 6. Build the reviewer prompt

Save a shared reviewer prompt to `$out_dir/prompt.txt`. Every reviewer gets
the same text, adapted from the `cross-review` skill's Step 3:

```
You are a senior staff engineer performing a rigorous code review. You have
15+ years of experience and a track record of catching subtle, high-impact
bugs before they ship. You are thorough but not pedantic. You care about
correctness, security, and maintainability — not style.

Your task: review the diff at {DIFF_PATH} against the project's conventions
documented in these files:
{PROJECT_DOCS_PATHS}

The PR was authored against commit <head_sha>. Read source files via
`git show <head_sha>:<path>` — the working tree does not match the PR.

The diff is scoped to exactly the changes on this PR. Everything in the diff
is in scope; everything outside is context you may read but should not review.

Review priorities, in order:

1. CORRECTNESS — bugs, logic errors, off-by-ones, race conditions, unhandled
   errors, incorrect assumptions about external systems, broken invariants,
   dead/unreachable code.
2. SECURITY — injection, authentication/authorization gaps, secret handling,
   input validation, unsafe deserialization, TOCTOU, privilege escalation.
3. CONVENTION ADHERENCE — violations of rules explicitly stated in the
   project docs above. Do NOT invent conventions the docs don't mandate.
4. MAINTAINABILITY — only flag things that will actively hurt the next
   engineer to touch this code. Not "could be slightly cleaner."
5. TEST COVERAGE — missing coverage for new logic, tests that assert the
   wrong thing, tests that document gaps instead of fixing them. Only flag if
   the project's docs call test coverage out as required.

What NOT to flag:

- Style, formatting, import ordering, naming nits unless the project docs
  explicitly mandate them.
- Issues the compiler, linter, or typechecker would catch — assume CI exists.
- Pre-existing issues on lines the diff did not modify.
- Speculative "what if" concerns without a concrete trigger.
- Missing documentation unless the docs mandate it.
- Renamings, reorganizations, or "this could be factored differently"
  suggestions.
- Pedantic edge cases a senior engineer would not call out in a real PR.

Output format — you MUST follow this exactly:

For each finding, emit a section like:

### <short title>

- **Severity:** critical | high | medium | low | nit
- **File:** <path>:<start-line>[-<end-line>]
- **Category:** correctness | security | convention | maintainability | tests
- **Finding:** <one-paragraph description of the issue>
- **Why it matters:** <concrete consequence if not fixed>
- **Recommended fix:** <specific, actionable fix — not "consider doing X">
- **Confidence:** <0-100> — how confident you are this is a real issue (100 =
  certain, 50 = plausible but unverified, 25 = hunch)

Order findings by severity (critical first) then by file.

If you find nothing worth raising, output exactly:

### No findings

<one-sentence justification of why you believe the diff is clean>

Do not include preamble, disclaimers, emojis, or summaries. Start directly
with the first finding (or "### No findings").
```

## 6a. Spawn five reviewers in parallel

Spawn all five in a **single message with five parallel tool calls**:

1. **Claude Opus A** — via the `Agent` tool (`model: "opus"`)
2. **Claude Opus B** — via the `Agent` tool (`model: "opus"`)
3. **Claude Sonnet** — via the `Agent` tool (`model: "sonnet"`)
4. **Codex gpt-5.5 A** — via `Bash` (`run_in_background: true`, `timeout: 600000`)
5. **Codex gpt-5.5 B** — via `Bash` (`run_in_background: true`, `timeout: 600000`)

### Reviewers 1-3 — Claude Opus A, Opus B, Sonnet (Agent tool)

Spawn three `Agent` tool calls: two with `model: "opus"`, one with
`model: "sonnet"`. Each uses `subagent_type: "general-purpose"`.
The prompt is the shared reviewer text above, plus:

```
The diff is at: $out_dir/diff.patch
Project docs: <list of paths>
Repo root: $repo_root

Read the diff, read the project docs, and read any source files referenced
by the diff that you need for context. Return your review in the format
specified above — nothing else.
```

Write each Agent's output to `$out_dir/raw-opus-a.md`,
`$out_dir/raw-opus-b.md`, and `$out_dir/raw-sonnet.md` respectively.

### Reviewers 4-5 — Codex gpt-5.5 A and B (Bash)

Spawn two parallel `Bash` calls (both `run_in_background: true`,
`timeout: 600000`). Both use `-m gpt-5.5`. Replace `$INSTANCE` with `a` or `b`:

```bash
cat "$out_dir/diff.patch" | codex exec \
  --sandbox read-only \
  -m gpt-5.5 \
  -C "$repo_root" \
  "The diff is provided on stdin. Analyze it as a code reviewer.

$(cat "$out_dir/prompt.txt")

Project docs: <list of paths>
Repo root: $repo_root

Read the project docs and any source files referenced by the diff that you
need for context. Return your review in the format specified above —
nothing else." \
  > "$out_dir/codex-${INSTANCE}-stdout.log" 2>&1
codex_exit=$?

# Extract review from Codex output.
# Codex mixes file-read echoes and tool-call logs with the actual review.
# The review appears after a bare "codex" marker line near the end.
codex_marker=$(grep -n '^codex$' "$out_dir/codex-${INSTANCE}-stdout.log" | tail -1 | cut -d: -f1)
if [ -n "$codex_marker" ]; then
  tail -n +$((codex_marker + 1)) "$out_dir/codex-${INSTANCE}-stdout.log" \
    | sed '/^tokens used$/,$d' \
    > "$out_dir/raw-codex-${INSTANCE}.md"
fi
```

Notes:
- `--sandbox read-only` is non-negotiable.
- Diff is piped via stdin so codex has content without finding the file.
- **Daily quota fallback**: If Codex fails with a daily limit error (look
  for `rate_limit` or `quota` with reset in hours), retry once with `-m o3`.

### Output validation

After all three finish, validate each output file:

```bash
validate_review() {
  local file="$1" reviewer="$2"
  [ ! -f "$file" ] && echo "$reviewer: no output" && return 1
  [ "$(wc -l < "$file")" -lt 5 ] && echo "$reviewer: too short" && return 1
  grep -q '^### ' "$file" || { echo "$reviewer: no findings headings"; return 1; }
  return 0
}
```

If a reviewer errors, record it as "reviewer errored" in the aggregator and
continue. Two reviewers is still valuable. If all three error, stop.

### Failure modes

- **Codex or Gemini not installed**: Check `command -v codex gemini` before
  spawning. If missing, warn the user and run with only the available
  reviewers. A single-model review is better than aborting.

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
- **Start each comment with a lowercase severity prefix** that signals
  how important the finding is: `critical:`, `should fix:`, `minor:`,
  or `nit:`. This replaces bold labels and numbered prefixes. The
  prefix is short and natural, like a colleague would write.
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

**Step 3 — Handle findings without diff lines.** Strongly prefer inline
comments over top-level body text. If a finding references unchanged
code, look for a **related** changed line in the diff where the comment
makes sense contextually. For example, if a finding is about an
interaction between existing code and newly introduced code (e.g., "the
existing reconciler doesn't account for the new compaction policy"),
place the comment on the new code that introduces the interaction, not
on the untouched code. Only fall back to the review `body` when the
finding has genuinely no related changed code anywhere in the diff
(e.g., a missing file, a documentation gap, a broad architectural
concern). The goal is to minimize the top-level body so the review
reads as targeted inline feedback, not a wall of text.

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
   severity labels. Use lowercase severity prefixes (`critical:`,
   `should fix:`, `minor:`, `nit:`) to signal importance. Write short,
   direct comments like a colleague would. The `raw-*.md` and
   `review.md` on disk can use structured formatting (they're local),
   but anything posted to GitHub must be conversational and concise.
8. **Maximize inline comments, minimize top-level body.** The review
   `body` should be a 2-3 sentence overall assessment only. Every
   finding should be an inline comment on a diff line. When a finding
   references unchanged code, place the comment on the nearest related
   changed line instead of putting it in the body.

---
allowed-tools: Bash(gt:*), Bash(git:*), Bash(gh:*), Bash(codex:*), Bash(linear:*), Bash(mkdir:*), Bash(cat:*), Bash(mktemp:*), Bash(rm:*), Bash(test:*), Bash(grep:*), Bash(wc:*), Bash(date:*), Bash(basename:*), Bash(find:*), Read, Write, Edit, Agent, AskUserQuestion
description: Cross-review the current branch, auto-fix findings, and re-review until clean. Loops automatically — only stops for user input on disputed findings or massive changes.
---

Run a full self-review loop on the current branch: review → auto-fix →
CI → re-review → repeat until clean. Use this right before you `gt submit`
something you wrote yourself, to catch issues before reviewers do.

The loop is **automatic by default**. Findings that clearly should be fixed
are fixed without asking. The loop re-runs the full review after each fix
pass to catch issues introduced by the fixes themselves. It stops when
the review returns no new actionable findings.

Follow these steps precisely.

---

## 1. Preflight

Verify prerequisites before doing anything:

1. You are in a git repo with a graphite-tracked branch:
   ```bash
   git rev-parse --show-toplevel
   gt log short
   ```

2. `codex` and `gt` are on PATH:
   ```bash
   command -v codex gt
   ```
   If `codex` is missing, warn the user and proceed with Claude-only
   reviewers (3 instead of 5). Three reviewers is still valuable.

3. The working tree is clean or stashed. A dirty tree pollutes the diff
   and confuses reviewers:
   ```bash
   git status --porcelain
   ```
   If dirty, tell the user and stop.

## 2. Resolve scope & prepare workspace

Determine what to review. On a graphite stack, **always diff against `gt
parent`**, not trunk — reviewing against trunk on a stacked branch would
include ancestor PRs and drown the reviewers in unrelated changes.

```bash
parent=$(gt parent 2>/dev/null || git merge-base origin/main HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)
head_sha=$(git rev-parse HEAD)
parent_sha=$(git rev-parse "$parent")
repo_root=$(git rev-parse --show-toplevel)
ts=$(date +%Y-%m-%d_%H-%M-%S)
safe_branch=$(echo "$branch" | tr '/' '_')
out_dir="$repo_root/claude-local-ctx/reviews/${ts}-${safe_branch}"
mkdir -p "$out_dir"
```

Write the diff and file manifest:

```bash
git diff "$parent"..HEAD > "$out_dir/diff.patch"
git diff --name-status "$parent"..HEAD > "$out_dir/files.txt"
wc -l "$out_dir/diff.patch"
```

Refuse to proceed if the diff is empty. If it exceeds 5000 lines, warn the
user and ask whether to proceed — reviewer quality degrades on huge diffs.

**Ensure the local-ctx folder is gitignored.** If `claude-local-ctx/` is not
in `.gitignore` (check with `grep -q claude-local-ctx "$repo_root/.gitignore"`),
ask the user for permission to add it. Do not silently modify `.gitignore`.

## 3. Load project context

```bash
find "$repo_root" -maxdepth 3 \( -name "CLAUDE.md" -o -name "AGENTS.md" \) \
  -not -path "*/node_modules/*" -not -path "*/target/*"
```

Keep only the paths. Reviewers will read them themselves.

Also extract the PR description if a PR exists for this branch:

```bash
pr_body=$(gh pr view --json body --jq '.body' 2>/dev/null || echo "No PR description available.")
```

## 4. Build the reviewer prompts

Every reviewer gets a **shared base prompt** plus a **per-reviewer focus
paragraph** that biases each toward a different class of bugs.

### Base prompt

Save this to `$out_dir/prompt-base.txt`:

```
You are a senior staff engineer performing a rigorous code review. You have
15+ years of experience and a track record of catching subtle, high-impact
bugs before they ship. You are thorough but not pedantic. You care about
correctness, security, and maintainability — not style.

Your task: review the diff at {DIFF_PATH} against the project's conventions
documented in these files:
{PROJECT_DOCS_PATHS}

The diff is scoped to exactly the changes on the current PR (parent..HEAD on a
graphite stack). Everything in the diff is in scope; everything outside is
context you may read but should not review.

The PR author describes the change as:
{PR_DESCRIPTION}

Evaluate whether the implementation actually delivers on this description.
If the PR claims to prevent event loss, verify that it does. If it claims
idempotency, check the dedup path. Do not take the description at face value.

Review priorities, in order:

1. CORRECTNESS — bugs, logic errors, off-by-ones, race conditions, unhandled
   errors, incorrect assumptions about external systems, broken invariants,
   dead/unreachable code.
2. CONCURRENCY & ORDERING — async operation sequencing, setup step ordering,
   TOCTOU between async calls, assumptions about which operation completes
   first, whether concurrent writers can produce inconsistent state.
3. SECURITY — injection, authentication/authorization gaps, secret handling,
   input validation, unsafe deserialization, privilege escalation.
4. CONVENTION ADHERENCE — violations of rules explicitly stated in the
   project docs above. Do NOT invent conventions the docs don't mandate.
5. MAINTAINABILITY — only flag things that will actively hurt the next
   engineer to touch this code. Not "could be slightly cleaner."
6. TEST COVERAGE — missing coverage for new logic, tests that assert the
   wrong thing, tests that document gaps instead of fixing them. Only flag if
   the project's docs call test coverage out as required.

What NOT to flag:

- Style, formatting, import ordering, naming nits unless the project docs
  explicitly mandate them.
- Issues the compiler, linter, or typechecker would catch — assume CI exists.
- Pre-existing issues on lines the diff did not modify.
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

### Per-reviewer focus paragraphs

Append one of these to the base prompt for each reviewer:

**Opus A — Concurrency & async ordering:**
```
YOUR FOCUS: Pay special attention to the ordering of async operations
during setup, teardown, and reconnection. When two async steps happen in
sequence (subscribe then query, or query then subscribe), consider what
happens if the world changes between them. Look for TOCTOU gaps in async
setup sequences, concurrent writers to shared state, and assumptions about
which operation completes first.
```

**Opus B — Goal evaluation & domain logic:**
```
YOUR FOCUS: Read the PR description carefully, then evaluate whether the
implementation actually achieves what it claims. If the PR says "events
are never lost," find a scenario where they could be. If it says
"checkpoint only advances safely," find a case where it doesn't. Be
adversarial about the stated goals — your job is to find the gap between
intent and implementation.
```

**Sonnet — Error handling & failure modes:**
```
YOUR FOCUS: Trace every error path and failure mode. What happens when a
database write fails mid-operation? When a background job exhausts its
retries? When a network call times out during a multi-step process? Look
for silent failures, missing error propagation, and recovery paths that
leave the system in an inconsistent state.
```

**Codex A — Edge cases & boundary conditions:**
```
YOUR FOCUS: Look for edge cases at boundaries. What happens at block 0?
When a range is empty? When both inputs are equal? When an optional value
is None for the first time? When a counter overflows? Find the inputs
that the author probably didn't test.
```

**Codex B — Broad general sweep:**
```
YOUR FOCUS: Do a broad, unbiased review. Don't focus on any particular
category — instead, try to find anything the other reviewers might miss.
Look at the change holistically: does the overall design make sense? Are
there interactions between components that could produce surprising
behavior? Are there implicit assumptions that aren't documented?
```

Save each complete prompt (base + focus) to `$out_dir/prompt-{reviewer}.txt`.

## 5. Spawn reviewers and inspectors in parallel

All reviewers and inspectors must be spawned in a **single message with
parallel tool calls**. Do not run them sequentially.

### Reviewers 1-3 — Claude Opus A, Opus B, Sonnet (Agent tool)

Spawn three `Agent` tool calls: two with `model: "opus"`, one with
`model: "sonnet"`. Each uses `subagent_type: "general-purpose"`. Each
gets its own prompt (base + focus paragraph from Step 4):

- **Opus A**: `$out_dir/prompt-opus-a.txt` (concurrency & async ordering)
- **Opus B**: `$out_dir/prompt-opus-b.txt` (goal evaluation & domain logic)
- **Sonnet**: `$out_dir/prompt-sonnet.txt` (error handling & failure modes)

Plus the suffix:

```
The diff is at: {DIFF_PATH}
Project docs: {PROJECT_DOCS_PATHS}
Repo root: {REPO_ROOT}

Read the diff, read the project docs, and read any source files referenced by
the diff that you need for context. Return your review in the format
specified above — nothing else.
```

Write each Agent's output to `$out_dir/raw-opus-a.md`,
`$out_dir/raw-opus-b.md`, and `$out_dir/raw-sonnet.md` respectively.

### Inspector agents — Test Inspector and Idiomatic Rust Inspector

Alongside the five reviewers, spawn two additional specialized inspector
agents. These produce structured reports in their own format (not the
reviewer finding format) and feed into the aggregator as supplementary
input.

**Test Inspector** — `model: "sonnet"`, `subagent_type: "general-purpose"`:

Prompt: the full content of the `/test-inspector` command skill
(`~/Github/dotclaude/commands/test-inspector.md`, everything below the
frontmatter). Replace `$ARGUMENTS` with the empty string (use the current
branch). Append:

```
The diff is at: {DIFF_PATH}
Repo root: {REPO_ROOT}

Read the diff to identify test files. Read the full test files and the
source files they test. Produce your inspection report. If no test files
are in the diff, say so and stop.
```

Write output to `$out_dir/raw-test-inspector.md`.

**Idiomatic Rust Inspector** — `model: "opus"`, `subagent_type: "general-purpose"`:

Prompt: the full content of the `/idiomatic-rust-inspector` command skill
(`~/Github/dotclaude/commands/idiomatic-rust-inspector.md`, everything
below the frontmatter). Replace `$ARGUMENTS` with the empty string (use
the current branch). Append:

```
The diff is at: {DIFF_PATH}
Repo root: {REPO_ROOT}

Read the diff to identify Rust files. Read the full files and related
type/trait/error definitions. Produce your inspection report. If no Rust
files are in the diff, say so and stop.
```

Write output to `$out_dir/raw-rust-inspector.md`.

**Skip conditions**: If the diff contains no test files, the test inspector
will self-exit (this is fine — record "no test files, skipped"). If the
diff contains no `.rs` files, the Rust inspector will self-exit (same
handling). The aggregator handles missing inspector reports gracefully.

### Reviewers 4-5 — Codex gpt-5.5 A and B (Bash)

Spawn two parallel `Bash` calls (both with `run_in_background: true`,
`timeout: 600000`). Both use `-m gpt-5.5`:

```bash
# Run for each instance: A (edge cases) and B (broad sweep).
# Replace $INSTANCE accordingly (a or b).
cat "$out_dir/diff.patch" | codex exec \
  --sandbox read-only \
  -m gpt-5.5 \
  -C "$repo_root" \
  "The diff is provided on stdin. Analyze it as a code reviewer.

$(cat "$out_dir/prompt-codex-${INSTANCE}.txt")

Project docs: <list of paths>
Repo root: $repo_root

Read the project docs and any source files referenced by the diff that you
need for context. Return your review in the format specified above —
nothing else." \
  > "$out_dir/codex-${INSTANCE}-stdout.log" 2>&1

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
- `--sandbox read-only` is non-negotiable — codex must not mutate the repo.
- The diff is piped via stdin so codex has the content without needing to
  find the file.
- `-C` sets the working directory so codex can resolve relative paths.
- **Output extraction**: Codex mixes internal tool-call output with review
  analysis. The review appears after a bare `codex` marker line near the end.
- If the `codex` marker is not found, the review file will be empty —
  recorded as "reviewer errored" in the aggregator.
- **Daily quota fallback**: If Codex fails with a daily limit error (look
  for `rate_limit` or `quota` with reset in hours), retry once with `-m o3`.

### Chunk splitting for large diffs

If the diff exceeds **3,500 lines**, split it into domain-based chunks to
keep each reviewer within quality range. Each chunk should be under ~3,500
lines.

1. Read `$out_dir/files.txt` to understand which files changed.
2. Group files by domain/crate/directory into logical chunks.
3. Generate per-chunk diffs using `git diff` with path filters:
   ```bash
   git diff "$parent"..HEAD -- 'crates/dto/' 'crates/finance/' > "$out_dir/chunk-a.patch"
   ```
4. Verify all files are covered.
5. Report chunk sizes to the user before proceeding.
6. Spawn **5 x N** reviewers (one per instance per chunk). Output files
   are named `raw-{model}-chunk-{label}.md`.
7. The aggregator receives ALL raw reviews across all chunks.

Skip chunking for diffs under 3,500 lines, single-directory diffs, or if the
user explicitly asks for a single-pass review.

### Output validation

After all reviewers finish, verify each output file:

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
continue. If all five error, stop.

### Parallelism

In a single Claude message, issue:

1. `Agent` call for Opus A
2. `Agent` call for Opus B
3. `Agent` call for Sonnet
4. `Bash` call for Codex gpt-5.5 A (`run_in_background: true`, `timeout: 600000`)
5. `Bash` call for Codex gpt-5.5 B (`run_in_background: true`, `timeout: 600000`)
6. `Agent` call for Test Inspector (`model: "sonnet"`)
7. `Agent` call for Idiomatic Rust Inspector (`model: "opus"`)

## 6. Aggregate

Spawn a fresh Claude Opus `Agent` to aggregate. This must be a new Agent
so it has no context pollution from the reviewers.

Aggregator prompt:

```
You are a senior staff engineer aggregating five independent code reviews of
the same diff. Your job is to produce a single canonical review report that
is more reliable than any individual reviewer.

You have five raw reviews:
- {OPUS_A_PATH}    (Claude Opus A)
- {OPUS_B_PATH}    (Claude Opus B)
- {SONNET_PATH}    (Claude Sonnet)
- {CODEX_A_PATH}   (Codex gpt-5.5 A)
- {CODEX_B_PATH}   (Codex gpt-5.5 B)

You also have two specialized inspector reports (may be empty if no
relevant files were in the diff):
- {TEST_INSPECTOR_PATH}    (Test Inspector — test quality assessment)
- {RUST_INSPECTOR_PATH}    (Idiomatic Rust Inspector — Rust idiom assessment)

And the diff itself at:
- {DIFF_PATH}

And the project conventions at:
- {PROJECT_DOCS_PATHS}

Do this:

1. Read all five reviews.
2. Read the diff so you can verify claims against the actual code.
3. For each distinct finding across the five reviews:
   a. Merge duplicates — findings that describe the same underlying issue
      should become one entry, even if worded differently.
   b. Record which reviewer(s) raised it: [opus-a], [opus-b], [sonnet],
      [codex-a], [codex-b], or a combination like [opus-a, sonnet].
   c. Verify the finding by reading the relevant code. For each one, form
      YOUR OWN opinion on whether it is:
         - valid: a real issue that should be fixed
         - likely: probably real but needs more context
         - disputed: reviewers disagree or the evidence is weak
         - invalid: false positive, not actually a problem
         - out-of-scope: real but on code not in the diff
   d. If a reviewer's claim conflicts with the actual code, mark it invalid
      and say why.
4. Re-score severity from scratch based on your own reading, using the same
   scale: critical | high | medium | low | nit.
5. Re-score confidence: 0-100, where 100 means you verified it yourself.

Output format:

# Review — {BRANCH}

**Commit:** {HEAD_SHA}
**Parent:** {PARENT_SHA} ({PARENT_BRANCH})
**Files changed:** {N}
**Diff size:** {LOC} lines
**Reviewers:** Claude Opus A, Claude Opus B, Claude Sonnet, Codex gpt-5.5 A, Codex gpt-5.5 B
**Aggregator:** Claude Opus

## Summary

<2-3 sentence overall verdict. Include the count of valid findings at each
severity.>

## Findings

<findings sorted by: severity (critical first), then validity (valid first),
then confidence (high first)>

For each finding:

### [SEVERITY] <short title>

- **File:** <path>:<line-range>
- **Category:** correctness | security | convention | maintainability | tests
- **Validity:** valid | likely | disputed | invalid | out-of-scope
- **Confidence:** <0-100>
- **Found by:** [opus-a], [opus-b], [sonnet], [codex-a], [codex-b], or a list
- **Issue:** <one paragraph>
- **Why it matters:** <concrete consequence>
- **Recommended fix:** <specific action>
- **Aggregator opinion:** <your own take — do you agree with the reviewers?
  Is this worth fixing? Is any reviewer overreaching?>

## Findings dismissed as invalid

<bullet list of findings you rejected, each with one-sentence rationale and
which reviewer raised it>

## Findings dismissed as out-of-scope

<bullet list — real issues but on code the diff did not touch>

## Overall assessment

<2-3 paragraphs. Your own senior-engineer judgment on whether this PR is
ready to merge, needs a second pass, or has fundamental issues. Call out
anything the individual reviewers missed collectively if you spot it.>

Inspector reports use a different format from the five reviewers. Integrate
their findings as follows:

- **Test Inspector findings** (useless/weak tests, missing coverage, mock
  abuse): convert each into a standard finding entry. Use category "tests".
  Severity: useless tests = medium, weak tests = low, missing coverage for
  risky logic = high, mock abuse = medium.
- **Idiomatic Rust Inspector findings** (non-idiomatic code, ownership
  issues, error handling, type design): convert each into a standard
  finding entry. Use category "maintainability" for style/idiom issues,
  "correctness" for ownership bugs or unsafe misuse. Severity: non-idiomatic
  with correctness impact = high, non-idiomatic style-only = medium,
  suboptimal = low.
- If an inspector report is empty or says "no files found", ignore it.
- Inspector findings can corroborate or conflict with the five reviewer
  findings — merge duplicates as you would between any two reviewers.
- In the "Found by" field, use [test-inspector] or [rust-inspector] as
  the attribution.

Do not include emojis, apologies, or disclaimers. Be decisive.
```

Write the aggregator's output to `$out_dir/review.md`.

## 7. Print findings to the terminal

Print a compact, scannable summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Review — <branch>
<N> files, <LOC> lines changed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▲ CRITICAL (count)
  1. <title>
     <file>:<line>  [opus, codex]  confidence: 95
     <one-line fix>

▲ HIGH (count)
  ...

▲ MEDIUM (count)
  ...

▲ LOW (count)
  ...

▲ NIT (count)
  ...

▽ Dismissed as invalid: <count>
▽ Dismissed as out-of-scope: <count>

Full report: <absolute path to review.md>
```

Keep each finding to **two lines**: title line (title + agents + confidence)
and fix line (recommended fix). The full details live in `review.md`.

If the review reports **no findings**, print that prominently and exit —
nothing to loop over.

---

## 8. Load the report & triage

Read `$out_dir/review.md`. For each finding in the "Findings" section
(excluding the "Dismissed as invalid" and "Dismissed as out-of-scope"
sections), extract:

- `title`
- `severity` (critical | high | medium | low | nit)
- `validity` (valid | likely | disputed)
- `confidence` (0-100)
- `category` (correctness | security | convention | maintainability | tests)
- `file` and `line-range`
- `issue` text
- `recommended_fix`
- `aggregator_opinion`

Skip findings already marked `invalid` or `out-of-scope` by the aggregator —
they've been pre-filtered.

## 9. Build the triage plan

For each remaining finding, compute a **default action** based on severity,
validity, and confidence. **Bias heavily toward fixing now** — only defer
when the fix is massive enough to warrant its own stacked PR.

| Severity   | Validity | Confidence | Default action |
| ---------- | -------- | ---------- | -------------- |
| critical   | any      | any        | **Auto-fix**   |
| high       | valid    | >= 50      | **Auto-fix**   |
| high       | likely   | >= 50      | **Auto-fix**   |
| high       | disputed | any        | **Discuss**    |
| medium     | valid    | >= 50      | **Auto-fix**   |
| medium     | likely   | >= 50      | **Auto-fix**   |
| medium     | disputed | any        | **Discuss**    |
| low        | valid    | >= 75      | **Auto-fix**   |
| low        | any      | < 75       | **Auto-dismiss** |
| nit        | any      | any        | **Auto-dismiss** |

**Auto-fix**: apply the fix immediately without asking. No user input needed.

**Auto-dismiss**: drop the finding silently. No user input needed.

**Discuss**: the evidence is weak or reviewers disagree. Show the user the
full finding and ask what to do. Default to fixing unless it's massive.

**Defer to Linear** is NOT a default action. Only use it when:
- The user explicitly asks to defer a specific finding, OR
- A fix is large enough that it should be a separate stacked PR (e.g.,
  a multi-file refactor or new feature, not a surgical bug fix)

When in doubt, fix it now.

## 10. Present the plan and auto-apply

Print the plan as a table, in severity order:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Review-loop triage — <N> findings (iteration <I>)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 # | sev      | action       | title
---+----------+--------------+------------------------
 1 | critical | auto-fix     | Off-by-one in batch loop
 2 | high     | auto-fix     | Missing auth check on /admin
 3 | medium   | auto-fix     | Add retry on transient errors
 4 | medium   | DISCUSS      | Lock contention in hot path
 5 | nit      | auto-dismiss | Rename variable for clarity

Full details: <path to review.md>
```

**Auto-fix and auto-dismiss findings proceed immediately — no user input.**

For **discuss** findings only, use `AskUserQuestion`:

```
Q: [#N] <title> — sev <severity>. Reviewers disagree — what should I do?
   options:
     - "Fix now" (Recommended) — implement the fix in this session
     - "Dismiss" — drop it, not a real issue
     - "Defer" — too large for this PR, will stack separately
     - "Show me the details" — read the full finding first
```

If the user picks "Show me the details", present the finding
conversationally and re-ask without that option.

After resolving discuss items, print the consolidated plan:

```
Plan:
  Fix now (4):     #1, #2, #3, #4
  Dismiss (1):     #5
```

## 11. Fix-now loop

For each "fix now" finding, in severity order:

1. Announce which one you're addressing.
2. Read the relevant source file(s).
3. Verify the finding is still valid (the code may have been edited since
   the review — re-read, don't trust the report blindly).
4. Apply the recommended fix using `Edit` (or `Write` for new files). Keep
   the change surgical — do not drift into unrelated cleanups. Match the
   project's style.
5. If the fix touches tests or requires them, add/update the tests. If the
   user's project docs (`CLAUDE.md`/`AGENTS.md`) mandate test coverage for
   the kind of logic being fixed, add tests even if the finding didn't
   mention it.
6. Print a one-line summary of what changed.
7. Do **not** run tests, typecheck, or commit yet — batch those at the end.

If while implementing a fix you realize it's larger than expected or the
finding is more nuanced than the report suggests, stop and tell the user.
Offer to re-triage (defer, dismiss, or adjust the fix).

After all fix-now items are done:

1. Run `/ci` (invoke the `ci` skill) to verify all changes are correct.
   Let the ci loop run until it passes or it asks the user for help. If
   `/ci` makes additional fixes, that's expected — it's part of this loop.
2. Report results. If something broke during `/ci`, address it before
   moving on — do not leave red tests or lint failures.
3. **Do not commit or `gt modify` automatically.**
4. Proceed to step 12 (re-review).

## 12. Re-review loop

After CI passes, re-run the full review to catch issues introduced by the
fixes. This is the core of the automatic loop.

**CRITICAL: The re-review is NOT optional.** After fixing findings, you
MUST re-run the review at least once. Do not skip it because the fixes
"looked straightforward" or "were simple." The entire point of this loop
is to catch issues introduced by fixes — you cannot know whether fixes
introduced new issues without re-reviewing. Only the review determines
when the loop is done, not your judgment.

1. Re-run **steps 2 through 7** in full — resolve scope, generate the
   diff, build prompts, spawn all five reviewers, aggregate, and print
   findings. The diff will now include the fixes (current state vs
   `gt parent`), so it reviews the full PR including the new changes.
   After the review finishes, **copy its `review.md` into the original
   review directory** as `review-iter{N}.md` so the full audit trail
   lives in one place:
   ```bash
   cp "$new_out_dir/review.md" "$original_out_dir/review-iter${iteration}.md"
   ```
2. If the review returns **no findings**: the loop is done. Print
   "Re-review clean — no new findings" and proceed to step 13 (defer) or
   step 14 (summarize).
3. If the review returns findings:
   - **Filter out findings already addressed** in a previous iteration.
     Compare by file + line range + issue description. If a finding is
     substantively the same as one already fixed or dismissed, skip it.
   - If **no new findings remain** after filtering: the loop is done.
   - If **new findings remain**: increment the review iteration counter,
     loop back to step 8 (triage) with only the new findings.

**Cap at 3 review iterations** (initial + 2 re-reviews). If new findings
keep appearing after 3 iterations, stop and tell the user — the fixes are
likely introducing as many issues as they solve, and a human needs to
assess the approach.

Print a status line at the start of each iteration:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Re-review iteration <N> — checking for new issues
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 13. Defer-to-Linear loop (only if user explicitly deferred findings)

This step only runs if the user chose "Defer" for any discuss finding.
Skip entirely if no findings were deferred.

For each "defer" finding, invoke the `linear-cli` skill. For each one:

1. **Draft the issue** in a tempfile, following the linear-cli skill's
   "Drafting issues from review findings" pattern:

   - **Title:** a concise imperative summary derived from the finding title.
     Lead with the action, not the problem. Example: "Add retry on
     transient HTTP errors in broker client" not "Missing retry".
   - **Body** (in the tempfile):

     ```markdown
     ## Problem

     <issue text from the finding>

     ## Evidence

     - File: `<path>:<line-range>`
     - Finding category: <correctness | security | convention | ...>
     - Severity: <severity>
     - Found during review of branch `<branch>` (commit `<sha>`)

     ## Proposed fix

     <recommended_fix from the finding>

     ## Aggregator opinion

     <aggregator_opinion from the review>

     ---

     Deferred from review `<path to review.md>`.
     ```

2. **Choose metadata**: priority by severity (critical -> urgent, high ->
   high, medium -> medium, low -> low, nit -> low). Labels: prefer `bug`
   for correctness/security, `tech-debt` for maintainability, `test` for
   test-coverage findings. Project and team come from the repo's
   `.linear.toml` — let `linear` pick them up automatically. Do not pass
   `--team` or `--project` unless the user tells you which ones.

3. **Show the draft to the user** before running any `linear` command.
   Format:

   ```
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Draft Linear issue — [#N] <finding title>
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Title:    <draft title>
   Priority: <severity-derived>
   Labels:   <labels>

   <body contents>
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ```

4. **Ask for confirmation**, using `AskUserQuestion`:

   ```
   Q: Create this Linear issue for finding #N?
     options:
       - "Create"    (Recommended)
       - "Edit"      — tell me what to change
       - "Skip"      — don't create this one
   ```

   If the user picks "Edit", ask what to change, revise, and re-confirm.

5. **Create the issue** only after explicit confirmation:

   ```bash
   body_file=$(mktemp -t linear-issue.XXXXXX.md)
   cat > "$body_file" <<'EOF'
   <approved body>
   EOF
   linear issue create \
     --title "<approved title>" \
     --description-file "$body_file" \
     --priority <severity-derived> \
     --label <labels>
   rm "$body_file"
   ```

6. **Print the issue URL** returned by `linear issue create` and record the
   issue ID — you'll reference them in the summary.

You can batch the confirmation step: if there are multiple "defer" findings,
draft all of them first, show all drafts, ask in one `AskUserQuestion`
call (up to 4 at a time). Don't skip showing the drafts — the user must see
the title and body before any issue is created.

## 14. Summarize

After all review iterations converge (no new findings) and any deferred
Linear issues are created (or skipped), print a final summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Review loop complete — <N> iteration(s), converged clean
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Fixed (3):
  #1  critical  Off-by-one in batch loop               <file>:<line>
  #2  high      Missing auth check on /admin            <file>:<line>
  #4  medium    Lock contention in hot path             <file>:<line>

Deferred to Linear (1):
  #3  medium    Add retry on transient errors           <linear url>

Dismissed (1):
  #5  nit       Rename variable for clarity

Reports: <paths to review.md files from each iteration>
```

Then stop. Do not auto-run `gt modify`, `gt submit`, or any other
mutation — the user decides when to amend and push.

---

## Failure modes

- **All reviewers error:** stop immediately, tell the user, don't proceed
  to triage.
- **Review returns no findings:** print "No findings" and exit the command
  successfully — nothing to loop over.
- **A fix turns out to be larger than expected:** stop, report progress,
  ask whether to continue, defer to a stacked PR, or dismiss.
- **Re-review iteration cap hit (3 iterations):** stop and tell the user.
  Summarize what was fixed in each iteration and what new issues keep
  appearing. The fixes are likely introducing as many issues as they solve.
- **A Linear issue fails to create:** report the exact `linear` error,
  leave the draft tempfile in place, and continue with the rest of the
  deferred items. Ask the user whether to retry the failed one at the end.
- **The user says "stop" mid-loop:** immediately stop, then print the
  summary with what was completed so far. Do not silently abandon the rest.
- **Codex not installed:** warn the user and run with Claude-only reviewers
  (3 instead of 5). Three reviewers is still valuable.

## Hard rules

1. **Auto-fix without asking** for findings that match auto-fix criteria.
   Only ask the user about "discuss" findings.
2. **Bias toward fixing now.** Defer to Linear only when the user explicitly
   asks or the fix is too large for the current PR.
3. Never create Linear issues without explicit per-issue user confirmation
   of the exact draft content.
4. Never amend, commit, or `gt submit` automatically — the user drives
   version control.
5. Always use `--description-file` with `linear issue create`, never inline
   `--description`.
6. Always re-verify findings against the current source before applying
   fixes — the code may have changed since the review.
7. Keep fixes surgical. No "while I'm here" cleanups.
8. After all fixes, run `/ci` and report results before re-reviewing.
9. Cap at 3 review iterations. Stop and ask the user if you don't converge.
10. Spawn all reviewers in a single message with parallel tool calls.
11. Use `--sandbox read-only` for codex — non-negotiable.
12. The aggregator is a separate Agent call, never reuse the main session
    to aggregate (context pollution).
13. Never fabricate findings when a reviewer errors — record the failure.
14. Save raw outputs and the aggregated report before printing to terminal.
15. Never silently modify `.gitignore` — ask permission to add
    `claude-local-ctx/` if missing.
16. Validate reviewer output files before passing to aggregator — reject
    files that contain dumped file contents instead of review analysis.

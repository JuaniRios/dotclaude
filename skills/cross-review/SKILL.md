---
name: cross-review
description: Run a multi-agent code review of the current branch/PR. Spawns three senior-engineer reviewers in parallel (Claude Opus, OpenAI Codex, Google Gemini), aggregates their findings with a Claude Opus aggregator, saves a markdown report, and prints structured findings to the terminal. Use when the user asks for a "cross review", "multi-agent review", "second opinion", "code review of this PR/branch/stack", or any phrasing that implies reviewing the current change set before pushing or handing off.
allowed-tools: Bash(gt:*), Bash(git:*), Bash(gh:*), Bash(codex:*), Bash(gemini:*), Bash(mkdir:*), Bash(wc:*), Bash(date:*), Bash(basename:*), Bash(test:*), Read, Write, Agent
---

# Cross-review — three reviewers in parallel

Runs an exhaustive code review of the **current branch's diff against its
graphite parent** using three independent frontier reasoning models, then
aggregates their findings into one canonical report.

Reviewers:

1. **Claude Opus** (via the `Agent` tool, subagent_type `general-purpose`, model `opus`)
2. **OpenAI Codex** (via `codex exec`, read-only sandbox)
3. **Google Gemini 2.5 Pro** (via `gemini -m gemini-2.5-pro -p`, `--approval-mode plan`)

Aggregator: a second **Claude Opus** Agent that merges, dedupes, scores, and
gives a personal opinion on each finding's validity.

---

## Preflight

Before invoking the reviewers, verify:

1. You are in a git repo with a graphite-tracked branch. If the user is
   reviewing someone else's PR or a non-checked-out diff, they should use the
   `/review-pr` command instead, which supplies the diff externally.
2. `codex`, `gemini`, and `gt` are on PATH:

   ```bash
   command -v codex gemini gt
   ```

3. The working tree is clean or stashed. A dirty tree pollutes the diff and
   confuses reviewers. If dirty, tell the user and stop.

## Step 1 — Resolve scope

Determine what to review. On a graphite stack, **always diff against `gt
parent`**, not trunk — reviewing against trunk on a stacked branch would
include ancestor PRs and drown the reviewers in unrelated changes.

```bash
parent=$(gt parent 2>/dev/null || git merge-base origin/main HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
ts=$(date +%Y-%m-%d_%H-%M-%S)
safe_branch=$(echo "$branch" | tr '/' '_')
out_dir="$repo_root/claude-local-ctx/reviews/${ts}-${safe_branch}"
mkdir -p "$out_dir"
```

Then write the diff and a file manifest:

```bash
git diff "$parent"..HEAD > "$out_dir/diff.patch"
git diff --name-status "$parent"..HEAD > "$out_dir/files.txt"
wc -l "$out_dir/diff.patch"
```

Refuse to proceed if the diff is empty. If it's absurdly huge (>5000 lines),
warn the user and ask if they want to proceed — very large diffs degrade
reviewer quality.

**Ensure the local-ctx folder is gitignored.** If `claude-local-ctx/` is not in
`.gitignore` (check with `grep -q claude-local-ctx "$repo_root/.gitignore"`),
ask the user for permission to add it. Do not silently modify `.gitignore`.

## Step 2 — Load project context

Before spawning reviewers, collect project conventions so each reviewer grades
the diff against the project's actual standards, not generic best practices:

```bash
# Find relevant CLAUDE.md / AGENTS.md files
find "$repo_root" -maxdepth 3 \( -name "CLAUDE.md" -o -name "AGENTS.md" \) \
  -not -path "*/node_modules/*" -not -path "*/target/*"
```

For each found file, keep only the **path** (the reviewers will read them
themselves) — don't inline them into the prompt, they're often 20k+ chars.

## Step 3 — The reviewer prompt

Every reviewer gets the same system prompt. Paste it verbatim into each
reviewer invocation, with the diff path and project-docs paths substituted:

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

Save this prompt to `$out_dir/prompt.txt` so all three reviewers read the same
text and you have a record of what was asked.

## Step 4 — Spawn reviewers in parallel

All three reviewers must be spawned in a **single message with three parallel
tool calls**. Do not run them sequentially — it wastes wall time and defeats
the point of cross-review.

### Reviewer 1 — Claude Opus (Agent tool)

Use the `Agent` tool, `subagent_type: "general-purpose"`, `model: "opus"`. The
prompt is the senior-engineer text above, plus:

```
The diff is at: {DIFF_PATH}
Project docs: {PROJECT_DOCS_PATHS}
Repo root: {REPO_ROOT}

Read the diff, read the project docs, and read any source files referenced by
the diff that you need for context. Return your review in the format
specified above — nothing else.
```

### Reviewer 2 — OpenAI Codex (Bash)

```bash
cat "$out_dir/diff.patch" | codex exec \
  --sandbox read-only \
  -C "$repo_root" \
  "The diff is provided on stdin. Analyze it as a code reviewer.

$(cat "$out_dir/prompt.txt")

Project docs: <list of paths>
Repo root: $repo_root

Read the project docs and any source files referenced by the diff that you
need for context. Return your review in the format specified above —
nothing else." \
  > "$out_dir/codex-stdout.log" 2>&1
codex_exit=$?

# Extract review from Codex output.
# Codex mixes file-read echoes and tool-call logs with the actual review
# in its output. The review appears after a bare "codex" marker line near
# the end. Extract from that marker to the "tokens used" footer.
codex_marker=$(grep -n '^codex$' "$out_dir/codex-stdout.log" | tail -1 | cut -d: -f1)
if [ -n "$codex_marker" ]; then
  tail -n +$((codex_marker + 1)) "$out_dir/codex-stdout.log" \
    | sed '/^tokens used$/,$d' \
    > "$out_dir/raw-codex.md"
fi
```

Notes:
- `--sandbox read-only` is non-negotiable — codex must not mutate the repo.
- The diff is piped via stdin so codex has the content without needing to find
  the file. Codex can still read other repo files for context.
- `-C` sets the working directory so codex can resolve relative paths.
- **Output extraction**: Codex mixes internal tool-call output (file reads,
  grep results, status lines) with the actual review analysis in a single
  stream. The review portion appears after a bare `codex` marker line near the
  end of output. The extraction step isolates just the review findings.
- If the `codex` marker is not found, the review file will be empty — recorded
  as "reviewer errored" in the aggregator.
- **Daily quota fallback**: If Codex fails with a daily limit error (look for
  `rate_limit` or `quota` with reset times in hours), retry once with
  `-m o3` as a cheaper fallback. Short rate limits (reset in seconds/minutes)
  should be retried with backoff, not model-switched.

### Reviewer 3 — Google Gemini (Bash)

Gemini's API has aggressive rate limits. Use a retry loop with exponential
backoff (max 60 seconds total):

```bash
gemini_with_fallback() {
  local out_file="$1"
  local log_file="$2"
  shift 2
  local max_wait=60
  local attempt=0
  local delay=5
  local elapsed=0
  local model_args=("$@")

  while [ "$elapsed" -lt "$max_wait" ]; do
    attempt=$((attempt + 1))
    gemini "${model_args[@]}" > "$log_file" 2>&1
    gemini_exit=$?

    # Success: check if findings were produced
    if [ -f "$out_file" ] && [ "$(wc -l < "$out_file")" -gt 5 ]; then
      return 0
    fi
    # Also check log for findings (Gemini may output to stdout, not file)
    if grep -q '^### ' "$log_file" 2>/dev/null; then
      sed -n '/^### /,$p' "$log_file" > "$out_file"
      return 0
    fi

    # Check for DAILY quota exhaustion (reset in hours — NOT short rate limits)
    # TerminalQuotaError with reset time in hours means daily limit, not transient.
    if grep -q 'TerminalQuotaError\|quota will reset after [0-9]*h' "$log_file" 2>/dev/null; then
      echo "Gemini daily quota exhausted. Falling back to gemini-2.5-flash..." >&2
      # Replace the model arg and retry once with the cheaper model
      local new_args=()
      local skip_next=false
      for arg in "${model_args[@]}"; do
        if $skip_next; then
          new_args+=("gemini-2.5-flash")
          skip_next=false
        elif [ "$arg" = "-m" ]; then
          new_args+=("$arg")
          skip_next=true
        else
          new_args+=("$arg")
        fi
      done
      gemini "${new_args[@]}" > "$log_file" 2>&1
      if grep -q '^### ' "$log_file" 2>/dev/null; then
        sed -n '/^### /,$p' "$log_file" > "$out_file"
        echo "(Gemini review produced via gemini-2.5-flash fallback)" >> "$out_file"
        return 0
      fi
      return 1
    fi

    # Short rate limit (429 with reset in seconds/minutes) — retry with backoff
    if grep -q '429\|exhausted your capacity\|quota will reset after [0-9]*s\|quota will reset after [0-9]*m' "$log_file" 2>/dev/null; then
      echo "Gemini attempt $attempt rate-limited, retrying in ${delay}s..." >&2
      sleep "$delay"
      elapsed=$((elapsed + delay))
      delay=$((delay * 2))
      [ "$delay" -gt 30 ] && delay=30
    else
      # Non-rate-limit failure — don't retry
      return "$gemini_exit"
    fi
  done
  echo "Gemini exhausted retry budget (${max_wait}s)" >&2
  return 1
}

gemini_with_fallback "$out_dir/raw-gemini.md" "$out_dir/gemini-stdout.log" \
  -m gemini-2.5-pro \
  -p "$(cat "$out_dir/prompt.txt")

The diff is at: $gemini_tmp/diff.patch
Project docs: <list of paths>
Repo root: $repo_root

Read the diff, project docs, and any source files for context.
Return your review in the format specified above — nothing else." \
  --approval-mode plan \
  -o text
```

Notes:
- `--approval-mode plan` keeps gemini read-only.
- `-o text` forces plain text output (not interactive TUI).
- The retry loop handles 429 rate limits and `MODEL_CAPACITY_EXHAUSTED` errors
  with exponential backoff, giving up after 60 seconds total.
- Like codex, the prompt instructs gemini to write findings to the output file.
- Gemini CLI has its own internal retry/backoff for 429s. Our wrapper adds an
  outer retry that checks if the output file was actually written.
- If Gemini is capacity-exhausted across all retries, record it as "reviewer
  errored" and continue with Opus + Codex. Two reviewers is still valuable.

**CRITICAL: Gemini file access restrictions.** Gemini CLI cannot read files that
are (a) gitignored or (b) outside the workspace. Since `claude-local-ctx/` is
gitignored and `/tmp/` is outside workspace, neither works for diff files.

**Solution**: Copy diff files to Gemini's allowed temp directory before launching:

```bash
gemini_tmp="$HOME/.gemini/tmp/$(basename "$repo_root")"
mkdir -p "$gemini_tmp"
cp "$out_dir"/diff.patch "$gemini_tmp/"
# For chunked reviews, also copy chunk patches
cp "$out_dir"/chunk-*.patch "$gemini_tmp/" 2>/dev/null
```

Then reference `$gemini_tmp/diff.patch` (or `$gemini_tmp/chunk-*.patch`) in the
Gemini prompt. Gemini can read from its own temp directory.

**Gemini output extraction**: Gemini outputs review findings to stdout (it
cannot write to gitignored dirs either). Extract findings from the log by
finding the first `### ` heading:

```bash
if grep -q '^### ' "$log_file"; then
  sed -n '/^### /,$p' "$log_file" > "$out_dir/raw-gemini.md"
fi
```

**Stagger launches**: When running multiple Gemini instances (e.g., chunked
reviews), stagger them by 10 seconds to avoid simultaneous rate-limit hits.
Gemini 2.5 Pro has aggressive per-minute quotas; 3-5s gaps are not enough.
Launch the first immediately, then `sleep 10` between each subsequent one.
For 4+ chunks, consider running Gemini chunks sequentially rather than in
parallel — the rate limits make parallel execution counterproductive.

### Output validation

After all reviewers finish, verify each output file contains actual review
content — not dumped file reads or error logs:

```bash
validate_review() {
  local file="$1"
  local reviewer="$2"
  if [ ! -f "$file" ]; then
    echo "$reviewer: no output file"
    return 1
  fi
  local lines=$(wc -l < "$file")
  if [ "$lines" -lt 5 ]; then
    echo "$reviewer: output too short ($lines lines)"
    return 1
  fi
  # Check that output contains structured findings (### headings)
  if ! grep -q '^### ' "$file"; then
    echo "$reviewer: no finding headings found — likely dumped file contents"
    return 1
  fi
  return 0
}
```

If a reviewer's output fails validation, record it as "reviewer errored" in the
aggregator prompt and continue with the other reviewers. If a reviewer dumps
file contents to the output file (common with Codex), do not use that output.

### Parallelism

In a single Claude message, issue:

1. `Agent` call for Opus (one per chunk if chunked — see below)
2. `Bash` call for codex (use `run_in_background: true`)
3. `Bash` call for gemini (use `run_in_background: true`)

Claude's runtime parallelizes sibling tool calls in a single assistant message,
so all three run concurrently. Use long timeouts (`timeout: 600000`, 10 min)
on the bash calls — reasoning models are slow. Use `run_in_background: true` on
the Bash calls so Claude can proceed when they finish rather than blocking.

The Opus result comes back as the Agent tool result. Write it to
`$out_dir/raw-opus.md` (or `raw-opus-{chunk}.md` if chunked) after it returns.

## Step 4a — Chunk splitting for large diffs

If the diff exceeds **3,500 lines**, split it into domain-based chunks to keep
each reviewer within quality range. Each chunk should be under ~3,500 lines.

### How to chunk

1. Read `$out_dir/files.txt` to understand which files changed.
2. Group files by domain/crate/directory into logical chunks. Good groupings:
   - **By crate/package**: `crates/dto/*`, `crates/execution/*`, etc.
   - **By layer**: backend core (`src/`), frontend (`dashboard/`), tests
     (`tests/`)
   - **By concern**: domain types, business logic, infrastructure, tests
3. Generate per-chunk diffs using `git diff` with path filters:
   ```bash
   git diff "$parent"..HEAD -- 'crates/dto/' 'crates/finance/' > "$out_dir/chunk-a.patch"
   git diff "$parent"..HEAD -- 'src/dashboard/' 'src/position.rs' > "$out_dir/chunk-b.patch"
   # etc.
   ```
4. Verify all files are covered — the sum of chunk files should equal the total.
5. Report chunk sizes to the user before proceeding.

### Chunked reviewer dispatch

With N chunks, spawn **3 x N** reviewers (one per model per chunk):
- N Opus Agent calls (one per chunk, all in `run_in_background: true`)
- One Bash call per model that loops over chunks (Codex and Gemini)

Each reviewer gets the chunk-specific diff path and the same prompt. Output
files are named `raw-{model}-{chunk}.md` (e.g., `raw-opus-a.md`,
`raw-codex-b.md`).

### Chunked aggregation

The aggregator receives ALL raw reviews across all chunks and all models. Its
job expands to also cross-reference findings across chunks (e.g., a DTO change
in chunk A that breaks an assumption in chunk B). The aggregator prompt should
list all raw review files and note which chunk each covers.

### When NOT to chunk

- Diffs under 3,500 lines — run the standard single-diff flow.
- If the user explicitly asks for a single-pass review.
- If the diff touches a single crate/directory — chunking by domain would
  produce one chunk, which is pointless.

## Step 5 — Aggregate

Spawn a **fourth** Agent call — another Claude Opus — to aggregate. This must
be a fresh Agent so it has no context pollution from the reviewers.

Aggregator prompt (paste verbatim):

```
You are a senior staff engineer aggregating three independent code reviews of
the same diff. Your job is to produce a single canonical review report that
is more reliable than any individual reviewer.

You have three raw reviews:
- {OPUS_PATH}  (Claude Opus)
- {CODEX_PATH} (OpenAI Codex)
- {GEMINI_PATH} (Google Gemini)

And the diff itself at:
- {DIFF_PATH}

And the project conventions at:
- {PROJECT_DOCS_PATHS}

Do this:

1. Read all three reviews.
2. Read the diff so you can verify claims against the actual code.
3. For each distinct finding across the three reviews:
   a. Merge duplicates — findings that describe the same underlying issue
      should become one entry, even if worded differently.
   b. Record which reviewer(s) raised it: [opus], [codex], [gemini], or a
      combination like [opus, codex].
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

# Cross-review — {BRANCH}

**Commit:** {HEAD_SHA}
**Parent:** {PARENT_SHA} ({PARENT_BRANCH})
**Files changed:** {N}
**Diff size:** {LOC} lines
**Reviewers:** Claude Opus, OpenAI Codex, Google Gemini
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
- **Found by:** [opus], [codex], [gemini], or a list
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

Do not include emojis, apologies, or disclaimers. Be decisive.
```

Write the aggregator's output to `$out_dir/review.md`.

## Step 6 — Print findings to the terminal

Print a compact, scannable summary to stdout. Format:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Cross-review — <branch>
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

Use unicode box drawing (`━`, `▲`, `▽`) for the section headers — this is
terminal-display output, not code.

Keep each finding to **two lines**: title line (title + agents + confidence)
and fix line (recommended fix). The full details live in `review.md`.

Print the path to the report at the end. Do not print the invalid/out-of-scope
finding details — just the count.

## Failure modes

- **A reviewer errors out:** record the failure in the aggregator prompt
  ("reviewer X returned no usable output") and continue with the other two.
  Note in the final report that fewer than 3 reviewers contributed.
- **All reviewers error:** stop and tell the user. Don't fake a report.
- **No findings:** print "No findings" prominently and still save the report.
- **Reviewers disagree wildly:** the aggregator's job is to verify against the
  code and decide. The aggregator opinion is authoritative — don't just list
  disagreements.

## Output structure

At the end, `$out_dir/` contains:

**Standard (single-diff) review:**

```
claude-local-ctx/reviews/<ts>-<branch>/
├── diff.patch          # the reviewed diff
├── files.txt           # file change manifest
├── prompt.txt          # the reviewer prompt (for reproducibility)
├── raw-opus.md         # Claude Opus's raw review
├── raw-codex.md        # OpenAI Codex's raw review
├── raw-gemini.md       # Google Gemini's raw review
├── codex-stdout.log    # Codex session log (for debugging)
├── gemini-stdout.log   # Gemini session log (for debugging)
└── review.md           # the aggregated canonical report
```

**Chunked review (large diffs):**

```
claude-local-ctx/reviews/<ts>-<branch>/
├── diff.patch              # full diff (for reference)
├── chunk-a-<label>.patch   # per-chunk diffs
├── chunk-b-<label>.patch
├── files.txt
├── prompt.txt
├── raw-opus-a.md           # per-chunk per-model raw reviews
├── raw-opus-b.md
├── raw-codex-a.md
├── raw-codex-b.md
├── raw-gemini-a.md
├── raw-gemini-b.md
├── codex-stdout.log
├── gemini-stdout.log
└── review.md               # single aggregated report across all chunks
```

The canonical, user-facing output is `review.md`. Raw files are kept for audit
and for tools like `/review-loop` to re-read without re-running reviewers.

## When NOT to use this skill

- Reviewing someone else's PR that isn't checked out — use `/review-pr` instead,
  which fetches the diff from GitHub and skips graphite.
- Reviewing a specific commit range the user names explicitly — adjust the
  `parent` variable at step 1 to the user-supplied range.
- Re-reviewing after small fixes — offer to re-run on the delta
  (`git diff HEAD~1..HEAD`) instead of re-running the whole cross-review.

## Hard rules

1. Always diff against `gt parent`, never against trunk on a stacked branch.
2. Spawn all reviewers in a single message with parallel tool calls.
3. Use `--sandbox workspace-write` for codex and `--approval-mode plan` for
   gemini — non-negotiable.
4. The aggregator is a separate Agent call, never reuse the main session to
   aggregate (context pollution).
5. Never fabricate findings when a reviewer errors — record the failure.
6. Save raw outputs and the aggregated report before printing to terminal.
7. Never silently modify `.gitignore` — ask permission to add
   `claude-local-ctx/` if missing.
8. Validate reviewer output files before passing to aggregator — reject files
   that contain dumped file contents instead of review analysis.
9. For diffs over 3,500 lines, chunk by domain and run reviewers per-chunk.
10. Gemini calls must use the retry-with-backoff wrapper (max 60s) to handle
    429 rate limits.

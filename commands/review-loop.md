---
allowed-tools: Bash(gt:*), Bash(git:*), Bash(gh:*), Bash(codex:*), Bash(gemini:*), Bash(linear:*), Bash(mkdir:*), Bash(cat:*), Bash(mktemp:*), Bash(rm:*), Bash(test:*), Bash(grep:*), Read, Write, Edit, Agent, Skill, AskUserQuestion
description: Cross-review the current branch, auto-fix findings, and re-review until clean. Loops automatically — only stops for user input on disputed findings or massive changes.
---

Run a full self-review loop on the current branch: cross-review → auto-fix →
CI → re-review → repeat until clean. Use this right before you `gt submit`
something you wrote yourself, to catch issues before reviewers do.

The loop is **automatic by default**. Findings that clearly should be fixed
are fixed without asking. The loop re-runs cross-review after each fix pass
to catch issues introduced by the fixes themselves. It stops when
cross-review returns no new actionable findings.

Follow these steps precisely.

## 1. Run the cross-review skill

Invoke the `cross-review` skill. When it finishes you will have:

- `$out_dir/review.md` — the canonical aggregated report
- `$out_dir/raw-{opus,codex,gemini}.md` — raw reviewer outputs
- A printed terminal summary

Record `$out_dir` — you'll reference the report again.

If `cross-review` reports **no findings**, print that prominently and exit —
nothing to loop over.

## 2. Load the report

Read `$out_dir/review.md`. For each finding in the "Findings" section
(excluding the "Dismissed as invalid" and "Dismissed as out-of-scope"
sections), extract:

- `title`
- `severity` (critical | high | medium | low | nit)
- `validity` (valid | likely | disputed)
- `confidence` (0–100)
- `category` (correctness | security | convention | maintainability | tests)
- `file` and `line-range`
- `issue` text
- `recommended_fix`
- `aggregator_opinion`

Skip findings already marked `invalid` or `out-of-scope` by the aggregator —
they've been pre-filtered.

## 3. Build the triage plan

For each remaining finding, compute a **default action** based on severity,
validity, and confidence. **Bias heavily toward fixing now** — only defer
when the fix is massive enough to warrant its own stacked PR.

| Severity   | Validity | Confidence | Default action |
| ---------- | -------- | ---------- | -------------- |
| critical   | any      | any        | **Auto-fix**   |
| high       | valid    | ≥ 50       | **Auto-fix**   |
| high       | likely   | ≥ 50       | **Auto-fix**   |
| high       | disputed | any        | **Discuss**    |
| medium     | valid    | ≥ 50       | **Auto-fix**   |
| medium     | likely   | ≥ 50       | **Auto-fix**   |
| medium     | disputed | any        | **Discuss**    |
| low        | valid    | ≥ 75       | **Auto-fix**   |
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

## 4. Present the plan and auto-apply

Print the plan as a table, in severity order:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Review-loop triage — <N> findings (iteration <I>)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 # │ sev      │ action       │ title
───┼──────────┼──────────────┼────────────────────────
 1 │ critical │ auto-fix     │ Off-by-one in batch loop
 2 │ high     │ auto-fix     │ Missing auth check on /admin
 3 │ medium   │ auto-fix     │ Add retry on transient errors
 4 │ medium   │ DISCUSS      │ Lock contention in hot path
 5 │ nit      │ auto-dismiss │ Rename variable for clarity

Full details: <path to review.md>
```

**Auto-fix and auto-dismiss findings proceed immediately — no user input.**

For **discuss** findings only, use `AskUserQuestion`:

```
Q: [#N] <title> — sev <severity>. Reviewers disagree — what should I do?
   options:
     • "Fix now" (Recommended) — implement the fix in this session
     • "Dismiss" — drop it, not a real issue
     • "Defer" — too large for this PR, will stack separately
     • "Show me the details" — read the full finding first
```

If the user picks "Show me the details", present the finding
conversationally and re-ask without that option.

After resolving discuss items, print the consolidated plan:

```
Plan:
  Fix now (4):     #1, #2, #3, #4
  Dismiss (1):     #5
```

## 5. Fix-now loop

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
4. Proceed to step 6 (re-review).

## 6. Re-review loop

After CI passes, re-run cross-review to catch issues introduced by the
fixes. This is the core of the automatic loop.

**CRITICAL: The re-review is NOT optional.** After fixing findings, you
MUST re-run cross-review at least once. Do not skip it because the fixes
"looked straightforward" or "were simple." The entire point of this loop
is to catch issues introduced by fixes — you cannot know whether fixes
introduced new issues without re-reviewing. Only the cross-review
determines when the loop is done, not your judgment.

1. Invoke the `cross-review` skill again — the **full** skill with all
   three reviewers and the aggregator, not a single-agent shortcut.
   Cross-review will diff the current state (with fixes applied) against
   `gt parent`, so it reviews the full PR including the new changes.
   The cross-review skill writes its output to a new timestamped
   `$out_dir`. After it finishes, **copy its `review.md` into the
   original review directory** as `review-iter{N}.md` so the full audit
   trail lives in one place:
   ```bash
   cp "$new_out_dir/review.md" "$out_dir/review-iter${iteration}.md"
   ```
2. If cross-review returns **no findings**: the loop is done. Print
   "Re-review clean — no new findings" and proceed to step 7 (defer) or
   step 8 (summarize).
3. If cross-review returns findings:
   - **Filter out findings already addressed** in a previous iteration.
     Compare by file + line range + issue description. If a finding is
     substantively the same as one already fixed or dismissed, skip it.
   - If **no new findings remain** after filtering: the loop is done.
   - If **new findings remain**: increment the review iteration counter,
     loop back to step 3 (triage) with only the new findings.

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

## 7. Defer-to-Linear loop (only if user explicitly deferred findings)

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
     - Finding category: <correctness | security | convention | …>
     - Severity: <severity>
     - Found during cross-review of branch `<branch>` (commit `<sha>`)

     ## Proposed fix

     <recommended_fix from the finding>

     ## Aggregator opinion

     <aggregator_opinion from the review>

     ---

     Deferred from review `<path to review.md>`.
     ```

2. **Choose metadata**: priority by severity (critical → urgent, high →
   high, medium → medium, low → low, nit → low). Labels: prefer `bug`
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
       • "Create"    (Recommended)
       • "Edit"      — tell me what to change
       • "Skip"      — don't create this one
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

## 8. Summarize

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

## Failure modes

- **cross-review fails entirely (all reviewers error):** stop immediately,
  tell the user, don't proceed to triage.
- **cross-review returns no findings:** print "No findings" and exit the
  command successfully — nothing to loop over.
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

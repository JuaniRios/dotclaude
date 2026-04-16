---
allowed-tools: Bash(gt:*), Bash(git:*), Bash(gh:*), Bash(codex:*), Bash(gemini:*), Bash(linear:*), Bash(mkdir:*), Bash(cat:*), Bash(mktemp:*), Bash(rm:*), Bash(test:*), Bash(grep:*), Read, Write, Edit, Agent, Skill, AskUserQuestion
description: Cross-review the current branch, turn the findings into a triage plan, and loop through them with user approval — fixing in place, deferring to Linear, or dismissing. For your own work, not someone else's PR.
---

Run a full self-review loop on the current branch: cross-review → triage →
address. Use this right before you `gt submit` something you wrote yourself,
to catch issues before reviewers do.

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

For each remaining finding, compute a **default recommendation** based on
severity, validity, and confidence:

| Severity   | Validity | Confidence | Default action |
| ---------- | -------- | ---------- | -------------- |
| critical   | valid    | ≥ 75       | **Fix now**    |
| critical   | any      | < 75       | **Fix now** (critical is critical — verify first) |
| high       | valid    | ≥ 75       | **Fix now**    |
| high       | likely   | ≥ 50       | **Fix now**    |
| high       | disputed | any        | **Discuss**    |
| medium     | valid    | ≥ 75       | **Fix now**    |
| medium     | valid    | < 75       | **Defer to Linear** |
| medium     | likely   | any        | **Defer to Linear** |
| medium     | disputed | any        | **Discuss**    |
| low        | any      | any        | **Defer to Linear** |
| nit        | any      | any        | **Dismiss**    |

The "Discuss" action means: show the user and ask what to do, with no
default. This table is a starting point, not a mandate — the user has the
final say.

## 4. Present the plan and collect decisions

Print the plan as a table, in severity order:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Review-loop triage — <N> findings
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 # │ sev      │ default    │ title
───┼──────────┼────────────┼────────────────────────
 1 │ critical │ fix-now    │ Off-by-one in batch loop
 2 │ high     │ fix-now    │ Missing auth check on /admin
 3 │ medium   │ defer      │ Add retry on transient errors
 4 │ medium   │ discuss    │ Lock contention in hot path
 5 │ low      │ defer      │ Cleanup duplicated helper
 6 │ nit      │ dismiss    │ Rename variable for clarity

Full details: <path to review.md>
```

Then use the `AskUserQuestion` tool to collect a decision per finding. **One
question per finding.** Use `multiSelect: false`, options tailored to the
default:

- For a fix-now default:

  ```
  Q: [#N] <title> — sev <severity>. What should I do?
     options:
       • "Fix now" (Recommended) — implement the recommended fix in this session
       • "Defer to Linear" — draft a Linear issue to fix later
       • "Dismiss" — I don't agree, drop it
       • "Show me the details" — read the full finding and aggregator opinion
  ```

- For a defer default:

  ```
  Q: [#N] <title> — sev <severity>. What should I do?
     options:
       • "Defer to Linear" (Recommended) — draft a Linear issue to fix later
       • "Fix now" — implement in this session
       • "Dismiss" — drop it
       • "Show me the details" — read the full finding
  ```

- For a discuss default:

  ```
  Q: [#N] <title> — sev <severity>. I'm not sure — what should I do?
     options:
       • "Show me the details" (Recommended) — walk me through the finding
       • "Fix now"
       • "Defer to Linear"
       • "Dismiss"
  ```

- For a dismiss default:

  ```
  Q: [#N] <title> — sev <severity>. Default is to drop it — confirm?
     options:
       • "Dismiss" (Recommended)
       • "Fix now"
       • "Defer to Linear"
  ```

Ask multiple questions in a **single `AskUserQuestion` call** when you have
up to four findings (the tool accepts 1–4 questions per call). For more
findings, batch them in groups of four.

If the user picks **"Show me the details"**, read the finding's full text
from `review.md` (issue, why it matters, recommended fix, aggregator
opinion), present it conversationally, then re-ask the question without
the "Show me the details" option.

After collecting decisions, print a consolidated list:

```
Plan:
  Fix now (3):   #1, #2, #4
  Defer (2):     #3, #5
  Dismiss (1):   #6
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

1. Run the project's fast verification command if you know it from
   `CLAUDE.md`/`AGENTS.md` (e.g., `cargo check -p <crate>`). If you don't
   know it, ask the user.
2. Report results. If something broke, fix it; do not leave red tests.
3. **Do not commit or `gt modify` automatically.** Tell the user what you
   changed and let them decide whether to amend.

## 6. Defer-to-Linear loop

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

## 7. Summarize

After all fix-now fixes are applied and all defer-to-Linear issues are
created (or skipped), print a final summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Review loop complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Fixed in this session (3):
  #1  critical  Off-by-one in batch loop               <file>:<line>
  #2  high      Missing auth check on /admin            <file>:<line>
  #4  medium    Lock contention in hot path             <file>:<line>

Deferred to Linear (2):
  #3  medium    Add retry on transient errors           <linear url>
  #5  low       Cleanup duplicated helper               <linear url>

Dismissed (1):
  #6  nit       Rename variable for clarity

Report: <path to review.md>
```

Then stop. Do not auto-run `gt modify`, `gt submit`, or any other
mutation — the user decides when to amend and push.

## Failure modes

- **cross-review fails entirely (all reviewers error):** stop immediately,
  tell the user, don't proceed to triage.
- **cross-review returns no findings:** print "No findings" and exit the
  command successfully — nothing to loop over.
- **A fix-now fix turns out to be larger than expected:** stop, report
  progress, ask whether to continue, defer, or dismiss. Don't half-finish.
- **A Linear issue fails to create:** report the exact `linear` error,
  leave the draft tempfile in place, and continue with the rest of the
  deferred items. Ask the user whether to retry the failed one at the end.
- **The user says "stop" mid-loop:** immediately stop, then print the
  summary with what was completed so far. Do not silently abandon the rest.

## Hard rules

1. Never create Linear issues without explicit per-issue user confirmation
   of the exact draft content.
2. Never amend, commit, or `gt submit` automatically — the user drives
   version control.
3. Always use `--description-file` with `linear issue create`, never inline
   `--description`.
4. Always re-verify findings against the current source before applying
   fixes — the code may have changed since the review.
5. Keep fixes surgical. No "while I'm here" cleanups.
6. After all fixes, run the project's fast verification command and report
   results before stopping.

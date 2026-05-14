---
allowed-tools: Bash(cargo:*), Bash(git:*), Bash(gt:*), Bash(grep:*), Bash(test:*), Read, Edit, Grep, Glob, Skill
description: Resolve merge conflicts after a graphite restack. Examines conflicts, fixes obvious ones, reports ambiguous ones.
---

# Fix merge conflicts after restack

Resolve merge conflicts left by `gt restack` or `gt sync`.

## Step 1 — Load graphite skill

Invoke the `graphite` skill so all `gt` conventions are in scope.

## Step 2 — Identify conflicted files

Run `git status` and collect files with conflict markers (`UU`, `AA`, etc.).

## Step 3 — Analyze each conflict

For each conflicted file, read it and find all conflict regions
(`<<<<<<<` / `=======` / `>>>>>>>`). Classify each region:

- **Both sides add independent code** (new fields, functions, imports) →
  keep both. This is the most common case after restack.
- **One side is a strict superset** (e.g., one branch renamed something,
  the other didn't touch it) → take the superset.
- **Both sides modify the same code differently** (true semantic conflict) →
  flag as ambiguous, do not guess.

## Step 4 — Fix obvious conflicts

Edit files to resolve, removing all conflict markers. Ensure the merged
result is syntactically valid and includes all additions from both sides.

## Step 5 — Verify

Run `cargo check -p <relevant-crate>` after fixing. If it fails, diagnose
and fix. Also run with `--all-features` to catch `cfg`-gated paths.

## Step 6 — Stage resolved files

`git add <file>` for each resolved file.

## Step 7 — Report

Tell the user:
- Which files were resolved and how
- Which conflicts (if any) are ambiguous and need manual review
- Whether `cargo check` passed
- Remind them to run `gt continue` when satisfied

## Hard rules

1. Use `gt continue` / `gt abort` — NEVER `git rebase --continue/--abort`.
2. Do NOT guess at semantic conflicts — if both sides change the same logic
   differently, stop and ask.
3. Do NOT delete code from either side unless clearly superseded.
4. Always verify with `cargo check` after resolving.
5. Do NOT run `gt continue` yourself — let the user do it after reviewing.

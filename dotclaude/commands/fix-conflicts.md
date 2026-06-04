---
allowed-tools: Bash(cargo:*), Bash(git:*), Bash(gt:*), Bash(grep:*), Bash(test:*), Read, Edit, Grep, Glob, Skill
description: Resolve graphite restack/sync conflicts and drive the whole stack to clean — auto gt continue through each branch, then gt restack + gt sync, looping until clean or a human decision is needed.
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

## Step 5 — Verify (compile + lint, defer tests)

After fixing a branch's conflicts, verify before continuing:

1. `cargo check -p <relevant-crate> --all-features` — the fast compile gate.
   This MUST pass before `gt continue`. `--all-features` catches `cfg`-gated
   paths. If it fails, diagnose and fix.
2. `cargo clippy -p <relevant-crate> --all-features` — catch lint regressions
   the merge introduced, and fix them on the branch you're currently on (you're
   already checked out there, so it's the cheapest place to fix).

Both `cargo check` and `cargo clippy` already parallelize across all CPU cores
by default — no flag needed to "use multiple cores." Scope with
`-p <relevant-crate>` during iteration to keep each pass fast; reserve
`--workspace` for a final confirmation.

**Defer the test suite.** Do NOT run `cargo nextest` / `cargo test` during the
conflict loop — it is slow and the merge mechanics are validated by compile +
clippy. Leave tests to CI (or a single explicit final run only if the user asks
at hand-off).

## Step 6 — Stage resolved files

`git add <file>` for each resolved file.

## Step 7 — Verify, stage, and drive the stack forward

This command **drives the whole restack/sync to completion** — it does not stop
after one branch. After resolving every conflict at the current stopping point:

1. **Verify** (Step 5): run `cargo check` then `cargo clippy` (both
   `--all-features`, scoped with `-p`). NEVER run `gt continue` on code that
   does not compile — fix it first. Do NOT run the test suite here.
2. **Stage** (Step 6): `git add` every resolved file.
3. **Continue**: run `gt continue` to resume the interrupted operation.
4. **Inspect the outcome and loop:**
   - **More conflicts** (the next branch in the stack stopped): go back to
     Step 2 and resolve them, then `gt continue` again. Repeat for every
     branch until the operation completes.
   - **Operation finished** (no conflicts remain): proceed to Step 8.
   - **A genuine semantic conflict you cannot safely resolve** (hard rule #2):
     STOP. Do not run `gt continue`. Report the ambiguous conflict and ask the
     user how to resolve it; resume the loop only after they decide.

Print a one-line progress note as each branch clears
(e.g. `"Resolved <branch>, continuing -> <next branch>"`).

## Step 8 — Restack, sync, and re-loop

Once the interrupted operation completes with no remaining conflicts:

1. Run `gt restack` to re-parent the whole stack onto the latest commits.
2. Run `gt sync` to fetch trunk and rebase the stack on top.
   - `gt sync` may prompt to delete merged branches — deleting a branch is a
     human decision, so do not blindly confirm; surface the prompt to the user.
3. **If `gt restack` or `gt sync` surfaces new conflicts:** go back to Step 2
   and resolve them (the full Step 7 loop applies again).
4. **If both complete with no conflicts and no changes:** the stack is clean —
   go to Step 9.

## Step 9 — Final report

When the stack is fully resolved, restacked, and synced clean, tell the user:
- Every branch that had conflicts and how each was resolved
- Any conflicts that required a human decision (and what was decided)
- Confirmation that `cargo check` + `cargo clippy` passed and `gt restack` +
  `gt sync` are clean (tests were deferred to CI — say so)

### Stopping conditions (when the loop ends)

- **Clean:** `gt restack` and `gt sync` produce no conflicts and no changes.
- **Human decision needed:** a true semantic conflict (hard rule #2), or a
  `gt sync` branch-deletion prompt — stop and ask, then resume after they
  decide.
- **No progress:** if the same conflict reappears or you loop without
  advancing, stop and ask rather than looping forever.

## Hard rules

1. Use `gt continue` / `gt abort` — NEVER `git rebase --continue/--abort`.
2. Do NOT guess at semantic conflicts — if both sides change the same logic
   differently, STOP and ask the user. Never `gt continue` past a conflict you
   resolved by guessing.
3. Do NOT delete code from either side unless clearly superseded.
4. Always verify with `cargo check` (compile gate) AND `cargo clippy` (lints)
   BEFORE running `gt continue` — never continue on code that does not compile.
   Defer the test suite: do NOT run `cargo nextest` / `cargo test` in the loop;
   leave it to CI.
5. **Drive the stack to completion:** after resolving and verifying, run
   `gt continue` yourself and keep looping (resolve -> verify -> stage ->
   continue) until the whole stack is applied, then `gt restack` + `gt sync`,
   re-looping until clean. Only stop for a human decision (a semantic conflict
   or a `gt sync` prompt) or when you stop making progress.

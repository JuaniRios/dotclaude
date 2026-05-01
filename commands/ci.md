---
allowed-tools: Bash(nix:*), Bash(cargo:*), Bash(git:*), Bash(gt:*), Bash(mktemp:*), Bash(rm:*), Bash(cat:*), Bash(grep:*), Bash(tail:*), Bash(wc:*), Bash(test:*), Read, Edit, Write, Grep, Glob, TodoWrite
description: Run the repo's `nix run .#ci` task and fix every issue it reports, iterating until the task passes clean. Final verification only — run after substantive work is done.
argument-hint: "[upstack]"
---

Run the project's `ci` nix flake task and fix every issue it reports. Loop
until `nix run .#ci` exits zero.

## Upstack mode

When invoked as `/ci upstack`, run CI on the **entire upstack** — the
current branch and every branch above it in the Graphite stack.

### Upstack flow

1. Record the starting branch: `git branch --show-current`.
2. Run the normal `/ci` flow (sections 1–8 below) on the current branch.
3. If CI passes (or was already clean), attempt to move up:
   ```bash
   gt up
   ```
   - If `gt up` succeeds (exits 0 and the branch changed), you're on the
     next branch in the stack. Print:
     `"Moving up stack → <new branch name>"` and repeat from step 2.
   - If `gt up` fails or the branch didn't change, you've reached the top
     of the stack. Print:
     `"✓ Reached top of stack. CI passed on all branches."` and stop.
4. If CI **fails to converge** on any branch (hits the iteration cap),
   stop on that branch. Do NOT continue up the stack — report which
   branch is stuck and follow the normal failure-to-converge flow
   (section 8).
5. When done (success or failure), print a summary of all branches
   visited and their CI result:
   ```
   Upstack CI summary:
     branch-a: ✓ clean
     branch-b: ✓ clean (fixed 2 issues)
     branch-c: ✗ stuck (clippy lint — see above)
   ```

**Hard rule for upstack mode**: Never commit, amend, or push on any
branch — the user drives version control. Fixes are left as uncommitted
changes on whichever branch they belong to.

This command is the **final verification pass**. Run it when you believe your
work is done. It covers the full workspace (`cargo check`, `cargo clippy`,
`cargo nextest`, `cargo fmt --check` — whatever the flake's `ci` task wraps).

## 1. Preflight

**Always use `nix run .#ci`** — never decompose it into individual cargo
commands, even when already inside a nix dev shell. The flake task is the
single source of truth for what CI runs and in what order.

### Verify the flake exposes a `ci` task

```bash
nix eval .#ci --apply 'x: "ok"' 2>/dev/null || nix flake show --json 2>/dev/null | grep -q '"ci"'
```

If `ci` doesn't exist in this flake:
- Fall back to reading `flake.nix` to see what tasks *do* exist.
- Tell the user: "`nix run .#ci` is not defined in this flake. Available tasks: <list>. Which one should I run, or should I use `cargo check + clippy + nextest + fmt` directly?"
- Wait for their direction. Do not guess.

If the working tree is dirty, print a `git status --short` summary so the user
knows their uncommitted work is in play. Do not stash or clean — the user may
be actively working.

## 2. Initialize the fix loop

Create a TodoWrite list with:

1. "Run `nix run .#ci`" — in_progress
2. "Fix issues from iteration 1" — pending
3. "Re-run `nix run .#ci` to confirm clean" — pending

Set a max iteration cap of **8**. Track iteration count. If you hit the cap
without convergence, stop and ask the user — you are probably fighting
yourself and need a human to untangle it.

## 3. Run the task

```bash
log=$(mktemp -t ci-run.XXXXXX.log)
nix run .#ci 2>&1 | tee "$log"
exit_code=${PIPESTATUS[0]}
```

Use a long timeout (`timeout: 600000` — 10 minutes minimum). Some of these
runs take a while.

If `exit_code == 0`:
- Print "✓ `nix run .#ci` passed clean" and the tail of the log.
- Mark all todos complete.
- Delete the tempfile.
- Stop. Do not commit, do not push, do not run anything else. The user
  drives version control.

If `exit_code != 0`:
- Read the full log. Do not truncate — errors often scroll past the visible
  tail, especially when multiple cargo steps fail in sequence.
- Proceed to step 4.

## 4. Parse the failure

The failure came from one of the steps in the flake's `ci` task. For the
standard st0x-style ci task, that's (in order):

1. `cargo check --workspace`
2. `cargo check --workspace --all-features`
3. `cargo nextest run --workspace --all-features`
4. `cargo clippy --workspace --all-targets --all-features`
5. `cargo fmt -- --check`

Identify which step failed first. `set -euxo pipefail` in the task means the
first non-zero exit stops everything, so there's exactly one "primary" step
per iteration — plus any collateral failures that only surface once the
primary is fixed.

Extract the concrete errors. For each error, record:

- **Category**: compile error | test failure | clippy lint | formatting | missing feature | unresolved import | other
- **File and line(s)** when present
- **Error message** verbatim
- **Likely cause** (your best read)

Update the todo list: replace "Fix issues from iteration 1" with one todo per
distinct failure, each specific ("Fix `E0277 Send bound missing` in
`src/foo.rs:142`" — not "fix clippy").

## 5. Fix the issues

Apply fixes one at a time, in this order:

1. **Compile errors first** (`cargo check`). Nothing else matters until the
   workspace compiles.
2. **Feature-gated compile errors** next (`cargo check --all-features`).
   These usually mean a feature gate is missing or a cfg is wrong.
3. **Test failures** (`cargo nextest`). Fix the code, not the assertion,
   unless the test is asserting the wrong thing.
4. **Clippy lints** last among "real" fixes. Often reveal design issues —
   address the design, not the symptom.
5. **Formatting** — let `cargo fmt` (not `--check`) do the work:

   ```bash
   cargo fmt
   ```

   Never hand-edit whitespace to appease `fmt --check`.

### Rules for fixes

Load the project conventions first:

```bash
find . -maxdepth 3 \( -name "CLAUDE.md" -o -name "AGENTS.md" \) \
  -not -path "*/node_modules/*" -not -path "*/target/*"
```

Read those files. They dictate what's allowed. Common rules the user's
projects enforce (inferred from their st0x.liquidity AGENTS.md, but check
the actual files you find):

- **Never suppress a lint without explicit user permission.** Do not add
  `#[allow(clippy::*)]`, `#[allow(dead_code)]`, `#[allow(deprecated)]`, etc.
  If clippy flags something, fix the design — break up the function, improve
  the types, handle the error properly. If you genuinely cannot fix it, stop
  and ask the user for permission to suppress, explaining why.
- **Never delete, skip, or disable tests.** If a test is failing, fix the
  code or fix the assertion (if and only if the assertion was wrong). If you
  think a test is fundamentally obsolete, stop and ask.
- **Never `.unwrap()` / `.expect()` in production code.** Use proper error
  handling with `#[from]` + `?`. Exception: test code.
- **Never create error variants with `String` values** (e.g., `Error(String)`)
  or `.to_string()` conversions. Preserve typed error chains.
- **Never silently early-return.** Log a warning/error before `let-else`
  returns and similar guard patterns.
- **Stick to the three-group import pattern**: external → workspace → crate.
  No function-level imports.
- **No one-liner helpers.** Inline single-expression helpers.
- **ASCII in code and comments**, unicode only in user-facing strings.
- **No single-letter variables** except short closures with obvious types.

If a fix would violate any project rule, **stop and ask the user** — don't
work around the rule. Rules exist for reasons.

### Specific fix patterns

- **Unused imports/variables**: delete the import or use `_` prefix if it's
  a binding you're keeping for a deliberate reason (rare — usually delete).
- **`too_many_lines` clippy**: ask the user for permission to `#[allow]` it
  for trivial state-machine matches. Otherwise refactor.
- **`cognitive_complexity` clippy**: extract focused helpers with clear
  responsibilities. Don't split for the sake of splitting.
- **Broken tests after a refactor**: update the test to match the new
  correct behavior. Never weaken the assertion to make it pass.
- **Feature-gate compile errors**: check if a use site needs the feature
  gate matching its callers. Often `#[cfg(feature = "...")]` is missing
  above an item or an `use` line.
- **`fmt --check` failing**: run `cargo fmt` (without `--check`), done.

### Editing

Use `Edit` for surgical changes. Use `Write` only for new files or complete
rewrites. Never touch files unrelated to the current failure — no drive-by
cleanups.

After applying fixes, mark the relevant todo items complete and move to
step 6.

## 6. Re-run the task

Re-run CI with a fresh log file:

```bash
log=$(mktemp -t ci-run.XXXXXX.log)
nix run .#ci 2>&1 | tee "$log"
exit_code=${PIPESTATUS[0]}
```

If `exit_code == 0`:
- Same success path as step 3.

If `exit_code != 0`:
- Increment iteration count.
- If iteration count ≥ 8, stop and ask the user. Summarize:
  - What you've fixed so far.
  - What keeps failing.
  - Your best theory on why you're stuck.
- Otherwise, loop back to step 4 with the new log.

**Important**: on each re-run, diff the failures against the previous
iteration. If the same error persists unchanged, your fix didn't work —
understand why before trying again. If the error *changed* (different
file/line/message), that's progress, keep going. If a new error appeared
that didn't exist before, your fix introduced a regression — back up
and try a different approach.

## 7. On success

When `nix run .#ci` passes:

1. Run a quick self-check: print a summary of every file you modified in
   this command's fix loop.
2. Print the tail of the final (successful) log as proof.
3. Delete the tempfiles.
4. Tell the user: "`nix run .#ci` is clean across <N> iterations. I
   modified <M> files. Let me know if you want me to amend / commit / push
   via `gt` — I won't do that automatically."
5. Stop.

## 8. On failure to converge

If you hit the iteration cap or realize you're chasing your own tail:

1. Stop running `nix run .#ci`.
2. Print the latest failure's key errors (not the full log — just the
   critical lines).
3. Print a list of fixes you attempted per iteration and what each one
   changed.
4. Give your honest best theory of why you're stuck.
5. Ask the user whether to:
   - Try a specific different approach (they direct).
   - Roll back the fix attempts (they direct how — `git restore` / `gt undo` / etc.).
   - Accept a narrower scope (e.g., fix compile errors only, leave lints).

Do not keep looping silently.

## Failure modes

- **`nix run .#ci` takes >10 min**: increase the bash timeout to 20 or 30
  min. Don't kill the run — partial state makes debugging harder.
- **The first run fails because of environment issues** (missing tools,
  network, nix cache): report it, stop, and tell the user — these are not
  fixable by code edits.
- **Tests fail flakily** (pass on re-run without changes): flag it
  explicitly ("test X failed on iteration 3, passed on iteration 4 with no
  changes — likely flaky"). Do not mark the command done without the user
  acknowledging.
- **A `sqlx` database error** (e.g., "unable to open database file"):
  project docs usually say to run `sqlx db reset -y`. Check the project
  docs and run whatever recovery command they prescribe before calling
  the fix impossible.

## Hard rules

1. Never suppress a lint (`#[allow(...)]`, `#![allow(...)]`) without
   explicit user permission.
2. Never delete, skip, or `#[ignore]` a test to make CI pass.
3. Never commit, amend, or push — the user drives version control.
4. Never make unrelated changes while fixing — no drive-by cleanups.
5. Never hand-edit whitespace; run `cargo fmt` for formatting.
6. Cap at 8 iterations; stop and ask the user if you don't converge.
7. Read the project's `CLAUDE.md` / `AGENTS.md` before applying fixes
   and respect its rules.
8. If an environment-level failure is the cause (missing tools, db state,
   network), stop and tell the user — don't try to patch code around it.

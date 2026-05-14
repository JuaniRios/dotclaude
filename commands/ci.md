---
allowed-tools: Bash(nix:*), Bash(cargo:*), Bash(git:*), Bash(gt:*), Bash(mktemp:*), Bash(rm:*), Bash(cat:*), Bash(grep:*), Bash(tail:*), Bash(wc:*), Bash(test:*), Bash(cd:*), Bash(bun:*), Bash(nixfmt:*), Bash(find:*), Read, Edit, Write, Grep, Glob, TodoWrite
description: Run CI steps individually (check, test, clippy, fmt, dashboard) and fix every issue, iterating until all pass clean. Final verification only — run after substantive work is done.
argument-hint: "[upstack]"
---

Run the project's CI steps individually and fix every issue they report.
Loop until all steps pass.

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
work is done. It covers the full workspace: cargo check, nextest, clippy,
fmt, and dashboard lint/check — each as individual steps.

## 1. Preflight

### Why individual steps, not `nix run .#ci`

**CRITICAL: Do NOT call `nix run .#ci` as a single monolithic command.**
The flake's CI task runs all steps in one shell with `set -euxo pipefail`,
which means:
- If step 3 (tests) fails, you must re-run steps 1-2 (check) again on
  the next iteration even though they already passed.
- A full CI run takes 10+ minutes; re-running passed steps wastes time.
- If something holds a cargo build directory lock, the entire run blocks.

Instead, run each CI step as a **separate command** via
`nix develop .#ci-backend -c <command>`. This way:
- When a step fails, fix the issue and re-run **only that step**.
- Once a step passes, skip it on subsequent iterations.
- No wasted time re-running passed steps.

### Verify the ci-backend dev shell exists

```bash
nix eval .#devShells.$(nix eval --impure --expr builtins.currentSystem --raw).ci-backend --apply 'x: "ok"' 2>/dev/null
```

If it doesn't exist, fall back to reading `flake.nix` to find the correct
dev shell name. Ask the user if unclear.

If the working tree is dirty, print a `git status --short` summary so the
user knows their uncommitted work is in play. Do not stash or clean — the
user may be actively working.

## 2. Initialize the fix loop

**CRITICAL: Run all CI commands directly in the main agent context.** Do
NOT delegate CI to a subagent or Agent tool call. The main agent must see
the full output, fix issues, and re-run — delegating loses context and
forces redundant work.

The CI pipeline has these steps in two parallel tracks:

**Backend track** (sequential — each depends on the prior):

| Step | Command | Shell | Timeout |
|------|---------|-------|---------|
| 1 | `nixfmt --check` on all `*.nix` files | direct | 60s |
| 2 | `cargo check --workspace` | `nix develop .#ci-backend -c` | 600s |
| 3 | `cargo check --workspace --all-features` | `nix develop .#ci-backend -c` | 600s |
| 4 | `cargo nextest run --workspace --all-features` | `nix develop .#ci-backend -c` | 600s |
| 5 | `cargo clippy --workspace --all-targets --all-features` | `nix develop .#ci-backend -c` | 600s |
| 6 | `cargo fmt -- --check` | `nix develop .#ci-backend -c` | 60s |

**Dashboard track** (independent of backend — start alongside step 2):

| Step | Command | Shell | Timeout |
|------|---------|-------|---------|
| 7 | `nix run .#genBunNix` | direct | 120s |
| 8 | `nix fmt -- dashboard/bun.nix` | direct | 60s |
| 9 | `nix run .#st0x-dto -- dashboard/src/lib/api` | direct | 120s |
| 10 | `cd dashboard && bun install --frozen-lockfile && bun run lint && bun run check` | `nix develop .#ci-dashboard -c bash -c` | 300s |

Steps 7, 8, and 9 can run in parallel with each other. Step 10 must wait
for step 9 to complete (it depends on generated DTO bindings).

### Step 1: nixfmt check

This is very fast (~150ms) so it runs first. Find all nix files and check
formatting:

```bash
nixfmt --check $(find . -name '*.nix' -not -path './.tmp/*' -not -path './.direnv/*')
```

If it fails, fix with:

```bash
nixfmt $(find . -name '*.nix' -not -path './.tmp/*' -not -path './.direnv/*')
```

Then re-run the check to confirm. Do not hand-edit nix whitespace.

Track which steps have passed. Set a max fix-loop iteration cap of **8**
per step. If you hit the cap on any step, stop and ask the user.

## 3. Run the steps

### Parallelism strategy

The steps form two independent tracks that can run **in parallel**:

- **Backend track** (steps 1–6): Must be sequential within this track
  because each step depends on the prior one passing (no point running
  tests if check fails).
- **Dashboard track** (steps 7–10): Completely independent of the backend
  track. These can start immediately alongside step 1.

**Execution plan:**

1. Launch **step 1** (nixfmt) — fast, ~150ms, run it first in both tracks.
2. After nixfmt passes, launch **steps 2–6 sequentially** (backend) and
   **steps 7–10 in parallel** (dashboard). Use separate Bash tool calls
   in a single message to run them concurrently.
3. Within the dashboard track, steps 7–9 are independent of each other
   and can run in parallel. Step 10 (bun lint+check) depends on step 9
   (dto codegen) completing first.

**If no fixes are needed** (common case — this is a verification pass),
parallelism cuts wall-clock time roughly in half.

**If fixes are needed**, fix the failing step, re-run only that step, and
continue. Steps that already passed do not need re-running.

### Timeout handling

**CRITICAL: Use `timeout: 600000` (10 minutes) on ALL `nix develop` and
`nix run` commands.** Many steps (nextest, clippy, cargo check) routinely
take 2–10 minutes. The default 120s timeout will cause the Bash tool to
auto-background the command, which breaks the sequential flow and forces
messy polling loops.

```bash
# Example — always set timeout
nix develop .#ci-backend -c cargo check --workspace 2>&1
# ^ with timeout: 600000 on the Bash tool call
```

**NEVER use `run_in_background: true`** for CI steps. The agent needs to
see the output immediately to decide whether to fix or continue. If a
command genuinely takes >10 minutes, increase timeout to `900000` (15 min)
rather than backgrounding it.

### Per-step behavior

**If the step passes (exit 0):**
- Print "✓ Step N passed: `<command>`"
- Move to the next step.

**If the step fails (exit != 0):**
- Read the full output. Do not truncate.
- Proceed to step 4 (parse and fix).
- After fixing, **re-run only the failed step** — do not re-run steps
  that already passed.
- Once the step passes, continue to the next step.

**If all steps pass:**
- Print the summary and stop. Do not commit, push, or run anything else.
  The user drives version control.

## 4. Parse the failure

The failure came from one of the steps in the flake's `ci` task. For the
standard st0x-style ci task, that's (in order):

1. `cargo check --workspace`
2. `cargo check --workspace --all-features`
3. `cargo nextest run --workspace --all-features`
4. `cargo clippy --workspace --all-targets --all-features`
5. `cargo fmt -- --check`
6. `(cd dashboard && bun install && bun run lint && bun run check)`

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
- **Dashboard `bun run lint` failing**: ESLint errors in `dashboard/` —
  read the flagged file, fix the TypeScript/Svelte issue. Common: stringifying
  objects (`@typescript-eslint/no-base-to-string`), unused vars, type errors.
- **Dashboard `bun run check` failing**: `svelte-check` type errors in
  `dashboard/` — fix the TypeScript types in the flagged Svelte components.

### Editing

Use `Edit` for surgical changes. Use `Write` only for new files or complete
rewrites. Never touch files unrelated to the current failure — no drive-by
cleanups.

After applying fixes, mark the relevant todo items complete and move to
step 6.

## 6. Re-run the failed step

After applying fixes, re-run **only the step that failed** — not the
entire pipeline. Steps that already passed do not need to be re-run.

```bash
nix develop .#ci-backend -c cargo clippy --workspace --all-targets --all-features 2>&1
```

If the step passes now, continue to the next step in the pipeline.

If the step still fails:
- Increment the fix-loop iteration count for this step.
- If iteration count >= 8, stop and ask the user. Summarize:
  - What you've fixed so far.
  - What keeps failing.
  - Your best theory on why you're stuck.
- Otherwise, loop back to step 4 with the new output.

**Important**: on each re-run, diff the failures against the previous
iteration. If the same error persists unchanged, your fix didn't work —
understand why before trying again. If the error *changed* (different
file/line/message), that's progress, keep going. If a new error appeared
that didn't exist before, your fix introduced a regression — back up
and try a different approach.

**Exception — when to re-run earlier steps**: If your fix changed code
that could affect compilation (not just formatting or lint suppression),
re-run from `cargo check` forward to catch regressions. Use judgment:
a `cargo fmt` fix never needs a re-check, but adding a new function
parameter does.

## 7. On success

When all steps pass:

1. Run a quick self-check: print a summary of every file you modified in
   this command's fix loop.
2. Print a step-by-step summary:
   ```
   CI passed clean:
     ✓ nixfmt --check
     ✓ cargo check --workspace
     ✓ cargo check --workspace --all-features
     ✓ cargo nextest run --workspace --all-features
     ✓ cargo clippy --workspace --all-targets --all-features
     ✓ cargo fmt -- --check
     ✓ dashboard (lint + check)
   ```
3. Tell the user: "CI is clean. I modified <M> files. Let me know if you
   want me to amend / commit / push via `gt` — I won't do that
   automatically."
4. Stop.

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

- **A step takes >10 min**: increase the Bash `timeout` parameter to
  `900000` (15 min). Don't kill the run — partial state makes debugging
  harder. **Never use `run_in_background`** as a workaround for slow
  commands — increase the timeout instead.
- **The first step fails because of environment issues** (missing tools,
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
- **Build directory lock**: If a cargo command blocks on "waiting for file
  lock on build directory", another cargo process is running. Wait for it
  to finish — do NOT kill processes, as you may kill the wrong one.

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

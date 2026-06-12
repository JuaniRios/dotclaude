---
allowed-tools: Bash(gt:*), Bash(gh:*), Bash(git:*), Bash(cargo:*), Read, Edit, Write, Grep, Glob, Skill, TodoWrite
description: Offload heavy verification to remote CI instead of running it locally — amend, submit, then poll the CI run until it finishes.
---

Switch this session into **remote-checks mode**: stop burning local machine time
on slow, heavy verification and let GitHub CI do it instead. Adopt the policy
below for the rest of the session, then run the submit-and-poll cycle.

## Policy for the rest of this session

**Do NOT run heavy checks locally on this machine.** These are slow here and are
exactly what remote CI exists to run:

- `nix run .#ci` and any full CI matrix
- `cargo nextest run --workspace` / `--all-features` (the full test suite)
- `nix develop .#ci-backend -c ...` heavy invocations, nix builds
- dashboard `bun run check` / lint full passes

**Light local checks are still fine and encouraged** for fast iteration feedback:

- `cargo check -p <crate>`
- `cargo clippy -p <crate>`
- targeted `cargo nextest run <specific_test>` (a single test or module)

Use the light checks while iterating; push the heavy stuff to CI.

## The submit-and-poll cycle

Run this whenever the work is ready for a heavy verification pass.

### 1. Amend and submit

Route all version-control mutations through the `/graphite` skill.

1. Amend the current branch with all working-tree changes: `gt modify -a`
   (amend, not a new stacked fix commit — this is the user's standing
   preference).
2. Submit to trigger remote CI: `gt submit --no-interactive`.

If there is nothing to amend (clean tree) but CI hasn't run on HEAD yet, still
submit so CI runs.

### 2. Find the CI run for this HEAD

CI takes a few seconds to register after the push. Capture the pushed SHA and
locate its run:

```bash
git rev-parse HEAD
gh run list --branch "$(git branch --show-current)" --limit 5 \
  --json databaseId,status,conclusion,headSha,createdAt,name
```

Match the run whose `headSha` equals the pushed HEAD. If none appears yet, check
again once or twice before giving up.

**Graphite caps CI at the first 5 PRs in a stack.** A branch 6th-or-deeper in the
stack gets **no run triggered for its HEAD at all** — `gh run list` will only ever
show stale runs from a different `headSha` (from when the branch sat lower in the
stack). Never accept one of those as "green": it didn't test this code. If no run
with a matching `headSha` appears after ~90s of retries, treat it as
**Graphite-skipped** and fall back to the **full local CI matrix** on this branch
(`nix run .#ci`, or the repo's equivalent) as the verification gate. The poller
below detects this and exits with a distinct code so you can branch on it.

### 3. Poll until it finishes (~10 min)

**Do NOT pin a single `gh run watch <run-id>`.** On a Graphite stack, a re-push
(of this branch or anything downstack) **cancels the in-flight run and spawns a
fresh one**. A frozen run-id would watch the cancelled run, see it exit, and
report `cancelled` as if it were the final result — silently abandoning the real
run. Instead, poll the **newest run on the branch** and follow replacements:
when a watched run ends in `cancelled`, re-discover and follow its successor;
only treat `success`/`failure`/`timed_out` as terminal.

Run this poller in the **background** so you can keep working while CI runs — the
harness re-invokes you when it exits. Write it to a temp file and launch with
`run_in_background: true`:

```bash
cat > /tmp/ci-poll.sh <<'EOF'
#!/usr/bin/env bash
# Follows the newest run on the branch; survives cancel-and-restart
# (stack re-push superseding a run). Only accepts a run whose headSha matches
# the pushed HEAD, so a stale run from a different commit never reads as green.
# Exits: 0 success, 1 failure/cancelled, 2 no run for HEAD (Graphite-skipped
# deep-stack branch -> caller runs full local CI instead).
set -uo pipefail
BRANCH="$(git branch --show-current)"
EXPECTED_SHA="$(git rev-parse HEAD)"
cancel_retries=0
no_run_retries=0
newest_run() {
  gh run list --branch "$BRANCH" --limit 1 \
    --json databaseId,status,conclusion,headSha,url \
    --jq '.[0] | "\(.databaseId)\t\(.status)\t\(.conclusion)\t\(.headSha)\t\(.url)"'
}
while true; do
  read -r RID STATUS CONCLUSION SHA URL <<<"$(newest_run)"
  # No run, or the newest run is for a different commit than what we pushed:
  # Graphite may not have triggered CI for this HEAD (6th+ in the stack).
  if [[ -z "${RID:-}" || "$SHA" != "$EXPECTED_SHA" ]]; then
    no_run_retries=$((no_run_retries + 1))
    if (( no_run_retries > 9 )); then
      echo "CI_RESULT=no_run_for_head sha=${EXPECTED_SHA:0:8} (Graphite skipped CI; run full local CI as the gate)"; exit 2
    fi
    echo "No CI run for HEAD ${EXPECTED_SHA:0:8} yet (try $no_run_retries/9); retrying..."; sleep 10; continue
  fi
  no_run_retries=0
  if [[ "$STATUS" != "completed" ]]; then
    echo ">> Watching run $RID (sha ${SHA:0:8}, status=$STATUS)"
    echo ">> URL: $URL"
    gh run watch "$RID" --exit-status
    read -r RID STATUS CONCLUSION SHA URL <<<"$(newest_run)"
  fi
  case "$CONCLUSION" in
    success) echo "CI_RESULT=success run=$RID sha=${SHA:0:8} url=$URL"; exit 0 ;;
    cancelled)
      cancel_retries=$((cancel_retries + 1))
      if (( cancel_retries > 12 )); then
        echo "CI_RESULT=cancelled run=$RID sha=${SHA:0:8} url=$URL (no replacement)"; exit 1
      fi
      echo ">> Run $RID cancelled; looking for replacement (try $cancel_retries)..."; sleep 10 ;;
    "") echo ">> Newest run is in progress; following it."; cancel_retries=0 ;;
    *) echo "CI_RESULT=$CONCLUSION run=$RID sha=${SHA:0:8} url=$URL"; exit 1 ;;
  esac
done
EOF
bash /tmp/ci-poll.sh
```

After launching the poller, **immediately fetch and report the run URL to the
user** so they can check status themselves without waiting for you:

```bash
gh run list --branch "$(git branch --show-current)" --limit 1 \
  --json url,databaseId --jq '.[0].url'
```

Tell the user CI is running (~10 min), paste the run URL, and continue with any
remaining light work. (The poller's output file also prints `>> URL: …` and the
final `CI_RESULT=… url=…` line, so the URL is always visible there too.)

### 4. When CI finishes

The poller's final line is `CI_RESULT=<conclusion> run=<id> sha=<sha>`; its exit
code mirrors it (0 = success).

- **Passed** (exit 0 / `CI_RESULT=success`): tell the user CI is green and report
  the run URL. Confirm the reported `sha` matches the current HEAD — if HEAD
  moved while CI ran, resubmit and poll again.
- **Failed** (exit 1 / `CI_RESULT=failure|cancelled|...`): hand off to `/ci-fix`
  to fetch the failed logs, diagnose, and fix locally — then re-run this cycle
  (amend + submit + poll). Repeat until green.
- **No run for HEAD** (exit 2 / `CI_RESULT=no_run_for_head`): Graphite didn't
  trigger CI for this branch (6th-or-deeper in the stack). Remote verification is
  unavailable here, so run the **full local CI matrix** on this branch as the
  gate — `nix run .#ci` (or the repo's documented equivalent). Treat its result
  exactly as you would a remote run: green → done; failures → `/ci-fix` and
  re-run the local matrix until clean. Tell the user this branch was verified
  locally because Graphite skipped its CI.

## Hard rules

1. Never run the full local CI / workspace test suite while in this mode — that
   defeats the purpose. Light per-crate `check`/`clippy` and targeted single
   tests are the only local verification allowed. **Sole exception:** a branch
   Graphite skipped CI on (6th+ in the stack, `CI_RESULT=no_run_for_head`) — then
   the full local matrix is the *only* available gate, so run it.
2. Always amend with `gt modify -a`, never stack a separate fix commit, unless
   the user asks otherwise.
3. Route every git mutation through `/graphite`; never raw `git commit`/`push`.
4. Poll CI in the background — never block the foreground for 10 minutes.
5. Track the newest run on the branch, never a frozen run-id. A stack re-push
   cancels and replaces runs; follow the replacement and only treat
   `success`/`failure`/`timed_out` as terminal — never `cancelled`.
6. On CI failure, fix and resubmit; do not leave the branch red without telling
   the user.

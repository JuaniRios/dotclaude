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
# (stack re-push superseding a run). Exits 0 on success, 1 otherwise.
set -uo pipefail
BRANCH="$(git branch --show-current)"
cancel_retries=0
newest_run() {
  gh run list --branch "$BRANCH" --limit 1 \
    --json databaseId,status,conclusion,headSha,url \
    --jq '.[0] | "\(.databaseId)\t\(.status)\t\(.conclusion)\t\(.headSha)\t\(.url)"'
}
while true; do
  read -r RID STATUS CONCLUSION SHA URL <<<"$(newest_run)"
  if [[ -z "${RID:-}" ]]; then echo "No run yet for $BRANCH; retrying..."; sleep 10; continue; fi
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
- **Failed** (non-zero exit): hand off to `/ci-fix` to fetch the failed logs,
  diagnose, and fix locally — then re-run this cycle (amend + submit + poll).
  Repeat until green.

## Hard rules

1. Never run the full local CI / workspace test suite while in this mode — that
   defeats the purpose. Light per-crate `check`/`clippy` and targeted single
   tests are the only local verification allowed.
2. Always amend with `gt modify -a`, never stack a separate fix commit, unless
   the user asks otherwise.
3. Route every git mutation through `/graphite`; never raw `git commit`/`push`.
4. Poll CI in the background — never block the foreground for 10 minutes.
5. Track the newest run on the branch, never a frozen run-id. A stack re-push
   cancels and replaces runs; follow the replacement and only treat
   `success`/`failure`/`timed_out` as terminal — never `cancelled`.
6. On CI failure, fix and resubmit; do not leave the branch red without telling
   the user.

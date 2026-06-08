#!/usr/bin/env bash
# Stop hook: keep a session working toward a directory-scoped goal.
#
# Reads the Stop-hook JSON from stdin. If an active goal state file exists for
# the session's cwd, blocks stopping and returns the goal condition as the
# continuation directive, incrementing a turn counter. Releases (allows stop)
# when the goal file is gone, the turn cap is exceeded, or the state is corrupt.
# Any session without a goal file falls straight through to a normal stop.
#
# Intentionally keeps blocking across turns (a goal loop must) rather than
# honoring stop_hook_active's "block once" convention. The runaway guard is the
# explicit max_turns counter, not that flag.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./goal-lib.sh
. "${here}/goal-lib.sh"

# Degrade to a normal stop if jq is unavailable rather than erroring the hook.
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] || exit 0

state_file="$(goal_state_file "$cwd")"
[ -f "$state_file" ] || exit 0

# Silence jq stderr: corrupt state should degrade to a clean stop, not noise.
condition="$(jq -r '.condition // empty' "$state_file" 2>/dev/null)"
max_turns="$(jq -r '.max_turns // 0' "$state_file" 2>/dev/null)"
turns="$(jq -r '.turns // 0' "$state_file" 2>/dev/null)"

# Non-numeric turn/cap (corrupt) -> treat as empty so we clear and allow stop.
case "$max_turns" in '' | *[!0-9]*) max_turns=0 ;; esac
case "$turns" in '' | *[!0-9]*) turns=0 ;; esac

# Corrupt/empty state -> clear it and allow stop rather than loop on garbage.
if [ -z "$condition" ]; then
  rm -f "$state_file"
  exit 0
fi

turns=$((turns + 1))

# Runaway guard: past the cap, clear the goal and allow the stop.
if [ "$max_turns" -gt 0 ] && [ "$turns" -gt "$max_turns" ]; then
  rm -f "$state_file"
  exit 0
fi

# Persist the incremented turn count.
tmp="$(mktemp)"
jq --argjson turns "$turns" '.turns = $turns' "$state_file" > "$tmp" && mv "$tmp" "$state_file"

reason="$(cat <<EOF
<objective>
${condition}
</objective>

Keep working toward this objective without asking the user anything (goal loop, turn ${turns}/${max_turns}). Surface verification (test/check output) in your turns so progress is visible across the loop.

When the objective is fully met, release the loop by clearing the goal:
  ${here}/goal-clear.sh
If you are genuinely blocked, state the blocker plainly, clear the goal, and stop.
EOF
)"

jq -n --arg reason "$reason" '{decision:"block", reason:$reason}'
exit 0

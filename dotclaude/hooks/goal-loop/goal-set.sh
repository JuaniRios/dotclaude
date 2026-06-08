#!/usr/bin/env bash
# Arm a directory-scoped goal for the current working directory.
#
# Usage: goal-set.sh "<condition>" <max_turns>
#
# Writes the goal state file for cwd. The Stop hook (check-goal.sh) then blocks
# stopping and re-feeds the condition each turn until the goal is cleared or the
# turn cap is exceeded. Replaces any existing goal for this directory.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./goal-lib.sh
. "${here}/goal-lib.sh"

condition="${1:?usage: goal-set.sh \"<condition>\" <max_turns>}"
max_turns="${2:?usage: goal-set.sh \"<condition>\" <max_turns>}"

case "$max_turns" in
  '' | *[!0-9]*) echo "max_turns must be a positive integer" >&2; exit 1 ;;
esac

cwd="$(pwd)"
state_file="$(goal_state_file "$cwd")"
mkdir -p "$(goal_state_dir)"

jq -n --arg cwd "$cwd" --arg condition "$condition" --argjson max_turns "$max_turns" \
  '{cwd: $cwd, condition: $condition, max_turns: $max_turns, turns: 0}' > "$state_file"

echo "Goal armed for ${cwd}"
echo "  condition: ${condition}"
echo "  max_turns: ${max_turns}"
echo "  state:     ${state_file}"

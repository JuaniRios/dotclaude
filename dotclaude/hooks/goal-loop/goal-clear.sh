#!/usr/bin/env bash
# Clear the directory-scoped goal, releasing the Stop-hook loop.
#
# Usage: goal-clear.sh [cwd]   (defaults to the current working directory)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./goal-lib.sh
. "${here}/goal-lib.sh"

cwd="${1:-$(pwd)}"
state_file="$(goal_state_file "$cwd")"

if [ -f "$state_file" ]; then
  rm -f "$state_file"
  echo "Goal cleared for ${cwd}"
else
  echo "No active goal for ${cwd}"
fi

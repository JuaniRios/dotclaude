# shellcheck shell=bash
# Shared helpers for the skill-driven goal loop (sourced, not executed).
#
# A "goal" is a JSON state file scoped to a working directory. While the file
# exists, the Stop hook (check-goal.sh) blocks the session from stopping and
# feeds the stored condition back as the next-turn directive. Removing the file
# releases the loop. Scoping by cwd lets the setter (a running skill) and the
# reader (the Stop hook) agree on the same file without knowing the session id,
# which a running agent cannot observe.

goal_state_dir() {
  printf '%s/.claude/goal-loop/state' "$HOME"
}

# Deterministic per-directory key so setter and reader resolve the same file.
goal_state_file() {
  cwd="$1"
  key="$(printf '%s' "$cwd" | shasum | cut -d' ' -f1)"
  printf '%s/%s.json' "$(goal_state_dir)" "$key"
}

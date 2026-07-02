---
allowed-tools: Bash(git:*), Bash(date:*), Bash(basename:*), Bash(pwd:*), Read, Write
description: Write a compact session-handoff summary to a temp file so a fresh session (optionally on a different model) can continue the work with zero re-explaining. Invoked as /handoff.
argument-hint: "[focus instructions]"
---

# Session handoff

Produce a dense, high-signal handoff document at a temp file that a **fresh
Claude session** -- possibly on a different model -- can read to pick up exactly
where this one left off, without inheriting this session's token bloat.

The output is written for an *agent*, not a human report: terse, structured,
scannable, and built from **pointers (path:line, symbols, IDs), not payloads
(pasted code, diffs, logs)**.

If `$ARGUMENTS` is provided, bias the summary toward that focus (e.g.
`/handoff the auth refactor only`), the way `/compact [instructions]` does.

## Step 1 -- Gather objective context

Run these to ground the summary in fact (distill the output; never paste it raw
into the file):

```bash
repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
name=$(basename "$repo")
stamp=$(date +%Y%m%d-%H%M%S)
git -C "$repo" branch --show-current
git -C "$repo" status --short
git -C "$repo" --no-pager diff --stat
git -C "$repo" --no-pager log --oneline -10
```

Also note any background tasks/processes you started this session and their
state.

## Step 2 -- Synthesize the session

From the conversation above, extract only what a successor needs. Prioritize the
**non-obvious**: decisions and the reasoning behind them, dead-ends already ruled
out, gotchas discovered. Drop anything the next agent can cheaply rederive
(obvious code structure, standard commands, conversational back-and-forth).

## Step 3 -- Write the file

Write to `/tmp/claude-handoff-<name>-<stamp>.md` using this template. Omit no
section; if one is empty, write `none` rather than padding.

```markdown
# Session handoff -- <name> -- <stamp>

## Goal
<1-3 sentences: the end state we're driving toward>

## Status
<blunt: what's done / in progress / not started right now>

## What we did
- <action -> outcome> (path:line)

## Key learnings & decisions
- <non-obvious fact, gotcha, or decision + WHY / what it rules out>

## Changes on disk
- <path> -- <one-line what changed> [uncommitted | committed <sha>]

## Next steps
1. <concrete next action>

## Blockers / open questions
- <awaiting user input, or `none`>

## Pointers
- Branch: <branch>
- Key files: <path:line>, ...
- Refs: <Linear IDs / PR # / commit SHAs>
- Background tasks: <running procs + state, or `none`>
```

## Step 4 -- Report the handoff

Print the path and ready-to-use resume commands:

```
Handoff written: /tmp/claude-handoff-<name>-<stamp>.md

Continue in a fresh session:
  claude "Read /tmp/claude-handoff-<name>-<stamp>.md and continue the work."

...on a different model:
  claude --model sonnet "Read /tmp/claude-handoff-<name>-<stamp>.md and continue the work."
```

## Hard rules

1. **Pointers, not payloads.** Reference `path:line`, function names, and IDs.
   Never paste code blocks, file contents, diffs, or command output into the
   handoff -- that is the bloat this command exists to avoid.
2. **Capture the *why*.** Decisions, their rationale, and dead-ends already
   eliminated are the highest-value, least-recoverable content. Lead with them.
3. **No conversation replay.** Synthesize the outcome; don't narrate turn by
   turn.
4. **Ruthless concision.** Aim under ~1500 words. Every line must earn its
   place; cut preamble and restatement. A trivial session gets a few lines, not
   a padded template.
5. **Facts only.** Ground status and changes in the git/context from Step 1 --
   never claim work is done that the diff doesn't show.
6. **Write, then report.** The only chat output is the file path plus the Step 4
   resume block -- never dump the summary into the chat (that re-bloats the
   current session).

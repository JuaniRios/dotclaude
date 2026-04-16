---
name: edit-skill
description: Modify, update, or refactor an existing Claude Code skill or slash command in the dotclaude repo. Use when the user asks to edit, change, update, fix, improve, or tweak a skill or command — e.g. "update the /ci command", "change the cross-review skill", "fix the worktree command", "add an option to /pr-description".
allowed-tools: Bash(git:*), Bash(test:*), Bash(ls:*), Read, Edit, Write, Grep, Glob, AskUserQuestion
---

# Edit skill / command

Modify an existing Claude Code skill or slash command in `~/Github/dotclaude`,
which is git-tracked and symlinked into `~/.claude/`.

## Architecture context

```
~/Github/dotclaude/          # git repo (source of truth)
  commands/                  # slash commands — one .md file each
    ci.md                    #   invoked as /ci
    pr-description.md        #   invoked as /pr-description
    review-loop.md
    review-pr.md
    worktree.md
    new-skill.md
  skills/                    # skills — subdirectory with SKILL.md each
    cross-review/SKILL.md    #   auto-matched by description
    graphite/SKILL.md
    linear-cli/SKILL.md
    edit-skill/SKILL.md      #   this skill

~/.claude/
  commands -> ~/Github/dotclaude/commands   # symlink
  skills   -> ~/Github/dotclaude/skills     # symlink
```

### File formats

**Commands** — `commands/<name>.md`:
```yaml
---
allowed-tools: <tools>
description: <one-line>
argument-hint: <hint>  # optional
---
```

**Skills** — `skills/<name>/SKILL.md`:
```yaml
---
name: <name>
description: <one-line — Claude matches against this>
allowed-tools: <tools>
---
```

## Step 1 — Identify the target

Determine which skill or command the user wants to edit from the
conversation context. If ambiguous, list what's available and ask:

```bash
echo "Commands:"
ls ~/Github/dotclaude/commands/*.md 2>/dev/null | xargs -I{} basename {} .md
echo ""
echo "Skills:"
ls -d ~/Github/dotclaude/skills/*/SKILL.md 2>/dev/null | xargs -I{} dirname {} | xargs -I{} basename {}
```

Then ask the user which one to edit using `AskUserQuestion`.

Resolve the file path:
- Command `<name>`: `~/Github/dotclaude/commands/<name>.md`
- Skill `<name>`: `~/Github/dotclaude/skills/<name>/SKILL.md`

## Step 2 — Read and understand

Read the full file. Understand:
- The frontmatter (tools, description, argument-hint)
- The workflow steps
- The hard rules
- The overall structure

Present a brief summary to confirm you're editing the right thing:

```
Editing: <type> "<name>"
  File: <path>
  Description: <description from frontmatter>
```

## Step 3 — Understand the requested changes

The user has either already described what they want changed (in the
conversation leading to this skill activating) or needs to be asked.

If the changes are clear from context, summarize what you'll do and
proceed. If not, ask the user what specifically they want to change.

## Step 4 — Apply edits

Use the `Edit` tool for surgical changes. Use `Write` only if the file
needs a complete rewrite (rare — prefer incremental edits).

When editing:
- Preserve the existing structure and style of the file
- Keep frontmatter fields up to date (especially `description` if the
  behavior changed, `allowed-tools` if new tools are needed)
- Don't reformat or restructure parts the user didn't ask to change
- If adding new steps, number them consistently with the existing scheme

## Step 5 — Show the result

After editing, show the user what changed. Do NOT run `git diff` expecting
the user to see the output — instead, summarize the changes in prose:

```
Changes to <type> "<name>":
  - <change 1>
  - <change 2>
  - ...

Updated file: <path>
```

If the changes are substantial, read the file back and present the full
updated content so the user can review.

Ask the user if they're satisfied or want further adjustments. Iterate
until they approve.

## Step 6 — Commit

Stage and commit using `gt`:

```bash
cd ~/Github/dotclaude
git add <path>
```

Check the current branch:
- If on `main`: create a new branch with `gt create edit-<name> -m "refactor: update /<name> <type>"`
- If on a non-trunk branch: add a commit with `gt modify --commit -m "refactor: update /<name> <type>"`

Use an appropriate commit prefix:
- `refactor:` for restructuring or improving
- `feat:` for adding new capabilities
- `fix:` for correcting broken behavior
- `docs:` for documentation-only changes

## Step 7 — Offer to push

```
Updated <type> "<name>" — committed.

  File: <path>
  Branch: <branch>
  Commit: <sha>

Want me to push?
```

Wait for confirmation. If yes, run `git push`. If no, stop.

## Hard rules

1. Always edit files in `~/Github/dotclaude/`, never directly in `~/.claude/`.
2. Never delete a skill or command file without explicit confirmation —
   editing means modifying, not removing.
3. Use `gt` for git mutations when possible. Fall back to `git push` if
   `gt submit` fails (e.g., repo not synced with Graphite cloud).
4. Show the user what changed before committing.
5. Keep frontmatter in sync with content — if behavior changes, update
   the `description` field.
6. Don't reformat or restructure parts the user didn't ask to change.

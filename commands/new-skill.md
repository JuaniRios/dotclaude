---
allowed-tools: Bash(git:*), Bash(test:*), Bash(ls:*), Read, Write, Edit, Glob, Grep, AskUserQuestion
description: Create a new Claude Code skill or slash command in the dotclaude repo (git-tracked, symlinked to ~/.claude). Handles file creation, commits via git, and offers to push. Use /new-skill to add a new skill or command.
argument-hint: [skill|command] [name] — e.g. "/new-skill command deploy" or just "/new-skill" for interactive
---

# New skill / command creator

Creates a new Claude Code skill or slash command in `~/Github/dotclaude`,
which is git-tracked and symlinked into `~/.claude/` so changes are
immediately available.

## Architecture context

```
~/Github/dotclaude/          # git repo (source of truth)
  commands/                  # slash commands — one .md file each
    ci.md                    #   invoked as /ci
    pr-description.md        #   invoked as /pr-description
    review-loop.md
    review-pr.md
  skills/                    # skills — subdirectory with SKILL.md each
    cross-review/SKILL.md    #   auto-matched by description
    graphite/SKILL.md
    linear-cli/SKILL.md

~/.claude/
  commands -> ~/Github/dotclaude/commands   # symlink
  skills   -> ~/Github/dotclaude/skills     # symlink
```

### Commands vs Skills

**Commands** (slash commands):
- Live at `commands/<name>.md`
- Invoked explicitly by the user as `/<name>`
- Single `.md` file with frontmatter + instructions
- Frontmatter fields: `allowed-tools`, `description`, `argument-hint` (optional)

**Skills**:
- Live at `skills/<name>/SKILL.md`
- Auto-triggered by Claude when the description matches the user's request
- Subdirectory with `SKILL.md` (can include sibling files for context)
- Frontmatter fields: `name`, `description`, `allowed-tools`

**When to use which:**
- Command: user will invoke it explicitly (`/deploy`, `/lint`, `/new-skill`)
- Skill: Claude should activate it automatically based on context (e.g.,
  graphite skill activates whenever git operations are mentioned)

## Step 1 — Determine type and name

Parse `$ARGUMENTS` for type (`skill` or `command`) and name. If not provided
or ambiguous, ask the user using `AskUserQuestion`:

1. **Type** — "Are you creating a slash command (/name) or a skill
   (auto-triggered by description)?"
2. **Name** — kebab-case identifier (e.g., `deploy`, `run-tests`,
   `claude-api`). This becomes the filename or directory name.

## Step 2 — Collect metadata

Ask the user (batch into one `AskUserQuestion` if possible):

1. **Description** — one-line summary of when this skill/command should be
   used. For skills, this is critical — Claude matches against it to decide
   whether to activate. Be specific about trigger phrases.
2. **Allowed tools** — which tools the skill/command needs. Common patterns:
   - Read-only research: `Read, Grep, Glob`
   - Code modification: `Read, Edit, Write, Grep, Glob`
   - Shell commands: `Bash(git:*), Bash(cargo:*), ...` (prefix-matched)
   - Full agent: `Read, Edit, Write, Bash(*), Agent`
   - Ask the user what the skill needs to do and suggest appropriate tools.
3. **Argument hint** (commands only, optional) — e.g., `<pr-number>`,
   `[--stack]`, `[skill|command] [name]`

## Step 3 — Draft the content

Ask the user to describe what the skill/command should do. Based on their
description, draft the full `.md` file following the patterns established by
existing skills/commands in this repo:

- Start with a one-line summary of what it does
- Use numbered steps for the workflow
- Include specific instructions, not vague guidance
- Add a "Hard rules" section at the end for non-negotiable constraints
- Add a "Failure modes" section if there are meaningful error cases

Show the draft to the user and ask for approval or edits. Iterate until
they're satisfied.

## Step 4 — Create the file

For a **command**:

```
~/Github/dotclaude/commands/<name>.md
```

With frontmatter:

```yaml
---
allowed-tools: <tools>
description: <description>
argument-hint: <hint>  # only if provided
---
```

For a **skill**:

```
~/Github/dotclaude/skills/<name>/SKILL.md
```

With frontmatter:

```yaml
---
name: <name>
description: <description>
allowed-tools: <tools>
---
```

Write the file using the `Write` tool.

## Step 5 — Verify

1. Confirm the file exists and is reachable through the symlink:

   ```bash
   test -f ~/.claude/commands/<name>.md && echo "Command linked"
   # or
   test -f ~/.claude/skills/<name>/SKILL.md && echo "Skill linked"
   ```

2. Print the file path and a summary of what was created.

## Step 6 — Commit

Stage and commit directly on master:

```bash
cd ~/Github/dotclaude
git add commands/<name>.md
# or
git add skills/<name>/SKILL.md
git commit -m "feat: add /<name> <type>"
```

## Step 7 — Offer to push

Tell the user the commit is ready and ask if they want to push:

```
New <type> "<name>" created and committed.

  File: <path>
  Commit: <sha>

Want me to push?
```

Wait for confirmation. If yes, run `git push`. If no, stop.

## Hard rules

1. Always create files in `~/Github/dotclaude/`, never directly in `~/.claude/`.
2. Never overwrite an existing skill or command without explicit confirmation.
3. Commit directly to master — no branches.
4. Show the full draft to the user before writing any file.
5. Verify the symlink works after creating the file.

---
name: linear-cli
description: Manage Linear issues, projects, cycles, milestones, and documents from the command line via schpet/linear-cli (`linear`). Use when the user asks to view, list, create, update, comment on, or link Linear issues; when starting or finishing work on an issue; when drafting Linear tickets from code review findings, bugs, or follow-ups; or when any Linear/ticket/issue-tracker operation is mentioned.
allowed-tools: Bash(linear:*), Bash(curl:*), Bash(cat:*), Bash(grep:*)
---

# Linear CLI (`linear`) — schpet/linear-cli

Adapted from the upstream skill at https://github.com/schpet/linear-cli for use
in this user's dotfiles. Manages Linear issues, projects, cycles, milestones,
and documents. Git- and jj-aware.

## Prerequisites

The `linear` command must be on PATH:

```bash
linear --version
```

Install options (first time only):

```bash
# macOS
brew install schpet/tap/linear

# Deno
deno install -A --reload -f -g -n linear jsr:@schpet/linear-cli

# Or one-off without installing
npx @schpet/linear-cli --version
```

First-time auth:

1. Create an API key at https://linear.app/settings/account/security
2. `linear auth login`
3. `linear config` — generates `.linear.toml` for the current repo (sets default team, workspace, sort, VCS, etc.)

## Core principle: discover options with `--help`

`linear` is large. **Always start from `--help` on the exact subcommand before
guessing flags.** Every command supports `--help`:

```bash
linear --help
linear issue --help
linear issue create --help
linear issue update --help
linear milestone create --help
```

Do not infer flag names from memory — Linear CLI evolves. Read the help output
for the specific command you're about to run.

## Best practice: markdown content via file flags

When issue descriptions or comments contain markdown, **always use file-based
flags**, never inline `--description`/`--body` strings:

- `issue create` / `issue update` → `--description-file <path>`
- `comment add` / `comment update` → `--body-file <path>`

Why: shell escaping mangles newlines, bullets, backticks, and `$` signs.
Literal `\n` sequences end up in the Linear UI. File flags preserve the
markdown exactly.

Pattern:

```bash
# Write markdown to a tempfile
tmp=$(mktemp -t linear-desc.XXXXXX.md)
cat > "$tmp" <<'EOF'
## Summary

- First point
- Second point

## Details

Multi-line description with `code` and **formatting**.
EOF

# Use the file
linear issue create --title "My issue" --description-file "$tmp"

# Clean up
rm "$tmp"
```

Only use inline `--description`/`--body` for single-line, no-special-chars content.

## Command map

### Auth

```
linear auth login      # interactive API key setup
linear auth logout
linear auth list       # list configured workspaces
linear auth default    # set default workspace
linear auth token      # print token (for curl)
linear auth whoami
linear auth migrate
```

### Issues — read

```
linear issue view [ID]     # details; no arg = issue from current branch
linear issue view -w       # open in web
linear issue view -a       # open in Linear.app
linear issue id            # print ID from current branch
linear issue title         # print title only
linear issue url           # print Linear URL
linear issue mine --sort priority --team RAI   # issues assigned to you (requires --sort and --team)
linear issue query --search "text"                         # team-scoped search
linear issue query --search "text" --team ENG --json       # structured output
linear issue query --all-teams --json --limit 0            # export all
linear issue list --team ENG --sort priority              # list with required sort
linear issue list --project "Phase 1" --milestone "Beta"
linear issue commits       # commits for issue (jj only)
linear issue describe      # render description in terminal
```

### Issues — write

```
linear issue create                                          # interactive
linear issue create -t "Title" --description-file desc.md
linear issue update [ID] --milestone "Phase 2"
linear issue update [ID] --description-file notes.md
linear issue start [ID]    # create/switch branch, mark In Progress
linear issue delete [ID]
linear issue comment add [ID] --body-file comment.md
linear issue comment add [ID] -p <parent-id> --body-file reply.md
linear issue comment list [ID]
linear issue comment update <comment-id> --body-file new.md
linear issue comment delete <comment-id>
linear issue attach [ID] <file-or-url>
linear issue link [ID] <url>
linear issue relation add [ID] --type blocks --to OTHER-123
linear issue relation list [ID]
linear issue pull-request  # create GitHub PR with issue metadata
```

### Teams / Projects / Milestones / Cycles

```
linear team list
linear team id
linear team members
linear team autolinks      # configure GitHub autolinks

linear project list
linear project view [ID]
linear project create
linear project update [ID]

linear milestone list --project <id>
linear milestone view <id>
linear milestone create --project <id> --name "Q1" --target-date 2026-03-31
linear milestone update <id> --name "Renamed"
linear milestone delete <id>

linear cycle list --team <key>
linear cycle view <id>
```

### Initiatives & updates

```
linear initiative list
linear initiative create
linear initiative add-project <init-id> --project <id>
linear initiative-update create --initiative <id> --body-file status.md

linear project-update create --project <id> --body-file status.md
```

### Labels & documents

```
linear label list
linear label create --name "bug" --color "#ff0000"

linear document list
linear document list --project <id>
linear document list --issue ENG-123
linear document view <slug>
linear document view <slug> --raw    # markdown source
linear document create --title "Plan" --content-file plan.md --project <id>
cat plan.md | linear document create --title "Plan" --project <id>
linear document update <slug> --edit  # open in $EDITOR
linear document delete <slug>
```

### Config, schema, raw API

```
linear config              # interactive .linear.toml setup
linear schema -o /tmp/linear-schema.graphql   # dump full schema for grep
linear api '<query>'       # raw GraphQL request
```

## Required flags and common gotchas

Some commands have non-obvious required flags. Hit `--help` before running:

- `linear issue list` and `linear issue mine` both require a sort order — pass `--sort priority` or `--sort manual`, or set `issue_sort` in `.linear.toml`, or export `LINEAR_ISSUE_SORT`. They also need `--team <key>` unless the team can be inferred from the directory (e.g. via `.linear.toml`). If unknown, run `linear team list` first to find the key.
- `--no-pager` is supported on `issue list`, `issue mine`, and `issue query` — it will error on `project list` and friends.
- Many commands infer the current issue from the branch name (via the VCS
  integration). If the branch doesn't encode an ID, pass the ID explicitly.
- `linear issue create` gotchas:
  - `--priority` takes a **number** (1=urgent, 2=high, 3=medium, 4=low), not a string. `--priority urgent` will error.
  - `--project` takes the **project name**, not the UUID. Use the name from `linear project list`.
  - `--label` must match an existing label exactly. Run `linear label list` first to see available labels — don't guess names like "bug" that may not exist.
  - `--team` is required if no default team is configured. Run `linear team list` to find the key.

## Config file

Linear CLI loads `.linear.toml` from (in order): cwd → repo root →
`.config/linear.toml` → `$XDG_CONFIG_HOME/linear/linear.toml`.

| TOML key          | Env var                 | Example                 |
| ----------------- | ----------------------- | ----------------------- |
| `team_id`         | `LINEAR_TEAM_ID`        | `"ENG"`                 |
| `workspace`       | `LINEAR_WORKSPACE`      | `"mycompany"`           |
| `issue_sort`      | `LINEAR_ISSUE_SORT`     | `"priority"` / `"manual"` |
| `vcs`             | `LINEAR_VCS`            | `"git"` / `"jj"`        |
| `download_images` | `LINEAR_DOWNLOAD_IMAGES`| `true` / `false`        |

`linear config` generates this file interactively. Commit it for repo-specific
defaults; rely on `~/.config/linear/linear.toml` for global ones.

## Drafting issues from review findings / bugs

When creating issues from code review findings or bugs discovered during
implementation, use this workflow:

1. **Draft the markdown body to a tempfile** — preserves formatting and lets
   the user review before submission.

   ```bash
   tmp=$(mktemp -t linear-issue.XXXXXX.md)
   cat > "$tmp" <<'EOF'
   ## Problem

   Describe what's wrong or missing.

   ## Evidence

   - File: `src/foo.rs:42`
   - Finding: <bug summary>
   - Reviewer: opus/codex/gemini (if from /cross-review)

   ## Proposed fix

   <one paragraph>

   ## Context

   Discovered during <task>.
   EOF
   ```

2. **Show the draft to the user** and wait for explicit confirmation before
   running `linear issue create`. Never auto-create without approval — the user
   should see the title, description, project, milestone, and priority first.

3. **Create the issue**, passing the description file and any applicable
   metadata. Prefer `--project`, `--priority`, and labels when known:

   ```bash
   linear issue create \
     --title "Fix off-by-one in <foo>" \
     --description-file "$tmp" \
     --priority 2 \
     --label bug
   ```

4. **Print the issue URL** so the user can open it. Clean up the tempfile.

## Using the raw GraphQL API (fallback only)

Prefer the CLI for everything it supports. For the rare case that isn't
covered:

```bash
# Dump the schema once and grep it to find the right type/field
linear schema -o "${TMPDIR:-/tmp}/linear-schema.graphql"
grep -i "cycle" "${TMPDIR:-/tmp}/linear-schema.graphql"

# Simple query (no null markers — inline is fine)
linear api '{ viewer { id name email } }'

# Queries with required type markers (String!, Int!) must use heredoc to avoid
# shell-escape pain
linear api --variable teamId=abc123 <<'GRAPHQL'
query($teamId: String!) { team(id: $teamId) { name } }
GRAPHQL

# Complex variables via JSON
linear api --variables-json '{"filter":{"state":{"name":{"eq":"In Progress"}}}}' <<'GRAPHQL'
query($filter: IssueFilter!) { issues(filter: $filter) { nodes { title } } }
GRAPHQL

# Pipe to jq
linear api '{ issues(first:5){ nodes{ identifier title }}}' | jq '.data.issues.nodes'
```

For full HTTP control, use the token directly:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $(linear auth token)" \
  -d '{"query":"{ viewer { id } }"}'
```

## Hard rules

1. **Never create issues without user confirmation.** Draft, show, wait for
   approval, then run `linear issue create`.
2. **Always use `--description-file` / `--body-file`** for markdown content.
3. **Run `--help` on the exact subcommand** before guessing flags.
4. `linear issue list` requires `--sort` and usually `--team`. Don't forget.
5. For structured output that another tool will parse, pass `--json`.
6. Prefer the CLI over raw `linear api` — fall back to GraphQL only for
   genuinely unsupported operations.

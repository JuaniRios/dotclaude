---
allowed-tools: Bash(linear:*), Bash(ls:*), Bash(cat:*), Bash(test:*), Bash(mkdir:*), Bash(rm:*), Bash(date:*), Bash(find:*), Bash(head:*), Bash(tail:*), Bash(sed:*), Bash(grep:*), Bash(wc:*), Bash(sort:*), Read, Write, Edit, Glob, Grep, AskUserQuestion, Agent
description: Persistent cross-repo investigation tracker. Create, load, update, and close investigation traces that span multiple repos and conversations. Each trace is a structured markdown file in ~/Github/traces/ with a linked Linear issue. Use /trace to manage complex, multi-repo issues that need context preserved across conversations.
argument-hint: "new [--link RAI-nnn] [title] | load <id> | update <id> [note] | list | status [id] | close <id> | park <id>"
---

# Trace — cross-repo investigation tracker

Manages persistent investigation files in `~/Github/traces/`. Each trace is a
folder named `<LINEAR-ID>-<slug>/` containing a `TRACE.md` file that captures
the full investigation context: timeline, findings, actions, notes, and links
to repos/PRs.

Traces solve the problem of losing context when debugging issues that span
multiple repos and multiple conversations. Any conversation can `/trace load`
to pick up where the last one left off.

## Constants

```
TRACES_DIR="$HOME/Github/traces"
```

## Mode detection

Parse `$ARGUMENTS` to determine the subcommand:

| Arguments pattern                        | Mode          |
| ---------------------------------------- | ------------- |
| `new --link RAI-nnn [title...]`          | create-linked |
| `new [title...]`                         | create-new    |
| `load <id>`                              | load          |
| `update <id> <note text...>`            | quick-update  |
| `update <id>`                            | full-update   |
| `update`                                 | auto-update   |
| `list`                                   | list          |
| `status [id]`                            | status        |
| `close <id>`                             | close         |
| `park <id>`                              | park          |
| empty                                    | interactive   |

`<id>` can be:
- A full slug: `RAI-173-alpaca-redemption-failure`
- Just the Linear ID prefix: `RAI-173` (matched against folder names)
- A partial slug: `alpaca` (fuzzy-matched if unambiguous)

### Resolving `<id>` to a trace folder

```bash
resolve_trace() {
  local id="$1"
  local matches
  matches=$(ls -d "$TRACES_DIR"/*"$id"*/ 2>/dev/null)
  count=$(echo "$matches" | grep -c .)
  if [ "$count" -eq 0 ]; then
    echo "No trace found matching '$id'" >&2
    return 1
  elif [ "$count" -eq 1 ]; then
    echo "$matches"
  else
    echo "Ambiguous match for '$id':" >&2
    echo "$matches" >&2
    return 1
  fi
}
```

When ambiguous, show the matches and ask the user to be more specific.

## Step 1 — `new`: Create a new trace

### 1a. Gather info

If title is not in `$ARGUMENTS`, ask the user:
1. **Title** — short description of the issue (becomes both the Linear issue
   title and the slug basis)
2. **Summary** — 1-3 sentences on what happened and what's affected
3. **Repos involved** — which repos are relevant (suggest from `~/Github/`)
4. **Priority** — for the Linear issue (1=urgent, 2=high, 3=medium, 4=low)

### 1b. Create or link Linear issue

**If `--link RAI-nnn` was provided:**

```bash
# Verify the issue exists and get its details
linear issue view RAI-nnn --json
```

Extract `identifier`, `title`, and `url` from the JSON output. Use the
existing issue's title as the trace title if none was provided.

**If creating new:**

```bash
tmp=$(mktemp -t trace-desc.XXXXXX.md)
cat > "$tmp" <<'EOF'
## Investigation Trace

This issue tracks a cross-repo investigation.

**Trace file:** `~/Github/traces/<slug>/TRACE.md`

<user-provided summary>

### Repos involved
- <repo list>
EOF

linear issue create \
  --title "<title>" \
  --description-file "$tmp" \
  --priority <priority> \
  --label "investigation" \
  --no-interactive

rm "$tmp"
```

After creation, retrieve the issue details to get the identifier:

```bash
# The CLI prints the issue after creation. If you need the identifier,
# search for the just-created issue:
linear issue query --search "<exact title>" --team RAI --json
```

Extract the `identifier` (e.g., `RAI-175`) from the output.

### 1c. Create the trace folder and file

Generate the slug: `<IDENTIFIER>-<kebab-case-title>`

Examples:
- `RAI-175-alpaca-redemption-failure`
- `RAI-180-hedge-position-drift`

```bash
slug="RAI-175-alpaca-redemption-failure"  # constructed from identifier + title
mkdir -p "$TRACES_DIR/$slug"
```

Write `TRACE.md` with this template:

```markdown
---
slug: <slug>
status: active
linear: <identifier>
linear-url: <url>
created: <YYYY-MM-DD>
resolved:
repos:
  - <repo1>
  - <repo2>
prs: []
---

# <Title>

## Summary
<user-provided summary>

## Timeline
- **<YYYY-MM-DD HH:MM>** — Investigation opened

## Findings

## Actions

## Notes
### <YYYY-MM-DD> — Initial context
<any initial notes the user provided>

## Resolution
```

### 1d. Confirm

Print:

```
Trace created: <slug>
  Path:   ~/Github/traces/<slug>/TRACE.md
  Linear: <identifier> — <url>
  Repos:  <repo list>

Load this trace in any conversation with:
  /trace load <identifier>
```

## Step 2 — `load`: Load trace context

This is the most important subcommand. It injects the full investigation
context into the current conversation.

### 2a. Read the local trace

```bash
trace_dir=$(resolve_trace "$id")
```

Read the full `TRACE.md` file.

### 2b. Sync from Linear

Fetch current state from the Linear issue:

```bash
linear issue view <identifier> --json
```

From the JSON, extract and report:
- Current **status/state** (compare with TRACE.md status)
- Any **comments** added since last update (these may contain context from
  other team members or automated updates)
- **Linked PRs** or attachments

Also fetch comments:

```bash
linear issue comment list <identifier>
```

### 2c. Present the context

Output the trace to the conversation in a clear format:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Trace loaded: <slug>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Then output the full TRACE.md content, followed by any new information from
Linear that isn't already captured in the trace.

If there are new Linear comments not reflected in the trace, suggest updating
the trace to capture them.

**Important:** After loading, tell the user you now have the full context and
are ready to continue the investigation. Reference the key open items from the
Actions section.

## Step 3 — `update`: Add to a trace

### 3z. Auto-detect trace from conversation (no ID provided)

When `/trace update` is called with no ID and no note text, try to
auto-detect which trace is active in the current conversation before
falling back to asking:

1. **Scan the conversation** for signs of a loaded trace:
   - The `━━━ Trace loaded: <slug> ━━━` banner from a prior `/trace load`
   - TRACE.md frontmatter content (look for `slug:`, `linear:`, `status:`)
   - References to a specific trace ID (e.g., "RAI-280", "trace RAI-280")

2. **If a trace is found** — proceed to auto-update mode:
   - Read the current TRACE.md file
   - Review the conversation since the trace was loaded (or since the last
     `/trace update`)
   - Auto-extract relevant new context into the appropriate sections:
     - **Timeline**: significant events, milestones, deployments, PRs opened
     - **Findings**: new technical discoveries, root cause insights, safety
       analyses, design decisions
     - **Actions**: new action items identified, existing actions completed
     - **Notes**: add a timestamped note summarizing the session's work
     - **PRs**: link any new PRs mentioned in the conversation
   - Skip information that is already captured in the trace (compare with
     existing content to avoid duplication)
   - Apply all edits to the TRACE.md file
   - Sync to Linear (Step 3c)
   - Print a summary of what was added

3. **If no trace is found** — fall back to interactive mode (Step 3b): ask
   the user which trace to update and what to change.

### 3a. Quick update (note text provided in args)

When `$ARGUMENTS` contains text after the id (e.g., `/trace update RAI-173
hedge bot positions now reconciled`):

1. Read the current TRACE.md
2. Append a timestamped entry to the Notes section:

   ```markdown
   ### <YYYY-MM-DD HH:MM> — Quick note
   <the note text>
   ```

3. Write the updated file
4. Print confirmation: `Trace RAI-173 updated with note.`

### 3b. Full interactive update

When no note text is provided, ask the user what to update:

1. **Add a finding** — append to Findings section
2. **Add a timeline entry** — append to Timeline
3. **Add/check off an action** — add new action item or mark one complete
4. **Add a note** — append a timestamped note to Notes section
5. **Link a PR** — add a PR reference to the frontmatter and Related section
6. **Link a repo** — add a repo to the frontmatter
7. **Update summary** — revise the Summary section

After each update, write the file and ask if there's more to update.

### 3c. Sync back to Linear

After any update, add a comment to the Linear issue summarizing what changed:

```bash
tmp=$(mktemp -t trace-comment.XXXXXX.md)
cat > "$tmp" <<'EOF'
**Trace updated** — <brief description of what was added>

See `~/Github/traces/<slug>/TRACE.md` for full context.
EOF

linear issue comment add <identifier> --body-file "$tmp"
rm "$tmp"
```

## Step 4 — `list`: Show all traces

```bash
ls -d "$TRACES_DIR"/*/
```

For each trace folder, read the TRACE.md frontmatter and display a table:

```
TRACE                                STATUS   LINEAR   REPOS                    CREATED
RAI-175-alpaca-redemption-failure    active   RAI-175  issuance, liquidity      2026-04-28
RAI-180-hedge-position-drift         parked   RAI-180  liquidity                2026-04-30
RAI-162-api-timeout-cascade          resolved RAI-162  rest.api, liquidity      2026-04-15
```

Sort by status (active first, then parked, then resolved) and then by the
Linear issue number descending (newest first within each status group).

## Step 5 — `status`: Quick summary

If `<id>` is provided, show a condensed view of that trace:

1. Read TRACE.md
2. Show: title, status, Linear link, repos, open action count, last note date
3. Fetch Linear issue status for comparison

If no `<id>`, show status for all **active** traces (skip resolved).

## Step 6 — `close`: Resolve a trace

1. Read the current TRACE.md
2. Ask the user for a **resolution summary** — what fixed it, what was
   the root cause, any follow-ups needed
3. Update the TRACE.md:
   - Set `status: resolved` in frontmatter
   - Set `resolved: <YYYY-MM-DD>` in frontmatter
   - Fill in the Resolution section with the user's summary
   - Add a final timeline entry: `**<YYYY-MM-DD HH:MM>** — Resolved`
4. Update the Linear issue:
   - Add a closing comment with the resolution summary
   - Optionally move the issue to "Done" state (ask the user)
5. Print confirmation

## Step 7 — `park`: Park a trace

For issues blocked on external parties or intentionally paused:

1. Read the current TRACE.md
2. Ask why it's being parked (e.g., "waiting on Alpaca support response")
3. Update the TRACE.md:
   - Set `status: parked` in frontmatter
   - Add a timeline entry: `**<YYYY-MM-DD HH:MM>** — Parked: <reason>`
4. Print confirmation with the parked reason

## Step 8 — Interactive mode (no arguments)

When `/trace` is run with no arguments:

1. Show the list of active traces (same as `/trace list` but filtered to
   active + parked only)
2. Ask what the user wants to do:
   - Load a trace
   - Create a new trace
   - Update a trace
   - Close a trace

## Hard rules

1. **Never delete a trace folder.** Resolved traces are kept for historical
   reference. They can be loaded for post-mortems.
2. **Always use `--body-file` / `--description-file`** when writing to Linear.
   Never inline markdown in shell strings.
3. **Always use `--no-interactive`** when creating Linear issues to avoid
   hanging on prompts.
4. **Slugs always start with the Linear identifier** (e.g., `RAI-175-...`)
   so they sort chronologically by issue number.
5. **Timestamps use local time** in `YYYY-MM-DD HH:MM` format.
6. **The trace file is the source of truth.** Linear is a mirror for
   visibility. If they diverge, the trace file wins.
7. **On load, always read the full TRACE.md** — never summarize or skip
   sections. The whole point is to restore full context.
8. **When resolving `<id>`, prefer exact prefix match** on the Linear
   identifier (e.g., `RAI-173` matches `RAI-173-alpaca-redemption-failure`).
   Fall back to substring match only if no prefix match exists.
9. **label `investigation`**: if the label doesn't exist in Linear, create it
   first or skip the label flag rather than failing.

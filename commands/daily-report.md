---
allowed-tools: Bash(*), Read, Grep, Glob, Agent
description: Generate a team-facing daily summary of all work done across repos. For pasting in the group chat. Shows what was accomplished, what's next, open points, and stats.
---

# Daily Report — end-of-day work summary

Generates a comprehensive daily report by aggregating Claude Code sessions,
git history, and GitHub activity across all repos in `~/Github/`.

## Step 1 — Determine date range

Use today's date (local timezone). Compute the start-of-day timestamp in
both ISO format and Unix milliseconds:

```bash
today=$(date +%Y-%m-%d)
today_start_epoch_ms=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today 00:00:00" +%s)000
echo "Report date: $today"
echo "Epoch ms start: $today_start_epoch_ms"
```

## Step 2 — Collect data (run all three in parallel using Agent sub-agents)

Launch four parallel sub-agents to collect data simultaneously. Each agent
should return structured findings.

### Agent A — Claude Code session activity

Parse `~/.claude/history.jsonl` to find all entries where `timestamp >=
$today_start_epoch_ms`. Use python3 for reliable JSONL parsing:

```bash
python3 -c "
import json, sys
from datetime import datetime

today = datetime.now().strftime('%Y-%m-%d')
start_ts = int(datetime.strptime(today + ' 00:00:00', '%Y-%m-%d %H:%M:%S').timestamp() * 1000)

sessions = {}
with open('$HOME/.claude/history.jsonl') as f:
    for line in f:
        try:
            entry = json.loads(line.strip())
        except json.JSONDecodeError:
            continue
        if entry.get('timestamp', 0) >= start_ts:
            sid = entry.get('sessionId', 'unknown')
            project = entry.get('project', 'unknown')
            display = entry.get('display', '')
            if sid not in sessions:
                sessions[sid] = {'project': project, 'prompts': [], 'first_ts': entry['timestamp']}
            sessions[sid]['prompts'].append(display)

# Group by project
by_project = {}
for sid, info in sessions.items():
    proj = info['project']
    if proj not in by_project:
        by_project[proj] = []
    by_project[proj].append({
        'session_id': sid,
        'prompt_count': len(info['prompts']),
        'first_prompts': info['prompts'][:5],
        'total_prompts': len(info['prompts'])
    })

for proj, slist in sorted(by_project.items()):
    print(f'\n## {proj}')
    for s in slist:
        print(f'  Session {s[\"session_id\"][:8]}... ({s[\"total_prompts\"]} prompts)')
        for p in s['first_prompts']:
            if p and not p.startswith('/'):
                print(f'    - {p[:120]}')
" 2>/dev/null
```

Then, for each session found, read the corresponding JSONL conversation file
to understand the full scope of work. Session files live at:

```
~/.claude/projects/<project-path-with-dashes>/<sessionId>.jsonl
```

Where `<project-path-with-dashes>` is the project path with `/` replaced by
`-` (e.g., `/Users/juanrios/Github/st0x.liquidity` becomes
`-Users-juanrios-Github-st0x-liquidity`).

For each session file, read the first 200 and last 200 lines to capture the
opening request and final state. Extract:
- What the user asked for (user messages)
- What was accomplished (look for tool calls, file edits, commits)
- Whether the work seems complete or in-progress

### Agent B — Git activity across all repos

**IMPORTANT**: This project uses Graphite (`gt`) which frequently amends and
rebases commits. `git log --since=today` uses the *author date* which does NOT
change on rebase/amend, so it misses work done today on branches created
earlier. Use TWO approaches to catch everything:

1. **Reflog-based detection** — `git reflog` records when branch tips move,
   regardless of commit dates. This catches rebases, amends, and force-pushes.
2. **Standard git log** — as a fallback for new commits authored today.

```bash
git_email=$(git config user.email 2>/dev/null || echo "")
today=$(date +%Y-%m-%d)

for repo in ~/Github/*/; do
  # Skip non-git directories and worktree container dirs
  if [[ "$repo" == *-worktrees* ]]; then continue; fi
  if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then continue; fi

  repo_name=$(basename "$repo")

  # Approach 1: Reflog — find branches updated today (catches amends/rebases)
  # Shows which branches had their tip moved today
  updated_branches=$(git -C "$repo" reflog --since="$today 00:00" \
    --pretty=format:"%D" --all 2>/dev/null | grep -oE 'refs/heads/[^ ,]+' | \
    sed 's|refs/heads/||' | sort -u)

  # Approach 2: Standard git log for commits authored today
  authored_today=$(git -C "$repo" log --since="$today 00:00" --author="$git_email" \
    --pretty=format:"%h|%s|%ai" --all 2>/dev/null)

  if [ -n "$updated_branches" ] || [ -n "$authored_today" ]; then
    echo "### $repo_name"

    if [ -n "$updated_branches" ]; then
      echo "  Branches pushed/amended today:"
      echo "$updated_branches" | while read -r branch; do
        # Show the branch tip commit
        tip=$(git -C "$repo" log -1 --pretty=format:"%h|%s" "$branch" 2>/dev/null)
        if [ -n "$tip" ]; then
          echo "    - $branch: $tip"
        fi
      done
    fi

    if [ -n "$authored_today" ]; then
      echo "  Commits authored today:"
      echo "$authored_today" | while IFS='|' read -r hash subject date; do
        echo "    - [$hash] $subject"
      done
    fi
    echo ""
  fi
done
```

Also check worktree directories:

```bash
for wt_dir in ~/Github/*-worktrees/*/; do
  if [ ! -d "$wt_dir/.git" ] && [ ! -f "$wt_dir/.git" ]; then continue; fi

  wt_name=$(basename "$(dirname "$wt_dir")")/$(basename "$wt_dir")

  updated_branches=$(git -C "$wt_dir" reflog --since="$today 00:00" \
    --pretty=format:"%D" --all 2>/dev/null | grep -oE 'refs/heads/[^ ,]+' | \
    sed 's|refs/heads/||' | sort -u)

  authored_today=$(git -C "$wt_dir" log --since="$today 00:00" --author="$git_email" \
    --pretty=format:"%h|%s|%ai" --all 2>/dev/null)

  if [ -n "$updated_branches" ] || [ -n "$authored_today" ]; then
    echo "### $wt_name (worktree)"
    if [ -n "$updated_branches" ]; then
      echo "  Branches pushed/amended today:"
      echo "$updated_branches" | while read -r branch; do
        tip=$(git -C "$wt_dir" log -1 --pretty=format:"%h|%s" "$branch" 2>/dev/null)
        if [ -n "$tip" ]; then
          echo "    - $branch: $tip"
        fi
      done
    fi
    if [ -n "$authored_today" ]; then
      echo "  Commits authored today:"
      echo "$authored_today" | while IFS='|' read -r hash subject date; do
        echo "    - [$hash] $subject"
      done
    fi
    echo ""
  fi
done
```

### Agent B2 — Trace files (run inside Agent B, not a separate agent)

Check for investigation traces updated today. Traces live at
`~/Github/traces/*/TRACE.md`. Include this in the git agent's work:

```bash
today=$(date +%Y-%m-%d)

echo "=== Traces updated today ==="
for trace_dir in ~/Github/traces/*/; do
  trace_file="$trace_dir/TRACE.md"
  if [ ! -f "$trace_file" ]; then continue; fi

  # Check if the trace file was modified today (via filesystem mtime)
  mod_date=$(stat -f "%Sm" -t "%Y-%m-%d" "$trace_file" 2>/dev/null)
  if [ "$mod_date" = "$today" ]; then
    slug=$(basename "$trace_dir")
    # Extract status from frontmatter
    status=$(grep -m1 '^status:' "$trace_file" | awk '{print $2}')
    linear=$(grep -m1 '^linear:' "$trace_file" | awk '{print $2}')
    echo "### $slug"
    echo "  Status: $status"
    echo "  Linear: $linear"
    # Show last 5 timeline entries for context
    grep -A0 '^\- \*\*' "$trace_file" | tail -5
    echo ""
  fi
done
```

This reveals which investigations were actively worked on today and their
current status (active/resolved). Include trace context in the report's
thematic grouping — traces represent multi-day investigations.

### Agent C — Linear activity

Use the `linear` CLI to find today's issue activity:

```bash
today=$(date +%Y-%m-%d)

echo "### Issues completed today"
linear issue mine --state completed --updated-after="$today" --no-pager 2>/dev/null

echo ""
echo "### Issues started today"
linear issue mine --state started --updated-after="$today" --no-pager 2>/dev/null

echo ""
echo "### Issues updated today (all states)"
linear issue mine --all-states --updated-after="$today" --no-pager 2>/dev/null
```

For each issue that was completed or started, also get details:

```bash
# For the most relevant issues (up to 5), get full context
linear issue view <ID> --no-pager 2>/dev/null
```

This reveals what tickets were worked on, their status transitions, and
any comments added today.

### Agent D — GitHub activity

Use `gh` to find today's PR and issue activity:

```bash
today=$(date +%Y-%m-%d)
gh_user=$(gh api user --jq '.login' 2>/dev/null)

echo "### PRs opened today"
gh search prs --author="$gh_user" --created=">=$today" --json title,url,repository,state \
  --jq '.[] | "- [\(.repository.nameWithOwner)] \(.title) (\(.state)) — \(.url)"' 2>/dev/null

echo ""
echo "### PRs merged today"
gh search prs --author="$gh_user" --merged=">=$today" --json title,url,repository \
  --jq '.[] | "- [\(.repository.nameWithOwner)] \(.title) — \(.url)"' 2>/dev/null

echo ""
echo "### Issues closed today"
gh search issues --author="$gh_user" --closed=">=$today" --json title,url,repository \
  --jq '.[] | "- [\(.repository.nameWithOwner)] \(.title) — \(.url)"' 2>/dev/null
```

## Step 3 — Synthesize the report

Once all three agents return their data, synthesize into a single markdown
report with these sections. Use thematic grouping — cluster work into 3-5
themes rather than listing every commit or prompt.

### Report format

```markdown
# Daily Report — {today's date}

## Summary
2-3 sentences in first person describing the day's overall focus and
accomplishments. Include temporal markers if work spanned morning/afternoon/evening.

## What Was Done
Group by theme (e.g., "Feature Development", "Bug Fixes", "Infrastructure",
"Research/Investigation"). Each theme gets:
- **Theme name**
  - 2-4 bullet points of what was accomplished, written in first person
  - Include repo names in brackets: [st0x.liquidity]
  - Include Linear issue IDs where applicable (e.g., RAI-280)
  - Link to PRs where applicable

Only create a theme if the work exceeded ~10 minutes. Small tasks go under
"Other".

## What's Next
Infer upcoming work from:
- Open PRs awaiting review
- In-progress sessions that weren't completed
- Branches with uncommitted changes
- TODO items or follow-ups mentioned in session conversations

## Open Points / Blockers
- Failing CI on any branches
- PRs with requested changes
- Stale reviews
- Any issues mentioned in sessions that weren't resolved

## Stats
- Pushed to: [repo] PR #X, [repo] PR #Y, ... (list each project/PR that got commits)
- PRs opened: {count} | merged: {count}
- Linear issues: completed: {count} | started: {count} | created: {count}
```

## Step 4 — Output

Wrap the entire report in a single fenced code block (` ```markdown ... ``` `)
so the user can copy-paste the raw markdown directly into a group chat.
Do NOT save it to a file unless the user asks.

## Hard rules

1. Always use the local timezone for "today" — not UTC.
2. Never read more than 400 lines from any single session JSONL file (read
   first 200 + last 200). These files can be huge.
3. Thematic grouping over flat lists — cluster related work, never dump raw
   commit messages.
4. If `gh` or `linear` is not authenticated or fails, skip that section
   gracefully and note it in the report.
5. If no activity is found for the day, say so clearly — don't fabricate.
6. Include worktree activity — the user works across multiple worktrees of
   the same repo.
7. Keep the report concise: aim for one screen (40-60 lines of markdown).
8. Write the entire report in first person ("I fixed...", "I investigated...")
   — this is pasted directly into a team group chat.
9. Never mention internal tooling or process in the output. This includes:
   Claude Code sessions, JSONL files, AI tooling, traces, cross-reviews,
   feedback-reviews, review loops, slash commands, skills, sub-agents, or
   any other implementation detail of how the work was done. These are
   input sources for understanding what was accomplished — the team only
   cares about outcomes, not process. Write about *what* was done and *why*,
   never *how* (e.g., "addressed PR review comments" not "ran
   /feedback-review"; "investigated and root-caused the bug" not "updated
   trace RAI-280"; "reviewed the fix" not "ran cross-review with 3 agents").
10. Always include Linear issue IDs (e.g., RAI-280) when referencing tickets.
11. If investigation traces were updated today, weave the investigation
    findings into the relevant theme naturally (e.g., "Root-caused the
    Fireblocks timeout — ..."). Never use the word "trace" in the output.

## Failure modes

- **No sessions today**: Report says "No Claude Code sessions found for
  today" and proceeds with git/GitHub data only.
- **`gh` not authenticated**: Skip GitHub section, add a note: "GitHub
  activity skipped (gh not authenticated)".
- **`linear` not authenticated**: Skip Linear section, add a note: "Linear
  activity skipped (linear not authenticated)".
- **No git repos found**: Report focuses on session activity only.
- **history.jsonl missing**: Fall back to scanning session JSONL files by
  modification date (`find ~/.claude/projects -name '*.jsonl' -newer
  <today-sentinel>`).

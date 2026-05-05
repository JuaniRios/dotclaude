---
allowed-tools: Bash(*), Read, Grep, Glob, Agent
description: Generate a team-facing daily summary of all work done across repos. For pasting in the group chat. Shows what was accomplished, what's next, open points, and stats.
argument-hint: "[compressed]"
---

# Daily Report — end-of-day work summary

Generates a comprehensive daily report by aggregating Claude Code sessions,
git history, and GitHub activity across all repos in `~/Github/`.

## Compressed mode

When invoked as `/daily-report compressed`, produce a much shorter report.
Still run all the same data collection (Steps 1–2), but in Step 3 compress
the output to ~10-15 lines max:

- No Stats section
- No Open Points / Blockers section (unless critical)
- "What Was Done" becomes 3-5 one-line bullets (one per theme, no sub-bullets)
- "What's Next" becomes 2-3 one-line bullets
- No theme sub-headings — just a flat list

Compressed format example:

```
📋 <b>Daily Report — {date}</b>

✅ <b>Done</b>
- [st0x.issuance] Built unified redemption recovery endpoint, PR #143 in review (RAI-281)
- [st0x.liquidity] Fixed silent WebSocket stream failure in OrderFillMonitor, PR #631
- [st0x.liquidity] Addressed PR feedback on #629, #616, #628; created RAI-291 for event-sorcery extraction
- Completed RAI-272 (nix secret rekeying fix)

📌 <b>Next</b>
- Merge all open PRs, recover stuck issuance funds, deploy stream fix
- Unblock staging, test hedging, deploy to prod if green
- Review 14 PRs awaiting my review
```

Then send via Telegram (Step 4) as normal. If the argument is NOT
"compressed", continue with the full report flow below.

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

Use `gh` to find today's PR and issue activity.

**IMPORTANT**: `gh search prs --merged` uses GitHub's search index which can
lag behind actual merge events (sometimes by hours). For merged PRs, query
each repo directly via `gh pr list` which hits the real-time repo API. Use
`gh search` only for opened PRs and closed issues where slight lag is
acceptable.

```bash
today=$(date +%Y-%m-%d)
gh_user=$(gh api user --jq '.login' 2>/dev/null)

echo "### PRs opened today"
gh search prs --author="$gh_user" --created=">=$today" --json title,url,repository,state \
  --jq '.[] | "- [\(.repository.nameWithOwner)] \(.title) (\(.state)) — \(.url)"' 2>/dev/null

echo ""
echo "### PRs merged today (per-repo, real-time)"
for repo in ~/Github/*/; do
  if [[ "$repo" == *-worktrees* ]]; then continue; fi
  if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then continue; fi

  # Get the GitHub remote (owner/repo)
  remote_url=$(git -C "$repo" remote get-url origin 2>/dev/null)
  if [ -z "$remote_url" ]; then continue; fi
  # Extract owner/repo from SSH or HTTPS URL
  nwo=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|')
  if [ -z "$nwo" ]; then continue; fi

  # Query merged PRs authored by user, sorted by most recent
  merged=$(gh pr list --repo "$nwo" --author "$gh_user" --state merged \
    --json number,title,mergedAt \
    --jq ".[] | select(.mergedAt >= \"${today}T00:00:00\") | \"- [$nwo] \(.title) (PR #\(.number))\"" 2>/dev/null)

  if [ -n "$merged" ]; then
    echo "$merged"
  fi
done

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

Use Telegram HTML formatting. `<b>` for headers and theme names,
`<code>` for repo names and issue IDs, plain `-` for bullets. No links —
write PR references as plain text (e.g., PR #143). Blank lines separate
sections. Every section header and theme name MUST start with an emoji.

Emoji conventions:
- 📋 Title
- ✅ What Was Done
- 🔧 Bug fix / reliability theme
- 🏗 Architecture / infrastructure theme
- 🚀 Feature development theme
- 📦 Other / miscellaneous theme
- 📌 What's Next
- ⚠️ Open Points / Blockers
- 📊 Stats

Pick the most fitting emoji per theme from the list above (or use another
relevant one if none fits). The key rule: every `<b>` header gets an emoji
prefix.

Example:

```
📋 <b>Daily Report — {today's date}</b>

{2-3 sentences in first person.}

✅ <b>What Was Done</b>

🔧 <b>{Theme Name}</b> — <code>{repo}</code>
- 2-4 bullet points of what was accomplished, written in first person
- Include repo names in code tags: <code>st0x.liquidity</code>
- Include Linear issue IDs: <code>RAI-280</code>
- Reference PRs as plain text: PR #143

Only create a theme if the work exceeded ~10 minutes. Small tasks go under
"📦 Other".

📌 <b>What's Next</b>
- Open PRs awaiting review
- In-progress sessions that weren't completed
- TODO items or follow-ups mentioned in session conversations

⚠️ <b>Open Points / Blockers</b>
- Failing CI on any branches
- PRs with requested changes
- Any issues mentioned in sessions that weren't resolved

📊 <b>Stats</b>
- Pushed to: <code>repo</code> PR #X, <code>repo</code> PR #Y, ...
- PRs opened: {count} | merged: {count}
- Linear issues: completed: {count} | started: {count} | created: {count}
```

## Step 4 — Send via Telegram

Send the report to the user's Telegram "Saved Messages" via the bot API.
Credentials are in `~/.config/telegram-bot.env` (must contain
`export TELEGRAM_BOT_TOKEN=...` and `export TELEGRAM_CHAT_ID=...`).

1. Write the report text to `/tmp/daily-report.txt` using Telegram HTML
   formatting (see formatting rules below).
2. Send it:

```bash
source ~/.config/telegram-bot.env
python3 -c "
import os, urllib.request, urllib.parse, json

with open('/tmp/daily-report.txt') as f:
    text = f.read()

token = os.environ['TELEGRAM_BOT_TOKEN']
chat_id = os.environ['TELEGRAM_CHAT_ID']
url = f'https://api.telegram.org/bot{token}/sendMessage'
data = urllib.parse.urlencode({
    'chat_id': chat_id,
    'text': text,
    'parse_mode': 'HTML'
}).encode()
req = urllib.request.Request(url, data)
resp = json.load(urllib.request.urlopen(req))
if resp.get('ok'):
    print('Sent to Telegram')
else:
    print(f'Telegram error: {resp}')
"
```

3. Print a brief confirmation ("Report sent to Telegram Saved Messages.")
   and also print the report inline so the user can review it in the
   terminal.

### Telegram HTML formatting rules

Use Telegram's HTML parse mode — it's more reliable than MarkdownV2:
- `<b>text</b>` for section headers and theme names
- `<code>text</code>` for repo names, issue IDs (e.g., `<code>RAI-280</code>`)
- Plain `-` for bullets
- No links — write PR references as plain text (e.g., PR #143)
- No special escaping needed (except `<`, `>`, `&` which are rare in reports)

Do NOT save the report to a permanent file unless the user asks.

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
12. The report is sent via Telegram bot using HTML parse mode. Use
    `<b>` for headers and theme names, `<code>` for repo names and IDs,
    plain `-` for bullets, and no links (plain "PR #123" text).

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

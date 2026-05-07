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

- Status section becomes 1 line (🟢/🟡/🔴 + one sentence)
- No Action Items section (unless 🔴 items exist)
- "What Was Done" becomes 3-5 one-line bullets (one per theme, no sub-bullets)
- No theme sub-headings — just a flat list

Compressed format example:

```
Logging off for the day. @highonhopium_josh @dcatki

📋 <b>Daily Report — {date}</b>

🟡 <b>Status:</b> Prod manually patched but code fix still in PR #642 — will crash on next non-USDC TakeOrder.

✅ <b>Done</b>
- [st0x.issuance] Recovered stuck mint, triaged queue, PR #145 open (RAI-364)
- [st0x.liquidity] Fixed orphaned order bug, merged PR #640; resilient transfers PR #641 open (RAI-365, RAI-366)
- [st0x.liquidity] Deployed 3 new tokens to prod, fixed crash-loop, PR #642 open (RAI-367)
- [st0x.liquidity] Merged dashboard PRs #633–#635; closed Schwab/Alpaca removal (RAI-140, RAI-166, RAI-247, RAI-99)

⚡ <b>Urgent</b>
- 🔴 Merge #642 — prod crashes on non-USDC TakeOrder events
```

Then send via Telegram (Step 4) as normal. If the argument is NOT
"compressed", continue with the full report flow below.

## Step 1 — Determine date range

Use local timezone. If the current local time is before 05:00, treat the
report as belonging to **yesterday** (the workday hasn't ended yet — the
user is still wrapping up the previous day's work).

```bash
current_hour=$(date +%H)
if [ "$current_hour" -lt 5 ]; then
  today=$(date -v-1d +%Y-%m-%d)
  echo "Before 5 AM — reporting on previous day"
else
  today=$(date +%Y-%m-%d)
fi
today_start_epoch_ms=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today 00:00:00" +%s)000
echo "Report date: $today"
echo "Epoch ms start: $today_start_epoch_ms"
```

## Step 2 — Collect data (run all four in parallel using Agent sub-agents)

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
- **Any production incidents, outages, or manual interventions**
- **Root causes identified and whether fixes are shipped or still in PRs**

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
    trace_status=$(grep -m1 '^status:' "$trace_file" | awk '{print $2}')
    trace_linear=$(grep -m1 '^linear:' "$trace_file" | awk '{print $2}')
    echo "### $slug"
    echo "  Status: $trace_status"
    echo "  Linear: $trace_linear"
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
linear issue mine --state completed --updated-after="$today" --sort priority --team RAI --no-pager 2>/dev/null

echo ""
echo "### Issues started today"
linear issue mine --state started --updated-after="$today" --sort priority --team RAI --no-pager 2>/dev/null

echo ""
echo "### Issues updated today (all states)"
linear issue mine --all-states --updated-after="$today" --sort priority --team RAI --no-pager 2>/dev/null
```

For each issue that was completed or started, also get details:

```bash
# For the most relevant issues (up to 5), get full context
linear issue view <ID> --no-pager 2>/dev/null
```

This reveals what tickets were worked on, their status transitions, and
any comments added today.

**Fallback if `linear` CLI fails**: grep all git commit messages and session
data for `RAI-\d+` patterns. Deduplicate and report as "referenced issues
(Linear CLI unavailable)". This is better than silently dropping all Linear
context.

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
  # Extract owner/repo from SSH or HTTPS URL (BSD sed compatible)
  nwo=$(echo "$remote_url" | sed 's|\.git$||' | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|')
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

## Step 2.5 — User review before writing

Once all four agents return, compile a short summary of what you found and
present it to the user for review using `AskUserQuestion`. This lets the
user correct emphasis, flag things you missed, or add context you couldn't
infer from the data (e.g., "prod is currently down", "this issue is the
most important one").

Format the summary as a bulleted list of proposed themes with key items:

```
Here's what I found for today's report:

🚦 Status: [your best guess — 🟢/🟡/🔴 + why]

Proposed themes:
- Prod incident: crash-loop, manual SQL patch, PR #642 pending
- Orphaned order fix: RKLB stuck, recovery merged (PR #640)
- Issuance: stuck mint recovered, PR #145 open
- Dashboard + cleanup: PRs #633–635 merged, Schwab/Alpaca removal done

Linear: 7 completed, 3 started
PRs: 4 opened, 4 merged

Are these the main things to talk about? Any corrections on status,
emphasis, or things I missed?
```

Wait for the user's response. Incorporate their feedback into the
synthesis — their input overrides your inferences. For example:
- If the user says "prod is down" → Status is 🔴, not 🟡
- If the user says "the issuance fix is most important" → lead with that
- If the user adds context not in the data → include it

Only proceed to Step 3 after the user confirms or provides corrections.
In compressed mode, still do this review step but keep the summary shorter.

## Step 3 — Synthesize the report

Once the user has reviewed and confirmed, synthesize into a single report.
This is the most important step — you are not just listing outputs, you are
**connecting dots across data sources** to tell a coherent story.

### Synthesis rules

Before writing, answer these questions from the collected data (and the
user's corrections from Step 2.5):

1. **System health**: Is anything broken, degraded, or at risk in production
   right now? Was there a prod incident today? Was it fully resolved (code
   fix deployed) or only manually patched (fix still in PR)?
2. **Impact & duration**: If an outage or blind spot was discovered, how long
   did it last? What's the business impact (e.g., assets not hedged, funds
   stuck, users affected)?
3. **Ship status**: For each piece of work, what's the deployment state?
   Distinguish clearly between:
   - ✅ Merged and deployed to prod
   - 🟡 Merged to main (not yet deployed)
   - 🟠 PR open, in review
   - 🔴 PR open, blocked (CI failing, review requested changes)
   - 🩹 Manually patched in prod (code fix not yet merged)
4. **Completeness**: Cross-reference Linear issues against git commits and
   PRs. If issues were completed today, make sure the corresponding work
   appears in the report. If git commits reference issue IDs not found in
   Linear data, include them anyway.

### Report structure

```
Logging off for the day. @highonhopium_josh @dcatki

📋 <b>Daily Report — {date}</b>

🚦 <b>Status</b>
{1-3 lines. Traffic light: 🟢 all systems healthy | 🟡 degraded or
at-risk | 🔴 prod down or critical issue. State what's wrong and what
needs to happen. If all green, say so in one line.}

✅ <b>What Was Done</b>

{Thematic groups. Each theme gets an emoji + bold name + repo link.
2-4 bullets per theme. Lead with OUTCOME ("Dashboard now shows X")
not activity ("Merged PR that changes X"). Include root causes for
bugs, duration for incidents, and deployment state for fixes.}

⚡ <b>Action Items</b>
{Priority-ordered list. Each item gets a marker:
- 🔴 Urgent — prod at risk, blocks others, time-sensitive
- 🟡 Important — should happen soon but not critical
- 🟢 Normal — review, cleanup, follow-up}

📊 <b>Stats</b>
- <b>PRs opened:</b> {n} — list each with repo
- <b>Same-day open→merge:</b> {n} — PRs opened and merged on the same day
  (include turnaround time if notable)
- <b>Prior-day open, merged today:</b> {n} — PRs opened before today that
  were merged today
- <b>Linear issues:</b> {n} completed · {n} started · {n} created
- <b>PR↔issue coverage:</b> {n}/{total} PRs have a linked Linear issue.
  Flag any PRs missing a corresponding issue.
- <b>Lines changed:</b> +{ins} / -{del} (aggregate across all repos, from
  git log --shortstat for commits authored today)
- <b>Repos touched:</b> {n} — list repo names with links
```

### Theme guidelines

- Group by **outcome**, not by repo or activity type. "Dashboard accuracy
  improvements" is better than "PRs #633, #634, #635 merged."
- Lead each bullet with what changed for the user/system, then the how.
  "Hedging now covers QQQM, VWO, ARKK — added to prod config" not
  "Added QQQM, VWO, ARKK to prod config."
- Include root causes for bugs — a manager needs to know if this is a
  one-off or a systemic issue.
- State incident duration when known: "PPLT/SIVR/IAU had no hedging
  coverage for 12 days (Apr 24 – May 6)" not just "WebSocket stream
  died."
- If a manual fix was applied to prod but the code fix is still in a PR,
  say so explicitly — this is a risk the team needs to track.

### Hyperlinks

Make references clickable using `<a href="...">`:
- Linear issues: `<a href="https://linear.app/makeitrain/issue/RAI-280">RAI-280</a>`
- Repo names: `<a href="https://github.com/ST0x-Technology/st0x.liquidity">st0x.liquidity</a>`
- PR references: `<a href="https://app.graphite.dev/github/pr/ST0x-Technology/st0x.liquidity/633">PR #633</a>`
  The Graphite URL pattern is: `https://app.graphite.dev/github/pr/<org>/<repo>/<number>`
- For repos, derive the GitHub org/repo from the git remote of each repo
  in `~/Github/`. The org is typically `ST0x-Technology` or `rainlanguage`.

### Emoji conventions

- 📋 Title
- 🚦 Status
- ✅ What Was Done
- 🔧 Bug fix / reliability theme
- 🏗 Architecture / infrastructure theme
- 🚀 Feature / capability theme
- 🧹 Cleanup / tech debt theme
- 📦 Other / miscellaneous theme
- ⚡ Action Items

Pick the most fitting emoji per theme (or use another relevant one if none
fits). Every `<b>` header gets an emoji prefix.

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
    'parse_mode': 'HTML',
    'disable_web_page_preview': 'true'
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
- `<a href="...">text</a>` for Linear issues and repo names (see
  Hyperlinks section above)
- `<code>text</code>` only for inline code (function names, endpoints,
  error messages) — NOT for repo names or issue IDs
- Plain `-` for bullets
- Link PRs to Graphite: `<a href="https://app.graphite.dev/github/pr/<org>/<repo>/<number>">PR #N</a>`
- No special escaping needed (except `<`, `>`, `&` which are rare in reports)

Do NOT save the report to a permanent file unless the user asks.

## Hard rules

1. Always use the local timezone for "today" — not UTC.
2. Never read more than 400 lines from any single session JSONL file (read
   first 200 + last 200). These files can be huge.
3. Thematic grouping over flat lists — cluster related work, never dump raw
   commit messages.
4. If `gh` or `linear` is not authenticated or fails, skip that section
   gracefully and note it in the report. For `linear`, fall back to
   extracting issue IDs from git commit messages and session data.
5. If no activity is found for the day, say so clearly — don't fabricate.
6. Include worktree activity — the user works across multiple worktrees of
   the same repo.
7. Keep the report concise: aim for one screen (40-60 lines).
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
    `<b>` for headers and theme names, `<a href>` links for Linear issues,
    repo names, and PR numbers (linking to Graphite), `<code>` only for
    inline code, and plain `-` for bullets.
13. **Production risk awareness**: Pay close attention to whether prod is
    currently functional or actively broken. Key signals from session data:
    crash-loops, error logs, manual restarts, "prod is down" mentions,
    events that trigger crashes repeatedly. If prod is actively crashing
    or down, Status is 🔴 — not 🟡. If a manual patch was applied but the
    root cause still triggers (e.g., a recurring event type that crashes
    the bot), prod is still 🔴 because it will crash again. Only use 🟡
    when prod is running but the fix is unmerged and the trigger is rare
    or unlikely. Never report a manual patch as "fixed" — it's "stabilized,
    fix pending in PR #X" (🟡) or "still crashing, fix in PR #X" (🔴).
14. **Cross-reference all data sources**: Don't report each agent's data in
    isolation. Connect Linear issues to PRs to git commits. If a Linear
    issue was completed but no corresponding PR appears, investigate. If a
    PR was merged but the corresponding Linear issue isn't marked done,
    note the discrepancy.
15. **State incident duration**: When a bug or outage is discovered, always
    state how long it lasted if the data is available (e.g., from log
    timestamps, git history, or session conversations).

## Failure modes

- **No sessions today**: Report says "No Claude Code sessions found for
  today" and proceeds with git/GitHub data only.
- **`gh` not authenticated**: Skip GitHub section, add a note: "GitHub
  activity skipped (gh not authenticated)".
- **`linear` not authenticated or fails**: Fall back to extracting issue
  IDs (e.g., `RAI-\d+`) from git commit messages and session text. Report
  these as "referenced issues" and note: "Linear CLI unavailable — issue
  statuses not verified."
- **No git repos found**: Report focuses on session activity only.
- **history.jsonl missing**: Fall back to scanning session JSONL files by
  modification date (`find ~/.claude/projects -name '*.jsonl' -newer
  <today-sentinel>`).

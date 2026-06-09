---
name: daily-report
description: "Use when the user asks to run the former Claude /daily-report workflow: Generate a team-facing daily summary of all work done across repos. For pasting in the group chat. Shows what was accomplished, what's next, open points, and stats."
---

# daily-report

Codex adaptation of the Claude slash command `daily-report`. Follow the
workflow below, but use Codex-native tools and normal user questions where
the original mentions Claude-only mechanisms.

Compatibility notes:
- Treat `$ARGUMENTS` as the relevant arguments or intent from the user's request.
- Ask the user a concise question directly when a decision is required.
- Run the collectors via Codex subagents in parallel when available;
  otherwise run them sequentially in the order given.
- When the workflow mentions another slash command, use the corresponding
  Codex skill or follow that workflow directly.

# Daily Report — end-of-day work summary

Generates a comprehensive daily report by aggregating Claude Code sessions,
Codex CLI sessions, git history, GitHub activity, Linear, investigation
traces, and Telegram conversations across all repos in `~/Github/`.

## Compressed mode

When invoked with the argument `compressed`, produce a much shorter report.
Still run all the same data collection (Steps 1–3), but in Step 5 compress
the output to ~10-15 lines max:

- Status section becomes 1 line (🟢/🟡/🔴 + one sentence)
- No Action Items section (unless 🔴 items exist)
- "What Was Done" becomes 3-5 one-line bullets (one per theme, no sub-bullets)
- "Continued / Refined" becomes a single line listing PR numbers touched
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

🔄 <b>Refined:</b> Restacked PRs #633–#635, addressed review feedback on PR #640

⚡ <b>Urgent</b>
- 🔴 Merge #642 — prod crashes on non-USDC TakeOrder events
```

Then review (Step 4), send via Telegram (Step 6), and save (Step 7) as
normal. If the argument is NOT "compressed", continue with the full report
flow below.

## Step 1 — Date anchors, pre-flight, and yesterday's report

### Date anchors — compute ONCE, then paste literals everywhere

Use local timezone. If the current local time is before 05:00, treat the
report as belonging to **yesterday** (the workday hasn't ended yet — the
user is still wrapping up the previous day's work).

```bash
current_hour=$(date +%H)
if [ "$current_hour" -lt 5 ]; then
  REPORT_DATE=$(date -v-1d +%Y-%m-%d)
  echo "Before 5 AM — reporting on previous day"
else
  REPORT_DATE=$(date +%Y-%m-%d)
fi
START_EPOCH_S=$(date -j -f "%Y-%m-%d %H:%M:%S" "$REPORT_DATE 00:00:00" +%s)
START_EPOCH_MS="${START_EPOCH_S}000"
START_UTC=$(date -j -u -r "$START_EPOCH_S" +%Y-%m-%dT%H:%M:%SZ)
PREV_DATE=$(date -j -v-1d -f "%Y-%m-%d" "$REPORT_DATE" +%Y-%m-%d)
NOW_EPOCH_S=$(date +%s)
CALENDAR_DATE=$(date +%Y-%m-%d)
echo "REPORT_DATE=$REPORT_DATE START_EPOCH_S=$START_EPOCH_S START_UTC=$START_UTC"
```

**Hard constraint**: every collector below receives these values as
LITERAL strings substituted into its instructions. Collectors must never
call `date` or `datetime.now()` themselves — a 1 AM run would otherwise
report the wrong day in every section. The local timezone is not UTC, so
GitHub timestamp comparisons must use `START_UTC`, not the local date
string.

### Pre-flight checks

Verify every external dependency up front so failures surface immediately
instead of as silently-empty report sections:

```bash
gh auth status >/dev/null 2>&1 && echo "gh: ok" || echo "gh: NOT AUTHENTICATED"
linear issue mine --no-pager >/dev/null 2>&1 && echo "linear: ok" || echo "linear: FAILED"
if ! command -v tdl >/dev/null; then echo "tdl: NOT INSTALLED"
elif ! tdl chat ls >/dev/null 2>&1; then echo "tdl: NOT LOGGED IN"
else echo "tdl: ok"; fi
[ -f ~/.config/daily-report-telegram-chats.txt ] && echo "tg chats: configured" || echo "tg chats: NO CONFIG"
```

- `gh` / `linear` failures: tell the user now; they can fix or accept the
  degraded report (see Failure modes).
- `tdl` not logged in: ask the user to run `tdl login` in a terminal,
  then re-check.
- Telegram chat config missing (but tdl ok): run `tdl chat ls`, show the
  chats, ask the user which are work-related, and write
  `~/.config/daily-report-telegram-chats.txt` — one chat per line (numeric
  ID or @username), `#` for comments. Do this NOW, not mid-collection.

### Load yesterday's report (continuity)

Reports are saved to `~/Github/dotagents/dotclaude/data/daily-report/reports/`
as `<date>.html` plus a `<date>.json` sidecar (see Step 7). Load the most
recent one before `REPORT_DATE`:

```bash
ls ~/Github/dotagents/dotclaude/data/daily-report/reports/*.json 2>/dev/null | sort | tail -3
```

Read the latest sidecar dated before `REPORT_DATE` (skip one equal to
`REPORT_DATE` — that's a re-run). It contains `status`, `action_items`,
`open_prs`, and `themes`. This feeds Step 4 (carried-over check) and
Step 5 (continued-vs-new classification, "did pending X ship?"). If no
prior report exists, note "first run — no continuity data" and move on.

## Step 2 — Discover sessions (inline, no agents)

Scan Claude Code history for the day's sessions — this is one cheap python
call, run it directly:

```bash
python3 -c "
import json
start_ts = $START_EPOCH_MS
sessions = {}
with open('$HOME/.claude/history.jsonl') as f:
    for line in f:
        try:
            entry = json.loads(line.strip())
        except json.JSONDecodeError:
            continue
        if entry.get('timestamp', 0) >= start_ts:
            sid = entry.get('sessionId', 'unknown')
            s = sessions.setdefault(sid, {'project': entry.get('project', 'unknown'), 'prompts': []})
            s['prompts'].append(entry.get('display', ''))
for sid, info in sessions.items():
    print(f'{sid}|{info[\"project\"]}|{len(info[\"prompts\"])}')
" 2>/dev/null
```

Then:

1. **Resolve session files by glob** — do NOT try to derive the
   dash-mangled project directory name (dots are mangled too, not just
   slashes): `ls ~/.claude/projects/*/<sessionId>.jsonl`
2. **Normalize project keys**: fold worktrees into their parent repo
   (`st0x.liquidity-worktrees/pale-quail` → `st0x.liquidity`).
3. **Group for fan-out**: one summarizer per project; merge projects that
   only had a single short session into one combined "misc" group. Cap at
   ~6 summarizer groups.
4. **Codex day directories**: `~/.codex/sessions/<YYYY>/<MM>/<DD>/` for
   `REPORT_DATE` — and ALSO for `CALENDAR_DATE` when the two differ (a
   post-midnight run must scan both).

## Step 3 — Collect (parallel where possible)

Run all collectors: the five fixed ones (git, Linear, GitHub, Codex,
Telegram) plus one session summarizer per project group from Step 2. Use
parallel subagents when available; otherwise run them sequentially —
either way, each collector follows its section below with the Step 1
literals substituted, and returns its findings as JSON in the stated
shape. Shape the *facts* (PR numbers, timestamps, issue IDs, ship status)
strictly so Step 5 can cross-reference mechanically — but keep narrative
fields free text; forcing the story into rigid enums is how the gist gets
lost.

Session/Codex collectors return:

```json
{"summaries": [{"project": "...", "goal": "...", "narrative": "...",
  "outcome": "...", "ship_status": "shipped|merged_undeployed|in_pr|in_progress|abandoned|ops_only|n/a",
  "incidents": ["..."], "unresolved": ["..."]}]}
```

Git: `{"repos": [{"repo", "branches": [...], "commits": [{"hash",
"subject", "committed_at"}]}], "traces": [{"slug", "status", "linear",
"latest"}]}`.
Linear: `{"issues": [{"id", "title", "state"}], "note": "..."}`.
GitHub: `{"opened"/"merged"/"reviewed": [{"repo", "number", "title",
"url", "created_at", "merged_at"}], "issues_closed": [...]}`.
Telegram: `{"decisions": [...], "asks": [{"ask", "from",
"addressed_guess"}], "incidents": [...], "commitments": [...],
"context": [...]}`.

A collector that fails means that source is unavailable (see Failure
modes) — never "no activity".

### Collector — Claude sessions (one per project group)

Each summarizer digests ONLY its own project's sessions (the project key
and session file paths from Step 2).

Session files are mostly tool-call noise; never read them raw. Extract
just the conversation — user messages and assistant text, skipping tool
results, system reminders, and sub-agent sidechains:

```bash
python3 -c "
import json, sys
msgs = []
with open(sys.argv[1]) as fh:
    for line in fh:
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get('isSidechain'):
            continue
        if e.get('type') not in ('user', 'assistant'):
            continue
        content = (e.get('message') or {}).get('content')
        if isinstance(content, str):
            parts = [content]
        elif isinstance(content, list):
            parts = [b.get('text', '') for b in content
                     if isinstance(b, dict) and b.get('type') == 'text']
        else:
            continue
        txt = ' '.join(p for p in parts if p).strip()
        if not txt or txt.startswith(('<system-reminder', '<command-name',
                '<local-command-stdout', '<task-notification', 'Caveat:')):
            continue
        msgs.append([e['type'], txt[:300]])
# Long sessions: keep ALL user messages (they mark every direction change)
# plus the assistant reply just before each, plus the final assistant
# message. Never blanket-elide the middle — that's where the pivots live.
if len(msgs) <= 120:
    keep = msgs
else:
    keep = []
    for i, m in enumerate(msgs):
        if m[0] == 'user':
            if i and msgs[i-1][0] == 'assistant' and (not keep or keep[-1] is not msgs[i-1]):
                keep.append(msgs[i-1])
            keep.append(m)
    if msgs[-1][0] == 'assistant' and (not keep or keep[-1] is not msgs[-1]):
        keep.append(msgs[-1])
for role, txt in keep:
    print(f'[{role}] {txt}')
" "$session_file"
```

The gist of a session usually lives in the MIDDLE of the conversation —
direction changes, discoveries, dead ends, fixes. Never summarize from the
opening request alone; long sessions often end up doing something different
from what they started with. Return one summary per session: goal, what
actually happened (narrative including pivots), outcome, ship_status,
incidents (prod outages, manual interventions, root causes and whether the
fix shipped or sits in a PR), and unresolved threads worth following up.

### Collector — Git activity + traces

This project uses Graphite (`gt`), which amends and rebases constantly.
`git log --since` filters on **committer date**, which DOES change on
amend/rebase — so a single pass catches restacks too. Worktrees share
refs with the main repo, so no separate worktree loop is needed (it would
only produce duplicates).

```bash
git_email=$(git config --global user.email)

for repo in ~/Github/*/; do
  if [[ "$repo" == *-worktrees* ]]; then continue; fi
  if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then continue; fi
  repo_name=$(basename "$repo")

  commits=$(git -C "$repo" log --all --since="REPORT_DATE 00:00" \
    --author="$git_email" --pretty=format:"%h|%s|%cI|%D" 2>/dev/null)

  # Belt-and-suspenders: reflog records today's branch-tip moves even when
  # committer dates were preserved (e.g. plain force-push)
  reflog=$(git -C "$repo" reflog --all --since="REPORT_DATE 00:00" \
    --format="%gd %gs" 2>/dev/null | \
    grep -E 'commit|rebase \(finish\)|reset' | head -20)

  if [ -n "$commits" ] || [ -n "$reflog" ]; then
    echo "### $repo_name"
    [ -n "$commits" ] && echo "$commits"
    [ -n "$reflog" ] && { echo "  reflog:"; echo "$reflog"; }
    echo ""
  fi
done
```

Also check investigation traces updated today (`~/Github/traces/*/TRACE.md`):

```bash
for trace_dir in ~/Github/traces/*/; do
  trace_file="$trace_dir/TRACE.md"
  [ -f "$trace_file" ] || continue
  mod_date=$(stat -f "%Sm" -t "%Y-%m-%d" "$trace_file" 2>/dev/null)
  if [ "$mod_date" = "REPORT_DATE" ]; then
    echo "### $(basename "$trace_dir")"
    grep -m1 '^status:' "$trace_file"
    grep -m1 '^linear:' "$trace_file"
    grep '^\- \*\*' "$trace_file" | tail -5
  fi
done
```

Traces represent multi-day investigations — report their status and latest
timeline entries so the synthesis can weave findings into themes.

### Collector — Linear activity

One query is a superset of completed/started/updated — run it once and
bucket by state locally:

```bash
linear issue mine --all-states --updated-after="REPORT_DATE" --sort priority --team RAI --no-pager 2>/dev/null
```

For the most relevant issues (up to 5), get full context with
`linear issue view <ID> --no-pager` — status transitions and comments
added today.

**Fallback if `linear` fails**: grep git commit messages and session data
for `RAI-\d+` patterns; report as "referenced issues (Linear CLI
unavailable)" in the `note` field. Better than silently dropping all
Linear context.

### Collector — GitHub activity

The local timezone is not UTC — always compare against `START_UTC`.
Search with a one-day-wider date window, then filter precisely in jq.
`gh search prs --merged` lags the real merge events, so query merged PRs
per-repo via `gh pr list` (real-time API). Include `createdAt` everywhere
so Step 5 can compute time-to-merge with zero extra `gh` calls.

```bash
gh_user=$(gh api user --jq '.login')

echo "### PRs opened"
gh search prs --author="$gh_user" --created=">=PREV_DATE" \
  --json title,url,repository,state,createdAt \
  --jq '.[] | select(.createdAt >= "START_UTC") | "\(.repository.nameWithOwner)|\(.title)|\(.state)|\(.createdAt)|\(.url)"' 2>/dev/null

echo "### PRs merged (per-repo, real-time)"
for repo in ~/Github/*/; do
  if [[ "$repo" == *-worktrees* ]]; then continue; fi
  if [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then continue; fi
  remote_url=$(git -C "$repo" remote get-url origin 2>/dev/null) || continue
  nwo=$(echo "$remote_url" | sed 's|\.git$||' | sed 's|.*[:/]\([^/]*/[^/]*\)$|\1|')
  [ -n "$nwo" ] || continue
  gh pr list --repo "$nwo" --author "$gh_user" --state merged \
    --json number,title,createdAt,mergedAt \
    --jq ".[] | select(.mergedAt >= \"START_UTC\") | \"$nwo|\(.number)|\(.title)|\(.createdAt)|\(.mergedAt)\"" 2>/dev/null
done

echo "### PRs reviewed (teammates' work — reviews are reportable work)"
gh search prs --reviewed-by="$gh_user" --updated=">=PREV_DATE" \
  --json title,url,repository,author \
  --jq ".[] | select(.author.login != \"$gh_user\") | \"\(.repository.nameWithOwner)|\(.title)|\(.url)\"" 2>/dev/null

echo "### Issues closed"
gh search issues --author="$gh_user" --closed=">=PREV_DATE" --json title,url,repository,closedAt \
  --jq '.[] | select(.closedAt >= "START_UTC") | "\(.repository.nameWithOwner)|\(.title)|\(.url)"' 2>/dev/null
```

The reviewed-by query is approximate (updated-by-anyone window) — when in
doubt whether the review actually happened today, check the PR's review
timestamps before including it.

### Collector — Codex CLI sessions

Codex stores conversations separately. Two stores:

1. `~/.codex/history.jsonl` — user prompts with `session_id`, `ts`
   (epoch **seconds**), `text`.
2. `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-*.jsonl` — full transcripts.

```bash
python3 -c "
import json
start_ts = START_EPOCH_S
sessions = {}
with open('$HOME/.codex/history.jsonl') as f:
    for line in f:
        try:
            entry = json.loads(line.strip())
        except json.JSONDecodeError:
            continue
        if entry.get('ts', 0) >= start_ts:
            sid = entry.get('session_id', 'unknown')
            sessions.setdefault(sid, []).append(entry.get('text', ''))
for sid, prompts in sessions.items():
    print(f'## Codex session {sid[:8]}... ({len(prompts)} prompts)')
    for p in prompts[:5]:
        if p and not p.startswith('/'):
            print(f'    - {p[:120]}')
" 2>/dev/null
```

Then read the rollout files in the day directories from Step 2 (both
directories when the report date differs from the calendar date). Each
rollout's first line is `session_meta` with `payload.cwd` (the repo). The
conversation is in `response_item` lines with `payload.type == "message"`.
These files are large — extract messages, don't cat:

```bash
for f in <each rollout file in the given day dirs>; do
  [ -f "$f" ] || continue
  python3 -c "
import json, sys
cwd = None
msgs = []
with open(sys.argv[1]) as fh:
    for line in fh:
        try: e = json.loads(line)
        except json.JSONDecodeError: continue
        if e.get('type') == 'session_meta':
            cwd = e.get('payload', {}).get('cwd')
        elif e.get('type') == 'response_item':
            p = e.get('payload', {})
            if p.get('type') == 'message' and p.get('role') in ('user', 'assistant'):
                parts = [c.get('text', '') for c in p.get('content', []) if isinstance(c, dict)]
                txt = ' '.join(t for t in parts if t).strip()
                if txt:
                    msgs.append((p['role'], txt[:200]))
print(f'### Codex: {cwd}')
for role, txt in msgs[:10]:
    print(f'  [{role}] {txt}')
print(f'  ... ({len(msgs)} messages total)')
" "$f"
done
```

Return the same per-session summaries as the Claude session collectors.
Do NOT separate "Claude work" from "Codex work" downstream — the team
cares about outcomes, not which tool produced them.

### Collector — Telegram conversations

A lot of work coordination happens in Telegram — decisions, requests from
teammates, incident chatter, commitments. Export today's messages from the
configured work chats via `tdl` and parse each export immediately (export
and parse must live in the same loop — variables set inside a piped
`while read` subshell don't survive it):

```bash
for chat in $(grep -v '^#' ~/.config/daily-report-telegram-chats.txt | grep -v '^$'); do
  out="/tmp/tg-export-$(echo "$chat" | tr -c 'A-Za-z0-9' '-').json"
  tdl chat export -c "$chat" -T time -i "START_EPOCH_S,NOW_EPOCH_S" \
    --all --with-content -o "$out" 2>/dev/null || { echo "export failed: $chat"; continue; }
  echo "=== $chat ==="
  python3 -c "
import json, sys
from datetime import datetime
data = json.load(open(sys.argv[1]))
for m in data.get('messages', []):
    txt = m.get('text') or m.get('content') or ''
    if not txt:
        continue
    ts = m.get('date')
    when = datetime.fromtimestamp(ts).strftime('%H:%M') if ts else '--:--'
    sender = m.get('from') or m.get('sender') or m.get('from_name') or '?'
    print(f'[{when}] {sender}: {str(txt)[:300]}')
" "$out"
done
```

If the parsed output looks wrong, inspect the export schema first
(`head -c 2000 "$out"`) and adapt the field names. From the messages,
extract:

- **Decisions made** (and by whom) that explain or redirect today's work
- **Asks directed at the user** — with a guess whether they were addressed
- **Incidents discussed** — corroborate with session/git data
- **Commitments the user made** ("I'll ship X tomorrow") → Action Items
- **Context** that explains *why* work happened, which sessions alone miss

## Step 4 — User review before writing

Once all collectors return, compile a short summary and present it to the
user for review. This lets the user correct emphasis, flag misses, or add
context the data can't show ("prod is currently down", "this issue is the
most important one").

```
Here's what I found for today's report:

🚦 Status: [your best guess — 🟢/🟡/🔴 + why]

Proposed themes:
- Prod incident: crash-loop, manual SQL patch, PR #642 pending
- Orphaned order fix: RKLB stuck, recovery merged (PR #640)
- Issuance: stuck mint recovered, PR #145 open
- Dashboard + cleanup: PRs #633–635 merged, Schwab/Alpaca removal done

Linear: 7 completed, 3 started
PRs: 4 opened, 4 merged, 2 reviewed

⏮ From yesterday: 2 of 3 action items addressed (#642 merged ✅);
"deploy hedge config" still open — carrying it forward.

💬 Telegram asks: Josh asked for the redemption fix by EOW — matching
work found (PR #641). Dan asked about the dashboard numbers — NO matching
work today; flag as open?

Are these the main things to talk about? Any corrections on status,
emphasis, or things I missed?
```

Also check PR↔issue coverage: for every PR opened or merged today, check
whether its title or body contains a `RAI-\d+` reference. Flag PRs missing
one:

```
⚠️ PRs without a Linear issue:
- PR #145 (st0x.issuance) — enhance /admin/stuck endpoint
  → Want me to create a Linear issue and link it?
```

If yes, create it via the `linear` CLI (follow the linear-cli skill rules
— draft, show, confirm, create), then update the PR description with the
new issue ID. Do this before Step 5.

The user's feedback overrides your inferences ("prod is down" → 🔴; "the
issuance fix is most important" → lead with it). Only proceed after the
user confirms. In compressed mode, still review but keep it shorter.

## Step 5 — Synthesize the report

This is the most important step — you are not just listing outputs, you
are **connecting dots across data sources** to tell a coherent story.

### Synthesis rules

Before writing, answer from the collected data (and Step 4 corrections):

1. **System health**: Is anything broken, degraded, or at risk in
   production right now? Was there an incident today? Fully resolved (code
   deployed) or only manually patched (fix still in PR)?
2. **Impact & duration**: How long did an outage or blind spot last?
   Business impact (assets not hedged, funds stuck, users affected)?
3. **Ship status** per piece of work:
   - ✅ Merged and deployed to prod
   - 🟡 Merged to main (not yet deployed)
   - 🟠 PR open, in review
   - 🔴 PR open, blocked (CI failing, review requested changes)
   - 🩹 Manually patched in prod (code fix not yet merged)
4. **Completeness**: Cross-reference Linear issues against commits and
   PRs. Completed issues must appear as work; commit-referenced issue IDs
   missing from Linear data still get included.
5. **Continuity**: For every item in yesterday's `action_items` and
   `open_prs`, state what happened — shipped, progressed, or untouched.
   "Yesterday I said X was pending — did it ship?" is the single thing a
   manager most wants answered. Unaddressed items carry forward into
   today's Action Items marked as carried over.
6. **Telegram asks**: For each ask directed at the user, state whether
   today's work addressed it. Unaddressed asks become Action Items.

### Classifying work: new vs continued

- **New today**: PR with `created_at >= START_UTC`, new branch with first
  commit today, Linear issue created today, incident discovered today.
- **Continued / refined**: PR in yesterday's `open_prs` sidecar or with
  `created_at < START_UTC` — amended, restacked, or review feedback
  addressed today. In-progress Linear issue that just moved state.

The collected `created_at` fields and yesterday's sidecar answer this
without any extra `gh` calls. For work without a PR (prod ops, config
changes), judge from session context.

### Report structure

```
Logging off for the day. @highonhopium_josh @dcatki

📋 <b>Daily Report — {date}</b>

🚦 <b>Status</b>
{1-3 lines. Traffic light: 🟢 all systems healthy | 🟡 degraded or
at-risk | 🔴 prod down or critical issue. State what's wrong and what
needs to happen. If all green, say so in one line.}

✅ <b>What Was Done</b>

{Thematic groups for work NEWLY started or created today. Each theme gets
an emoji + bold name + repo link. 2-4 bullets per theme. Lead with OUTCOME
not activity. Include root causes for bugs, duration for incidents, and
deployment state for fixes. Reviews of teammates' PRs count as work.}

🔄 <b>Continued / Refined</b>

{Work on PRs or branches that existed before today. One bullet per
PR/branch, stating what changed ("addressed review feedback", "restacked
on latest main", "fixed CI failures"). Close the loop on yesterday's
pending items here or in Status.}

⚡ <b>Action Items</b>
{Priority-ordered. Markers:
- 🔴 Urgent — prod at risk, blocks others, time-sensitive
- 🟡 Important — should happen soon but not critical
- 🟢 Normal — review, cleanup, follow-up
Mark items carried over from a previous day as such.}

📊 <b>Stats</b>
- <b>PRs opened:</b> {n} — list each with repo
- <b>PRs merged:</b> {n} — list each with time-to-merge (e.g., "PR #640
  (7h)"), computed from the collected created_at→merged_at
- <b>PRs reviewed:</b> {n} (teammates' PRs)
- <b>Linear issues:</b> {n} completed · {n} started · {n} created
- <b>PR↔issue coverage:</b> {n}/{total} PRs have a linked Linear issue
  (a RAI-\d+ in title or body); flag the rest
- <b>Lines changed:</b> +{ins} / -{del} (aggregate, from git log
  --shortstat for commits authored today)
- <b>Repos touched:</b> {n} — list repo names with links
```

### Theme guidelines

- Group by **outcome**, not by repo or activity type. "Dashboard accuracy
  improvements" is better than "PRs #633, #634, #635 merged."
- Lead each bullet with what changed for the user/system, then the how.
  "Hedging now covers QQQM, VWO, ARKK — added to prod config" not
  "Added QQQM, VWO, ARKK to prod config."
- Include root causes for bugs — a manager needs to know if this is a
  one-off or systemic.
- State incident duration when known: "PPLT/SIVR/IAU had no hedging
  coverage for 12 days (Apr 24 – May 6)" not just "WebSocket stream died."
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

- 📋 Title · 🚦 Status · ✅ What Was Done · 🔄 Continued / Refined
- 🔧 Bug fix / reliability theme · 🏗 Architecture / infrastructure theme
- 🚀 Feature / capability theme · 🧹 Cleanup / tech debt theme
- 📦 Other / miscellaneous theme · ⚡ Action Items

Pick the most fitting emoji per theme (or another relevant one). Every
`<b>` header gets an emoji prefix.

## Step 6 — Confirm, then send via Telegram

Send to the user's Telegram "Saved Messages" via the bot API. Credentials
in `~/.config/telegram-bot.env` (`export TELEGRAM_BOT_TOKEN=...` and
`export TELEGRAM_CHAT_ID=...`).

1. Write the report to `/tmp/daily-report-1.txt` using Telegram HTML
   formatting. **Escape literal `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`
   in all non-tag text** (error messages and code like `Vec<u8>` will
   otherwise 400 the whole send).
2. If the report exceeds ~4000 characters (Telegram's limit is 4096),
   split on section boundaries into `/tmp/daily-report-2.txt` etc.
3. **Always show the full message and wait for explicit confirmation
   before sending.** Print the complete report inline exactly as it will
   appear, then ask the user directly to approve or request changes and
   wait for a clear yes. Do NOT send until explicitly approved this run.
   If they request changes, edit, re-show, re-ask. This applies in
   compressed mode too.
4. Once approved, send each part in order:

```bash
source ~/.config/telegram-bot.env
for part in /tmp/daily-report-*.txt; do
python3 -c "
import os, sys, urllib.request, urllib.parse, json

with open(sys.argv[1]) as f:
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
    print('Sent: ' + sys.argv[1])
else:
    print(f'Telegram error: {resp}')
" "$part"
done
```

5. On an HTML-parse 400, show the exact Telegram error, fix the offending
   entity, and re-confirm — or offer a plain-text resend (drop
   `parse_mode`). Never retry blind: each successful send is permanent.
6. Print a brief confirmation ("Report sent to Telegram Saved Messages.").

### Telegram HTML formatting rules

Use Telegram's HTML parse mode — more reliable than MarkdownV2:
- `<b>text</b>` for section headers and theme names
- `<a href="...">text</a>` for Linear issues and repo names (see
  Hyperlinks above)
- `<code>text</code>` only for inline code (function names, endpoints,
  error messages) — NOT for repo names or issue IDs
- Plain `-` for bullets
- Link PRs to Graphite: `<a href="https://app.graphite.dev/github/pr/<org>/<repo>/<number>">PR #N</a>`
- Escape literal `&`, `<`, `>` in text as HTML entities

## Step 7 — Save the report

After a successful send, persist for tomorrow's continuity:

```bash
mkdir -p ~/Github/dotagents/dotclaude/data/daily-report/reports
```

1. Save the exact sent message(s) to
   `~/Github/dotagents/dotclaude/data/daily-report/reports/<REPORT_DATE>.html`
2. Write the sidecar
   `~/Github/dotagents/dotclaude/data/daily-report/reports/<REPORT_DATE>.json`:

```json
{
  "date": "<REPORT_DATE>",
  "status": "🟡 prod patched, fix in PR #642",
  "action_items": [
    {"text": "Merge #642 — prod crashes on non-USDC TakeOrder", "severity": "urgent", "carried_over": false}
  ],
  "open_prs": [{"repo": "st0x.liquidity", "number": 642, "title": "..."}],
  "themes": ["Prod crash-loop fix", "Issuance recovery"]
}
```

If a report for the same date exists, overwrite it (it's a re-run).
Confirm: `Report saved: .../reports/<REPORT_DATE>.html (+ sidecar)`.

## Hard rules

1. **One set of date anchors**: compute `REPORT_DATE` / `START_EPOCH_S` /
   `START_EPOCH_MS` / `START_UTC` / `PREV_DATE` once in Step 1 and
   substitute literals into every collector. Collectors never call `date`
   or `datetime.now()`. Local timezone for "today"; `START_UTC` for any
   GitHub timestamp comparison.
2. Never read session JSONL files raw — they are huge and mostly tool-call
   noise. Always use the message extractor; for long sessions keep all
   user messages (plus adjacent assistant replies), never blanket-elide
   the middle.
3. Thematic grouping over flat lists — cluster related work, never dump
   raw commit messages.
4. If `gh` or `linear` fails pre-flight, tell the user immediately; if
   they proceed, skip that section gracefully and note it in the report.
   For `linear`, fall back to extracting `RAI-\d+` IDs from commits and
   sessions.
5. If no activity is found for the day, say so clearly — don't fabricate.
6. Worktree sessions and branches belong to their parent repo — fold
   `<repo>-worktrees/<name>` into `<repo>` everywhere. No separate
   worktree git scan (worktrees share refs with the main checkout).
7. Keep the report concise: aim for one screen (40-60 lines).
8. Write the entire report in first person ("I fixed...",
   "I investigated...") — it's pasted directly into a team group chat.
9. Never mention internal tooling or process in the output: Claude Code
   sessions, Codex CLI sessions, JSONL files, AI tooling, Telegram
   exports, traces, cross-reviews, feedback-reviews, review loops, slash
   commands, skills, sub-agents, or any other implementation detail.
   These are input sources — the team only cares about outcomes. Write
   *what* was done and *why*, never *how* ("addressed PR review comments"
   not "ran the feedback-review skill").
10. Always include Linear issue IDs (e.g., RAI-280) when referencing
    tickets.
11. If investigation traces were updated today, weave the findings into
    the relevant theme naturally ("Root-caused the Fireblocks timeout —
    ..."). Never use the word "trace" in the output.
12. The report is sent via Telegram bot using HTML parse mode: `<b>` for
    headers, `<a href>` links for Linear issues / repos / PRs (Graphite),
    `<code>` only for inline code, plain `-` bullets, entities for
    literal `&` `<` `>`.
13. **Production risk awareness**: if prod is actively crashing or down,
    Status is 🔴 — not 🟡. If a manual patch was applied but the root
    cause still triggers, prod is still 🔴 because it will crash again.
    Only use 🟡 when prod runs and the trigger is rare. Never report a
    manual patch as "fixed" — it's "stabilized, fix pending in PR #X".
14. **Cross-reference all data sources**: connect Linear issues to PRs to
    commits to Telegram asks. Completed issue with no PR → investigate.
    Merged PR with issue not marked done → note the discrepancy.
15. **State incident duration** whenever the data allows (log timestamps,
    git history, session conversations).
16. **Never send before approval**: show the full composed message and get
    an explicit "send it" on every run, including compressed mode. The
    send is irreversible.
17. **Telegram is context, not content**: Telegram messages inform the
    synthesis (decisions, asks, incidents, commitments) but are never
    quoted verbatim or attributed to teammates in the report.
18. **Always save the report + sidecar** (Step 7) after a successful send
    — tomorrow's report depends on it.

## Failure modes

- **No Claude sessions today**: proceed with the other collectors; say so
  in the Step 4 summary.
- **No Codex sessions today** (or `~/.codex/` missing): skip silently.
- **`gh` not authenticated**: caught in pre-flight; if proceeding, note
  "GitHub activity skipped (gh not authenticated)".
- **`linear` fails**: fall back to `RAI-\d+` extraction from commits and
  sessions; note "Linear CLI unavailable — issue statuses not verified."
- **`tdl` not installed**: skip Telegram; note "Telegram context skipped
  (tdl not installed — add it via nix-darwin and run `tdl login`)."
- **`tdl` not logged in**: caught in pre-flight; ask the user to run
  `tdl login` in a terminal, re-check, otherwise skip Telegram.
- **Telegram chat config missing**: pre-flight runs `tdl chat ls`, asks
  the user which chats are work-related, writes
  `~/.config/daily-report-telegram-chats.txt`, then proceeds.
- **A collector fails**: treat that source as unavailable and note it —
  never as "no activity".
- **No prior report sidecar**: first run — skip continuity, note it.
- **history.jsonl missing**: fall back to scanning session JSONL files by
  modification date (`find ~/.claude/projects -name '*.jsonl' -newer
  <today-sentinel>`).

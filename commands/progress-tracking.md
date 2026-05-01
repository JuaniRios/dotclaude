---
allowed-tools: Bash(linear:*), Bash(git:*), Bash(gh:*), Bash(cat:*), Bash(date:*), Bash(jq:*), Read, Write, Grep, Glob
description: Gather progress on a project (e.g. hedge-bot) from Linear issues, GitHub PRs, and git history since the last run or a custom time range. Outputs an investor-facing summary and saves it to disk.
argument-hint: <project> [since <timeframe>]
---

# Progress tracking

Compile a progress report for a project by pulling from Linear issues and
git history. The report covers everything since the last time this command
was run, or since a user-specified time range.

## Step 1 — Parse arguments

The argument is: `<project> [since <timeframe>]`

Examples:
- `hedge-bot` — since last run
- `hedge-bot since last week` — override: last 7 days
- `hedge-bot since last 10 days` — override: last 10 days
- `hedge-bot since 2026-04-01` — override: specific date

Extract:
1. **Project name** — the first word (e.g., `hedge-bot`)
2. **Time override** — everything after `since` (optional)

If no project name is provided, default to `hedge-bot`.

## Step 2 — Load config and determine date range

Read the config file:

```bash
cat ~/Github/dotclaude/data/progress-tracking.json
```

Look up the project by name. If the project isn't found, tell the user
and list available projects.

Determine the "since" date:
- If the user provided a `since` override, parse it into a date. Use
  `date` to resolve relative expressions (e.g., "last week" → 7 days ago,
  "last 10 days" → 10 days ago, or a literal ISO date).
- If no override, use `last_run` from the config. If `last_run` is null
  (first run), default to 14 days ago and tell the user.

Store the resolved date as an ISO 8601 string for use in queries.

## Step 3 — Fetch git history

Run git log on the project's repo:

```bash
git -C <repo_path> log --since="<date>" --format="%h %ad %s" --date=short --all
```

Also get a summary of files changed:

```bash
git -C <repo_path> log --since="<date>" --format="" --shortstat --all | tail -5
```

If the repo path starts with `~`, expand it. Collect all commits — these
will go into the report.

## Step 3b — Fetch GitHub PRs

PRs often contain richer descriptions than commit messages or Linear
issues. Fetch both merged and open PRs from the repo:

```bash
cd <repo_path>

# Merged PRs in the date range
gh pr list --state merged --search "merged:>=<date>" \
  --json number,title,author,mergedAt,body,labels,url --limit 100

# Open PRs (in review / in progress)
gh pr list --state open \
  --json number,title,author,createdAt,body,url --limit 50
```

PR descriptions are a primary source for the executive summary — they
explain the *why* and *impact* in ways that commit messages and issue
titles often don't. When writing the summary, prefer PR descriptions
over issue titles for understanding what was actually accomplished.

Also use PRs to catch work that has no Linear issue attached. A merged
PR without a linked issue still represents real progress that should
appear in the report.

## Step 4 — Fetch Linear issues

**Important**: Use `linear issue query`, not `linear issue list`. The `list`
subcommand does not support `--json` output or date-based sorting. Only
`query` supports `--json`, `--updated-after`, and `--no-pager`.

Fetch all issues from the team updated in the date range:

```bash
linear issue query --team <team> --updated-after <date> --json --limit 0 --no-pager
```

This returns structured JSON with all issue metadata (title, state,
project, milestone, assignee, labels, updatedAt, etc.).

Then, for each candidate issue, if you need the full description (not
included in query output), fetch it:

```bash
linear issue view <ID> --json
```

Read the description and metadata of each issue.

## Step 4b — Fetch Linear milestones

For each relevant Linear project, fetch the milestone structure to
understand the planned roadmap and current phase:

```bash
linear project list --json --no-pager  # find project IDs
linear milestone list --project "<project name>" --json --no-pager
```

Note which milestones are completed, which is active, and what's coming
next. This is essential for placing the period's work in context and for
writing an accurate "coming next" section.

## Step 5 — Filter issues by relevance

For each issue, decide whether it's relevant to the project based on:

1. **Project context** from the config (e.g., for hedge-bot: liquidity bot,
   hedging, rebalancing, vaults, Raindex, Alpaca, order strategies,
   staging/prod deployment)
2. **Issue description** — does it mention components, features, or bugs
   related to this project?
3. **Labels and Linear project assignment** — if assigned to a matching
   Linear project, include it
4. **Common sense** — an issue about "website redesign" is not hedge-bot;
   an issue about "fix hedging gap calculation" is

Classify each issue as:
- **INCLUDED** — relevant to the project
- **EXCLUDED** — not relevant (note the reason)

## Step 6 — Compile the report

Structure the report as markdown, ready to copy-paste.

The report has two distinct audiences and sections:

### Section 1: Executive Summary (investor-facing)

This is the most important part of the report. It will be sent to
investors to communicate progress, justify timelines, and build
confidence. Write it as a standalone narrative — someone should be able
to read only this section and fully understand what happened.

**Tone**: professional, confident, specific. Not overly technical but not
dumbed down. Use domain terms investors would know (hedging, rebalancing,
deployment infrastructure) but explain system internals in plain English.
Avoid jargon like "projection views", "optimistic lock conflicts", or
"apalis jobs" — translate these into what they mean for the product.

**Before writing the summary**, fetch Linear project milestones to
understand the planned roadmap:

```bash
linear milestone list --project "<project name>" --json
```

Run this for each relevant Linear project (e.g., "Live MVP of st0x.liquidity bot",
"Robust liquidity management with auto-recovery"). Milestones define the
intended sequencing — use them to understand what phase the team is in
and what the next milestone is.

Also look at all **Todo** and **Backlog** issues (not just In Progress /
In Review) to identify the forward workplan. From these, determine:
- What's on the **critical path** to the next milestone?
- What's running in **parallel** and not blocking anything?
- What's **background / whenever** with no immediate deadline?

Be precise about sequencing — don't imply something is a prerequisite
if it isn't. If two workstreams are parallel and independent, say so
explicitly.

**Structure the summary as**:
1. **Opening paragraph** — what the team focused on this period and why.
   Frame the work in terms of product goals (e.g., "production readiness",
   "risk reduction", "operational reliability") not just tickets closed.
2. **Key accomplishments** — 3-5 bullet points, each 1-2 sentences.
   Lead with the business impact, then briefly mention what was done
   technically. E.g., "Eliminated a class of stuck-transfer failures that
   could block rebalancing indefinitely — added timeout-based recovery so
   the system self-heals without manual intervention."
3. **What's in progress / coming next** — Derive a clear workplan from
   the milestone structure, Todo/Backlog issues, and open PRs. Distinguish
   explicitly between: (a) what's on the critical path to the next
   milestone, (b) what's running in parallel and not blocking, and (c)
   what's deferred / background. Don't guess at sequencing — use the
   milestone and issue data to reason about it. Frame delays honestly but
   constructively.
4. **Team output stats** — one line with commit count, contributors, and
   issues completed. Demonstrates velocity without belaboring it.

**Do**:
- Quantify where possible (N issues completed, N bugs fixed, N contributors)
- Explain *why* work matters, not just *what* was done
- Be honest about challenges — investors respect transparency
- Group related work into themes rather than listing individual tickets
- If there were delays or scope changes, explain the root cause and how
  the team adapted

**Don't**:
- Use passive voice ("issues were resolved") — use active voice
  ("the team resolved", "we shipped")
- Minimize the work — if a bug fix took a week because it was genuinely
  hard, say why it was hard
- Include issue IDs or Git SHAs in the summary — those go in the
  detailed sections below
- Pad with filler — every sentence should carry information

### Section 2: Detailed breakdown (reference / appendix)

After the summary, include the full technical detail for the team's own
reference and for investors who want to drill down:

```markdown
# Progress Report: <project>
**Period**: <since_date> to <today>
**Generated**: <today datetime>

## Summary

<executive summary as described above — multiple paragraphs>

---

## Detailed Breakdown

### Linear Issues

#### Completed
- **<ID>**: <title> — <one-line summary of what was done>

#### In Progress
- **<ID>**: <title> — <current status / what remains>

#### In Review
- **<ID>**: <title> — <what this is about>

#### Upcoming
- **<ID>**: <title> — <what this is about>

#### Backlog (relevant)
- **<ID>**: <title>

### Git Activity
- **<N> commits** across the period
- Key changes:
  - <grouped summary of commits by area/feature>

### Excluded Issues (for review)
These RAI issues were updated in the period but deemed unrelated:
- **<ID>**: <title> — reason: <why excluded>

---
*Generated by /progress-tracking*
```

Adapt the sections based on what's actually there — omit empty sections.
Keep descriptions concise. Group related commits rather than listing every
single one.

## Step 7 — Output and save

1. **Print the full report** as text output so the user can read and
   copy-paste it.

2. **Save the report** to disk:

   ```bash
   # File: ~/Github/dotclaude/data/progress-tracking/reports/<project>-<YYYY-MM-DD>.md
   ```

   Use `Write` to save the report. If a report for the same project and
   date already exists, overwrite it (it's a re-run).

3. **Update the last-run timestamp** in the config:

   ```bash
   # Read, update last_run to current ISO datetime, write back
   ```

   Read `~/Github/dotclaude/data/progress-tracking.json`, update the
   project's `last_run` to the current datetime (ISO 8601), and write it
   back using `Write`.

4. **Confirm**:

   ```
   Report saved: ~/Github/dotclaude/data/progress-tracking/reports/<project>-<date>.md
   Last run updated to: <datetime>
   ```

## Hard rules

1. **Never modify the repo or Linear issues** — this is read-only.
2. **Always show excluded issues** — the user needs to verify filtering.
3. **Always save the report to disk** before finishing.
4. **Always update last_run** after a successful run.
5. **Use `--json` for Linear queries** — parse structured data, don't
   scrape human-readable output.
6. **Expand `~` in repo paths** before passing to git commands.
7. If Linear or git commands fail, report what you could gather and note
   what was unavailable — don't fail silently.

## Failure modes

- **Linear auth expired**: tell the user to run `linear auth login`.
- **Repo path doesn't exist**: tell the user and suggest updating the
  config file at `~/Github/dotclaude/data/progress-tracking.json`.
- **No issues found**: report git activity only, note no Linear activity.
- **No commits found**: report Linear activity only, note no git activity.
- **First run (last_run is null)**: default to 14 days, tell the user.

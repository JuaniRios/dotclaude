---
allowed-tools: Bash(staging-status:*), Bash(prod-status:*), Bash(sqlite3:*), Bash(ls:*), Bash(find:*), Bash(wc:*), Bash(tail:*), Bash(head:*), Read, Grep, Glob
description: Run `staging-status` or `prod-status`, read downloaded logs/DB/trades, and diagnose whether the liquidity bot is healthy — hedging, rebalancing, errors, and overall status.
argument-hint: <prod|staging>
---

**Required argument**: `prod` or `staging`. This determines which environment
to check and which status command to run.

If the argument is missing or not one of `prod`/`staging`, tell the user:
"Usage: `/check-liquidity-bot <prod|staging>`" — and stop.

Set the status command based on the argument:
- `staging` → `staging-status`
- `prod` → `prod-status`

Run the chosen command to fetch live data from the server, then analyze the
downloaded artifacts to produce a health report.

## 1. Run status command

```bash
<staging-status or prod-status>
```

Use a long timeout (300000ms / 5 minutes) -- the script SSHes into the server,
queries the subgraph, downloads the DB (~100MB) and logs.

**CRITICAL: After the command completes, you MUST paste the ENTIRE raw
terminal output to the user inside a single code block, character for
character, before doing anything else.** Do NOT summarize, paraphrase,
reformat, bullet-point, or abridge the output in any way. The user needs
the exact text that the status command printed -- copy-paste it as-is into
a ```text code block. Only after showing the full raw output may you
proceed with the automated analysis below.

If the command fails:
- **"op" / 1Password errors**: Ask the user if they need to pass `--op` flags
  or set `SSH_IDENTITY`.
- **SSH connection refused**: Ask the user to check Tailscale
  (`tailscale status`) or provide the identity file path.
- **Permission denied**: Ask the user to verify SSH key access to the staging
  server.

Do not guess credentials or identities. Ask the user and wait.

## 2. Locate the output directory

The script saves everything under `./claude-local-ctx/<timestamp>-<status>/`.
Find the most recent one:

```bash
ls -td ./claude-local-ctx/*/ | head -1
```

The directory name ends with `running` or `stopped`. Note this for the report.

Expected files:
- `logs.txt` -- full journalctl output from the bot service
- `st0x-hedge.db` -- SQLite database snapshot (~100MB, query with sqlite3)
- `raindex-orders-decoded.json` -- Raindex open orders with decoded float values
- `trades_*.csv` -- trade history CSVs per order (columns: timestamp, datetime,
  block_number, tx_hash, input_symbol, input_amount, output_symbol, output_amount)
- `trades_*.json` -- raw trade history JSON per order

## 3. Analyze bot status

Work through each section below. Use `sqlite3` for all DB queries (never
`Read` on the .db file). Use `Read` for logs, JSON, and CSV files.

### 3a. Service health

From the directory name, determine if the bot is `running` or `stopped`.
If stopped, this is the most critical finding -- lead the report with it.

### 3b. Logs analysis

Read the logs file (`logs.txt`). It can be large, so focus on:

- **Recent errors/warnings**: grep for `ERROR` and `WARN` in the last ~500
  lines. Categorize them:
  - Transient network issues (RPC timeouts, subgraph errors) -- usually OK
  - Logic bugs or unexpected states -- critical
  - Panics (`panic`, `thread.*panicked`) -- critical, means crash
- **Restart loops**: look for repeated "Started st0x" or "Initializing" entries
  in quick succession -- suggests crash loops.
- **Last activity timestamp**: find the most recent log line. If the bot is
  "running" but the last log is hours old, it may be hung.
- **Market hours context**: during market close (nights, weekends), reduced
  offchain activity is normal. Note this if relevant.

### 3c. Hedging analysis

Query the downloaded DB for offchain orders:

```bash
sqlite3 <db_path> "SELECT view_id, status, payload FROM offchain_order_view ORDER BY rowid DESC LIMIT 30;"
```

Check:
- **Are offchain orders being placed?** If onchain trades are happening but no
  offchain orders exist, hedging is broken.
- **Order success rate**: count Filled vs Failed vs Pending. A high failure
  rate indicates a problem.
- **Failed order patterns**: extract error messages from Failed orders. Common
  issues:
  - "insufficient buying power" -- account is underfunded for the trade size
  - "market is closed" -- bot tried to hedge outside market hours
  - Auth/permission errors -- credential issues
  - If the same error repeats many times in a row, flag it prominently.
- **Hedging gaps**: compare onchain trade timestamps against offchain order
  timestamps. Every onchain trade should have a corresponding offchain hedge
  placed shortly after. Large gaps (e.g., many onchain trades over hours with
  no offchain activity) mean hedging fell behind.
- **Direction correctness**: onchain buys should produce offchain sells and
  vice versa. Flag any mismatch.
- **Post-deploy hedging**: if the bot was recently redeployed, check whether
  hedging resumed immediately. A deploy that doesn't produce offchain orders
  for existing onchain activity is suspicious.

Also check event type distribution:

```bash
sqlite3 <db_path> "SELECT event_type, COUNT(*) as cnt FROM events GROUP BY event_type ORDER BY cnt DESC;"
```

### 3d. Inventory and position analysis

```bash
sqlite3 <db_path> "SELECT * FROM position_view;"
```

Check:
- **Net position**: should be near zero if hedging is working. A large absolute
  net position means delta exposure is building up unhedged.
- **Inventory snapshot freshness**: the status output shows snapshot timestamps.
  If they are stale (more than ~30 minutes old while bot is running), the
  inventory polling loop may have stopped.
- **Onchain vs offchain balance**: note the split. Large imbalances may be
  intentional (vault funding) or may indicate rebalancing issues.

### 3e. Rebalancing analysis

The status output shows whether rebalancing is enabled or disabled per asset.

If rebalancing is **enabled** for any asset:
- Query for rebalancing events:
  ```bash
  sqlite3 <db_path> "SELECT event_type, payload FROM events WHERE event_type LIKE '%Rebalanc%' ORDER BY rowid DESC LIMIT 20;"
  ```
- Grep logs for `rebalanc` (case-insensitive) to find rebalancing activity.
- Check if vault balances are being maintained within expected ranges.
- Look for rebalancing errors or failures.

If rebalancing is **disabled** for all assets, note it briefly and skip
detailed analysis.

### 3f. Raindex orders analysis

Read `raindex-orders-decoded.json`:
- **Active order count**: zero means the bot has no onchain presence.
- **Vault balances**: check if decoded values are present or still raw hex.
  Raw hex (long `0xffffff...` strings) means the decode-floats binary wasn't
  available -- note this limitation.
- **Trade activity**: use the trades CSVs to check:
  - Total trade count per order
  - Most recent trade timestamp -- is the bot actively being matched?
  - Trade frequency -- are trades happening regularly or in bursts?
  - Any orders with zero trades may be misconfigured or have empty vaults.

## 4. Produce the health report

Structure the report as:

1. **Overall verdict**: one line -- Healthy / Degraded / Critical
2. **Service**: running/stopped, uptime since last start, deployed version
3. **Hedging**: working/broken/degraded, success rate, any error patterns,
   hedging gaps
4. **Rebalancing**: enabled/disabled, working/broken (if enabled)
5. **Inventory**: net position, snapshot freshness, balance overview
6. **Onchain activity**: active orders, trade frequency, vault balances
7. **Issues found**: ranked by severity (CRITICAL > WARNING > INFO).
   For each issue, use this structured format so the user can copy-paste
   it directly to their team channel:

   ### `<Short issue name>`

   **What it does**: What the component/subsystem is supposed to do.

   **How it's erroring**: The exact error message pattern, how frequently
   it occurs, and where it appears (log source, DB status, etc.).

   **Why it errors**: Root cause or most likely explanation based on the
   data available.

   **Impact**: Whether it affects bot operation (trading, hedging,
   rebalancing) or is purely noise/observability. Be definitive -- say
   "None" if there's no operational impact, not "probably fine."

   Severity categories for reference:
   - CRITICAL: bot stopped, panics, total hedging failure, crash loops
   - WARNING: repeated failed orders, hedging gaps, stale snapshots,
     growing net position
   - INFO: minor transient errors, expected market-hours gaps

Be direct. If everything is healthy, say so in 3-4 lines. Don't pad. If there
are problems, lead with the worst ones and be specific about what's wrong and
what to do.

## Hard rules

1. Never modify any files -- this is a read-only diagnostic command.
2. Never run `cargo run` or start any services.
3. Never read secret files (`.env`, credentials, keys) -- work only with the
   artifacts `staging-status` downloads.
4. If the status command cannot run, help the user fix the issue (SSH, identity,
   Tailscale) -- do not skip it and try to SSH manually.
5. Always use the most recent `claude-local-ctx` directory, not stale ones.
6. Report findings honestly -- don't minimize issues or speculate beyond what
   the data shows.
7. Never use `Read` on the `.db` file -- always use `sqlite3` queries.

## Failure modes

- **Status command hangs**: the SSH connection or subgraph query may be slow.
  Wait the full 5-minute timeout before reporting.
- **No DB downloaded**: the DB download sometimes fails. Report what you can
  from logs and orders alone, and note the DB was unavailable.
- **No logs downloaded**: same -- report from DB and orders, note logs were
  unavailable.
- **Empty DB / no events**: the bot may have just been deployed or the DB may
  have been reset. Note this rather than reporting "everything is broken."
- **decode-floats not available**: vault balances may show as raw hex. Note
  this in the report -- it doesn't mean the bot is broken, just that the
  display couldn't decode the values.

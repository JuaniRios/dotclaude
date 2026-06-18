---
allowed-tools: Bash(find:*), Bash(du:*), Bash(rm:*), Bash(ls:*), Bash(test:*), Bash(awk:*), Bash(sort:*), Bash(dirname:*), Bash(basename:*), Bash(printf:*), Bash(echo:*), Bash(wc:*), Bash(cat:*), Bash(head:*), Bash(git:*), AskUserQuestion
description: Reclaim SSD space by finding and (with per-category approval) deleting Rust target/ dirs, Foundry/cast caches, gitignored temp bloat, and other dev build artifacts across ~/Github. Strictly scoped to enumerated dev paths so macOS never prompts for file access. Nothing is deleted without explicit approval via selector prompts. Use /reclaim-disk, /reclaim-disk --dry-run, or /reclaim-disk <extra-root>.
argument-hint: [--dry-run] [--min-ignored <MB>] [extra-root ...]
---

# Reclaim disk — prune build bloat with per-category approval

Find disk bloat across your dev directories and delete it **only after you
approve each category** in a selector prompt. Built for the "weeks of worktrees"
problem: dozens of Rust `target/` dirs, Foundry RPC caches, `node_modules`, and
stray gitignored temp folders (`.tmp`, `.cache`, logs, Claude/editor leftovers).

## Non-negotiable: stay scoped, never trigger macOS file-access prompts

macOS TCC prompts the terminal for permission the moment a command touches
`~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive, or certain app data.
This command **only ever reads or deletes under an explicit allowlist of dev
paths**, so those prompts never appear.

- **NEVER** run `find` / `du` / `rm` rooted at `/`, `~`, `$HOME` (bare),
  `~/Desktop`, `~/Documents`, `~/Downloads`, or any iCloud path.
- **NEVER** use `sudo`, `mdfind`, or Spotlight.
- Only scan and delete under these roots (the allowlist):
  - `~/Github`
  - `~/.foundry`
  - `~/.svm`
  - `~/.cargo`
  - `~/.cache`
  - `~/Library/Developer/Xcode/DerivedData`
  - `~/Library/Caches`
  - any extra root passed in `$ARGUMENTS` (must be an existing absolute path under `$HOME`)
- Always redirect scan stderr to `/dev/null` so a stray permission error never
  derails the run.

## Step 0 — Parse arguments and define guards

Parse `$ARGUMENTS`:
- `--dry-run` present → build and print the full report, then **stop** (no
  prompts, no deletion).
- `--min-ignored <MB>` → size threshold for the "Other ignored / temp bloat"
  scan (Step 6b). Default `50`.
- Any other token that is an existing absolute path under `$HOME` → add it to
  the scan roots **and** the deletion allowlist.

Define these helpers in the working shell and reuse them for every deletion.
The `safe_rm` guard is the last line of defense — every `rm -rf` goes through it.

```bash
HOME_REAL="$HOME"
MIN_IGNORED_MB=50   # overridden by --min-ignored
ALLOW_ROOTS=(
  "$HOME_REAL/Github"
  "$HOME_REAL/.foundry"
  "$HOME_REAL/.svm"
  "$HOME_REAL/.cargo"
  "$HOME_REAL/.cache"
  "$HOME_REAL/Library/Developer/Xcode/DerivedData"
  "$HOME_REAL/Library/Caches"
)
# (append validated extra roots from $ARGUMENTS here)

# kilobytes of a path (0 if missing)
dsize() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

# human-readable from KB
human() { awk -v k="$1" 'BEGIN{ split("KB MB GB TB",u); i=1; while(k>=1024 && i<4){k/=1024;i++} printf "%.1f %s", k, u[i] }'; }

# the ONLY way anything gets deleted
safe_rm() {
  local t="$1"
  case "$t" in /*) ;; *) echo "REFUSE (not absolute): $t"; return 1;; esac
  case "$t" in *..*) echo "REFUSE (contains ..): $t"; return 1;; esac
  [ -e "$t" ] || { echo "skip (already gone): $t"; return 0; }
  local ok=0 r
  for r in "${ALLOW_ROOTS[@]}"; do
    case "$t" in "$r"/*) ok=1; break;; esac
  done
  [ "$ok" = 1 ] || { echo "REFUSE (outside allowlist): $t"; return 1; }
  for r in "${ALLOW_ROOTS[@]}"; do
    [ "$t" = "$r" ] && { echo "REFUSE (is a root): $t"; return 1; }
  done
  [ -d "$t/.git" ] && { echo "REFUSE (git repo root): $t"; return 1; }
  rm -rf -- "$t"
}
```

Keep a running `seen` set of absolute paths already collected, so later scans
(especially Step 6b) never list the same path twice.

## Step 1 — Scan: Rust `target/` directories

Find every `target/` build dir under the scan roots, pruning so the search does
not descend into `target/`, `node_modules/`, or `.git/`. Confirm each is a real
Cargo target (has `CACHEDIR.TAG`, or a sibling `Cargo.toml`) so we never touch a
source folder that happens to be named `target`.

```bash
for root in "$HOME_REAL/Github" <extra-roots>; do
  find "$root" -type d \( -name node_modules -o -name .git \) -prune -o \
       -type d -name target -prune -print 2>/dev/null
done | while read -r d; do
  if [ -f "$d/CACHEDIR.TAG" ] || [ -f "$(dirname "$d")/Cargo.toml" ]; then
    echo "$d"
  fi
done
```

This covers main repos and every `*-worktrees/<name>/target`. Record each path
and its `dsize`.

## Step 2 — Scan: Foundry / cast / solc

- `~/.foundry/cache` — RPC + block cache (`cast`/`forge` fork cache). Usually the
  single biggest offender. Include the whole dir.
- `~/.svm` — installed solc compiler binaries (re-downloaded on demand).
- Per-project Foundry artifacts: a dir with a sibling `foundry.toml` →
  its `out/` and `cache/`. **Never** touch `broadcast/` (deployment records).

```bash
test -d "$HOME_REAL/.foundry/cache" && echo "$HOME_REAL/.foundry/cache"
test -d "$HOME_REAL/.svm" && echo "$HOME_REAL/.svm"
for root in "$HOME_REAL/Github" <extra-roots>; do
  find "$root" -type d -name node_modules -prune -o \
       -type f -name foundry.toml -print 2>/dev/null
done | while read -r cfg; do
  p="$(dirname "$cfg")"
  test -d "$p/out"   && echo "$p/out"
  test -d "$p/cache" && echo "$p/cache"
done
```

## Step 3 — Scan: global cargo caches

Regenerated automatically on next build/fetch:
- `~/.cargo/registry/cache`
- `~/.cargo/registry/src`
- `~/.cargo/git/checkouts`
- `~/.cargo/git/db`

Leave `~/.cargo/registry/index` and `~/.cargo/bin` alone.

## Step 4 — Scan: JS / web build bloat

Top-level only (prune so nested `node_modules` is counted once, not re-listed):

```bash
for root in "$HOME_REAL/Github" <extra-roots>; do
  find "$root" -type d -name node_modules -prune -print 2>/dev/null
done
```

Also collect, when they sit beside a `package.json`: `.next`, `.turbo`,
`.svelte-kit`, `coverage`, `dist`, `build`. These are presented for approval
like everything else — never auto-deleted.

## Step 5 — Scan: Hardhat

Dirs with a sibling `hardhat.config.{js,ts,cjs}` → their `artifacts/`, `cache/`,
and `typechain-types/`.

## Step 6 — Scan: Xcode DerivedData

If `~/Library/Developer/Xcode/DerivedData` exists and is non-empty, include its
contents as one candidate. Skip silently if absent.

## Step 6b — Ignored / temp bloat inside repos

For each git work tree under the scan roots, ask git itself what's ignored —
this catches `.tmp`, `tmp/`, `.cache`, `.turbo`, log dirs, Claude/editor temp
dirs, and anything else your `.gitignore` hides that isn't a named category.

Enumerate work trees (matches normal repos *and* worktrees, whose `.git` is a
file, not a dir):

```bash
for root in "$HOME_REAL/Github" <extra-roots>; do
  find "$root" -maxdepth 4 -name .git -not -path '*/node_modules/*' 2>/dev/null
done | while read -r g; do dirname "$g"; done | sort -u
```

For each work tree, list ignored entries with fully-ignored dirs collapsed to a
single path:

```bash
git -C "$wt" ls-files --others --ignored --exclude-standard --directory 2>/dev/null
```

Keep an entry only if **all** hold:
- its size ≥ `MIN_IGNORED_MB` (default 50 MB; `--min-ignored <MB>` overrides);
- its absolute path isn't already in the `seen` set (dedup);
- its basename isn't an already-handled category (`target`, `node_modules`,
  `out`, `cache`, `artifacts`, `typechain-types`);
- it does **not** match a sensitive pattern — never offered at any size:
  `.env`, `.env.*`, `*.key`, `*.pem`, `id_rsa*`, `*.keystore`, `*secret*`,
  `.netrc`, `credentials*`.

Group survivors into one category **"Other ignored / temp bloat"**, listing each
path + size (e.g. `.tmp/`, `.cache/`, `logs/`). Git-ignored = regenerable, but
still requires approval like everything else.

## Step 7 — Build categories and print the report

Group every collected path into categories. For each category compute the
total size (sum of `dsize`) and item count. Sort categories by size descending.
Print a report:

```
Reclaim-disk scan (scoped to <N> roots) — nothing deleted yet
──────────────────────────────────────────────────────────────
  9.2 GB   Rust target/ dirs            (14 dirs)
  3.4 GB   node_modules                 (5 repos)
  3.1 GB   Foundry RPC/block cache      (~/.foundry/cache)
  2.0 GB   solc binaries                (~/.svm)
  1.1 GB   cargo registry/git caches    (4 dirs)
  0.8 GB   Other ignored / temp bloat   (.tmp, .cache in 3 repos)
  0.6 GB   Hardhat artifacts/cache      (2 repos)
──────────────────────────────────────────────────────────────
  Total reclaimable: 20.2 GB
```

For categories with many items (e.g. 14 target dirs, or the ignored/temp
bucket), also print the individual paths + sizes below the table so the user can
see exactly what's in each bucket.

If `--dry-run` was passed, **stop here.**

## Step 8 — Approve via grouped selector prompts

Use `AskUserQuestion` (`multiSelect: true`) with **categories as the options**:

- Each option label = `"<category> — <human size>"`; description = item count +
  a few example paths.
- A selector question takes **2–4 options**, so chunk categories into questions
  of ≤4 options each; you may put up to 4 questions in a single
  `AskUserQuestion` call, and make additional calls if there are more than 16
  categories.
- If only **one** category exists, present it as a single-select question with
  options `"Delete (<size>)"` and `"Skip"`.
- Selected = approved for deletion. Unselected = kept.

Never collapse this into a single "delete everything" confirmation — the user
must tick each category they want gone.

## Step 9 — Delete approved categories and report

For every path in each approved category, call `safe_rm "$path"`. Tally the
KB freed (sum of the pre-deletion sizes of paths that `safe_rm` actually
removed). Print:

```
Reclaimed 16.5 GB
  Deleted: Rust target/ (14), node_modules (5), Foundry cache, Other ignored (3)
  Kept:    solc binaries, cargo caches, Hardhat artifacts
  Refused: 0
```

If `safe_rm` refused any path, list it and why.

## Hard rules

1. **Nothing is deleted without explicit approval.** The scan/report (Steps 1–7)
   is always read-only. Deletion happens only in Step 9, only for categories the
   user ticked in Step 8.
2. **Every deletion goes through `safe_rm`** — absolute path, no `..`, under the
   allowlist, not a root, not a git repo root.
3. **Stay inside the allowlist.** Never scan or delete under `~/Desktop`,
   `~/Documents`, `~/Downloads`, iCloud, bare `~`, or `/`. No `sudo`, no
   `mdfind`. This is what keeps macOS from prompting for file access.
4. **Never delete source or records:** repo roots, `.git`, `Cargo.toml`,
   `~/.cargo/bin`, `~/.cargo/registry/index`, Foundry `broadcast/`.
5. A `target` dir is deletable only if it has `CACHEDIR.TAG` or a sibling
   `Cargo.toml`.
6. **Never offer or delete sensitive ignored files** regardless of size:
   `.env`, `.env.*`, `*.key`, `*.pem`, `id_rsa*`, `*.keystore`, `*secret*`,
   `.netrc`, `credentials*`. Git-ignored ≠ disposable.
7. `--dry-run` must never delete anything.

## Failure modes

- **A scan command errors on a permission boundary:** stderr is sent to
  `/dev/null`; the path is simply skipped. If you ever see a macOS access
  prompt, a scan root escaped the allowlist — stop and fix the root list.
- **`du` is slow on huge trees:** acceptable; it runs once per candidate. Do not
  switch to a whole-`$HOME` scan to "speed it up."
- **A candidate disappears between scan and delete** (concurrent build):
  `safe_rm` prints `skip (already gone)` and continues.
- **`git ls-files --ignored` run outside a repo:** returns nothing on stderr →
  that work tree is skipped. Worktrees are handled because their `.git` is a
  file and `dirname` still resolves the work-tree root.
- **Nothing reclaimable found:** print the empty report and exit without any
  selector prompt.

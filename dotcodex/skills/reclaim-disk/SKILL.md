---
name: reclaim-disk
description: "Use when the user asks to run the former Claude /reclaim-disk workflow: Scan approved dev paths for build caches and gitignored bloat, then delete only user-approved categories through guarded removal."
---

# reclaim-disk

Codex adaptation of the Claude slash command `reclaim-disk`. Follow the
workflow below, but use Codex-native tools and normal user questions where the
original mentions Claude-only mechanisms.

Compatibility notes:
- Treat `$ARGUMENTS` as the relevant arguments or intent from the user's
  request.
- Use the structured user-input prompt when deletion approval is required. If it
  is unavailable, ask a concise direct question and stop until the user answers.
- Replace Claude `Agent` calls with Codex subagents only when the user
  explicitly asks for parallel agents; otherwise do the work locally.
- Ignore Claude `allowed-tools`, `argument-hint`, `TodoWrite`, and `Skill` tool
  references as tool-permission metadata.
- When the workflow mentions another slash command, use the corresponding Codex
  skill or follow that workflow directly.

Find disk bloat across approved dev directories and delete it only after the
user approves each category. This is built for worktree-heavy development:
multiple Rust `target/` directories, Foundry caches, `node_modules`, and
gitignored temp folders.

## Non-negotiable scope

macOS can prompt for file access as soon as a command touches protected
locations such as `~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive, or
some app data. This workflow only reads or deletes under an explicit allowlist
of dev paths.

Never run `find`, `du`, or `rm` rooted at `/`, bare `~`, `$HOME`, `~/Desktop`,
`~/Documents`, `~/Downloads`, or any iCloud path. Never use `sudo`, `mdfind`, or
Spotlight.

Allowed scan/delete roots:

- `~/Github`
- `~/.foundry`
- `~/.svm`
- `~/.cargo`
- `~/.cache`
- `~/Library/Developer/Xcode/DerivedData`
- `~/Library/Caches`
- Extra roots passed by the user, only if each is an existing absolute path
  under `$HOME`

Always redirect scan stderr to `/dev/null` so a stray permission error does not
derail the run.

## 0. Parse arguments and define guards

Parse the user's request:

- `--dry-run`: build and print the full report, then stop. No prompts, no
  deletion.
- `--min-ignored <MB>`: size threshold for "Other ignored / temp bloat". Default
  is `50`.
- Any other token that is an existing absolute path under `$HOME`: add it to the
  scan roots and deletion allowlist.

Define and reuse these helpers in the working shell. Every deletion must go
through `safe_rm`.

```bash
HOME_REAL="$HOME"
MIN_IGNORED_MB=50
ALLOW_ROOTS=(
  "$HOME_REAL/Github"
  "$HOME_REAL/.foundry"
  "$HOME_REAL/.svm"
  "$HOME_REAL/.cargo"
  "$HOME_REAL/.cache"
  "$HOME_REAL/Library/Developer/Xcode/DerivedData"
  "$HOME_REAL/Library/Caches"
)

dsize() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }

human() {
  awk -v k="$1" 'BEGIN{ split("KB MB GB TB",u); i=1; while(k>=1024 && i<4){k/=1024;i++} printf "%.1f %s", k, u[i] }'
}

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

Keep a `seen` set of absolute paths already collected so later scans never list
the same path twice.

## 1. Scan Rust `target/` directories

Find every `target/` build dir under the scan roots, pruning so the search does
not descend into `target/`, `node_modules/`, or `.git/`. Confirm each is a real
Cargo target by requiring either `CACHEDIR.TAG` inside it or a sibling
`Cargo.toml`.

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

Record each path and its `dsize`.

## 2. Scan Foundry, cast, and solc caches

Include:

- `~/.foundry/cache`
- `~/.svm`
- Per-project Foundry `out/` and `cache/` directories when a sibling
  `foundry.toml` exists

Never touch Foundry `broadcast/`.

```bash
test -d "$HOME_REAL/.foundry/cache" && echo "$HOME_REAL/.foundry/cache"
test -d "$HOME_REAL/.svm" && echo "$HOME_REAL/.svm"
for root in "$HOME_REAL/Github" <extra-roots>; do
  find "$root" -type d -name node_modules -prune -o \
       -type f -name foundry.toml -print 2>/dev/null
done | while read -r cfg; do
  p="$(dirname "$cfg")"
  test -d "$p/out" && echo "$p/out"
  test -d "$p/cache" && echo "$p/cache"
done
```

## 3. Scan global cargo caches

Regenerated automatically on next build or fetch:

- `~/.cargo/registry/cache`
- `~/.cargo/registry/src`
- `~/.cargo/git/checkouts`
- `~/.cargo/git/db`

Leave `~/.cargo/registry/index` and `~/.cargo/bin` alone.

## 4. Scan JS and web build bloat

Find top-level `node_modules` directories, pruning so nested ones are counted
once:

```bash
for root in "$HOME_REAL/Github" <extra-roots>; do
  find "$root" -type d -name node_modules -prune -print 2>/dev/null
done
```

Also collect `.next`, `.turbo`, `.svelte-kit`, `coverage`, `dist`, and `build`
when they sit beside a `package.json`.

## 5. Scan Hardhat artifacts

For directories with a sibling `hardhat.config.{js,ts,cjs}`, collect
`artifacts/`, `cache/`, and `typechain-types/`.

## 6. Scan Xcode DerivedData

If `~/Library/Developer/Xcode/DerivedData` exists and is non-empty, include its
contents as one candidate. Skip silently if absent.

## 7. Scan ignored/temp bloat inside repos

For each git work tree under scan roots, ask git what is ignored. This catches
`.tmp`, `tmp/`, `.cache`, `.turbo`, logs, editor temp dirs, and other ignored
paths that are not a named category.

Enumerate work trees:

```bash
for root in "$HOME_REAL/Github" <extra-roots>; do
  find "$root" -maxdepth 4 -name .git -not -path '*/node_modules/*' 2>/dev/null
done | while read -r g; do dirname "$g"; done | sort -u
```

List ignored entries with fully ignored dirs collapsed:

```bash
git -C "$wt" ls-files --others --ignored --exclude-standard --directory 2>/dev/null
```

Keep an entry only if all are true:

- Size is at least `MIN_IGNORED_MB`.
- Absolute path is not already in `seen`.
- Basename is not an already-handled category: `target`, `node_modules`, `out`,
  `cache`, `artifacts`, `typechain-types`.
- It does not match a sensitive pattern.

Never offer or delete sensitive ignored files regardless of size:

- `.env`
- `.env.*`
- `*.key`
- `*.pem`
- `id_rsa*`
- `*.keystore`
- `*secret*`
- `.netrc`
- `credentials*`

Group survivors as "Other ignored / temp bloat".

## 8. Build categories and print the report

Group collected paths into categories. For each category, compute total size and
item count. Sort by size descending. Print a report like:

```text
Reclaim-disk scan (scoped to <N> roots) - nothing deleted yet

  9.2 GB   Rust target/ dirs            (14 dirs)
  3.4 GB   node_modules                 (5 repos)
  3.1 GB   Foundry RPC/block cache      (~/.foundry/cache)
  2.0 GB   solc binaries                (~/.svm)
  1.1 GB   cargo registry/git caches    (4 dirs)
  0.8 GB   Other ignored / temp bloat   (.tmp, .cache in 3 repos)
  0.6 GB   Hardhat artifacts/cache      (2 repos)

  Total reclaimable: 20.2 GB
```

For large categories, also print individual paths and sizes.

If `--dry-run` was passed, stop here.

## 9. Approve by category

Use the structured user-input prompt with categories as options:

- Option label: `<category> - <human size>`
- Description: item count plus a few example paths
- Present 2-4 options per question.
- If only one category exists, present `Delete (<size>)` and `Skip`.

Selected categories are approved for deletion. Unselected categories are kept.
Never collapse this into a single "delete everything" confirmation.

## 10. Delete approved categories and report

For every path in each approved category, call:

```bash
safe_rm "$path"
```

Tally the KB freed from paths that `safe_rm` actually removed. Report:

```text
Reclaimed 16.5 GB
  Deleted: Rust target/ (14), node_modules (5), Foundry cache, Other ignored (3)
  Kept:    solc binaries, cargo caches, Hardhat artifacts
  Refused: 0
```

If `safe_rm` refused any path, list it and why.

## Hard rules

1. Nothing is deleted without explicit approval. The scan/report is always
   read-only.
2. Every deletion goes through `safe_rm`.
3. Stay inside the allowlist. Never scan or delete under protected home
   directories, bare `~`, or `/`; never use `sudo` or `mdfind`.
4. Never delete source or records: repo roots, `.git`, `Cargo.toml`,
   `~/.cargo/bin`, `~/.cargo/registry/index`, or Foundry `broadcast/`.
5. A `target` dir is deletable only if it has `CACHEDIR.TAG` or a sibling
   `Cargo.toml`.
6. Never offer or delete sensitive ignored files regardless of size.
7. `--dry-run` must never delete anything.

## Failure modes

- A scan command errors on a permission boundary: stderr goes to `/dev/null` and
  the path is skipped. If a macOS access prompt appears, stop and fix the root
  list.
- `du` is slow on huge trees: acceptable. Do not switch to a whole-home scan.
- A candidate disappears between scan and delete: `safe_rm` prints
  `skip (already gone)` and continues.
- `git ls-files --ignored` outside a repo: returns nothing on stderr; skip that
  work tree.
- Nothing reclaimable found: print the empty report and exit without prompting.

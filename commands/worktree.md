---
allowed-tools: Bash(git:*), Bash(gt:*), Bash(rm:*), Bash(mkdir:*), Bash(basename:*), Bash(ls:*), Bash(test:*), Bash(cat:*), Bash(wc:*), Bash(shuf:*), Bash(printf:*), Bash(direnv:*), Read
description: Create or remove a git worktree for the current repo. Creates worktrees in ../<repo>-worktrees/<adjective-noun> detached at trunk, with optimized submodule init. Use /worktree to create, /worktree remove <name> to delete.
argument-hint: [remove <name> | list | detach-all]
---

# Worktree — fast parallel working copies

Create or remove git worktrees for the current repo. Worktrees land in a
sibling directory alongside the repo, with memorable random names.

## Layout

```
~/Github/
  st0x.liquidity/                    # main repo
  st0x.liquidity-worktrees/          # worktree container
    curious-banana/                  # a worktree
    bold-octopus/                    # another worktree
```

## Mode detection

Parse `$ARGUMENTS`:

- **Empty** or missing: create a new worktree (step 1).
- **`remove <name>`**: remove the named worktree (step 5).
- **`list`**: list existing worktrees (step 6).
- **`detach-all`**: detach all worktrees from their branches (step 7).

## Step 1 — Resolve repo info

```bash
repo_root=$(git rev-parse --show-toplevel)
repo_name=$(basename "$repo_root")
worktree_dir="$(dirname "$repo_root")/${repo_name}-worktrees"
trunk=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
if [ -z "$trunk" ]; then
  # Fallback: check for main or master
  if git show-ref --verify --quiet refs/heads/main; then
    trunk="main"
  elif git show-ref --verify --quiet refs/heads/master; then
    trunk="master"
  else
    echo "Cannot determine trunk branch"; exit 1
  fi
fi
trunk_sha=$(git rev-parse "origin/$trunk")
```

## Step 2 — Generate a memorable name

Pick an adjective-noun combo that's easy to remember and type. Use this
word list and `$RANDOM` to select:

```bash
adjectives="swift bold calm cool crisp deft dry eager fair fast fond free glad gold green keen kind lean lush mild neat pale pure raw red rich ripe safe sharp shy slim soft tall tame thin vast warm wide wild wise"
nouns="apple arrow badge beach bell bloom bolt bread brook brush cedar charm claw cliff cloud coral crane creek crown daisy delta dingo drift eagle ember fawn ferry flame frost gecko grove heron hound iris jade jewel kayak kite lemon lily lotus maple marsh melon moth opal otter pansy pearl plume quail raven reef robin sage seal shell snail spark squid stone storm thorn tiger trout tulip viper waltz whale wheat wren yak"

adj_arr=($adjectives)
noun_arr=($nouns)
name="${adj_arr[$((RANDOM % ${#adj_arr[@]}))]}-${noun_arr[$((RANDOM % ${#noun_arr[@]}))]}"
wt_path="$worktree_dir/$name"
```

If the name already exists (unlikely), regenerate once.

## Step 3 — Create the worktree

```bash
mkdir -p "$worktree_dir"
git worktree add --detach "$wt_path" "$trunk_sha"
```

Print the name and path clearly:

```
Worktree created: <name>
  Path: <wt_path>
  Detached at: <trunk> (<short sha>)
```

## Step 4 — Initialize submodules (if any)

Check if the repo has submodules:

```bash
test -f "$repo_root/.gitmodules"
```

If yes, initialize them in the worktree using `--reference` to avoid
re-downloading objects from the network. The main repo already has all
submodule objects locally — reference them:

```bash
cd "$wt_path"
git submodule update --init --recursive --reference "$repo_root"
```

The `--reference` flag tells git to borrow objects from the main repo's
submodule clones, making this near-instant instead of fetching from the
network.

After submodule init, print how many submodules were initialized:

```bash
count=$(git submodule status --recursive | wc -l | tr -d ' ')
echo "Submodules initialized: $count (via --reference, no network fetch)"
```

Then `cd` back or use absolute paths for any remaining work.

## Step 4b — Allow direnv

If the worktree contains a `.envrc` file, run `direnv allow` so the
environment is ready when the user enters the directory:

```bash
test -f "$wt_path/.envrc" && direnv allow "$wt_path"
```

Print confirmation if direnv was allowed:

```
direnv: allowed <wt_path>/.envrc
```

## Step 4c — Project setup (deterministic checks)

Run these checks from `$wt_path`. Each check is independent — run all
that apply, in order.

### Solidity artifacts

If the repo has a nix flake with `prep-sol-artifacts`, compile them:

```bash
cd "$wt_path"
if nix flake show 2>/dev/null | grep -q prep-sol-artifacts; then
  echo "Setup: compiling Solidity artifacts..."
  nix run .#prep-sol-artifacts
  echo "Setup: Solidity artifacts ready"
fi
```

This is **not optional** — the build will fail without these artifacts.

### sqlx database

If the repo uses sqlx (has a `.sqlx/` directory or `sqlx` in any
`Cargo.toml`), reset the database so sqlx macros can compile:

```bash
cd "$wt_path"
if [ -d ".sqlx" ] || grep -rq 'sqlx' Cargo.toml crates/*/Cargo.toml 2>/dev/null; then
  echo "Setup: initializing sqlx database..."
  sqlx db reset -y
  echo "Setup: database ready"
fi
```

## Step 4d — Initialize Graphite

Initialize Graphite in the new worktree so `gt` commands work immediately:

```bash
cd "$wt_path"
gt init --trunk "$trunk" --no-interactive
```

Print confirmation:

```
Graphite: initialized (trunk: <trunk>)
```

## Step 5 — Remove a worktree

When `$ARGUMENTS` starts with `remove`:

1. Extract the worktree name from the arguments.
2. Resolve the path:

   ```bash
   repo_root=$(git rev-parse --show-toplevel)
   repo_name=$(basename "$repo_root")
   worktree_dir="$(dirname "$repo_root")/${repo_name}-worktrees"
   wt_path="$worktree_dir/<name>"
   ```

3. Verify it exists:

   ```bash
   test -d "$wt_path" || { echo "Worktree '<name>' not found at $wt_path"; exit 1; }
   ```

4. Remove it:

   ```bash
   git worktree remove --force "$wt_path"
   git worktree prune
   ```

5. If the directory still exists (e.g., worktree had untracked files and
   `--force` wasn't enough), ask the user before running `rm -rf`.

6. Print confirmation:

   ```
   Worktree '<name>' removed and pruned.
   ```

## Step 6 — List worktrees

When `$ARGUMENTS` is `list`:

```bash
repo_root=$(git rev-parse --show-toplevel)
repo_name=$(basename "$repo_root")
worktree_dir="$(dirname "$repo_root")/${repo_name}-worktrees"

echo "Worktrees in $worktree_dir:"
if [ -d "$worktree_dir" ]; then
  ls "$worktree_dir"
else
  echo "  (none)"
fi
```

Also show `git worktree list` for the full picture.

## Final output

After creating a worktree, print a ready-to-use summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Worktree ready: <name>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Path:       <wt_path>
  Detached at: <trunk> (<short sha>)
  Submodules: <count> initialized
  Setup:      <commands run, or "none needed">
  Graphite:   initialized (trunk: <trunk>)

To open in a new terminal:
  cd <wt_path>

To remove later:
  /worktree remove <name>
```

## Step 7 — Detach all worktrees at trunk

When `$ARGUMENTS` is `detach-all`:

1. Fetch the latest from the remote:

   ```bash
   git fetch origin
   ```

2. Determine the trunk branch name (`main` or `master`):

   ```bash
   git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null
   ```

   If that fails, check which of `origin/main` or `origin/master` exists.
   Store the result as `trunk_ref` (e.g., `origin/main`).

3. List all worktrees:

   ```bash
   git worktree list --porcelain
   ```

   Parse the output: each worktree block has `worktree <path>`, `HEAD <sha>`,
   and either `branch refs/heads/<name>` or `detached`. Skip the main repo
   worktree (the bare repo root).

4. For each worktree (whether on a branch or already detached at an old
   commit), reset it to the latest trunk and detach:

   ```bash
   git -C "<wt_path>" checkout --detach "$trunk_ref"
   ```

   A worktree is **already up to date** only if it is detached AND its HEAD
   already matches the resolved sha of `$trunk_ref`. Skip those.

5. Print a summary:

   ```
   Detached <count> worktree(s) at <trunk_ref> (<short sha>):
     <name>: <previous state> -> detached at <short sha>
     ...

   Already up to date: <count>
   Skipped (main repo): <main path>
   ```

   `<previous state>` is either the branch name or `detached at <old short sha>`.

   If no worktrees needed updating, print:

   ```
   All worktrees are already detached at <trunk_ref>.
   ```

## Hard rules

1. Always create worktrees detached at trunk — never on a branch.
2. Always use `--reference` for submodule init to avoid network fetches.
3. Never remove a worktree without verifying the path is inside the
   expected `-worktrees/` directory — prevent accidental `rm -rf` of
   the main repo.
4. If `git worktree remove --force` fails and `rm -rf` is needed, ask
   the user first.

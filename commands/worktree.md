---
allowed-tools: Bash(git:*), Bash(rm:*), Bash(mkdir:*), Bash(basename:*), Bash(ls:*), Bash(test:*), Bash(cat:*), Bash(wc:*), Bash(shuf:*), Bash(printf:*), Read
description: Create or remove a git worktree for the current repo. Creates worktrees in ../<repo>-worktrees/<adjective-noun> detached at trunk, with optimized submodule init. Use /worktree to create, /worktree remove <name> to delete.
argument-hint: [remove <name>]
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

To open in a new terminal:
  cd <wt_path>

To remove later:
  /worktree remove <name>
```

## Hard rules

1. Always create worktrees detached at trunk — never on a branch.
2. Always use `--reference` for submodule init to avoid network fetches.
3. Never remove a worktree without verifying the path is inside the
   expected `-worktrees/` directory — prevent accidental `rm -rf` of
   the main repo.
4. If `git worktree remove --force` fails and `rm -rf` is needed, ask
   the user first.

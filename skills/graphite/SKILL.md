---
name: graphite
description: Use for ANY git, branch, commit, rebase, merge, push, pull, stack, PR, or version-control operation. Graphite (`gt`) is the authoritative tool for mutating version-control state in this user's repos — never use raw `git` for commits, branches, rebases, amends, or pushes. Use when the user says commit, push, branch, rebase, amend, stack, submit PR, sync, restack, check out branch, create PR, update PR, or any similar phrasing.
allowed-tools: Bash(gt:*), Bash(git:*), Bash(gh:*)
---

# Graphite (`gt`) — the version-control tool for this user

**Read this before touching version control.** This user uses Graphite stacked
PRs. `gt` wraps git, preserves stack metadata, and keeps parent/child branches
consistent through rebases. Using raw `git` for mutations silently breaks the
stack.

## The Core Rule

> **Never use `git` to mutate state. Always use `gt`.**

| Task                                  | Correct                   | Wrong                  |
| ------------------------------------- | ------------------------- | ---------------------- |
| Create a new branch + commit          | `gt create <name>`        | `git checkout -b` + `git commit` |
| Amend current branch                  | `gt modify`               | `git commit --amend`   |
| Create a follow-up commit on branch   | `gt modify --commit`      | `git commit`           |
| Stack a branch on another             | `gt create` (from parent) | `git rebase --onto`    |
| Rebase stack onto latest trunk        | `gt restack` / `gt sync`  | `git rebase main`      |
| Push branches + open/update PRs       | `gt submit`               | `git push` + `gh pr create` |
| Switch branches                       | `gt checkout <name>`      | `git checkout <name>`  |
| Fetch trunk + clean up merged         | `gt sync`                 | `git pull` + manual cleanup |
| Move a branch to a new parent         | `gt move`                 | `git rebase --onto`    |
| Split a branch                        | `gt split`                | manual cherry-pick     |
| Squash branch commits                 | `gt squash`               | `git rebase -i`        |
| Delete a branch (and restack kids)    | `gt delete <name>`        | `git branch -D`        |

## When `git` is OK

Read-only inspection only. `gt` does not wrap everything, and for these `git`
is fine (and expected):

- `git diff` (and `git --no-pager diff` — avoid the pager)
- `git diff $(gt parent)..HEAD` — parent-aware stack diff
- `git log`, `git log --oneline`, `git log -p`
- `git status`
- `git blame`
- `git show <sha>`
- `git stash list` / `git stash show`
- `git merge-base`, `git rev-parse`

**Never** run: `git commit`, `git commit --amend`, `git checkout -b`, `git
rebase`, `git reset --hard`, `git push`, `git pull`, `git merge`, `git cherry-pick`,
`git branch -D`. Use the `gt` equivalent.

## Command reference (grouped by workflow)

### Setup / auth

- `gt init` — initialize a repo for Graphite (pick trunk). Run once per repo.
- `gt auth --token <token>` — authenticate with Graphite cloud (for `gt submit`).

### Create & edit

- `gt create <name>` *(alias `gt c`)* — new stacked branch on top of current branch, commits staged changes. Always stage first (`gt add <files>` or `git add <files>`).
- `gt modify` *(alias `gt m`)* — amend current branch's commit, automatically restacks descendants. Use `--commit` to create a new commit instead of amending.
- `gt absorb` — auto-distribute staged hunks into the right commits downstack. Powerful for fixing review feedback across a stack.
- `gt split` — split current branch by commit, hunk, or file into a new stack.
- `gt squash` — collapse all commits in the current branch into one.
- `gt fold` — fold the current branch into its parent.

### Navigate the stack

- `gt log short` *(alias `gt ls`)* — compact stack view. Use this first when orienting.
- `gt log long` *(alias `gt ll`)* — detailed stack view with commits.
- `gt up` *(alias `gt u`)* — move to child branch.
- `gt down` *(alias `gt d`)* — move to parent branch.
- `gt top` / `gt bottom` — jump to tip / base of current stack.
- `gt checkout [branch]` *(alias `gt co`)* — switch branches (interactive if omitted).
- `gt parent` — print the current branch's parent.
- `gt children` — list descendants.
- `gt trunk` — print trunk for current branch.

### Submit & sync

- `gt submit` *(alias `gt s`)* — push current branch and all downstack branches, open/update PRs. Use `--stack` for the whole stack, `--no-interactive` for scripts, `--no-edit-description` to keep existing PR descriptions, `--draft` for draft PRs, `--dry-run` to preview.
- `gt sync` — fetch trunk from remote, rebase all stacks on top, prompt to delete merged branches. Run at the start of every session on a branch that depends on trunk.
- `gt restack` — re-parent every branch in the current stack onto its parent's latest commit. Run after `gt modify` in a lower branch to propagate to children (though `gt modify` usually does this automatically).
- `gt get [branch]` — pull a branch (and its stack) from remote with conflict resolution.
- `gt move` — move the current branch onto a new parent (`gt move --onto <branch>`), restacks descendants.
- `gt reorder` — interactively reorder branches in the current stack.

### Conflicts

When a `gt` command halts on a conflict:

1. Resolve the conflicts in the working tree (check `git status`, edit files).
2. `gt add <resolved files>` (or `git add`).
3. `gt continue` — resume the interrupted operation.
4. Or `gt abort` to bail out entirely.
5. After the whole operation finishes: `gt undo` reverts the most recent `gt`
   operation if you change your mind.

Never run `git rebase --continue` or `git rebase --abort` during a `gt`
operation — it will desync stack metadata.

### Information

- `gt info [branch]` — show metadata for a branch (parent, PR link, etc.).
- `gt pr [branch]` — open the PR page in the browser.
- `gt dash` — open the Graphite web dashboard.

## Workflows

### Start a new feature off trunk

```bash
gt sync                          # refresh trunk
gt checkout main                 # or your trunk
# edit files
gt add <files>                   # stage
gt create my-feature             # new branch + commit
gt submit                        # push + open PR
```

### Stack a second branch on top of the first

```bash
# from my-feature
# edit more files
gt add <files>
gt create my-feature-pt2         # stacks on my-feature
gt submit --stack                # submits both PRs
```

### Address review feedback on a lower branch

```bash
gt down                          # move to the branch with the feedback
# edit files
gt add <files>
gt modify                        # amends; descendants auto-restack
gt submit --stack                # force-pushes the whole stack
```

### Sync after trunk moves

```bash
gt sync                          # pulls trunk, rebases stacks, offers cleanup
# resolve conflicts if prompted -> gt add ... && gt continue
```

### Inspect what's in the current PR

```bash
gt log short                     # see the stack shape
git --no-pager diff $(gt parent)..HEAD   # parent-aware diff = exactly the PR contents
```

Important: `git diff main..HEAD` is **wrong** on a stacked branch — it includes
the ancestor PRs too. Always diff against `gt parent`.

### Recover from a mistake

- `gt undo` — revert the last `gt` operation.
- Never use `git reset --hard` to "fix" a broken stack — run `gt restack` or
  `gt sync` first and let graphite do the right thing.

## Scripting / non-interactive use

When running `gt` from an automation or non-TTY context, pass:

- `--no-interactive` — skip prompts (required for scripts).
- `--no-edit` / `--no-edit-description` — don't open an editor.
- `--dry-run` — print what would happen without doing it.

Example: `gt submit --stack --no-interactive --no-edit-description`

## When this user says...

- **"commit this"** → stage with `git add`, then `gt create <name>` (new branch) or `gt modify` (amend current).
- **"push this"** → `gt submit` (or `gt submit --stack` if they want the whole stack).
- **"rebase on main"** → `gt sync` (not `git rebase main`).
- **"create a PR"** → `gt submit`. Do not use `gh pr create` directly — graphite handles it.
- **"update the PR"** → `gt modify` then `gt submit`.
- **"new branch stacked on this"** → `gt create <name>` after staging.
- **"what's in this PR"** → `git --no-pager diff $(gt parent)..HEAD` (diff vs parent).
- **"switch to <branch>"** → `gt checkout <branch>`.
- **"delete this branch"** → `gt delete <branch>` (restacks children automatically).

## Hard rules

1. Never run `git commit`, `git push`, `git rebase`, or `git checkout -b` in a
   graphite-managed repo.
2. Always diff a stacked branch against `gt parent`, never against `main`.
3. When a `gt` operation conflicts, use `gt continue`/`gt abort`, never the git
   equivalents.
4. Run `gt sync` before starting work and after trunk moves.
5. In non-interactive contexts always pass `--no-interactive` to `gt submit`.
6. Before running any mutating `gt` command, verify you're on the expected
   branch (`gt log short` or `git rev-parse --abbrev-ref HEAD`).

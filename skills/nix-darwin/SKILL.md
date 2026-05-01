---
name: nix-darwin
description: "Edit, add, or remove anything in the user's nix-darwin + home-manager macOS config. Use whenever the user wants to: install/uninstall an app (GUI or CLI), add a homebrew cask or formula, add a nushell alias or PATH entry, change ghostty/starship/karabiner config, modify macOS system defaults, add nix deprecation silencing, or do anything involving ~/Github/nix-darwin-config. Also trigger when the user says 'rebuild', mentions their darwin config, or asks about where something should go in their nix setup."
allowed-tools: Bash(nix:*), Bash(git:*), Bash(brew:*), Bash(python3:*), Read, Write, Edit, Glob, Grep
---

# nix-darwin Config Manager

This user has a declarative macOS system config at `~/Github/nix-darwin-config/`
managed by nix-darwin + home-manager, running on Lix (not upstream nix).

**Read the relevant file(s) before making any edits.** The config is modular —
know which file to touch before you touch it.

## Repo Layout

```
~/Github/nix-darwin-config/
├── flake.nix                      # inputs: nixpkgs-unstable, nix-darwin, home-manager
├── flake.lock
├── hosts/juanrios-m2.nix          # system wiring, imports modules
├── modules/
│   ├── nix.nix                    # nix.enable=false (Lix) + /etc/nix/nix.custom.conf
│   ├── homebrew.nix               # casks, brews (w/ taps), masApps
│   ├── system-defaults.nix        # dock, TouchID sudo, etc.
│   └── tailscale-cli.nix          # activation script: wrapper for tailscale CLI
├── home/
│   ├── default.nix                # home-manager entry, imports submodules
│   ├── packages.nix               # CLI tools from nixpkgs
│   ├── shell.nix                  # zsh, nushell, starship, zoxide, yazi, direnv
│   ├── git.nix                    # git identity
│   ├── ghostty.nix                # ghostty terminal config
│   ├── dotfiles.nix               # xdg.configFile wiring
│   └── dotfiles/
│       ├── starship.toml          # gruvbox-dark powerline prompt
│       ├── karabiner.json         # keyboard remaps + mouse scroll flip
│       ├── raycast.rayconfig.age  # age-encrypted raycast export
│       └── raycast.rayconfig.README.md
└── .gitignore
```

## Decision Tree: Where Does It Go?

| What you're adding | File | Section |
|---|---|---|
| GUI app (any .app) | `modules/homebrew.nix` | `homebrew.casks` |
| Mac App Store app | `modules/homebrew.nix` | `homebrew.masApps` (needs numeric ID) |
| CLI tool (check nixpkgs first!) | `home/packages.nix` | `home.packages` |
| CLI tool NOT in nixpkgs | `modules/homebrew.nix` | `homebrew.brews` (fully qualified tap name) |
| Homebrew tap | `modules/homebrew.nix` | `homebrew.taps` |
| Nushell alias | `home/shell.nix` | `programs.nushell.shellAliases` |
| Nushell config | `home/shell.nix` | `programs.nushell.extraConfig` |
| Nushell PATH entry | `home/shell.nix` | `programs.nushell.extraEnv` |
| Starship prompt | `home/dotfiles/starship.toml` | (see starship caveat below) |
| Karabiner rule/device | `home/dotfiles/karabiner.json` | (validate JSON after edit) |
| Ghostty setting | `home/ghostty.nix` | `home.file...text` (nix string interpolation) |
| macOS system default | `modules/system-defaults.nix` | `system.defaults.*` |
| Nix/Lix setting | `modules/nix.nix` | `environment.etc."nix/nix.custom.conf".text` |
| System activation script | new module in `modules/` | `system.activationScripts.*` (+ import in hosts/) |
| New home-manager module | new file in `home/` | (+ import in home/default.nix) |

## Adding a CLI Tool — Always Check nixpkgs First

Before adding a brew formula, check if nixpkgs has it:

```bash
nix eval --raw nixpkgs#<package-name>.meta.description
```

- **If found**: add to `home/packages.nix` → `home.packages` list. Preferred.
- **If NOT found**: add to `modules/homebrew.nix` → `homebrew.brews`. If it
  comes from a custom tap, add the tap to `homebrew.taps` and use the fully
  qualified name in brews (e.g. `"schpet/tap/linear"` not `"linear"`) to avoid
  name collisions with homebrew-core.

## Important Patterns & Gotchas

### Nushell alias conflicts
Nushell has built-in commands that shadow macOS commands. Most notably `open`
(nushell's file reader vs macOS `/usr/bin/open`). Prefix with `^` to force the
external command:

```nix
shellAliases = {
  rustrover = "^open -a RustRover";  # ^open forces /usr/bin/open
};
```

### Nushell PATH
GUI-launched ghostty inherits a minimal launchctl PATH that's missing most nix
and homebrew directories. The nushell `extraEnv` in `home/shell.nix` explicitly
constructs PATH with `prepend` (nix paths go first) and `append` (homebrew,
/usr/local/bin go last) plus `| uniq`. When adding a new PATH entry, add it to
the appropriate position in this block.

### Starship powerline glyph (U+E0B0)
The Edit tool strips the powerline arrow character `` (U+E0B0). When editing
`starship.toml` and the change involves powerline transition strings like
`[](fg:X bg:Y)`, use a Python script instead of the Edit tool:

```bash
python3 -c "
p='home/dotfiles/starship.toml'
s=open(p).read()
# ... replacements using '\ue0b0' for the glyph ...
open(p,'w').write(s)
"
```

### Karabiner is read-only
`karabiner.json` is symlinked from the nix store (via `xdg.configFile`).
Karabiner's Settings GUI cannot save changes — all edits must go through the
repo. After editing, validate JSON:

```bash
python3 -c "import json; json.load(open('home/dotfiles/karabiner.json')); print('valid')"
```

### Ghostty config uses nix interpolation
`home/ghostty.nix` uses `${pkgs.nushell}/bin/nu` for the shell command. This
pins to the exact nix store path and updates automatically on rebuild. Any new
ghostty settings go in the same `home.file...text` block.

### homebrew cleanup = "zap"
Anything brew-installed that's NOT listed in the config is **removed** on next
rebuild. This is intentional — the config is the source of truth. Warn the user
if they mention having manually brew-installed something.

### Sensitive files
Encrypt with `age` using the user's 1Password SSH Key 2 (ed25519 public key:
`ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPu9iq79tAdGnRu+Mxyxa75GiOBV5jtXG2Kzw2tYid/8`).
Commit the `.age` file, add the plaintext filename to `.gitignore`.

## Git & Rebuild Workflow

1. **Read** the file(s) you'll edit
2. **Edit** them
3. **Commit** with the user's identity:
   ```bash
   cd ~/Github/nix-darwin-config
   git -c user.name=JuaniRios -c user.email=juani.rios.99@gmail.com commit -am "message"
   ```
   For new files, use `git add <files>` first instead of `-a`.
4. **Push** to master:
   ```bash
   cd ~/Github/nix-darwin-config
   git push
   ```
5. **Tell the user** to run `rebuild` (Claude cannot `sudo` — no TTY for
   password/TouchID).
6. **Post-rebuild notes** — remind the user if applicable:
   - Shell config change → `exec nu` or new ghostty window
   - `nix.custom.conf` change → `sudo launchctl kickstart -k system/org.nixos.nix-daemon`
   - Ghostty config change → close and reopen ghostty windows

## Removing Things

- **Cask/brew/masApp**: delete the line from `modules/homebrew.nix`. `cleanup = "zap"` handles the actual uninstall on next rebuild.
- **nixpkgs CLI tool**: delete from `home/packages.nix`.
- **Nushell alias**: delete from `programs.nushell.shellAliases` in `home/shell.nix`.
- **Entire module**: delete the `.nix` file AND remove its import from `hosts/juanrios-m2.nix` (system modules) or `home/default.nix` (home-manager modules).

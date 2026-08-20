# Operations

What a run does to this machine, and what it will and won't touch. Read this
before a large re-run or when onboarding a machine that already has software
installed outside Homebrew.

For *why* things behave this way, see [architecture.md](architecture.md). For
failures with known causes and recovery steps, see [findings.md](findings.md).

## Running it

```bash
# Reconcile now
computer-setup apply

# What would change, without changing it (the same check the 10:00 agent runs)
computer-setup check

# A fully converged machine reports:  changed=0  failed=0
```

Ask what the last run actually did, without re-running anything:

```bash
computer-setup status
```

```
Last run:  check — ok at 2026-08-20T10:00:04+0200
Drift:     2 task(s) would change:
  - Deploy layer template: settings.json  →  /Users/you/.config/zed/settings.json
  - Deploy the managed git config  →  /Users/you/.config/git/managed.gitconfig
Sync:      ok — last successful scheduled run 0 day(s) ago
```

The `Sync:` line is the one to read first. The scheduled modes exit 0 when the
repo is unreachable — a closed laptop is not a fault — which means a machine
that quietly stopped syncing weeks ago otherwise looks exactly like a healthy
one. Past `drift_correction_stale_after_days` (14 by default) it reports
`STALE`.

`computer-setup status --json` prints the same thing for machines. It is the
interface a UI would consume; see "Run state" in
[architecture.md](architecture.md) for the shape and its guarantees.

Clone repositories that are listed but missing:

```bash
computer-setup apply --tags repositories
```

## git config is included, not imposed

`~/.gitconfig` is **not** owned by this setup. It owns
`~/.config/git/computer-setup.gitconfig` and reaches `~/.gitconfig` only to
append one `include.path`. Anything you put in `~/.gitconfig` — signing keys,
credential helpers, your own `includeIf` blocks — is preserved.

The include is appended, so managed values are read **last** and still win over
entries above them. Full enforcement, no collateral damage.

### Per-directory identities

`git_conditional_identities` renders `includeIf` blocks — how a work layer
supplies a work address for its own remotes without touching the machine-wide
identity. The machine-wide `git_user_name`/`git_user_email` come from questions
instead (see "The machine tier" in [architecture.md](architecture.md)).

Two condition forms, both passed to git verbatim:

- `gitdir:<path>` — matches by location. **Git resolves symlinks first**, so the
  pattern must be the real path: on macOS `/private/tmp/...`, never `/tmp/...`.
  A pattern that looks right but points through a symlink silently never matches.
- `hasconfig:remote.*.url:<pattern>` — matches by remote URL (git ≥ 2.36), and
  is layout-independent. Use this when work and personal repositories share one
  directory, which is the normal case here.

Verify with `git -C <repo> config --get user.email` inside an affected
repository — the condition is evaluated per repo, so checking the config file
alone tells you nothing.

## How your manual changes are handled

### Enforced — reverted on the next run

| What you change | Behaviour |
|---|---|
| `~/.zshrc` | Replaced from the layer-provided `zshrc` (timestamped backup kept). Edit it in the layer. |
| `~/.zsh/*.zsh` managed snippets | Regenerated from the layers' `files/shell/*.zsh`. |
| `~/.config/git/computer-setup.gitconfig` | Re-rendered whole. Anything not declared in a layer is dropped. `~/.gitconfig` itself is only appended to. |
| `~/.gitignore_global` | Replaced entirely from `git_global_gitignore_entries`. |
| `~/.p10k.zsh` | Replaced from the layer-provided `p10k.zsh`. |
| macOS defaults | `osx_defaults` enforces the layer-declared value; System Settings changes are reverted. |
| NVM default alias | Mismatch is detected and `nvm alias default <declared>` re-run. |
| tfenv active version | Reverted to `runtimes_tfenv_terraform_version` (and never auto-upgraded). |
| Capability config files | Re-deployed from the providing layer whenever the capability is active. |
| `computer-setup`, the engine's own LaunchAgent plists | Regenerated, then the agents are reloaded. |
| Layer-declared scheduled agents | Plists regenerated and reloaded. An agent whose `requires_capability` is no longer active, or whose entry is removed, is booted out of launchd and its plist deleted — a stale plist would otherwise keep firing across reboots. |

### Additive — nothing of yours is removed

| What you change | Behaviour |
|---|---|
| Install extra Homebrew packages or editor extensions | Preserved. Only listed items are ensured present. |
| Uninstall a *managed* package or extension | Reinstalled on the next run. |

### Preserved — left untouched

| What you change | Behaviour |
|---|---|
| Extra files in `~/.zsh/` | Left on disk. Cleanup only removes paths recorded in `~/.zsh/.computer-setup-snippets` from a previous run. |
| `~/.config/computer-setup/prefs.yml` edited by hand | Read as-is. Malformed YAML falls back to defaults with a warning. |
| Local changes in a listed repo | Never touched. Cloning uses `update: false` and only clones repos that are entirely absent. |

## Non-destructive guarantees

The `homebrew` role is `state: present` only — no prune, no `absent`. Applying
never uninstalls manually-installed apps or unmanaged Homebrew leaves. Removing
an item from a baseline list stops *enforcing* it; nothing is uninstalled.
Cleanup is always a deliberate manual step, never a side effect of a run.

### Asymmetry: config deploys are not garbage-collected

Shell snippets **are** cleaned up — the `shell` role records what it deployed and
removes anything that falls out of that set, so disabling a capability withdraws
its snippet.

Capability `config:` bundles are **not**. Deselecting a capability, or changing a
bundle's `dest`, leaves the previously deployed file in place.

This is deliberate. `~/.zsh/` is wholly engine-owned, so removing an
unrecognised file there is safe. Config bundles write to arbitrary paths the user
also owns and edits. A "remove what we no longer manage" pass over those paths
would turn a renamed `dest`, a mistyped capability id, or a layer that briefly
failed to load into silent deletion of real user config. An orphan is the cheaper
failure. After renaming a bundle's `dest`, delete the old file yourself.

Scheduled agents are the deliberate exception: `scheduled_agents` **does** remove
plists it no longer wants. The reasoning above does not hold for them — an
orphaned plist is not an inert stale file, it is a job that keeps running on
schedule across reboots. Leaving one behind means the machine keeps doing work it
was told to stop doing, which is worse than the deletion risk.

## Where scheduled jobs log

`computer-setup log` tails only the engine's own rolling log
(`~/Library/Logs/computer-setup.log`) — the 09:00 upgrade and 10:00 drift check.
It does **not** show layer-declared agents.

Those write one pair of files per agent, named for the agent's label:

    ~/Library/Logs/<label>.stdout.log
    ~/Library/Logs/<label>.stderr.log

These are not rotated. A job that is noisy on every run will grow them without
bound, so prefer one that stays quiet when it has nothing to report.

Check `stderr.log` first when an agent appears to do nothing. A LaunchAgent
inherits no login-shell environment, so the usual cause is a `PATH` problem — the
plist sets a fixed `PATH` covering Homebrew and the system, and a tool installed
anywhere else will not be found. `launchctl list | grep <label>` shows whether
the job is loaded and what it last exited with.

## Adopting manually-installed apps

The `homebrew` role only uses `install_options: adopt` for casks explicitly
listed in `homebrew_adopt_casks`. Adoption is **not** safe for every cask — see
"Casks with protected payloads" in [findings.md](findings.md) before adding one.

## Migrating a tool off a manual installer

Tools installed via vendor scripts leave a footprint (a `~/.tool` dir plus PATH
and completion lines in `.zshrc`). To bring one under management:

1. Add it as a capability in a layer's `capabilities.yml`, then add that
   capability's `id` to `selected_capabilities` in
   `~/.config/computer-setup/prefs.yml`. Selection is by capability id, not by
   package name.
2. Apply, so Homebrew installs the managed copy.
3. Remove the manual install dir and its `.zshrc` lines.

## PATH priority: managed vs. manual tools

Layers own PATH (typically a `files/shell/*.zsh` snippet), not the orchestrator.
If a layer puts `~/.local/bin` ahead of `/opt/homebrew/bin`, a manually-installed
binary there will **shadow** the Homebrew-managed one. After bringing such a tool
under management, remove the manual copy so the brew version wins.

## Backing up and restoring a machine

`prefs.yml` is this machine's entire declaration — every answer, every
capability selection. `bootstrap.sh --answers <file>` replays one
non-interactively, and `check.sh` asserts a written `prefs.yml` is a valid
answers file, so **a backup is a restorable machine**.

```bash
computer-setup prefs init     # choose the private repo and name this machine
computer-setup prefs push     # back up the current prefs.yml
computer-setup prefs list     # machines backed up in the repo
computer-setup prefs pull work-macbook
```

One file per machine under `machines/<name>.yml`, so a laptop and a desktop keep
separate declarations instead of fighting over one. The machine name is prompted
at `init` — the hostname is a serial number on a corporate Mac, which is exactly
why it is not silently used as the default.

`pull` writes a **file**; it never touches the live `prefs.yml`. Review it, then:

```bash
bootstrap.sh --answers ./work-macbook-prefs.yml
```

so a restore from the wrong machine is a deleted file rather than a reconfigured
laptop.

The repo is **private** and holds git identity and a per-machine software
inventory. Do not make it public, and do not use a secret gist for it — a secret
gist is unlisted, not access-controlled, and anyone with the URL can read it.

It is also **not a content layer**. Layers are force-synced (fetch + hard reset)
by `computer-setup-layers`, which would destroy commits here waiting to push. It
is cloned separately to `~/.local/share/computer-setup/state`.

# Operations

How a run behaves, what it enforces, and hard-won findings from migrating a
manually-configured Mac into this setup. Read this before large re-runs or when
onboarding a machine that already has software installed outside Homebrew.

## git config is included, not imposed

`~/.gitconfig` is **not** owned by this role. It owns
`~/.config/git/computer-setup.gitconfig` and reaches `~/.gitconfig` only to
append one `include.path`. Anything you put in `~/.gitconfig` — signing keys,
credential helpers, your own `includeIf` blocks — is preserved.

The include is appended, so managed values are read **last** and still win over
entries above them. Full enforcement, no collateral damage: `~/.gitconfig` is
never touched beyond that one appended line.

### Per-directory identities

`git_conditional_identities` renders `includeIf` blocks — how a work layer
supplies a work address for its own remotes without touching the machine-wide
identity.

The machine-wide `git_user_name`/`git_user_email` come from questions instead:
a layer may PROPOSE them through a question `default:` (so a private layer can
carry an account's noreply address), and the machine's answer wins. A layer's
`vars.yml` still may not set them — see "The machine tier" in
[architecture.md](architecture.md).

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

## Validating a run

```bash
# Dry run (no changes):
ansible-playbook -i inventory local.yml -e @$HOME/.config/computer-setup/prefs.yml --check

# A fully converged machine reports:  changed=0  failed=0
```

## How user-made changes are handled

### Enforced — your manual change is reverted

| What you change | Behaviour |
|---|---|
| `~/.zshrc` | Replaced from the layer-provided `zshrc` every run (timestamped backup kept). Edit it in the layer. |
| `~/.zsh/*.zsh` managed snippets | Regenerated from the engine template and layer `files/shell/*.zsh`. |
| `~/.config/git/computer-setup.gitconfig` | Re-rendered whole from `gitconfig.j2`. Anything not declared in a layer is dropped. `~/.gitconfig` itself is only appended to — see "Additive" below. |
| `~/.gitignore_global` | Replaced entirely from `git_global_gitignore_entries`. |
| `~/.p10k.zsh` | Replaced from the layer-provided `p10k.zsh`. |
| macOS defaults | `osx_defaults` enforces the layer-declared value; System Settings changes are reverted. |
| NVM default alias | Mismatch is detected and `nvm alias default <declared>` re-run. |
| tfenv active version | Reverted to `runtimes_tfenv_terraform_version` (and never auto-upgraded). |
| Capability config files | Re-deployed from the providing layer whenever the capability is active. |
| `computer-setup-run`, LaunchAgent plists | Regenerated, then the agents are reloaded. |

### Additive — nothing of yours is removed

| What you change | Behaviour |
|---|---|
| Install extra Homebrew packages or VS Code extensions | Preserved. Only listed items are ensured present. |
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

## Adopting manually-installed apps

The `homebrew` role only uses `install_options: adopt` for casks explicitly
listed in `homebrew_adopt_casks`, keeping adoption available for known-safe apps
while avoiding casks whose protected payloads can fail mid-adoption.

### Do not adopt casks with protected payloads

Some casks ship helper files carrying protected extended attributes. During
adoption Homebrew backs up and removes the existing app, then fails when it
cannot rewrite an attribute — leaving **no app** installed.

| Cask | File that triggers the failure |
|---|---|
| `docker-desktop` | `docker-compose.bash-completion` |
| `zed` | `Contents/MacOS/cli` (`com.apple.metadata:kMDItemAlternateNames`) |

Use a fresh install instead of adoption for these. If a previous failed adopt
left a dangling binary symlink, remove it first or the reinstall aborts with
*"there is already a Binary at …"*:

```bash
rm -f /opt/homebrew/bin/zed
brew install --cask zed
```

### Casks that need root: `sudo` has no TTY inside Ansible

Some casks replace files they own as **root**, and Homebrew shells out to `sudo`
to do it. An Ansible task has no controlling terminal, so that `sudo` cannot
prompt:

```
sudo: a terminal is required to read the password
```

Two things that do **not** work, both tried: running `drift-update` from a real
terminal (the terminal you launch from is not the terminal the task runs in), and
pre-caching with `sudo -v` (the ticket is not usable from the task's context).

The fix is an askpass helper. `community.general.homebrew_cask` implements it:
given `sudo_password` it writes a 0700 temp askpass script and exports
`SUDO_ASKPASS`, so Homebrew invokes `sudo -A`. `drift-update` collects the
password in your shell and passes it via the `CS_SUDO_PASSWORD` environment
variable — never `-e`, which would expose it in the process list. Press Enter at
the prompt to skip those casks.

`upgrade_casks_exclude` remains the right tool for a cask whose own updater
should own the job entirely: listing it there keeps it installed and managed but
skips the upgrade.

### Self-updating casks and `greedy`

Most GUI casks update themselves (`auto_updates` in `brew info`).
`brew upgrade --cask --greedy` forces Homebrew to replace them anyway, and the
two update paths race.

Observed failure: an app had already self-updated while the Caskroom still
recorded the previous version. The forced upgrade tried to replace an app that
had changed underneath it, `hdiutil attach` failed `Resource busy`, and
Homebrew's rollback could not find the original to restore — leaving an empty
`/Applications/<App>.app` and a cask reported as *not installed*.

`upgrade_casks_greedy` is therefore **false** by default. Recovering a cask left
in that state:

```bash
# 1. Quit the app.
# 2. If /Applications/<App>.app is an empty directory, remove it:
rmdir /Applications/<App>.app
# 3. Clear Homebrew's partial record and reinstall:
brew uninstall --cask --force <name>
brew install --cask <name>
```

The real app usually survives under
`/opt/homebrew/Caskroom/<name>/<version>.upgrading/` if you need to recover data
first.

Cask upgrades also run **one at a time**: passing the whole list to a single task
meant the first failure aborted the Galaxy and Node upgrades that follow.
Failures are collected and reported together at the end.

### The scheduled agents cannot answer sudo prompts

This is why the 09:00 agent runs with `computer_setup_upgrade_include_casks=false`: formulae,
Galaxy collections and Node all live under `homebrew_prefix` and never need
`sudo`, whereas cask upgrades replace bundles in `/Applications`. Do the initial
cask installs interactively; once the apps are brew-managed, later runs see them
as present and skip the privileged step.

### The connectivity probe must match the transport

The scheduled runner probes GitHub with `git ls-remote` over SSH — the exact
transport the pull uses — not an HTTPS `curl`. An HTTPS probe passes on networks
that allow 443 but block 22 (corporate wifi, hotels, captive portals); the pull
then fails and fires a "drift check failed" notification indistinguishable from a
real breakage. A closed laptop, a blocked port and an unavailable key are all
"can't run right now", and all exit 0 silently.

## PATH priority: managed vs. manual tools

Layers own PATH (typically a `files/shell/*.zsh` snippet), not the orchestrator.
If a layer puts `~/.local/bin` ahead of `/opt/homebrew/bin`, a manually-installed
binary there will **shadow** the Homebrew-managed one. After bringing such a tool
under management, remove the manual copy so the brew version wins.

## Migrating tools off manual installers

Tools installed via vendor scripts leave a footprint (a `~/.tool` dir plus PATH
and completion lines in `.zshrc`). To bring one under management:

1. Add it as a capability in a layer's `capabilities.yml`, then add that
   capability's `id` to `selected_capabilities` in `~/.config/computer-setup/prefs.yml`.
   Selection is by capability id, not by package name.
2. Apply the playbook, so Homebrew installs the managed copy.
3. Remove the manual install dir and its `.zshrc` lines.

## VS Code paths contain spaces

The `code` binary lives at
`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`. Command
tasks must use the `argv:` list form; a plain string is split on whitespace by
`ansible.builtin.command` and fails with
`No such file or directory: /Applications/Visual`.

## gcloud SDK

- The cask token is **`gcloud-cli`**. `google-cloud-sdk` is a deprecated alias;
  using it as a capability's `packages` value breaks idempotency, because brew
  lists it under the canonical name and the module keeps reporting *changed*.
- Auth and config live in `~/.config/gcloud`, *not* in the SDK directory, so a
  manual `~/google-cloud-sdk` install can be removed without losing auth.

## Rust / rustup (intentionally not managed)

`rustup` manages its own toolchains and self-updates; wrapping it in Homebrew or
an Ansible task fights that model, so it is left out on purpose. Install it
headless when needed:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
```

`-y` is what makes it non-interactive. Let rustup manage its own PATH (do not
pass `--no-modify-path`); updates are then `rustup update`, independent of this
repo.

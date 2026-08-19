# Findings

Failures with known causes, and the reasoning behind choices that look wrong
until you know what went wrong. Append-only: each entry exists because something
broke or was tried and rejected, and re-deriving it costs an afternoon.

This is not the runbook — see [operations.md](operations.md) for what a run does.

## Homebrew casks

### Casks with protected payloads must not be adopted

Some casks ship helper files carrying protected extended attributes. During
adoption Homebrew backs up and removes the existing app, then fails when it
cannot rewrite an attribute — leaving **no app** installed.

| Cask | File that triggers the failure |
|---|---|
| `docker-desktop` | `docker-compose.bash-completion` |
| `zed` | `Contents/MacOS/cli` (`com.apple.metadata:kMDItemAlternateNames`) |

Use a fresh install instead of adoption for these. Keep `homebrew_adopt_casks`
an explicit allow-list for this reason. If a previous failed adopt left a
dangling binary symlink, remove it first or the reinstall aborts with *"there is
already a Binary at …"*:

```bash
rm -f /opt/homebrew/bin/zed
brew install --cask zed
```

### `sudo` inside an Ansible task has no controlling terminal — ever

Some casks replace files they own as **root**, and Homebrew shells out to `sudo`.
An Ansible task has no controlling terminal, so that `sudo` cannot prompt:

```
sudo: a terminal is required to read the password
```

Two things that do **not** work, both tried: running the upgrade from a real
terminal (the terminal you launch from is not the terminal the task runs in), and
pre-caching with `sudo -v` (the ticket is not usable from the task's context).

The fix is an askpass helper, which `community.general.homebrew_cask` implements:
given `sudo_password` it writes a 0700 temp askpass script and exports
`SUDO_ASKPASS`, so Homebrew invokes `sudo -A`. `computer-setup upgrade` collects
the password in your shell and passes it via the `CS_SUDO_PASSWORD` environment
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

### `brew outdated` exits 1 to mean "something is outdated"

Like `diff`. So `rc` is useless as an error signal. A real failure (unknown
formula, missing tap) also exits non-zero but writes `Error:` to stderr and
nothing to stdout — and `brew outdated` is all-or-nothing, so one bad name means
nothing was checked. Without distinguishing the two, empty stdout renders as
"(up to date)" when in fact *nothing was verified*.

Related: the `homebrew` and `homebrew_cask` modules **skip entirely under
`--check`**, so a dry run reporting "up to date" can mean "never checked".

## The scheduled agents

### They cannot answer sudo prompts

This is why the 09:00 agent runs with
`computer_setup_upgrade_include_casks=false`: formulae, Galaxy collections and
Node all live under `homebrew_prefix` and never need `sudo`, whereas cask
upgrades replace bundles in `/Applications`. Do the initial cask installs
interactively; once the apps are brew-managed, later runs see them as present and
skip the privileged step.

### The connectivity probe must match the transport

The scheduled runner probes GitHub with `git ls-remote` over SSH — the exact
transport the pull uses — not an HTTPS `curl`. An HTTPS probe passes on networks
that allow 443 but block 22 (corporate wifi, hotels, captive portals); the pull
then fails and fires a "check failed" notification indistinguishable from a real
breakage. A closed laptop, a blocked port and an unavailable key are all "can't
work right now", and all exit 0 silently.

`GIT_SSH_COMMAND` is **exported**, not scoped to the probe: a command-prefix
assignment would leave the layer sync and the pull itself free to hit an
interactive host-key or passphrase prompt, which hangs forever with no TTY.

### A `~` in a templated path is literal in shell, but not in Ansible

`repositories_base_dir` is answered by a human, and `~/Projects` is the natural
answer. Ansible expands `~` whenever a module consumes a path, so that answer is
correct for the `repositories` role and reads fine in every YAML file.

Baked into a shell script it is not. `~` does not expand inside a quoted
assignment, so `REPOS_BASE_DIR="~/Projects"` is a literal directory name that
cannot exist. This broke `computer-setup repos` silently for as long as the
answer had a tilde, and would have made the branch-cleanup agent exit 1 every
morning into a log nobody opens.

Any path a HUMAN answers needs `| expanduser` when it is rendered into a shell
template. Paths the engine builds itself (`home_dir` comes from
`ansible_facts['env']['HOME']`) are already absolute and do not. `expanduser` is
a no-op on an absolute path, so it is safe to apply either way.

The wrong fix is to change the answer to an absolute path: it works, and it
silently ties the machine's config to one username.

## Specific tools

### VS Code paths contain spaces

The `code` binary lives at
`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code`. Command
tasks must use the `argv:` list form; a plain string is split on whitespace by
`ansible.builtin.command` and fails with
`No such file or directory: /Applications/Visual`.

### gcloud SDK

- The cask token is **`gcloud-cli`**. `google-cloud-sdk` is a deprecated alias;
  using it as a capability's `packages` value breaks idempotency, because brew
  lists it under the canonical name and the module keeps reporting *changed*.
- Auth and config live in `~/.config/gcloud`, *not* in the SDK directory, so a
  manual `~/google-cloud-sdk` install can be removed without losing auth.

### nvm and tfenv version specs must be quoted

Both run under zsh, whose `NOMATCH` option makes an unmatched glob a fatal error.
The nvm default is `lts/*`, so an unquoted spec aborts the shell with
"no matches found: lts/\*" before `nvm` is ever invoked — failing the task and
taking the whole play with it. On a fresh machine that meant no LaunchAgents and
no CLI, because `drift_correction` runs after `runtimes`.

### Rust / rustup is intentionally not managed

`rustup` manages its own toolchains and self-updates; wrapping it in Homebrew or
an Ansible task fights that model. Install it headless when needed:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
```

`-y` is what makes it non-interactive. Let rustup manage its own PATH (do not
pass `--no-modify-path`); updates are then `rustup update`, independent of this
repo.

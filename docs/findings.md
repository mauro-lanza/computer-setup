# Findings

Failures with known causes, and the reasoning behind choices that look wrong
until you know what went wrong. Each entry exists because something broke or was
tried and rejected, and re-deriving it costs an afternoon.

Not append-only: an entry whose cause no longer exists — the code path is gone,
the upstream bug is fixed — should be deleted, not left to imply a hazard that
is no longer there. Rewriting an entry to be shorter is always fair.

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

This is why the `brew outdated` tasks are NOT given `check_mode: false`, even
though read-only tasks elsewhere (tfenv's `version-name`, the extension list) do
get it so the drift check can see them. `brew outdated` needs a refreshed index,
which only a mutating `brew update` provides — so under `--check` it reports
"(not checked)" rather than pretending to know.

## Partial failures are reported at the end of the play, not where they happen

`osx_defaults` refuses to change a key's type, so a single wrong `type:` in
layer data is a hard failure — and `macos` runs before `runtimes` and
`scheduled_agents`. Raised in-role, it aborted the play: the first real
fresh-machine bootstrap lost its version managers and its scheduled agents over
a tap-to-click preference. Homebrew casks have the same shape and run even
earlier.

Both are collected with `failed_when: false` / `ignore_errors` and reported from
`post_tasks` in `local.yml` instead. A machine that got 95% configured and says
so is worth more than one that got 20% and stopped. Any new task that can fail
on one item of layer data belongs in that pattern.

Reading the type of a key on a machine this playbook already configured reports
what *this playbook* wrote, not what macOS uses natively — trust a fresh machine:

```bash
defaults read-type <domain> <key>
```

## The upgrade path

Three separate failures here shared one shape: the repair was reachable only by
the code path that was already broken, so the machine could not self-heal and
every scheduled 09:00 upgrade failed identically until someone intervened by
hand. That is why the Galaxy tasks in `roles/upgrade/tasks/main.yml` look
over-engineered for "install some collections".

### The Galaxy install must be the first task in the block

A `community.general` collection too stale for the installed `ansible-core`
fails at result deserialization (*"Unknown profile name 'module_legacy_m2c'"*).
Every task in the upgrade block uses that collection except the
`ansible-galaxy` call that repairs it.

That call used to sit third. A stale collection broke the formulae upgrade above
it, the block aborted, and the repair never ran — permanently. Observed
2026-08-05. It is a plain command with no collection dependency, so first is the
only position where it always executes.

### `--upgrade` is keyed on the running core, not on "is brew about to bump ansible?"

The obvious signal is the wrong one. It sees only the bumps this playbook
performs, so a core upgraded any other way — a manual `brew upgrade`, or ansible
pulled in as another formula's dependency — never triggers it, and the stale
collection stays stale forever. The same permanent-failure loop, re-entered
through a side door.

Comparing against the recorded `upgrade_galaxy_core_marker` catches every path,
because it compares against what is actually running. The marker is written only
after a successful install, so a failed run retries with `--upgrade` instead of
assuming the repair happened.

This repairs on the run *after* the core changes, which is soon enough: upgrading
the `ansible` formula mid-play does not change the already-running interpreter,
so the rest of the play still executes under the old core.

### `--clear-response-cache` on every run

Galaxy's `galaxy_cache/api.json` can be poisoned by one bad response, after which
every `ansible-galaxy` call fails for the full 24h TTL (*"Missing expected
'results' in ansible-galaxy cache"*). Observed 2026-08-16 and 2026-08-17.
Starting from a cold cache is what makes that self-healing.

Note this is cheap: without `--upgrade` the install is satisfied from disk with
no API round trip at all. The daily round trip it replaced bought nothing —
`community.general` releases nowhere near daily.

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

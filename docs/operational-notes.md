# Operational Notes & Findings

Hard-won findings from provisioning and migrating a manually-configured Mac
into this IaC setup. Read this before large re-runs or when onboarding a
machine that already has software installed outside Homebrew.

## Adopting manually-installed apps

The `homebrew` role only uses `install_options: adopt` for casks explicitly
listed in `homebrew_adopt_casks`. That keeps adoption available for known-safe
apps while avoiding casks whose protected payloads can fail mid-adoption.

### Adopt is explicitly allow-listed
Currently allow-listed: Rectangle, Visual Studio Code, Firefox, Discord,
Spotify.

### Do not adopt casks with protected payloads
Some casks ship helper files carrying protected/immutable extended
attributes. During adoption Homebrew backs up and removes the existing app,
then fails when it can't rewrite an extended attribute — leaving **no app**
installed.

| Cask | File that triggers the failure |
|---|---|
| `docker-desktop` | `docker-compose.bash-completion` |
| `zed` | `Contents/MacOS/cli` (`com.apple.metadata:kMDItemAlternateNames`) |

These casks should use a fresh Homebrew install instead of adoption:

```bash
brew install --cask docker-desktop
brew install --cask zed
```

If a previous failed adopt left a **dangling binary symlink** (e.g.
`/opt/homebrew/bin/zed` → a now-deleted app), remove it first or the
reinstall aborts with *"there is already a Binary at …"*:

```bash
rm -f /opt/homebrew/bin/zed
brew install --cask zed
```

### Self-updating casks and `greedy`
Most GUI casks here update themselves (`auto_updates` in `brew info`): Spotify,
Docker Desktop, VS Code, Firefox, Discord, Zed, Stats, Rectangle, gcloud-cli,
Antigravity, opencode-desktop. `brew upgrade --cask --greedy` forces those to be
replaced by Homebrew anyway, and the two update paths race.

Observed failure: Spotify had already self-updated `/Applications/Spotify.app`
to a newer build while the Caskroom still recorded the previous version. The
forced upgrade tried to replace an app that had changed underneath it,
`hdiutil attach` failed `Resource busy`, and Homebrew's automatic rollback then
could not find the original app to restore. The result was an **empty**
`/Applications/Spotify.app`, a `<version>.upgrading` directory holding the real
app, and `brew list --cask spotify` reporting *not installed*.

`upgrade_casks_greedy` is therefore **false** by default. Self-updaters keep
themselves current; forcing them buys nothing. Set it true only with the apps
quit.

**Recovering a cask left in that state:**

```bash
# 1. Quit the app.
# 2. If /Applications/<App>.app is an empty directory, remove it:
rmdir /Applications/Spotify.app
# 3. Clear Homebrew's partial record and reinstall:
brew uninstall --cask --force spotify
brew install --cask spotify
```

The real app usually survives under
`/opt/homebrew/Caskroom/<name>/<version>.upgrading/` if you need to recover data
before reinstalling.

Cask upgrades also run **one cask at a time**. Passing the whole list to a single
task meant the first failure aborted everything after it — including the Ansible
Galaxy and Node upgrades that follow. Failures are now collected and reported
together at the end of the run.

### The scheduled agents cannot answer sudo prompts
Installing casks that touch system-owned paths can trigger a `sudo`
password prompt. A LaunchAgent (and any unattended `ansible-pull`) has no
TTY and the cask task fails. **Do the initial cask installs interactively**,
then re-run the playbook — once the apps are brew-managed,
subsequent runs see them as present and skip the privileged step.

This is why the 09:00 upgrade agent runs with `upgrade_include_casks=false`:
formulae, Galaxy collections and Node all live under `{{ homebrew_prefix }}` and
never need `sudo`, whereas cask upgrades replace app bundles in `/Applications`.
Cask upgrades are reserved for the interactive `drift-update`.

### The connectivity probe must match the transport
The scheduled runner probes GitHub with `git ls-remote` over SSH — the exact
transport the pull uses — not an HTTPS `curl`. An HTTPS probe passes on networks
that allow 443 but block 22 (corporate wifi, hotels, captive portals); the pull
then fails on SSH and fires a "drift check failed" notification indistinguishable
from a real breakage. A closed laptop, a blocked port and an unavailable key are
all "can't run right now", and all exit 0 silently.

## gcloud SDK

- The cask token is **`gcloud-cli`**. `google-cloud-sdk` is a deprecated
  alias; using the alias in `optional_casks` breaks idempotency (brew lists
  it under the canonical name, so the module keeps reporting *changed*).
- Install layout: SDK at `/opt/homebrew/share/google-cloud-sdk`; `gcloud`,
  `gsutil`, `bq` symlinked into `/opt/homebrew/bin`; zsh completion linked
  into `site-functions`.
- **Auth/config lives in `~/.config/gcloud`**, *not* in the SDK directory.
  A manual `~/google-cloud-sdk` install can be removed without losing auth.

## PATH priority: managed vs. manual tools

The public layer's `files/shell/10-path.zsh` prepends `/opt/homebrew/bin`,
`/opt/homebrew/sbin`, and `~/.local/bin` (each prepended in turn, so `~/.local/bin`
ends up **highest priority** — above `/opt/homebrew/bin`). PATH is layer content,
not an orchestrator template. Consequence: a manually-installed binary in
`~/.local/bin` (e.g. a curl'd `duckdb`) will **shadow** the Homebrew-managed one.
After adding such a tool to the catalog, remove the manual copy so the brew
version wins:

```bash
rm -f ~/.local/bin/duckdb
```

## Non-destructive guarantees

- The `homebrew` role is `state: present` only — **no prune/absent**.
  Applying never uninstalls manually-installed apps, unmanaged Homebrew
  leaves, or extra Python versions. Removing an item from the baseline
  lists just stops *enforcing* it; nothing is uninstalled.
- Cleanup of unwanted software is therefore always a **manual, deliberate**
  step, never a side effect of a run.

## VS Code role and paths with spaces

The `code` binary lives at
`/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code` — the
path contains spaces. Command tasks must use the `argv:` list form;
a plain string is split on whitespace by `ansible.builtin.command` and fails
with `No such file or directory: /Applications/Visual`.

## Migrating tools off manual installers

Tools installed via vendor scripts leave a footprint (a `~/.tool` dir plus
`PATH`/completion lines in `.zshrc`). To bring one under management:

1. Add it as a capability in a content layer's `capabilities.yml`, then add that
   capability's `id` to `selected_capabilities` in `~/.mac-prefs.yml`.
   (Selection is by capability id, not by package name.)
2. Apply the playbook (Homebrew installs the managed copy).
3. Remove the manual install dir and its `.zshrc` lines — the managed
   `path.zsh` already covers `/opt/homebrew/bin`.

Migrated in this repo's history: **bun** (`~/.bun`), **gcloud**
(`~/google-cloud-sdk`), **duckdb** (`~/.local/bin`).

## Rust / rustup (intentionally NOT managed)

The Rust toolchain (`~/.cargo`, `~/.rustup`) is installed via `rustup`, which
manages its own toolchains and self-updates — wrapping it in Homebrew or an
Ansible task fights that model, so it is left out of the playbook on purpose.

If you need Rust on a machine, install it **headless** (unattended, no
prompts) with:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
# minimal profile variant:
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
  -y --profile minimal
```

The `-y` flag is what makes it non-interactive. By default rustup appends a
`~/.cargo/bin` line to the shell profile — the managed `path.zsh` does **not**
cover `~/.cargo/bin`, so let rustup handle its own PATH (don't pass
`--no-modify-path`). Day-to-day updates are then `rustup update`, independent
of this repo.

## Validating a run

```bash
# Dry run (no changes):
ansible-playbook -i inventory local.yml -e @$HOME/.mac-prefs.yml --check

# A fully converged machine reports:  changed=0  failed=0
```

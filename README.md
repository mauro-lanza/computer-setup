# computer-setup

Generalized, open-source macOS provisioning framework. An Ansible **orchestrator**
(the engine) consumes pluggable **content layers** (your data), so the core stays
public and shareable while personal and work data live in separate repos.

Two LaunchAgents run each morning: at 09:00 managed tools are upgraded, and at
10:00 the playbook re-runs in check mode and notifies you when the machine drifts
from the declared state — across the orchestrator *and* every layer.

## Why layers?

The orchestrator defines *how* to configure a Mac (roles, templates, bootstrap
flow, and a versioned variable interface). It contains **no personal data** — only
safe empty defaults. Everything machine-, person-, or job-specific comes from
content layers you plug in:

| | Repo | Contains |
|---|---|---|
| **Orchestrator** | this repo (public) | roles, bootstrap, contract, example layer |
| **Public layer** | `computer-setup-layer-public` | baseline brew tools, VS Code/editor settings, prompt, catalog |
| **Personal layer** | `computer-setup-layer-personal` (private) | personal repos & tools |
| **Work layer** | `computer-setup-layer-work` (private) | employer repos, dbt project/schema |

Changing jobs = swap one layer, touch nothing else.

## Requirements

- **macOS 13 Ventura or newer**, **Apple Silicon (arm64)**. The playbook asserts
  `Darwin` + `arm64`; `homebrew_prefix` is `/opt/homebrew`.
- **Xcode Command Line Tools** — Homebrew's installer triggers the OS dialog
  automatically.

## Quick start

```bash
# One-liner on a fresh Mac (must be run from a terminal — bootstrap is interactive):
bash <(curl -fsSL https://raw.githubusercontent.com/mauro-lanza/computer-setup/main/bootstrap.sh)

# Or clone first after GitHub SSH auth (gives you the repo for later edits):
git clone git@github.com:mauro-lanza/computer-setup.git
cd computer-setup
./bootstrap.sh
```

Bootstrap prompts for layers and git identity, so it needs a terminal. Piping
(`curl … | bash`) also works — the script reattaches stdin to `/dev/tty` — but
process substitution above is preferred because it never puts the script on
stdin in the first place. With no TTY at all (CI, `nohup`), bootstrap fails with
an explicit message rather than silently accepting every default.

`bootstrap.sh` runs four phases (numbered as the script's own banners do, 0-3):

0. **Prerequisites + GitHub auth** — platform check → Xcode CLT → Homebrew →
   `yq`/`git`/`gh`/`ansible` → `gh auth login` (browser device flow + SSH key).
   Auth completes before any layer is cloned, and readiness is confirmed with a
   real `git ls-remote` over SSH rather than `gh auth status`.
1. **Layer selection & fetch** — define/modify your layer manifest (persisted to
   `~/.config/computer-setup/layers.yml`), then clone each layer into the plugin
   cache (`~/.local/share/computer-setup/plugins/<name>/`). GitHub layers clone
   over SSH. Each layer's `schema_version` is validated.
2. **Build preferences** — merge every layer's `capabilities.yml` into one menu,
   prompt for git identity and optional tools, then write `~/.mac-prefs.yml`.
3. **Run Ansible** — `ansible-pull` this orchestrator, merging the layer vars and
   resolving layer files.

## How layers merge

Layers merge in ascending `priority` order (higher wins on scalar conflicts):

| Type | Strategy |
|---|---|
| Catalog items | Union, dedup by `id` |
| **List** vars (`repositories`, `homebrew_baseline_formulae`, …) | **Append** across layers |
| **Scalar** vars (`dbt_bigquery_project`, …) | **Override**, highest priority wins, with an info message on overlap |
| Files (`p10k.zsh`, editor settings) | Resolved across layers by priority (highest wins); skipped when no layer provides the file |

## Writing your own layer

Copy [examples/example-layer/](examples/example-layer) into a new git repo:

```
your-layer/
  plugin.yml     # manifest (required): name, schema_version, priority, provides
  capabilities.yml # selectable capability bundles (menu + config + adopt)
  vars.yml       # optional variable values (the role interface)
  files/         # optional static files roles resolve by key
  templates/     # optional templates roles resolve by key
```

Then add it during `bootstrap.sh` Phase 1 (layer selection), or edit
`~/.config/computer-setup/layers.yml` directly (see
[layers.example.yml](layers.example.yml)).

The **variable interface** plus `schema_version` is the public API — see
[docs/architecture.md](docs/architecture.md).

## Maintenance helpers

Shell functions installed by the setup. The three that run the playbook
(`drift-check`, `drift-apply`, `drift-update`) delegate to
`~/.local/bin/computer-setup-run`, which owns the `ansible-pull` invocation so
the scheduled agents and the interactive commands can never drift apart.
(`bootstrap.sh` builds its own invocation — it runs before the runner exists.)

- `drift-check` — run the same check the 10:00 agent runs (never mutates).
- `drift-apply` — reconcile detected drift now (`ansible-pull` for real).
- `drift-update` — upgrade managed tools **including casks**, with a confirmation
  prompt. The 09:00 agent already upgrades formulae, Galaxy collections and Node;
  casks are left to this command because they can raise a `sudo` prompt that an
  unattended agent has no TTY to answer.
- `drift-log` — tail the rolling drift log (reads the log file directly).
- `repos-generate` — scaffold a `~/.repositories.yml` override from this machine
  (inspects your checkouts; does not run the playbook).

Plus one standalone command in `~/.local/bin`:

- `macos-capture` — read-only; diffs this machine's live macOS `defaults`
  against the values declared by your layers and emits paste-ready YAML, so a
  setting you tweaked in System Settings can be adopted back into a layer's
  `vars.yml`. `macos-capture --domain <domain>` dumps every key in a domain to
  discover new ones.

To clone catalogued repos that are missing, run `drift-apply --tags repositories`.

## Documentation

- [docs/architecture.md](docs/architecture.md) — the orchestrator + layers contract.
- [docs/playbook-execution.md](docs/playbook-execution.md) — what each run does.
- [docs/operational-notes.md](docs/operational-notes.md) — hard-won provisioning findings.

## License

[MIT](LICENSE).

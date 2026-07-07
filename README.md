# computer-setup

Generalized, open-source macOS provisioning framework. An Ansible **orchestrator**
(the engine) consumes pluggable **content layers** (your data), so the core stays
public and shareable while personal and work data live in separate repos.

A LaunchAgent re-runs the playbook in check mode daily and notifies you when the
machine drifts from the declared state — across the orchestrator *and* every layer.

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
# One-liner on a fresh Mac (orchestrator is public — pulls anonymously):
curl -fsSL https://raw.githubusercontent.com/mauro-lanza/computer-setup/main/bootstrap.sh | bash

# Or clone first (gives you the repo for later edits):
git clone https://github.com/mauro-lanza/computer-setup.git
cd computer-setup
./bootstrap.sh
```

`bootstrap.sh` runs four phases:

1. **Prerequisites + GitHub auth** — platform check → Xcode CLT → Homebrew →
   `yq`/`git`/`gh`/`ansible` → `gh auth login` (browser device flow + SSH key).
   Auth completes *before* any private layer is cloned.
2. **Layer selection & fetch** — define/modify your layer manifest (persisted to
   `~/.config/computer-setup/layers.yml`), then clone each layer into the plugin
   cache (`~/.local/share/computer-setup/plugins/<name>/`). Public layers clone
   over HTTPS, private over SSH. Each layer's `schema_version` is validated.
3. **Build preferences** — merge every layer's `catalog.yml` into one menu, prompt
   for git identity, optional tools, and feature toggles, then write
   `~/.mac-prefs.yml`.
4. **Run Ansible** — `ansible-pull` this orchestrator, merging the layer vars and
   resolving layer files.

## How layers merge

Layers merge in ascending `priority` order (higher wins on scalar conflicts):

| Type | Strategy |
|---|---|
| Catalog items | Union, dedup by `id` |
| **List** vars (`repositories`, `homebrew_mandatory_formulae`, …) | **Append** across layers |
| **Scalar** vars (`dbt_bigquery_project`, …) | **Override**, highest priority wins, with an info message on overlap |
| Files (`p10k.zsh`, editor settings) | Resolved across layers by priority (highest wins), falling back to a role's bundled copy |

## Writing your own layer

Copy [examples/example-layer/](examples/example-layer) into a new git repo:

```
your-layer/
  plugin.yml     # manifest (required): name, schema_version, priority, provides
  catalog.yml    # optional selectable menu items (union-merged)
  vars.yml       # optional variable values (the role interface)
  files/         # optional static files roles resolve by key
```

Then add it during `bootstrap.sh` Phase 1, or edit
`~/.config/computer-setup/layers.yml` directly (see
[layers.example.yml](layers.example.yml)).

The **variable interface** plus `schema_version` is the public API — see
[docs/architecture.md](docs/architecture.md).

## Maintenance helpers

Shell functions installed by the setup:

- `drift-apply` — reconcile detected drift now (`ansible-pull` for real).
- `drift-update` — run the opt-in `upgrade` role (`--tags upgrade`).
- `repos-resurrect` — clone the merged `repositories` list (`--tags repositories`).
- `repos-generate` — scaffold a `~/.repositories.yml` override from this machine.

## Documentation

- [docs/architecture.md](docs/architecture.md) — the orchestrator + layers contract.
- [docs/playbook-execution.md](docs/playbook-execution.md) — what each run does.
- [docs/operational-notes.md](docs/operational-notes.md) — hard-won provisioning findings.

## License

[MIT](LICENSE).

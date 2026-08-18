# computer-setup

Generalized macOS provisioning framework. An Ansible **orchestrator** (the
engine) consumes pluggable **content layers** (your data), so the core stays
public and shareable while personal and work data live in separate repos.

Scheduled LaunchAgents run each morning: at 09:00 managed tools are upgraded, at
10:00 the playbook re-runs in check mode and notifies you when the machine has
drifted from the declared state — across the orchestrator *and* every layer.
Layers can schedule jobs of their own on the same mechanism (see
`scheduled_agents`).

## Why layers?

The orchestrator defines *how* to configure a Mac. It contains **no personal
data** — only safe empty defaults. Everything machine-, person-, or job-specific
comes from content layers you plug in:

| | Repo | Contains |
|---|---|---|
| **Orchestrator** | this repo (public) | roles, bootstrap, contract, example layer |
| **Public layer** | `computer-setup-layer-public` | baseline brew tools, editor settings, prompt, capabilities |
| **Personal layer** | `computer-setup-layer-personal` (private) | personal repos & tools |
| **Work layer** | `computer-setup-layer-work` (private) | employer repos, dbt project/schema |

Changing jobs = swap one layer, touch nothing else.

## Requirements

- **macOS 13 Ventura or newer**, **Apple Silicon (arm64)**. The playbook asserts
  `Darwin` + `arm64`; `homebrew_prefix` is `/opt/homebrew`.
- **Xcode Command Line Tools** — Homebrew's installer triggers the OS dialog.

## Quick start

```bash
# One-liner on a fresh Mac (must be run from a terminal — bootstrap is interactive):
bash <(curl -fsSL https://raw.githubusercontent.com/mauro-lanza/computer-setup/main/bootstrap.sh)

# Or clone first after GitHub SSH auth (gives you the repo for later edits):
git clone git@github.com:mauro-lanza/computer-setup.git
cd computer-setup
./bootstrap.sh
```

Bootstrap prompts for layers and setup decisions, so it needs a terminal. Piping
(`curl … | bash`) also works — the script reattaches stdin to `/dev/tty` — but
process substitution is preferred because it never puts the script on stdin in
the first place. With no TTY at all (CI, `nohup`), bootstrap fails with an
explicit message rather than silently accepting every default.

`bootstrap.sh` runs four phases:

0. **Prerequisites + GitHub auth** — platform check → Xcode CLT → Homebrew →
   `yq`/`git`/`gh`/`ansible` → `gh auth login`. Auth completes before any layer
   is cloned, and readiness is confirmed with a real `git ls-remote` over SSH.
1. **Layer selection & fetch** — define your layer manifest (persisted to
   `~/.config/computer-setup/layers.yml`), then clone each layer into
   `~/.local/share/computer-setup/layers/<name>/`, validating `schema_version`.
2. **Build preferences** — offer the layers' presets as a starting point, then
   merge every layer's `questions.yml` into one set of decisions and every
   `capabilities.yml` into one menu, prompt for both, and write
   `~/.config/computer-setup/prefs.yml`. Git identity is one of those decisions, so a private
   layer can pre-fill it rather than have it retyped.
3. **Run Ansible** — `ansible-pull` this orchestrator with the merged input.

## Writing your own layer

Copy [examples/example-layer/](examples/example-layer) into a new git repo:

```
your-layer/
  layer.yml         # manifest (required): name, schema_version
  capabilities.yml  # selectable capability bundles (menu + config + adopt)
  questions.yml     # optional single-select/free-text machine decisions
  presets.yml       # optional named starting points for the bootstrap prompts
  vars.yml          # optional variable values (the role interface)
  files/            # optional static files roles resolve by key
  templates/        # optional templates roles resolve by key
```

Add it during `bootstrap.sh` Phase 1, or edit
`~/.config/computer-setup/layers.yml` directly (see
[layers.example.yml](layers.example.yml)), which is also where merge `priority`
is declared.

The **variable interface** plus `schema_version` is the public API. Merge rules,
the capability model, and reserved keys are all specified in
[docs/architecture.md](docs/architecture.md).

## The `computer-setup` command

One command in `~/.local/bin` operates the whole system. It owns the
`ansible-pull` invocation — repo, branch, prefs, layer cache, layer manifest —
so the scheduled agents and everything you type by hand can never drift apart.

- `computer-setup apply` — reconcile the machine now. Streams to your terminal.
- `computer-setup check` — the same check the 10:00 agent runs (never mutates).
- `computer-setup upgrade` — upgrade managed tools **including casks**, with
  confirmation. The 09:00 agent already upgrades formulae, Galaxy collections
  and Node; casks are left to this command because they can raise a `sudo`
  prompt that an unattended agent has no TTY to answer.
- `computer-setup log [n]` — tail the rolling log.
- `computer-setup repos` — scaffold a `repositories.yml` from this machine's
  checkouts. To clone the ones that are *missing*, run
  `computer-setup apply --tags repositories`.
- `computer-setup capture` — read-only; diffs this machine's live macOS
  `defaults` against the values declared by your layers and emits paste-ready
  YAML, so a setting you tweaked in System Settings can be adopted back into a
  layer. `computer-setup capture --domain <domain>` dumps every key in a domain.
- `computer-setup layers sync …` — refresh the content-layer cache.

`computer-setup` with no arguments prints this list.

## Documentation

- [docs/architecture.md](docs/architecture.md) — the orchestrator + layer
  contract, and the reasoning behind it.
- [docs/operations.md](docs/operations.md) — what a run does to the machine, and
  what it will and won't touch.
- [docs/findings.md](docs/findings.md) — failures with known causes, and choices
  that look wrong until you know what went wrong.
- [CONTRIBUTING.md](CONTRIBUTING.md) — development setup and checks.

## License

[MIT](LICENSE).

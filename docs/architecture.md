# Architecture

`computer-setup` is the orchestrator: it owns bootstrap, Ansible roles, merge
logic, and the layer contract. Personal, work, and shareable machine content live
in content layers.

## Repositories

| Repository | Role |
|---|---|
| `computer-setup` | Orchestrator with safe empty defaults. |
| `computer-setup-layer-public` | Shareable baseline catalog, vars, and files. |
| `computer-setup-layer-personal` | Personal repositories and private personal data. |
| `computer-setup-layer-work` | Work repositories and work-specific configuration. |

## Layer Contract

Each layer is a git repo with this structure:

```text
plugin.yml     # required manifest: name, schema_version, priority, provides
catalog.yml    # optional bootstrap menu items
vars.yml       # optional role variable values
files/         # optional static files resolved by roles
templates/     # optional templates resolved by roles
```

The public API is the role variable interface plus `schema_version`. Bump the
orchestrator-supported schema version when changing that contract in a breaking
way.

## Merge Rules

| Input | Rule |
|---|---|
| Catalog items | Union by `id`; highest-priority layer wins duplicate ids. |
| List vars | Append across layers with duplicate replacement semantics from Ansible `append_rp`. |
| Scalar vars | Highest-priority layer wins; overrides are reported. |
| Files/templates | Highest-priority layer wins; absent files are skipped. |

Layers are applied in ascending priority order, so higher-priority layers are
merged last.

## Runtime Flow

1. `bootstrap.sh` installs prerequisites and authenticates GitHub with SSH.
2. The user defines a layer manifest at `~/.config/computer-setup/layers.yml`.
3. Layers are cloned to `~/.local/share/computer-setup/plugins/<name>/`.
4. Catalogs are merged and `~/.mac-prefs.yml` is written.
5. `ansible-pull` applies the orchestrator with the layer manifest/cache paths.
6. Drift correction refreshes the orchestrator and layer cache before check-mode.

## Managed State

The orchestrator can run with no layers, but then it intentionally manages almost
nothing beyond engine-owned helpers. Parity with the old single-repo setup
requires the expected content layers to be active.

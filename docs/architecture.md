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
capabilities.yml # selectable capability bundles (packages, config, adopt, reminders)
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
| Capabilities (`capabilities.yml`) | Union by `id` into one registry; highest-priority layer wins duplicate ids. |
| List vars | Append across layers with duplicate replacement semantics from Ansible `append_rp`. |
| Scalar vars | Highest-priority layer wins; overrides are reported. |
| Files/templates | Highest-priority layer wins; absent files are skipped. |

Layers are applied in ascending priority order, so higher-priority layers are
merged last.

## The capability model

Selecting a tool records its capability `id` in `selected_capabilities` (the only
selection state in `~/.mac-prefs.yml`). The engine merges every layer's
`capabilities.yml` into a registry and derives the whole role interface from the
active set — the engine hardcodes no package names or paths:

- **active capabilities** = `selected_capabilities` ∪ any capability whose
  `adopt_if_present` path exists (adopt an already-installed tool).
- **packages** (`homebrew_optional_*`, `vscode_optional_extensions`) come from the
  *selected* capabilities' `packages`, split by `type`.
- **config deploys** (`computer_setup_config_deploys`) and **reminders**
  (`computer_setup_reminders`) come from the *active* capabilities' `config` /
  `reminders` bundles.
- Roles and shell snippets gate on membership in the active set; a shell snippet
  self-declares its gate with a `# cs:requires-capability: <id>` directive.

Always-on **baseline** config (mandatory-for-this-layer packages, `macos_defaults`,
`git_config_sections`, …) is plain flat layer vars, separate from opt-in
capabilities.

## Runtime Flow

1. `bootstrap.sh` installs prerequisites and authenticates GitHub with SSH.
2. The user defines a layer manifest at `~/.config/computer-setup/layers.yml`.
3. Layers are cloned to `~/.local/share/computer-setup/plugins/<name>/`.
4. `capabilities.yml` is merged into the bootstrap menu; the user's selections are
   written to `~/.mac-prefs.yml` as `selected_capabilities`.
5. `ansible-pull` applies the orchestrator with the layer manifest/cache paths.
6. Drift correction refreshes the orchestrator and layer cache before check-mode.

## Orchestrator Primitives

The top-level playbook delegates setup work to the `computer_setup` role:

| Primitive | Purpose |
|---|---|
| `roles/computer_setup/tasks/main.yml` | Platform check, prefs loading, layer var merge, capability registry + adoption probe, and the derived interface (packages, config deploys, reminders). |
| `roles/computer_setup/tasks/merge_layer_capabilities.yml` | Merge one layer's `capabilities.yml` into the capability registry. |
| `roles/computer_setup/tasks/resolve_layer_file.yml` | Resolve one static file from active layers by priority. |
| `roles/computer_setup/tasks/resolve_layer_template.yml` | Resolve one template from active layers by priority. |
| `roles/computer_setup/tasks/deploy_layer_file.yml` | Resolve **and** deploy one layer file/template to a destination (creates the parent dir, copies or templates, no-op when unprovided). The primitive behind capability config, the prompt, dbt profiles, and `~/.zshrc`. |
| `scripts/computer-setup-layers` | Sync layer repos into the plugin cache for bootstrap and drift. |

See [managers.md](managers.md) for the full manager registry (generated from each
role's `meta/manager.yml`).

Machine-local keys (`selected_capabilities`, `git_user_name`, `git_user_email`)
are reserved for `computer_setup_prefs_file` and are rejected from layer
`vars.yml`, as are engine-owned play vars (`home_dir`, `repo_url`, `repo_branch`,
`homebrew_prefix`, `vscode_code_binary`, `repositories_base_dir`) and the whole
`computer_setup_*` namespace — a layer cannot override the orchestrator itself.
The layer sync helper validates manifest entries before use: layer names must be
unique, required fields must be present, priorities must be numeric, and
`plugin.yml.name` must match the manifest name.

## Managed State

The orchestrator can run with no layers, but then it intentionally manages almost
nothing beyond engine-owned helpers. Parity with the old single-repo setup
requires the expected content layers to be active.

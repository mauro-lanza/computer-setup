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

Always-on **baseline** config (packages this layer always installs, `macos_defaults`,
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
| `roles/computer_setup/tasks/deploy_layer_file.yml` | Resolve **and** deploy one layer file/template to a destination (creates the parent dir, copies or templates, no-op when unprovided). The primitive behind every "a layer supplies this file" case: capability `config:` bundles, the prompt, VS Code settings, and `~/.zshrc`. |
| `roles/computer_setup/tasks/merge_layer_vars.yml` | Merge one layer's `vars.yml` into play scope: enforces `schema_version`, rejects reserved keys, appends lists and overrides scalars by priority. |
| `scripts/computer-setup-layers` | Sync layer repos into the plugin cache for bootstrap and drift. Validates layer names, `schema_version`, and force-syncs the cache to `origin` (fetch + hard reset), so a diverged or hand-edited cache can never silently persist. |

See [managers.md](managers.md) for the full manager registry (generated from each
role's `meta/manager.yml`).

### Reserved keys

A layer's `vars.yml` may not define certain keys. The authoritative list is
`computer_setup_reserved_layer_keys` in
[`roles/computer_setup/tasks/main.yml`](../roles/computer_setup/tasks/main.yml)
— it is enforced by an assert in `merge_layer_vars.yml`, and deliberately not
re-listed here, because an enumeration in prose is a copy that goes stale (this
one did). The categories are:

1. **Machine-local prefs** — belong in `~/.mac-prefs.yml`, not a layer
   (`selected_capabilities`, git identity).
2. **Engine-owned play/role vars** — a layer overriding these would break the
   orchestrator (`home_dir`, `repo_url`, `homebrew_prefix`, the repository
   catalog paths, …), plus the entire `computer_setup_*` namespace, which is
   additionally guarded by prefix rather than by name.
3. **Vars that decide what code runs, or runs unattended** — everything baked
   into the deployed runner script and the scheduled agents
   (`drift_correction_*`), the upgrade auto-approval switches, and Ansible's own
   execution controls (`ansible_connection`, `ansible_python_interpreter`, …).

Category 3 is the security boundary. Layer vars land in play scope via
`set_fact`, which outranks both role defaults and play vars — so without it, a
compromised layer repo could redirect the unattended morning `ansible-pull` at
its own playbook. Both the reserved-key and `schema_version` guards are covered
by `tests/negative.yml`, which asserts they actually *reject* rather than
silently degrade.

The layer sync helper validates manifest entries before use: layer names must be
unique and shell/path-safe, required fields must be present, priorities must be
numeric, and `plugin.yml.name` must match the manifest name.

## Managed State

The orchestrator can run with no layers, but then it intentionally manages almost
nothing beyond engine-owned helpers. Parity with the old single-repo setup
requires the expected content layers to be active.

# Architecture

`computer-setup` is the orchestrator: it owns bootstrap, the Ansible roles, the
merge logic, and the layer contract. Personal, work, and shareable machine
content live in content layers.

## Layer contract

Each layer is a git repo with this structure:

```text
layer.yml         # required manifest: name, schema_version
capabilities.yml  # selectable capability bundles (packages, config, adopt, reminders)
vars.yml          # optional role variable values
files/            # optional static files resolved by roles
templates/        # optional templates resolved by roles
```

Merge `priority` is declared in the *manifest*
(`~/.config/computer-setup/layers.yml`), not in `layer.yml` — one source of
truth, so a layer cannot disagree with the machine about its own ordering.

The public API is the role variable interface plus `schema_version`. Bump the
orchestrator-supported maximum (`computer_setup_schema_version` in `local.yml`,
`SCHEMA_VERSION_MAX` in `bootstrap.sh`) when changing that contract in a
breaking way.

## Merge rules

Layers are applied in ascending priority order, so higher-priority layers merge
last and win.

| Input | Rule |
|---|---|
| Capabilities (`capabilities.yml`) | Union by `id` into one registry; the highest-priority layer wins a duplicate id **wholesale**, not field-wise. |
| List vars | Append across layers (Ansible `append_rp` semantics). |
| Scalar vars | Highest-priority layer wins; overrides are reported at runtime. |
| Files/templates | Highest-priority layer wins; absent files are skipped, not an error. |

A key whose value is null (a bare `some_key:` with no entries) is dropped before
merging, so the consuming role's own default applies.

## The capability model

Selecting a tool records its capability `id` in `selected_capabilities` — the
only selection state in `~/.mac-prefs.yml`. The engine merges every layer's
`capabilities.yml` into a registry and derives the whole role interface from it,
so the engine hardcodes no package names or paths:

- **active capabilities** = `selected_capabilities` ∪ any capability whose
  `adopt_if_present` path exists (adopting an already-installed tool).
- **packages** (`homebrew_optional_*`, `vscode_optional_extensions`) come from
  the *selected* capabilities' `packages`, split by `type`.
- **config deploys** (`computer_setup_config_deploys`) and **reminders**
  (`computer_setup_reminders`) come from the *active* capabilities.
- Roles and shell snippets gate on membership in the active set; a snippet
  self-declares its gate with a `# cs:requires-capability: <id>` directive.

That selected/active split is deliberate: install only what you asked for, but
manage the config of anything already present.

Always-on **baseline** content (`homebrew_baseline_*`, `macos_defaults`,
`git_config_sections`, …) is plain flat layer vars, separate from opt-in
capabilities.

## Runtime flow

1. `bootstrap.sh` installs prerequisites and authenticates GitHub over SSH.
2. The user defines a layer manifest at `~/.config/computer-setup/layers.yml`.
3. Layers are cloned to `~/.local/share/computer-setup/layers/<name>/`.
4. `capabilities.yml` files are merged into the bootstrap menu; selections are
   written to `~/.mac-prefs.yml`.
5. `ansible-pull` applies the orchestrator with the layer manifest/cache paths.
6. Thereafter the scheduled agents refresh the orchestrator and the layer cache
   before every check, so drift covers layer content too.

## Orchestrator primitives

`local.yml` delegates all layer handling to the `computer_setup` role:

| Primitive | Purpose |
|---|---|
| `tasks/main.yml` | Platform check, prefs loading, layer var merge, capability registry + adoption probe, and the derived interface (packages, config deploys, reminders). |
| `tasks/merge_layer_vars.yml` | Merge one layer's `vars.yml` into play scope: enforces `schema_version`, rejects reserved keys, appends lists, overrides scalars. |
| `tasks/merge_layer_capabilities.yml` | Merge one layer's `capabilities.yml` into the capability registry. |
| `tasks/deploy_layer_file.yml` | Resolve **and** deploy one layer file/template: creates the parent dir, copies or templates, no-ops when no layer provides the key. The primitive behind every "a layer supplies this file" case — capability `config:` bundles, the prompt, VS Code settings, `~/.zshrc`. |
| `scripts/computer-setup-layers` | Sync layer repos into the cache. Validates layer names, `schema_version`, and force-syncs to `origin` (fetch + hard reset), so a diverged or hand-edited cache can never silently persist. |

The remaining roles (`homebrew`, `git`, `shell`, `vscode`, `layer_configs`,
`macos`, `runtimes`, `repositories`, `upgrade`, `drift_correction`) are ordinary
consumers of that interface. Before adding one, apply the litmus test: if
configuring a tool is just placing a file, it is **data** — a capability
`config:` entry — not a new role.

## Reserved keys

A layer's `vars.yml` may not define certain keys. The authoritative list is
`computer_setup_reserved_layer_keys`, plus the reserved *prefixes* in
`computer_setup_reserved_layer_prefixes`, both in
[`roles/computer_setup/tasks/main.yml`](../roles/computer_setup/tasks/main.yml).
It is deliberately not re-listed here, because an enumeration in prose is a copy
that goes stale. The categories are:

1. **Machine-local prefs** — belong in `~/.mac-prefs.yml`
   (`selected_capabilities`, git identity).
2. **Engine-owned play vars** — overriding these breaks the orchestrator
   (`home_dir`, `repo_url`, `homebrew_prefix`, …), plus the entire
   `computer_setup_*` namespace.
3. **Vars deciding what code runs, or runs unattended** — the whole
   `drift_correction_*` namespace (everything baked into the deployed runner and
   the scheduled agents), the upgrade auto-approval switches, and Ansible's own
   execution controls (`ansible_connection`, `ansible_python_interpreter`, …).

Categories 2 and 3 are reserved **by prefix**, not by name, so a newly added
engine var is protected automatically.

Category 3 is the security boundary. Layer vars land in play scope via
`set_fact`, which outranks both role defaults and play vars — so without it, a
compromised layer repo could redirect the unattended morning `ansible-pull` at
its own playbook. `tests/negative.yml` asserts these guards actually *reject*,
rather than silently degrading into no-ops.

The sync helper separately validates manifest entries before use: names must be
unique and path-safe, required fields present, priorities numeric, and
`layer.yml`'s `name` must match the manifest.

## A layer var cannot reference another layer var

Values in `vars.yml` may template against **play vars** (`home_dir`,
`repositories_base_dir`, `homebrew_prefix`, …) and other roles' `defaults/`, but
**not against keys defined in any layer's `vars.yml`**:

```yaml
# WON'T WORK
projects_root: "{{ home_dir }}/Work"
repositories:
  - folder: "{{ projects_root }}/analytics"   # 'projects_root' is undefined
```

The merge reads the whole incoming mapping in one expression, and reading a
container recursively templates every value inside it — during `pre_tasks`,
before any layer key has been published as a fact. This is why
`repositories_base_dir` is a play var in `local.yml` rather than layer content.
Use a play var, or repeat the literal.

# Architecture

`computer-setup` is the orchestrator: it owns bootstrap, the Ansible roles, the
merge logic, and the layer contract. Personal, work, and shareable machine
content live in content layers.

## Layer contract

Each layer is a git repo with this structure:

```text
layer.yml         # required manifest: name, schema_version
capabilities.yml  # optional selectable capabilities (packages, config, adopt, reminders)
questions.yml     # optional setup questions that set layer vars
presets.yml       # optional named bundles of answers + capabilities
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
only selection state in `~/.config/computer-setup/prefs.yml`. The engine merges every layer's
`capabilities.yml` into a registry and derives the whole role interface from it,
so the engine hardcodes no package names or paths:

- **active capabilities** = `selected_capabilities` ∪ any capability whose
  `adopt_if_present` path exists (adopting an already-installed tool).
- **packages** (`homebrew_optional_*`, `extension_optional`) come from the
  *selected* capabilities' `packages`, split by `type`. `type: extension`
  entries also carry a `manager:` and are grouped by it — the engine names no
  editor, and the managers themselves are layer data (`extension_managers`).
- a capability may declare `requires: <id>`, and is then **offered** only when
  that one is selected earlier in the run or already present (via its
  `adopt_if_present` path). This replaced a hardcoded `command -v code` probe.
  Note the scope: `requires` is a *menu* gate, enforced in `bootstrap.sh`
  against the merged registry. The engine does not re-check it, so a
  `selected_capabilities` list that names a gated id — hand-edited, or carried
  in via `--answers` from an older machine — still installs it. That is
  tolerable because the prefs file is the machine's own declaration, but it
  means `requires` constrains what you are *asked*, not what can be *applied*.
- **config deploys** (`computer_setup_config_deploys`) and **reminders**
  (`computer_setup_reminders`) come from the *active* capabilities.
- Roles and shell snippets gate on membership in the active set; a snippet
  self-declares its gate with a `# cs:requires-capability: <id>` directive.

That selected/active split is deliberate: install only what you asked for, but
manage the config of anything already present.

Always-on **baseline** content (`homebrew_baseline_*`, `macos_defaults`,
`git_config_sections`, …) is plain flat layer vars, separate from opt-in
capabilities.

## The question model

A capability answers "do I want this tool?" — independently, yes or no. Some
decisions are not that shape: which editor is *the* editor, where repositories
live, which address commits carry. Those have exactly one answer. Without a
representation for them they end up hardcoded in engine code, which is what this
mechanism exists to prevent.

A layer declares questions in `questions.yml`; they merge union-by-id in
descending priority exactly like capabilities. The **answer** is machine-local
and lives under `answers:` in `~/.config/computer-setup/prefs.yml`.

| Field | Meaning |
|---|---|
| `id` | Stable token; keys the stored answer. Never rename. |
| `type` | `select` \| `bool` \| `text` \| `path` |
| `default` | Used when unanswered — a fresh machine, or a question added after this machine's prefs were written |
| `set_var` | Optional: assign the raw answer to this variable |
| `validate` | Optional (`text`/`path`): regex the answer must match |
| `options[].set` | Optional: literal vars applied when that option is chosen |
| `options[].implies` | Optional: capability ids added to the selection |

`implies` is the generic dependency edge: choosing an editor selects the
capability that installs it.

`validate` is checked in two places by two different regex engines — bash ERE at
the bootstrap prompt, Python `re` on apply, because the prefs file is editable by
hand and an `--answers` file can come from anywhere. Patterns must therefore use
the subset both understand: `[^ @]`, `+`, `*`, `?`, `^`, `$`, `\.` are safe;
POSIX names like `[[:space:]]` are bash-only and `\s`/`\d`/`\w` are Python-only.
A pattern only one engine understands passes the prompt and fails every apply.

Resolution order, all in `pre_tasks`:

1. answers = declared defaults, overridden by stored answers
2. an answer to a question no layer declares any more is **dropped**, not
   carried into play scope as a phantom var
3. every `select` answer is validated against its options, and every answer to
   a question declaring `validate` is checked against that pattern; a stale or
   malformed one fails loudly rather than silently falling back
4. `set_var` / `set` payloads become play-scope facts
5. `implies` folds into `selected_capabilities`

This runs **after** the layer var merge, so an answer outranks a layer var: the
machine is more specific than the layer that proposed the question.

### The machine tier

A few keys are neither layer content nor engine constants: they are decisions
the *machine* makes. `repositories_base_dir` is the clearest — `~/Projects` was
a play var, reserved, and duplicated as a literal in the shell CLI, so there was
no way to answer it at all.

`computer_setup_machine_tier_keys` is the enumeration of keys a **question** may
set although a layer's `vars.yml` may not:

| Key | Decision |
|---|---|
| `repositories_base_dir` | where repositories are cloned |
| `drift_correction_enabled` | whether the engine's own drift/upgrade agents exist at all |
| `drift_correction_schedule_hour` | when the drift check runs |
| `drift_correction_upgrade_schedule_hour` | when the unattended upgrade runs |
| `git_user_name`, `git_user_email` | commit identity |

These are *where things go*, *when the agent runs*, and *who the commits are
from* — not *what code runs*.

Commit identity is the case that shows why the tier is a tier and not simply an
unreserving. A GitHub noreply address is a property of the **account**, not of
the machine, so a private layer should be able to carry it — retyping it at
every rebuild is how a real address ends up in a public commit, and that cannot
be retracted. But it must stay *proposed*: a layer supplies the `default:`, the
prompt shows it, and the machine's answer wins. Unreserving the keys outright
would invert that, because a layer's `vars.yml` is merged by `set_fact` and
would silently beat the machine's own prefs.
Everything that decides *what code runs* stays unreachable from every
direction: `computer_setup_repo_url`, `computer_setup_repo_branch`, the upgrade
auto-approval switches and the `ansible_*` controls are not in the tier and must
not be added to it. Widening the tier is a security decision, which is why it is
an enumeration rather than a prefix.

Both halves are asserted: `tests/contract.yml` proves a question *can* set a
tier key, and `tests/fixtures/negative/machine-tier/` proves a layer's `vars.yml`
naming the same key is still rejected. A door, not a hole.

### Questions are an escalation path, and are guarded as one

A `set:` payload lands in play scope exactly as a layer var does. Questions are
**layer** content — only the answer is machine-local. So without a guard, a
layer that cannot write `computer_setup_repo_url` in its `vars.yml` could declare a
question whose only option sets it, and redirect the unattended morning
`ansible-pull` at its own playbook.

`merge_layer_questions.yml` therefore applies the **same** reserved-key and
reserved-prefix guard to every `set:` payload that `merge_layer_vars.yml`
applies to `vars.yml`. A question cannot reach further than the layer's own vars
can. `tests/fixtures/negative/question/` asserts this rejects, for the right
reason.

## Presets

A fresh machine faces ~50 capability prompts plus every question. Presets make
that survivable: bootstrap offers the layers' `presets.yml` entries, and
declining "review every individual answer?" accepts the bundle wholesale.

A preset is a **pure prefill**. It supplies the defaults the prompts start from
and is never recorded in the prefs file, so a machine set up from a preset is
indistinguishable from one answered by hand. That means presets can be edited
later without silently reconfiguring machines that once used them — the reason
not to store a live binding.

Precedence for a question's starting value: declared default, then this
machine's prior answer, then the preset. The preset wins because choosing one on
a re-run is a deliberate "start from that instead".

Presets live entirely in `bootstrap.sh`. The engine has no concept of them.

Capabilities, questions and presets are all merged by one bootstrap helper,
`merge_layer_file`, which walks the manifest in descending priority and dedupes
rows on their first field. The caller supplies only the filename and a `yq`
projection, so a column layout is defined in exactly one place. It reaches the
same union-by-id result as the engine's `merge_layer_*.yml`, which walks
ascending and lets the last write win.

`bootstrap.sh --answers <file>` skips every prompt and takes the whole
preference set from a file with the same shape `write_prefs` emits — so a
previous machine's `~/.config/computer-setup/prefs.yml` works directly, and "rebuild this machine"
is one command. It requires an existing layer manifest, since nothing can guess
which layers a machine wants.

## Runtime flow

1. `bootstrap.sh` installs prerequisites and authenticates GitHub over SSH.
2. The user defines a layer manifest at `~/.config/computer-setup/layers.yml`.
3. Layers are cloned to `~/.local/share/computer-setup/layers/<name>/`.
4. `capabilities.yml` files are merged into the bootstrap menu; selections are
   written to `~/.config/computer-setup/prefs.yml`.
5. `ansible-pull` applies the orchestrator with the layer manifest/cache paths.
6. Thereafter the scheduled agents refresh the orchestrator and the layer cache
   before every check, so drift covers layer content too.

## Orchestrator primitives

`local.yml` delegates all layer handling to the `core` role. It is not a role in
the ordinary sense — it configures nothing. It is the engine: play initialisation
plus a library of primitives the real roles call via `tasks_from`.

| Primitive | Purpose |
|---|---|
| `tasks/main.yml` | Platform check, prefs loading, layer var merge, capability registry + adoption probe, and the derived interface (packages, config deploys, reminders). |
| `tasks/merge_layer_vars.yml` | Merge one layer's `vars.yml` into play scope: enforces `schema_version`, rejects reserved keys, appends lists, overrides scalars. |
| `tasks/merge_layer_capabilities.yml` | Merge one layer's `capabilities.yml` into the capability registry. |
| `tasks/merge_layer_questions.yml` | Merge one layer's `questions.yml` into the question registry, rejecting any `set:` payload that names a reserved key. |
| `tasks/deploy_layer_file.yml` | Resolve **and** deploy one layer file/template: creates the parent dir, copies or templates, no-ops when no layer provides the key. The primitive behind every "a layer supplies this file" case — capability `config:` bundles, the prompt, editor settings, `~/.zshrc`. |
| `scripts/computer-setup-layers` | Sync layer repos into the cache. Validates layer names and `schema_version`, and force-syncs to `origin` (fetch + hard reset), so a diverged or hand-edited cache can never silently persist. Repo URLs are used as written — an explicit `https://` is not rewritten to SSH, since that is a deliberate choice where port 22 is blocked. |

### File vs template resolution

For a lookup key `<key>`, `deploy_layer_file` resolves in two steps:

1. `<key>.j2` across the layers' `templates/` dirs → rendered as a template
2. `<key>` across the layers' `files/` dirs → copied verbatim

A layer therefore promotes any config file to a template by renaming it and
moving it under `templates/` — no capability, role, or engine change. This is
what lets one value reach several config files; verbatim `files/` cannot, and a
layer var cannot reference another layer var (see below), so duplication was
otherwise the only option. Templates render late, after the layer merge, so they
*can* read merged layer vars.

A key should be supplied as either a file or a template across all layers, not
both: step 1 wins over step 2 regardless of layer priority.

A lookup key is always written **without** the `.j2` suffix — whether a layer
supplies the key as a template is the layer's business, not the caller's. This
is the only resolution rule; there is no per-caller override.

Shell snippets are globbed rather than looked up, so they follow the same rule
with a different path: `files/shell/*.zsh.j2` is rendered, `*.zsh` is copied,
and both land at the same managed destination.

The remaining roles (`homebrew`, `git`, `shell`, `extensions`, `capability_configs`,
`macos`, `runtimes`, `repositories`, `upgrade`, `drift_correction`,
`scheduled_agents`) are ordinary consumers of that interface. Before adding one,
apply the litmus test: if configuring a tool is just placing a file, it is
**data** — a capability `config:` entry — not a new role.

`scheduled_agents` is the one place that test needs a word of explanation. A
LaunchAgent *is* just a plist file, so by the rule above it should be data — and
its content is: layers declare agents in the `scheduled_agents` list, and the
role names no tool. It exists as a role only because launchd needs
`bootout`/`bootstrap` to notice a rewritten or deleted plist, and
`capability_configs` has no handler to run them. The lifecycle is the role; the
schedule is data.

## The engine names no tool

The engine hardcodes no tool, app, or editor. Every tool-specific decision is
layer data, reached through one of these interfaces:

| Decision | Layer interface |
|---|---|
| Which editor(s) to manage — binary, settings key, extension install command | `extension_managers`; a capability declares `type: extension` + `manager:` |
| Whether a capability is offered at all | `requires: <capability-id>`, resolved against `adopt_if_present` (bootstrap-side; see the capability model above) |
| App-conditional macOS defaults (Rectangle, Raycast, …) | `macos_conditional_defaults[].app` |
| Which whole-file shell configs exist (`zshrc`, `p10k.zsh`, …) | `shell_config_files` |
| Which capability gates nvm / tfenv | `runtimes_*_capability` |
| Terraform version | layer var, empty by default |
| Which recurring jobs run, and when | `scheduled_agents`; the engine schedules them and knows nothing of what they do |

If you find yourself typing a tool's name into `roles/`, one of these interfaces
is the right place instead.

### Where this deliberately stops

The version managers keep bespoke task bodies. The obvious generalisation is a
data table carrying each manager's shell commands — rejected, because layer vars
would then be arbitrary shell executed as the user on every drift run, which is
precisely the remote-code-execution path the reserved-key guard exists to close.
Adding pyenv or mise is a small reviewable engine change; making it layer data
would trade a real security boundary for a cosmetic one.

The same reasoning is why `set:` payloads on questions are guarded: data that
becomes *variables* is checked against a reserved list; data that would become
*commands* is not accepted at all.

## Reserved keys

A layer's `vars.yml` may not define certain keys. The authoritative lists are
`computer_setup_reserved_layer_keys` and `computer_setup_reserved_layer_prefixes`
in [`roles/core/tasks/main.yml`](../roles/core/tasks/main.yml).
They are deliberately not re-listed here, because an enumeration in prose is a
copy that goes stale.

The split between them is an invariant, not a judgement call:

> **Reserved by prefix** — everything the engine owns: `computer_setup_`,
> `drift_correction_`, `ansible_`, and `_cs_` (the engine's short-lived internal
> facts, e.g. `_cs_deploy_src`).
>
> **Reserved by name** — only names that are *public interface* and therefore
> cannot be prefixed away: the prefs-file keys (`selected_capabilities`,
> `answers`), the machine tier (`git_user_name`, `git_user_email`), and the play
> vars layers legitimately template against (`home_dir`, `homebrew_prefix`,
> `repositories_base_dir`).

The consequence is what matters: **adding an engine variable never requires
editing the reserved list.** A new `computer_setup_*` or `drift_correction_*`
var is protected the moment it exists. Only the seven public-interface names are
enumerated, and that list should essentially never grow.

`ansible_` is a prefix for the same reason. It used to be five hand-picked names
(`ansible_connection`, `ansible_python_interpreter`, …), which left
`ansible_become_password` and `ansible_ssh_common_args` reachable by a layer —
an enumeration nobody had remembered to extend.
`tests/fixtures/negative/ansible-prefix/` asserts that hole is closed.

This is the security boundary. Layer vars land in play scope via `set_fact`,
which outranks both role defaults and play vars — so without it, a compromised
layer repo could redirect the unattended morning `ansible-pull` at its own
playbook. `tests/negative.yml` asserts these guards actually *reject*, rather
than silently degrading into no-ops.

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

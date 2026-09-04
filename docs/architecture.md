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
(the `layers:` block of `~/.config/computer-setup/machine.yml`), not in
`layer.yml` — one source of
truth, so a layer cannot disagree with the machine about its own ordering.

The public API is the role variable interface plus this `schema_version`. Bump
the orchestrator-supported maximum in all three places that state it —
`computer_setup_schema_version` in `local.yml`, `SCHEMA_VERSION_MAX` in
`bootstrap.sh`, and the default in `scripts/computer-setup-layers` — when
changing that contract in a breaking way. They cannot import from each other, so
`check.sh` asserts they agree instead.

Not to be confused with the `schema_version` on the run-state file below, which
is machine-local and not yet a contract.

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
only selection state in `~/.config/computer-setup/machine.yml`. The engine merges every layer's
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
  tolerable because machine.yml is the machine's own declaration, but it
  means `requires` constrains what you are *asked*, not what can be *applied*.
- **config deploys** (`computer_setup_config_deploys`) and **reminders**
  (`computer_setup_reminders`) come from the *active* capabilities. A `config:`
  entry is `{src, dest, executable?}`. The deployed file's **mode is left
  unmanaged** unless `executable: true` asks for `0755` — pinning a mode makes
  any tool that chmods its own config file register as drift on every scheduled
  check, forever. `executable` exists because a `templates/<src>.j2` cannot
  inherit the source file's exec bit the way a `files/<src>` copy does.
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
and lives under `answers:` in `~/.config/computer-setup/machine.yml`.

| Field | Meaning |
|---|---|
| `id` | Stable token; keys the stored answer. Never rename. |
| `type` | `select` \| `bool` \| `text` \| `path` |
| `default` | Used when unanswered — a fresh machine, or a question added after this machine's declaration was written |
| `set_var` | Optional: assign the raw answer to this variable |
| `validate` | Optional (`text`/`path`): regex the answer must match |
| `options[].set` | Optional: literal vars applied when that option is chosen |
| `options[].implies` | Optional: capability ids added to the selection |

`implies` is the generic dependency edge: choosing an editor selects the
capability that installs it.

`validate` is checked in two places by two different regex engines — bash ERE at
the bootstrap prompt, Python `re` on apply, because machine.yml is editable by
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
would silently beat the machine's own declaration.
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
and is never recorded in machine.yml, so a machine set up from a preset is
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
preference set from a file with the same shape `write_machine` emits — so a
previous machine's `~/.config/computer-setup/machine.yml` works directly, and
"rebuild this machine" is one command — the file names its own layers, so
nothing has to guess
which layers a machine wants.

## Runtime flow

1. `bootstrap.sh` installs prerequisites and authenticates GitHub over SSH.
2. The user defines the layers in `~/.config/computer-setup/machine.yml`.
3. Layers are cloned to `~/.local/share/computer-setup/layers/<name>/`.
4. `capabilities.yml` files are merged into the bootstrap menu; selections are
   written to the same `machine.yml`.
5. `ansible-pull` applies the orchestrator with that file and the cache path.
6. Thereafter the scheduled agents refresh the orchestrator and the layer cache
   before every check, so drift covers layer content too.

## Run state

Everything this system does is otherwise invisible unless you read Ansible's
console output. `callback_plugins/computer_setup_state.py` writes a
machine-readable summary of each run to `~/.local/state/computer-setup/last-run.json`
(mode `0600`), which `computer-setup status` renders and a UI could consume
directly.

It is an **aggregate** callback, so it runs alongside the normal stdout callback
and the human-readable log is unchanged. It is inert unless `CS_STATE_FILE` is
exported, which the runner does for `apply`, `check` and both scheduled modes.

```json
{ "schema_version": 1, "mode": "check", "partial": false, "finished": "…",
  "duration_seconds": 57.8, "result": "ok",
  "totals": { "ok": 156, "changed": 2, "failed": 0, … },
  "changed": [ { "task": "…", "action": "…", "role": "…", "dest": "…" } ],
  "failed": [], "truncated": false }
```

`partial` marks a run narrowed by `--tags`/`--limit`, which describes only what
it looked at. Without it, `apply --tags repositories` would record "no drift"
and read as a verdict on the whole machine. `upgrade` is always partial.

### The three schemas, and when they become contracts

| Artifact | Version | Versioned |
|---|---|---|
| `last-run.json` | `STATE_SCHEMA_VERSION` | per file |
| `managed-paths.json` | `MANIFEST_SCHEMA_VERSION` | per file |
| `history.jsonl` | `HISTORY_SCHEMA_VERSION` | **per line** |

History is versioned per line because a JSONL file has no header, and lines
written months apart genuinely can differ in shape — old ones are never
rewritten. A reader meeting a mixed file handles each line on its own terms,
which one file-level version could not express.

Three numbers rather than one, because they answer different questions and will
change for different reasons: a field added to the inventory should not force
every reader of the run summary to re-check its version.

**None of them is a contract yet.** They exist so they can become contracts
without a migration, but everything that reads them — `computer-setup status`,
`manifest`, `history` — ships in this repo, in the same commit as any change to
the plugin. Reshape them freely while that is true.

They become contracts the moment something *outside* this repo reads one: a UI,
a Jamf extension attribute, a teammate's script. From then on, bump on a
breaking change and update the contract test, exactly as layers do. That is a
decision to take deliberately, on the day the first outside consumer is written
— not to discover afterwards.

Two properties are load-bearing:

- **Metadata only.** Ansible's diffs carry full before/after file *contents* —
  your gitconfig identity, and whatever else a managed file holds. The plugin
  records a task name, its action and the destination path, and nothing else.
  `check.sh` plants a canary string in `tests/state.yml` and fails if it ever
  reaches the state file, so this cannot regress quietly.
- **A callback, not a parser.** `ansible-pull` runs its own checkout play before
  the real one and prints `[WARNING]` lines *between* the two, so every
  text-based approach — including the `changed=N` scrape this replaced — has to
  guess which recap belongs to which play. A callback runs inside the play and
  simply knows. The last play to finish wins, which is the real one.

Staleness is tracked separately in `last-success`, a plain ISO timestamp written
only by a scheduled run that reached the repo and finished cleanly. It is not a
field in the JSON because it has to survive a run that failed.

## The manifest: what this system owns

The same callback writes `managed-paths.json` — every filesystem path the run
managed, whether or not it changed. `computer-setup manifest` renders it.

```json
{ "schema_version": 1, "generated": "…", "mode": "check",
  "partial": false, "complete": true,
  "files":       [ { "path": "…", "action": "template", "role": "shell", "task": "…" } ],
  "directories": [ … ],
  "backups":     [ … ] }
```

**Drift is an event; an inventory is a state.** `last-run.json` lists what
changed, so on a converged machine it is empty — correct for drift, useless for
knowing what the tool owns. The manifest lists a file that is already correct,
which is why the two are separate artifacts with separate schema versions rather
than more fields on one.

Why derived from the callback rather than declared per role: a declared path and
a written path are the same fact in two places, and this repo has twice paid for
that — `mode` declared on capability configs, and `computer_setup_state_dir`
declared `0700` by one role and `0755` by another, drifting daily for a week. A
list maintained by hand drifts silently, and here the silent side holds the
delete button.

Three omissions are deliberate, and `check.sh` asserts each one:

- **A `state: absent` path is not managed.** Recording it would have a
  collection step re-delete what it just deleted, forever.
- **A skipped task contributes nothing.** A task skipped because its capability
  was deselected no longer manages its path, and that path dropping out of the
  manifest is precisely the signal collection needs.
- **`command`/`shell` side effects are invisible.** nvm, tfenv, editor
  extensions and `logins` remedies write through them and the path is not
  knowable from a callback. They are also not files anything would collect —
  they need `brew uninstall` or `--uninstall-extension`, a different verb.

A path is resolved from three sources in order, because no single one covers
both a converged run and a first one:

| Source | Available when |
|---|---|
| the module's result `dest` | the file exists |
| the diff's `before_header` | it exists and is changing |
| the rendered loop item | always, including creating a file under `--check` |

The third matters more than it looks. Under `--check` a file that does not exist
yet produces neither a result path nor a diff header, so for a LOOP the rendered
item is the only thing left that names it — and without it the first manifest a
new machine wrote was missing every loop-created file, eight shell snippets
among them. Found by running the whole playbook in check mode against a scratch
`$HOME`, which is now a gate.

One residual gap, on purpose: a loop under `--check` whose item is not itself
the path — the LaunchAgent plists keyed on `agent.label`, the git identity file
keyed on a hash — still cannot be resolved before the file exists. The first
real `apply` records them, because then the module returns the path. Reaching
further would mean re-rendering templates inside the callback with a variable
context it does not have.

`backups` is its own class: `backup: true` leaves `<dest>.<pid>.<date>@<time>~`
beside a file and **nothing has ever removed them**. Ansible names the file it
generated in its result, so these are captured rather than guessed at with a
glob.

### Only a complete run writes it

A run that was partial or failed **does not write the manifest at all**. It saw
a fraction of the machine — `--tags git` sees three files of twenty-seven — and
replacing a full inventory with a fraction gives a wrong answer to "what does
this own" until the next full run. The previous complete manifest is the better
answer, so it survives untouched.

That is stricter than marking the file incomplete and letting readers check,
which is what this did first. The stricter rule is what makes orphan detection
possible at all: the diff below needs a trustworthy *previous*, and a partial
run would have destroyed it.

`complete` stays in the payload even though it is now always true. A consumer
should be able to check the property rather than having to know the rule that
guarantees it.

The interlocks already existed — `partial` was added so nobody could read "no
drift in the one role I ran" as "machine converged", which is the same
precondition.

## Orphans: paths that stopped being managed

Each complete run diffs the previous manifest against its own and records what
fell out, in `orphans`. `computer-setup manifest` lists them and `status` says
how many there are.

**Reported, never removed.** Deciding a file is garbage is a judgement, and the
evidence is presented so a person can make it. Shipping the report first is
deliberate: it should be watched being right for a while before anything acts on
it.

Three properties, each gated:

- **An orphan is carried forward, not recomputed.** A naive
  previous-minus-current diff reports a path exactly once — on the next run the
  previous manifest no longer lists it either, so it silently disappears while
  the file is still sitting there. An orphan stays on the list until it stops
  existing or comes back under management.
- **It must still exist on disk** (`lexists`, so a broken symlink counts). A
  report that only grows is one nobody reads.
- **Directories are not tracked.** A directory falling out almost always means
  its contents did too, and the blast radius is categorically larger —
  `~/Library/Logs` and `~/.local/bin` are both managed directories and neither
  is this system's to delete.

Attribution (`role`, `task`, `action`) is kept from when the path *was* managed,
plus a `since` timestamp preserved across runs. "Which role used to own this,
and how long has it been unmanaged" is what someone asks when deciding whether
to delete it.

Scheduled agents are the one thing that reaps itself rather than waiting for
this, because **an agent is not just a file**: removing the plist without
`launchctl bootout` leaves the job running until the next reboot, so removal has
an ordering requirement no path-based collector can honour.

## Run history

`history.jsonl` — one JSON line per run, oldest trimmed past 500.

The rolling log (`~/Library/Logs/computer-setup.log`) is capped at 5000 lines,
which sounds generous and is about **three days**, because it stores full
Ansible output. The history stores nine fields, so the same budget covers most
of a year. It is what makes "when did this machine last actually change
anything" answerable.

JSON Lines, not a JSON array: appending to an array means rewriting the whole
file, and a run that dies mid-write leaves invalid JSON. A truncated last line
costs one record.

One line per **invocation**, not per play. `ansible-pull` can reach the
callback's final hook more than once, and since this file is appended rather
than overwritten, each line is keyed on `CS_RUN_ID` and a repeat of the same id
replaces the previous line instead of adding one.

## Orchestrator primitives

`local.yml` delegates all layer handling to the `core` role. It is not a role in
the ordinary sense — it configures nothing. It is the engine: play initialisation
plus a library of primitives the real roles call via `tasks_from`.

| Primitive | Purpose |
|---|---|
| `tasks/main.yml` | Platform check, machine-declaration loading, layer var merge, capability registry + adoption probe, and the derived interface (packages, config deploys, reminders). |
| `tasks/merge_layer_vars.yml` | Merge one layer's `vars.yml` into play scope: enforces `schema_version`, rejects reserved keys, appends lists, overrides scalars. |
| `tasks/merge_layer_capabilities.yml` | Merge one layer's `capabilities.yml` into the capability registry. |
| `tasks/merge_layer_questions.yml` | Merge one layer's `questions.yml` into the question registry, rejecting any `set:` payload that names a reserved key. |
| `tasks/deploy_layer_file.yml` | Resolve **and** deploy one layer file/template: creates the parent dir, copies or templates, no-ops when no layer provides the key. Leaves the destination's mode alone unless `computer_setup_deploy_executable` is set. The primitive behind every "a layer supplies this file" case — capability `config:` bundles, the prompt, editor settings, `~/.zshrc`. |
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
its content is: agents are declared in the `scheduled_agents` list, and the
role names no tool. It exists as a role only because launchd needs
`bootout`/`bootstrap` to notice a rewritten or deleted plist, and
`capability_configs` has no handler to run them. The lifecycle is the role; the
schedule is data.

The engine's **own** two jobs (the daily drift check and the unattended
upgrade) are entries in that same list, `scheduled_agents_engine` — there is
one LaunchAgent implementation, not a private second copy inside
`drift_correction`. They are kept in a separate variable from `scheduled_agents`
so a layer cannot retask, reschedule, or delete them by redeclaring the list,
and they answer to their own kill switch (`drift_correction_enabled`) rather
than the layer-facing `scheduled_agents_enabled`. `drift_correction` itself now
only deploys the `computer-setup` command those jobs invoke.

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
> cannot be prefixed away: the machine-file keys (`layers`, `selected_capabilities`,
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

## Logins: credentials a person has to obtain

Some things cannot be installed, only signed in to. `opencode auth login` and
`gcloud auth login` open a browser or prompt and have no token flag, so the
engine can detect them but not perform them unattended.

Declared by layers, alongside `scheduled_agents` and with the same
`requires_capability` gating:

```yaml
logins:
  - id: opencode-on-dev-tooling
    desc: "opencode → On dev-tooling"
    requires_capability: opencode
    detect_file: "{{ home_dir }}/.local/share/opencode/auth.json"
    detect_key: "https://dev-tooling.on.com"     # optional
    remedy: "opencode auth login https://dev-tooling.on.com"
```

`detect_file` alone means *existence is the check*, which is all a single-purpose
store allows (gcloud keeps SQLite). `detect_key` additionally requires a
top-level key, because a store holding several providers proves nothing by
existing — a machine signed in to Copilot alone still has opencode's `auth.json`.

**This is what a reminder should have been.** `reminders:` prints on every run
whether or not the thing is done, so it is noise the day after you read it. A
login is *checked*: it reports as ordinary drift while the credential is missing
— by name, in `computer-setup status` — and goes quiet once it is not.

Two halves, split deliberately:

- **Detection always runs**, including under `--check` (`check_mode: false`),
  because a check that cannot see a missing credential is not a check. The probe
  is inline rather than a deployed script: a deployed one would have to exist
  before it could be used, so the first check on a machine would report
  everything missing, and deploying it during `--check` would mean a check that
  mutates.
- **The remedy runs only when `computer_setup_interactive`** is true. Both
  scheduled modes pass `false`, so a LaunchAgent with no TTY reports instead of
  hanging on a browser flow — the same split as casks in the upgrade role.

The probe prints nothing from the file. These are token stores, so the exit code
is the entire result and no credential reaches Ansible's memory, a `-v`
transcript, or the run-state file.

A login can only exist where the signed-in state is visible on disk. 1Password
stays an unconditional reminder because it is a GUI app with no readable marker
— an honest nag beats a check that cannot check.

## Where files live

Split by the XDG question — who owns it, and what does losing it cost:

| Path | Holds | Losing it |
|---|---|---|
| `~/.config/computer-setup/machine.yml` | the machine declaration | you re-answer every question |
| `~/.config/computer-setup/backup.yml` | which repo backs this machine up, under what name | you re-run `machine init` |
| `~/.local/share/computer-setup/layers/` | the layer cache | re-cloned on the next run |
| `~/.local/share/computer-setup/backups/` | clone of the backup repo | **possibly a commit** — see below |
| `~/.local/state/computer-setup/last-run.json` | what the last run did | nothing; the next run rewrites it |
| `~/.local/state/computer-setup/managed-paths.json` | every path this system owns | nothing — but collection loses its memory, so orphans survive. Fails safe |
| `~/.local/state/computer-setup/history.jsonl` | one line per run, ~500 runs | the run history, which no run can reconstruct |
| `~/.local/state/computer-setup/last-success` | when a scheduled run last succeeded | staleness reads as "never synced" until the next one |
| `~/.local/state/computer-setup/galaxy-core-version` | which ansible-core the collections were resolved against | a redundant re-resolve |
| `~/Library/Logs/computer-setup.log` | the rolling log, ~3 days | nothing |

Both `~/.config` entries are configuration because a HUMAN decided them and no
run can reconstruct them. `backup.yml` is config despite describing where state
goes, and is deliberately not a key in `machine.yml`: machine.yml is the thing
being backed up, so it cannot also be the record of where its backups live.

The backup clone is in `share` rather than `cache` for a concrete reason: a push
that fails leaves a **local commit** there (`machine push` warns and returns 0),
so deleting it can lose work. The layer cache has no such property and is
arguably cache by a strict reading — it stays in `share` because it is the
working set every apply reads, and `~/.cache` is somewhere cleaners feel
entitled to delete from underneath a running job.

`~/.local/state` means one thing here: a record of what this machine did. It is
never read to decide what to do.

`history.jsonl` is the one entry whose loss is not free — nothing regenerates a
run history. It stays in `state` rather than `share` because it is still only a
record, and because the alternative is pretending a log is data. If it ever
matters enough to survive a wipe, it belongs in the backup repo, not a different
directory.

### What this system puts in `$HOME`

Managed files go in a directory a tool already owns, not loose in `$HOME`.
Anything loose is there because the tool gives no choice:

| Path | Why there |
|---|---|
| `~/.zshrc` | zsh reads only this, unless `ZDOTDIR` is set in `~/.zshenv` — a bigger change than it looks |
| `~/.gitconfig` | git prefers it over the XDG path, and it is user-authored: the engine only **appends an include** |
| `~/.zsh/*.zsh` | snippets, auto-sourced by glob, garbage-collected via the manifest |
| `~/.zsh/configs/*` | whole-file configs, sourced by name, **not** garbage-collected |
| `~/.config/<tool>/` | anything that honours XDG: `git`, `zed`, `opencode`, `computer-setup` |
| `~/.config/git/ignore` | git's own XDG path for the global ignore list — `core.excludesFile` is still set explicitly, because git only falls back to this path when that key is **unset** |
| `~/.local/bin/` | the runner and its helpers |
| `~/.ansible/pull/computer-setup/` | `ansible-pull`'s checkout of this repo — ansible's own directory, but the name is **pinned** (see below) |
| `~/.dbt/`, `~/.docker/` | the tool insists |

The distinction inside `~/.zsh` is the one that catches people. A snippet is
sourced because it matched a glob and is deleted when it leaves the manifest; a
config is sourced because something names it and survives forever once written.
Putting a config where the glob can see it would source it at the wrong moment;
putting a snippet in `configs/` would silently stop it loading.

Two rules follow, and both have already been learned the hard way:

- **Tell the tool where you moved its file.** Relocating a config that a tool
  looks for by a fixed path only works if the tool has an override and you set
  it. p10k reads `POWERLEVEL9K_CONFIG_FILE`; without it `p10k configure` writes
  to `~/.p10k.zsh` and the prompt silently never changes.
- **Moving a managed file leaves the old one behind.** Config deploys are not
  garbage-collected, so the previous path stays on every machine that already
  had it — usually shadowing nothing, occasionally shadowing everything. Remove
  it deliberately, in the same change.
- **The pull checkout is pinned, and must never be edited.** `ansible-pull`
  defaults to `~/.ansible/pull/<hostname>`, and a Mac's hostname is not stable —
  joining a network that appends an mDNS `.home` suffix starts a second checkout
  which then sits stale until that network comes back. The hostname is in the
  default so hosts sharing an NFS home don't collide; a per-user macOS home has
  no such sharing. Both callers pass `-d` (`computer_setup_pull_dir` in
  `local.yml`, `PULL_DIR` in `bootstrap.sh`) and `check.sh` asserts they agree.
  Editing the checkout is separately fatal: `ansible-pull` clones with
  `force=no`, so a dirty checkout makes it **refuse to update**, and the
  scheduled agents then run stale code without complaining.

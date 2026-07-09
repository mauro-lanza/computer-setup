# Capability Model Blueprint (in-progress refactor)

> **Status: living document for an active redesign.** It describes the *target*
> architecture we are converging on, the decisions behind it, and the staged
> roadmap to get there. `docs/architecture.md` describes what currently ships;
> where the two disagree, this file is the intent. When the roadmap is complete,
> fold the durable parts into `architecture.md` and keep this as design rationale.
>
> The project is **development-only** right now — not applied to any machine but
> the author's, tested locally via `./scripts/check.sh` + `tests/contract.yml`.
> Therefore **no backward-compatibility or prefs migrations are required**; we do
> clean cutovers.

## Vision

`computer-setup` is an **engine** (a growing library of reusable *managers* that
know *how* to configure a Mac) plus **plugins** (git repos of pure *data* that
say *what* to configure). The engine ships **no obligatory content** — every
tool/config/package comes from a plugin. Even the author's "always-on baseline"
is just their public layer's data, not engine-mandated; a fresh plugin author
starts from zero.

Goal: a repertoire that grows over time (author + community + a company/team
plugin), where **adding a tool is plugin data + at most a small engine manager**,
never a rewrite.

## Locked strategic decisions

1. **macOS-only** for the foreseeable future. Keep manager *names* OS-neutral
   where cheap (e.g. prefer `system_settings` over `macos_defaults` in new code)
   so the door isn't nailed shut, but do not build a cross-platform abstraction.
2. **Invest in the full manager registry** (manifests + generated docs + tests).
   Justification: this may onboard the author's team and back a private company
   plugin repo, so discoverability/contract clarity matter.
3. **Hybrid data model**: *always-on baseline* = flat plugin vars; *opt-in tools*
   = capability bundles. Two mechanisms because "always-on" and "selectable" are
   genuinely different; do not force baseline through fake capabilities.
4. **Plugins are git repos**, priority-merged. No package registry/infra — this is
   how dotfile communities already work and it's zero-ops. One repo = one layer =
   one priority.

## The three-tier manager model

- **Tier 0 — Self-management machinery**: bootstrap, layer sync, drift agent,
  merge engine. Runs the show; not something you configure *with*.
- **Tier 1 — Generic managers** (workhorses, pure-data driven): install packages,
  deploy a file/template to a path, apply key-value system settings, clone repos,
  drop shell snippets. ~5 primitives cover the large majority of needs.
- **Tier 2 — Specific managers**: bespoke idempotency for a *named* tool driven
  through its own CLI (nvm version, tfenv version, vscode extensions, gcloud).
  Opt-in, small, added only when Tier 1 can't express it.

### The litmus test (engine vs plugin, generic vs specific)

> **If configuring the tool is *just placing a file*, it's data → a generic
> manager. If it needs the tool's own CLI with idempotency logic, it's a specific
> manager.**

This is why `vscode` earns a bespoke role (shells out to `code --install-extension`)
but `zed` does **not** (it's just `settings.json` → generic file deploy).

## Hard guardrails (explicitly OUT of scope)

- **No generic "run arbitrary commands" plugin primitive.** It would turn plugins
  into code and destroy the safety/shareability/reviewability model. The only
  bounded exception is `repositories[].post_clone` (your own repos, once, on
  clone). New logic ⇒ add/extend a manager deliberately.
- **No dynamic manifest dispatcher.** The manager registry is metadata + docs +
  tests. Managers stay ordinary Ansible roles in `local.yml`; we do not build an
  engine that reads manifests and invokes roles at runtime (framework-in-framework).
- **No cross-platform abstraction** (see decision 1).
- **No migrations/back-compat shims** (dev-only, see top).

## Target data model

### Single selection token

`~/.mac-prefs.yml` is only identity + selections. Everything else is derived:

```yaml
git_user_name: ...
git_user_email: ...
selected_capabilities: [zed, nvm, vscode, dbt, gcloud]
```

No `has_*` in prefs, no `use_dbt`, no bootstrap-derived package lists.

### Capability bundle (a plugin's `capabilities.yml`, currently `catalog.yml`)

One self-contained, reviewable block per selectable tool. The capability **id is
the capability token** (no separate `capability` field). Both bootstrap (menu)
and the engine (execution) read this — so the engine never hardcodes package
names.

```yaml
capabilities:
  - id: zed
    desc: "Zed editor"
    type: cask                 # formula | cask | vscode | feature
    packages: zed              # space-separated; omitted for `feature`
    config:                    # generic file/template deploys (Tier 1)
      - { src: zed/settings.json, dest: "{{ home_dir }}/.config/zed/settings.json" }

  - id: gcloud
    desc: "Google Cloud SDK"
    type: cask
    packages: gcloud-cli
    reminders: ["Run: gcloud auth login (if using GCP)"]

  - id: dbt
    desc: "dbt (BigQuery profile)"
    type: feature              # no package — a config-only capability
    config:
      - { src: profiles.yml.j2, dest: "{{ home_dir }}/.dbt/profiles.yml",
          kind: template, adopt_if_present: true }
```

- **Packages**: derived per type into `homebrew_optional_formulae/_casks`,
  `vscode_optional_extensions` from selected ids.
- **config**: fed to the generic `deploy_layer_file` manager (Tier 1), gated by
  the owning capability; `adopt_if_present` handles "manage if already installed".
- **reminders**: rendered by a generic post-task.
- **Specific managers are NOT declared here** — each specific manager role
  self-gates with `when: '<id>' in selected_capabilities` (+ presence fallback
  where "adopt if present" applies).
- **Shell snippets are NOT declared here** — they self-gate with a
  `# cs:requires-capability: <id>` directive in the snippet file itself (already
  implemented). Deliberate exception: the snippet already lives in `files/shell/`
  and self-guards on tool presence.

### Baseline (always-on) — flat plugin vars

Applied regardless of selections; consumed by always-on managers:
`homebrew_baseline_formulae` / `_casks` (renamed from `mandatory`),
`macos_defaults`, `git_config_sections`, `git_global_gitignore_entries`,
baseline shell snippets (no directive), `repositories`, etc.

### Gating, unified

Everything conditional resolves to `'<id>' in selected_capabilities`, plus an
"or already present" fallback only for tools we can detect and adopt
(`has_dbt` ← profiles.yml, `has_vscode` ← code binary, `has_gcloud` ← SDK — with
the gcloud path corrected to the Homebrew location).

## Plugin structure (unchanged shape, richer schema)

```
plugin.yml         # manifest: name, schema_version, priority, provides
capabilities.yml   # capability bundles (opt-in tools)   [currently catalog.yml]
vars.yml           # flat baseline vars (always-on)
files/             # config files + shell snippets referenced above
templates/         # templates
```

## Manager registry (Tier "invest fully")

Each manager role gets `roles/<name>/meta/manager.yml`:

```yaml
manager:
  name: config_file          # or system_settings, packages, node_version, ...
  kind: generic              # generic | specific
  capability: null           # specific managers name their gating capability
  summary: "Deploy a layer-provided file/template to a destination."
  consumes: ["capabilities[].config"]
```

Used for: a generated `docs/managers.md`, a contract test that every manifest is
valid and every capability's needs map to a real manager, and a clear
"how to add a manager" contributor path. **Metadata only — not runtime dispatch.**

## Team / company onboarding (a first-class driver)

- Engine = public repo (shared, versioned). Company data = a private
  `computer-setup-layer-<team>` plugin at a chosen priority: required packages,
  editor settings, git config, gcloud/dbt config, repo lists, macOS policy — all
  pure data, no Ansible knowledge needed to contribute.
- New teammate: run bootstrap → add company layer (+ optionally personal) → pick
  optional capabilities → done. Drift agent keeps the baseline compliant.
- To add for reproducible onboarding: **engine version pinning** in the layer
  manifest (teammate gets the validated engine ref, not bleeding-edge `main`).
- Secrets always stay references (env / keychain / 1Password); never committed.
  `reminders` covers "sign into X".

## Refactor roadmap (one commit each; green checks between)

- [x] **1 — Capability registry + `selected_capabilities`.** Engine merges each
  layer's `catalog.yml` into a registry and derives optional package lists from
  selections; capability flags become membership-only; `dbt` becomes a
  (no-package) `feature` capability; `use_dbt` and the `prefs.optional_*` lists
  are removed. *Done: engine (`merge_layer_catalog.yml`, derived interface),
  `bootstrap.sh` (writes `selected_capabilities` only), fixtures + contract all
  green.*
- [x] **2 — Config as capability `config:` bundles.** Retire the engine-default
  `layer_configs`; derive the deploy list from selected capabilities' `config`;
  add `adopt_if_present`. *Done: engine derives `computer_setup_active_capabilities`
  (selected ∪ adoptable-present) and `computer_setup_config_deploys`; the
  layer_configs role consumes the derived list; config moved into the public
  (zed/opencode) and work (dbt) catalogs. Per-entry `adopt_if_present` path is
  deferred to step 3 (currently adoption is via the engine's presence stats).*
- [x] **3 — Specific managers gate on capability membership.** runtimes/vscode
  gate on `'<id>' in computer_setup_active_capabilities`; fix the gcloud presence
  path; implement `adopt_if_present` semantics. *Done: `has_*` flags removed
  entirely — everything gates on active-capability membership; adoption is
  data-driven via a per-capability `adopt_if_present: <path>` probe in the engine
  (no hardcoded tool paths); gcloud path corrected to the Homebrew location;
  nvm/tfenv/gcloud/vscode (public) and dbt (work) declare adopt paths.*
- [x] **4 — Reminders as capability data**; gcloud/opencode shell snippets adopt
  the `# cs:requires-capability:` directive (consistency with nvm). *Done: engine
  derives `computer_setup_reminders` from active capabilities; local.yml renders
  them and no longer hardcodes gcloud/1password; the shell snippet directive gate
  now uses the active set; gcloud/opencode snippets declare their capability.*
- [x] **5 — Manager manifests** (`meta/manager.yml`) + generated `docs/managers.md`
  + contract-test validation. *Done: every role has a `meta/manager.yml`
  (name/tier/summary/capabilities/consumes); `scripts/managers generate` renders
  `docs/managers.md`; `scripts/managers check` (wired into `scripts/check.sh`)
  validates the manifests and that the doc is current. Metadata only — no runtime
  dispatch.*
- [ ] **6 — Rename & polish**: `catalog.yml` → `capabilities.yml`;
  `homebrew_mandatory_*` → `homebrew_baseline_*`; refresh docs, example-layer,
  and the three plugins (public/personal/work).

## Terminology (locked)

- **core / engine** — the `computer-setup` repo (Tier 0 machinery + managers).
- **manager** — an engine building block (Ansible role) that configures one kind
  of thing. The "building blocks" are the managers, *not* the plugins.
- **capability** — a selection token (a capability bundle's `id`).
- **plugin / content layer** — a git repo of pure data that activates managers.

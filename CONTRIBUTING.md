# Contributing

Thanks for your interest in improving **computer-setup**. This repo is the
*orchestrator* (the engine): Ansible roles, the bootstrap flow, and the plugin
contract. Personal/work data lives in separate **content layers** and never
belongs here.

## Ground rules

- **No personal data in the orchestrator.** No repo lists, project IDs,
  usernames, emails, or machine-specific values. Those belong in a content
  layer's `vars.yml`. The orchestrator ships *safe empty defaults*.
- **No secrets anywhere.** Tokens/keys stay in the environment, keychain, or a
  password manager and are referenced at runtime — never committed, even to a
  private layer.
- **macOS / Apple Silicon only.** The playbook asserts `Darwin` + `arm64`.

## Development setup

```bash
brew install ansible yq ansible-lint
ansible-galaxy collection install -r requirements.yml
```

## Before opening a PR

Run the checks locally:

```bash
./scripts/check.sh
ansible-lint
```

If you touch the merge logic, extend or run `tests/contract.yml` and confirm:

- list vars (`repositories`, `homebrew_baseline_formulae`, …) **append** across
  layers, and
- scalar vars (`dbt_bigquery_project`, …) take the **highest-priority** value and
  print an info message on overlap, and
- machine-local prefs stay in `computer_setup_prefs_file`, not layer `vars.yml`.

## Changing the contract

The **variable interface** (the set of vars roles read) plus `schema_version`
is the public API — see [docs/architecture.md](docs/architecture.md). Bump
`schema_version` (and the orchestrator's supported max in `local.yml` /
`bootstrap.sh`) when you make a breaking change to it.

## Adding a role, manager, or capability

- New roles (managers) go under `roles/` and are added to the `roles:` list in
  `local.yml` with a tag (and a `when:` capability gate if optional). Every role
  needs a `roles/<name>/meta/manager.yml` manifest (name, tier, summary,
  capabilities, consumes); run `scripts/managers generate` to refresh
  [docs/managers.md](docs/managers.md). `scripts/check.sh` validates it.
- Before adding a *specific* manager, apply the litmus test: if configuring the
  tool is just placing a file, it's **data** (a capability `config:` entry), not
  a new role. Only shell out to a tool's CLI when a file can't express it.
- New optional tools are **catalog items in a layer**, not in the orchestrator.
  See [examples/example-layer/capabilities.yml](examples/example-layer/capabilities.yml).

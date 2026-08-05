# Contributing

This repo is the *orchestrator* (the engine): Ansible roles, the bootstrap flow,
and the layer contract. Personal and work data live in separate **content
layers** and never belong here.

## Ground rules

- **No personal data in the orchestrator.** No repo lists, project IDs,
  usernames, emails, or machine-specific values — those belong in a layer's
  `vars.yml`. The orchestrator ships safe empty defaults.
- **No secrets anywhere.** Tokens and keys stay in the environment, keychain, or
  a password manager and are referenced at runtime — never committed, even to a
  private layer.
- **macOS / Apple Silicon only.** The playbook asserts `Darwin` + `arm64`.

## Development setup

```bash
brew install ansible yq ansible-lint shellcheck
ansible-galaxy collection install -r requirements.yml
```

## Before opening a PR

```bash
./scripts/check.sh
```

This runs everything: bash and Jinja syntax, `shellcheck`, the bootstrap prompt
tests, the layer contract and its negative paths, and `ansible-lint`. Both
linters are **required** — the script fails if either is absent rather than
skipping it, because a fresh machine is exactly where a tool is missing and
where "passed" has to mean it.

`ansible-lint` rules waived on architectural grounds are documented in
[.ansible-lint](.ansible-lint). `shellcheck` findings are waived **inline, at the
line, with a reason** — never globally — so each waiver is reviewed where it
applies.

Extend the tests when you touch what they cover:

- **`tests/bootstrap-prompts.sh`** — the prompt flow. That path only executes on
  a fresh machine, which is exactly where nobody is watching: it once shipped a
  capability menu that selected nothing at all, silently, because the prompt and
  the capability list were both reading stdin. `bash -n` cannot see that class of
  bug; only driving the loop with scripted answers can.
- **`tests/contract.yml`** — the merge logic. Confirm list vars append, scalar
  vars take the highest-priority value, capability ids collide correctly, and
  machine-local prefs stay out of layer `vars.yml`.
- **`tests/negative.yml`** — the guards (reserved keys, reserved prefixes,
  `schema_version`, malformed `capabilities.yml`). These assert a bad layer is
  *rejected for the stated reason*, so a guard cannot silently degrade into a
  no-op that still looks like a passing suite.

## Changing the contract

The **variable interface** plus `schema_version` is the public API — see
[docs/architecture.md](docs/architecture.md). Bump `schema_version`, and the
orchestrator's supported maximum in `local.yml` and `bootstrap.sh`, when making a
breaking change to it.

## Adding a role or capability

- New roles go under `roles/` and into the `roles:` list in `local.yml` with a
  tag (and a `when:` capability gate if optional).
- Apply the litmus test first: if configuring the tool is just placing a file,
  it is **data** — a capability `config:` entry — not a new role. Only shell out
  to a tool's CLI when a file cannot express it.
- New optional tools are **capabilities in a layer**, never in the orchestrator.
  See [examples/example-layer/capabilities.yml](examples/example-layer/capabilities.yml).

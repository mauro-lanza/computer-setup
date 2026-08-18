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
- **`tests/fixtures/lint/`** — the layer linter. Capabilities, questions and
  presets refer to each other by id, and every such reference fails *silently*
  when wrong: a preset naming a capability that does not exist simply selects
  nothing. Each broken reference in the fixture must be reported by name.

Lint your own layers after editing them:

```bash
computer-setup layers lint --cache ~/.local/share/computer-setup/layers
```

It also reports capabilities that appear in no preset — a report, not an error,
since presets are curated on purpose.

## Changing the contract

The **variable interface** plus `schema_version` is the public API — see
[docs/architecture.md](docs/architecture.md). Bump `schema_version`, and the
orchestrator's supported maximum in `local.yml` and `bootstrap.sh`, when making a
breaking change to it.

## Gotchas that bite engine code

- **Command tasks must use `argv:`** when any path can contain a space. The
  `code` binary lives under `/Applications/Visual Studio Code.app/...`, and a
  plain string is split on whitespace by `ansible.builtin.command`.
- **The `homebrew`/`homebrew_cask` modules skip entirely under `--check`**, so a
  dry run cannot report package drift. Where that signal matters, emit it from a
  `check_mode: false` read-only task instead.
- **A bare YAML `key:` parses to `None`, which is *defined*** — `| default([])`
  does not fire on it. The layer merge drops null-valued keys structurally for
  this reason; any new ingestion point for hand-editable YAML needs the same care.
- **Jinja reads `{#` as a comment-open, even inside a shell `#` comment.** Bash
  array-length syntax is therefore hazardous in a `.j2`; wrap it in `{% raw %}`
  or keep the file out of `templates/`.

More of these, with the failures that produced them, are in
[docs/findings.md](docs/findings.md).

## Where rationale lives

**Rationale lives in [docs/architecture.md](docs/architecture.md). Code states
the rule in a line or two and points there.**

This repo records *why* things are built the way they are, which is worth
keeping — but the same argument had been written out in full in up to six
places, and prose that exists twice is prose that goes stale in one of them. The
layers already learned this once: `capabilities.yml` in both content layers says
"the schema is defined once, in the engine — do not restate it here, that is how
the two copies drifted apart before."

So, when you are about to explain a decision in a comment:

- Is it **what this variable means**, or the **shape of an item** in it? That is
  interface documentation — it belongs next to the variable.
- Is it **why the design is this way**, what was rejected, or what broke once?
  That belongs in `docs/architecture.md`. Leave a one-line rule and a pointer.

A comment that reads like a paragraph is a signal you are writing the second
copy.

## Adding a role or capability

- New roles go under `roles/` and into the `roles:` list in `local.yml` with a
  tag (and a `when:` capability gate if optional).
- Apply the litmus test first: if configuring the tool is just placing a file,
  it is **data** — a capability `config:` entry — not a new role. Only shell out
  to a tool's CLI when a file cannot express it.
- New optional tools are **capabilities in a layer**, never in the orchestrator.
  See [examples/example-layer/capabilities.yml](examples/example-layer/capabilities.yml).
- The litmus test has one documented exception: a role is also justified when a
  file needs a **lifecycle command** run after it is written, which a `config:`
  entry cannot express. `scheduled_agents` exists only because launchd must be
  told to reload a changed plist. See "The engine names no tool" in
  [docs/architecture.md](docs/architecture.md).
- When you add a role, update the roster paragraph in `docs/architecture.md` —
  it enumerates every role by name and nothing else will catch it going stale.
- If the role exposes a variable a layer is meant to set, add a commented
  example to [examples/example-layer/vars.yml](examples/example-layer/vars.yml).
  That file is the only documentation of the public variable interface.

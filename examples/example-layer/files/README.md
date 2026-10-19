# Static files supplied by this layer

Roles resolve certain files across all layers' `files/` directories in
descending priority order (highest-priority layer wins). The engine ships no
content of its own, so a key no layer supplies is simply not deployed. A private
layer can override a file shipped by a public one.

Any key below may instead be supplied as `../templates/<key>.j2`, which is
rendered rather than copied. The key is unchanged; see `docs/architecture.md`.

## Whole-file shell configs

The engine looks up no file key by name. A layer lists the whole-file shell
configs it ships in `shell_config_files` (see `../vars.yml`), each entry a `key`
resolved against this directory and a `dest`. Editor settings work the same way:
each `extension_managers` entry names its own `settings_key`.

## Keys your layer invents

A capability's `config:` entry names any `src` it likes and the engine resolves
that string across layers; it has no built-in knowledge of it. For example the
public layer ships `zed/settings.json` and `opencode.json` purely because its
own `capabilities.yml` references those strings; there is no zed role and no
opencode role. See `example-tool` in `../capabilities.yml`, which uses
`example/config.toml`.

A `config:` entry can just as well deploy an EXECUTABLE (set `executable: true`,
dest somewhere on PATH such as `~/.local/bin`). That is how a layer supplies the
`program` of a `scheduled_agents` entry in `../vars.yml`: the script is layer
data, and so is the decision to run it on a schedule.

## Shell snippets: `files/shell/*.zsh`

Every `*.zsh` here is deployed into `~/.zsh/` (prefixed with this layer's
priority and name) and sourced by the layer-provided `~/.zshrc`. Use these for
aliases, functions, PATH tweaks, and tool integrations.

A snippet named `*.zsh.j2` is RENDERED as a template (it can read merged layer
vars such as `homebrew_prefix`) and lands at the same dest with `.j2` stripped.
A plain `*.zsh` is copied verbatim: write plain zsh and self-guard on tool
presence.

Optional capability gate: add a directive line to a snippet to deploy it only
when a capability is selected (see `capabilities.yml`):

```zsh
# cs:requires-capability: nvm
```

Without the directive a snippet is deployed to every machine. The orchestrator
parses this generically; it never hardcodes snippet filenames.

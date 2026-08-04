# Static files supplied by this layer.
#
# Roles resolve certain files across all layers' `files/` directories in
# descending priority order (highest-priority layer wins), falling back to the
# role's own bundled copy. A private layer can therefore override a file shipped
# by a public one.
#
# Any key below may instead be supplied as ../templates/<key>.j2, which is
# rendered rather than copied. The key is unchanged; see docs/architecture.md.
#
# Engine-recognized file keys (path relative to this files/ directory).
# These three are the only keys the orchestrator looks up by name:
#
#   zshrc                 → ~/.zshrc  (sources ~/.zsh/*.zsh, prompt, plugins)
#   p10k.zsh              → Powerlevel10k prompt config      (shell role)
#   vscode/settings.json  → VS Code user settings            (vscode role)
#
# Everything else is a key YOUR layer invents. A capability's `config:` entry
# names any `src` it likes and the engine resolves that string across layers —
# it has no built-in knowledge of it. For example the public layer ships
# `zed/settings.json` and `opencode.json` purely because its own capabilities.yml
# references those strings; there is no zed role and no opencode role.
# See `example-tool` in ../capabilities.yml, which uses `example/config.toml`.
#
# Shell snippets — files/shell/*.zsh:
#   Every *.zsh here is deployed into ~/.zsh/ (prefixed with this layer's
#   priority + name) and sourced by the layer-provided ~/.zshrc. Use these for
#   aliases, functions, PATH tweaks, and tool integrations.
#
#   A snippet named *.zsh.j2 is RENDERED as a template (it can read merged layer
#   vars such as homebrew_prefix) and lands at the same dest with .j2 stripped.
#   A plain *.zsh is copied verbatim — write plain zsh and self-guard on tool
#   presence.
#
#   Optional capability gate — add a directive line to a snippet to deploy it
#   only when a capability is selected (see capabilities.yml):
#
#       # cs:requires-capability: nvm
#
#   Without the directive a snippet is deployed to every machine. The
#   orchestrator parses this generically — it never hardcodes snippet filenames.
#
# Drop any of these here to have this layer provide (or override) them.

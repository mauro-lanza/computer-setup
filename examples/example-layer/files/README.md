# Static files supplied by this layer.
#
# Roles resolve certain files across all layers' `files/` directories in
# descending priority order (highest-priority layer wins), falling back to the
# role's own bundled copy. A private layer can therefore override a file shipped
# by a public one.
#
# Recognized file keys (path relative to this files/ directory):
#
#   zshrc                 → ~/.zshrc  (sources ~/.zsh/*.zsh, prompt, plugins)
#   p10k.zsh              → Powerlevel10k prompt config      (shell role)
#   vscode/settings.json  → VS Code user settings            (vscode role)
#   zed/settings.json     → Zed editor settings              (zed role)
#   opencode.json         → opencode CLI config              (opencode role)
#
# Shell snippets — files/shell/*.zsh:
#   Every *.zsh here is deployed into ~/.zsh/ (prefixed with this layer's
#   priority + name) and sourced by the layer-provided ~/.zshrc. Use these for
#   aliases, functions, PATH tweaks, and tool integrations. They are copied
#   verbatim (not templated), so write plain zsh and self-guard on tool presence.
#
#   Optional capability gate — add a directive line to a snippet to deploy it
#   only when a capability is selected (see catalog.yml `capability`):
#
#       # cs:requires-capability: nvm
#
#   Without the directive a snippet is deployed to every machine. The
#   orchestrator parses this generically — it never hardcodes snippet filenames.
#
# Drop any of these here to have this layer provide (or override) them.

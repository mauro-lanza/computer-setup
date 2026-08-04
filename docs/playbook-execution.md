# Playbook Execution Reference

Step-by-step breakdown of what `local.yml` does on each run and how it
handles user-made changes.

## Execution Phases

### Phase 1: `computer_setup` role (setup & detection)

1. **Gather facts** -- Ansible collects system info (OS, architecture, env
   vars).
2. **Platform check** -- Asserts macOS + arm64. Fails immediately otherwise.
3. **Load preferences** -- Reads `computer_setup_prefs_file` (normally
   `~/.mac-prefs.yml`, written by `bootstrap.sh`). If missing, all optionals
   default to empty lists. If malformed, warns and continues with defaults.
4. **Merge content layers** -- Reads `~/.config/computer-setup/layers.yml`, then
   merges each layer's `vars.yml` in ascending priority (lists append, scalars
   take the highest-priority value). The merged keys become the role variable
   interface, and layer `files/`/`templates/` search paths are built for file
   and template resolution. Keys in `computer_setup_reserved_layer_keys` (plus
   anything in the `computer_setup_*` namespace) can never be set by a layer.
   Absent manifest = no layers, safe empty defaults.
5. **Merge capability registries** -- Each layer's `capabilities.yml` is merged
   into `computer_setup_capability_registry`. Capabilities are pure data: id,
   type (`formula`/`cask`/`vscode`/`feature`), packages, optional `config:`
   bundles, `reminders:` and `adopt_if_present:`.
6. **Probe adoptable capabilities** -- The only detection the engine performs:
   a generic `stat` of whatever path each capability declares in
   `adopt_if_present`. The engine hardcodes no tool paths or package names.
7. **Resolve active capabilities** --
   `computer_setup_capabilities` = the explicit `selected_capabilities` from
   prefs; `computer_setup_active_capabilities` = those plus every capability
   whose `adopt_if_present` path exists (so an already-configured machine is
   adopted and stays managed). Everything gates on the active set.
8. **Derive the role interface** -- From the *selected* capabilities:
   `homebrew_optional_formulae`, `homebrew_optional_casks`,
   `vscode_optional_extensions` (install what you picked). From the *active*
   capabilities: `computer_setup_config_deploys` and
   `computer_setup_reminders` (also manage what's already present).

### Phase 2: Roles (in order)

#### homebrew -- Install packages

9. Partition all casks (`homebrew_baseline_casks + homebrew_optional_casks`)
   into the `homebrew_adopt_casks` allow-list and everything else.
10. Install all baseline + optional formulae (`brew update` first if
    `homebrew_update` is true). Tap-qualified names (e.g. `user/tap/formula`)
    are handled automatically by Homebrew.
11. Install the adopt set with `--adopt`, then the remaining casks fresh.

#### git -- Configure git

12. Stat the VS Code binary (`vscode_code_binary`).
13. Resolve `git_editor_resolved`: the layer/prefs `git_editor` if set, else
    `code --wait` when that binary exists, else `vim`.
14. Deploy `~/.gitignore_global` from `git_global_gitignore_entries` (layer
    content) — the file is written whole by `copy`.
15. Render `~/.gitconfig` from `gitconfig.j2` with `backup: true`. The template
    renders `user.name`/`user.email` (from prefs, omitted when empty),
    `init.defaultBranch` (`git_default_branch`), `core.editor`,
    `core.excludesFile` and every section in `git_config_sections`. There are no
    separate `git_config` tasks — the whole file is one render, so a
    pre-existing `~/.gitconfig` is replaced wholesale (hence the backup).

#### shell -- Shell environment

16. Create `~/.zsh/` and deploy the engine-owned CLI snippet
    (`50-computer-setup-cli.zsh` — the `drift-*`/`repos-*` commands).
17. Discover every active layer's `files/shell/*.zsh` and deploy them into
    `~/.zsh/` named `<priority>-<layer>-<file>` (deterministic load order, no
    collisions). A snippet may declare `# cs:requires-capability: <name>` to be
    deployed only when that capability is active; the engine parses the
    directive generically (it never hardcodes snippet filenames).
18. Reconcile via `~/.zsh/.computer-setup-snippets`: snippets listed in the
    previous run's manifest (or discovered now but gate-disabled) and no longer
    deployed are removed; the manifest is rewritten. Files not in the manifest
    are never inferred as managed.
19. Deploy the layer-provided `~/.zshrc` (with backup) and `~/.p10k.zsh`
    (resolved across layers, highest priority wins) via the `deploy_layer_file`
    primitive. The orchestrator ships none of its own.
20. `~/.oh-my-zsh`: deleted **only** when `shell_remove_oh_my_zsh=true`
    (opt-in). Otherwise, if present, the role just warns that it is unmanaged
    and inert.

#### vscode -- VS Code extensions & settings

21. The whole role is gated in `local.yml` on
    `'vscode' in (computer_setup_active_capabilities | default([]))` — selected
    **or** adopted via `adopt_if_present`. Selection covers a same-run install
    (homebrew runs first).
22. Stat the `code` binary as an execution guard, then list installed
    extensions (`check_mode: false`, so the daily check-mode run still skips
    already-present extensions).
23. Install any missing `vscode_baseline_extensions + vscode_optional_extensions`.
24. Deploy layer-provided `vscode/settings.json` (via `deploy_layer_file`).

#### layer_configs -- Data-driven config deployment

25. A ~20-line generic loop over `computer_setup_config_deploys` (derived in
    Phase 1 from the active capabilities' `config:` bundles). Each entry is
    resolved across layers and deployed via `deploy_layer_file` (highest-priority
    layer wins; no-op when no layer provides it). Entry keys:
    - `src` -- lookup key resolved across layer `files/`/`templates/`.
    - `dest` -- destination path (parent dir created).
    - `kind` -- `file` (copy, default) or `template`.
    - `mode` -- file mode, default `0644`.
    - `fallback_dir` -- role-bundled fallback search dir, default
      `roles/layer_configs/files`.

    The role has **no built-in entries**. Current configs are layer data, e.g.
    `zed/settings.json` and `opencode.json` in computer-setup-layer-public and
    `profiles.yml.j2` -> `~/.dbt/profiles.yml` (`kind: template`) in
    computer-setup-layer-work. Adding a managed config needs no engine change.

#### macos -- System preferences

26. Apply the `macos_defaults` declared by content layers via `osx_defaults`.
    Each entry may carry `notify:` to trigger a handler.
27. If Rectangle.app exists, apply `macos_rectangle_defaults`.
28. Deploy `~/.local/bin/macos-capture` — a read-only helper that diffs this
    machine's live defaults against the declared values and emits paste-ready
    YAML (the reverse of enforcement; see
    [Maintenance helpers](../README.md#maintenance-helpers)).

#### runtimes -- Language toolchains

29. If the `nvm` capability is active and `nvm.sh` exists, compare the default
    alias against `runtimes_nvm_default_node` and install + alias on mismatch.
30. If the `tfenv` capability is active and `tfenv` exists, compare the active
    version against `runtimes_tfenv_terraform_version` and install + use on
    mismatch.

#### repositories -- Project catalog (opt-in, `never` tag)

31. Skipped on normal runs (bootstrap and the scheduled agents). Runs only via
    `drift-apply --tags repositories`. Loads
    `repositories_catalog_file` (`~/.repositories.yml`) — falling back to the
    layer-merged `repositories:` — and clones any missing repos. Entries with
    `active: false` are skipped. Non-destructive: `update: false` and existing
    checkouts are never touched. Each entry's `post_clone` hooks run once, on
    the run that actually cloned it (skipped under `--check`).

#### upgrade -- Package upgrades (opt-in, `never` tag)

32. Skipped on normal runs; runs only with `--tags upgrade` (the `drift-update`
    helper and the 09:00 agent). `brew update`, then preview which *managed*
    packages are outdated. Both `brew outdated` tasks are skipped when their
    package lists are empty (a bare `brew outdated` would report unmanaged
    packages the apply step could never upgrade).
33. The cask preview and cask upgrade are additionally gated on
    `upgrade_include_casks` (default true; the scheduled 09:00 agent passes
    `false` because cask upgrades replace app bundles and can raise a sudo
    prompt that a TTY-less LaunchAgent cannot answer).
34. Upgrades apply only when `upgrade_assume_yes` is true and not in check mode:
    managed formulae and casks to `latest` (casks `greedy` per
    `upgrade_casks_greedy`), Ansible Galaxy collections `--upgrade`, and — when
    nvm is present — Node `upgrade_nvm_node`. Otherwise it prints a
    preview-only notice. tfenv's Terraform is deliberately *not* upgraded (it is
    pinned by `runtimes_tfenv_terraform_version`).

#### drift_correction -- Scheduled monitoring and upgrades

35. Ensure `~/Library/Logs`, `~/Library/LaunchAgents` and
    `drift_correction_wrapper_dir` (`~/.local/bin`) exist.
36. Deploy the shared `computer-setup-layers` helper used to sync layer repos.
37. Deploy `~/.local/bin/computer-setup-run` from template — the single entry
    point for every `ansible-pull`. It builds the pull argument set once and
    takes a mode: `apply` (interactive, streams, exec's directly), `check`
    (`-e homebrew_update=false --check --diff`) or `upgrade` (`--tags upgrade
    -e upgrade_assume_yes=true -e upgrade_include_casks=false`). Both scheduled
    modes probe the repo with an SSH `git ls-remote` and exit 0 silently when it
    is unreachable, then sync layers, log, trim to
    `drift_correction_log_max_lines`, and notify.
38. Deploy one LaunchAgent plist per entry in `drift_correction_agents`:
    `com.ansible.drift-upgrade` (09:00, `upgrade`) and
    `com.ansible.drift-correction` (10:00, `check`) — staggered so the morning
    upgrade finishes before the check reports on it.
39. Remove the superseded `~/.local/bin/drift-check` wrapper and its
    separately-named logs.
40. If the runner or any plist changed, the handler reloads every agent.

### Phase 3: Post-tasks

41. Run `gh auth status`, then print `Setup complete!` plus `gh auth login` if
    unauthenticated and every string in `computer_setup_reminders` (contributed
    by the active capabilities — the engine hardcodes no reminder text).

### Phase 4: Handlers (run once, at the end)

- **Shell config changed** -- Prints a message telling you to open a new
  terminal or `exec zsh`.
- **Restart Dock and Finder** -- `killall Dock` + `killall Finder` (only when a
  macOS default that declares `notify:` changed).
- **Reload scheduled agents** -- `launchctl bootout` + `bootstrap` for every
  entry in `drift_correction_agents` (only if the runner or a plist changed).

---

## How User-Made Changes Are Handled

### Enforced (reverts your changes on next run)

| What you change manually | Behaviour |
|---|---|
| `.zshrc` | Replaced from the layer-provided `zshrc` on every run (a timestamped backup is kept). Manual edits are lost — edit it in the layer. |
| `~/.zsh/*.zsh` managed snippets (engine CLI + layer snippets) | Regenerated from the engine template and layer `files/shell/*.zsh`. Manual edits are lost. |
| `~/.gitconfig` | Re-rendered whole from `gitconfig.j2` (user, `init.defaultBranch`, `core.editor`, `core.excludesFile`, `git_config_sections`). Anything not declared in a layer is dropped; a timestamped backup is kept. |
| `~/.gitignore_global` | The `copy` task replaces the entire file (from `git_global_gitignore_entries`). |
| macOS defaults (Dock size, Finder settings, etc.) | `osx_defaults` enforces the layer-declared value. Changes via System Settings are reverted. |
| NVM default alias (`nvm alias default 18`) | The `slurp` check detects the mismatch and re-runs `nvm alias default <declared>`. |
| Capability config files (e.g. `~/.config/zed/settings.json`, `~/.config/opencode/opencode.json`, `~/.dbt/profiles.yml`) | Re-deployed from the providing layer whenever the capability is active. |
| `computer-setup-run` / LaunchAgent plists | Template tasks regenerate from source, then the agents are reloaded. |

### Additive-only (won't remove your stuff)

| What you change manually | Behaviour |
|---|---|
| Install extra Homebrew packages | Preserved. `state: present` only ensures listed packages exist. |
| Install extra VS Code extensions | Preserved. The task only installs missing listed extensions. |
| Uninstall a managed Homebrew package | Reinstalled on next run. |
| Uninstall a managed VS Code extension | Reinstalled on next run. |

### Preserved (left untouched)

| What you change manually | Behaviour |
|---|---|
| Extra files in `~/.zsh/` | Left on disk. Cleanup only removes paths recorded in `~/.zsh/.computer-setup-snippets` from a previous run. Add durable shell behavior to a layer instead. |
| `~/.oh-my-zsh` | Not removed unless you opt in with `-e shell_remove_oh_my_zsh=true`; otherwise the role only warns that it is unmanaged. |
| `~/.mac-prefs.yml` edited manually | Read as-is. Malformed YAML triggers the rescue block and falls back to defaults. |
| Local changes in a catalogued repo (`repositories` role) | Never touched. Cloning uses `update: false` and only ever clones repos that are entirely absent — existing checkouts are never fetched or reset. |

### Fully managed (manual edits overwritten)

| What you change manually | Behaviour |
|---|---|
| `~/.p10k.zsh` | Replaced from the layer-provided `p10k.zsh` on every run. Prompt changes belong in a layer. |
| tfenv active version (`tfenv use 1.11.0`) | Reverted to `runtimes_tfenv_terraform_version` on the next run (and never auto-upgraded). |

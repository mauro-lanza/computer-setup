# Playbook Execution Reference

Step-by-step breakdown of what `local.yml` does on each run and how it
handles user-made changes.

## Execution Phases

### Phase 1: Pre-tasks (setup & detection)

1. **Gather facts** -- Ansible collects system info (OS, architecture, env
   vars).
2. **Platform check** -- Asserts macOS + arm64. Fails immediately otherwise.
3. **Load preferences** -- Reads `~/.mac-prefs.yml` (written by
   `bootstrap.sh`). If missing, all optionals default to empty lists. If
   malformed, warns and continues with defaults.
4. **Detect gcloud SDK** -- Checks if `~/google-cloud-sdk` exists.
5. **Detect existing dbt config** -- Checks if `~/.dbt/profiles.yml` exists.
6. **Merge content layers** -- Reads `~/.config/computer-setup/layers.yml`, then
   merges each layer's `vars.yml` in ascending priority (lists append, scalars
   take the highest-priority value). The merged keys become the role variable
   interface, and layer `files/`/`templates/` search paths are built for file
   and template resolution. Absent manifest = no layers, safe empty defaults.
7. **Resolve capability flags** -- Derives `has_gcloud`, `has_dbt`, `has_zed`,
   and `has_opencode` booleans from preferences. These gate conditional roles /
   post-task reminders. `has_dbt` is `use_dbt` (a `~/.mac-prefs.yml` toggle)
   **or** an already-present `~/.dbt/profiles.yml`.

### Phase 2: Roles (in order)

#### homebrew -- Install packages

1. Install all mandatory + optional formulae (`brew update` first if
   `homebrew_update` is true). Tap-qualified names (e.g.
   `user/tap/formula`) are handled automatically by Homebrew.
2. Install all mandatory + optional casks.

#### git -- Configure git

3. Set `user.name` and `user.email` from prefs (skipped if empty).
4. Render `~/.gitconfig` from the merged layer vars: `git_default_branch`
   (`init.defaultBranch`), and every section in `git_config_sections`. The
   template is a generic renderer; the values come from layers.
5. Detect VS Code (stat on app bundle), set `core.editor` to
   `code --wait` or fall back to `vim`.
6. Deploy `~/.gitignore_global` from `git_global_gitignore_entries` (layer
   content) and set `core.excludesFile`.

#### shell -- Shell environment

7. Create `~/.zsh/` and deploy the engine-owned CLI snippet
   (`50-computer-setup-cli.zsh` — the `drift-*`/`repos-*` commands).
8. Deploy every layer's `files/shell/*.zsh` into `~/.zsh/` (prefixed with the
   layer priority + name), and remove managed snippets no layer provides.
9. Deploy the layer-provided `~/.zshrc` and `~/.p10k.zsh` (resolved across
   layers, highest priority wins). The orchestrator ships none of its own.
10. Remove legacy `~/.oh-my-zsh`.

#### vscode -- VS Code extensions

15. Detect VS Code via app bundle stat.
16. List installed extensions, install any missing mandatory + optional ones.

#### dbt -- Analytics config (conditional)

16b. Only runs when `has_dbt` is true. Creates `~/.dbt/` and renders a
     `profiles.yml.j2` resolved from a content layer (`dbt_cloud.yml` is left
     unmanaged). Skipped if no layer supplies a profiles template.

#### macos -- System preferences

17. Apply the `macos_defaults` declared by content layers via `osx_defaults`.
18. If Rectangle.app exists, apply `macos_rectangle_defaults`.
19. If any Dock/Finder defaults changed, handler kills Dock and Finder to
    apply.
19b. Deploy `~/.local/bin/macos-capture` — a read-only helper that diffs this
     machine's live defaults against the declared values and emits paste-ready
     YAML (the reverse of enforcement; see the README).

#### runtimes -- Language toolchains

20. If NVM is installed and the default alias doesn't match the declared
    version, install + alias it.
21. If tfenv is installed and the active Terraform version differs from the
    declared version, install + use it.

#### repositories -- Project catalog (opt-in, `never` tag)

21b. Skipped on normal runs (bootstrap and the daily drift check). Runs only
     via `--tags repositories` / the `repos-resurrect` helper. Loads
     `~/.repositories.yml` and clones any missing repos (non-destructive:
     existing checkouts are never touched), running each entry's `post_clone`
     hooks once on first clone.

#### drift_correction -- Daily sync monitoring

22. Ensure `~/Library/Logs`, `~/Library/LaunchAgents`, `~/.local/bin`
    exist.
23. Deploy `~/.local/bin/drift-check` wrapper script from template.
24. Deploy LaunchAgent plist (daily at 10:00).
25. If either file changed, handler reloads the LaunchAgent.

### Phase 3: Post-tasks

26. Check `gh auth status`, print conditional setup reminders (`gh auth
    login` if not authenticated, `gcloud auth login` if gcloud is
    installed, 1Password sign-in if 1Password is selected).

### Phase 4: Handlers (run once, at the end)

- **Shell config changed** -- Prints a message telling you to open a new
  terminal.
- **Restart Dock and Finder** -- `killall Dock` + `killall Finder` (only
  if macOS defaults changed).
- **Reload drift-correction agent** -- `launchctl bootout` + `bootstrap`
  (only if plist/script changed).

---

## How User-Made Changes Are Handled

### Enforced (reverts your changes on next run)

| What you change manually | Behaviour |
|---|---|
| `.zshrc` | Replaced from the layer-provided `zshrc` on every run. Manual edits are lost — edit it in the layer. |
| `~/.zsh/*.zsh` managed snippets (engine CLI + layer snippets) | Regenerated from the engine template and layer `files/shell/*.zsh`. Manual edits are lost. |
| Git config (`user.name`, `editor`, `defaultBranch`, `excludesFile`, `git_config_sections`) | Rendered to the exact declared value (values come from layers). |
| `~/.gitignore_global` | The `copy` task replaces the entire file (from `git_global_gitignore_entries`). |
| macOS defaults (Dock size, Finder settings, etc.) | `osx_defaults` enforces the layer-declared value. Changes via System Settings are reverted. |
| NVM default alias (`nvm alias default 18`) | The `slurp` check detects the mismatch and re-runs `nvm alias default lts/*`. |
| Drift-check script / LaunchAgent plist | Template tasks regenerate from source. |

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
| Extra files in `~/.zsh/` | A managed snippet a layer no longer provides is removed on the next run; unmanaged files you add there are left on disk. Add shell behavior to a layer instead. |
| `~/.mac-prefs.yml` edited manually | Read as-is. Malformed YAML triggers the rescue block and falls back to defaults. |
| Local changes in a catalogued repo (`repositories` role) | Never touched. Cloning uses `update: false` and only ever clones repos that are entirely absent — existing checkouts are never fetched or reset. |

### Fully managed (manual edits overwritten)

| What you change manually | Behaviour |
|---|---|
| `~/.p10k.zsh` | Replaced from the layer-provided `p10k.zsh` on every run. Prompt changes belong in a layer. |
| tfenv active version (`tfenv use 1.11.0`) | Reverted to `runtimes_tfenv_terraform_version` on the next run. |

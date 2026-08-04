# Proposal: machine answers, presets, and de-privileging the editor

Status: draft / not implemented
Scope: `computer-setup` engine + all layer repos

## Problem

The engine has exactly one selection axis: `selected_capabilities`, a set of
independent yes/no answers. Everything else a person might want different on a
new machine is either an engine constant or unconditional layer data.

Concretely, a fresh machine cannot choose its editor, its shell prompt, where
its repositories live, or whether an unattended `ansible-pull` runs every
morning — and VS Code is privileged in engine code in three places by literal
string.

The audit behind this proposal identified four distinct classes of problem.
They need three fixes, not one.

| Class | Example | Fix |
| --- | --- | --- |
| A. Machine facts with no home | `repositories_base_dir`, drift schedule, terraform version, git signing key | Fix 1 |
| B. Single-select decisions with no representation | editor, prompt, shell, window manager, runtime manager | Fix 1 (same mechanism) |
| C. Engine privileging tools by magic string | `id == 'vscode'`, `'nvm'`, `'tfenv'`, `Rectangle.app`, `p10k.zsh` | Fix 3 |
| D. One value duplicated across config files | 4 AI model strings with 3 values; python version twice; default branch twice | Fix 2 |

A and B are the same mechanism with different widget types. That is the central
simplification in this design.

---

## Fix 1 — Questions, answers, and a machine-prefs tier

### 1.1 New layer file: `questions.yml`

A layer may declare questions. They are merged across layers exactly like
capabilities: descending priority, union by `id`, highest priority wins the
whole entry.

```yaml
schema_version: 1
questions:
  - id: editor
    type: select
    prompt: "Primary editor"
    default: vscode
    options:
      - value: vscode
        desc: "Visual Studio Code"
        implies: [vscode]
        set:
          git_editor: "code --wait"
          editor_command: "code"
      - value: zed
        desc: "Zed"
        implies: [zed]
        set:
          git_editor: "zed --wait"
          editor_command: "zed"
      - value: none
        desc: "Don't manage the editor; respect $EDITOR"
        set:
          git_editor: ""

  - id: repositories_base_dir
    type: path
    prompt: "Where should repositories be cloned?"
    default: "{{ home_dir }}/Projects"
    tier: machine

  - id: drift_enabled
    type: bool
    prompt: "Install the scheduled drift-check and upgrade agents?"
    default: true
    tier: machine
    set:
      drift_correction_enabled: "{{ answer }}"
```

Widget types: `bool`, `text`, `path`, `select`. `select` options carry two
optional payloads:

- `set:` — variables published into play scope.
- `implies:` — capability ids added to `selected_capabilities`. This is the
  generic dependency edge that replaces the bespoke `requires_vscode` flag.

### 1.2 Storage

`~/.mac-prefs.yml` gains an `answers` map alongside the existing keys:

```yaml
git_user_name: "…"
git_user_email: "…"
preset: developer          # optional, see Fix 1.4
answers:
  editor: zed
  repositories_base_dir: /Users/x/src
  drift_enabled: false
selected_capabilities: [...]
```

An absent `answers` key means "all defaults", so existing prefs files keep
working untouched.

### 1.3 The security problem this creates, and the guard

Questions are **layer-declared**, and their `set:` payloads land in play scope.
Without a guard this is a straight privilege-escalation bypass around the
reserved-key model: a compromised layer that cannot write `repo_url` in
`vars.yml` could simply declare a question whose only option sets it, and the
morning unattended `ansible-pull` is redirected.

Therefore:

1. The **same** reserved-key and reserved-prefix guard that applies to
   `vars.yml` applies to every `set:` payload, with one exception:
2. an explicit **machine-tier allowlist** of keys that a question may set even
   though a layer var may not. Initially:
   `repositories_base_dir`, `drift_correction_enabled`,
   `drift_correction_schedule_hour`, `drift_correction_upgrade_hour`.
3. Category 3 keys from `docs/architecture.md` (`upgrade_assume_yes`,
   `upgrade_include_casks`, `repo_url`, `repo_branch`, `ansible_*`,
   `computer_setup_*`) are **never** settable by a question. The boundary is
   unchanged.

This makes the tiering explicit: engine defaults < layer vars (by priority) <
machine answers, with each tier able to reach strictly fewer keys as you go up
in privilege.

`tests/negative.yml` must gain cases asserting a question setting a Category 3
key is *rejected*, not silently ignored — matching the existing convention.

### 1.4 Presets

Answering ~48 capabilities plus ~14 questions linearly is how a setup script
becomes something you avoid running. Layers may declare presets:

```yaml
presets:
  - id: developer
    desc: "Full development machine"
    answers: {editor: zed, drift_enabled: true}
    capabilities: [nvm, uv, ripgrep, zed, docker-cli]
  - id: minimal
    desc: "Shell and git only"
    answers: {editor: none, drift_enabled: false}
    capabilities: []
```

Bootstrap flow becomes:

1. Pick a preset (or `custom`).
2. `Review individual answers? [y/N]` — declining accepts the preset wholesale.
3. Reviewing walks the existing per-item loop, pre-filled from the preset.

Plus `bootstrap.sh --answers <file>` for a zero-touch rebuild, which is the
actual "new machine in one command" story.

### 1.5 Engine changes

- `roles/computer_setup/tasks/merge_layer_questions.yml` — merge, mirroring
  `merge_layer_capabilities.yml`.
- Validate every stored answer against the merged registry; unknown ids warn,
  invalid `select` values fail loudly.
- Publish `computer_setup_answers` as a fact and apply `set:` payloads, **in
  `pre_tasks`, before layer `vars.yml` merge**.
- Union `implies:` into `computer_setup_active_capabilities`.
- `bootstrap.sh`: extend the TSV loader and prompt loop; `write_prefs` emits
  `answers:` and `preset:`.
- `computer-setup-run.sh.j2` must pass the machine-tier answers through, or the
  scheduled agent will disagree with interactive runs — this is the existing
  `repositories_base_dir` bug (`computer-setup-run.sh.j2:42-45`) and it must not
  be reproduced.

### 1.6 Useful side effect

Because answers are published as play-scope facts *before* the layer var merge,
layer `vars.yml` **can** template against them. This is a legitimate exception
to "a layer var cannot reference another layer var" (`architecture.md:127-143`),
because answers are not layer vars. It is what makes Fix 2 possible.

---

## Fix 2 — Config files become templates

`opencode.json`, `vscode/settings.json`, `zed/settings.json` and the shell
snippets are currently `files/` (copied verbatim), so no value can be shared
between them. Convert them to `templates/*.j2` — `deploy_layer_file.yml` already
supports `kind: template`, so this needs **no engine change**.

Deduplicates:

- AI model: one `ai_default_model` var replacing 4 strings / 3 values.
- Python version: one var replacing `vars.yml` + `20-aliases.zsh`.
- Default branch: one var replacing `main` / `master` disagreement.
- `homebrew_prefix` instead of ~10 literal `/opt/homebrew`.

Also lets optional-tool references degrade properly, e.g. only emit
`todo-tree.ripgrep.ripgrep` when `ripgrep` is active.

Lowest risk, highest immediate value. Do this first.

---

## Fix 3 — De-magic the engine

Replace literal-string gates with data:

| Today | Proposed |
| --- | --- |
| `local.yml:50` `'vscode' in active_capabilities`; `bootstrap.sh:438`; `type: vscode` | capability `provides: [editor-extensions]` tokens |
| `macos/tasks/main.yml:14-29` hardcoded `Rectangle.app` | generic `when_app_present: <path>` on a `macos_defaults` group |
| `runtimes/tasks/main.yml:10,42` literal `nvm`/`tfenv` | data-driven runtime-manager table, so pyenv/mise/asdf need no engine change |
| `shell/tasks/main.yml:138,151` literal `zshrc`, `p10k.zsh` | layer-declarable file keys |

Largest change, least urgent. It removes the contradiction between the code and
the stated "the engine hardcodes nothing" invariant.

---

## Explicitly out of scope

- **Aesthetics and behavioral habits** stay unconditional layer data: colour
  customizations, Peacock palette, dock tile size, tap-to-click, arrow-key
  rebinding, `auto_activate_venv`. These are layer content and editing your own
  layer is the correct way to change them.
- **Non-zsh shells.** fish/bash support would require rewriting the engine's own
  management CLI. Noted as a known limitation; not attempted.
- **Intel / Linux.** The arm64 assert is deliberate scope.

---

## Known issues found alongside, tracked separately

These are not preference bias but were found during the audit and are arguably
higher severity:

1. `~/.gitconfig` is replaced wholesale every run (`roles/git/tasks/main.yml:38-45`),
   destroying pre-existing `includeIf`, signing config and credential helpers.
   No merge mode, no opt-out.
2. Single global git identity, with `git_user_*` reserved — so the work layer
   **cannot** supply a work email. This contradicts the work/personal layer
   premise the whole repo is built on. `includeIf` support is the standard fix.
3. `p10k.zsh:47` requires a powerline/Nerd font that no layer installs.
4. `30-functions.zsh:5-27` deploys Docker helpers unconditionally though
   `docker-cli` and `colima` are both optional — missing a
   `cs:requires-capability` directive.
5. `scripts/computer-setup-layers:19-28` silently rewrites HTTPS remotes to SSH,
   blocking the port-22 case `bootstrap.sh:205-207` itself warns about.
6. `runtimes/defaults/main.yml:3` pins terraform `1.12.2` in the engine and
   drift *reverts* a hand-set version daily.

---

## Sequencing

1. **Fix 2** — layers only, no engine risk, immediate dedup.
2. **Fix 1, editor as the pilot** — proves the mechanism end to end on the
   motivating case.
3. **Fix 1, machine tier** — touches the security model; lands with negative
   tests.
4. **Fix 1, presets** — needed before the question count grows further.
5. **Fix 3** — incremental, one magic string at a time.

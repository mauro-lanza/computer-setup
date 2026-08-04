#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# computer-setup bootstrap (orchestrator)
#
# Run on a fresh Mac to install prerequisites, define/clone content layers, and
# kick off the Ansible playbook.
#
#   Phase 0  Prerequisites + GitHub auth (no repo access required)
#   Phase 1  Layer selection & fetch (define manifest, clone to layer cache)
#   Phase 2  Build preferences (merge capabilities → prompts → ~/.mac-prefs.yml)
#   Phase 3  Run Ansible (ansible-pull the orchestrator with merged input)
#
# Usage: curl -fsSL <raw-url>/bootstrap.sh | bash
#    or: ./bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────

# ─── Locations ────────────────────────────────────────────────────────────────
PREFS_FILE="$HOME/.mac-prefs.yml"
CONFIG_DIR="$HOME/.config/computer-setup"
LAYERS_FILE="$CONFIG_DIR/layers.yml"
LAYER_CACHE="$HOME/.local/share/computer-setup/layers"

# Orchestrator repo. Bootstrap authenticates GitHub before cloning layers or
# running ansible-pull, so GitHub repos are accessed over SSH consistently.
ORCH_OWNER="mauro-lanza"
ORCH_NAME="computer-setup"
REPO_URL="git@github.com:${ORCH_OWNER}/${ORCH_NAME}.git"
REPO_BRANCH="${BOOTSTRAP_BRANCH:-main}"

# Highest layer schema_version this orchestrator understands.
SCHEMA_VERSION_MAX=1

export HOMEBREW_NO_ANALYTICS=1

# Under `curl … | bash` stdin IS the script source, so every `read` would
# consume the unparsed remainder of this file. Re-point stdin at the terminal
# before any prompt. A function, not top-level code, so sourcing this file for
# tests does not hijack the harness's stdin.
INTERACTIVE=1
reattach_stdin() {
    if [[ ! -t 0 ]]; then
        if [[ -r /dev/tty ]] && { exec < /dev/tty; } 2>/dev/null; then
            :
        else
            INTERACTIVE=0
        fi
    fi
}

# Refuse to guess: a non-interactive run cannot answer "which layers?" or "what
# is your git email?", and defaulting them yields an empty manifest.
require_tty() {
    if [[ "$INTERACTIVE" -eq 0 ]]; then
        error "No terminal available for prompts."
        error "Re-run attached to a TTY, e.g.:"
        error "    bash <(curl -fsSL ${1:-<raw-url>/bootstrap.sh})"
        error "or clone the repo and run ./bootstrap.sh"
        exit 1
    fi
}

# When piped via curl, BASH_SOURCE may be empty. Fall back to current dir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
LAYER_SYNC_SCRIPT="$SCRIPT_DIR/scripts/computer-setup-layers"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}▶${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }

# ─── Helper: yes/no prompt with custom default ───────────────────────────────
ask_yn() {
    local prompt="$1" default="${2:-n}" yn
    require_tty
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " yn
        yn="${yn:-y}"
    else
        read -rp "$prompt [y/N]: " yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

# ─── Helper: YAML-safe single-line string ────────────────────────────────────
yaml_quote() {
    local s="$1"
    s="${s//\\/\\\\}"   # escape backslashes
    s="${s//\"/\\\"}"   # escape double quotes
    printf '"%s"' "$s"
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 0 — Prerequisites + GitHub auth
# ═════════════════════════════════════════════════════════════════════════════

install_xcode_clt() {
    if xcode-select -p &>/dev/null; then
        ok "Xcode Command Line Tools already installed"
        return
    fi
    info "Installing Xcode Command Line Tools..."
    xcode-select --install
    until xcode-select -p &>/dev/null; do
        sleep 5
    done
    ok "Xcode Command Line Tools installed"
}

install_homebrew() {
    if command -v brew &>/dev/null; then
        ok "Homebrew already installed"
        return
    fi
    info "Installing Homebrew..."
    if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        error "Homebrew installation failed"
        exit 1
    fi
    eval "$(/opt/homebrew/bin/brew shellenv)"
    ok "Homebrew installed"
}

# yq/git/gh are needed before we can read capabilities or clone layers.
ensure_prereqs() {
    local pkg
    for pkg in yq git gh; do
        if ! command -v "$pkg" &>/dev/null; then
            info "Installing ${pkg}..."
            brew install "$pkg"
        fi
    done
    ok "Core prerequisites present (yq, git, gh)"
}

install_ansible() {
    if command -v ansible-pull &>/dev/null; then
        ok "Ansible already installed"
        return
    fi
    info "Installing Ansible..."
    brew install ansible
    ok "Ansible installed"
}

install_galaxy_collections() {
    info "Installing Ansible Galaxy collections..."
    local reqs="$SCRIPT_DIR/requirements.yml"
    if [[ ! -f "$reqs" ]]; then
        local repo_raw="https://raw.githubusercontent.com/${ORCH_OWNER}/${ORCH_NAME}/${REPO_BRANCH}"
        reqs="$(mktemp)"
        trap 'rm -f "$reqs"' RETURN
        if ! curl -fsSL "$repo_raw/requirements.yml" -o "$reqs"; then
            error "Failed to download requirements.yml from $repo_raw"
            exit 1
        fi
    fi
    ansible-galaxy collection install -r "$reqs" --upgrade
    ok "Collections installed"
}

# GitHub auth MUST complete before layers are cloned. Uses the gh device flow
# (browser) and uploads an SSH key so subsequent SSH clones of layers and
# repositories work without prompts.
#
# The readiness probe is an actual SSH operation, not `gh auth status`. The
# latter only proves an API token exists — it says nothing about an SSH key
# being uploaded or port 22 being reachable. A machine authenticated with
# `--git-protocol https`, or on a token-only login, passes `gh auth status` and
# then dies `Permission denied (publickey)` inside clone_layers under `set -e`.
# Probe the transport you are about to use.
github_ssh_ready() {
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new" \
        git ls-remote "$REPO_URL" HEAD &>/dev/null
}

ensure_gh_auth() {
    if github_ssh_ready; then
        ok "GitHub SSH access confirmed"
        return
    fi
    if gh auth status &>/dev/null; then
        warn "GitHub CLI is authenticated, but SSH to github.com does not work."
        warn "That usually means no SSH key is uploaded, or port 22 is blocked here."
        info "Re-running the login flow to add an SSH key..."
    else
        info "GitHub authentication is required to clone content layers over SSH."
        info "A browser device-code flow will open and an SSH key will be uploaded."
    fi
    if ! gh auth login --hostname github.com --git-protocol ssh --web; then
        error "GitHub authentication failed. Re-run bootstrap once authenticated."
        exit 1
    fi
    if ! github_ssh_ready; then
        error "Still cannot reach ${REPO_URL} over SSH after authenticating."
        error "Check that an SSH key is uploaded (gh ssh-key list) and that port 22"
        error "is not blocked on this network."
        exit 1
    fi
    ok "GitHub authenticated and SSH access confirmed"
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Layer selection & fetch
# ═════════════════════════════════════════════════════════════════════════════

show_layers() {
    if [[ -f "$LAYERS_FILE" ]] && [[ "$(yq -r '.layers | length' "$LAYERS_FILE")" -gt 0 ]]; then
        yq -r '.layers | sort_by(.priority) | .[] | "    • \(.name) (priority \(.priority)) → \(.repo)"' "$LAYERS_FILE"
    else
        echo "    (none)"
    fi
}

# Interactively define/modify the layer manifest, persisted to layers.yml.
manage_layers() {
    require_tty
    mkdir -p "$CONFIG_DIR"
    echo
    info "Content layers — pluggable repos that supply capabilities, vars, and files."
    echo "  Current manifest:"
    show_layers
    echo

    if [[ -f "$LAYERS_FILE" ]] && [[ "$(yq -r '.layers | length' "$LAYERS_FILE")" -gt 0 ]]; then
        if ! ask_yn "Reconfigure layers?" "n"; then
            ok "Keeping existing layer manifest"
            return
        fi
    fi

    local tmp; tmp="$(mktemp)"
    echo "---" > "$tmp"
    echo "# Content-layer manifest for computer-setup. Managed by bootstrap.sh." >> "$tmp"
    echo "layers:" >> "$tmp"

    local added=0 name repo prio
    while true; do
        if [[ $added -eq 0 ]]; then
            ask_yn "Add a content layer?" "y" || break
        else
            ask_yn "Add another layer?" "n" || break
        fi

        while true; do
            read -rp "  Layer name (e.g. public, personal, work): " name
            [[ -n "$name" ]] && break
            warn "  Name cannot be empty"
        done
        while true; do
            read -rp "  Git repo URL (git@ preferred; GitHub HTTPS is converted to SSH): " repo
            [[ -n "$repo" ]] && break
            warn "  Repo URL cannot be empty"
        done
        read -rp "  Priority (higher wins on scalar conflicts) [$(( (added + 1) * 10 ))]: " prio
        prio="${prio:-$(( (added + 1) * 10 ))}"

        {
            echo "  - name: $(yaml_quote "$name")"
            echo "    repo: $(yaml_quote "$repo")"
            echo "    priority: ${prio}"
        } >> "$tmp"
        added=$((added + 1))
    done

    if [[ $added -gt 0 ]]; then
        mv "$tmp" "$LAYERS_FILE"
        chmod 600 "$LAYERS_FILE"
        ok "Wrote layer manifest ($added layer(s)) to ${LAYERS_FILE}"
    else
        rm -f "$tmp"
        printf -- "---\nlayers: []\n" > "$LAYERS_FILE"
        warn "No layers defined — orchestrator will run on safe empty defaults."
    fi
    echo
    info "Active layers:"
    show_layers
}

# Clone/update each layer into the stable layer cache.
clone_layers() {
    [[ ! -f "$LAYERS_FILE" ]] && return
    if [[ ! -x "$LAYER_SYNC_SCRIPT" ]]; then
        local repo_raw="https://raw.githubusercontent.com/${ORCH_OWNER}/${ORCH_NAME}/${REPO_BRANCH}"
        LAYER_SYNC_SCRIPT="$(mktemp)"
        trap 'rm -f "$LAYER_SYNC_SCRIPT"' RETURN
        curl -fsSL "$repo_raw/scripts/computer-setup-layers" -o "$LAYER_SYNC_SCRIPT"
        chmod +x "$LAYER_SYNC_SCRIPT"
    fi

    "$LAYER_SYNC_SCRIPT" sync \
        --manifest "$LAYERS_FILE" \
        --cache "$LAYER_CACHE" \
        --schema-version "$SCHEMA_VERSION_MAX"
    ok "All layers fetched to ${LAYER_CACHE}"
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Build preferences
# ═════════════════════════════════════════════════════════════════════════════

# Merged capabilities across all layers as TSV rows:
#   id desc type packages requires_vscode
# Layers are processed in DESCENDING priority so the highest-priority definition
# of any given id wins; each id appears once (union, dedup by id). The `id` is
# the capability token written to ~/.mac-prefs.yml as a selection.
load_capabilities() {
    MERGED_CAPABILITIES_FILE="$(mktemp)"

    if [[ ! -f "$LAYERS_FILE" ]]; then
        warn "No layer manifest — no capabilities offered."
        return
    fi

    local seen=" " order name cat
    order="$(yq -r '.layers | sort_by(.priority) | reverse | .[].name' "$LAYERS_FILE" 2>/dev/null || true)"
    for name in $order; do
        cat="$LAYER_CACHE/$name/capabilities.yml"
        [[ -f "$cat" ]] || continue
        if ! yq '.' "$cat" >/dev/null 2>&1; then
            warn "Layer '$name' has an invalid capabilities.yml — skipping it."
            continue
        fi
        while IFS=$'\t' read -r id desc type pkgs req_vscode; do
            [[ -z "$id" ]] && continue
            [[ "$seen" == *" $id "* ]] && continue
            seen="${seen}${id} "
            printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$desc" "$type" "$pkgs" "$req_vscode" >> "$MERGED_CAPABILITIES_FILE"
        done < <(yq -r '.capabilities[]? | [.id, .desc, .type, (.packages // ""), (.requires_vscode // false)] | @tsv' "$cat")
    done

    local count
    count="$(wc -l < "$MERGED_CAPABILITIES_FILE" | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
        warn "No capabilities declared by any layer — no optional tools to offer."
    else
        ok "Capabilities: ${count} optional item(s) across layers"
    fi
}

# Merged questions across all layers as TSV rows:
#   id type prompt default options
# `options` is a comma-separated list of option values (empty for non-select).
# Same merge rule as capabilities: descending priority, union by id, first wins.
#
# A question is a single-select or free-text decision the MACHINE makes. The
# capability menu can only express independent yes/no, so anything "pick one"
# (which editor) had no representation at all before this.
load_questions() {
    MERGED_QUESTIONS_FILE="$(mktemp)"

    [[ ! -f "$LAYERS_FILE" ]] && return

    local seen=" " order name qf
    order="$(yq -r '.layers | sort_by(.priority) | reverse | .[].name' "$LAYERS_FILE" 2>/dev/null || true)"
    for name in $order; do
        qf="$LAYER_CACHE/$name/questions.yml"
        [[ -f "$qf" ]] || continue
        if ! yq '.' "$qf" >/dev/null 2>&1; then
            warn "Layer '$name' has an invalid questions.yml — skipping it."
            continue
        fi
        while IFS=$'\t' read -r id type prompt default options; do
            [[ -z "$id" ]] && continue
            [[ "$seen" == *" $id "* ]] && continue
            seen="${seen}${id} "
            printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$type" "$prompt" "$default" "$options" \
                >> "$MERGED_QUESTIONS_FILE"
        done < <(yq -r '.questions[]? | [.id, .type, (.desc // .prompt // .id), (.default // ""),
                        ([.options[]?.value] | join(","))] | @tsv' "$qf")
    done

    local count
    count="$(wc -l < "$MERGED_QUESTIONS_FILE" | tr -d ' ')"
    [[ "$count" -gt 0 ]] && ok "Questions: ${count} decision(s) across layers"
}

# ─── Prior selections (re-run friendliness) ──────────────────────────────────
PRIOR_SELECTED_IDS=" "
PRIOR_NAME=""
PRIOR_EMAIL=""
HAS_PRIOR_PREFS=false

is_prior_selected() {
    [[ "$PRIOR_SELECTED_IDS" == *" $1 "* ]]
}

load_prior_prefs() {
    [[ ! -f "$PREFS_FILE" ]] && return
    HAS_PRIOR_PREFS=true

    PRIOR_NAME=$(yq -r '.git_user_name // ""' "$PREFS_FILE" 2>/dev/null || echo "")
    PRIOR_EMAIL=$(yq -r '.git_user_email // ""' "$PREFS_FILE" 2>/dev/null || echo "")

    # Selections are just capability ids now — remember them directly.
    local cap
    while IFS= read -r cap; do
        [[ -n "$cap" ]] && PRIOR_SELECTED_IDS="${PRIOR_SELECTED_IDS}${cap} "
    done < <(yq -r '.selected_capabilities[]?' "$PREFS_FILE" 2>/dev/null || true)
}

# Prior answer for one question id, empty when unanswered. Read on demand rather
# than slurped into an array: bash 3.2 has no associative arrays.
#
# The id goes through the environment (`strenv`), not string interpolation: this
# is mikefarah/yq, which has no jq-style `--arg`, and interpolating an id
# straight into the expression would break on any quoting in it.
prior_answer() {
    [[ -f "$PREFS_FILE" ]] || return 0
    CS_ANSWER_KEY="$1" yq -r '.answers[strenv(CS_ANSWER_KEY)] // ""' \
        "$PREFS_FILE" 2>/dev/null || true
}

# ─── Git identity ────────────────────────────────────────────────────────────
gather_git_identity() {
    require_tty
    info "Git identity (used for commits)"
    local default_hint=""
    if [[ -n "$PRIOR_NAME" ]]; then default_hint=" [$PRIOR_NAME]"; fi
    while true; do
        read -rp "  Git user.name${default_hint}: " GIT_NAME
        GIT_NAME="${GIT_NAME:-$PRIOR_NAME}"
        [[ -n "$GIT_NAME" ]] && break
        warn "  Name cannot be empty"
    done

    default_hint=""
    if [[ -n "$PRIOR_EMAIL" ]]; then default_hint=" [$PRIOR_EMAIL]"; fi
    while true; do
        read -rp "  Git user.email${default_hint}: " GIT_EMAIL
        GIT_EMAIL="${GIT_EMAIL:-$PRIOR_EMAIL}"
        [[ "$GIT_EMAIL" == *@* ]] && break
        warn "  Please enter a valid email address"
    done
    echo
}

# ─── Optional tool selection ─────────────────────────────────────────────────
# Records selected capability *ids* only. Packages, config, and gating are all
# derived by the engine from the merged capability registry at apply time.
gather_optional_tools() {
    echo
    # Always defined, including on the early return below, so write_prefs never
    # has to reason about an unset array (bash 3.2 + `set -u` is unforgiving).
    SELECTED_CAPABILITIES=()

    if [[ ! -s "$MERGED_CAPABILITIES_FILE" ]]; then
        return 0
    fi
    if $HAS_PRIOR_PREFS; then
        info "Optional tools — your previous answers are pre-filled (press Enter to keep):"
    else
        info "Optional tools — answer y/n for each:"
        echo "  (Press Enter to skip = no)"
    fi
    echo

    local vscode_available=false
    if command -v code &>/dev/null; then
        vscode_available=true
    fi

    # The list is read on FD 3, not stdin: `ask_yn` in the body reads stdin, and
    # a `done < file` redirect covers the body too — so every prompt would
    # consume the next capability line as its answer.
    local id desc type pkgs requires_vscode default
    while IFS=$'\t' read -r -u 3 id desc type pkgs requires_vscode; do

        if [[ "$requires_vscode" == "true" && "$vscode_available" != true ]]; then
            continue
        fi

        if is_prior_selected "$id"; then default="y"; else default="n"; fi

        if ask_yn "  Enable ${desc}?" "$default"; then
            SELECTED_CAPABILITIES+=("$id")
            # So VS Code extensions offered later this run are prompted too.
            if [[ "$id" == "vscode" ]]; then
                vscode_available=true
            fi
        fi
    done 3< "$MERGED_CAPABILITIES_FILE"

    # A `while` returns its body's last status, which under `set -e` would abort
    # main() after the last prompt but before write_prefs.
    return 0
}

# ─── Questions (single-select / free-text decisions) ─────────────────────────
# Answers are written to the prefs file as `answers:`. The engine turns them into
# play-scope vars via each question's `set_var:` / each option's `set:` payload.
ANSWER_IDS=()
ANSWER_VALUES=()

gather_answers() {
    ANSWER_IDS=()
    ANSWER_VALUES=()
    [[ ! -s "${MERGED_QUESTIONS_FILE:-}" ]] && return 0

    echo
    info "Setup decisions — press Enter to accept the shown default:"
    echo

    local id type prompt default options prior reply
    while IFS=$'\t' read -r -u 3 id type prompt default options; do
        prior="$(prior_answer "$id")"
        [[ -n "$prior" ]] && default="$prior"

        if [[ "$type" == "select" ]]; then
            reply="$(ask_select "$prompt" "$default" "$options")"
        else
            reply="$(ask_text "$prompt" "$default")"
        fi

        ANSWER_IDS+=("$id")
        ANSWER_VALUES+=("$reply")
    done 3< "$MERGED_QUESTIONS_FILE"

    # A `while` returns its body's last status, which under `set -e` would abort
    # main() after the last prompt but before write_prefs.
    return 0
}

# Numbered single-select. Prints the chosen value on stdout, so every prompt it
# writes must go to stderr or it would be captured as part of the answer.
ask_select() {
    local prompt="$1" default="$2" options="$3"
    require_tty
    local -a opts=()
    local IFS=','
    for o in $options; do opts+=("$o"); done
    unset IFS

    if [[ ${#opts[@]} -eq 0 ]]; then
        printf '%s' "$default"
        return 0
    fi

    local i n=1 marker
    echo "  ${prompt}:" >&2
    for i in "${opts[@]}"; do
        marker=" "
        [[ "$i" == "$default" ]] && marker="*"
        echo "    ${marker} ${n}) ${i}" >&2
        n=$((n + 1))
    done

    local reply idx
    while true; do
        read -rp "    Choice [${default}]: " reply
        if [[ -z "$reply" ]]; then
            printf '%s' "$default"
            return 0
        fi
        # Accept either the number or the value itself.
        if [[ "$reply" =~ ^[0-9]+$ ]]; then
            idx=$((reply - 1))
            if [[ $idx -ge 0 && $idx -lt ${#opts[@]} ]]; then
                printf '%s' "${opts[$idx]}"
                return 0
            fi
        else
            for i in "${opts[@]}"; do
                if [[ "$i" == "$reply" ]]; then
                    printf '%s' "$i"
                    return 0
                fi
            done
        fi
        echo "    Not one of the offered options." >&2
    done
}

ask_text() {
    local prompt="$1" default="$2" reply
    require_tty
    read -rp "  ${prompt} [${default}]: " reply
    printf '%s' "${reply:-$default}"
}

# ─── Write preferences file ──────────────────────────────────────────────────
yaml_list() {
    local key="$1"; shift
    echo "${key}:"
    if [[ $# -eq 0 ]]; then
        echo "  []"
    else
        for item in "$@"; do
            echo "  - $(yaml_quote "$item")"
        done
    fi
}

write_prefs() {
    info "Writing preferences to ${PREFS_FILE}"
    {
        echo "---"
        echo "# Generated by bootstrap.sh — $(date +%Y-%m-%d)"
        echo "# Re-run bootstrap.sh to update; prior answers are remembered."
        echo
        echo "git_user_name: $(yaml_quote "$GIT_NAME")"
        echo "git_user_email: $(yaml_quote "$GIT_EMAIL")"
        echo
        echo "# Answers to the layers' questions. The engine turns each into play-scope"
        echo "# vars via the question's set_var / the chosen option's set payload."
        echo "answers:"
        if [[ ${#ANSWER_IDS[@]} -eq 0 ]]; then
            echo "  {}"
        else
            local _i
            for _i in $(seq 0 $((${#ANSWER_IDS[@]} - 1))); do
                echo "  ${ANSWER_IDS[$_i]}: $(yaml_quote "${ANSWER_VALUES[$_i]}")"
            done
        fi
        echo
        echo "# Selection tokens. Packages, config, and gating are derived from the"
        echo "# merged capability registry (the layers' capabilities) at apply time."
        yaml_list selected_capabilities "${SELECTED_CAPABILITIES[@]+"${SELECTED_CAPABILITIES[@]}"}"
    } > "$PREFS_FILE"

    chmod 600 "$PREFS_FILE"
    ok "Preferences saved"
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Run Ansible
# ═════════════════════════════════════════════════════════════════════════════

# Keep GitHub access on SSH. This avoids macOS keychain prompts for HTTPS tokens.
resolve_repo_url() {
    REPO_URL="git@github.com:${ORCH_OWNER}/${ORCH_NAME}.git"
    ok "Using GitHub SSH remote (no keychain prompts)"
}

run_playbook() {
    echo
    info "Running playbook..."
    echo

    local extra_args=(
        -e "@${PREFS_FILE}"
        -e "computer_setup_layer_cache=${LAYER_CACHE}"
        -e "computer_setup_layers_manifest=${LAYERS_FILE}"
        -e "computer_setup_prefs_file=${PREFS_FILE}"
        -e "repo_branch=${REPO_BRANCH}"
    )

    if ask_yn "Preview changes first (dry-run)?"; then
        ansible-pull \
            -U "$REPO_URL" \
            -C "$REPO_BRANCH" \
            "${extra_args[@]}" \
            --check --diff \
            local.yml || warn "Dry-run completed with warnings (some tasks can't be previewed)"
        echo
        if ! ask_yn "Apply these changes for real?"; then
            warn "Aborted — no changes applied"
            exit 0
        fi
    fi

    info "Applying changes..."
    ansible-pull \
        -U "$REPO_URL" \
        -C "$REPO_BRANCH" \
        "${extra_args[@]}" \
        local.yml

    ok "Playbook completed successfully"
}

# ═════════════════════════════════════════════════════════════════════════════
# Main
# ═════════════════════════════════════════════════════════════════════════════
main() {
    reattach_stdin

    echo
    echo "╔══════════════════════════════════════════════╗"
    echo "║   macOS Workstation Setup — orchestrator     ║"
    echo "║   github.com/${ORCH_OWNER}/${ORCH_NAME}"
    echo "╚══════════════════════════════════════════════╝"
    echo

    if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
        error "Unsupported platform: $(uname -s) $(uname -m) — Apple Silicon macOS required."
        exit 1
    fi

    # ── Phase 0 ──────────────────────────────────────────────────────────────
    install_xcode_clt
    install_homebrew
    ensure_prereqs
    install_ansible
    install_galaxy_collections
    ensure_gh_auth

    # ── Phase 1 ──────────────────────────────────────────────────────────────
    manage_layers
    clone_layers

    # ── Phase 2 ──────────────────────────────────────────────────────────────
    load_capabilities
    load_questions
    load_prior_prefs
    if $HAS_PRIOR_PREFS; then
        ok "Found existing prefs at ${PREFS_FILE} — using prior answers as defaults"
        echo
    fi
    gather_git_identity
    gather_answers
    gather_optional_tools
    write_prefs

    # ── Phase 3 ──────────────────────────────────────────────────────────────
    resolve_repo_url
    run_playbook

    echo
    ok "All done! Open a new terminal to pick up shell changes."
    echo
}

# Run the installer only when executed directly. Setting
# COMPUTER_SETUP_BOOTSTRAP_LIB=1 lets tests/bootstrap-prompts.sh source this file
# for its functions — the prompt loop is the one part of bootstrap that `bash -n`
# cannot check, and it is where the interactive bugs live.
if [[ "${COMPUTER_SETUP_BOOTSTRAP_LIB:-0}" != "1" ]]; then
    main "$@"
fi

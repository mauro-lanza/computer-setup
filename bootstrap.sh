#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# computer-setup bootstrap (orchestrator)
#
# Run on a fresh Mac to install prerequisites, define/clone content layers, and
# kick off the Ansible playbook.
#
#   Phase 0  Prerequisites + GitHub auth (no repo access required)
#   Phase 1  Layer selection & fetch (define manifest, clone to plugin cache)
#   Phase 2  Build preferences (merge catalogs → prompts → ~/.mac-prefs.yml)
#   Phase 3  Run Ansible (ansible-pull the orchestrator with merged input)
#
# Usage: curl -fsSL <raw-url>/bootstrap.sh | bash
#    or: ./bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────

# ─── Locations ────────────────────────────────────────────────────────────────
PREFS_FILE="$HOME/.mac-prefs.yml"
CONFIG_DIR="$HOME/.config/computer-setup"
LAYERS_FILE="$CONFIG_DIR/layers.yml"
PLUGIN_CACHE="$HOME/.local/share/computer-setup/plugins"

# Orchestrator repo. Bootstrap authenticates GitHub before cloning layers or
# running ansible-pull, so GitHub repos are accessed over SSH consistently.
ORCH_OWNER="mauro-lanza"
ORCH_NAME="computer-setup"
REPO_URL="git@github.com:${ORCH_OWNER}/${ORCH_NAME}.git"
REPO_BRANCH="${BOOTSTRAP_BRANCH:-main}"

# Highest plugin schema_version this orchestrator understands.
SCHEMA_VERSION_MAX=1

export HOMEBREW_NO_ANALYTICS=1

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

# yq/git/gh are needed before we can read catalogs or clone layers.
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
ensure_gh_auth() {
    if gh auth status &>/dev/null; then
        ok "GitHub CLI already authenticated"
        return
    fi
    info "GitHub authentication is required to clone content layers over SSH."
    info "A browser device-code flow will open and an SSH key will be uploaded."
    if ! gh auth login --hostname github.com --git-protocol ssh --web; then
        error "GitHub authentication failed. Re-run bootstrap once authenticated."
        exit 1
    fi
    ok "GitHub authenticated"
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
    mkdir -p "$CONFIG_DIR"
    echo
    info "Content layers — pluggable repos that supply catalog options, vars, and files."
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

    local added=0 name repo prio priv
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

        if [[ "$repo" == git@* ]]; then priv=true; else priv=false; fi
        if ask_yn "  Private layer?" "$([[ $priv == true ]] && echo y || echo n)"; then
            priv=true
        else
            priv=false
        fi

        {
            echo "  - name: $(yaml_quote "$name")"
            echo "    repo: $(yaml_quote "$repo")"
            echo "    priority: ${prio}"
            echo "    private: ${priv}"
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

# Clone/update each layer into the stable plugin cache.
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
        --cache "$PLUGIN_CACHE" \
        --schema-version "$SCHEMA_VERSION_MAX"
    ok "All layers fetched to ${PLUGIN_CACHE}"
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Build preferences
# ═════════════════════════════════════════════════════════════════════════════

# Merged catalog across all layers as TSV rows:
#   id desc type packages requires_vscode capability
# Layers are processed in DESCENDING priority so the highest-priority definition
# of any given id wins; each id appears once (union, dedup by id). Capability
# defaults to id and is written to ~/.mac-prefs.yml for optional role gates.
load_catalog() {
    MERGED_CATALOG_FILE="$(mktemp)"

    if [[ ! -f "$LAYERS_FILE" ]]; then
        warn "No layer manifest — catalog is empty (no optional tools offered)."
        return
    fi

    local seen=" " order name cat
    order="$(yq -r '.layers | sort_by(.priority) | reverse | .[].name' "$LAYERS_FILE" 2>/dev/null || true)"
    for name in $order; do
        cat="$PLUGIN_CACHE/$name/catalog.yml"
        [[ -f "$cat" ]] || continue
        if ! yq '.' "$cat" >/dev/null 2>&1; then
            warn "Layer '$name' has an invalid catalog.yml — skipping it."
            continue
        fi
        while IFS=$'\t' read -r id desc type pkgs req_vscode capability; do
            [[ -z "$id" ]] && continue
            [[ "$seen" == *" $id "* ]] && continue
            seen="${seen}${id} "
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$desc" "$type" "$pkgs" "$req_vscode" "${capability:-$id}" >> "$MERGED_CATALOG_FILE"
        done < <(yq -r '.catalog[]? | [.id, .desc, .type, .packages, (.requires_vscode // false), (.capability // .id)] | @tsv' "$cat")
    done

    local count
    count="$(wc -l < "$MERGED_CATALOG_FILE" | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
        warn "Merged catalog is empty — no optional tools to offer."
    else
        ok "Merged catalog: ${count} optional item(s) across layers"
    fi
}

# ─── Prior selections (re-run friendliness) ──────────────────────────────────
PRIOR_SELECTED_IDS=" "
PRIOR_NAME=""
PRIOR_EMAIL=""
PRIOR_USE_DBT=false
HAS_PRIOR_PREFS=false
USE_DBT=false

is_prior_selected() {
    [[ "$PRIOR_SELECTED_IDS" == *" $1 "* ]]
}

load_prior_prefs() {
    [[ ! -f "$PREFS_FILE" ]] && return
    HAS_PRIOR_PREFS=true

    PRIOR_NAME=$(yq -r '.git_user_name // ""' "$PREFS_FILE" 2>/dev/null || echo "")
    PRIOR_EMAIL=$(yq -r '.git_user_email // ""' "$PREFS_FILE" 2>/dev/null || echo "")
    PRIOR_USE_DBT=$(yq -r '.use_dbt // false' "$PREFS_FILE" 2>/dev/null || echo false)

    local prior_formulae prior_casks prior_vscode
    prior_formulae=$(yq -r '.prefs.optional_formulae[]?' "$PREFS_FILE" 2>/dev/null || true)
    prior_casks=$(yq -r '.prefs.optional_casks[]?' "$PREFS_FILE" 2>/dev/null || true)
    prior_vscode=$(yq -r '.prefs.optional_vscode_extensions[]?' "$PREFS_FILE" 2>/dev/null || true)

    local id desc type pkgs requires_vscode capability source_list pkg
    while IFS=$'\t' read -r id desc type pkgs requires_vscode capability; do
        case "$type" in
            formula) source_list="$prior_formulae" ;;
            cask)    source_list="$prior_casks" ;;
            vscode)  source_list="$prior_vscode" ;;
            *)       continue ;;
        esac
        for pkg in $pkgs; do
            if grep -qFx "$pkg" <<< "$source_list"; then
                PRIOR_SELECTED_IDS="${PRIOR_SELECTED_IDS}${id} "
                break
            fi
        done
    done < "$MERGED_CATALOG_FILE"
}

# ─── Git identity ────────────────────────────────────────────────────────────
gather_git_identity() {
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
gather_optional_tools() {
    echo
    if [[ ! -s "$MERGED_CATALOG_FILE" ]]; then
        return
    fi
    if $HAS_PRIOR_PREFS; then
        info "Optional tools — your previous answers are pre-filled (press Enter to keep):"
    else
        info "Optional tools — answer y/n for each:"
        echo "  (Press Enter to skip = no)"
    fi
    echo

    SELECTED_FORMULAE=()
    SELECTED_CASKS=()
    SELECTED_VSCODE=()
    SELECTED_CAPABILITIES=()

    local vscode_available=false
    if command -v code &>/dev/null; then
        vscode_available=true
    fi

    local id desc type pkgs requires_vscode capability default pkg
    while IFS=$'\t' read -r id desc type pkgs requires_vscode capability; do

        if [[ "$requires_vscode" == "true" && "$vscode_available" != true ]]; then
            continue
        fi

        if is_prior_selected "$id"; then default="y"; else default="n"; fi

        if ask_yn "  Install ${desc}?" "$default"; then
            SELECTED_CAPABILITIES+=("${capability:-$id}")
            case "$type" in
                formula)
                    for pkg in $pkgs; do SELECTED_FORMULAE+=("$pkg"); done
                    ;;
                cask)
                    for pkg in $pkgs; do SELECTED_CASKS+=("$pkg"); done
                    if [[ "$id" == "vscode" ]]; then vscode_available=true; fi
                    ;;
                vscode)
                    for pkg in $pkgs; do SELECTED_VSCODE+=("$pkg"); done
                    ;;
            esac
        fi
    done < "$MERGED_CATALOG_FILE"
}

# ─── Feature toggles (not tied to a package) ─────────────────────────────────
gather_dbt() {
    echo
    info "Project tooling"
    local default="n"
    [[ "$PRIOR_USE_DBT" == "true" ]] && default="y"
    if ask_yn "  Configure dbt (deploy ~/.dbt/profiles.yml)?" "$default"; then
        USE_DBT=true
    else
        USE_DBT=false
    fi
}

# ─── Write preferences file ──────────────────────────────────────────────────
yaml_list() {
    local key="$1"; shift
    echo "  ${key}:"
    if [[ $# -eq 0 ]]; then
        echo "    []"
    else
        for item in "$@"; do
            echo "    - $(yaml_quote "$item")"
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
        echo "use_dbt: ${USE_DBT}"
        echo
        echo "prefs:"
        yaml_list optional_formulae "${SELECTED_FORMULAE[@]+"${SELECTED_FORMULAE[@]}"}"
        yaml_list optional_casks "${SELECTED_CASKS[@]+"${SELECTED_CASKS[@]}"}"
        yaml_list optional_vscode_extensions "${SELECTED_VSCODE[@]+"${SELECTED_VSCODE[@]}"}"
        yaml_list capabilities "${SELECTED_CAPABILITIES[@]+"${SELECTED_CAPABILITIES[@]}"}"
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
        -e "computer_setup_plugin_cache=${PLUGIN_CACHE}"
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
    load_catalog
    load_prior_prefs
    if $HAS_PRIOR_PREFS; then
        ok "Found existing prefs at ${PREFS_FILE} — using prior answers as defaults"
        echo
    fi
    gather_git_identity
    gather_optional_tools
    gather_dbt
    write_prefs

    # ── Phase 3 ──────────────────────────────────────────────────────────────
    resolve_repo_url
    run_playbook

    echo
    ok "All done! Open a new terminal to pick up shell changes."
    echo
}

main "$@"

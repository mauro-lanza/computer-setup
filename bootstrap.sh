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

# Apple silicon prefix. Asserted in main() and in the playbook, so this is a
# constant rather than a `brew --prefix` call that must run before Homebrew is
# installed. Layers reference it as `{{ homebrew_prefix }}`.
HOMEBREW_PREFIX="/opt/homebrew"

# Orchestrator repo. Bootstrap authenticates GitHub before cloning layers or
# running ansible-pull, so GitHub repos are accessed over SSH consistently.
ORCH_OWNER="mauro-lanza"
ORCH_NAME="computer-setup"
REPO_URL="git@github.com:${ORCH_OWNER}/${ORCH_NAME}.git"
REPO_BRANCH="${BOOTSTRAP_BRANCH:-main}"
# Raw file base, for the two things fetched before any checkout exists
# (requirements.yml, the layer sync helper) and for the re-run hint in
# require_tty. One definition so the hint can never name a URL that 404s.
RAW_BASE="https://raw.githubusercontent.com/${ORCH_OWNER}/${ORCH_NAME}/${REPO_BRANCH}"

# Highest layer schema_version this orchestrator understands.
#
# This duplicates `computer_setup_schema_version` in local.yml and the default
# in scripts/computer-setup-layers. It cannot simply read local.yml: under the
# `curl | bash` install path no checkout exists yet. scripts/check.sh asserts
# all three agree, so a bump that misses one fails the suite rather than
# silently accepting a layer the engine will later reject.
SCHEMA_VERSION_MAX=1

# Field separator for the merged capability/question/preset files.
#
# NOT a tab. Tab is an "IFS whitespace" character, so `IFS=$'\t' read` collapses
# runs of tabs into one: a row with an empty middle field (a `feature`
# capability has no `packages`; a text question has no `options`) silently
# shifts every later column left. ASCII Unit Separator is not whitespace, so
# empty fields survive. yq's @tsv already escapes any literal tab in a value,
# so the translation below is lossless.
FS_U=$'\037'

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
        error "    bash <(curl -fsSL ${RAW_BASE}/bootstrap.sh)"
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
    eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
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
        local repo_raw="$RAW_BASE"
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

# Does the manifest exist and declare at least one layer? Asked at three points
# in the layer-management flow; an empty `layers:` list is not a manifest.
manifest_has_layers() {
    [[ -f "$LAYERS_FILE" ]] || return 1
    [[ "$(yq -r '.layers | length' "$LAYERS_FILE" 2>/dev/null || echo 0)" -gt 0 ]]
}

show_layers() {
    if manifest_has_layers; then
        yq -r '.layers | sort_by(.priority) | .[] | "    • \(.name) (priority \(.priority)) → \(.repo)"' "$LAYERS_FILE"
    else
        echo "    (none)"
    fi
}

# Interactively define/modify the layer manifest, persisted to layers.yml.
manage_layers() {
    # A non-interactive run cannot answer "which layers?". An existing manifest
    # is used as-is; a missing one is fatal rather than a silently empty setup.
    if [[ -n "$ANSWERS_FILE" ]]; then
        if manifest_has_layers; then
            ok "Using existing layer manifest (${LAYERS_FILE})"
            return
        fi
        error "--answers needs an existing layer manifest at ${LAYERS_FILE}."
        error "Run bootstrap.sh once interactively to configure layers."
        exit 1
    fi

    require_tty
    mkdir -p "$CONFIG_DIR"
    echo
    info "Content layers — pluggable repos that supply capabilities, vars, and files."
    echo "  Current manifest:"
    show_layers
    echo

    if manifest_has_layers; then
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
            read -rp "  Git repo URL (SSH; 'github.com:owner/repo' is completed to git@): " repo
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
        local repo_raw="$RAW_BASE"
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

# ─── Layer merge primitive ───────────────────────────────────────────────────
# Merge one filename across every layer into a single FS_U-delimited file.
#
# Layers are visited in DESCENDING priority and rows are deduped on their first
# field, so the highest-priority layer's definition of any id wins wholesale.
# That mirrors the engine's union-by-id merge (roles/computer_setup/tasks/
# merge_layer_{capabilities,questions}.yml), which sorts ASCENDING and lets the
# last write win — the same result reached from the other end.
#
# The row is written through verbatim rather than being split into named fields
# and reassembled: the caller's yq projection is the single definition of the
# column layout, so adding a column means editing one string, not two.
merge_layer_file() {
    local filename="$1" projection="$2" outfile="$3"
    local seen=" " order name src line id

    [[ -f "$LAYERS_FILE" ]] || return 0

    order="$(yq -r '.layers | sort_by(.priority) | reverse | .[].name' "$LAYERS_FILE" 2>/dev/null || true)"
    for name in $order; do
        src="$LAYER_CACHE/$name/$filename"
        [[ -f "$src" ]] || continue
        # yq -r on a malformed file would emit nothing and succeed, so the layer
        # would be silently ignored. Report it instead.
        if ! yq '.' "$src" >/dev/null 2>&1; then
            warn "Layer '$name' has an invalid $filename — skipping it."
            continue
        fi
        while IFS= read -r line; do
            id="${line%%"$FS_U"*}"
            [[ -z "$id" ]] && continue
            [[ "$seen" == *" $id "* ]] && continue
            seen="${seen}${id} "
            printf '%s\n' "$line" >> "$outfile"
        done < <(yq -r "$projection" "$src" | tr '\t' "$FS_U")
    done
    return 0
}

# Number of rows a merge produced.
merged_count() {
    [[ -s "$1" ]] || { printf '0'; return 0; }
    wc -l < "$1" | tr -d ' '
}

# Merged capabilities. Columns:
#   id  desc  type  packages  requires  adopt_if_present
# `id` is the capability token written to ~/.mac-prefs.yml as a selection.
load_capabilities() {
    MERGED_CAPABILITIES_FILE="$(mktemp)"

    if [[ ! -f "$LAYERS_FILE" ]]; then
        warn "No layer manifest — no capabilities offered."
        return 0
    fi

    merge_layer_file capabilities.yml \
        '.capabilities[]? | [.id, .desc, .type, (.packages // ""), (.requires // ""),
                             (.adopt_if_present // "")] | @tsv' \
        "$MERGED_CAPABILITIES_FILE"

    local count
    count="$(merged_count "$MERGED_CAPABILITIES_FILE")"
    if [[ "$count" -eq 0 ]]; then
        warn "No capabilities declared by any layer — no optional tools to offer."
    else
        ok "Capabilities: ${count} optional item(s) across layers"
    fi
    return 0
}

# Merged questions. Columns:
#   id  type  prompt  default  options(csv)  validate
# `options` is a comma-separated list of option values (empty for non-select).
# `validate` is an optional ERE a text/path answer must match (empty for none).
#
# A question is a single-select or free-text decision the MACHINE makes. The
# capability menu expresses only independent yes/no, so anything "pick one"
# (which editor) is a question, not a capability.
load_questions() {
    MERGED_QUESTIONS_FILE="$(mktemp)"

    merge_layer_file questions.yml \
        '.questions[]? | [.id, .type, (.desc // .id), (.default // ""),
                          ([.options[]?.value] | join(",")), (.validate // "")] | @tsv' \
        "$MERGED_QUESTIONS_FILE"

    local count
    count="$(merged_count "$MERGED_QUESTIONS_FILE")"
    [[ "$count" -gt 0 ]] && ok "Questions: ${count} decision(s) across layers"
    # A bare [[ ]] as the last statement returns 1 when no layer declares a
    # question, which under `set -e` would abort main().
    return 0
}

# ─── Presets ─────────────────────────────────────────────────────────────────
# A preset is a named bundle of answers + capability selections. It is a PURE
# PREFILL: it only supplies the defaults the prompts start from, and is never
# recorded in the prefs file. A machine set up from a preset is indistinguishable
# from one answered by hand, so a preset can be edited later without silently
# reconfiguring machines that once used it.
#
# This exists because "every decision is re-answerable" and "bootstrap asks 50+
# questions one at a time" are the same statement. A preset plus "review? [y/N]"
# keeps the first true without making a fresh machine unbearable.
PRESET_ID=""
PRESET_CAPS=" "
REVIEW_ANSWERS=true

# Merged presets. Columns:
#   id  desc  capabilities(csv)  answers(k=v,csv)
load_presets() {
    MERGED_PRESETS_FILE="$(mktemp)"

    merge_layer_file presets.yml \
        '.presets[]? | [.id, (.desc // .id),
                        ([.capabilities[]?] | join(",")),
                        ((.answers // {}) | to_entries
                         | map(.key + "=" + (.value | tostring)) | join(","))] | @tsv' \
        "$MERGED_PRESETS_FILE"
    return 0
}

# The preset's answer for one question id, empty when the preset does not set it.
preset_answer() {
    [[ -z "$PRESET_ID" ]] && return 0
    awk -F'\037' -v p="$PRESET_ID" -v k="$1" '
        $1 == p {
            n = split($4, kv, ",")
            for (i = 1; i <= n; i++) {
                eq = index(kv[i], "=")
                if (eq > 0 && substr(kv[i], 1, eq - 1) == k) {
                    print substr(kv[i], eq + 1)
                    exit
                }
            }
        }' "$MERGED_PRESETS_FILE" 2>/dev/null || true
}

choose_preset() {
    [[ ! -s "${MERGED_PRESETS_FILE:-}" ]] && return 0
    require_tty

    echo
    info "Presets — a starting point you can then review:"
    local -a ids=()
    local id desc caps ans n=1
    while IFS="$FS_U" read -r id desc caps ans; do
        ids+=("$id")
        echo "    ${n}) ${desc}"
        n=$((n + 1))
    done < "$MERGED_PRESETS_FILE"
    echo "    ${n}) Custom — start from $($HAS_PRIOR_PREFS && echo "your previous answers" || echo "the defaults")"
    echo

    local reply idx
    while true; do
        read -rp "  Preset [${n}]: " reply
        reply="${reply:-$n}"
        if [[ "$reply" =~ ^[0-9]+$ ]]; then
            idx=$((reply - 1))
            if [[ $idx -ge 0 && $idx -lt ${#ids[@]} ]]; then
                PRESET_ID="${ids[$idx]}"
                break
            elif [[ $idx -eq ${#ids[@]} ]]; then
                PRESET_ID=""
                break
            fi
        fi
        echo "    Not one of the offered options." >&2
    done

    if [[ -n "$PRESET_ID" ]]; then
        PRESET_CAPS=" $(awk -F'\037' -v p="$PRESET_ID" '$1==p{gsub(/,/," ",$3); print $3}' \
            "$MERGED_PRESETS_FILE") "
        ok "Preset '${PRESET_ID}' selected"
        # Reviewing is opt-IN: the whole point of picking a preset is not being
        # asked 50 questions. Answering yes walks the same prompts, prefilled.
        if ask_yn "  Review every individual answer?" "n"; then
            REVIEW_ANSWERS=true
        else
            REVIEW_ANSWERS=false
        fi
    fi
    echo
}

# ─── Non-interactive answers (zero-touch rebuild) ────────────────────────────
# `bootstrap.sh --answers <file>` skips every prompt and takes the whole
# preference set from a YAML file with the same shape bootstrap writes:
#
#   answers: {editor: zed, git-email: me@example.com, ...}
#   selected_capabilities: [nvm, ...]
#
# That makes "rebuild this machine" one command, which is what actually makes
# every-decision-is-a-prompt survivable. The file is the same shape write_prefs
# emits, so ~/.mac-prefs.yml from an old machine works directly.
#
# Nothing here is required: an answer a layer no longer asks for is dropped by
# the engine, and a question the file does not answer falls back to the default
# its layer declares. So a partial file is valid, and an empty one means "take
# every layer default".
ANSWERS_FILE=""

load_answers_file() {
    local f="$1"
    # Existence is already checked in parse_args, so the run fails before any
    # prerequisite is installed. Only validity is re-checked here.
    if ! yq '.' "$f" >/dev/null 2>&1; then
        error "Answers file is not valid YAML: $f"
        exit 1
    fi

    ANSWER_IDS=(); ANSWER_VALUES=()
    local k v
    while IFS="$FS_U" read -r k v; do
        [[ -z "$k" ]] && continue
        ANSWER_IDS+=("$k")
        ANSWER_VALUES+=("$v")
    done < <(yq -r '(.answers // {}) | to_entries | .[] | [.key, (.value | tostring)] | @tsv' "$f" | tr '\t' "$FS_U")

    SELECTED_CAPABILITIES=()
    local cap
    while IFS= read -r cap; do
        [[ -n "$cap" ]] && SELECTED_CAPABILITIES+=("$cap")
    done < <(yq -r '.selected_capabilities[]?' "$f")

    ok "Answers loaded from ${f} (${#ANSWER_IDS[@]} answer(s), ${#SELECTED_CAPABILITIES[@]} capability selection(s))"
}

usage() {
    cat <<USAGE
Usage: bootstrap.sh [--answers <file>] [--help]

  --answers <file>  Take every preference from <file> and skip all prompts.
                    Same shape as ~/.mac-prefs.yml, so a previous machine's
                    prefs file can be used directly.
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --answers)
                ANSWERS_FILE="${2:-}"
                if [[ -z "$ANSWERS_FILE" ]]; then
                    error "--answers requires a file path"
                    exit 1
                fi
                shift 2
                ;;
            --answers=*)
                ANSWERS_FILE="${1#*=}"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Fail on a bad path HERE, not in Phase 2 — otherwise a typo installs Xcode
    # CLT, Homebrew, Ansible and clones every layer before reporting it.
    if [[ -n "$ANSWERS_FILE" && ! -f "$ANSWERS_FILE" ]]; then
        error "No such answers file: $ANSWERS_FILE"
        exit 1
    fi
}

# ─── Prior selections (re-run friendliness) ──────────────────────────────────
PRIOR_SELECTED_IDS=" "
HAS_PRIOR_PREFS=false

is_prior_selected() {
    [[ "$PRIOR_SELECTED_IDS" == *" $1 "* ]]
}

load_prior_prefs() {
    [[ ! -f "$PREFS_FILE" ]] && return
    HAS_PRIOR_PREFS=true

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


# Is a capability already present on this machine? Uses the capability's own
# `adopt_if_present` path — layer data — so bootstrap names no tool.
#
# Reads the MERGED registry, not the raw per-layer files: the merge already
# resolved which layer's definition of an id wins. Globbing the cache directly
# would resolve by directory name instead, so two layers defining the same id
# with different probes would disagree with the engine.
#
# Only the two path roots a probe cannot avoid are expanded here (`home_dir`,
# `homebrew_prefix`); the engine templates every other value at apply time. Keep
# this list in step with the `adopt_if_present` contract in docs/architecture.md.
cap_is_present() {
    local id="$1" probe
    [[ -s "${MERGED_CAPABILITIES_FILE:-}" ]] || return 1
    probe="$(awk -F"$FS_U" -v want="$id" '$1 == want { print $6; exit }' \
        "$MERGED_CAPABILITIES_FILE")"
    [[ -z "$probe" ]] && return 1
    # Collapse any inner whitespace first ({{ home_dir }}, {{home_dir}}, and
    # {{  home_dir  }} are one token), so each root needs a single rule below.
    probe="$(printf '%s' "$probe" |
        sed -E 's/\{\{[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\}\}/{{\1}}/g')"
    probe="${probe//\{\{home_dir\}\}/$HOME}"
    probe="${probe//\{\{homebrew_prefix\}\}/$HOMEBREW_PREFIX}"
    [[ -e "$probe" ]]
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

    # Capabilities satisfied so far this run: anything already selected above,
    # plus anything adopted (already installed) — see cap_is_present. Replaces a
    # hardcoded `command -v code` probe and the vscode-only `requires_vscode`.
    local satisfied=" "

    # The list is read on FD 3, not stdin: `ask_yn` in the body reads stdin, and
    # a `done < file` redirect covers the body too — so every prompt would
    # consume the next capability line as its answer.
    # `adopt` is read but unused here: `read` assigns the remainder of the line
    # to its last variable, so omitting it would fold adopt_if_present into
    # `requires`. cap_is_present reads that column from the file directly.
    local id desc type pkgs requires adopt default
    while IFS="$FS_U" read -r -u 3 id desc type pkgs requires adopt; do

        # A capability may require another. It is offered only when that one is
        # satisfied — selected earlier in this run, or already present. Order in
        # the merged list therefore matters, exactly as it did before.
        if [[ -n "$requires" && "$satisfied" != *" $requires "* ]]; then
            if ! cap_is_present "$requires"; then
                continue
            fi
            satisfied="${satisfied}${requires} "
        fi

        # With a preset chosen, ITS capability list is the default set — not the
        # machine's prior selections, which the preset is explicitly replacing.
        if [[ -n "$PRESET_ID" ]]; then
            if [[ "$PRESET_CAPS" == *" $id "* ]]; then default="y"; else default="n"; fi
        elif is_prior_selected "$id"; then
            default="y"
        else
            default="n"
        fi

        if ! $REVIEW_ANSWERS; then
            if [[ "$default" == "y" ]]; then
                SELECTED_CAPABILITIES+=("$id")
                satisfied="${satisfied}${id} "
            fi
            continue
        fi

        if ask_yn "  Enable ${desc}?" "$default"; then
            SELECTED_CAPABILITIES+=("$id")
            # So capabilities requiring this one are offered later in this run.
            satisfied="${satisfied}${id} "
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

    local id type prompt default options validate prior preset reply
    while IFS="$FS_U" read -r -u 3 id type prompt default options validate; do
        # Precedence: the question's declared default, then this machine's prior
        # answer, then the preset. The preset wins because choosing one this run
        # is a deliberate "start from that" — otherwise picking a preset on a
        # re-run would appear to do nothing.
        prior="$(prior_answer "$id")"
        [[ -n "$prior" ]] && default="$prior"
        preset="$(preset_answer "$id")"
        [[ -n "$preset" ]] && default="$preset"

        if ! $REVIEW_ANSWERS; then
            ANSWER_IDS+=("$id")
            ANSWER_VALUES+=("$default")
            continue
        fi

        case "$type" in
            select)
                reply="$(ask_select "$prompt" "$default" "$options")"
                ;;
            bool)
                # Stored as the strings true/false so the engine's `| bool`
                # filter reads them, and so the prefs file stays valid YAML.
                if [[ "$default" == "true" ]]; then
                    ask_yn "  ${prompt}?" "y" && reply=true || reply=false
                else
                    ask_yn "  ${prompt}?" "n" && reply=true || reply=false
                fi
                ;;
            *)
                reply="$(ask_text "$prompt" "$default" "$validate")"
                ;;
        esac

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

# Free-text prompt. `validate` (optional) is an ERE the answer must match; the
# layer that declares the question owns the pattern, so bootstrap enforces a
# shape without knowing what the value means.
ask_text() {
    local prompt="$1" default="$2" validate="${3:-}" reply
    require_tty
    while true; do
        read -rp "  ${prompt} [${default}]: " reply
        reply="${reply:-$default}"
        [[ -z "$validate" ]] && break
        [[ "$reply" =~ $validate ]] && break
        # Prompts go to stderr: this function's stdout IS the answer.
        warn "  '${reply}' does not match the expected format (${validate})" >&2
    done
    printf '%s' "$reply"
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

    if [[ -n "$ANSWERS_FILE" ]]; then
        info "Non-interactive run — applying without a dry-run prompt."
    elif ask_yn "Preview changes first (dry-run)?"; then
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
# The three merge files live for the whole run (the prompt loops read them on
# FD 3), so they cannot be cleaned per-function. Remove them on any exit path.
cleanup_merge_files() {
    rm -f "${MERGED_CAPABILITIES_FILE:-}" \
          "${MERGED_QUESTIONS_FILE:-}" \
          "${MERGED_PRESETS_FILE:-}"
}

main() {
    trap cleanup_merge_files EXIT
    parse_args "$@"

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
    load_presets
    load_prior_prefs
    if [[ -n "$ANSWERS_FILE" ]]; then
        load_answers_file "$ANSWERS_FILE"
    else
        if $HAS_PRIOR_PREFS; then
            ok "Found existing prefs at ${PREFS_FILE} — using prior answers as defaults"
            echo
        fi
        choose_preset
        gather_answers
        gather_optional_tools
    fi
    write_prefs

    # ── Phase 3 ──────────────────────────────────────────────────────────────
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

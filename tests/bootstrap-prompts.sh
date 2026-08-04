#!/bin/bash
# Regression tests for bootstrap.sh's interactive prompt path.
#
# WHY THIS EXISTS
# ---------------
# Everything else in scripts/check.sh validates static artefacts: `bash -n`
# parses bootstrap.sh, ansible-playbook syntax-checks the roles, the contract
# playbook exercises the merge. None of that executes a single prompt — so the
# one code path that ONLY ever runs on a fresh machine had zero coverage, and
# shipped two bugs that made a from-scratch install silently useless:
#
#   1. The capability loop read its list from stdin (`done < "$FILE"`), while
#      ask_yn's `read` also read from stdin. Every prompt ate the NEXT capability
#      line as its answer: half the capabilities were skipped, none were ever
#      selected, and bash suppressed the prompt text entirely (it only renders a
#      `read -p` prompt when stdin is a terminal). Result: `selected_capabilities: []`
#      on every fresh machine, with no error and no visible symptom.
#
#   2. The loop body ended in `[[ "$id" == "vscode" ]] && ...`, so when the last
#      capability was selected and wasn't literally `vscode`, the while loop —
#      and therefore the function — returned 1. Under `set -e` that aborts
#      bootstrap AFTER the final prompt but BEFORE write_prefs, leaving no
#      preferences file at all.
#
# Both are invisible to a human running bootstrap (it looks like it worked) and
# both are trivially caught by driving the loop with a scripted answer file.
# Every assertion below maps to a specific way the selection path can rot.

set -uo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# Source bootstrap.sh for its functions without running the installer.
export COMPUTER_SETUP_BOOTSTRAP_LIB=1
# shellcheck source=../bootstrap.sh
source "$REPO_ROOT/bootstrap.sh"
# bootstrap.sh sets -e; the harness needs to inspect failures rather than die.
set +e

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { printf '  ok  %s\n' "$1"; }
fail() { printf '  FAIL %s\n     %s\n' "$1" "$2" >&2; FAILURES=$((FAILURES + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "expected [$expected], got [$actual]"
    fi
}

# A capability list in the same TSV shape load_capabilities produces:
#   id \t desc \t type \t packages \t requires_vscode
# `vscode` sits BEFORE `ext-pack` so the in-run "VS Code was just selected"
# unlock is exercised, and `zzz-last` is deliberately final and not named
# `vscode` — that is the exact shape that triggered bug 2.
make_caps() {
    printf 'alpha\tAlpha tool\tformula\talpha\tfalse\n'
    printf 'vscode\tVisual Studio Code\tcask\tvisual-studio-code\tfalse\n'
    printf 'ext-pack\tEditor extension pack\tvscode\tsome.extension\ttrue\n'
    printf 'zzz-last\tLast capability\tformula\tzzz\tfalse\n'
}

# Drive gather_optional_tools with a scripted answer file and echo the result.
#   $1 answers file, $2 prior-selection string, $3 "true"/"false" HAS_PRIOR_PREFS
# Prints: "<rc>|<space separated selections>"
run_prompts() {
    local answers="$1" prior="${2:- }" has_prior="${3:-false}"
    (
        PRIOR_SELECTED_IDS="$prior"
        HAS_PRIOR_PREFS="$has_prior"
        INTERACTIVE=1
        MERGED_CAPABILITIES_FILE="$WORK/caps.tsv"
        SELECTED_CAPABILITIES=()
        # Answers arrive on the function's stdin. The capability list must come
        # from somewhere else entirely (FD 3) — that separation IS the fix, so
        # feeding answers this way is what makes bug 1 detectable.
        gather_optional_tools < "$answers" >/dev/null 2>&1
        printf '%s|%s\n' "$?" "${SELECTED_CAPABILITIES[*]+${SELECTED_CAPABILITIES[*]}}"
    )
}

echo "==> bootstrap prompt loop"
make_caps > "$WORK/caps.tsv"
TOTAL=4

# ── 1. Answering yes must select EVERY capability ────────────────────────────
# The regression signature of bug 1 is 0 selections from an all-yes run.
printf 'y\ny\ny\ny\ny\ny\n' > "$WORK/all-yes"
result="$(run_prompts "$WORK/all-yes")"
rc="${result%%|*}"; sel="${result#*|}"
count=$(printf '%s' "$sel" | wc -w | tr -d ' ')
assert_eq "answering yes selects every capability ($TOTAL)" "$TOTAL" "$count"
assert_eq "  selections are the capability ids, in catalog order" \
    "alpha vscode ext-pack zzz-last" "$sel"

# ── 2. The function must return success ──────────────────────────────────────
# Bug 2: a trailing failed test made the loop return 1, which `set -e` turns
# into "bootstrap exits before write_prefs" — no prefs file, no error message.
assert_eq "returns 0 after selecting a non-vscode capability last" "0" "$rc"

# ── 3. Answering no must select nothing (and still return success) ───────────
printf 'n\nn\nn\nn\nn\nn\n' > "$WORK/all-no"
result="$(run_prompts "$WORK/all-no")"
assert_eq "answering no selects nothing" "0|" "$result"

# ── 4. Bare Enter defaults to no on a first run ──────────────────────────────
printf '\n\n\n\n\n\n' > "$WORK/all-enter"
result="$(run_prompts "$WORK/all-enter")"
assert_eq "Enter defaults to no when there are no prior prefs" "0|" "$result"

# ── 5. Bare Enter keeps prior answers on a re-run ────────────────────────────
# Before the fix this path did not merely mis-prompt, it silently DISCARDED a
# returning user's entire prior selection set.
result="$(run_prompts "$WORK/all-enter" " alpha zzz-last " true)"
assert_eq "Enter keeps prior selections on re-run" "0|alpha zzz-last" "$result"

# ── 6. requires_vscode gating ────────────────────────────────────────────────
# Selecting `vscode` in-run must unlock the later requires_vscode entry.
# Answers: alpha=n, vscode=y, ext-pack=y, zzz-last=n
printf 'n\ny\ny\nn\n' > "$WORK/vscode-yes"
result="$(PATH=/usr/bin:/bin run_prompts "$WORK/vscode-yes")"
assert_eq "selecting vscode in-run unlocks requires_vscode entries" \
    "0|vscode ext-pack" "$result"

# Declining vscode with no `code` on PATH must SKIP the gated entry without
# consuming an answer for it. Answers: alpha=y, vscode=n, zzz-last=y
printf 'y\nn\ny\n' > "$WORK/vscode-no"
result="$(PATH=/usr/bin:/bin run_prompts "$WORK/vscode-no")"
assert_eq "requires_vscode entries are skipped when VS Code is unavailable" \
    "0|alpha zzz-last" "$result"

# ── 7. An empty capability list is a no-op, not a crash ──────────────────────
: > "$WORK/caps.tsv"
result="$(run_prompts "$WORK/all-yes")"
assert_eq "empty capability list selects nothing and returns 0" "0|" "$result"

# ── 8. write_prefs must be reachable and emit parseable YAML ─────────────────
# Ties the two bugs together: the point of selecting capabilities is that they
# reach the prefs file the playbook actually consumes.
echo "==> bootstrap prefs file"
make_caps > "$WORK/caps.tsv"
(
    PRIOR_SELECTED_IDS=" "
    HAS_PRIOR_PREFS=false
    INTERACTIVE=1
    MERGED_CAPABILITIES_FILE="$WORK/caps.tsv"
    PREFS_FILE="$WORK/prefs.yml"
    GIT_NAME="Test User"
    GIT_EMAIL="test@example.com"
    gather_optional_tools < "$WORK/all-yes" >/dev/null 2>&1 \
        && write_prefs >/dev/null 2>&1
) || fail "write_prefs is reachable after the prompt loop" "the chain aborted"

if [[ -f "$WORK/prefs.yml" ]]; then
    pass "write_prefs is reachable after the prompt loop"
    got="$(yq -r '.selected_capabilities | join(" ")' "$WORK/prefs.yml" 2>/dev/null)"
    assert_eq "  prefs file records every selection" "alpha vscode ext-pack zzz-last" "$got"
    assert_eq "  prefs file records the git identity" \
        "Test User test@example.com" \
        "$(yq -r '[.git_user_name, .git_user_email] | join(" ")' "$WORK/prefs.yml" 2>/dev/null)"
    mode="$(stat -f '%OLp' "$WORK/prefs.yml" 2>/dev/null)"
    assert_eq "  prefs file is created 0600" "600" "$mode"
else
    fail "write_prefs is reachable after the prompt loop" "no prefs file was written"
fi

# ── 9. An empty selection set must still produce a valid prefs file ──────────
(
    PRIOR_SELECTED_IDS=" "; HAS_PRIOR_PREFS=false; INTERACTIVE=1
    MERGED_CAPABILITIES_FILE="$WORK/caps.tsv"
    PREFS_FILE="$WORK/prefs-empty.yml"
    GIT_NAME="Test User"; GIT_EMAIL="test@example.com"
    gather_optional_tools < "$WORK/all-no" >/dev/null 2>&1 && write_prefs >/dev/null 2>&1
)
assert_eq "empty selection still writes a valid selected_capabilities list" \
    "0" "$(yq -r '.selected_capabilities | length' "$WORK/prefs-empty.yml" 2>/dev/null)"

# ── 10. load_capabilities merges layers by descending priority, dedup by id ──
# Reuses the contract fixtures: `nvm` is defined in both layers and the
# higher-priority (override) definition must win in the menu, exactly as it does
# in the engine's capability registry.
echo "==> bootstrap capability merge"
(
    PLUGIN_CACHE="$REPO_ROOT/tests/fixtures/plugins"
    LAYERS_FILE="$REPO_ROOT/tests/fixtures/layers.yml"
    load_capabilities >/dev/null 2>&1
    cp "$MERGED_CAPABILITIES_FILE" "$WORK/merged.tsv"
)
merged_ids="$(cut -f1 "$WORK/merged.tsv" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "layers merge highest-priority-first, deduped by id" \
    "nvm vscode dbt vscode-peacock opencode zed adopted" "$merged_ids"
assert_eq "  the higher-priority layer's definition wins" \
    "nvm-from-override" "$(awk -F'\t' '$1=="nvm"{print $4}' "$WORK/merged.tsv")"

echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "bootstrap prompt tests: ${FAILURES} failure(s)" >&2
    exit 1
fi
echo "bootstrap prompt tests passed"

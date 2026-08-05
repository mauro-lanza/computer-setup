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
#   id \t desc \t type \t packages \t requires
# `vscode` sits BEFORE `ext-pack` so the in-run "VS Code was just selected"
# unlock is exercised, and `zzz-last` is deliberately final and not named
# `vscode` — that is the exact shape that triggered bug 2.
make_caps() {
    # Fields are separated by FS_U (ASCII Unit Separator), not tab — see the
    # comment on FS_U in bootstrap.sh. `ext-pack` deliberately has an EMPTY
    # packages field in no row, but `feature` capabilities do, and a tab
    # separator would collapse those and shift `requires` into `packages`.
    printf 'alpha%sAlpha tool%sformula%salpha%s\n' "$FS_U" "$FS_U" "$FS_U" "$FS_U"
    printf 'vscode%sVisual Studio Code%scask%svisual-studio-code%s\n' "$FS_U" "$FS_U" "$FS_U" "$FS_U"
    printf 'ext-pack%sEditor extension pack%sextension%ssome.extension%svscode\n' "$FS_U" "$FS_U" "$FS_U" "$FS_U"
    printf 'zzz-last%sLast capability%sformula%szzz%s\n' "$FS_U" "$FS_U" "$FS_U" "$FS_U"
    # A `feature` capability: no packages, but it DOES declare `requires`. With a
    # tab separator the empty field collapses and `vscode` is read as its
    # package list — installing a nonexistent formula.
    printf 'feat-gated%sConfig-only tool%sfeature%s%svscode\n' "$FS_U" "$FS_U" "$FS_U" "$FS_U"
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
        # `requires:` gating asks whether the required capability is already
        # present, via its adopt_if_present path in the layer cache. Point that
        # at a controlled dir: the real ~/.local/share cache would make the
        # result depend on what the developer happens to have installed.
        LAYER_CACHE="${LAYER_CACHE_OVERRIDE:-$WORK/empty-cache}"
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
TOTAL=5

# ── 1. Answering yes must select EVERY capability ────────────────────────────
# The regression signature of bug 1 is 0 selections from an all-yes run.
printf 'y\ny\ny\ny\ny\ny\ny\n' > "$WORK/all-yes"
result="$(run_prompts "$WORK/all-yes")"
rc="${result%%|*}"; sel="${result#*|}"
count=$(printf '%s' "$sel" | wc -w | tr -d ' ')
assert_eq "answering yes selects every capability ($TOTAL)" "$TOTAL" "$count"
assert_eq "  selections are the capability ids, in capability order" \
    "alpha vscode ext-pack zzz-last feat-gated" "$sel"

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

# ── 6. `requires:` gating ────────────────────────────────────────────────────
# Selecting `vscode` in-run must unlock the later entry that requires it.
# Answers: alpha=n, vscode=y, ext-pack=y, zzz-last=n
printf 'n\ny\ny\nn\n' > "$WORK/vscode-yes"
result="$(run_prompts "$WORK/vscode-yes")"
assert_eq "selecting a capability in-run unlocks entries requiring it" \
    "0|vscode ext-pack" "$result"

# Declining vscode, with nothing present to satisfy the requirement, must SKIP
# the gated entry without consuming an answer for it. Answers: alpha=y,
# vscode=n, zzz-last=y — only three, because ext-pack is never offered.
printf 'y\nn\ny\n' > "$WORK/vscode-no"
result="$(run_prompts "$WORK/vscode-no")"
assert_eq "entries are skipped when their requirement is unmet" \
    "0|alpha zzz-last" "$result"

# Same gate, for a capability whose `packages` field is EMPTY (a `feature`).
# With a tab separator that empty field collapses, `requires` is read as
# `packages`, the gate disappears, and `feat-gated` is offered on a machine with
# no editor — then "installed" as a formula literally named `vscode`.
#
# The trailing `y` is the trap: correct parsing never offers feat-gated, so the
# extra answer is simply unread. Broken parsing offers it and takes the `y`.
printf 'y\nn\ny\ny\n' > "$WORK/vscode-no-trap"
result="$(run_prompts "$WORK/vscode-no-trap")"
assert_eq "  a feature capability's requires survives an empty packages field" \
    "0|alpha zzz-last" "$result"

# ...but an ALREADY-INSTALLED requirement satisfies the gate without selecting
# it, via the capability's own adopt_if_present path. This is what replaced the
# hardcoded `command -v code` probe, so it needs its own coverage: a layer that
# names a different editor must gate on that editor, not on VS Code.
mkdir -p "$WORK/present-cache/lyr"
touch "$WORK/present-marker"
cat > "$WORK/present-cache/lyr/capabilities.yml" <<CAPS
---
capabilities:
  - id: vscode
    desc: "Already installed"
    type: cask
    packages: visual-studio-code
    adopt_if_present: "$WORK/present-marker"
CAPS
printf 'y\nn\ny\nn\n' > "$WORK/vscode-present"
result="$(LAYER_CACHE_OVERRIDE="$WORK/present-cache" run_prompts "$WORK/vscode-present")"
assert_eq "an already-present requirement satisfies the gate" \
    "0|alpha ext-pack" "$result"

# The same probe must report ABSENT when the path does not exist, or every gate
# would silently open.
rm -f "$WORK/present-marker"
printf 'y\nn\ny\n' > "$WORK/vscode-absent"
result="$(LAYER_CACHE_OVERRIDE="$WORK/present-cache" run_prompts "$WORK/vscode-absent")"
assert_eq "  and does not when the adopt path is missing" \
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
    gather_optional_tools < "$WORK/all-yes" >/dev/null 2>&1 \
        && write_prefs >/dev/null 2>&1
) || fail "write_prefs is reachable after the prompt loop" "the chain aborted"

if [[ -f "$WORK/prefs.yml" ]]; then
    pass "write_prefs is reachable after the prompt loop"
    got="$(yq -r '.selected_capabilities | join(" ")' "$WORK/prefs.yml" 2>/dev/null)"
    assert_eq "  prefs file records every selection" "alpha vscode ext-pack zzz-last feat-gated" "$got"
    # Identity is an ordinary answer now, so the prefs file must NOT carry a
    # top-level git_user_* key — that shape was the old special case.
    assert_eq "  prefs file has no top-level git identity keys" "false false" \
        "$(yq -r '[has("git_user_name"), has("git_user_email")] | join(" ")' "$WORK/prefs.yml" 2>/dev/null)"
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
    LAYER_CACHE="$REPO_ROOT/tests/fixtures/layers_cache"
    LAYERS_FILE="$REPO_ROOT/tests/fixtures/layers.yml"
    load_capabilities >/dev/null 2>&1
    cp "$MERGED_CAPABILITIES_FILE" "$WORK/merged.tsv"
)
merged_ids="$(cut -d"$FS_U" -f1 "$WORK/merged.tsv" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "layers merge highest-priority-first, deduped by id" \
    "nvm vscode dbt vscode-peacock opencode zed adopted" "$merged_ids"
assert_eq "  the higher-priority layer's definition wins" \
    "nvm-from-override" "$(awk -F'\037' '$1=="nvm"{print $4}' "$WORK/merged.tsv")"

# ── 11. Questions: the single-select prompt path ─────────────────────────────
# Same class of bug as the capability loop, and the same shape of test. Two
# extra hazards here: ask_select PRINTS its result on stdout, so any prompt text
# that leaks to stdout is captured as part of the answer; and the question list
# must again come from FD 3, not stdin.
echo "==> bootstrap question prompts"

make_questions() {
    printf 'editor%sselect%sDefault editor%svscode%svscode,zed,none%s\n' \
        "$FS_U" "$FS_U" "$FS_U" "$FS_U" "$FS_U"
    printf 'scratch%stext%sScratch dir%s/tmp/scratch%s%s\n' \
        "$FS_U" "$FS_U" "$FS_U" "$FS_U" "$FS_U"
}

# A validated text question. `options` is empty and `validate` follows it, which
# is exactly the empty-middle-field case a tab separator would corrupt.
make_validated_question() {
    printf 'email%stext%sGit email%sdefault@example.com%s%s^[^ @]+@[^ @]+\\.[^ @]+$\n' \
        "$FS_U" "$FS_U" "$FS_U" "$FS_U" "$FS_U"
}
make_questions > "$WORK/questions.tsv"

# Drive gather_answers with a scripted answer file. Prints "<rc>|id=value;..."
run_questions() {
    local answers="$1"
    (
        INTERACTIVE=1
        MERGED_QUESTIONS_FILE="$WORK/questions.tsv"
        PREFS_FILE="$WORK/no-such-prefs.yml"
        ANSWER_IDS=(); ANSWER_VALUES=()
        gather_answers < "$answers" >/dev/null 2>&1
        local rc=$? out="" i
        for i in $(seq 0 $((${#ANSWER_IDS[@]} - 1))); do
            out="${out}${ANSWER_IDS[$i]}=${ANSWER_VALUES[$i]};"
        done
        printf '%s|%s\n' "$rc" "$out"
    )
}

# Choosing by number, then a typed text answer.
printf '2\n/tmp/mine\n' > "$WORK/q-number"
assert_eq "select by number returns the option VALUE, not the number" \
    "0|editor=zed;scratch=/tmp/mine;" "$(run_questions "$WORK/q-number")"

# Choosing by typing the value itself.
printf 'none\n\n' > "$WORK/q-value"
assert_eq "select accepts the option value typed literally" \
    "0|editor=none;scratch=/tmp/scratch;" "$(run_questions "$WORK/q-value")"

# Bare Enter must take the declared default, not an empty answer. An empty
# answer would fail the engine's select validation on the very next run.
printf '\n\n' > "$WORK/q-enter"
assert_eq "Enter takes the declared default for both types" \
    "0|editor=vscode;scratch=/tmp/scratch;" "$(run_questions "$WORK/q-enter")"

# An out-of-range choice must re-prompt rather than be accepted or crash.
printf '99\nzed\n/tmp/x\n' > "$WORK/q-bad"
assert_eq "an invalid choice re-prompts instead of being accepted" \
    "0|editor=zed;scratch=/tmp/x;" "$(run_questions "$WORK/q-bad")"

# ── validate: a text answer must match the pattern its layer declares ───────
# Without this, a mistyped git address is written straight into the managed
# gitconfig and every commit carries it. The engine re-checks on apply, because
# the prefs file is editable by hand.
make_validated_question > "$WORK/questions-validated.tsv"
run_validated() {
    (
        INTERACTIVE=1
        MERGED_QUESTIONS_FILE="$WORK/questions-validated.tsv"
        PREFS_FILE="$WORK/no-such-prefs.yml"
        ANSWER_IDS=(); ANSWER_VALUES=()
        gather_answers < "$1" >/dev/null 2>&1
        printf '%s' "${ANSWER_VALUES[0]}"
    )
}

printf 'me@example.com\n' > "$WORK/v-good"
assert_eq "a valid answer is accepted" "me@example.com" "$(run_validated "$WORK/v-good")"

# The first answer violates the pattern and must be re-prompted, not stored.
printf 'not-an-email\nsecond@example.com\n' > "$WORK/v-bad"
assert_eq "  an answer failing validate re-prompts instead of being accepted" \
    "second@example.com" "$(run_validated "$WORK/v-bad")"

# Enter takes the default, which must itself satisfy the pattern.
printf '\n' > "$WORK/v-enter"
assert_eq "  Enter still takes the declared default" "default@example.com" \
    "$(run_validated "$WORK/v-enter")"

# Answers must survive write_prefs and come BACK as the defaults on a re-run.
# A one-way write would silently reset every decision on the next bootstrap.
(
    PREFS_FILE="$WORK/prefs-answers.yml"
    SELECTED_CAPABILITIES=(alpha)
    ANSWER_IDS=(editor scratch); ANSWER_VALUES=(zed "/tmp/mine")
    write_prefs >/dev/null 2>&1
)
assert_eq "prefs file records the answers" "zed" \
    "$(yq -r '.answers.editor' "$WORK/prefs-answers.yml" 2>/dev/null)"
assert_eq "  answers survive a yq round-trip as valid YAML" "/tmp/mine" \
    "$(yq -r '.answers.scratch' "$WORK/prefs-answers.yml" 2>/dev/null)"
assert_eq "  a stored answer is read back as the next run's default" "zed" \
    "$(PREFS_FILE="$WORK/prefs-answers.yml" prior_answer editor)"

# With prior answers present, bare Enter must keep them rather than revert to
# the layer's declared default.
printf '\n\n' > "$WORK/q-enter2"
result="$(
    INTERACTIVE=1
    MERGED_QUESTIONS_FILE="$WORK/questions.tsv"
    PREFS_FILE="$WORK/prefs-answers.yml"
    ANSWER_IDS=(); ANSWER_VALUES=()
    gather_answers < "$WORK/q-enter2" >/dev/null 2>&1
    printf '%s=%s' "${ANSWER_IDS[0]}" "${ANSWER_VALUES[0]}"
)"
assert_eq "Enter keeps the prior answer instead of the declared default" \
    "editor=zed" "$result"

# ── 12. load_questions merges layers by descending priority, dedup by id ─────
(
    LAYER_CACHE="$REPO_ROOT/tests/fixtures/layers_cache"
    LAYERS_FILE="$REPO_ROOT/tests/fixtures/layers.yml"
    load_questions >/dev/null 2>&1
    cp "$MERGED_QUESTIONS_FILE" "$WORK/merged-q.tsv"
)
assert_eq "questions merge deduped by id" \
    "editor unanswered repositories-dir drift-agents git-email" \
    "$(cut -d"$FS_U" -f1 "$WORK/merged-q.tsv" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "  the higher-priority layer's question wins" \
    "Default editor (override)" \
    "$(awk -F'\037' '$1=="editor"{print $3}' "$WORK/merged-q.tsv")"

# ── 13. Presets ──────────────────────────────────────────────────────────────
# A preset is a pure prefill. The risks are that it loads nothing (a yq
# expression that silently yields no rows looks identical to "no presets
# declared"), or that declining the review still blocks on a prompt.
echo "==> bootstrap presets"
(
    LAYER_CACHE="$REPO_ROOT/tests/fixtures/layers_cache"
    LAYERS_FILE="$REPO_ROOT/tests/fixtures/layers.yml"
    load_presets >/dev/null 2>&1
    cp "$MERGED_PRESETS_FILE" "$WORK/presets.tsv"
)
assert_eq "presets load from layers" "everything nothing" \
    "$(cut -d"$FS_U" -f1 "$WORK/presets.tsv" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "  capabilities survive as a csv column" "alpha,zzz-last" \
    "$(awk -F'\037' '$1=="everything"{print $3}' "$WORK/presets.tsv")"
assert_eq "  preset_answer extracts one answer" "picked" \
    "$(MERGED_PRESETS_FILE="$WORK/presets.tsv" PRESET_ID=everything preset_answer editor)"
assert_eq "  preset_answer is empty for an unset question" "" \
    "$(MERGED_PRESETS_FILE="$WORK/presets.tsv" PRESET_ID=nothing preset_answer unanswered)"

# Declining the review must consume NO stdin at all. Feeding it /dev/null means
# any stray `read` turns into an empty answer or a hang, both of which fail here.
result="$(
    MERGED_QUESTIONS_FILE="$WORK/questions.tsv"
    MERGED_PRESETS_FILE="$WORK/presets.tsv"
    PREFS_FILE="$WORK/no-such-prefs.yml"
    PRESET_ID=everything
    REVIEW_ANSWERS=false
    ANSWER_IDS=(); ANSWER_VALUES=()
    gather_answers < /dev/null >/dev/null 2>&1
    printf '%s=%s' "${ANSWER_IDS[0]}" "${ANSWER_VALUES[0]}"
)"
assert_eq "declining review takes preset answers without prompting" \
    "editor=picked" "$result"

# The preset, not the machine's prior selections, defines the default set.
result="$(
    MERGED_CAPABILITIES_FILE="$WORK/caps.tsv"
    MERGED_PRESETS_FILE="$WORK/presets.tsv"
    PRIOR_SELECTED_IDS=" ext-pack "
    HAS_PRIOR_PREFS=true
    PRESET_ID=everything
    PRESET_CAPS=" alpha zzz-last "
    REVIEW_ANSWERS=false
    SELECTED_CAPABILITIES=()
    gather_optional_tools < /dev/null >/dev/null 2>&1
    printf '%s' "${SELECTED_CAPABILITIES[*]+${SELECTED_CAPABILITIES[*]}}"
)"
assert_eq "preset capabilities replace prior selections" "alpha zzz-last" "$result"

# ── 14. --answers: the zero-touch rebuild path ───────────────────────────────
echo "==> bootstrap answers file"
cat > "$WORK/answers.yml" <<'ANSWERS'
---
answers:
  git-name: File User
  git-email: file@example.com
  editor: zed
  drift-agents: false
selected_capabilities:
  - alpha
  - ripgrep
ANSWERS
result="$(
    load_answers_file "$WORK/answers.yml" >/dev/null 2>&1
    printf '%s|%s' "${ANSWER_IDS[*]}" "${SELECTED_CAPABILITIES[*]}"
)"
assert_eq "an answers file supplies answers (identity included) and selections" \
    "git-name git-email editor drift-agents|alpha ripgrep" "$result"

# Identity travels as an ordinary answer, so it needs no special handling on
# either side of the round trip.
result="$(
    load_answers_file "$WORK/answers.yml" >/dev/null 2>&1
    printf '%s|%s' "${ANSWER_VALUES[0]}" "${ANSWER_VALUES[1]}"
)"
assert_eq "  the identity answers survive as ordinary answers" \
    "File User|file@example.com" "$result"

# A YAML bool must survive as the string the engine's `| bool` filter reads,
# not as an empty value.
result="$(
    load_answers_file "$WORK/answers.yml" >/dev/null 2>&1
    printf '%s' "${ANSWER_VALUES[3]}"
)"
assert_eq "  a YAML bool answer is preserved as a string" "false" "$result"

# The file bootstrap WRITES must be usable as the file it READS — that
# round-trip is the whole point of "rebuild this machine in one command".
(
    PREFS_FILE="$WORK/prefs-roundtrip.yml"
    SELECTED_CAPABILITIES=(alpha zzz-last)
    ANSWER_IDS=(git-email editor); ANSWER_VALUES=(rt@example.com zed)
    write_prefs >/dev/null 2>&1
)
result="$(
    load_answers_file "$WORK/prefs-roundtrip.yml" >/dev/null 2>&1
    printf '%s|%s|%s' "${ANSWER_VALUES[0]}" "${ANSWER_VALUES[1]}" "${SELECTED_CAPABILITIES[*]}"
)"
assert_eq "a written prefs file is a valid --answers file" \
    "rt@example.com|zed|alpha zzz-last" "$result"

echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "bootstrap prompt tests: ${FAILURES} failure(s)" >&2
    exit 1
fi
echo "bootstrap prompt tests passed"

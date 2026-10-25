#!/bin/bash
# Regression tests for bootstrap.sh's interactive prompt path, the one code path
# that only runs on a fresh machine. Each assertion maps to a way selection can rot:
#   - the capability loop and `ask_yn` both reading stdin (every prompt ate the
#     next capability, so nothing was ever selected);
#   - a trailing failed test making the loop return 1, which `set -e` turns into
#     an exit before write_machine.

# The assertions run in subshells; shellcheck cannot see their globals consumed
# by the sourced functions. File-scoped, so it must stay above the first command.
# shellcheck disable=SC2034,SC2030,SC2031
# shellcheck source-path=SCRIPTDIR/..

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$PWD"

# Source bootstrap.sh for its functions without running the installer.
export COMPUTER_SETUP_BOOTSTRAP_LIB=1
# shellcheck source=bootstrap.sh
source "$REPO_ROOT/bootstrap.sh"
# bootstrap.sh sets -e; the harness needs to inspect failures rather than die.
set +e

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { printf '  ok  %s\n' "$1"; }
fail() { printf '  FAIL %s\n     %s\n' "$1" "$2" >&2; FAILURES=$((FAILURES + 1)); }

# Octal permission bits; BSD and GNU stat spell it differently.
file_mode() {
    if [[ "$(uname -s)" == Darwin ]]; then stat -f '%OLp' "$1"; else stat -c '%a' "$1"; fi 2>/dev/null
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label" "expected [$expected], got [$actual]"
    fi
}

# One merged-registry row, fields joined by FS_U via IFS so the column count
# (id, desc, requires, adopt_if_present) is right by construction.
caps_row() {
    local IFS="$FS_U"
    printf '%s\n' "$*"
}

# `vscode` precedes `ext-pack` to exercise the in-run unlock; `zzz-last` is last
# and not `vscode`, the shape that made the loop return 1.
# $1 (optional): the adopt_if_present path for the `vscode` row.
make_caps() {
    caps_row alpha      "Alpha tool"            ""       ""
    caps_row vscode     "Visual Studio Code"    ""       "${1:-}"
    caps_row ext-pack   "Editor extension pack" vscode   ""
    caps_row zzz-last   "Last capability"       ""       ""
    # A second capability gated on vscode, after zzz-last.
    caps_row feat-gated "Config-only tool"      vscode   ""
}

# Drive gather_optional_tools with a scripted answer file and echo the result.
#   $1 answers file, $2 prior-selection string, $3 "true"/"false" HAS_PRIOR_MACHINE
# Prints: "<rc>|<space separated selections>"
run_prompts() {
    local answers="$1" prior="${2:- }" has_prior="${3:-false}"
    (
        PRIOR_SELECTED_IDS="$prior"
        HAS_PRIOR_MACHINE="$has_prior"
        INTERACTIVE=1
        MERGED_CAPABILITIES_FILE="$WORK/caps.tsv"
        # The registry alone resolves `requires:`; an empty cache dir makes a
        # reintroduced cache lookup fail here.
        LAYER_CACHE="$WORK/empty-cache"
        SELECTED_CAPABILITIES=()
        # Answers come on stdin and the capability list on FD 3; that separation is the fix under test.
        gather_optional_tools < "$answers" >/dev/null 2>&1
        printf '%s|%s\n' "$?" "${SELECTED_CAPABILITIES[*]+${SELECTED_CAPABILITIES[*]}}"
    )
}

echo "==> bootstrap prompt loop"
make_caps > "$WORK/caps.tsv"
TOTAL=5

# ── 1. Answering yes must select EVERY capability ────────────────────────────
printf 'y\ny\ny\ny\ny\ny\ny\n' > "$WORK/all-yes"
result="$(run_prompts "$WORK/all-yes")"
rc="${result%%|*}"; sel="${result#*|}"
count=$(printf '%s' "$sel" | wc -w | tr -d ' ')
assert_eq "answering yes selects every capability ($TOTAL)" "$TOTAL" "$count"
assert_eq "  selections are the capability ids, in capability order" \
    "alpha vscode ext-pack zzz-last feat-gated" "$sel"

# ── 2. The function must return success ──────────────────────────────────────
# A trailing failed test made the loop return 1, which `set -e` turns into an
# exit before write_machine.
assert_eq "returns 0 after selecting a non-vscode capability last" "0" "$rc"

# ── 3. Answering no must select nothing (and still return success) ───────────
printf 'n\nn\nn\nn\nn\nn\n' > "$WORK/all-no"
result="$(run_prompts "$WORK/all-no")"
assert_eq "answering no selects nothing" "0|" "$result"

# ── 4. Bare Enter defaults to no on a first run ──────────────────────────────
printf '\n\n\n\n\n\n' > "$WORK/all-enter"
result="$(run_prompts "$WORK/all-enter")"
assert_eq "Enter defaults to no when there is no prior machine file" "0|" "$result"

# ── 5. Bare Enter keeps prior answers on a re-run ────────────────────────────
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

# A second gated entry after the last ungated one must stay gated too. The
# trailing `y` is the trap: correct gating never offers feat-gated, so it goes unread.
printf 'y\nn\ny\ny\n' > "$WORK/vscode-no-trap"
result="$(run_prompts "$WORK/vscode-no-trap")"
assert_eq "  a later gated capability stays gated" \
    "0|alpha zzz-last" "$result"

# An ALREADY-INSTALLED requirement satisfies the gate via the capability's own
# adopt_if_present, read from the merged registry column (staged here as data).
# The vscode row then has an empty `requires` before a set adopt path: a tab
# separator would collapse it and read the path as `requires`.
touch "$WORK/present-marker"
make_caps "$WORK/present-marker" > "$WORK/caps.tsv"
printf 'y\nn\ny\nn\n' > "$WORK/vscode-present"
result="$(run_prompts "$WORK/vscode-present")"
assert_eq "an already-present requirement satisfies the gate" \
    "0|alpha ext-pack" "$result"

# The same probe must report ABSENT when the path does not exist, or every gate
# would silently open.
rm -f "$WORK/present-marker"
printf 'y\nn\ny\n' > "$WORK/vscode-absent"
result="$(run_prompts "$WORK/vscode-absent")"
assert_eq "  and does not when the adopt path is missing" \
    "0|alpha zzz-last" "$result"

# Restore the default registry for the remaining cases.
make_caps > "$WORK/caps.tsv"

# ── 7. `requires:` must survive a capability declared BEFORE its requirement ──
# `requires` resolves in one forward pass, so load_capabilities reorders topologically.
echo "==> capability requires-ordering"
{
    caps_row ext-early "Extension, declared first" vscode ""
    caps_row alpha     "Alpha tool"                ""     ""
    caps_row vscode    "Visual Studio Code"        ""     ""
} > "$WORK/caps-unordered.tsv"
cp "$WORK/caps-unordered.tsv" "$WORK/caps-ordered.tsv"
order_capabilities_by_requires "$WORK/caps-ordered.tsv"
assert_eq "a dependent is reordered to follow its requirement" \
    "alpha vscode ext-early" \
    "$(cut -d"$FS_U" -f1 "$WORK/caps-ordered.tsv" | tr '\n' ' ' | sed 's/ $//')"

# And it is now actually OFFERED. Answers: alpha=y, vscode=y, ext-early=y.
cp "$WORK/caps-ordered.tsv" "$WORK/caps.tsv"
printf 'y\ny\ny\n' > "$WORK/reorder-yes"
result="$(run_prompts "$WORK/reorder-yes")"
assert_eq "  and is then offered, instead of silently vanishing" \
    "0|alpha vscode ext-early" "$result"

# A requirement that no layer declares must NOT be reordered away; the entry
# keeps its place and stays gated on adopt_if_present.
{
    caps_row orphan "Needs something unregistered" external-thing ""
    caps_row alpha  "Alpha tool"                   ""             ""
} > "$WORK/caps-orphan.tsv"
order_capabilities_by_requires "$WORK/caps-orphan.tsv"
assert_eq "  an unregistered requirement leaves the row in place" \
    "orphan alpha" \
    "$(cut -d"$FS_U" -f1 "$WORK/caps-orphan.tsv" | tr '\n' ' ' | sed 's/ $//')"

make_caps > "$WORK/caps.tsv"

# ── 8. An empty capability list is a no-op, not a crash ──────────────────────
: > "$WORK/caps.tsv"
result="$(run_prompts "$WORK/all-yes")"
assert_eq "empty capability list selects nothing and returns 0" "0|" "$result"

# ── 9. write_machine must be reachable and emit parseable YAML ─────────────────
# Selections must reach the machine file the playbook consumes.
echo "==> bootstrap machine file"
make_caps > "$WORK/caps.tsv"
(
    PRIOR_SELECTED_IDS=" "
    HAS_PRIOR_MACHINE=false
    INTERACTIVE=1
    MERGED_CAPABILITIES_FILE="$WORK/caps.tsv"
    MACHINE_FILE="$WORK/machine.yml"
    gather_optional_tools < "$WORK/all-yes" >/dev/null 2>&1 \
        && write_machine >/dev/null 2>&1
) || fail "write_machine is reachable after the prompt loop" "the chain aborted"

if [[ -f "$WORK/machine.yml" ]]; then
    pass "write_machine is reachable after the prompt loop"
    got="$(yq -r '.selected_capabilities | join(" ")' "$WORK/machine.yml" 2>/dev/null)"
    assert_eq "  machine file records every selection" "alpha vscode ext-pack zzz-last feat-gated" "$got"
    # Identity is an ordinary answer now, so the machine file must NOT carry a
    # top-level git_user_* key — that shape was the old special case.
    assert_eq "  machine file has no top-level git identity keys" "false false" \
        "$(yq -r '[has("git_user_name"), has("git_user_email")] | join(" ")' "$WORK/machine.yml" 2>/dev/null)"
    mode="$(file_mode "$WORK/machine.yml")"
    assert_eq "  machine file is created 0600" "600" "$mode"
else
    fail "write_machine is reachable after the prompt loop" "no machine file was written"
fi

# ── 10. An empty selection set must still produce a valid machine file ──────────
(
    PRIOR_SELECTED_IDS=" "; HAS_PRIOR_MACHINE=false; INTERACTIVE=1
    MERGED_CAPABILITIES_FILE="$WORK/caps.tsv"
    MACHINE_FILE="$WORK/machine-empty.yml"
    gather_optional_tools < "$WORK/all-no" >/dev/null 2>&1 && write_machine >/dev/null 2>&1
)
assert_eq "empty selection still writes a valid selected_capabilities list" \
    "0" "$(yq -r '.selected_capabilities | length' "$WORK/machine-empty.yml" 2>/dev/null)"

# ── 11. load_capabilities merges layers by descending priority, dedup by id ──
# Reuses the contract fixtures: `nvm` is defined in both layers and the
# higher-priority definition must win, as in the engine.
echo "==> bootstrap capability merge"
(
    LAYER_CACHE="$REPO_ROOT/tests/fixtures/layers_cache"
    MACHINE_FILE="$REPO_ROOT/tests/fixtures/machine.yml"
    load_capabilities >/dev/null 2>&1
    cp "$MERGED_CAPABILITIES_FILE" "$WORK/merged.tsv"
    rm -f "$MERGED_CAPABILITIES_FILE"
)
merged_ids="$(cut -d"$FS_U" -f1 "$WORK/merged.tsv" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "layers merge highest-priority-first, deduped by id" \
    "nvm vscode dbt vscode-peacock ripgrep pacman-only opencode zed adopted" "$merged_ids"
assert_eq "  the higher-priority layer's definition wins" \
    "Node Version Manager (override wins)" "$(awk -F"$FS_U" '$1=="nvm"{print $2}' "$WORK/merged.tsv")"

# ── 12. Questions: the single-select prompt path ────────────────────────────
# Same stdin/FD 3 hazard as the capability loop; also ask_select prints its
# result on stdout, so prompt text leaking there would corrupt the answer.
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
        MACHINE_FILE="$WORK/no-such-machine.yml"
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
# the machine file is editable by hand.
make_validated_question > "$WORK/questions-validated.tsv"
run_validated() {
    (
        INTERACTIVE=1
        MERGED_QUESTIONS_FILE="$WORK/questions-validated.tsv"
        MACHINE_FILE="$WORK/no-such-machine.yml"
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

# A templated default must survive its own question's validate pattern. The
# `repositories-dir` question defaults to `{{ home_dir }}/Projects` so it
# resolves per-machine; that literal contains spaces inside the braces, so
# `^[^ ]+$` rejected it and the first real fresh-machine bootstrap had to be
# answered by hand. bootstrap does not render Jinja, so it must not validate it.
printf '\n' > "$WORK/tmpl-default"
result="$(ask_text "Where repos go" '{{ home_dir }}/Projects' '^[^ ]+$' < "$WORK/tmpl-default" 2>/dev/null)"
assert_eq "  a templated default is accepted, not rejected by its own validate" \
    "{{ home_dir }}/Projects" "$result"

# The pattern must still bite on a real, non-templated answer.
printf 'has space\nok-value\n' > "$WORK/tmpl-real"
result="$(ask_text "Where repos go" '/tmp/x' '^[^ ]+$' < "$WORK/tmpl-real" 2>/dev/null)"
assert_eq "  a non-templated answer is still validated" "ok-value" "$result"

# Answers must survive write_machine and come BACK as the defaults on a re-run.
# A one-way write would silently reset every decision on the next bootstrap.
(
    MACHINE_FILE="$WORK/machine-answers.yml"
    SELECTED_CAPABILITIES=(alpha)
    ANSWER_IDS=(editor scratch); ANSWER_VALUES=(zed "/tmp/mine")
    write_machine >/dev/null 2>&1
)
assert_eq "machine file records the answers" "zed" \
    "$(yq -r '.answers.editor' "$WORK/machine-answers.yml" 2>/dev/null)"
assert_eq "  answers survive a yq round-trip as valid YAML" "/tmp/mine" \
    "$(yq -r '.answers.scratch' "$WORK/machine-answers.yml" 2>/dev/null)"
assert_eq "  a stored answer is read back as the next run's default" "zed" \
    "$(MACHINE_FILE="$WORK/machine-answers.yml" HAS_PRIOR_MACHINE=true prior_answer editor)"

# A first run's machine.yml holds layers only (Phase 1 wrote it), so it must not
# count as a prior machine; one carrying answers or selections must, however few.
printf -- '---\nlayers:\n  - name: "a"\n    repo: "r"\n    priority: 10\nanswers: {}\nselected_capabilities: []\n' \
    > "$WORK/prior-layers-only.yml"
printf -- '---\nlayers: []\nanswers:\n  editor: "zed"\nselected_capabilities: []\n' \
    > "$WORK/prior-answers.yml"
printf -- '---\nlayers: []\nselected_capabilities:\n  - alpha\n' \
    > "$WORK/prior-selections.yml"
printf -- '---\nlayers: []\nanswers:\nselected_capabilities:\n' \
    > "$WORK/prior-null-keys.yml"
prior_flag() {
    (
        HAS_PRIOR_MACHINE=false
        PRIOR_SELECTED_IDS=" "
        MACHINE_FILE="$1"
        load_prior_machine
        printf '%s' "$HAS_PRIOR_MACHINE"
    )
}
assert_eq "a layers-only machine file is not a prior machine" "false" \
    "$(prior_flag "$WORK/prior-layers-only.yml")"
assert_eq "  null answers and selections are not a prior machine" "false" \
    "$(prior_flag "$WORK/prior-null-keys.yml")"
assert_eq "  a missing machine file is not a prior machine" "false" \
    "$(prior_flag "$WORK/no-such-machine.yml")"
assert_eq "  a file with answers is a prior machine" "true" \
    "$(prior_flag "$WORK/prior-answers.yml")"
assert_eq "  a file with only selections is a prior machine" "true" \
    "$(prior_flag "$WORK/prior-selections.yml")"

# ── manage_layers: with and without layers; machine_write creates the directory ─
echo "==> bootstrap layer manifest"
run_layers() {
    (
        INTERACTIVE=1
        ANSWERS_FILE=""
        MACHINE_FILE="$2"
        manage_layers < "$1" >/dev/null 2>&1
    )
}
printf 'n\n' > "$WORK/layers-none"
run_layers "$WORK/layers-none" "$WORK/new-config/machine.yml"
assert_eq "declining every layer still writes a manifest with none" "0|0" \
    "$(yq -r '(.layers // [] | length | tostring) + "|" + (.selected_capabilities | length | tostring)' \
        "$WORK/new-config/machine.yml" 2>/dev/null)"
printf 'y\npub\ngit@github.com:o/r.git\n\nn\n' > "$WORK/layers-one"
run_layers "$WORK/layers-one" "$WORK/new-config/machine-one.yml"
assert_eq "  one layer is written with the default priority" "pub|10" \
    "$(yq -r '.layers[0].name + "|" + (.layers[0].priority | tostring)' "$WORK/new-config/machine-one.yml" 2>/dev/null)"
printf -- '---\nlayers:\n  - name: "a"\n    repo: "r"\n    priority: 10\nanswers:\n  editor: "zed"\nselected_capabilities: []\n' \
    > "$WORK/new-config/machine-reconf.yml"
printf 'y\nn\n' > "$WORK/layers-reconf"
run_layers "$WORK/layers-reconf" "$WORK/new-config/machine-reconf.yml"
assert_eq "  reconfiguring layers keeps the answers on disk" "zed" \
    "$(yq -r '.answers.editor' "$WORK/new-config/machine-reconf.yml" 2>/dev/null)"

# A `ref:` pin survives a rewrite; dropping it silently moved a pinned layer
# back to its default branch on the next sync.
printf -- 'layers:\n  - {name: a, repo: r, priority: 10, ref: some-branch}\n  - {name: b, repo: s, priority: 20}\n' \
    > "$WORK/new-config/machine-ref.yml"
( MACHINE_FILE="$WORK/new-config/machine-ref.yml"; machine_write ) >/dev/null 2>&1
assert_eq "  a layer's ref: pin survives a rewrite, and no ref is invented" "some-branch|false" \
    "$(yq -r '.layers[0].ref + "|" + (.layers[1] | has("ref") | tostring)' "$WORK/new-config/machine-ref.yml" 2>/dev/null)"

# main must refuse before installing anything when there is neither a terminal
# nor an --answers file. Every first Phase 0 step (macOS: Xcode CLT; Linux:
# prerequisites) is stubbed so a missing guard shows up as "reached phase 0"
# instead of running an installer.
no_tty_main() {
    (
        reattach_stdin() { INTERACTIVE=0; }
        install_xcode_clt() { echo "reached phase 0"; exit 0; }
        ensure_prereqs() { echo "reached phase 0"; exit 0; }
        main "$@" 2>&1
    )
}
out="$(no_tty_main)"; rc=$?
assert_eq "no terminal and no --answers exits 1 with the hint, before phase 0" "1|1" \
    "$rc|$([[ "$out" == *"No terminal available for prompts."* && "$out" != *"reached phase 0"* ]] && echo 1 || echo "$out")"
out="$(no_tty_main --answers "$WORK/prior-answers.yml")"; rc=$?
assert_eq "  --answers needs no terminal" "0|reached phase 0" \
    "$rc|$([[ "$out" == *"reached phase 0"* ]] && echo "reached phase 0" || echo "$out")"

# With prior answers present, bare Enter must keep them rather than revert to
# the layer's declared default.
printf '\n\n' > "$WORK/q-enter2"
result="$(
    INTERACTIVE=1
    MERGED_QUESTIONS_FILE="$WORK/questions.tsv"
    MACHINE_FILE="$WORK/machine-answers.yml"
    HAS_PRIOR_MACHINE=true
    ANSWER_IDS=(); ANSWER_VALUES=()
    gather_answers < "$WORK/q-enter2" >/dev/null 2>&1
    printf '%s=%s' "${ANSWER_IDS[0]}" "${ANSWER_VALUES[0]}"
)"
assert_eq "Enter keeps the prior answer instead of the declared default" \
    "editor=zed" "$result"

# bool questions: the declared default is what Enter keeps, in both directions.
bool_answer() {
    (
        INTERACTIVE=1
        MERGED_QUESTIONS_FILE="$WORK/q-bool.tsv"
        MACHINE_FILE="$WORK/no-such-machine.yml"
        ANSWER_IDS=(); ANSWER_VALUES=()
        gather_answers <<< "$1" >/dev/null 2>&1
        printf '%s' "${ANSWER_VALUES[0]}"
    )
}
for bool_default in true false; do
    printf 'flag%sbool%sA flag%s%s%s\n' "$FS_U" "$FS_U" "$FS_U" "$bool_default" "$FS_U" \
        > "$WORK/q-bool.tsv"
    assert_eq "bool default ${bool_default}: Enter keeps it" "$bool_default" "$(bool_answer '')"
    assert_eq "  y answers true" "true" "$(bool_answer y)"
    assert_eq "  n answers false" "false" "$(bool_answer n)"
done

# The play gets the pull flags and the repo URL on the apply call.
mkdir -p "$WORK/fake-bin"
# shellcheck disable=SC2016 # the stub's $* and $PULL_LOG expand when it runs, not here
printf '#!/bin/bash\necho "$*" >> "$PULL_LOG"\n' > "$WORK/fake-bin/ansible-pull"
chmod +x "$WORK/fake-bin/ansible-pull"
PULL_LOG="$WORK/pull.log" RUNTIME_BIN="$WORK/fake-bin" ANSWERS_FILE=x MACHINE_FILE=/m.yml \
    run_playbook >/dev/null 2>&1
assert_eq "run_playbook passes the repo, branch, pull dir and repo URL to ansible-pull" "1|1|1|1" \
    "$(l="$(<"$WORK/pull.log")"
       printf '%s|%s|%s|%s' \
        "$([[ "$l" == "-U $REPO_URL -C $REPO_BRANCH "* ]] && echo 1)" \
        "$([[ "$l" == *"-d $PULL_DIR "* ]] && echo 1)" \
        "$([[ "$l" == *"-e computer_setup_repo_url=$REPO_URL"* ]] && echo 1)" \
        "$([[ "$l" == *" local.yml" ]] && echo 1)")"

# ── 13. load_questions merges layers by descending priority, dedup by id ─────
(
    LAYER_CACHE="$REPO_ROOT/tests/fixtures/layers_cache"
    MACHINE_FILE="$REPO_ROOT/tests/fixtures/machine.yml"
    load_questions >/dev/null 2>&1
    cp "$MERGED_QUESTIONS_FILE" "$WORK/merged-q.tsv"
    rm -f "$MERGED_QUESTIONS_FILE"
)
assert_eq "questions merge deduped by id" \
    "editor unanswered repositories-dir drift-agents git-email" \
    "$(cut -d"$FS_U" -f1 "$WORK/merged-q.tsv" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "  the higher-priority layer's question wins" \
    "Default editor (override)" \
    "$(awk -F"$FS_U" '$1=="editor"{print $3}' "$WORK/merged-q.tsv")"

# ── 14. Presets ──────────────────────────────────────────────────────────────
# A preset is a pure prefill. The risks are that it loads nothing (a yq
# expression that silently yields no rows looks identical to "no presets
# declared"), or that declining the review still blocks on a prompt.
echo "==> bootstrap presets"
(
    LAYER_CACHE="$REPO_ROOT/tests/fixtures/layers_cache"
    MACHINE_FILE="$REPO_ROOT/tests/fixtures/machine.yml"
    load_presets >/dev/null 2>&1
    cp "$MERGED_PRESETS_FILE" "$WORK/presets.tsv"
    rm -f "$MERGED_PRESETS_FILE"
)
assert_eq "presets load from layers" "everything nothing" \
    "$(cut -d"$FS_U" -f1 "$WORK/presets.tsv" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "  capabilities survive as a csv column" "alpha,zzz-last" \
    "$(awk -F"$FS_U" '$1=="everything"{print $3}' "$WORK/presets.tsv")"
assert_eq "  preset_answer extracts one answer" "picked" \
    "$(MERGED_PRESETS_FILE="$WORK/presets.tsv" PRESET_ID=everything preset_answer editor)"
assert_eq "  preset_answer is empty for an unset question" "" \
    "$(MERGED_PRESETS_FILE="$WORK/presets.tsv" PRESET_ID=nothing preset_answer unanswered)"

# Declining the review must consume NO stdin at all. Feeding it /dev/null means
# any stray `read` turns into an empty answer or a hang, both of which fail here.
result="$(
    MERGED_QUESTIONS_FILE="$WORK/questions.tsv"
    MERGED_PRESETS_FILE="$WORK/presets.tsv"
    MACHINE_FILE="$WORK/no-such-machine.yml"
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
    HAS_PRIOR_MACHINE=true
    PRESET_ID=everything
    PRESET_CAPS=" alpha zzz-last "
    REVIEW_ANSWERS=false
    SELECTED_CAPABILITIES=()
    gather_optional_tools < /dev/null >/dev/null 2>&1
    printf '%s' "${SELECTED_CAPABILITIES[*]+${SELECTED_CAPABILITIES[*]}}"
)"
assert_eq "preset capabilities replace prior selections" "alpha zzz-last" "$result"

# ── 15. --answers: the zero-touch rebuild path ───────────────────────────────
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
    MACHINE_FILE="$WORK/machine-roundtrip.yml"
    SELECTED_CAPABILITIES=(alpha zzz-last)
    ANSWER_IDS=(git-email editor); ANSWER_VALUES=(rt@example.com zed)
    write_machine >/dev/null 2>&1
)
result="$(
    load_answers_file "$WORK/machine-roundtrip.yml" >/dev/null 2>&1
    printf '%s|%s|%s' "${ANSWER_VALUES[0]}" "${ANSWER_VALUES[1]}" "${SELECTED_CAPABILITIES[*]}"
)"
assert_eq "a written machine file is a valid --answers file" \
    "rt@example.com|zed|alpha zzz-last" "$result"

# ── 16. offer_restore / offer_backup ─────────────────────────────────────────
# Runs only on a genuinely fresh machine; each guard below is a way it could
# wrongly fire and hijack a working setup.
echo "==> bootstrap machine restore"

# A real bare repo with one backup in it, so `names` and `pull` are exercised
# for real rather than stubbed.
RBACKUP="$WORK/restore"; mkdir -p "$RBACKUP/cfg"
# -b main: the push below targets main, and a bare repo's HEAD follows
# init.defaultBranch, so on a host that defaults to master the clone gets nothing.
git init -q -b main --bare "$RBACKUP/remote.git"
git init -q -b main "$RBACKUP/seed"
(
    cd "$RBACKUP/seed"
    mkdir -p machines
    cp "$REPO_ROOT/tests/fixtures/machine.yml" machines/beta.yml
    git add -A
    git -c user.email=t@t -c user.name=t commit -qm init
    git push -q "$RBACKUP/remote.git" HEAD:main
)
printf -- '---\nrepo: "%s"\nmachine: "here"\n' "$RBACKUP/remote.git" > "$RBACKUP/cfg/backup.yml"

run_restore() {
    (
        INTERACTIVE="${2:-1}"
        ANSWERS_FILE="${3:-}"
        CONFIG_DIR="$RBACKUP/cfg"
        BACKUP_CONFIG="$RBACKUP/cfg/backup.yml"
        BACKUP_REPO_DIR="$RBACKUP/clone-$RANDOM"
        MACHINE_FILE="${4:-$WORK/restored-$RANDOM.yml}"
        offer_restore < "$1" >/dev/null 2>&1
        printf '%s' "$ANSWERS_FILE"
    )
}

# The fresh-machine path: no checkout (SCRIPT_DIR empty), so the helper is
# downloaded. file:// stands in for raw.githubusercontent.com.
#   $1 raw base URL; prints "<rc>|<ANSWERS_FILE set?>|<leftover temp files>|<output>"
run_restore_download() {
    mkdir -p "$WORK/dl-tmp"
    (
        INTERACTIVE=1
        ANSWERS_FILE=""
        SCRIPT_DIR=""
        RAW_BASE="$1"
        TMPDIR="$WORK/dl-tmp"
        BACKUP_CONFIG="$RBACKUP/cfg/backup.yml"
        BACKUP_REPO_DIR="$RBACKUP/clone-$RANDOM"
        MACHINE_FILE="$WORK/restored-$RANDOM.yml"
        offer_restore < "$WORK/pick-1" > "$WORK/dl-out" 2>&1; rc=$?
        printf '%s|%s|%s|%s' "$rc" "${ANSWERS_FILE:+set}" \
            "$(find "$WORK/dl-tmp" -type f | wc -l | tr -d ' ')" "$(<"$WORK/dl-out")"
    )
}

printf '1\n' > "$WORK/pick-1"
printf '0\n' > "$WORK/pick-0"

got="$(run_restore "$WORK/pick-1")"
if [[ -n "$got" && -f "$got" ]]; then
    pass "choosing a backup sets ANSWERS_FILE to the fetched declaration"
    assert_eq "  the restored file carries the layers" "2" \
        "$(yq -r '.layers | length' "$got" 2>/dev/null)"
    assert_eq "  and is private" "600" "$(file_mode "$got")"
else
    fail "choosing a backup sets ANSWERS_FILE to the fetched declaration" "got [$got]"
fi

assert_eq "choosing 0 starts fresh and sets no answers file" "" \
    "$(run_restore "$WORK/pick-0")"

# Guards. Each must return WITHOUT consuming the answer file, so a stray prompt
# here would show up as a restore that should never have been offered.
assert_eq "a non-interactive run is never offered a restore" "" \
    "$(run_restore "$WORK/pick-1" 0)"
assert_eq "--answers wins over a restore prompt" "supplied.yml" \
    "$(run_restore "$WORK/pick-1" 1 "supplied.yml")"

printf -- '---\nlayers: []\n' > "$WORK/already.yml"
assert_eq "an already-declared machine is not offered a restore" "" \
    "$(run_restore "$WORK/pick-1" 1 "" "$WORK/already.yml")"

# pick-1 is defined above the guards; `run_restore_download` reads it too.
got="$(run_restore_download "file://$REPO_ROOT")"
dl_rc="${got%%|*}"; got="${got#*|}"; dl_set="${got%%|*}"; got="${got#*|}"
dl_tmp="${got%%|*}"; dl_out="${got#*|}"
assert_eq "a downloaded helper restores and leaves no temp file behind" "0|set|0" "$dl_rc|$dl_set|$dl_tmp"
got="$(run_restore_download "file://$WORK/no-such-raw-base")"
dl_rc="${got%%|*}"; got="${got#*|}"; dl_set="${got%%|*}"; got="${got#*|}"
dl_tmp="${got%%|*}"; dl_out="${got#*|}"
assert_eq "an undownloadable helper warns and continues, never fails" "0||0|warned" \
    "$dl_rc|$dl_set|$dl_tmp|$([[ "$dl_out" == *"Could not read the machine backup repo"* ]] && echo warned || echo "$dl_out")"

# ─── Where bootstrap thinks it is running from ───────────────────────────────
# Under `curl | bash` no directory may be trusted (architecture.md, "Bootstrap internals").
assert_eq "a real checkout is trusted" "$REPO_ROOT" \
    "$(resolve_script_dir "$REPO_ROOT/bootstrap.sh")"

# The two invocations with no file behind them. Both must yield nothing, so
# every consumer downloads what it needs instead of reading a stranger's copy.
assert_eq "curl | bash trusts no directory" "" "$(resolve_script_dir "")"
assert_eq "bash <(curl ...) trusts no directory" "" \
    "$(resolve_script_dir "/dev/fd/63")"

# The case that motivated it: a decoy $PWD carrying both marker files. Piping
# from here must still refuse, because nothing was passed to verify.
DECOY="$WORK/decoy"
mkdir -p "$DECOY/scripts"
touch "$DECOY/local.yml" "$DECOY/scripts/computer-setup-layers" "$DECOY/requirements.yml"
assert_eq "a lookalike \$PWD is not adopted when piped" "" \
    "$(cd "$DECOY" && resolve_script_dir "")"

# A directory missing either marker is not a checkout, however suggestive.
HALF="$WORK/half"
mkdir -p "$HALF/scripts"
touch "$HALF/scripts/computer-setup-layers"
assert_eq "a directory without local.yml is not a checkout" "" \
    "$(resolve_script_dir "$HALF/bootstrap.sh")"

# ─── Running a fork ──────────────────────────────────────────────────────────
# BOOTSTRAP_OWNER must move the clone URL, the raw-download base and the branch
# together; a half-applied override would clone one repo and fetch from another.
echo "==> bootstrap owner override"
fork="$(BOOTSTRAP_OWNER=acme BOOTSTRAP_BRANCH=v9 bash -c 'source "$1"; printf "%s|%s" "$REPO_URL" "$RAW_BASE"' _ "$REPO_ROOT/bootstrap.sh")"
assert_eq "a fork owner and ref reach every URL" \
    "git@github.com:acme/computer-setup.git|https://raw.githubusercontent.com/acme/computer-setup/v9" "$fork"
# shellcheck disable=SC2016 # the single-quoted program is for the inner bash, which expands it
dflt="$(env -u BOOTSTRAP_OWNER -u BOOTSTRAP_BRANCH bash -c 'source "$1"; printf "%s" "$REPO_URL"' _ "$REPO_ROOT/bootstrap.sh")"
assert_eq "no override keeps the default owner" "git@github.com:mauro-lanza/computer-setup.git" "$dflt"
# The value must also reach the play, or the scheduled agents would keep following the original repo.
# shellcheck disable=SC2016 # a literal pattern: the ${...} must NOT expand here
if grep -qF -- '-e "computer_setup_repo_url=${REPO_URL}"' "$REPO_ROOT/bootstrap.sh"; then
    pass "the repo URL is passed to the play"
else
    fail "the repo URL is passed to the play" "extra_args lost computer_setup_repo_url"
fi

echo
if [[ "$FAILURES" -gt 0 ]]; then
    echo "bootstrap prompt tests: ${FAILURES} failure(s)" >&2
    exit 1
fi
echo "bootstrap prompt tests passed"

#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Bash syntax"
bash -n bootstrap.sh
bash -n scripts/computer-setup-layers
bash -n tests/bootstrap-prompts.sh

# `bash -n` only proves the file parses. shellcheck is the actual gate for the
# ~1,900 lines of bash here, and a FAILURE when absent for the same reason
# ansible-lint is: a fresh machine is where the tool is missing and where
# "passed" has to mean it. Findings are waived inline, at the line, with a
# reason — never globally.
echo "==> shellcheck"
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "ERROR: shellcheck is not installed, so this gate cannot run." >&2
    echo "       Install it:  brew install shellcheck" >&2
    echo "       (it is also the 'shellcheck' capability in the public layer)" >&2
    exit 1
fi
shellcheck -S style -x bootstrap.sh scripts/computer-setup-layers scripts/check.sh \
    tests/bootstrap-prompts.sh
echo "  ok  no findings"

# `bash -n` proves bootstrap.sh parses, not that the prompt loop works — and
# that loop only runs on a fresh machine, where nobody is watching it fail.
# These drive it with scripted answers.
echo "==> Bootstrap prompt behaviour"
./tests/bootstrap-prompts.sh

# Templated shell only becomes shell after rendering, so a broken runner would
# first surface inside a LaunchAgent at 09:00. De-template and check the skeleton.
echo "==> Templated script syntax"
# Templated scripts cannot be linted in place — Jinja is not shell. De-template
# first (placeholders for {{ }}, drop {% %} lines), then parse AND shellcheck.
# Every templated script is bash now, which is the point: shellcheck has no zsh
# mode, so a zsh template would be parse-checked only.
check_template_syntax() {
    local src="$1" shell="$2" tmp
    tmp="$(mktemp)"
    sed -e 's/{{[^}]*}}/PLACEHOLDER/g' -e '/{%.*%}/d' "$src" > "$tmp"
    if ! "$shell" -n "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: $src does not parse as $shell after de-templating" >&2
        return 1
    fi
    if [[ "$shell" == "bash" ]] && ! shellcheck -S style -s bash "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: $src has shellcheck findings after de-templating" >&2
        return 1
    fi
    rm -f "$tmp"
    echo "  ok  $src"
}
check_template_syntax roles/drift_correction/templates/computer-setup.j2 bash
check_template_syntax roles/macos/templates/macos-capture.sh.j2 bash

# The sed above cannot see a template Jinja itself refuses to parse — and the
# syntaxes collide: `${#arr[@]}` contains Jinja's comment-open `{#`. Parse each
# template with the same Jinja2 Ansible uses.
echo "==> Template parses as Jinja"
# Ansible's own interpreter: the only one guaranteed to have Jinja2 installed.
CS_PY="$(head -1 "$(command -v ansible)" | sed 's/^#!//')"
[[ -x "$CS_PY" ]] || CS_PY=python3
"$CS_PY" - <<'PY'
import sys, pathlib
from jinja2 import Environment
env = Environment()
rc = 0
for p in sorted(pathlib.Path("roles").glob("*/templates/*.j2")):
    try:
        env.parse(p.read_text())
        print(f"  ok  {p}")
    except Exception as e:
        print(f"  ERROR: {p}: {e}", file=sys.stderr)
        rc = 1
sys.exit(rc)
PY

# The callback plugin is the only Python here, and it runs inside every single
# ansible-pull — including the unattended ones. A syntax error in it would first
# surface at 09:00 inside a LaunchAgent. Compiled with ANSIBLE's interpreter,
# which is the one that will actually import it.
echo "==> Callback plugin"
"$CS_PY" -m py_compile callback_plugins/computer_setup_state.py
"$CS_PY" - <<'PY'
import sys
sys.path.insert(0, "callback_plugins")
import computer_setup_state as m

cb = m.CallbackModule
assert cb.CALLBACK_TYPE == "aggregate", "must not replace the stdout callback"
assert cb.CALLBACK_NAME == "computer_setup_state", "name must match the filename"
assert cb.CALLBACK_NEEDS_ENABLED is True, "must be opt-in via callbacks_enabled"
assert isinstance(m.STATE_SCHEMA_VERSION, int)
print("  ok  aggregate, opt-in, schema_version =", m.STATE_SCHEMA_VERSION)
PY

echo "==> Ansible syntax"
ansible-playbook --syntax-check local.yml
ANSIBLE_ROLES_PATH="$PWD/roles" ansible-playbook --syntax-check tests/contract.yml

echo "==> Inventory"
ansible-inventory --list >/dev/null

echo "==> Tags"
ansible-playbook --list-tags local.yml >/dev/null

echo "==> Default task graph"
ansible-playbook --list-tasks local.yml >/dev/null

echo "==> Repository task graph"
ansible-playbook --list-tasks --tags repositories local.yml >/dev/null

echo "==> Upgrade task graph"
ansible-playbook --list-tasks --tags upgrade local.yml >/dev/null

echo "==> Layer contract"
ANSIBLE_ROLES_PATH="$PWD/roles" ansible-playbook tests/contract.yml >/dev/null

# The state file is a CONSUMED INTERFACE: `computer-setup status` reads it, and
# a UI would too. Assert its shape, and — the point of the whole design — that
# no file CONTENT reaches it. Ansible's diffs carry before/after payloads; the
# plugin must record only task, action and dest.
echo "==> Run state contract"
cs_state="$(mktemp -d)/last-run.json"
CS_STATE_FILE="$cs_state" CS_RUN_MODE=check \
    ansible-playbook tests/state.yml --check --diff >/dev/null
if [[ ! -f "$cs_state" ]]; then
    echo "ERROR: the callback plugin wrote no state file" >&2
    exit 1
fi
"$CS_PY" - "$cs_state" <<'PY'
import json, sys, stat, os

path = sys.argv[1]
raw = open(path).read()
d = json.loads(raw)

# The canary from tests/state.yml. If this ever appears, the plugin started
# recording diff payloads and is now leaking managed file contents to disk.
assert "CANARY-DO-NOT-RECORD-a3f9" not in raw, "FILE CONTENT LEAKED INTO STATE FILE"
for banned in ("before", "after", "before_header", "after_header", "stdout"):
    assert banned not in raw, f"state file carries a {banned!r} payload"

assert d["schema_version"] == 1, d["schema_version"]
assert d["mode"] == "check", d["mode"]
assert d["result"] == "ok", d["result"]
assert d["totals"]["changed"] == 1, d["totals"]
assert d["truncated"] is False
assert d["partial"] is False, "a full run must not be marked partial"
entry = d["changed"][0]
assert entry["task"] == "A task that would change a file", entry
assert entry["dest"].endswith("cs-state-contract.txt"), entry
assert entry["action"] == "ansible.builtin.copy", entry

# 0600: it describes this machine's files.
mode = stat.S_IMODE(os.stat(path).st_mode)
assert mode == 0o600, oct(mode)
print("  ok  shape, 0600, and no file contents recorded")
PY
rm -rf "$(dirname "$cs_state")"

# A guard whose expression always evaluates false looks exactly like a passing
# suite. Assert the run FAILS, and for the right reason.
echo "==> Layer contract (negative paths)"
expect_layer_failure() {
    local case="$1" expect="$2" out
    out="$(ANSIBLE_ROLES_PATH="$PWD/roles" ansible-playbook tests/negative.yml \
        -e computer_setup_layer_cache="$PWD/tests/fixtures/negative/$case/layers_cache" \
        -e computer_setup_layers_manifest="$PWD/tests/fixtures/negative/$case/layers.yml" 2>&1)" && {
        echo "ERROR: negative case '$case' was ACCEPTED — the guard is not enforcing" >&2
        return 1
    }
    if ! grep -q "$expect" <<<"$out"; then
        echo "ERROR: negative case '$case' failed, but not for the expected reason" >&2
        echo "       expected to find: $expect" >&2
        return 1
    fi
    echo "  ok  $case rejected"
}
expect_layer_failure reserved "defines reserved key"
expect_layer_failure schema "requires schema_version 99"
# Reserved by PREFIX, not by name: the runner loads this key at extra-vars
# precedence on every unattended run.
expect_layer_failure prefix "defines reserved key"
# Ansible's execution controls are reserved as a NAMESPACE. Enumerating five of
# them left ansible_become_password and ansible_ssh_common_args reachable.
expect_layer_failure ansible-prefix "defines reserved key"
# Must fail ATTRIBUTED to the layer: a mis-shaped `capabilities:` key aborts
# pre_tasks, which every entry point runs.
expect_layer_failure capabilities "malformed capabilities.yml"

# A question's `set:` payload lands in play scope exactly as a layer var does,
# so it is an escalation path AROUND the reserved-key guard unless it clears the
# same one. Assert a layer cannot reach the orchestrator's own repo URL through
# a question.
expect_layer_failure question "question setting reserved key"

# The machine tier widens what a QUESTION may set. It must not widen what a
# layer var may set, or the tier becomes a hole rather than a door.
expect_layer_failure machine-tier "defines reserved key"

# Capabilities, questions and presets refer to each other by id, and every one of
# those references fails SILENTLY when wrong — a preset naming a capability that
# does not exist just selects nothing. The linter makes them loud.
echo "==> Layer lint (reference layer)"
./scripts/computer-setup-layers lint --layer examples/example-layer

# ...and it has to actually reject. Same standard as the negative layer contract
# cases: a linter that cannot fail looks exactly like a clean layer.
echo "==> Layer lint (negative)"
lint_out="$(./scripts/computer-setup-layers lint --cache "$PWD/tests/fixtures/lint" 2>&1)" && {
    echo "ERROR: the broken lint fixture was ACCEPTED — the linter is not enforcing" >&2
    exit 1
}
for expect in \
    "capability id declared twice" \
    "capability requires 'nonexistent'" \
    "is type: extension but declares no manager" \
    "preset selects capability 'does-not-exist'" \
    "preset answers question 'no-such-question'" \
    "question implies capability 'ghost-capability'" \
    "names a tapped package but declares no tap" \
    "has a config: entry missing src: or dest:" \
    "config: uses mode:" \
    "config: has a non-boolean executable:"
do
    if ! grep -qF "$expect" <<<"$lint_out"; then
        echo "ERROR: linter did not report: $expect" >&2
        exit 1
    fi
done
echo "  ok  all 10 broken references rejected"

# The highest supported layer schema_version is stated in three places that
# cannot import from each other: bootstrap.sh runs before any checkout exists
# under `curl | bash`, and the sync helper is deployed standalone. Duplication
# is therefore forced — but disagreement is not. A bump that updates only one
# would let bootstrap accept a layer the engine then rejects, on a fresh machine,
# mid-provision. Assert them equal instead of documenting that they should be.
echo "==> Schema version agreement"
sv_bootstrap="$(sed -n 's/^SCHEMA_VERSION_MAX=\([0-9]*\)$/\1/p' bootstrap.sh)"
sv_playbook="$(yq -r '.[0].vars.computer_setup_schema_version' local.yml)"
sv_sync="$(sed -n 's/.*schema_version_max=\([0-9]*\)$/\1/p' scripts/computer-setup-layers)"
if [[ -z "$sv_bootstrap" || -z "$sv_playbook" || -z "$sv_sync" ]]; then
    echo "ERROR: could not read the schema version from all three sources" >&2
    echo "       bootstrap.sh='$sv_bootstrap' local.yml='$sv_playbook' sync='$sv_sync'" >&2
    exit 1
fi
# Not the "always true" pattern SC2055 targets: this compares ONE variable
# against TWO others, so it is false exactly when all three agree.
# shellcheck disable=SC2055
if [[ "$sv_bootstrap" != "$sv_playbook" || "$sv_bootstrap" != "$sv_sync" ]]; then
    echo "ERROR: schema version disagreement" >&2
    echo "       bootstrap.sh SCHEMA_VERSION_MAX      = $sv_bootstrap" >&2
    echo "       local.yml computer_setup_schema_version = $sv_playbook" >&2
    echo "       scripts/computer-setup-layers default = $sv_sync" >&2
    exit 1
fi
echo "  ok  all three agree on schema_version $sv_bootstrap"

# A gate, not an advisory: .ansible-lint waives the two rules that contradict
# this architecture, so any finding is real. Missing ansible-lint is a FAILURE —
# a fresh machine is where the tool is absent and where "passed" must mean it.
echo "==> ansible-lint"
if ! command -v ansible-lint >/dev/null 2>&1; then
    echo "ERROR: ansible-lint is not installed, so this gate cannot run." >&2
    echo "       Install it:  brew install ansible-lint" >&2
    echo "       (it is also the 'ansible-lint' capability in the public layer)" >&2
    exit 1
fi
ansible-lint -q
echo "  ok  no findings"

echo "Checks passed"

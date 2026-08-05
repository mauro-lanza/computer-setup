#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Bash syntax"
bash -n bootstrap.sh
bash -n scripts/computer-setup-layers
bash -n tests/bootstrap-prompts.sh

# `bash -n` proves bootstrap.sh parses, not that the prompt loop works — and
# that loop only runs on a fresh machine, where nobody is watching it fail.
# These drive it with scripted answers.
echo "==> Bootstrap prompt behaviour"
./tests/bootstrap-prompts.sh

# Templated shell only becomes shell after rendering, so a broken runner would
# first surface inside a LaunchAgent at 09:00. De-template and check the skeleton.
echo "==> Templated script syntax"
check_template_syntax() {
    local src="$1" shell="$2" tmp
    tmp="$(mktemp)"
    sed -e 's/{{[^}]*}}/PLACEHOLDER/g' -e '/{%.*%}/d' "$src" > "$tmp"
    if ! "$shell" -n "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: $src does not parse as $shell after de-templating" >&2
        return 1
    fi
    rm -f "$tmp"
    echo "  ok  $src"
}
check_template_syntax roles/drift_correction/templates/computer-setup-run.sh.j2 zsh
check_template_syntax roles/shell/templates/computer-setup-cli.zsh.j2 zsh
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

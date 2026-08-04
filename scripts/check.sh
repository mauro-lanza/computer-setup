#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Bash syntax"
bash -n bootstrap.sh
bash -n scripts/computer-setup-layers
bash -n scripts/managers
bash -n tests/bootstrap-prompts.sh

# `bash -n` proves bootstrap.sh PARSES; it proves nothing about what the prompt
# loop DOES. That loop only ever runs on a fresh machine, which is precisely
# where it cannot be observed failing — it shipped two bugs that made a
# from-scratch install select zero optional tools, silently. These tests drive
# the loop with scripted answers so the selection path has actual coverage.
echo "==> Bootstrap prompt behaviour"
./tests/bootstrap-prompts.sh

# Shell scripts shipped as Jinja templates are never syntax-checked by the line
# above — they only become shell after templating. A broken edit to the runner
# would deploy to ~/.local/bin and first surface inside a LaunchAgent at 09:00
# the next morning. Strip the Jinja and check the shell skeleton: substitute
# {{ ... }} with a placeholder token and drop {% ... %} control lines.
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

# The de-templating above strips Jinja with sed, so it cannot see a template that
# Jinja itself refuses to PARSE. That is a real hazard in shell templates because
# the syntaxes collide: `${#arr[@]}` contains `{#`, Jinja's comment-open — a
# perfectly good bash line that makes the whole template unrenderable. The role
# then fails at deploy time on a real machine (and only on the code path that
# renders it), long after the checks went green. Parse each template with the
# same Jinja2 that Ansible uses.
echo "==> Template parses as Jinja"
# Use the interpreter Ansible itself runs on — that is the Jinja2 that will
# actually render these templates, and the only one guaranteed to have it
# installed (system python3 on macOS does not).
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

echo "==> Manager registry"
./scripts/managers check

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

# Negative paths. These guards are documented as guarantees, so a silently
# degraded one (an expression that always evaluates false) must not look like a
# pass. Assert the run FAILS, and that it fails for the right reason.
echo "==> Layer contract (negative paths)"
expect_layer_failure() {
    local case="$1" expect="$2" out
    out="$(ANSIBLE_ROLES_PATH="$PWD/roles" ansible-playbook tests/negative.yml \
        -e computer_setup_plugin_cache="$PWD/tests/fixtures/negative/$case/plugins" \
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
# Reserved by PREFIX, not by name. The name list previously missed six
# drift_correction_* keys that the role defines — including the one below, which
# the runner loads at extra-vars precedence on every unattended run.
expect_layer_failure prefix "defines reserved key"
# A malformed capabilities.yml must fail ATTRIBUTED to the layer. A null or
# mis-shaped `capabilities:` key used to abort pre_tasks — i.e. bootstrap,
# drift-check, drift-apply and both LaunchAgents — on a bare Jinja error.
expect_layer_failure capabilities "malformed capabilities.yml"

# ansible-lint was documented in CONTRIBUTING as a pre-PR step but lived outside
# this script, so it drifted to 23 standing failures and stopped being read.
# It is a gate now: .ansible-lint records the two rules waived on architectural
# grounds, so a non-zero exit means something real.
echo "==> ansible-lint"
if command -v ansible-lint >/dev/null 2>&1; then
    ansible-lint -q
    echo "  ok  no findings"
else
    echo "  skip  ansible-lint not installed (brew install ansible-lint)"
fi

echo "Checks passed"

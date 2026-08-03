#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Bash syntax"
bash -n bootstrap.sh
bash -n scripts/computer-setup-layers
bash -n scripts/managers

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

echo "Checks passed"

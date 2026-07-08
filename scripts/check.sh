#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Bash syntax"
bash -n bootstrap.sh

echo "==> Ansible syntax"
ansible-playbook --syntax-check local.yml

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

echo "Checks passed"

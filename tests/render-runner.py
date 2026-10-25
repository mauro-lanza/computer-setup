#!/usr/bin/env python3
"""Render the runner template the way Ansible does, against one platform profile.

    render-runner.py PLATFORM SCRATCH_DIR OUT [LAYER_CACHE]

Used by tests/runner.sh (the host's platform) and check.sh (every platform), so
each platform's real output is what gets tested, not a de-templated skeleton.
Run with Ansible's interpreter, which has jinja2 and PyYAML.
"""
import os
import shlex
import sys

import jinja2
import yaml

platform, t, out = sys.argv[1], sys.argv[2], sys.argv[3]
layer_cache = sys.argv[4] if len(sys.argv) > 4 else ""
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

with open(os.path.join(root, "roles/core/vars/platform", platform + ".yml")) as f:
    profile = yaml.safe_load(f)["computer_setup_platform"]

# Ansible renders templates with trim_blocks, and provides `quote`.
env = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True, trim_blocks=True)
env.filters["expanduser"] = os.path.expanduser
env.filters["quote"] = shlex.quote
v = dict(
    computer_setup_repo_url="git@example.invalid:o/r.git", computer_setup_repo_branch="main",
    computer_setup_machine_file=t + "/none.yml", computer_setup_layer_cache=layer_cache,
    computer_setup_log_dir=t + "/logs", computer_setup_state_dir=t + "/state",
    computer_setup_config_dir=t + "/config", computer_setup_backup_repo_dir=t + "/backups",
    computer_setup_runtime_bin=t + "/bin", computer_setup_runtime_tools=t + "/tools",
    computer_setup_python_version="3.14", computer_setup_pull_dir=t + "/pull",
    computer_setup_bin_dir=t + "/bin", computer_setup_schema_version=1,
    drift_correction_log_retention_days=30, drift_correction_stale_after_days=14,
    drift_correction_connectivity_timeout=1, computer_setup_repositories_override_file=t + "/repositories.yml",
    repositories_base_dir=t + "/repos",
    computer_setup_platform=profile,
)
with open(os.path.join(root, "roles/drift_correction/templates/computer-setup.j2")) as f:
    rendered = env.from_string(f.read()).render(**v)
with open(out, "w") as f:
    f.write(rendered)
os.chmod(out, 0o755)

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
# `computer-setup prefs` is git plumbing that only ever runs by hand, which is
# where bit-rot hides. Driven against a LOCAL bare repo — no network, no gh, no
# GitHub account — so the gate works on a fresh machine and in CI. `init` is the
# only subcommand not covered: it is the one that needs an authenticated gh.
# Two roles declaring the SAME directory with DIFFERENT modes is invisible until
# it ships: one role sets the mode, the other reports drift on it, forever. That
# is exactly what happened to ~/.local/state/computer-setup -- 0755 from the
# 09:00 upgrade, 0700 from the 10:00 check, drifting daily for a week before
# `computer-setup status` named the task and made it obvious.
#
# Textual, so it only catches divergence when both spell the path the same way.
# That is the point: writing one directory as two expressions (the original bug
# aliased it through `| dirname`) is itself the thing to avoid.
echo "==> Directory mode agreement"
"$CS_PY" - <<'CSPY'
import re, pathlib, collections, sys

decls = collections.defaultdict(set)
for f in sorted(pathlib.Path("roles").glob("*/tasks/*.yml")):
    for m in re.finditer(
        r'path:\s*"([^"]+)"\s*\n\s*state:\s*directory\s*\n\s*mode:\s*"([0-7]{4})"',
        f.read_text(),
    ):
        decls[m.group(1)].add((m.group(2), str(f)))

rc = 0
for path, entries in sorted(decls.items()):
    if len({mode for mode, _ in entries}) > 1:
        rc = 1
        print("ERROR: %s is declared with conflicting modes:" % path, file=sys.stderr)
        for mode, f in sorted(entries):
            print("         %s  %s" % (mode, f), file=sys.stderr)
if rc:
    sys.exit(rc)
print("  ok  %d managed directories, no conflicting modes" % len(decls))
CSPY

# `computer-setup-machine` is git plumbing that only runs by hand or on a fresh
# machine, which is where bit-rot hides. Driven against a LOCAL bare repo — no
# network, no gh, no GitHub account — so the gate works on a fresh machine and
# in CI. `init` is the only subcommand not covered: it needs an authenticated gh.
echo "==> Machine backup round-trip"
cs_m_tmp="$(mktemp -d)"
mkdir -p "$cs_m_tmp/cfg"
git init -q --bare "$cs_m_tmp/remote.git"
git init -q "$cs_m_tmp/seed"
(
    cd "$cs_m_tmp/seed"
    echo "# state" > README.md
    git add -A
    git -c user.email=t@t -c user.name=t commit -qm init
    git push -q "$cs_m_tmp/remote.git" HEAD:main
)
cp tests/fixtures/machine.yml "$cs_m_tmp/cfg/machine.yml"
printf -- '---\nrepo: "%s"\nmachine: "alpha"\n' "$cs_m_tmp/remote.git" > "$cs_m_tmp/cfg/backup.yml"
# Flags only — the SUBCOMMAND has to come first on the real command line.
cs_m_flags=(--config "$cs_m_tmp/cfg/backup.yml"
            --repo-dir "$cs_m_tmp/clone"
            --machine-file "$cs_m_tmp/cfg/machine.yml")
cs_m() { scripts/computer-setup-machine "$@" "${cs_m_flags[@]}"; }

# An unconfigured machine must say so, not traceback.
if scripts/computer-setup-machine push --config "$cs_m_tmp/nope.yml" \
        --repo-dir "$cs_m_tmp/clone" \
        --machine-file "$cs_m_tmp/cfg/machine.yml" >/dev/null 2>&1; then
    echo "ERROR: push succeeded without configuration" >&2
    exit 1
fi

# Captured into variables rather than piped into `grep -q`. `grep -q` exits the
# moment it matches, SIGPIPE-ing the still-writing producer (141), and this
# script runs `set -o pipefail` — so a PASSING assertion fails the build,
# racily. Cost an afternoon; do not reintroduce the pipe.
cs_m push >/dev/null
cs_m_out="$(cs_m push)"
[[ "$cs_m_out" == *"Already up to date"* ]] || {
    echo "ERROR: a second push was not a no-op: $cs_m_out" >&2; exit 1; }
cs_m_out="$(cs_m list)"
[[ "$cs_m_out" == *"alpha"* ]] || {
    echo "ERROR: pushed machine missing from list: $cs_m_out" >&2; exit 1; }

# `names` is what bootstrap builds its restore menu from: one bare name per
# line, nothing else. A stray log line here becomes a menu entry there.
cs_m_out="$(cs_m names)"
[[ "$cs_m_out" == "alpha" ]] || {
    echo "ERROR: names emitted more than the bare name: [$cs_m_out]" >&2; exit 1; }

cs_m pull alpha "$cs_m_tmp/out.yml" >/dev/null

# The whole premise: a pulled backup is a valid `--answers` file, layers and
# all. If this stops being true, restoring a machine silently produces a
# DIFFERENT machine.
diff -q tests/fixtures/machine.yml "$cs_m_tmp/out.yml" >/dev/null || {
    echo "ERROR: pulled backup does not match the pushed declaration" >&2; exit 1; }
for cs_m_key in '.layers[]?' '.selected_capabilities[]?' '.answers'; do
    yq -r "$cs_m_key" "$cs_m_tmp/out.yml" >/dev/null || {
        echo "ERROR: pulled backup does not parse ($cs_m_key)" >&2; exit 1; }
done
[[ "$(yq -r '.layers | length' "$cs_m_tmp/out.yml")" -gt 0 ]] || {
    echo "ERROR: restored declaration carries no layers" >&2; exit 1; }

# Never clobber: a bad restore must always be recoverable.
if cs_m pull alpha "$cs_m_tmp/out.yml" >/dev/null 2>&1; then
    echo "ERROR: pull overwrote an existing file" >&2
    exit 1
fi
if cs_m pull nonexistent "$cs_m_tmp/x.yml" >/dev/null 2>&1; then
    echo "ERROR: pull accepted an unknown machine name" >&2
    exit 1
fi
rm -rf "$cs_m_tmp"
echo "  ok  push, idempotent re-push, list, names, pull, and both refusals"

echo "==> Run state contract"
rm -f /tmp/cs-state-contract-template.txt /tmp/cs-state-contract-loop-a.txt /tmp/cs-state-contract-loop-b.txt
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
assert d["truncated"] is False
assert d["partial"] is False, "a full run must not be marked partial"

# Ansible's temp render dir. A template's diff `after_header` points here, so
# recording it yields a path that does not survive the run. Shipped once.
assert "ansible-local-" not in raw, "a temporary render path was recorded as dest"

# Every changed entry resolves to the REAL destination: a plain copy, a
# template (dest must not be the temp .j2), and a loop CREATING files, whose
# paths exist neither in the task args (unrendered) nor in a diff header
# (nothing to diff against). One entry per item, not one per task.
by_dest = {e.get("dest"): e for e in d["changed"]}
for expected in (
    "/tmp/cs-state-contract.txt",
    "/tmp/cs-state-contract-template.txt",
    "/tmp/cs-state-contract-loop-a.txt",
    "/tmp/cs-state-contract-loop-b.txt",
):
    assert expected in by_dest, f"{expected} missing from {sorted(by_dest)}"
assert d["totals"]["changed"] == 4, d["totals"]
assert len(d["changed"]) == 6, "a looped task must contribute one entry per item"

# A looped task with no path must still say WHICH item, via the loop label.
# Two missing credentials would otherwise be two identical lines.
by_item = {e.get("item"): e for e in d["changed"] if "item" in e}
for expected in ("alpha-item", "beta-item"):
    assert expected in by_item, f"{expected} missing; got {sorted(by_item)}"
assert "dest" not in by_item["alpha-item"], "item and dest should not both be set"
assert by_dest["/tmp/cs-state-contract.txt"]["action"] == "ansible.builtin.copy"

# Bare task name: `get_name()` would return "role : name", duplicating `role`
# and making every consumer strip a prefix to display one.
for e in d["changed"]:
    assert " : " not in e["task"], f"task name carries a role prefix: {e}"
assert isinstance(d["duration_seconds"], float), d.get("duration_seconds")

# 0600: it describes this machine's files.
mode = stat.S_IMODE(os.stat(path).st_mode)
assert mode == 0o600, oct(mode)
print("  ok  shape, 0600, and no file contents recorded")
PY
rm -rf "$(dirname "$cs_state")"

# The manifest is the basis for deciding a path is no longer managed, so what it
# OMITS matters as much as what it lists. Each omission below is deliberate and
# would be invisible if it regressed.
echo "==> Manifest contract"
cs_mdir="$(mktemp -d)"
cs_mscratch=/tmp/cs-manifest-contract
rm -rf -- "$cs_mscratch"
CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" CS_HISTORY_FILE="$cs_mdir/history.jsonl" \
    CS_RUN_MODE=apply CS_RUN_PARTIAL=0 CS_RUN_ID=contract-1 \
    ansible-playbook tests/manifest.yml >/dev/null
# A second run with the SAME run id: ansible-pull can reach the callback's final
# hook more than once per invocation, and history is appended, so without a key
# one run would leave two lines.
CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" CS_HISTORY_FILE="$cs_mdir/history.jsonl" \
    CS_RUN_MODE=apply CS_RUN_PARTIAL=0 CS_RUN_ID=contract-1 \
    ansible-playbook tests/manifest.yml >/dev/null
# A third, with a new id and narrowed — the shape of a `--tags` run.
CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" CS_HISTORY_FILE="$cs_mdir/history.jsonl" \
    CS_RUN_MODE=check CS_RUN_PARTIAL=1 CS_RUN_ID=contract-2 \
    ansible-playbook tests/manifest.yml >/dev/null
"$CS_PY" - "$cs_mdir" <<'PY'
import json, os, stat, sys

d = os.path.abspath(sys.argv[1])
m = json.load(open(os.path.join(d, "managed-paths.json")))
base = "/tmp/cs-manifest-contract"

assert m["schema_version"] == 1, m["schema_version"]
files = {e["path"] for e in m["files"]}
dirs = {e["path"] for e in m["directories"]}
backups = {e["path"] for e in m["backups"]}

# An inventory is a STATE: the third run changed nothing, and every managed file
# must still be listed. A manifest that empties itself on a converged machine
# would be useless exactly when it matters.
for expected in (f"{base}/managed.conf", f"{base}/looped-a.conf", f"{base}/looped-b.conf"):
    assert expected in files, f"{expected} missing from {sorted(files)}"
assert base in dirs, f"{base} missing from {sorted(dirs)}"
assert base not in files and f"{base}/managed.conf" not in dirs, "file/directory confusion"

# A loop's rendered per-item path, not the bare `item.dest` filename.
assert all(p.startswith("/") for p in files), f"relative path recorded: {sorted(files)}"

# Recording a removal has a collection step re-deleting what it just deleted.
assert f"{base}/removed.conf" not in files | dirs, "a `state: absent` path entered the manifest"

# A skipped task no longer manages its path — that is the signal collection
# needs, so it must NOT appear.
assert f"{base}/skipped.conf" not in files, "a skipped task's path entered the manifest"

# The known blind spot, asserted so it stays known rather than being rediscovered.
assert f"{base}/invisible.txt" not in files, "command side effects are not knowable here"

# `backup: true` residue: named by the module, never removed by anything else.
assert len(backups) == 1, f"expected one backup, got {sorted(backups)}"
assert next(iter(backups)).startswith(f"{base}/managed.conf."), sorted(backups)
assert not (backups & files), "a backup must not also be listed as a live file"

# The one field a collection step may act on. The last run was PARTIAL.
assert m["partial"] is True, m["partial"]
assert m["complete"] is False, "a partial run must never be marked complete"

mode = stat.S_IMODE(os.stat(os.path.join(d, "managed-paths.json")).st_mode)
assert mode == 0o600, oct(mode)

# History: appended, one line per RUN and not per play.
lines = [l for l in open(os.path.join(d, "history.jsonl")).read().splitlines() if l.strip()]
assert len(lines) == 2, f"expected 2 runs, got {len(lines)}: {lines}"
assert [json.loads(l)["run_id"] for l in lines] == ["contract-1", "contract-2"]
last = json.loads(lines[-1])
for key in ("finished", "mode", "result", "changed", "failed", "ok", "duration_seconds"):
    assert key in last, f"history line missing {key}: {last}"
assert last["partial"] is True, last
mode = stat.S_IMODE(os.stat(os.path.join(d, "history.jsonl")).st_mode)
assert mode == 0o600, oct(mode)
print("  ok  inventory, omissions, backups, partial flag, and one line per run")
PY
rm -rf -- "$cs_mdir" "$cs_mscratch"

# `result` was derived from a stats key Ansible does not emit ("failed" rather
# than "failures"), so every failed run reported itself as ok. `complete` is
# derived from the same total, which would have authorised collection after a
# run that never finished.
echo "==> Failure is reported as failure"
cs_fdir="$(mktemp -d)"
cs_fscratch=/tmp/cs-failure-contract
rm -rf -- "$cs_fscratch"
if CS_STATE_FILE="$cs_fdir/last-run.json" CS_MANIFEST_FILE="$cs_fdir/managed-paths.json" \
   CS_HISTORY_FILE="$cs_fdir/history.jsonl" CS_RUN_MODE=apply CS_RUN_PARTIAL=0 \
   CS_RUN_ID=fail-1 ansible-playbook tests/failure.yml >/dev/null 2>&1; then
    echo "ERROR: tests/failure.yml was expected to fail and did not" >&2
    exit 1
fi
"$CS_PY" - "$cs_fdir" <<'PY'
import json, os, sys

d = os.path.abspath(sys.argv[1])
s = json.load(open(os.path.join(d, "last-run.json")))
m = json.load(open(os.path.join(d, "managed-paths.json")))
h = [json.loads(l) for l in
     open(os.path.join(d, "history.jsonl")).read().splitlines() if l.strip()]

assert s["result"] == "failed", f"a failed run reported result={s['result']!r}"
assert s["totals"]["failed"] == 1, s["totals"]
assert len(s["failed"]) == 1, s["failed"]
assert h[-1]["result"] == "failed", h[-1]
assert h[-1]["failed"] == 1, h[-1]

# The point: the task after the failure never ran, so its path is absent. Acting
# on this manifest would delete a file the machine still manages.
paths = {e["path"] for e in m["files"]}
assert "/tmp/cs-failure-contract/reached.conf" in paths, sorted(paths)
assert "/tmp/cs-failure-contract/unreached.conf" not in paths, sorted(paths)
assert m["complete"] is False, "a failed run must never be marked complete"
print("  ok  failed runs say so, and their manifest refuses to be complete")
PY
rm -rf -- "$cs_fdir" "$cs_fscratch"

# A guard whose expression always evaluates false looks exactly like a passing
# suite. Assert the run FAILS, and for the right reason.
echo "==> Layer contract (negative paths)"
expect_layer_failure() {
    local case="$1" expect="$2" out
    out="$(ANSIBLE_ROLES_PATH="$PWD/roles" ansible-playbook tests/negative.yml \
        -e computer_setup_layer_cache="$PWD/tests/fixtures/negative/$case/layers_cache" \
        -e computer_setup_machine_file="$PWD/tests/fixtures/negative/$case/machine.yml" 2>&1)" && {
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

# bootstrap.sh clones the orchestrator before the playbook has ever run, so it
# cannot read the play var. If the two spellings drift, bootstrap clones into one
# directory and every subsequent run re-clones into another — which looks like a
# slow first run, not like a bug, so nothing would ever report it.
echo "==> Pull directory agreement"
# shellcheck disable=SC2016  # $HOME is matched literally in the source line, not expanded
pull_bootstrap="$(sed -n 's|^PULL_DIR="\$HOME/\(.*\)"$|\1|p' bootstrap.sh)"
pull_playbook="$(yq -r '.[0].vars.computer_setup_pull_dir' local.yml \
    | sed 's|^{{ home_dir }}/||')"
if [[ -z "$pull_bootstrap" || -z "$pull_playbook" ]]; then
    echo "ERROR: could not read the pull directory from both sources" >&2
    echo "       bootstrap.sh='$pull_bootstrap' local.yml='$pull_playbook'" >&2
    exit 1
fi
if [[ "$pull_bootstrap" != "$pull_playbook" ]]; then
    echo "ERROR: pull directory disagreement" >&2
    echo "       bootstrap.sh PULL_DIR                 = \$HOME/$pull_bootstrap" >&2
    echo "       local.yml computer_setup_pull_dir     = {{ home_dir }}/$pull_playbook" >&2
    exit 1
fi
echo "  ok  bootstrap.sh and local.yml agree on ~/$pull_bootstrap"

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

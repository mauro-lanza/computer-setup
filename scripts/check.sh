#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Section names, in run order. Each is a function of the same name with `-`
# turned into `_`, defined below.
SECTIONS=(shellcheck bootstrap templates syntax contract machine run-state
          manifest progress roles runner negative layers agreement ansible-lint)

verbose="${CS_CHECK_VERBOSE:-0}"
selected=()
for arg in "$@"; do
    case "$arg" in
        --list) printf '%s\n' "${SECTIONS[@]}"; exit 0 ;;
        -v) verbose=1 ;;
        -*) echo "ERROR: unknown option '$arg' (options: -v, --list)" >&2; exit 2 ;;
        *)
            if [[ " ${SECTIONS[*]} " != *" $arg "* ]]; then
                echo "ERROR: unknown section '$arg'" >&2
                echo "       valid sections: ${SECTIONS[*]}" >&2
                exit 2
            fi
            selected+=("$arg")
            ;;
    esac
done
if (( ${#selected[@]} == 0 )); then
    selected=("${SECTIONS[@]}")
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/computer-setup-check.XXXXXX")"
echo "log: $LOG"

# All scratch lives here so one EXIT trap in the main shell cleans up after a
# failed section. The log stays outside: its path is for reading afterwards.
CS_TMP="$(mktemp -d)"
preamble_log=""
trap 'rc=$?; if (( rc != 0 )) && [[ -n "$preamble_log" ]]; then tail -n 40 "$preamble_log" >&2; echo "log: $LOG" >&2; fi; rm -rf -- "$CS_TMP"' EXIT

# Plain command, not under if/||: those disable set -e inside the section.
run_section() {
    local name="$1" sec_log rc
    sec_log="$(mktemp "$CS_TMP/section.XXXXXX")"
    set +e
    if [[ "$verbose" == 1 ]]; then
        ( set -e; "section_${name//-/_}" ) 2>&1 | tee "$sec_log"
        rc="${PIPESTATUS[0]}"
    else
        ( set -e; "section_${name//-/_}" ) >"$sec_log" 2>&1
        rc=$?
    fi
    set -e
    cat "$sec_log" >> "$LOG"
    if (( rc != 0 )); then
        echo "==> $name ... FAILED"
        if [[ "$verbose" != 1 ]]; then
            tail -n 40 "$sec_log"
        fi
        echo "log: $LOG"
        rm -f "$sec_log"
        exit 1
    fi
    rm -f "$sec_log"
    echo "==> $name ... ok"
}

# cs_run MODE PARTIAL ID [VAR=VAL...] playbook [args]: quiet ansible-playbook with
# the run env scoped to this one call.
cs_run() {
    local mode="$1" partial="$2" id="$3" envs=()
    shift 3
    while [[ "${1:-}" == [A-Z]*=* ]]; do envs+=("$1"); shift; done
    env CS_RUN_MODE="$mode" CS_RUN_PARTIAL="$partial" CS_RUN_ID="$id" \
        ${envs[@]+"${envs[@]}"} ansible-playbook "$@" >/dev/null
}

# run_quiet ERROR_MSG cmd...: output kept in RQ_OUT, re-printed (with ERROR_MSG
# when non-empty) on failure. An `assert` failure prints on STDOUT, so
# `>/dev/null` would leave a failing gate showing nothing.
run_quiet() {
    local msg="$1"
    shift
    RQ_OUT="$("$@" 2>&1)" || {
        printf '%s\n' "$RQ_OUT" >&2
        [[ -z "$msg" ]] || echo "ERROR: $msg" >&2
        return 1
    }
}

# cs_py DIR_OR_FILE [args]: the python snippet on stdin, run after a shared
# prelude (d = argv[1] absolute, load/jsonl readers, mode0600). Heredocs stay quoted.
CS_PY_PRELUDE='
import json, os, stat, sys
d = os.path.abspath(sys.argv[1])
def load(name):
    return json.load(open(os.path.join(d, name)))
def jsonl(name):
    return [json.loads(l) for l in open(os.path.join(d, name)).read().splitlines() if l.strip()]
def mode0600(path):
    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode == 0o600, oct(mode)
'
cs_py() {
    local body
    body="$(cat)"
    "$CS_PY" -c "$CS_PY_PRELUDE$body" "$@"
}

# Test the pinned runtime, not whatever `ansible` is on PATH: another core hides production breakage.
# Runs in the current shell, since it exports PATH and the mitogen strategy.
preamble() {
RUNTIME_BIN="$HOME/.local/share/computer-setup/runtime/bin"
if [[ ! -x "$RUNTIME_BIN/ansible-playbook" ]]; then
    echo "ERROR: the pinned engine runtime is missing." >&2
    echo "       expected: $RUNTIME_BIN/ansible-playbook" >&2
    echo "       Install it:  computer-setup apply --tags runtime" >&2
    echo "       (or re-run bootstrap.sh, which installs it in Phase 0)" >&2
    exit 1
fi
PATH="$RUNTIME_BIN:$PATH"
export PATH

pinned_core="$(yq -r '.ansible_core' runtime.yml)"
running_core="$(ansible --version | sed -n '1s/.*core \([0-9.]*\).*/\1/p')"
if [[ "$pinned_core" != "$running_core" ]]; then
    echo "ERROR: runtime.yml pins ansible-core $pinned_core, but the runtime has $running_core" >&2
    echo "       Reconcile it:  computer-setup apply --tags runtime" >&2
    exit 1
fi
# The gate runs with mitogen too, for the same reason it runs the pinned core:
# production uses it, so a suite that does not is testing something else.
# CS_NO_MITOGEN=1 runs the gate the slow way, which is how you tell a mitogen
# problem apart from a real one.
pinned_python="$(yq -r '.python' runtime.yml)"
pinned_mitogen="$(yq -r '.mitogen' runtime.yml)"
MITOGEN_STRATEGY_DIR="$HOME/.local/share/computer-setup/runtime/tools/ansible-core/lib/python${pinned_python}/site-packages/ansible_mitogen/plugins/strategy"
echo "==> Pinned runtime"
if [[ "${CS_NO_MITOGEN:-0}" != "1" && -d "$MITOGEN_STRATEGY_DIR" ]]; then
    export ANSIBLE_STRATEGY_PLUGINS="$MITOGEN_STRATEGY_DIR"
    export ANSIBLE_STRATEGY=mitogen_linear
    echo "  ok  ansible-core $running_core (python $pinned_python), mitogen $pinned_mitogen"
elif [[ "${CS_NO_MITOGEN:-0}" == "1" ]]; then
    echo "  ok  ansible-core $running_core (python $pinned_python), mitogen DISABLED"
else
    echo "ERROR: mitogen $pinned_mitogen is pinned but its strategy plugin is missing." >&2
    echo "       expected: $MITOGEN_STRATEGY_DIR" >&2
    echo "       Reconcile it:  computer-setup apply --tags runtime" >&2
    exit 1
fi
# Ansible's own interpreter: the only one guaranteed to have Jinja2 installed.
CS_PY="$(head -1 "$(command -v ansible)" | sed 's/^#!//')"
[[ -x "$CS_PY" ]] || CS_PY=python3
}

preamble_log="$(mktemp "$CS_TMP/preamble.XXXXXX")"
if [[ "$verbose" == 1 ]]; then
    preamble
else
    preamble >"$preamble_log" 2>&1
fi
cat "$preamble_log" >> "$LOG"
rm -f "$preamble_log"
preamble_log=""
echo "==> runtime ... ok"

# Every bash file here is linted by shellcheck (a parse error fails it too), and a
# FAILURE when absent for the same reason ansible-lint is: a fresh machine is
# where the tool is missing and where "passed" has to mean it. Findings are
# waived inline, at the line, with a reason — never globally.
section_shellcheck() {
echo "==> shellcheck"
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "ERROR: shellcheck is not installed, so this gate cannot run." >&2
    echo "       Install it:  brew install shellcheck" >&2
    echo "       (it is also the 'shellcheck' capability in the public layer)" >&2
    exit 1
fi
shellcheck -S style -x bootstrap.sh scripts/* tests/*.sh
echo "  ok  no findings"
}

# `bash -n` proves bootstrap.sh parses, not that the prompt loop works — and
# that loop only runs on a fresh machine, where nobody is watching it fail.
# These drive it with scripted answers.
section_bootstrap() {
echo "==> Bootstrap prompt behaviour"
./tests/bootstrap-prompts.sh
}

# Templated shell only becomes shell after rendering, so a broken runner would
# first surface inside a LaunchAgent at 09:00. De-template and check the skeleton.
section_templates() {
echo "==> Templated script syntax"
check_template_syntax() {
    local src="$1" tmp
    tmp="$(mktemp "$CS_TMP/template.XXXXXX")"
    sed -e 's/{{[^}]*}}/PLACEHOLDER/g' -e '/{%.*%}/d' "$src" > "$tmp"
    if ! bash -n "$tmp"; then
        echo "ERROR: $src does not parse as bash after de-templating" >&2
        return 1
    fi
    if ! shellcheck -S style -s bash "$tmp"; then
        echo "ERROR: $src has shellcheck findings after de-templating" >&2
        return 1
    fi
    echo "  ok  $src"
}
check_template_syntax roles/macos/templates/macos-capture.sh.j2

# The runner is rendered for real, once per platform profile: each platform's
# output is a different script, and only the rendered one is what ships.
echo "==> Runner rendered per platform"
for profile in roles/core/vars/platform/*.yml; do
    platform="$(basename "$profile" .yml)"
    rendered="$CS_TMP/computer-setup.$platform"
    "$CS_PY" tests/render-runner.py "$platform" "$CS_TMP" "$rendered"
    bash -n "$rendered" || { echo "ERROR: the $platform runner does not parse" >&2; return 1; }
    shellcheck -S style -s bash "$rendered" || { echo "ERROR: the $platform runner has shellcheck findings" >&2; return 1; }
    echo "  ok  $platform"
done

# Every profile must define the same keys: a key missing from one is a
# StrictUndefined failure on that platform only, on its first apply.
echo "==> Platform profile keys agree"
"$CS_PY" - roles/core/vars/platform/*.yml <<'PY'
import sys, yaml
def keys(d, p=""):
    out = set()
    for k, v in d.items():
        out.add(p + k)
        # package_managers is a per-platform list of candidates, not a schema.
        if isinstance(v, dict) and k != "package_managers":
            out |= keys(v, p + k + ".")
    return out
sets = {f: keys(yaml.safe_load(open(f))["computer_setup_platform"]) for f in sys.argv[1:]}
ref = set.union(*sets.values())
rc = 0
for f, s in sets.items():
    if s != ref:
        print(f"  ERROR: {f} lacks {sorted(ref - s)}", file=sys.stderr)
        rc = 1
sys.exit(rc)
PY
echo "  ok  every profile defines the same keys"

# The sed above cannot see a template Jinja itself refuses to parse — and the
# syntaxes collide: `${#arr[@]}` contains Jinja's comment-open `{#`. Parse each
# template with the same Jinja2 Ansible uses.
echo "==> Template parses as Jinja"
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
}

section_syntax() {
echo "==> Ansible syntax"
ansible-playbook --syntax-check local.yml
ansible-playbook --syntax-check tests/failure.yml

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
}

section_contract() {
echo "==> Layer contract"
ANSIBLE_ROLES_PATH="$PWD/roles" ansible-playbook tests/contract.yml >/dev/null

# An agent DELETED from a layer (as opposed to disabled) used to be unreachable:
# the teardown set was built from agents still declared, so nothing could name
# it, and its plist stayed loaded across reboots — the job kept running long
# after the machine stopped declaring it.
echo "==> Scheduled agent teardown"
ANSIBLE_ROLES_PATH="$PWD/roles" run_quiet \
    "a scheduled agent deleted from a layer was not torn down" \
    ansible-playbook tests/scheduled-agents.yml
echo "  ok  an agent deleted from a layer is torn down, not orphaned"

echo "==> Shell snippets"
sh_scratch="$(mktemp -d "$CS_TMP/shell.XXXXXX")"
for sh_phase in 1 2 3; do
    ANSIBLE_ROLES_PATH="$PWD/roles" run_quiet "shell snippet test failed in phase $sh_phase" \
        ansible-playbook tests/shell.yml -e shell_scratch="$sh_scratch" -e shell_phase="$sh_phase"
done
echo "  ok  copy, render, gate, a deleted snippet and a missing directory are handled"

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
}

# `computer-setup-machine` is git plumbing that only runs by hand or on a fresh
# machine, which is where bit-rot hides. Driven against a LOCAL bare repo — no
# network, no gh, no GitHub account — so the gate works on a fresh machine and
# in CI. `init` is the only subcommand not covered: it needs an authenticated gh.
section_machine() {
echo "==> Machine backup round-trip"
cs_m_tmp="$(mktemp -d "$CS_TMP/machine.XXXXXX")"
mkdir -p "$cs_m_tmp/cfg"
# -b main: see tests/bootstrap-prompts.sh; the host's init.defaultBranch must not matter.
git init -q -b main --bare "$cs_m_tmp/remote.git"
git init -q -b main "$cs_m_tmp/seed"
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

# A refusal has to name its reason: a bare non-zero exit also happens when the
# guard is deleted and a later command fails on its own.
cs_m_expect_failure() {
    local expect="$1" out
    shift
    if out="$(scripts/computer-setup-machine "$@" 2>&1)"; then
        echo "ERROR: accepted, expected a refusal: $*" >&2
        return 1
    fi
    if [[ "$out" != *"$expect"* ]]; then
        echo "ERROR: '$*' failed, but not for the expected reason" >&2
        echo "       expected to find: $expect" >&2
        echo "       got: $out" >&2
        return 1
    fi
}

# An unconfigured machine must say so, not traceback.
cs_m_expect_failure "No backup configured" push --config "$cs_m_tmp/nope.yml" \
    --repo-dir "$cs_m_tmp/clone" --machine-file "$cs_m_tmp/cfg/machine.yml"

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

# Never clobber: a bad restore must always be recoverable.
cs_m_expect_failure "Refusing to overwrite" pull alpha "$cs_m_tmp/out.yml" "${cs_m_flags[@]}"
cs_m_expect_failure "No backup named" pull nonexistent "$cs_m_tmp/x.yml" "${cs_m_flags[@]}"
echo "  ok  push, idempotent re-push, list, names, pull, and both refusals"
}

# The state file is a consumed interface (`computer-setup status`, and a UI later).
# Diffs carry before/after payloads, so the plugin must record only task, action and dest.
section_run_state() {
echo "==> Run state contract"
rm -f /tmp/cs-state-contract-template.txt /tmp/cs-state-contract-loop-a.txt /tmp/cs-state-contract-loop-b.txt
cs_state="$(mktemp -d "$CS_TMP/state.XXXXXX")/last-run.json"
CS_STATE_FILE="$cs_state" CS_RUN_MODE=check \
    ansible-playbook tests/state.yml --check --diff >/dev/null
if [[ ! -f "$cs_state" ]]; then
    echo "ERROR: the callback plugin wrote no state file" >&2
    exit 1
fi
cs_py "$cs_state" <<'PY'
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
mode0600(path)
print("  ok  shape, 0600, and no file contents recorded")
PY
}

# The manifest is the basis for deciding a path is no longer managed, so what it
# OMITS matters as much as what it lists. Each omission below is deliberate and
# would be invisible if it regressed.
section_manifest() {
echo "==> Manifest contract"
cs_mdir="$(mktemp -d "$CS_TMP/manifest.XXXXXX")"
cs_mscratch="$cs_mdir/scratch"
cs_run apply 0 contract-1 CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" \
    CS_HISTORY_FILE="$cs_mdir/history.jsonl" tests/manifest.yml -e "m=$cs_mscratch"
# A second run with the SAME run id: ansible-pull can reach the callback's final
# hook more than once per invocation, and history is appended, so without a key
# one run would leave two lines.
cs_run apply 0 contract-1 CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" \
    CS_HISTORY_FILE="$cs_mdir/history.jsonl" tests/manifest.yml -e "m=$cs_mscratch"
# A third, with a new id and narrowed — the shape of a `--tags` run.
cs_run check 1 contract-2 CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" \
    CS_HISTORY_FILE="$cs_mdir/history.jsonl" tests/manifest.yml -e "m=$cs_mscratch"
cs_py "$cs_mdir" <<'PY'
m = load("managed-paths.json")
base = os.path.join(d, "scratch")

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

# The third run was PARTIAL, and must not have been written at all: it saw a
# fraction of the machine, and replacing a full inventory with a fraction gives
# a wrong answer to "what does this own" until the next full run. The previous
# complete manifest is the better answer, so it survives untouched.
assert m["complete"] is True, "a partial run overwrote the manifest"
assert m["partial"] is False, m["partial"]
assert m["mode"] == "apply", "the partial check run clobbered the manifest"
assert f"{base}/looped-a.conf" in files, "the partial run truncated the inventory"

mode0600(os.path.join(d, "managed-paths.json"))

# History: appended, one line per RUN and not per play.
lines = jsonl("history.jsonl")
assert len(lines) == 2, f"expected 2 runs, got {len(lines)}: {lines}"
assert [l["run_id"] for l in lines] == ["contract-1", "contract-2"]
last = lines[-1]
for key in ("schema_version", "finished", "mode", "result", "changed", "failed",
            "ok", "duration_seconds"):
    assert key in last, f"history line missing {key}: {last}"
# Versioned per LINE: a JSONL file has no header, and lines written months
# apart can legitimately differ in shape because old ones are never rewritten.
assert last["schema_version"] == 1, last["schema_version"]
assert last["partial"] is True, last
mode0600(os.path.join(d, "history.jsonl"))
print("  ok  inventory, omissions, backups, partial flag, and one line per run")
PY

# Phase 1b: the SAME playbook under --check against a directory that does not
# exist yet — a fresh machine. Creating a file in check mode yields neither a
# result `dest` nor a diff header, so a loop's rendered item is the only thing
# left that names it. Without that fallback the first manifest a new machine
# wrote was missing every loop-created file: eight shell snippets among them.
cs_fresh="$(mktemp -d "$CS_TMP/fresh.XXXXXX")"
cs_run check 0 fresh-1 CS_MANIFEST_FILE="$cs_fresh/managed-paths.json" \
    tests/manifest.yml --check -e "m=$cs_fresh/scratch"
cs_py "$cs_fresh" <<'PYEOF'
m = load("managed-paths.json")
files = {e["path"] for e in m["files"]}
base = os.path.join(d, "scratch")

for expected in (f"{base}/abs-a.conf", f"{base}/abs-b.conf"):
    assert expected in files, f"{expected} missing from a check-mode manifest: {sorted(files)}"
assert f"{base}/managed.conf" in files, sorted(files)
print("  ok  a fresh machine's manifest includes loop-created files")
PYEOF

# Phase two: a path that STOPS being managed. Same fixture directory, fewer
# declared files — so what tests/manifest.yml wrote (the same `m` scratch dir;
# this phase depends on it) is now unmanaged and still on disk. Report-only;
# nothing here deletes anything.
cs_run apply 0 contract-3 CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" tests/orphans.yml -e "m=$cs_mscratch"
# Twice, because an orphan must SURVIVE the next run. A naive
# previous-minus-current diff reports it once and then silently forgets it,
# while the file is still sitting there.
cs_run apply 0 contract-4 CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" tests/orphans.yml -e "m=$cs_mscratch"
cs_py "$cs_mdir" <<'PYEOF'
m = load("managed-paths.json")
base = os.path.join(d, "scratch")
orphans = {e["path"]: e for e in m["orphans"]}

# Dropped from the declaration, still on disk, and still reported after a
# SECOND run — the property a one-shot diff does not have.
for expected in (f"{base}/looped-a.conf", f"{base}/looped-b.conf",
                 f"{base}/abs-a.conf", f"{base}/abs-b.conf"):
    assert expected in orphans, f"{expected} missing from {sorted(orphans)}"

# Still declared, so not an orphan however many runs go by.
assert f"{base}/managed.conf" not in orphans, "a managed file was reported as an orphan"

# Never existed on disk: `state: absent` and skipped paths must not be
# resurrected as orphans by the diff.
for never in (f"{base}/removed.conf", f"{base}/skipped.conf"):
    assert never not in orphans, f"{never} was invented as an orphan"

# Directories are deliberately untracked: ~/Library/Logs and ~/.local/bin are
# both managed directories and neither is ours to delete.
assert base not in orphans, "a directory was reported as an orphan"

# Attribution survives the file falling out of management — "which role used to
# own this" is what someone asks when deciding whether to delete it.
assert orphans[f"{base}/looped-a.conf"].get("since"), "an orphan carries no `since`"
print("  ok  orphans found, carried across runs, and not invented")
PYEOF

# Phase three: an orphan that gets DEALT WITH must stop being reported. Without
# this the list only ever grows, and a report that never shrinks is one nobody
# reads. The check is `lexists`, so a broken symlink still counts as present.
rm -f -- "$cs_mscratch/looped-a.conf"
cs_run apply 0 contract-5 CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" tests/orphans.yml -e "m=$cs_mscratch"
cs_py "$cs_mdir" <<'PYEOF'
m = load("managed-paths.json")
base = os.path.join(d, "scratch")
orphans = {e["path"] for e in m["orphans"]}

assert f"{base}/looped-a.conf" not in orphans, "a deleted orphan is still reported"
# The one still on disk must survive, or the rule is "forget everything" rather
# than "forget what is gone".
assert f"{base}/looped-b.conf" in orphans, "deleting one orphan dropped the others"
print("  ok  an orphan removed from disk stops being reported")
PYEOF

# The failure to read a previous manifest is swallowed, so one of the wrong SHAPE
# would otherwise block every later manifest without a word.
for cs_garbage in '[]' '{"files": null, "orphans": "x"}'; do
    printf '%s\n' "$cs_garbage" > "$cs_mdir/managed-paths.json"
    cs_run apply 0 contract-6 CS_MANIFEST_FILE="$cs_mdir/managed-paths.json" tests/orphans.yml -e "m=$cs_mscratch"
    cs_py "$cs_mdir" "$cs_garbage" <<'PYEOF'
m = load("managed-paths.json")
assert isinstance(m, dict) and m["files"], \
    f"a previous manifest {sys.argv[2]} blocked the next one: {m}"
PYEOF
done
echo "  ok  a malformed previous manifest does not stop the next one being written"
}

# A progress file is only useful if a reader can distinguish "running" from
# "finished" from "died half way", and if the file describes THIS run rather
# than an interleaving of two. Both are easy to get wrong and invisible when
# wrong: the run still succeeds either way.
section_progress() {
echo "==> Live progress"
cs_pdir="$(mktemp -d "$CS_TMP/progress.XXXXXX")"
cs_run apply 0 prog-1 CS_PROGRESS_FILE="$cs_pdir/progress.jsonl" \
    CS_HISTORY_FILE="$cs_pdir/history.jsonl" tests/manifest.yml -e "m=$cs_pdir/scratch"
# A second run must REPLACE the file, not append to it. Appending would leave a
# reader seeing the previous run's tasks as this run's, and a progress bar that
# starts at 100%.
cs_run apply 0 prog-2 CS_PROGRESS_FILE="$cs_pdir/progress.jsonl" \
    CS_HISTORY_FILE="$cs_pdir/history.jsonl" tests/manifest.yml -e "m=$cs_pdir/scratch"
cs_py "$cs_pdir" <<'PYEOF'
lines = jsonl("progress.jsonl")

head = lines[0]
assert head["event"] == "start", head
assert head["schema_version"] == 1, head
assert head["mode"] == "apply", head
assert head["run_id"] == "prog-2", f"the file describes an earlier run: {head}"

tasks = [l for l in lines if l.get("event") == "task"]
assert tasks, "no task lines"
# Monotonic from 1: a reader divides by the estimate, so a gap or a repeat
# renders as a bar that jumps or goes backwards.
assert [t["n"] for t in tasks] == list(range(1, len(tasks) + 1)), \
    f"task numbers are not 1..n: {[t['n'] for t in tasks][:10]}"
assert all(t.get("task") for t in tasks), "a task line carries no name"

end = lines[-1]
assert end["event"] == "end", f"the last line is not an end marker: {end}"
assert end["result"] == "ok", end
assert end["tasks"] == len(tasks), (end["tasks"], len(tasks))

# The second run's denominator comes from the FIRST run's history entry, which
# is the only reason a bar has a scale at all.
assert head["total_estimate"] == end["tasks"], \
    f"estimate {head['total_estimate']} did not match the previous run's {end['tasks']}"

# It names this machine's tasks and paths.
mode0600(os.path.join(d, "progress.jsonl"))

# history carries the count the next run will read.
hist = jsonl("history.jsonl")
assert hist[-1]["tasks"] == end["tasks"], hist[-1]
print(f"  ok  {len(tasks)} tasks streamed, replaced not appended, end marker present")
PYEOF

# MAX_RECORDED had never executed: the run-state contract asserts
# `truncated is False` and nothing drove the other side. It matters on exactly
# the run nobody has watched — a first apply on a fresh machine, where a large
# loop changes everything at once.
echo "==> Run state truncation"
cs_tdir="$(mktemp -d "$CS_TMP/truncation.XXXXXX")"
cs_tscratch=/tmp/cs-truncation-contract
rm -rf -- "$cs_tscratch"
cs_run apply 0 trunc-1 CS_STATE_FILE="$cs_tdir/last-run.json" \
    CS_MANIFEST_FILE="$cs_tdir/managed-paths.json" tests/truncation.yml
cs_py "$cs_tdir" <<'PY'
s = load("last-run.json")
m = load("managed-paths.json")

assert s["truncated"] is True, "250 changes did not trip truncation"
assert len(s["changed"]) == 200, len(s["changed"])

# The whole point of the split. A drift report may be truncated — past 200
# entries the list is a sample and says so. An INVENTORY may not: a manifest
# that silently dropped paths would have collection treat live files as
# orphans, which is the one failure mode worth being paranoid about.
files = {e["path"] for e in m["files"]}
assert len(files) == 250, f"the manifest was capped at {len(files)}"
assert m["complete"] is True, m["complete"]
print("  ok  drift truncates and says so; the inventory does not")
PY
rm -rf -- "$cs_tscratch"
}

# Roles against pre-existing user state, and the rendered runner's scheduled path
# with git/ansible-pull stubbed. Output is captured and re-printed on failure.
section_roles() {
echo "==> Role robustness"
ANSIBLE_ROLES_PATH="$PWD/roles" run_quiet "" ansible-playbook tests/robustness.yml
echo "  ok  git includes survive, empty docker config, bad conditional default"
echo "==> Repositories role"
ANSIBLE_ROLES_PATH="$PWD/roles" run_quiet "" ansible-playbook tests/repositories.yml
echo "  ok  clone once, hook once, local work untouched, inactive skipped"
for ro_case in none empty bare list; do
    ro_dir="$(mktemp -d "$CS_TMP/override.XXXXXX")"
    mkdir -p "$ro_dir/cfg"
    ANSIBLE_ROLES_PATH="$PWD/roles" run_quiet "repository override case '$ro_case' failed" \
        ansible-playbook tests/repositories-override.yml -e repo_case="$ro_case" -e repo_scratch="$ro_dir"
done
echo "  ok  override file wins only when it declares repositories (none, empty, bare key, list)"
echo "==> Logins and upgrade roles"
for t in logins upgrade; do
    ANSIBLE_ROLES_PATH="$PWD/roles" run_quiet "" ansible-playbook "tests/$t.yml"
done
lu_out="$RQ_OUT"
# The preview names Node only while the nvm capability is active: with it on in
# the preview run and in the apply run, off in the other two.
[[ "$(grep -c 'Node\.js lts' <<<"$lu_out")" == 2 ]] || {
    echo "ERROR: the upgrade preview must mention Node exactly when nvm is active" >&2
    printf '%s\n' "$lu_out" >&2
    exit 1
}
echo "  ok  logins detect/remedy gating, upgrade preview queries only managed packages"
}

section_runner() {
echo "==> Scheduled runner"
./tests/runner.sh

# The macOS failure report lives in local.yml, which no test plays. Lift the real
# task out and feed it fake failures from BOTH sources, so a variable the message
# uses but the task does not define (it happened) fails here rather than at the
# one moment a default is wrong.
echo "==> macOS defaults failure report"
mr_dir="$(mktemp -d "$CS_TMP/macos-report.XXXXXX")"
yq '[.[0].post_tasks[] | select(.name == "Report macOS defaults that could not be applied")]' local.yml > "$mr_dir/task.yml"
yq -n '[{"hosts":"localhost","connection":"local","gather_facts":false,"vars":{
  "macos_defaults_results":{"results":[
    {"failed":true,"msg":"mismatch-A","item":{"domain":"dom1","key":"key1","type":"bool"}},
    {"failed":true,"msg":"mismatch-B","item":{"domain":"dom2","key":"key2","type":"int"}},
    {"failed":false,"item":{"domain":"fine","key":"fine","type":"int"}}]}},
  "tasks":[]}]' > "$mr_dir/pb.yml"
yq -i ".[0].tasks = load(\"$mr_dir/task.yml\")" "$mr_dir/pb.yml"
mr_out="$(ansible-playbook "$mr_dir/pb.yml" 2>&1 || true)"
for expect in "2 macOS default(s)" "dom1 key1 (declared bool): mismatch-A" "dom2 key2 (declared int): mismatch-B"; do
    [[ "$mr_out" == *"$expect"* ]] || {
        echo "ERROR: the macOS failure report is missing '$expect'" >&2
        printf '%s\n' "$mr_out" >&2
        exit 1
    }
done
[[ "$mr_out" != *"fine fine"* ]] || { echo "ERROR: a SUCCESSFUL default was reported as failed" >&2; exit 1; }
echo "  ok  both failure sources reported, successes not"

# Same lift for the cask report: the merged install loop registers one result
# that this task must still collect failures from.
echo "==> Cask failure report"
cr_dir="$(mktemp -d "$CS_TMP/cask-report.XXXXXX")"
yq '[.[0].post_tasks[] | select(.name == "Report casks that could not be installed")]' local.yml > "$cr_dir/task.yml"
yq -n '[{"hosts":"localhost","connection":"local","gather_facts":false,"vars":{
  "packages_cask_results":{"results":[
    {"failed":true,"msg":"boom-A","item":"cask-bad-a"},
    {"failed":false,"item":"cask-fine"},
    {"failed":true,"msg":"boom-B","item":"cask-bad-b"}]}},
  "tasks":[]}]' > "$cr_dir/pb.yml"
yq -i ".[0].tasks = load(\"$cr_dir/task.yml\")" "$cr_dir/pb.yml"
cr_out="$(ansible-playbook "$cr_dir/pb.yml" 2>&1 || true)"
for expect in "2 cask(s) could not be installed" "cask-bad-a: boom-A" "cask-bad-b: boom-B"; do
    [[ "$cr_out" == *"$expect"* ]] || {
        echo "ERROR: the cask failure report is missing '$expect'" >&2
        printf '%s\n' "$cr_out" >&2
        exit 1
    }
done
[[ "$cr_out" != *"cask-fine:"* ]] || { echo "ERROR: a SUCCESSFUL cask was reported as failed" >&2; exit 1; }
echo "  ok  failed casks collected and reported, successes not"

echo "==> History rendering"
# A broken yq expression fails silently (rows vanish), so check the rendered rows.
# Lifted from the runner template, so the tested expression is the one that runs.
hist_expr="$(sed -n "s/.*| yq -p json -r '\(.*\)' \\\\$/\1/p" \
    roles/drift_correction/templates/computer-setup.j2)"
if [[ -z "$hist_expr" ]]; then
    echo "ERROR: could not lift the history yq expression out of the runner" >&2
    echo "       (looked for the HISTORY_TSV_EXPR line)" >&2
    exit 1
fi
hist_fixture="$(mktemp "$CS_TMP/history.XXXXXX")"
cat > "$hist_fixture" <<'JSONL'
{"changed":0,"duration_seconds":48.5,"failed":0,"finished":"2026-09-03T21:43:28+0200","mode":"check","ok":163,"partial":false,"result":"ok","run_id":"a"}
{"changed":2,"duration_seconds":11.4,"failed":1,"finished":"2026-09-03T21:44:54+0200","mode":"apply","ok":78,"partial":true,"result":"failed","run_id":"b"}
JSONL
# Captured into a variable, not piped into grep: check.sh runs with pipefail and
# `grep -q` SIGPIPEs the producer, which racily fails a passing assertion.
hist_out="$(yq -p json -r "$hist_expr" < "$hist_fixture")"
hist_rows="$(printf '%s\n' "$hist_out" | grep -c . || true)"
if [[ "$hist_rows" -ne 2 ]]; then
    echo "ERROR: the history expression rendered $hist_rows row(s), expected 2" >&2
    echo "       expression: $hist_expr" >&2
    exit 1
fi
# Field order is what awk positionally depends on downstream.
if [[ "$(printf '%s\n' "$hist_out" | tail -1)" \
      != "2026-09-03T21:44:54+0200	apply	failed	true	2	1	11.4" ]]; then
    echo "ERROR: the history expression changed shape" >&2
    printf '%s\n' "$hist_out" >&2
    exit 1
fi
echo "  ok  2 rows, fields in the order awk expects"
}

# `result` was derived from a stats key Ansible does not emit ("failed" rather
# than "failures"), so every failed run reported itself as ok. `complete` is
# derived from the same total, which would have authorised collection after a
# run that never finished.
section_negative() {
echo "==> Failure is reported as failure"
cs_fdir="$(mktemp -d "$CS_TMP/failure.XXXXXX")"
cs_fscratch=/tmp/cs-failure-contract
rm -rf -- "$cs_fscratch"
if cs_run apply 0 fail-1 CS_STATE_FILE="$cs_fdir/last-run.json" \
    CS_MANIFEST_FILE="$cs_fdir/managed-paths.json" CS_HISTORY_FILE="$cs_fdir/history.jsonl" \
    tests/failure.yml >/dev/null 2>&1; then
    echo "ERROR: tests/failure.yml was expected to fail and did not" >&2
    exit 1
fi
cs_py "$cs_fdir" <<'PYEOF'
s = load("last-run.json")
h = jsonl("history.jsonl")

assert s["result"] == "failed", f"a failed run reported result={s['result']!r}"
assert s["totals"]["failed"] == 1, s["totals"]
assert len(s["failed"]) == 1, s["failed"]
assert h[-1]["result"] == "failed", h[-1]
assert h[-1]["failed"] == 1, h[-1]

# A failed run writes NO manifest. The task after the failure never ran, so its
# path would be missing from the inventory — and the next run would then report
# a file the machine still manages as an orphan. Both the run summary and the
# history still record the failure; only the inventory abstains.
assert not os.path.exists(os.path.join(d, "managed-paths.json")), \
    "a failed run wrote a manifest"
print("  ok  failed runs say so, and write no inventory at all")
PYEOF

# A state file that cannot be written must not turn a failed run into an ok one:
# history and the end marker are derived from the same totals.
: > "$cs_fdir/blocker"
if cs_run apply 0 fail-2 CS_STATE_FILE="$cs_fdir/blocker/last-run.json" \
    CS_HISTORY_FILE="$cs_fdir/history.jsonl" tests/failure.yml >/dev/null 2>&1; then
    echo "ERROR: tests/failure.yml was expected to fail and did not" >&2
    exit 1
fi
cs_py "$cs_fdir" <<'PYEOF'
h = jsonl("history.jsonl")
assert h[-1].get("run_id") == "fail-2", h[-1]
assert h[-1]["result"] == "failed" and h[-1]["failed"] == 1, \
    f"an unwritable state file hid a failed run: {h[-1]}"
print("  ok  an unwritable state file does not hide a failed run")
PYEOF
rm -rf -- "$cs_fscratch"

# A guard whose expression always evaluates false looks exactly like a passing
# suite. Assert the run FAILS, and for the right reason.
echo "==> Layer contract (negative paths)"
expect_layer_failure() {
    local case="$1" expect="$2" machine="${3:-machine.yml}" out
    out="$(ANSIBLE_ROLES_PATH="$PWD/roles" ansible-playbook tests/negative.yml \
        -e computer_setup_layer_cache="$PWD/tests/fixtures/negative/$case/layers_cache" \
        -e computer_setup_machine_file="$PWD/tests/fixtures/negative/${machine}" 2>&1)" && {
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
expect_layer_failure schema-old "requires schema_version 1"
# Reserved by PREFIX, not by name: the engine's scheduled jobs read these keys.
expect_layer_failure drift-prefix "defines reserved key"
# Ansible's execution controls are reserved as a NAMESPACE. Enumerating five of
# them left ansible_become_password and ansible_ssh_common_args reachable.
expect_layer_failure ansible-prefix "defines reserved key"
expect_layer_failure cs-prefix "defines reserved key"
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

# A malformed machine declaration must abort, not continue with defaults.
expect_layer_failure malformed-machine "YAML parsing failed" malformed-machine/machine.yml
}

# A pinned layer must stay put while origin moves, and unpinning must return it
# to the branch. Real local repos, no network. Captured, never piped into grep -q.
section_layers() {
echo "==> Layer sync (pinned ref)"
_pd="$(mktemp -d "$CS_TMP/pin.XXXXXX")"
git init -q -b main "$_pd/src"
printf 'name: pinme\nschema_version: 2\n' > "$_pd/src/layer.yml"
echo one > "$_pd/src/marker"
git -C "$_pd/src" add -A
git -C "$_pd/src" -c user.email=t@t -c user.name=t commit -qm one
git -C "$_pd/src" tag v1
_pd_sha="$(git -C "$_pd/src" rev-parse HEAD)"
pin_manifest() { printf 'layers:\n  - name: pinme\n    repo: "%s"\n    priority: 10\n%b' "$_pd/src" "${1:-}" > "$_pd/m.yml"; }
pin_sync() { ./scripts/computer-setup-layers sync --manifest "$_pd/m.yml" --cache "$_pd/cache" 2>&1; }
# For the cases that must succeed: show why when they do not.
pin_ok() { pin_out="$(pin_sync)" || { echo "ERROR: pinned sync failed: $pin_out" >&2; exit 1; }; }
pin_manifest '    ref: v1\n'; pin_ok
echo two > "$_pd/src/marker"
git -C "$_pd/src" -c user.email=t@t -c user.name=t commit -qam two
pin_ok
[[ "$(cat "$_pd/cache/pinme/marker")" == one ]] || { echo "ERROR: a tag-pinned layer moved with origin" >&2; exit 1; }
pin_manifest "    ref: $_pd_sha\n"; pin_ok
[[ "$(cat "$_pd/cache/pinme/marker")" == one ]] || { echo "ERROR: a sha-pinned layer moved with origin" >&2; exit 1; }
pin_manifest ''; pin_ok
[[ "$(cat "$_pd/cache/pinme/marker")" == two ]] || { echo "ERROR: unpinning did not return the layer to the branch" >&2; exit 1; }
pin_manifest '    ref: v1\n'; pin_ok
[[ "$(cat "$_pd/cache/pinme/marker")" == one ]] || { echo "ERROR: re-pinning a followed layer did not take" >&2; exit 1; }
pin_manifest '    ref: "--upload-pack=x"\n'
pin_out="$(pin_sync)" && { echo "ERROR: a ref starting with '-' was ACCEPTED" >&2; exit 1; }
[[ "$pin_out" == *"is invalid"* ]] || { echo "ERROR: bad ref rejected for the wrong reason: $pin_out" >&2; exit 1; }
pin_manifest '    ref: no-such-tag\n'
pin_out="$(pin_sync)" && { echo "ERROR: an unknown ref was ACCEPTED" >&2; exit 1; }
[[ "$pin_out" == *"could not fetch ref"* ]] || { echo "ERROR: unknown ref failed for the wrong reason: $pin_out" >&2; exit 1; }
echo "  ok  tag and sha pins hold, unpin follows the branch, bad refs rejected"

# Cross-references (capability, question and preset ids) fail silently when wrong; the linter makes them loud.
# `lint --machine`: an unknown selected id is an error, a known one is not.
echo "==> Layer lint (machine selections)"
lm_out="$(./scripts/computer-setup-layers lint --cache tests/fixtures/layers_cache \
    --machine tests/fixtures/machine.yml 2>&1)" && {
    echo "ERROR: lint --machine accepted the fixture's ghost" >&2
    exit 1
}
[[ "$lm_out" == *"selected_capabilities names 'ghost'"* && "$lm_out" != *"names 'nvm'"* ]] || {
    echo "ERROR: lint --machine reported the wrong ids: $lm_out" >&2
    exit 1
}
echo "  ok  unknown selection rejected, known ones accepted"

# A manifest repo URL starting with '-' would be parsed by `git clone` as an
# option. Reject it before any git call; capture the output (no pipe into grep -q).
echo "==> Layer sync (hostile manifest repo)"
_hm="$(mktemp -d "$CS_TMP/hostile.XXXXXX")"
printf 'layers:\n  - name: evil\n    repo: "--upload-pack=touch %s/pwned"\n    priority: 10\n' "$_hm" > "$_hm/manifest.yml"
sync_out="$(./scripts/computer-setup-layers sync --manifest "$_hm/manifest.yml" --cache "$_hm/cache" 2>&1)" && {
    echo "ERROR: a manifest repo starting with '-' was ACCEPTED" >&2
    exit 1
}
[[ "$sync_out" == *"must not start with '-'"* ]] && [[ ! -e "$_hm/pwned" ]] || {
    echo "ERROR: hostile manifest repo rejected for the wrong reason: $sync_out" >&2
    exit 1
}
echo "  ok  repo URL starting with '-' rejected"

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
    "Layer 'oldschema' requires schema_version 1, but this orchestrator supports 2" \
    "capability id declared twice" \
    "capability requires 'nonexistent'" \
    "capability 'oldshape' uses removed key 'type:'" \
    "capability 'oldshape' packages: must be a mapping" \
    "capability 'oldtap' uses removed key 'tap:'" \
    "capability 'badmgr' packages: key 'apt' must be one of" \
    "vars.yml sets 'homebrew_baseline_formulae', which no role reads" \
    "vars/Darwn.yml names no platform" \
    "preset selects capability 'does-not-exist'" \
    "preset answers question 'no-such-question'" \
    "question implies capability 'ghost-capability'" \
    "has a config: entry missing src: or dest:" \
    "config: uses mode:" \
    "config: has a non-boolean executable:" \
    "shell_config_files key 'no-such-shell-file' matches no files/" \
    "config src 'no-such-config-file' matches no files/"
do
    if ! grep -qF "$expect" <<<"$lint_out"; then
        echo "ERROR: linter did not report: $expect" >&2
        exit 1
    fi
done
echo "  ok  all 16 broken references rejected"

# One malformed file is one error, not one per projection read from it.
malformed_count="$(grep -cF "malformed/capabilities.yml is not valid YAML" <<<"$lint_out" || true)"
if [[ "$malformed_count" -ne 1 ]]; then
    echo "ERROR: malformed capabilities.yml reported $malformed_count times, expected 1" >&2
    exit 1
fi
echo "  ok  malformed YAML reported once"
}

# The highest supported layer schema_version is stated in three places that
# cannot import from each other: bootstrap.sh runs before any checkout exists
# under `curl | bash`, and the sync helper is deployed standalone. Duplication
# is therefore forced — but disagreement is not. A bump that updates only one
# would let bootstrap accept a layer the engine then rejects, on a fresh machine,
# mid-provision. Assert them equal instead of documenting that they should be.
section_agreement() {
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

# Same reason for the data directory: bootstrap spells it per subdirectory.
echo "==> Data directory agreement"
data_playbook="$(yq -r '.[0].vars.computer_setup_data_dir' local.yml | sed 's|^{{ home_dir }}/||')"
for v in LAYER_CACHE RUNTIME_DIR BACKUP_REPO_DIR; do
    # shellcheck disable=SC2016  # $HOME is matched literally in the source line
    d="$(sed -n "s|^${v}=\"\\\$HOME/\(.*\)/[a-z]*\"\$|\1|p" bootstrap.sh)"
    if [[ -z "$data_playbook" || "$d" != "$data_playbook" ]]; then
        echo "ERROR: $v in bootstrap.sh ('$d') disagrees with computer_setup_data_dir ('$data_playbook')" >&2
        exit 1
    fi
done
echo "  ok  bootstrap.sh and local.yml agree on ~/$data_playbook"

# bootstrap.sh expands {{ homebrew_prefix }} in adopt_if_present before any
# profile can be read, so it keeps a copy per platform.
echo "==> Homebrew prefix agreement"
for platform in Darwin Linux; do
    hp_profile="$(yq -r '.computer_setup_platform.homebrew_prefix' "roles/core/vars/platform/$platform.yml")"
    if [[ "$(sed -n 's/^    HOMEBREW_PREFIX="\(.*\)"$/\1/p' bootstrap.sh)" != *"$hp_profile"* ]]; then
        echo "ERROR: bootstrap.sh has no HOMEBREW_PREFIX=\"$hp_profile\" for $platform" >&2
        exit 1
    fi
done
echo "  ok  bootstrap.sh and the platform profiles agree"

echo "==> Lint platform list agreement"
lp_profiles="$(for f in roles/core/vars/platform/*.yml; do basename "$f" .yml; done | sort | tr '\n' ' ')"
lp_lint="$(sed -n 's/^LINT_PLATFORMS="\(.*\)"$/\1/p' scripts/computer-setup-layers | tr ' ' '\n' | sort | tr '\n' ' ')"
if [[ -z "$lp_lint" || "$lp_profiles" != "$lp_lint" ]]; then
    echo "ERROR: LINT_PLATFORMS ('$lp_lint') disagrees with the platform profiles ('$lp_profiles')" >&2
    exit 1
fi
echo "  ok  lint knows every platform profile"

lm_profiles="$(yq -r '.computer_setup_platform.package_managers | keys | .[]' roles/core/vars/platform/*.yml | sort -u | tr '\n' ' ')"
lm_lint="$(sed -n 's/^LINT_MANAGERS="\(.*\)"$/\1/p' scripts/computer-setup-layers | tr ' ' '\n' | sort | tr '\n' ' ')"
if [[ -z "$lm_lint" || "$lm_profiles" != "$lm_lint" ]]; then
    echo "ERROR: LINT_MANAGERS ('$lm_lint') disagrees with the profiles' package managers ('$lm_profiles')" >&2
    exit 1
fi
echo "  ok  lint knows every package manager"
}

# A gate, not an advisory: .ansible-lint waives the two rules that contradict
# this architecture, so any finding is real. Missing ansible-lint is a FAILURE —
# a fresh machine is where the tool is absent and where "passed" must mean it.
section_ansible_lint() {
echo "==> ansible-lint"
if ! command -v ansible-lint >/dev/null 2>&1; then
    echo "ERROR: ansible-lint is not installed, so this gate cannot run." >&2
    echo "       Install it:  brew install ansible-lint" >&2
    echo "       (it is also the 'ansible-lint' capability in the public layer)" >&2
    exit 1
fi
ansible-lint -q
echo "  ok  no findings"
}

for section in "${selected[@]}"; do
    run_section "$section"
done

echo "Checks passed"

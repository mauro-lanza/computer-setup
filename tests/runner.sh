#!/bin/bash
# Behaviour of the RENDERED runner's scheduled path, against a scratch HOME with
# `git` and `ansible-pull` stubbed. Covers what check.sh otherwise only parses:
# the connectivity retry, the skip being diagnosable, and the per-mode stamps.
# Needs the pinned runtime on PATH (jinja2) and yq.
set -euo pipefail
cd "$(dirname "$0")/.."

T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/logs" "$T/home"

# The runtime's own interpreter (has jinja2); its path is the `ansible` shebang.
RT_PY="$(head -1 "$(command -v ansible)" | sed 's/^#!//')"
"$RT_PY" - "$T" <<'PY'
import sys, os, jinja2
t = sys.argv[1]
env = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
env.filters["expanduser"] = os.path.expanduser
v = dict(
    computer_setup_repo_url="git@example.invalid:o/r.git", computer_setup_repo_branch="main",
    computer_setup_machine_file=t + "/none.yml", computer_setup_layer_cache="",
    computer_setup_log_dir=t + "/logs", computer_setup_state_dir=t + "/state",
    computer_setup_config_dir=t + "/config", computer_setup_backup_repo_dir=t + "/backups",
    computer_setup_runtime_bin=t + "/bin", computer_setup_runtime_tools=t + "/tools",
    computer_setup_python_version="3.14", computer_setup_pull_dir=t + "/pull",
    computer_setup_bin_dir=t + "/bin", computer_setup_schema_version=1,
    drift_correction_log_retention_days=30, drift_correction_stale_after_days=14,
    drift_correction_connectivity_timeout=1, computer_setup_repositories_override_file=t + "/repositories.yml",
    repositories_base_dir=t + "/repos",
)
src = open("roles/drift_correction/templates/computer-setup.j2").read()
open(t + "/bin/computer-setup", "w").write(env.from_string(src).render(**v))
PY
chmod +x "$T/bin/computer-setup"

# Stubs. The git stub counts calls and fails while $GIT_FAIL is set.
cat > "$T/bin/git" <<STUB
#!/bin/bash
echo x >> "$T/git-calls"
if [[ -n "\${GIT_FAIL:-}" ]]; then echo "ssh: Could not resolve hostname" >&2; exit 128; fi
exit 0
STUB
cat > "$T/bin/ansible-pull" <<STUB
#!/bin/bash
echo x >> "$T/pull-calls"
printf '%s\\n' "\$*" > "$T/pull-args"
exit 0
STUB
chmod +x "$T/bin/git" "$T/bin/ansible-pull"

run() { HOME="$T/home" PROBE_RETRY_DELAY=0 PATH="$T/bin:$PATH" "$T/bin/computer-setup" "$@"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
latest_log() { ls -t "$T"/logs/*.log | head -1; }

# 1. Unreachable: 3 attempts, the git error survives in the log, nothing runs,
#    and no success stamp is written.
GIT_FAIL=1 run _scheduled-upgrade
log="$(cat "$(latest_log)")"
[[ "$(wc -l < "$T/git-calls" | tr -d ' ')" == 3 ]] || fail "expected 3 probe attempts"
[[ "$log" == *"probe 3/3 failed: ssh: Could not resolve hostname"* ]] || fail "git error not in the log: $log"
[[ "$log" == *"RESULT: skipped"* ]] || fail "skip not recorded"
[[ ! -e "$T/pull-calls" ]] || fail "ansible-pull ran while unreachable"
[[ ! -e "$T/state/last-success" && ! -e "$T/state/last-success-upgrade" ]] || fail "a skip wrote a success stamp"
echo "  ok  unreachable: 3 attempts, error logged, no stamp"

# 2. Recovers on the 3rd attempt (flaky wake-time network).
rm -f "$T/git-calls"
cat > "$T/bin/git" <<STUB
#!/bin/bash
echo x >> "$T/git-calls"
[[ "\$(wc -l < "$T/git-calls" | tr -d ' ')" -ge 3 ]] || exit 128
STUB
run _scheduled-upgrade
[[ -e "$T/pull-calls" ]] || fail "did not proceed after the probe recovered"
echo "  ok  probe recovering on attempt 3 proceeds"

# 3. The upgrade stamps both files; a check stamps only the shared one.
[[ -s "$T/state/last-success-upgrade" && -s "$T/state/last-success" ]] || fail "upgrade did not write both stamps"
rm -f "$T/state/last-success" "$T/state/last-success-upgrade"
run _scheduled-check
[[ -s "$T/state/last-success" ]] || fail "check did not write last-success"
[[ ! -e "$T/state/last-success-upgrade" ]] || fail "a CHECK wrote the upgrade stamp"
echo "  ok  check stamps last-success only"

# 4. status: BEHIND appears only for an old upgrade stamp, and --json carries it.
run status | grep -q "BEHIND" && fail "BEHIND shown with no upgrade stamp" || true
date -v-5d '+%Y-%m-%dT%H:%M:%S%z' > "$T/state/last-success-upgrade"
echo '{"mode":"check","result":"ok","finished":"x"}' > "$T/state/last-run.json"
out="$(run status)"
[[ "$out" == *"BEHIND — last successful scheduled upgrade was 5 day(s) ago"* ]] || fail "BEHIND missing: $out"
[[ "$(run status --json | yq -p json '.days_since_upgrade_success')" == 5 ]] || fail "status --json lacks days_since_upgrade_success"
echo "  ok  status reports a stale upgrade"

# 5. One run at a time. A live holder makes a scheduled run skip (exit 0, no
#    ansible-pull, progress file untouched) and an interactive one refuse
#    (non-zero, names the pid). A dead holder's lock is cleared, and the lock is
#    released when a run ends.
rm -f "$T/pull-calls" "$T/git-calls"
mkdir "$T/state/run.lock"; sleep 30 & holder=$!; echo "$holder" > "$T/state/run.lock/pid"
printf '{"event":"sentinel"}\n' > "$T/state/progress.jsonl"
out="$(run _scheduled-check)" || fail "a busy scheduled run must exit 0"
[[ "$out" == *"another run is in progress (pid $holder)"* ]] || fail "busy skip not explained: $out"
[[ ! -e "$T/pull-calls" ]] || fail "ansible-pull ran while the lock was held"
[[ "$(cat "$T/state/progress.jsonl")" == '{"event":"sentinel"}' ]] || fail "a skipped run clobbered the live run's progress"
if err="$(run apply 2>&1)"; then fail "an interactive run was not refused"; fi
[[ "$err" == *"pid $holder"* ]] || fail "refusal does not name the holder: $err"
[[ ! -e "$T/pull-calls" ]] || fail "ansible-pull ran while refused"
echo "  ok  live lock: scheduled skips, interactive refuses, progress untouched"

kill "$holder"; wait "$holder" 2>/dev/null || true
run apply >/dev/null 2>&1 || fail "a dead holder's lock was not cleared"
[[ -e "$T/pull-calls" ]] || fail "run did not proceed past a stale lock"
[[ ! -e "$T/state/run.lock" ]] || fail "lock not released after the run"
echo "  ok  stale lock cleared, lock released on exit"

# 6. A lock that never got a pid (holder died between mkdir and the write) is
#    cleared once it is old, but respected while young.
mkdir "$T/state/run.lock"
out="$(run _scheduled-check)" || fail "young pid-less lock must exit 0"
[[ "$out" == *"another run is in progress"* ]] || fail "young pid-less lock was not respected: $out"
touch -t 202001010000 "$T/state/run.lock"
run apply >/dev/null 2>&1 || fail "an old pid-less lock was not cleared"
echo "  ok  pid-less lock: respected when young, cleared when old"

# 7. The play must be told which repo and ref this runner follows, or it re-renders
#    the runner from local.yml's defaults and silently un-forks it.
args="$(cat "$T/pull-args")"
[[ "$args" == *"-e computer_setup_repo_url=git@example.invalid:o/r.git"* ]] || fail "repo url not passed to the play: $args"
[[ "$args" == *"-e computer_setup_repo_branch=main"* ]] || fail "repo branch not passed to the play: $args"
echo "  ok  the play is told the repo url and branch"

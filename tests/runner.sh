#!/bin/bash
# Behaviour of the RENDERED runner's scheduled path, against a scratch HOME with
# `git` and `ansible-pull` stubbed. Covers what check.sh otherwise only parses:
# the connectivity retry, the skip being diagnosable, and the per-mode stamps.
# Needs the pinned runtime on PATH (jinja2) and yq.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

T="$(mktemp -d)"
trap 'rm -rf -- "$T"; [[ -z "${holder:-}" ]] || kill "$holder" 2>/dev/null || true' EXIT
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
tpl = env.from_string(src)
open(t + "/bin/computer-setup", "w").write(tpl.render(**v))
open(t + "/bin/computer-setup-cached", "w").write(tpl.render(**dict(v, computer_setup_layer_cache=t + "/cache")))
PY
chmod +x "$T/bin/computer-setup" "$T/bin/computer-setup-cached"

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
runc() { HOME="$T/home" PATH="$T/bin:$PATH" "$T/bin/computer-setup-cached" "$@"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
latest_log() { printf '%s\n' "$T"/logs/*.log | sort | tail -n 1; }

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
out="$(run status)"
[[ "$out" != *BEHIND* ]] || fail "BEHIND shown with no upgrade stamp"
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

# 8. `layers new` scaffolds a lintable layer named as asked, and refuses to overwrite.
mkdir -p "$T/pull/examples"
cp -R "$ROOT/examples/example-layer" "$T/pull/examples/example-layer"
(cd "$T" && run layers new acme >/dev/null) || fail "layers new failed"
[[ "$(yq -r '.name' "$T/acme/layer.yml")" == acme ]] || fail "scaffold not renamed"
"$ROOT/scripts/computer-setup-layers" lint --layer "$T/acme" >/dev/null || fail "scaffold does not lint"
(cd "$T" && run layers new acme >/dev/null 2>&1) && fail "layers new overwrote an existing dir"
(cd "$T" && run layers new ../x >/dev/null 2>&1) && fail "layers new accepted a bad name"
echo "  ok  layers new scaffolds a lintable layer, refuses overwrite and bad names"

# 8b. `layers sync` and `layers lint` pass the machine file and keep explicit flags.
printf '#!/bin/bash\necho "$*"\n' > "$T/bin/computer-setup-layers"
chmod +x "$T/bin/computer-setup-layers"
[[ "$(run layers sync)" == "sync" ]] || fail "layers sync added args without a machine file"
touch "$T/none.yml"
[[ "$(run layers sync)" == "sync --manifest $T/none.yml" ]] || fail "layers sync did not pass the manifest"
[[ "$(run layers sync --manifest y.yml)" == "sync --manifest y.yml" ]] || fail "layers sync overrode --manifest"
[[ "$(run layers lint)" == "lint --manifest $T/none.yml --machine $T/none.yml" ]] || fail "layers lint args wrong"
[[ "$(run layers lint --layer x)" == "lint --manifest $T/none.yml --layer x" ]] || fail "layers lint --layer got --machine"
[[ "$(runc layers sync)" == "sync --manifest $T/none.yml --cache $T/cache" ]] || fail "layers sync did not default --cache"
[[ "$(runc layers sync --cache X)" == "sync --manifest $T/none.yml --cache X" ]] || fail "layers sync did not keep explicit --cache"
rm "$T/none.yml" "$T/bin/computer-setup-layers"
echo "  ok  layers sync/lint pass the manifest and respect explicit flags"

# 9. Pruning removes old successful logs and never an old failed one. A failed run
#    is identified by history.jsonl, so the log paths below must match it exactly.
printf '{"result":"failed","log":"%s"}\n{"result":"ok","log":"%s"}\n' \
    "$T/logs/old-failed.log" "$T/logs/old-ok.log" > "$T/state/history.jsonl"
touch -t 202001010000 "$T/logs/old-failed.log" "$T/logs/old-ok.log"
run apply >/dev/null 2>&1 || fail "apply failed before pruning"
[[ -e "$T/logs/old-failed.log" ]] || fail "pruning deleted a failed run's log"
[[ ! -e "$T/logs/old-ok.log" ]] || fail "pruning kept an old successful log"
echo "  ok  prune: an old failed log is kept, an old successful one removed"

# 10. status (text) against a fixture with changed, failed, partial and truncated
#     set. A task with no dest/item must not leave a trailing arrow.
rm -f "$T/state/last-success" "$T/state/last-success-upgrade" "$T/state/managed-paths.json"
cat > "$T/state/last-run.json" <<'JSON'
{"mode":"apply","result":"failed","finished":"2026-01-01T00:00:00+0000","duration_seconds":12,
 "partial":true,"truncated":true,"totals":{"changed":2,"failed":1},
 "changed":[{"task":"Install foo","dest":"/tmp/a"},{"task":"Loop task","item":"x"}],
 "failed":[{"task":"Broken"}]}
JSON
out="$(run status)"
for want in \
    "Last run:  apply — failed at 2026-01-01T00:00:00+0000 (12s)" \
    "(partial run — only part of the configuration was evaluated)" \
    "Changed:   2 task(s):" \
    "  - Install foo  →  /tmp/a" \
    "  - Loop task  →  x" \
    "  … list truncated" \
    "Failed:    1 task(s):" \
    "  - Broken" \
    "Run \`computer-setup log\` for the detail." \
    "Sync:      no successful scheduled run recorded yet"; do
    [[ "$out" == *"$want"* ]] || fail "status lacks '$want': $out"
done
[[ "$out" != *"Broken  →"* && "$out" != *BEHIND* && "$out" != *Orphans* ]] || fail "status shows what it should not: $out"
yq -i '.partial = true | .truncated = false' "$T/state/last-run.json"
out="$(run status)"
[[ "$out" == *"(partial run"* && "$out" != *"list truncated"* ]] || fail "partial-only status wrong: $out"
yq -i '.partial = false | .truncated = true' "$T/state/last-run.json"
out="$(run status)"
[[ "$out" == *"list truncated"* && "$out" != *"(partial run"* ]] || fail "truncated-only status wrong: $out"
yq -i '.mode = "check" | del(.partial) | del(.truncated) | del(.failed) | .totals.failed = 0' "$T/state/last-run.json"
out="$(run status)"
[[ "$out" == *"Drift:     2 task(s) would change:"* ]] || fail "check-mode drift line missing: $out"
[[ "$out" != *partial* && "$out" != *truncated* && "$out" != *Failed:* ]] || fail "status shows partial/truncated/failed for a clean check: $out"
yq -i '.changed = [] | .totals.changed = 0' "$T/state/last-run.json"
[[ "$(run status)" == *"Drift:     none"* ]] || fail "no-drift line missing"
date -v-2d '+%Y-%m-%dT%H:%M:%S%z' > "$T/state/last-success"
[[ "$(run status)" == *"Sync:      ok — last successful scheduled run 2 day(s) ago"* ]] || fail "Sync ok line missing"
date -v-20d '+%Y-%m-%dT%H:%M:%S%z' > "$T/state/last-success"
[[ "$(run status)" == *"Sync:      STALE — last successful scheduled run was 20 day(s) ago"* ]] || fail "Sync STALE line missing"
rm -f "$T/state/last-run.json"
[[ "$(run status)" == "No run recorded yet. Run \`computer-setup check\` to populate it." ]] || fail "empty-state message changed"
echo "  ok  status: changed/failed/partial/truncated, drift, sync, empty"

# 11. status --json, with the success stamp missing and present.
rm -f "$T/state/last-success" "$T/state/last-success-upgrade"
echo '{"mode":"check","result":"ok","finished":"x"}' > "$T/state/last-run.json"
js="$(run status --json)"
[[ "$(yq -p json -r '.last_success' <<<"$js")" == null ]] || fail "last_success not null without a stamp: $js"
[[ "$(yq -p json -r '.days_since_success' <<<"$js")" == null ]] || fail "days_since_success not null without a stamp"
[[ "$(yq -p json -r '.stale' <<<"$js")" == false ]] || fail "stale without a stamp"
[[ "$(yq -p json -r '.days_since_upgrade_success' <<<"$js")" == null ]] || fail "days_since_upgrade_success not null without a stamp"
[[ "$(yq -p json -r '.last_run.result' <<<"$js")" == ok ]] || fail "last_run not embedded"
stamp="$(date -v-20d '+%Y-%m-%dT%H:%M:%S%z')"
echo "$stamp" > "$T/state/last-success"
js="$(run status --json)"
[[ "$(yq -p json -r '.last_success' <<<"$js")" == "$stamp" ]] || fail "last_success not the stamp: $js"
[[ "$(yq -p json -r '.days_since_success' <<<"$js")" == 20 ]] || fail "days_since_success wrong: $js"
[[ "$(yq -p json -r '.stale' <<<"$js")" == true ]] || fail "20 days old is not stale"
rm -f "$T/state/last-run.json"
[[ "$(run status --json | yq -p json -r '.last_run')" == null ]] || fail "last_run not null without state"
echo "  ok  status --json: stamp missing/present, stale, last_run"

# 12. history [n]: the last n rows, a header, and a bad n is rejected (64).
printf '%s\n' \
    '{"finished":"2026-01-01T01:00:00+0000","mode":"check","result":"ok","partial":false,"changed":0,"failed":0,"duration_seconds":5,"log":"a"}' \
    '{"finished":"2026-01-02T01:00:00+0000","mode":"apply","result":"failed","partial":true,"changed":3,"failed":1,"duration_seconds":7,"log":"b"}' \
    '{"finished":"2026-01-03T01:00:00+0000","mode":"upgrade","result":"ok","partial":false,"changed":2,"failed":0,"duration_seconds":9,"log":"c"}' \
    > "$T/state/history.jsonl"
out="$(run history)"
[[ "$out" == *FINISHED*MODE*RESULT*CHANGED*FAILED*DURATION* ]] || fail "history header missing: $out"
[[ "$out" == *"2026-01-02T01:00:00+0000"*"apply*"*failed*3*1*7s* ]] || fail "partial row not starred: $out"
[[ "$out" == *"2026-01-01T01:00:00+0000"*check*ok* && "$out" != *"check*"* ]] || fail "plain row wrong: $out"
[[ "$out" == *"* = partial run"* ]] || fail "history footnote missing"
out="$(run history 1)"
[[ "$out" == *"2026-01-03"* && "$out" != *"2026-01-02"* ]] || fail "history 1 is not the last row only: $out"
err="$(run history abc 2>&1)" && fail "history abc accepted"
[[ "$err" == *"history: expected a number, got 'abc'"* ]] || fail "bad history n not explained: $err"
run history -1 >/dev/null 2>&1 && fail "history -1 accepted"
rm "$T/state/history.jsonl"
[[ "$(run history)" == "No history yet. It is appended to by every run." ]] || fail "empty history message changed"
echo "  ok  history: rows, n, bad n rejected, empty"

# 13. log: empty dir, newest of two shown, --list newest first, bad n rejected (64).
rm -rf "$T/logs"; mkdir "$T/logs"
[[ "$(run log)" == "No logs yet in $T/logs" ]] || fail "empty log dir message changed"
[[ "$(run log --list)" == "No logs yet in $T/logs" ]] || fail "empty log --list message changed"
printf 'old1\nold2\n' > "$T/logs/20260101-000000-check.log"
printf 'new1\nnew2\nnew3\n' > "$T/logs/20260102-000000-apply.log"
out="$(run log)"
[[ "$out" == "── $T/logs/20260102-000000-apply.log"$'\n\nnew1\nnew2\nnew3' ]] || fail "log did not show the latest: $out"
[[ "$(run log 1)" == *new3 && "$(run log 1)" != *new2* ]] || fail "log 1 is not the last line"
[[ "$(run log --list)" == "$T/logs/20260102-000000-apply.log"$'\n'"$T/logs/20260101-000000-check.log" ]] || fail "log --list not newest first"
err="$(run log abc 2>&1)" && fail "log abc accepted"
[[ "$err" == *"log: expected a number, got 'abc'"* ]] || fail "bad log n not explained: $err"
rc=0; err="$(run log -1 2>&1)" || rc=$?
[[ "$rc" == 64 ]] || fail "log -1 exit $rc, want 64"
[[ "$err" == *"log: expected a number, got '-1'"* ]] || fail "log -1 not rejected: $err"
echo "  ok  log: empty, latest, n, --list, bad n rejected"

# 14. manifest: counts and sections from a fixture; missing file is a message.
[[ "$(run manifest)" == "No manifest yet. Run \`computer-setup check\` to populate it." ]] || fail "missing manifest message changed"
cat > "$T/state/managed-paths.json" <<'JSON'
{"generated":"2026-01-05T00:00:00+0000",
 "files":[{"path":"/h/.zshrc","role":"shell"},{"path":"/h/.gitconfig","role":"git"}],
 "directories":[{"path":"/h/bin"}],
 "backups":[{"path":"/h/.zshrc.bak"}],
 "orphans":[{"path":"/h/.old","role":"tmux","since":"2026-01-01"}]}
JSON
out="$(run manifest)"
for want in "Recorded:  2026-01-05T00:00:00+0000" "Files (2):" "/h/.zshrc" "shell" "/h/.gitconfig" \
    "Directories (1):" "  /h/bin" "Backup copies left behind (1):" "  /h/.zshrc.bak" \
    "No longer managed, still on disk (1):" "/h/.old" "was tmux" "since 2026-01-01" \
    "Nothing is deleted automatically."; do
    [[ "$out" == *"$want"* ]] || fail "manifest lacks '$want': $out"
done
[[ "$(run manifest --json | yq -p json -r '.files | length')" == 2 ]] || fail "manifest --json not the file"
yq -i -o=json 'del(.backups[]) | del(.orphans[])' "$T/state/managed-paths.json"
out="$(run manifest)"
[[ "$out" != *"Backup copies"* && "$out" != *"No longer managed"* ]] || fail "empty backups/orphans still listed: $out"
echo "  ok  manifest: counts, sections, --json, empty sections hidden"

# 15. progress. Each branch reads the header (first line), the last line and the
#     file's mtime; there is no --json (the flag is ignored). Mutating any of the
#     parsed fields or the 300 s threshold must break one of these.
progress_file() { printf '%s\n' "$@" > "$T/state/progress.jsonl"; }
rm -f "$T/state/progress.jsonl"
[[ "$(run progress)" == "No run has recorded progress yet." ]] || fail "no-progress message changed"

progress_file '{"event":"launching","mode":"upgrade","run_id":"1","started":"x"}'
[[ "$(run progress)" == "upgrade  starting — syncing layers and fetching the orchestrator" ]] || fail "launching line changed"

HEAD='{"event":"start","mode":"apply","run_id":"1","total_estimate":40}'
progress_file "$HEAD" '{"event":"task","n":1,"task":"first"}' '{"event":"task","n":10,"task":"Install foo"}'
[[ "$(run progress)" == "apply  [#####...............] 25%  10/40"$'\n'"  now: Install foo" ]] || fail "running line changed: $(run progress)"
progress_file "$HEAD" '{"event":"task","n":50,"task":"Past the estimate"}'
[[ "$(run progress)" == "apply  [####################] 100%  50/40"$'\n'"  now: Past the estimate" ]] || fail "bar not clamped at 100%"
progress_file '{"event":"start","mode":"check","run_id":"1"}' '{"event":"task","n":4,"task":"No estimate"}'
[[ "$(run progress)" == "check  task 4 (no estimate yet — needs one completed run of this mode)"$'\n'"  now: No estimate" ]] || fail "no-estimate line changed"

progress_file "$HEAD" '{"event":"task","n":10,"task":"Install foo"}'
touch -t 202001010000 "$T/state/progress.jsonl"
out="$(run progress)"
[[ "$out" == "Stalled or interrupted — no progress for "*"m, stopped at task 10."$'\n'"  last: Install foo" ]] || fail "stalled line changed: $out"
touch -t "$(date -v-4M '+%Y%m%d%H%M')" "$T/state/progress.jsonl"
[[ "$(run progress)" == "apply  [#####"* ]] || fail "a 4-minute-old file counted as stalled"
touch -t "$(date -v-6M '+%Y%m%d%H%M')" "$T/state/progress.jsonl"
[[ "$(run progress)" == "Stalled or interrupted"* ]] || fail "a 6-minute-old file not stalled"

progress_file "$HEAD" '{"event":"task","n":10,"task":"Install foo"}' '{"event":"end","result":"failed","tasks":12}'
touch -t 202001010000 "$T/state/progress.jsonl"
[[ "$(run progress)" == "Not running. Last run: apply — failed (12 task(s))" ]] || fail "ended line changed (and an old file must not read as stalled)"
progress_file '{"event":"launching","mode":"upgrade"}' '{"event":"end","result":"ok","tasks":0}'
[[ "$(run progress)" == "Not running. Last run: upgrade — ok (0 task(s))" ]] || fail "end marker after launching header not honoured"

# Half-written last line (no newline, invalid JSON): today yq yields nothing, so
# n and the task are empty and the run reads as live (fresh) or stalled at "?".
printf '%s\n%s' "$HEAD" '{"event":"task","n":3,"ta' > "$T/state/progress.jsonl"
out="$(run progress)"
[[ "$out" == "apply  [....................] 0%  /40"$'\n'"  now: " ]] || fail "half-written last line (fresh) changed: $out"
touch -t 202001010000 "$T/state/progress.jsonl"
out="$(run progress)"
[[ "$out" == "Stalled or interrupted — no progress for "*"m, stopped at task ?."$'\n'"  last: " ]] || fail "half-written last line (stale) changed: $out"
printf '%s\n%s' "$HEAD" '{"event":"end","result":"ok","tas' > "$T/state/progress.jsonl"
[[ "$(run progress)" != "Not running"* ]] || fail "a half-written end marker was taken as an end"
[[ "$(run progress --json)" == "$(run progress)" ]] || fail "progress grew a --json mode"
echo "  ok  progress: absent, launching, running, clamp, no estimate, stalled, ended, half-written"

# 16. upgrade, on a pty (it refuses without a terminal on stdin). ansible-pull is
#     stubbed to record CS_SUDO_PASSWORD and its output; a yq stub records the
#     password as prune_logs sees it, i.e. after the run.
cat > "$T/bin/ansible-pull" <<STUB
#!/bin/bash
echo x >> "$T/pull-calls"
printf '%s\\n' "\$*" > "$T/pull-args"
printf '%s' "\${CS_SUDO_PASSWORD-UNSET}" > "$T/pull-pw"
printf '%s %s\\n' "\${CS_RUN_MODE-}" "\${CS_RUN_PARTIAL-}" > "$T/pull-mode"
echo PULL-OUTPUT
exit "\${PULL_RC:-0}"
STUB
cat > "$T/bin/yq" <<STUB
#!/bin/bash
printf '%s' "\${CS_SUDO_PASSWORD-UNSET}" > "$T/prune-pw"
exec "$(command -v yq)" "\$@"
STUB
chmod +x "$T/bin/ansible-pull" "$T/bin/yq"
cat > "$T/ptyrun.py" <<'PY'
import os, pty, sys
out, answers, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    if out != "-":
        os.dup2(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC), 1)
    os.execvp(cmd[0], cmd)
os.write(fd, answers.encode())
buf = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    buf += d
sys.stdout.write(buf.decode().replace("\r", ""))
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
PY
# $1 answers typed on the terminal, $2 file for stdout ("-" keeps it on the pty).
upgrade_tty() {
    rm -f "$T"/pull-{calls,args,pw,mode} "$T/prune-pw"
    HOME="$T/home" PATH="$T/bin:$PATH" "$RT_PY" "$T/ptyrun.py" "$2" "$1" "$T/bin/computer-setup" upgrade
}

rc=0; out="$(upgrade_tty $'y\nhunter2\n' -)" || rc=$?
[[ "$rc" == 0 ]] || fail "upgrade failed: rc=$rc $out"
[[ "$out" == *"Proceed? [y/N]: "* && "$out" == *"macOS password (Enter to skip those casks): "* ]] || fail "prompts changed: $out"
[[ "$out" == *PULL-OUTPUT* ]] || fail "upgrade did not stream ansible-pull to the terminal: $out"
[[ "$(cat "$(latest_log)")" != *hunter2* ]] || fail "the password reached the run log"
[[ "$(cat "$T/pull-pw")" == hunter2 ]] || fail "CS_SUDO_PASSWORD did not reach ansible-pull"
[[ "$(cat "$T/pull-args")" == *"--tags upgrade -e computer_setup_upgrade_assume_yes=true local.yml"* ]] || fail "upgrade args changed: $(cat "$T/pull-args")"
[[ "$(cat "$T/pull-mode")" == "upgrade 1" ]] || fail "upgrade not recorded as a partial upgrade run: $(cat "$T/pull-mode")"
[[ "$(cat "$T/prune-pw")" == UNSET ]] || fail "CS_SUDO_PASSWORD still set after the run (prune saw it)"
[[ "$(cat "$(latest_log)")" == *PULL-OUTPUT* ]] || fail "upgrade did not keep its output in the run log"
[[ ! -e "$T/state/run.lock" ]] || fail "upgrade left the lock behind"
[[ "$(yq -p json -o json -r '.mode' "$T/state/progress.jsonl")" == upgrade ]] || fail "upgrade did not claim the progress file"

rc=0; out="$(upgrade_tty $'y\n\n' -)" || rc=$?
[[ "$rc" == 0 && "$(cat "$T/pull-pw")" == UNSET ]] || fail "an empty password was exported: rc=$rc pw=$(cat "$T/pull-pw")"

rc=0; out="$(upgrade_tty $'n\n' -)" || rc=$?
[[ "$rc" == 0 && "$out" == *"Aborted — nothing changed."* ]] || fail "declining did not abort cleanly: rc=$rc $out"
[[ ! -e "$T/pull-calls" && "$out" != *"macOS password"* ]] || fail "declining still went on"

rc=0; out="$(PULL_RC=3 upgrade_tty $'y\nhunter2\n' -)" || rc=$?
[[ "$rc" == 3 ]] || fail "ansible-pull's exit code not returned: rc=$rc"
[[ ! -e "$T/prune-pw" ]] || fail "a failed upgrade pruned logs"

# Not a terminal on stdout: the run is still teed to stdout and logged, and the
# password still reaches ansible-pull. (Today no notification is sent either way;
# notify() calls an absolute /usr/bin/osascript, so it cannot be stubbed here.)
rc=0; upgrade_tty $'y\nhunter2\n' "$T/upgrade-stdout" >/dev/null || rc=$?
[[ "$rc" == 0 && "$(cat "$T/upgrade-stdout")" == *PULL-OUTPUT* ]] || fail "non-tty stdout: output no longer teed: rc=$rc"
[[ "$(cat "$T/pull-pw")" == hunter2 && "$(cat "$(latest_log)")" == *PULL-OUTPUT* ]] || fail "non-tty stdout: password or log lost"

rc=0; out="$(run upgrade </dev/null 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" == *"computer-setup upgrade needs a terminal to confirm on."* ]] || fail "no-terminal refusal changed: rc=$rc $out"
echo "  ok  upgrade: prompts, password reaches ansible-pull and is gone after, decline, rc, non-tty stdout, no terminal"

# 17. A held lock refuses the upgrade AFTER the prompts, without running anything.
rm -f "$T/pull-calls" "$T/prune-pw"
mkdir "$T/state/run.lock"; sleep 30 & holder=$!; echo "$holder" > "$T/state/run.lock/pid"
printf '{"event":"sentinel"}\n' > "$T/state/progress.jsonl"
rc=0; out="$(upgrade_tty $'y\nhunter2\n' -)" || rc=$?
kill "$holder"; wait "$holder" 2>/dev/null || true
rm -rf "$T/state/run.lock"
[[ "$rc" == 1 ]] || fail "a locked upgrade did not exit 1: rc=$rc"
[[ "$out" == *"macOS password"* ]] || fail "the lock was checked before the prompts"
[[ "$out" == *"another run is in progress (pid $holder)"* ]] || fail "refusal does not name the holder: $out"
[[ "$out" != *PULL-OUTPUT* ]] || fail "locked upgrade ran"
[[ ! -e "$T/pull-calls" && ! -e "$T/prune-pw" ]] || fail "ansible-pull ran while the lock was held"
[[ "$(cat "$T/state/progress.jsonl")" == '{"event":"sentinel"}' ]] || fail "a refused upgrade clobbered the live run's progress"
echo "  ok  upgrade: a held lock refuses after the prompts and runs nothing"

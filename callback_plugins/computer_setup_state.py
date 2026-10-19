# Managed by ansible — the engine's own callback plugin (docs/architecture.md, "Run state").
#
# Metadata only: task name, action, role and destination path. Never add
# `before`/`after`, `stdout`, `msg` or `_task.args` wholesale; diffs hold file contents.
# Every hook is wrapped: reporting must never fail a run.
from __future__ import absolute_import, division, print_function

import json
import os
import tempfile
import time

from ansible.plugins.callback import CallbackBase

__metaclass__ = type

DOCUMENTATION = """
    name: computer_setup_state
    type: aggregate
    short_description: Write a machine-readable run summary to CS_STATE_FILE
    description:
      - Records which tasks changed (or would change under --check), by name,
        role and destination path. Metadata only, never file contents.
      - Silently does nothing when CS_STATE_FILE is unset, so ordinary
        interactive runs are unaffected.
      - Records every managed filesystem path to CS_MANIFEST_FILE, so "what
        does this system own" is a question with an answer.
      - Appends one line per run to CS_HISTORY_FILE, so a machine has a history
        longer than its last run.
    requirements:
      - Set the CS_STATE_FILE environment variable to enable.
"""

# The shape below is a CONSUMED INTERFACE (`computer-setup status`, and any UI
# later). Bump on a breaking change and update the contract test in
# scripts/check.sh, the same way layers carry a schema_version.
STATE_SCHEMA_VERSION = 1

# The manifest is a SEPARATE interface with its own lifecycle: last-run.json
# describes one run and is rewritten every time, the manifest describes what the
# machine owns and is the basis for garbage collection. Versioned apart so
# either can change without forcing the other.
MANIFEST_SCHEMA_VERSION = 1

# A pathological run (a large loop over layer content) should not write an
# unbounded file. Past this, the count still reflects reality and `changed` is
# truncated — flagged by `truncated` so a reader never mistakes it for the whole.
MAX_RECORDED = 200

# History is versioned PER LINE, not per file. A JSONL file has no header, and
# lines written months apart genuinely can have different shapes — the old ones
# are never rewritten. A reader meeting a mixed file can then handle each line
# on its own terms, which a single file-level version could not express.
HISTORY_SCHEMA_VERSION = 1

# Progress is a LIVE file, rewritten from scratch by every run, and its shape is
# its own contract: a reader tailing it mid-run must be able to tell "task 40 of
# 193" from "finished" from "died half way".
PROGRESS_SCHEMA_VERSION = 1

# Runs of history to keep. Two scheduled runs a day makes this most of a year,
# at roughly 200 bytes a line. Deliberately NOT capped the way `changed` is:
# an inventory or a history that silently drops entries is worse than a big
# file, so this trims the OLDEST rather than refusing the newest.
MAX_HISTORY = 500

# Modules that put something on disk at a path we could later have to remove.
# An allow-list, not a deny-list: a module absent from here contributes nothing
# to the manifest, which fails safe (an orphan survives). `command`/`shell` are
# deliberately absent — nvm, tfenv and editor extensions write through them and
# the path is unknowable from the callback.
WRITE_ACTIONS = frozenset((
    "copy", "template", "file", "lineinfile", "blockinfile",
    "assemble", "get_url", "unarchive", "ini_file",
))


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "computer_setup_state"
    # Aggregate callbacks run alongside the stdout callback rather than
    # replacing it, so the human-readable log keeps its normal format.
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self, *args, **kwargs):
        super(CallbackModule, self).__init__(*args, **kwargs)
        self.state_file = os.environ.get("CS_STATE_FILE") or ""
        self.run_mode = os.environ.get("CS_RUN_MODE") or "apply"
        # A run narrowed by --tags/--limit describes only what it looked at.
        # Recorded so a reader cannot mistake "nothing changed in the one role I
        # ran" for "this machine matches its configuration".
        self.partial = os.environ.get("CS_RUN_PARTIAL") == "1"
        self.changed = []
        self.failed = []
        self.truncated = False
        # Both are independent opt-ins, like state_file: a caller that wants a
        # run summary but no inventory simply does not set them.
        self.manifest_file = os.environ.get("CS_MANIFEST_FILE") or ""
        self.history_file = os.environ.get("CS_HISTORY_FILE") or ""
        # Live progress, for a UI to tail while the run is happening. Truncated
        # at the first task rather than appended to: the previous run's progress
        # is of no interest, and a reader must never see two runs interleaved.
        self.progress_file = os.environ.get("CS_PROGRESS_FILE") or ""
        # This run's own log. Recorded into the history line so every entry can
        # be traced to the output it produced — which is what lets a "recent
        # runs" list be clickable rather than decorative.
        self.log_file = os.environ.get("CS_LOG_FILE") or ""
        self.progress_handle = None
        self.task_number = 0
        # Identifies THIS invocation across every play it runs. ansible-pull can
        # reach the stats hook more than once (its own checkout play, then the
        # real one), and history is appended rather than overwritten — so
        # without this a single run could leave two lines. Keyed rather than
        # counted, because the two plays may be separate processes.
        self.run_id = os.environ.get("CS_RUN_ID") or ""
        # path -> entry. A dict, so a path deployed by two tasks (a parent
        # directory created by several roles) is recorded once.
        self.managed_files = {}
        self.managed_dirs = {}
        self.managed_backups = {}
        # The plugin is constructed as the play starts, so this is the run's
        # start within a second. Recorded because "the 10:00 check now takes
        # four minutes" is a thing worth being able to see, and it cannot be
        # reconstructed after the fact.
        self.started = time.time()

    # ── helpers ──────────────────────────────────────────────────────────────
    def _dest_from_args(self, task):
        """The task's declared destination; checked first because a new file's diff has no `before_header`."""
        args = getattr(task, "args", {}) or {}
        # Only dest/path: other args are `_ansible_*` internals or long name lists.
        for key in ("dest", "path"):
            value = args.get(key)
            # A looped task's dest is still "{{ item.x }}" here; the per-item
            # results below carry the rendered one.
            if isinstance(value, str) and value and "{{" not in value:
                return value
        return None

    def _dest_from_diff(self, diff):
        """The path a diff refers to: `before_header` only, since `after_header` is a temp render source."""
        # The file module returns a bare dict diff with no headers.
        if isinstance(diff, dict):
            diff = [diff]
        if not isinstance(diff, list):
            return None
        for entry in diff:
            if isinstance(entry, dict):
                header = entry.get("before_header")
                if isinstance(header, str) and header:
                    return header
        return None

    def _dest_from_item(self, item):
        """The path a loop item names: a bare path or its `dest`/`path` key, never the whole item."""
        if isinstance(item, str) and item.startswith("/"):
            return item
        if isinstance(item, dict):
            for key in ("dest", "path"):
                value = item.get(key)
                if isinstance(value, str) and value.startswith("/"):
                    return value
        return None

    def _entry(self, task, dest, label=None):
        # `.name`, not `get_name()`: the latter returns "git : Deploy the
        # managed git config", duplicating the `role` field below and forcing
        # every consumer to strip a prefix to display a task name. Unnamed tasks
        # have an empty `.name`, so fall back to the module they run.
        entry = {"task": (getattr(task, "name", "") or task.action), "action": task.action}
        try:
            role = task._role
            if role:
                entry["role"] = role.get_name()
        except Exception:
            pass
        if dest:
            entry["dest"] = dest
        elif label:
            # A looped task with no path still has to say WHICH item changed.
            # `_ansible_item_label` is the loop_control label Ansible already
            # computes, so this is generic: without it, two missing credentials
            # or two failed packages render as two identical lines.
            entry["item"] = label
        return entry

    def _record(self, bucket, result):
        """Append one entry per changed thing, per item for a looped task (whose task-level `dest` is unrendered)."""
        if not self.state_file:
            return
        try:
            task = result._task
            payload = result._result
            sub_results = payload.get("results")

            if isinstance(sub_results, list) and sub_results:
                for sub in sub_results:
                    if not isinstance(sub, dict) or not sub.get("changed"):
                        continue
                    if len(bucket) >= MAX_RECORDED:
                        self.truncated = True
                        return
                    dest = self._dest_from_diff(sub.get("diff"))
                    if not dest:
                        dest = self._dest_from_item(sub.get("item"))
                    label = sub.get("_ansible_item_label")
                    if not isinstance(label, str):
                        label = None
                    bucket.append(self._entry(task, dest, label))
                return

            if len(bucket) >= MAX_RECORDED:
                self.truncated = True
                return
            dest = self._dest_from_args(task) or self._dest_from_diff(payload.get("diff"))
            bucket.append(self._entry(task, dest))
        except Exception:
            pass

    # ── the manifest: what this system owns ──────────────────────────────────
    def _manifest_entry(self, task, dest):
        entry = {"path": dest, "action": task.action.split(".")[-1]}
        name = getattr(task, "name", "") or ""
        if name:
            entry["task"] = name
        try:
            role = task._role
            if role:
                entry["role"] = role.get_name()
        except Exception:
            pass
        return entry

    def _inventory(self, result):
        """Record every path this run manages, changed or not; skipped tasks stay absent (architecture.md, "The manifest")."""
        if not self.manifest_file:
            return
        try:
            task = result._task
            action = task.action.split(".")[-1]
            if action not in WRITE_ACTIONS:
                return
            payload = result._result
            args = getattr(task, "args", {}) or {}

            def absorb(dest, state, sub):
                if not isinstance(dest, str) or not dest.startswith("/"):
                    return
                # A removal is the opposite of a managed path — recording it
                # would have collection re-delete what it just deleted, forever.
                if state == "absent":
                    return
                bucket = self.managed_dirs if state == "directory" else self.managed_files
                bucket.setdefault(dest, self._manifest_entry(task, dest))
                # `backup: true` leaves <dest>.<pid>.<date>@<time>~ beside the
                # file and nothing ever removes it. Ansible names it in the
                # result, so it is captured here rather than guessed at later
                # with a glob.
                backup = sub.get("backup_file")
                if isinstance(backup, str) and backup.startswith("/"):
                    self.managed_backups.setdefault(
                        backup, self._manifest_entry(task, backup))

            sub_results = payload.get("results")
            if isinstance(sub_results, list) and sub_results:
                for sub in sub_results:
                    if not isinstance(sub, dict) or sub.get("skipped"):
                        continue
                    item = sub.get("item")
                    state = args.get("state")
                    if isinstance(item, dict) and item.get("state"):
                        state = item["state"]
                    # Result dest, then diff header, then rendered item (architecture.md, "The manifest").
                    dest = sub.get("dest") or sub.get("path")
                    if not isinstance(dest, str) or not dest.startswith("/"):
                        dest = self._dest_from_diff(sub.get("diff"))
                    if not dest:
                        dest = self._dest_from_item(sub.get("item"))
                    absorb(dest, state, sub)
                return

            dest = payload.get("dest") or payload.get("path")
            if not isinstance(dest, str) or not dest.startswith("/"):
                # Falls back to the task args, which ARE rendered by the time a
                # task has run. Only a loop leaves "{{ item.x }}" here, and
                # loops are handled above.
                dest = args.get("dest") or args.get("path")
                if isinstance(dest, str) and "{{" in dest:
                    dest = None
            absorb(dest, args.get("state"), payload)
        except Exception:
            pass

    # ── live progress ────────────────────────────────────────────────────────
    def _estimate_total(self):
        """Task count of the previous run of the same mode (architecture.md, "Live progress")."""
        if not self.history_file:
            return None
        try:
            with open(self.history_file) as stream:
                lines = [line for line in stream.read().splitlines() if line.strip()]
            for line in reversed(lines):
                record = json.loads(line)
                if record.get("mode") == self.run_mode and record.get("tasks"):
                    return record["tasks"]
        except Exception:
            pass
        return None

    def _progress(self, payload):
        if not self.progress_file:
            return
        try:
            if self.progress_handle is None:
                directory = os.path.dirname(self.progress_file) or "."
                try:
                    os.makedirs(directory, mode=0o700)
                except OSError:
                    pass
                # Truncating, not appending: see __init__.
                self.progress_handle = open(self.progress_file, "w")
                os.chmod(self.progress_file, 0o600)
                header = {
                    "schema_version": PROGRESS_SCHEMA_VERSION,
                    "event": "start",
                    "mode": self.run_mode,
                    "partial": self.partial,
                    "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "total_estimate": self._estimate_total(),
                }
                if self.run_id:
                    header["run_id"] = self.run_id
                self.progress_handle.write(json.dumps(header, sort_keys=True) + "\n")
            self.progress_handle.write(json.dumps(payload, sort_keys=True) + "\n")
            # Flushed every line, or a reader tailing the file sees nothing
            # until the run ends — which is the one moment it does not need it.
            self.progress_handle.flush()
        except Exception:
            # A progress file is a convenience. It must never cost a run.
            self.progress_file = ""

    def v2_playbook_on_task_start(self, task, is_conditional):
        self.task_number += 1
        entry = {"event": "task", "n": self.task_number,
                 "task": (getattr(task, "name", "") or task.action)}
        try:
            role = task._role
            if role:
                entry["role"] = role.get_name()
        except Exception:
            pass
        self._progress(entry)

    # A handler is a task too, and it runs AFTER the last ordinary one — so a
    # bar that stopped at the estimate would sit at 100% through the handlers.
    def v2_playbook_on_handler_task_start(self, task):
        self.task_number += 1
        self._progress({"event": "task", "n": self.task_number, "handler": True,
                        "task": (getattr(task, "name", "") or task.action)})

    # ── hooks ────────────────────────────────────────────────────────────────
    def v2_runner_on_ok(self, result):
        try:
            # `changed` is the whole signal: under --check it means "would
            # change", which is exactly what drift detection asks.
            if result._result.get("changed"):
                self._record(self.changed, result)
            self._inventory(result)
        except Exception:
            pass

    def v2_runner_on_failed(self, result, ignore_errors=False):
        try:
            if not ignore_errors:
                self._record(self.failed, result)
        except Exception:
            pass

    def v2_runner_on_unreachable(self, result):
        self._record(self.failed, result)

    def v2_playbook_on_stats(self, stats):
        """Write the run's four artifacts (state, manifest, history, progress end marker), each independently."""
        if not (self.state_file or self.manifest_file
                or self.history_file or self.progress_file):
            return
        # Ansible's summary key is `failures`, ours is `failed`; reading `failed` yields 0 forever.
        summary_keys = {
            "ok": "ok",
            "changed": "changed",
            "failed": "failures",
            "unreachable": "unreachable",
            "skipped": "skipped",
        }
        totals = dict.fromkeys(summary_keys, 0)
        try:
            for host in stats.processed.keys():
                summary = stats.summarize(host)
                for ours, theirs in summary_keys.items():
                    totals[ours] += summary.get(theirs, 0)
        except Exception:
            totals = dict.fromkeys(summary_keys, 0)
        result = "failed" if (totals["failed"] or totals["unreachable"]) else "ok"

        # Own try: an unwritable state file must not take the totals down with it.
        try:
            payload = {
                "schema_version": STATE_SCHEMA_VERSION,
                "mode": self.run_mode,
                "partial": self.partial,
                "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "duration_seconds": round(time.time() - self.started, 1),
                "result": result,
                "totals": totals,
                "changed": self.changed,
                "failed": self.failed,
                "truncated": self.truncated,
            }
            if self.state_file:
                self._write(self.state_file, payload)
        except Exception:
            pass

        try:
            self._write_manifest(result)
        except Exception:
            pass
        try:
            self._append_history(totals, result)
        except Exception:
            pass

        # Last, always: the `end` line is how a reader tells a finished run from a dead one.
        try:
            self._progress({
                "event": "end",
                "result": result,
                "tasks": self.task_number,
                "changed": totals["changed"],
                "failed": totals["failed"],
                "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            })
            if self.progress_handle is not None:
                self.progress_handle.close()
                self.progress_handle = None
        except Exception:
            pass

    def _write_manifest(self, result):
        """Write the manifest only for a complete run (not partial, not failed); see architecture.md."""
        if not self.manifest_file:
            return
        complete = not self.partial and result == "ok"
        if not complete:
            return

        previous = {}
        try:
            with open(self.manifest_file) as stream:
                loaded = json.load(stream)
            if isinstance(loaded, dict):
                previous = loaded
        except Exception:
            pass

        files = sorted(self.managed_files.values(), key=lambda e: e["path"])
        directories = sorted(self.managed_dirs.values(), key=lambda e: e["path"])
        payload = {
            "schema_version": MANIFEST_SCHEMA_VERSION,
            "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "mode": self.run_mode,
            "partial": self.partial,
            "complete": complete,
            "files": files,
            "directories": directories,
            # Backup litter: nothing reads or removes it, so it is listed apart.
            "backups": sorted(self.managed_backups.values(), key=lambda e: e["path"]),
            "orphans": self._orphans(previous, files),
        }
        self._write(self.manifest_file, payload)

    def _orphans(self, previous, files):
        """Paths once managed, still on disk, no longer written; reported only, carried forward (architecture.md, "Orphans")."""
        current = {entry["path"] for entry in files}
        # Anything the previous run listed as managed, including its own
        # orphans: a path stays reported until it is gone or is managed again.
        candidates = {}
        listed = []
        for key in ("files", "orphans"):
            value = previous.get(key)
            if isinstance(value, list):
                listed += value
        for entry in listed:
            if not isinstance(entry, dict):
                continue
            path = entry.get("path")
            if not isinstance(path, str) or path in current:
                continue
            candidates[path] = entry

        orphans = []
        for path, entry in sorted(candidates.items()):
            try:
                if not os.path.lexists(path):
                    continue
            except Exception:
                continue
            record = {"path": path}
            # Kept from when it WAS managed: "which role used to own this" is
            # the question someone asks when deciding whether to delete it.
            for key in ("role", "task", "action"):
                if entry.get(key):
                    record[key] = entry[key]
            # Preserved across runs so the report can say how long it has been
            # unmanaged, rather than resetting to "since the last run".
            record["since"] = entry.get("since") or time.strftime("%Y-%m-%dT%H:%M:%S%z")
            orphans.append(record)
        return orphans

    def _append_history(self, totals, result):
        """One line per run, oldest trimmed (architecture.md, "Run history")."""
        if not self.history_file:
            return
        record = {
            "schema_version": HISTORY_SCHEMA_VERSION,
            "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "mode": self.run_mode,
            "partial": self.partial,
            "result": result,
            "duration_seconds": round(time.time() - self.started, 1),
            "changed": totals["changed"],
            "failed": totals["failed"],
            "ok": totals["ok"],
            # Counted, not derived from totals: a looped task is one task but many results.
            "tasks": self.task_number,
        }
        if self.log_file:
            record["log"] = self.log_file
        if self.run_id:
            record["run_id"] = self.run_id

        directory = os.path.dirname(self.history_file) or "."
        try:
            os.makedirs(directory, mode=0o700)
        except OSError:
            pass

        lines = []
        if os.path.exists(self.history_file):
            with open(self.history_file, "r") as stream:
                lines = [line for line in stream.read().splitlines() if line.strip()]

        # Same invocation, second play: replace rather than append.
        if self.run_id and lines:
            try:
                if json.loads(lines[-1]).get("run_id") == self.run_id:
                    lines.pop()
            except ValueError:
                pass

        lines.append(json.dumps(record, sort_keys=True))
        lines = lines[-MAX_HISTORY:]

        handle, tmp_path = tempfile.mkstemp(dir=directory, prefix=".history-")
        try:
            with os.fdopen(handle, "w") as stream:
                stream.write("\n".join(lines) + "\n")
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, self.history_file)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

    def _write(self, target, payload):
        """Atomic 0600 write: temp file plus rename, so readers never see a half-written file."""
        directory = os.path.dirname(target) or "."
        try:
            os.makedirs(directory, mode=0o700)
        except OSError:
            pass  # exists
        handle, tmp_path = tempfile.mkstemp(dir=directory, prefix=".state-")
        try:
            with os.fdopen(handle, "w") as stream:
                json.dump(payload, stream, indent=2, sort_keys=True)
                stream.write("\n")
            os.chmod(tmp_path, 0o600)
            os.replace(tmp_path, target)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

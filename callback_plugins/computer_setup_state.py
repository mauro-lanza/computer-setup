# Managed by ansible — the engine's own callback plugin.
#
# Writes a machine-readable summary of a run to CS_STATE_FILE, so that "what
# changed / what drifted" is a FILE ANYTHING CAN READ rather than something
# scraped out of Ansible's console output.
#
# WHY A PLUGIN AND NOT A PARSER
# `ansible-pull` emits its own checkout play plus the real play, and prints
# `[WARNING]` lines interleaved between them. Under the json stdout callback
# that is two concatenated JSON documents with non-JSON text in the middle —
# strictly harder to parse than the `changed=N` text it would replace. A
# callback writes structured data directly and never touches stdout, so the
# human-readable log is unaffected and there is no parsing step at all.
#
# METADATA ONLY, DELIBERATELY
# Ansible's diffs carry full before/after FILE CONTENTS. That is your gitconfig
# identity and anything else a managed file happens to hold, so none of it is
# recorded here: a task name, its role, and the destination path only. Enough to
# answer "what would change", not enough to leak a file. Do not add `before`,
# `after`, `stdout`, `msg` from arbitrary tasks, or `_task.args` wholesale.
#
# NEVER BREAKS A RUN
# Every hook is wrapped: a bug in here must not fail a machine's provisioning.
# Reporting is strictly less important than converging.
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
        """The task's declared destination.

        Authoritative and checked FIRST, because it is the only source that
        works for a file being created: a new file's diff carries no
        `before_header` at all.

        Only these two keys are ever read. A module's args also carry every
        `_ansible_*` internal, and `name` on a package module is a long list —
        none of which is a path, and none of which belongs in a report.
        """
        args = getattr(task, "args", {}) or {}
        for key in ("dest", "path"):
            value = args.get(key)
            # A looped task's dest is still "{{ item.x }}" here; the per-item
            # results below carry the rendered one.
            if isinstance(value, str) and value and "{{" not in value:
                return value
        return None

    def _dest_from_diff(self, diff):
        """The path a diff refers to.

        `before_header` ONLY. For a template task `after_header` is Ansible's
        temporary rendered source (…/ansible-local-*/tmp*/foo.j2), not the
        destination — recording it produced entries pointing at a temp dir that
        no longer exists.

        The `file` module returns a dict rather than a list, and carries no
        headers; it is normalised here and simply yields nothing.
        """
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
        """The path a loop item refers to.

        Needed because a loop CREATING files has neither a usable task-level
        `dest` (it is still "{{ item.dest }}") nor a `before_header` (nothing
        exists to diff against). The rendered item is the only place left that
        names the file.

        Narrow on purpose: a bare path string, or the two conventional keys.
        Never the whole item, which is arbitrary layer data.
        """
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
        """Append one entry per changed thing — per ITEM for a looped task.

        A loop reports once at task level with a `results` list, and its
        task-level `dest` is the unrendered template. Recording the task alone
        would say "Deploy per-directory identity files" and never say which
        files, which is most of the value.
        """
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
        """Record every path this run manages, changed or not.

        The difference from `_record` is the whole point: drift is an EVENT, so
        it only lists what changed. An inventory is a STATE, so a file that is
        already correct still has to appear — otherwise the manifest would empty
        itself out on a converged machine, which is exactly when it matters.

        Skipped tasks are deliberately absent. A task skipped because its
        capability was deselected no longer manages its path, and that path
        dropping out of the manifest is precisely the signal collection needs.
        """
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
                    # Three sources, in order, because no single one covers
                    # both a converged run and a first one:
                    #   result dest — present once the file EXISTS
                    #   diff header — present when it exists and is changing
                    #   rendered item — the only one that survives creating a
                    #     file under --check, where the first two are empty
                    # Without the last, a fresh machine's first manifest was
                    # missing every loop-created file: eight shell snippets and
                    # every LaunchAgent plist.
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
        """Write the run's three artifacts, once, at the end of the play.

        `ansible-pull` runs its own checkout play before the real one. Both
        reach this hook, and the LAST write wins — which is the real play, the
        one worth recording. History is APPENDED rather than overwritten, so it
        is keyed on the run id instead of relying on that.

        Each artifact is an independent opt-in and gets its own try block: a
        caller may want a run summary and no inventory, and a failure to write
        one must not cost the others — least of all the run itself.
        """
        if not (self.state_file or self.manifest_file or self.history_file):
            return
        try:
            # Ansible's summary calls it `failures`; this file has always
            # published it as `failed`, to match the `failed` list beside it.
            # Mapped explicitly — reading `failed` straight out of the summary
            # silently yields 0 forever, which is how a failed run reported
            # itself as ok until this was caught.
            summary_keys = {
                "ok": "ok",
                "changed": "changed",
                "failed": "failures",
                "unreachable": "unreachable",
                "skipped": "skipped",
            }
            totals = dict.fromkeys(summary_keys, 0)
            for host in stats.processed.keys():
                summary = stats.summarize(host)
                for ours, theirs in summary_keys.items():
                    totals[ours] += summary.get(theirs, 0)

            payload = {
                "schema_version": STATE_SCHEMA_VERSION,
                "mode": self.run_mode,
                "partial": self.partial,
                "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "duration_seconds": round(time.time() - self.started, 1),
                "result": "failed" if (totals["failed"] or totals["unreachable"]) else "ok",
                "totals": totals,
                "changed": self.changed,
                "failed": self.failed,
                "truncated": self.truncated,
            }
            if self.state_file:
                self._write(self.state_file, payload)
        except Exception:
            totals = {k: 0 for k in
                      ("ok", "changed", "failed", "unreachable", "skipped")}

        try:
            self._write_manifest(totals)
        except Exception:
            pass
        try:
            self._append_history(totals)
        except Exception:
            pass

    def _write_manifest(self, totals):
        """The set of paths this system owns, as of the last COMPLETE run.

        Not written at all by a partial or failed run. Such a run saw a fraction
        of the machine — `--tags git` sees three files of twenty-seven — and
        writing that fraction would destroy the inventory until the next full
        run, which is exactly when someone asking "what does this own" gets a
        wrong answer. The previous complete manifest is a better answer than a
        fresh incomplete one, so it is left alone.

        `complete` stays in the payload even though it is now always true: a
        consumer should be able to check the property rather than having to know
        the rule that guarantees it.
        """
        if not self.manifest_file:
            return
        complete = (
            not self.partial
            and not totals["failed"]
            and not totals["unreachable"]
        )
        if not complete:
            return

        previous = {}
        try:
            with open(self.manifest_file) as stream:
                previous = json.load(stream)
        except Exception:
            previous = {}

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
            # Ansible's `backup: true` residue. Listed apart from `files`
            # because they are the one class here that is pure litter: nothing
            # reads them and nothing else will ever remove them.
            "backups": sorted(self.managed_backups.values(), key=lambda e: e["path"]),
            "orphans": self._orphans(previous, files),
        }
        self._write(self.manifest_file, payload)

    def _orphans(self, previous, files):
        """Paths this system used to manage, still on disk, no longer written.

        REPORTED ONLY. Nothing deletes them; this is the evidence a collection
        step would eventually act on, and the point of shipping it first is to
        watch it be right for a while before anything is destructive.

        Carried forward rather than recomputed from scratch. A naive
        previous-minus-current diff reports an orphan exactly once — the next
        run's "previous" no longer lists it either, so it silently disappears
        while the file is still sitting there. An orphan therefore stays on the
        list until it stops existing or comes back under management.

        Directories are deliberately not tracked. A directory falling out of the
        manifest almost always means its contents did too, and removing
        directories is a categorically larger blast radius than removing the
        files this system wrote — `~/Library/Logs` and `~/.local/bin` are both
        in here, and neither is ours to delete.
        """
        current = {entry["path"] for entry in files}
        # Anything the previous run listed as managed, including its own
        # orphans: a path stays reported until it is gone or is managed again.
        candidates = {}
        for entry in previous.get("files", []) + previous.get("orphans", []):
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

    def _append_history(self, totals):
        """One line per run, oldest trimmed.

        JSON Lines rather than a JSON array: appending to an array means reading
        and rewriting the whole file, and a run that dies mid-write leaves
        invalid JSON. A truncated last line costs one record.

        The full log is capped at 5000 lines, which is about three days. This is
        the record that outlives it — deliberately tiny, so it can.
        """
        if not self.history_file:
            return
        record = {
            "schema_version": HISTORY_SCHEMA_VERSION,
            "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "mode": self.run_mode,
            "partial": self.partial,
            "result": "failed"
            if (totals["failed"] or totals["unreachable"])
            else "ok",
            "duration_seconds": round(time.time() - self.started, 1),
            "changed": totals["changed"],
            "failed": totals["failed"],
            "ok": totals["ok"],
        }
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

        # Same run, second play: replace rather than append. ansible-pull can
        # reach this hook more than once per invocation, and two lines for one
        # run would make every rate or count computed from this file wrong.
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
        """Atomic, 0600.

        Written to a temp file in the same directory and renamed: a reader (the
        `status` command, a UI polling it) must never observe a half-written
        file, and rename is atomic within a filesystem.
        """
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

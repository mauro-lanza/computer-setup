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
    requirements:
      - Set the CS_STATE_FILE environment variable to enable.
"""

# The shape below is a CONSUMED INTERFACE (`computer-setup status`, and any UI
# later). Bump on a breaking change and update the contract test in
# scripts/check.sh, the same way layers carry a schema_version.
STATE_SCHEMA_VERSION = 1

# A pathological run (a large loop over layer content) should not write an
# unbounded file. Past this, the count still reflects reality and `changed` is
# truncated — flagged by `truncated` so a reader never mistakes it for the whole.
MAX_RECORDED = 200


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

    # ── hooks ────────────────────────────────────────────────────────────────
    def v2_runner_on_ok(self, result):
        try:
            # `changed` is the whole signal: under --check it means "would
            # change", which is exactly what drift detection asks.
            if result._result.get("changed"):
                self._record(self.changed, result)
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
        """Write the state file once, at the end of the play.

        `ansible-pull` runs its own checkout play before the real one. Both
        reach this hook, and the LAST write wins — which is the real play, the
        one worth recording.
        """
        if not self.state_file:
            return
        try:
            totals = {"ok": 0, "changed": 0, "failed": 0, "unreachable": 0, "skipped": 0}
            for host in stats.processed.keys():
                summary = stats.summarize(host)
                for key in totals:
                    totals[key] += summary.get(key, 0)

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
            self._write(payload)
        except Exception:
            pass

    def _write(self, payload):
        """Atomic, 0600.

        Written to a temp file in the same directory and renamed: a reader (the
        `status` command, a UI polling it) must never observe a half-written
        file, and rename is atomic within a filesystem.
        """
        directory = os.path.dirname(self.state_file) or "."
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
            os.replace(tmp_path, self.state_file)
        except Exception:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise

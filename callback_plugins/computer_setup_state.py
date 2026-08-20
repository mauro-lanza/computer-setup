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

    # ── helpers ──────────────────────────────────────────────────────────────
    def _dest_of(self, result):
        """Destination path only — never the diff payload.

        Prefers the diff header, which is the path Ansible actually acted on,
        and falls back to the task's own dest/path argument.
        """
        try:
            diff = result._result.get("diff")
            if isinstance(diff, list):
                for entry in diff:
                    if isinstance(entry, dict):
                        header = entry.get("after_header") or entry.get("before_header")
                        if header:
                            return str(header)
            args = getattr(result._task, "args", {}) or {}
            for key in ("dest", "path", "name"):
                value = args.get(key)
                # Only ever a string: `name` on a package module can be a long
                # list, and an unrendered template is not a path.
                if isinstance(value, str) and value and "{{" not in value:
                    return value
        except Exception:
            pass
        return None

    def _record(self, bucket, result):
        if not self.state_file:
            return
        try:
            if len(bucket) >= MAX_RECORDED:
                self.truncated = True
                return
            task = result._task
            entry = {
                "task": task.get_name(),
                "action": task.action,
            }
            role = task._role
            if role:
                entry["role"] = role.get_name()
            dest = self._dest_of(result)
            if dest:
                entry["dest"] = dest
            bucket.append(entry)
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

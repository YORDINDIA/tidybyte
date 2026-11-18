#!/usr/bin/env python3
"""End-to-end test for the tidybyte-mcp server over stdio JSON-RPC.

Builds a small duplicate fixture, drives the real server binary through the
full agent flow (initialize, scan, inspect, mandatory dry-run, confirmed
execute, history, confirmed undo), and checks the on-disk effects of an APFS
fold and its undo through inode identity.

Containment. Every path the server sees is inside one fresh temporary
directory (ROOT). The scan covers only ROOT/a and ROOT/b. HOME, TMPDIR and the
history database also sit inside ROOT. A CANARY directory outside ROOT holds a
byte-identical copy of the fixture; the run fails if the canary changes, and
if anything appears under ROOT that the test did not create. Both directories
are removed at the end.

Usage: Scripts/mcp-e2e.py [path-to-tidybyte-mcp-binary]
"""

import hashlib
import json
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile

REQUEST_TIMEOUT = 120.0  # seconds
OLD_TS = 1700000000  # any timestamp outside the fold's quiet period
# Resolve before anything changes directory: the server runs with cwd set to the
# fixture, so a relative path would resolve inside the fixture and not be found.
BINARY = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/tidybyte-mcp")
# The only SQLite files the server writes next to its database.
DATABASE_FILES = ("mcp-e2e.sqlite", "mcp-e2e.sqlite-wal", "mcp-e2e.sqlite-shm")


class MCPClient:
    def __init__(self, proc):
        self.proc = proc
        self.next_id = 0

    def request(self, method, params=None, timeout=REQUEST_TIMEOUT):
        self.next_id += 1
        payload = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            payload["params"] = params
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()
        line = self._readline_bounded(timeout)
        if not line:
            raise RuntimeError(f"server closed the stream during {method}")
        return json.loads(line)

    def _readline_bounded(self, timeout):
        # A wedged server must fail the e2e in seconds, not at the CI job
        # timeout. select() bounds the wait for the next line.
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not ready:
            self.proc.kill()
            raise RuntimeError(f"server sent no reply within {timeout:.0f} seconds")
        return self.proc.stdout.readline()

    def call(self, tool, arguments=None):
        response = self.request("tools/call", {"name": tool, "arguments": arguments or {}})
        result = response["result"]
        text = result["content"][0]["text"]
        return result.get("isError", False), text


def identity(path):
    st = os.lstat(path)
    return (st.st_dev, st.st_ino)


def tree(top):
    """Every entry under top: relative path mapped to device, inode, size, mtime and,
    for regular files, a SHA-256 of the bytes. A same-size rewrite with restored
    metadata still changes the digest. A missing top yields {}."""
    entries = {}
    for dirpath, dirnames, filenames in os.walk(top):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            st = os.lstat(path)
            digest = None
            if os.path.isfile(path) and not os.path.islink(path):
                with open(path, "rb") as f:
                    digest = hashlib.sha256(f.read()).hexdigest()
            entries[os.path.relpath(path, top)] = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, digest)
    return entries


def inside(root, path):
    """True when path is root itself or lies below it."""
    return path == root or path.startswith(root + os.sep)


def main():
    if not os.path.exists(BINARY):
        print(f"FAIL: binary not found at {BINARY}; run swift build first")
        return 2

    # Paths keep the tempfile spelling, which the server reports back in history.
    # Containment checks compare resolved paths.
    root = tempfile.mkdtemp(prefix="mcp-e2e-")
    canary = tempfile.mkdtemp(prefix="mcp-e2e-canary-")
    temp_parent = os.path.realpath(tempfile.gettempdir())
    root_real, canary_real = os.path.realpath(root), os.path.realpath(canary)
    # Fail closed: both fresh directories must sit under the temp location,
    # and neither may contain the other.
    if not (inside(temp_parent, root_real) and inside(temp_parent, canary_real)) \
            or inside(root_real, canary_real) or inside(canary_real, root_real):
        print(f"FAIL: unsafe fixture layout root={root_real} canary={canary_real}")
        return 2

    failures = []
    proc = None
    canary_before = None

    def check(name, condition, detail=""):
        status = "ok" if condition else "FAIL"
        print(f"[{status}] {name}{(' — ' + detail) if detail and not condition else ''}")
        if not condition:
            failures.append(name)

    try:
        a = os.path.join(root, "a")
        b = os.path.join(root, "b")
        home = os.path.join(root, "home")
        tmpdir = os.path.join(root, "tmp")
        for directory in (a, b, home, tmpdir):
            os.makedirs(directory)
        payload = os.urandom(200_000)
        first = os.path.join(a, "blob.bin")
        second = os.path.join(b, "blob.bin")
        with open(first, "wb") as f:
            f.write(payload)
        shutil.copyfile(first, second)
        for path in (first, second):
            os.utime(path, (OLD_TS, OLD_TS))
        before_first = identity(first)
        before_second = identity(second)

        # A byte-identical copy outside ROOT. A scan that reached it would fold it.
        shutil.copyfile(first, os.path.join(canary, "blob.bin"))
        canary_before = tree(canary)

        db_path = os.path.join(root, "mcp-e2e.sqlite")
        history_db_path = os.path.join(root, "nonexistent-history.sqlite")
        env = {
            "PATH": os.environ.get("PATH", ""),
            "LANG": os.environ.get("LANG", "en_US.UTF-8"),
            "HOME": home,
            "TMPDIR": tmpdir,
            "TIDYBYTE_DB": db_path,
            "TIDYBYTE_HISTORY_DB": history_db_path,
        }
        proc = subprocess.Popen(
            [BINARY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, bufsize=1, env=env, cwd=root,
        )
        client = MCPClient(proc)
        scan_paths = [a, b]
        assert all(inside(root, p) for p in scan_paths), "scan paths must stay inside the fixture"

        init = client.request("initialize", {"protocolVersion": "2024-11-05"})
        check("initialize echoes protocol", init["result"]["protocolVersion"] == "2024-11-05")

        tools = client.request("tools/list")["result"]["tools"]
        names = [t["name"] for t in tools]
        expected_tools = [
            "scan", "list_findings", "show_plan", "check_finding", "execute", "history", "undo",
            "monitor_status", "monitor_top", "monitor_ports", "monitor_agents", "monitor_limits",
            "monitor_history", "monitor_inspect", "monitor_hardware",
        ]
        check("tools/list has the full 15-tool surface", names == expected_tools, str(names))
        check(
            "every tool declares readOnlyHint and destructiveHint annotations",
            all(
                isinstance(t.get("annotations"), dict)
                and isinstance(t["annotations"].get("readOnlyHint"), bool)
                and isinstance(t["annotations"].get("destructiveHint"), bool)
                for t in tools
            ),
            str(tools),
        )

        resources = client.request("resources/list")["result"]["resources"]
        resource_uris = [r["uri"] for r in resources]
        check(
            "resources/list exposes scan summary and live monitor",
            "tidybyte://scan/summary" in resource_uris and "tidybyte://monitor/live" in resource_uris,
            str(resource_uris),
        )
        before_summary_text = client.request(
            "resources/read", {"uri": "tidybyte://scan/summary"}
        )["result"]["contents"][0]["text"]
        check("scan summary before scan reports no_scan", json.loads(before_summary_text).get("status") == "no_scan")

        prompts = client.request("prompts/list")["result"]["prompts"]
        prompt_names = [p["name"] for p in prompts]
        check(
            "prompts/list exposes diagnostic and cleanup prompts",
            prompt_names == ["diagnose-slowdown", "review-safe-duplicates", "reclaim-dev-bloat"],
            str(prompt_names),
        )
        prompt_get = client.request(
            "prompts/get", {"name": "review-safe-duplicates", "arguments": {"path": a}}
        )["result"]
        prompt_text = prompt_get["messages"][0]["content"]["text"]
        check("prompts/get renders prompt template with path", a in prompt_text and "check_finding" in prompt_text)

        is_error, status_text = client.call("monitor_status")
        status_json = json.loads(status_text) if not is_error else {}
        check(
            "monitor_status returns CPU and memory telemetry",
            not is_error and "cpu_percent" in status_json and "memory_total_bytes" in status_json,
            status_text,
        )

        is_error, hw_text = client.call("monitor_hardware")
        hw_json = json.loads(hw_text) if not is_error else {}
        check(
            "monitor_hardware returns hardware telemetry",
            not is_error and "cpu" in hw_json and "memory" in hw_json and "power" in hw_json,
            hw_text,
        )

        is_error, hist_text = client.call("monitor_history", {"metric": "cpu", "range": "24h"})
        hist_json = json.loads(hist_text) if not is_error else {}
        check(
            "monitor_history returns structured series JSON",
            not is_error and hist_json.get("metric") == "cpu" and isinstance(hist_json.get("points"), list),
            hist_text,
        )

        is_error, inspect_text = client.call("monitor_inspect", {"pid": proc.pid})
        inspect_json = json.loads(inspect_text) if not is_error else {}
        check(
            "monitor_inspect inspects running MCP server process",
            not is_error and inspect_json.get("pid") == proc.pid,
            inspect_text,
        )

        is_error, text = client.call("scan", {"paths": scan_paths})
        check("scan succeeds", not is_error, text)

        after_summary_text = client.request(
            "resources/read", {"uri": "tidybyte://scan/summary"}
        )["result"]["contents"][0]["text"]
        after_summary = json.loads(after_summary_text)
        check(
            "scan summary after scan reports ready and findings",
            after_summary.get("status") == "ready" and after_summary.get("files_count") == 2,
            after_summary_text,
        )

        is_error, text = client.call("list_findings", {"query": "duplicate"})
        check("list_findings shows a duplicate group", not is_error and "duplicate" in text.lower(), text)
        finding_match = re.search(r"- \[([0-9a-fA-F-]{8,})\]", text)
        check("list_findings exposes a finding id", finding_match is not None, text)

        plan_args = {"finding_id": finding_match.group(1)} if finding_match else {}
        is_error, plan_text = client.call("show_plan", plan_args)
        check(
            "show_plan returns proposed actions with target paths",
            not is_error and "proposed actions" in plan_text and "targets:" in plan_text,
            plan_text,
        )

        if finding_match:
            is_error, check_text = client.call("check_finding", {"finding_id": finding_match.group(1)})
            check(
                "check_finding verifies duplicate bytes on disk",
                not is_error and "byte-identical to the scan" in check_text and "safe to execute" in check_text,
                check_text,
            )

        is_error, text = client.call("execute")
        check("execute without confirm is a dry run",
              not is_error and "Dry run" in text and "confirm: true" in text, text)

        is_error, text = client.call("execute", {"confirm": True})
        check("confirmed execute succeeds", not is_error, text)

        after_first = identity(first)
        after_second = identity(second)
        # Among byte-identical twins the keeper choice is an implementation
        # detail (either file may win the tie-break); what the contract
        # guarantees is: one file keeps its inode, the other is replaced, and
        # the replaced one is the operation's undo target.
        if after_first == before_first:
            keeper, duplicate = first, second
        else:
            keeper, duplicate = second, first
        check("fold keeps the keeper inode", identity(keeper) == (before_first if keeper is first else before_second))
        check("fold replaces the duplicate inode", identity(duplicate) != (before_second if duplicate is second else before_first))
        with open(duplicate, "rb") as f:
            check("folded file keeps its contents", f.read() == payload)

        is_error, text = client.call("history")
        check("history lists the operation", not is_error and "clone" in text.lower(), text)

        # Match the operation that touched THIS run's fixture. Earlier runs may
        # have left records whose paths no longer exist.
        match = re.search(rf"op \[([0-9a-fA-F-]+)\] unfoldClone {re.escape(duplicate)} ", text)
        check("history exposes an operation id", match is not None, text)
        if match:
            op_id = match.group(1)
            is_error, text = client.call("undo", {"operation_log_id": op_id})
            check("undo without confirm is a dry run",
                  not is_error and "Dry run" in text and "confirm: true" in text, text)
            is_error, text = client.call("undo", {"operation_log_id": op_id, "confirm": True})
            check("confirmed undo succeeds", not is_error, text)

            undone_duplicate = identity(duplicate)
            after_duplicate = after_second if duplicate is second else after_first
            check("undo gives the file a fresh private inode", undone_duplicate != after_duplicate)
            with open(duplicate, "rb") as f:
                check("unfolded file keeps its contents", f.read() == payload)
    finally:
        if proc is not None:
            try:
                proc.kill()
                proc.wait(timeout=10)
            except Exception:
                pass

        # Containment checks. The canary must be untouched, and ROOT must hold
        # only what the test made: the two fixture files, the database with its
        # journal files, and the empty HOME and TMPDIR.
        # Each check runs unconditionally. A deleted canary or root is a failure,
        # not a skipped check: tree() of a missing directory is {}, which differs
        # from the recorded state.
        check("canary outside the fixture is unchanged",
              canary_before is not None and os.path.isdir(canary) and tree(canary) == canary_before)
        if os.path.isdir(root):
            allowed = {"a/blob.bin", "b/blob.bin", "a", "b", "home", "tmp"}
            stray = [rel for rel in tree(root)
                     if rel not in allowed and rel not in DATABASE_FILES]
            check("nothing outside the fixture layout was written", not stray, ", ".join(sorted(stray)))
        else:
            check("the fixture root survived the run", False, root)
        shutil.rmtree(root, ignore_errors=True)
        shutil.rmtree(canary, ignore_errors=True)

    if failures:
        print(f"\nmcp-e2e: {len(failures)} check(s) failed: {failures}")
        return 1
    print("\nmcp-e2e: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

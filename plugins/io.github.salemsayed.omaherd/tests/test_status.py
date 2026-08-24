#!/usr/bin/env python3

import os
import stat
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("omaherd_status", ROOT / "omaherd-status.py")
STATUS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(STATUS)


SNAPSHOT = {
    "workspaces": [
        {"workspace_id": "w1", "number": 1, "label": "omarchy"},
        {"workspace_id": "w2", "number": 2, "label": "api"},
    ],
    "tabs": [
        {"tab_id": "t1", "workspace_id": "w1", "number": 1, "label": "shell"},
        {"tab_id": "t2", "workspace_id": "w2", "number": 1, "label": "tests"},
    ],
    "agents": [
        {
            "pane_id": "w1:p1",
            "terminal_id": "term_1",
            "workspace_id": "w1",
            "tab_id": "t1",
            "agent": "codex",
            "display_agent": "Codex",
            "agent_status": "working",
            "foreground_cwd": "/home/salem/Work/omarchy",
            "focused": False,
            "state_change_seq": 8,
        },
        {
            "pane_id": "w2:p1",
            "terminal_id": "term_2",
            "workspace_id": "w2",
            "tab_id": "t2",
            "agent": "claude",
            "display_agent": "Claude",
            "name": "reviewer",
            "agent_status": "blocked",
            "cwd": "/srv/api",
            "focused": False,
            "state_change_seq": 12,
        },
    ],
}


class StatusTests(unittest.TestCase):
    def test_discovers_concrete_ssh_aliases_and_includes(self):
        with tempfile.TemporaryDirectory() as directory:
            ssh_dir = Path(directory)
            included_dir = ssh_dir / "conf.d"
            included_dir.mkdir()
            (included_dir / "servers.conf").write_text(
                "Host buildbox gpu-* !gpu-old\n  User salem\nHost second\n",
                encoding="utf-8",
            )
            config = ssh_dir / "config"
            config.write_text(
                "Include conf.d/*.conf\nHost workbox\n  HostName 10.0.0.2\n"
                "Host git.example\n  User git\nHost *\n",
                encoding="utf-8",
            )

            hosts = STATUS.discover_ssh_hosts(config)

        self.assertEqual(
            [item["host"] for item in hosts],
            ["buildbox", "second", "workbox"],
        )
        self.assertTrue(all(item["source"] == "SSH config" for item in hosts))

    def test_ssh_discovery_stops_at_its_documented_cap(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config"
            config.write_text("\n".join(f"Host box-{index}" for index in range(80)), encoding="utf-8")
            hosts = STATUS.discover_ssh_hosts(config)
        self.assertEqual(len(hosts), 50)
        self.assertEqual(hosts[-1]["host"], "box-49")

    def test_discovers_only_online_tailscale_computers(self):
        payload = {
            "Peer": {
                "linux": {
                    "Online": True,
                    "OS": "linux",
                    "DNSName": "build.tailnet.ts.net.",
                    "HostName": "build",
                },
                "phone": {
                    "Online": True,
                    "OS": "iOS",
                    "DNSName": "phone.tailnet.ts.net.",
                    "HostName": "phone",
                },
                "offline": {
                    "Online": False,
                    "OS": "linux",
                    "DNSName": "old.tailnet.ts.net.",
                    "HostName": "old",
                },
            }
        }
        hosts = STATUS.discover_tailscale_hosts(
            lambda command, timeout: (0, json.dumps(payload), ""),
            available=True,
        )
        self.assertEqual(hosts, [{
            "host": "build.tailnet.ts.net",
            "source": "Tailscale",
            "detail": "build",
        }])
        self.assertEqual(STATUS.discover_tailscale_hosts(
            lambda *_: (_ for _ in ()).throw(RuntimeError("tailscale disappeared")),
            available=True,
        ), [])

    def test_remote_target_validation_supports_ssh_uris(self):
        self.assertTrue(STATUS.valid_remote_target("workbox"))
        self.assertTrue(STATUS.valid_remote_target("salem@workbox"))
        self.assertTrue(STATUS.valid_remote_target("ssh://salem@workbox:2222"))
        self.assertTrue(STATUS.valid_remote_target("ssh://build_box:2222"))
        self.assertTrue(STATUS.valid_remote_target("ssh://deploy@[2001:db8::1]:2222"))
        self.assertFalse(STATUS.valid_remote_target("ssh://workbox:70000"))
        self.assertFalse(STATUS.valid_remote_target("ssh://salem:secret@workbox"))
        self.assertFalse(STATUS.valid_remote_target("workbox;reboot"))
        for unusable in ("@", "-", ".", "..", "a@", "@b", "a@@b", "ssh://-host", "ssh://."):
            with self.subTest(unusable=unusable):
                self.assertFalse(STATUS.valid_remote_target(unusable))

    def test_normalize_snapshot_enriches_and_prioritizes_agents(self):
        agents = STATUS.normalize_snapshot("workbox", "agents", SNAPSHOT)
        self.assertEqual([agent["status"] for agent in agents], ["blocked", "working"])
        self.assertEqual(agents[0]["name"], "reviewer")
        self.assertEqual(agents[0]["workspaceLabel"], "api")
        self.assertEqual(agents[0]["tabLabel"], "tests")
        self.assertEqual(agents[0]["cwdLabel"], "api")
        self.assertEqual(agents[0]["key"], "workbox|agents|w2:p1")

    def test_malformed_snapshot_fields_degrade_without_crashing_the_poll(self):
        agents = STATUS.normalize_snapshot("local", "default", {
            "workspaces": None,
            "tabs": "not a list",
            "agents": [None, {
                "pane_id": "w1:p1",
                "workspace_id": ["not hashable"],
                "tab_id": {"not": "hashable"},
                "state_change_seq": {"not": "a number"},
                "agent_status": None,
            }],
        })
        self.assertEqual(len(agents), 1)
        self.assertEqual(agents[0]["workspaceNumber"], 0)
        self.assertEqual(agents[0]["stateChangeSeq"], 0)
        self.assertEqual(agents[0]["status"], "unknown")

    def test_collect_target_uses_session_snapshot(self):
        calls = []

        def runner(command, timeout):
            calls.append(command)
            if command[-3:] == ["session", "list", "--json"] or (
                command[0] == "ssh" and "session list --json" in command[-1]
            ):
                return 0, json.dumps({
                    "sessions": [
                        {"name": "default", "default": True, "running": True},
                        {"name": "sleeping", "default": False, "running": False},
                    ]
                }), ""
            return 0, json.dumps({
                "id": "cli:api:snapshot",
                "result": {"type": "session_snapshot", "snapshot": SNAPSHOT},
            }), ""

        target = STATUS.collect_target("local", False, 3, runner)
        self.assertTrue(target["running"])
        self.assertEqual(len(target["agents"]), 2)
        self.assertEqual(target["sessions"][0]["agentCount"], 2)
        self.assertEqual(target["sessions"][1]["agentCount"], 0)
        self.assertIn(["herdr", "--session", "default", "api", "snapshot"], calls)

    def test_aggregate_counts_attention_across_hosts(self):
        local_agents = STATUS.normalize_snapshot("local", "default", SNAPSHOT)
        remote_snapshot = dict(SNAPSHOT)
        remote_snapshot["agents"] = [dict(SNAPSHOT["agents"][0], agent_status="done")]
        remote_agents = STATUS.normalize_snapshot("workbox", "default", remote_snapshot)
        result = STATUS.aggregate([
            {"host": "local", "local": True, "installed": True, "running": True,
             "sessions": [], "agents": local_agents, "error": ""},
            {"host": "workbox", "local": False, "installed": True, "running": True,
             "sessions": [], "agents": remote_agents, "error": ""},
        ])
        self.assertEqual(result["counts"]["total"], 3)
        self.assertEqual(result["counts"]["blocked"], 1)
        self.assertEqual(result["counts"]["done"], 1)
        self.assertEqual(result["counts"]["attention"], 2)
        self.assertEqual(result["statusText"], "2 need attention")

    def test_invalid_remote_alias_is_rejected_before_ssh(self):
        target = STATUS.collect_target("bad host;touch nope", True, 3, lambda *_: self.fail())
        self.assertFalse(target["reachable"])
        self.assertEqual(target["error"], "Invalid SSH target")

    def test_remote_collection_uses_batch_ssh_and_normalizes_host(self):
        calls = []

        def runner(command, timeout):
            calls.append(command)
            if command[-3:] == ["session", "list", "--json"] or (
                command[0] == "ssh" and "session list --json" in command[-1]
            ):
                return 0, json.dumps({
                    "sessions": [{"name": "default", "default": True, "running": True}]
                }), ""
            return 0, json.dumps({
                "result": {"type": "session_snapshot", "snapshot": SNAPSHOT}
            }), ""

        with tempfile.TemporaryDirectory() as tmp:
            old_runtime = os.environ.get("XDG_RUNTIME_DIR")
            os.environ["XDG_RUNTIME_DIR"] = tmp
            try:
                target = STATUS.collect_target("workbox", True, 4, runner)
            finally:
                if old_runtime is None:
                    del os.environ["XDG_RUNTIME_DIR"]
                else:
                    os.environ["XDG_RUNTIME_DIR"] = old_runtime
        self.assertTrue(target["reachable"])
        self.assertEqual(len(target["agents"]), 2)
        self.assertTrue(all(agent["host"] == "workbox" for agent in target["agents"]))
        self.assertEqual(calls[0][:5], ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4"])
        self.assertIn("ControlMaster=auto", calls[0])
        self.assertIn("ControlPersist=60", calls[0])
        control = [part for part in calls[0] if part.startswith("ControlPath=")]
        self.assertEqual(len(control), 1)
        self.assertTrue(control[0].endswith("/omaherd/ssh-%C"))
        separator = calls[0].index("--")
        self.assertEqual(calls[0][separator + 1], "workbox")
        tail = calls[0][separator + 2]
        self.assertIn("$HOME/.local/bin", tail)
        self.assertTrue(tail.startswith("exec /bin/sh -lc "))
        self.assertIn("herdr session list --json; printf", tail)
        self.assertIn(STATUS.HOSTNAME_MARKER, tail)
        # The snapshot call is still a plain exec with no trailer.
        self.assertIn("exec herdr --session default api snapshot", calls[1][calls[1].index("--") + 2])

    def test_ssh_options_fall_back_without_a_control_dir(self):
        options = STATUS.ssh_options(3, Path("/proc/omaherd-cannot-create"))
        self.assertEqual(options, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3"])
        with tempfile.TemporaryDirectory() as tmp:
            control = Path(tmp) / "control"
            STATUS.ssh_options(3, control)
            self.assertEqual(stat.S_IMODE(control.stat().st_mode), 0o700)

    def test_ssh_uri_targets_pass_straight_to_ssh(self):
        calls = []

        def runner(command, timeout):
            calls.append(command)
            return 255, "", "ssh: connect to host example.com port 2222: Connection refused"

        target = STATUS.collect_target("ssh://deploy@example.com:2222", True, 3, runner)
        self.assertEqual(calls[0][calls[0].index("--") + 1], "ssh://deploy@example.com:2222")
        self.assertFalse(target["reachable"])
        self.assertIn("Connection refused", target["error"])

    def test_offline_remote_host_is_reported_not_raised(self):
        target = STATUS.collect_target("workbox", True, 3, lambda *_: (124, "", "Command timed out"))
        self.assertFalse(target["reachable"])
        self.assertTrue(target["installed"])
        self.assertEqual(target["error"], "Command timed out")
        result = STATUS.aggregate([
            {"host": "local", "local": True, "installed": True, "running": True,
             "sessions": [], "agents": [], "error": ""},
            target,
        ])
        self.assertTrue(result["hasErrors"])
        self.assertEqual(result["lastError"], "workbox: Command timed out")
        self.assertEqual(result["statusText"], "No active agents")

    def test_remote_without_herdr_is_marked_not_installed(self):
        target = STATUS.collect_target("workbox", True, 3, lambda *_: (127, "", "herdr: not found"))
        self.assertFalse(target["reachable"])
        self.assertFalse(target["installed"])

    def test_stopped_server_reads_as_stopped(self):
        def runner(command, timeout):
            if command[-3:] == ["session", "list", "--json"]:
                return 0, json.dumps({"sessions": [{"name": "default", "default": True, "running": False}]}), ""
            self.fail("a stopped session must not be snapshotted")

        target = STATUS.collect_target("local", False, 3, runner)
        self.assertFalse(target["running"])
        self.assertEqual(target["agents"], [])
        result = STATUS.aggregate([target])
        self.assertEqual(result["statusText"], "HerdR is stopped")
        self.assertEqual(result["counts"]["total"], 0)

    def test_snapshot_failure_for_one_session_keeps_the_others(self):
        def runner(command, timeout):
            if command[-3:] == ["session", "list", "--json"]:
                return 0, json.dumps({"sessions": [
                    {"name": "default", "default": True, "running": True},
                    {"name": "broken", "default": False, "running": True},
                ]}), ""
            if "broken" in command:
                return 1, "", "socket closed"
            return 0, json.dumps({"result": {"snapshot": SNAPSHOT}}), ""

        target = STATUS.collect_target("local", False, 3, runner)
        self.assertEqual(len(target["agents"]), 2)
        self.assertEqual(target["sessions"][1]["error"], "socket closed")
        self.assertTrue(STATUS.aggregate([target])["hasErrors"])

    def test_one_host_shares_a_deadline_across_all_running_sessions(self):
        clock = [100.0]
        original_monotonic = STATUS.time.monotonic

        def runner(command, timeout):
            clock[0] += 0.06
            if command[-3:] == ["session", "list", "--json"]:
                return 0, json.dumps({"sessions": [
                    {"name": f"s{index}", "running": True} for index in range(5)
                ]}), ""
            return 0, json.dumps({"result": {"snapshot": SNAPSHOT}}), ""

        STATUS.time.monotonic = lambda: clock[0]
        try:
            target = STATUS.collect_target("local", False, 3, runner, budget=0.12)
        finally:
            STATUS.time.monotonic = original_monotonic

        self.assertEqual(len(target["agents"]), 2)
        self.assertTrue(any(session["error"] == "Collection deadline exceeded"
                            for session in target["sessions"]))

    def test_runner_exceptions_become_target_errors(self):
        target = STATUS.collect_target(
            "workbox", True, 3,
            lambda *_: (_ for _ in ()).throw(RuntimeError("runner exploded")),
        )
        self.assertFalse(target["reachable"])
        self.assertEqual(target["error"], "runner exploded")

    def test_background_refresh_skips_host_discovery_work(self):
        calls = []

        def runner(command, timeout):
            calls.append(command)
            return 0, json.dumps({"sessions": [
                {"name": "default", "default": True, "running": False}
            ]}), ""

        original_which = STATUS.shutil.which
        STATUS.shutil.which = lambda command: f"/x/{command}"
        try:
            result = STATUS.collect([], 3, runner, include_discovery=False)
        finally:
            STATUS.shutil.which = original_which
        self.assertEqual(result["discoveredHosts"], [])
        self.assertTrue(any(command[0] == "herdr" for command in calls))
        self.assertFalse(any(command[0] == "tailscale" for command in calls))

    def test_fixture_drop_in_replaces_live_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fixture.json"
            path.write_text(json.dumps({"statusText": "fixture", "agents": [], "counts": {"total": 0}}))
            fixture = STATUS.load_fixture(path)
            self.assertEqual(fixture["statusText"], "fixture")
            self.assertTrue(fixture["ok"])
            self.assertGreater(fixture["generatedAt"], 0)
            (Path(tmp) / "bad.json").write_text("{not json")
            self.assertIsNone(STATUS.load_fixture(Path(tmp) / "bad.json"))
            old = os.environ.get("OMAHERD_FIXTURE")
            os.environ["OMAHERD_FIXTURE"] = str(path)
            try:
                self.assertEqual(STATUS.fixture_path(), path)
            finally:
                if old is None:
                    del os.environ["OMAHERD_FIXTURE"]
                else:
                    os.environ["OMAHERD_FIXTURE"] = old

    def test_explicit_bad_fixture_returns_json_and_a_clear_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "missing.json"
            environment = dict(os.environ, OMAHERD_FIXTURE=str(missing))
            result = subprocess.run(
                [sys.executable, str(ROOT / "omaherd-status.py")],
                capture_output=True, text=True, env=environment, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["ok"])
        self.assertIn("Could not load Omaherd fixture", payload["lastError"])
        self.assertIn("Could not load Omaherd fixture", result.stderr)


class SocketAndHostnameTests(unittest.TestCase):
    def test_hostname_trailer_is_split_off_and_validated(self):
        text, hostname = STATUS.split_hostname_trailer('{"sessions": []}\n__omaherd_hostname__ ubuntu-8gb\n')
        self.assertEqual(json.loads(text), {"sessions": []})
        self.assertEqual(hostname, "ubuntu-8gb")
        self.assertEqual(STATUS.split_hostname_trailer('{"a":1}'), ('{"a":1}', ""))
        self.assertEqual(STATUS.split_hostname_trailer('{}\n__omaherd_hostname__ bad host;x\n')[1], "")

    def test_remote_listing_stamps_the_hostname_onto_every_agent(self):
        def runner(command, timeout):
            if "session list --json" in command[-1]:
                return 0, json.dumps({"sessions": [{"name": "default", "default": True, "running": True}]}) \
                    + "\n__omaherd_hostname__ ubuntu-8gb\n", ""
            return 0, json.dumps({"result": {"snapshot": SNAPSHOT}}), ""

        target = STATUS.collect_target("workbox", True, 3, runner)
        self.assertEqual(target["hostname"], "ubuntu-8gb")
        result = STATUS.aggregate([target])
        self.assertTrue(all(agent["hostname"] == "ubuntu-8gb" for agent in result["agents"]))

    def test_local_snapshot_prefers_the_session_socket_and_falls_back_to_the_cli(self):
        calls = []

        def runner(command, timeout):
            calls.append(command)
            if command[-3:] == ["session", "list", "--json"]:
                return 0, json.dumps({"sessions": [
                    {"name": "default", "default": True, "running": True, "socket_path": "/run/x/herdr.sock"},
                    {"name": "review", "default": False, "running": True, "socket_path": "/run/x/review.sock"},
                ]}), ""
            return 0, json.dumps({"result": {"snapshot": SNAPSHOT}}), ""

        def reader(path, timeout):
            return SNAPSHOT if path.endswith("herdr.sock") else None

        target = STATUS.collect_target("local", False, 3, runner, snapshot_reader=reader)
        self.assertEqual([s["transport"] for s in target["sessions"]], ["socket", "cli"])
        self.assertEqual(len(target["agents"]), 4)
        self.assertEqual(sum(1 for c in calls if "snapshot" in c), 1)
        self.assertTrue(target["hostname"])

    def test_socket_snapshot_speaks_newline_json_and_fails_soft(self):
        import socket as socket_module
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "herdr.sock")
            server = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            seen = {}

            def serve():
                conn, _ = server.accept()
                with conn:
                    seen["request"] = json.loads(conn.recv(4096).decode().split("\n")[0])
                    conn.sendall((json.dumps({"id": "omaherd", "result": {"type": "session_snapshot", "snapshot": SNAPSHOT}}) + "\n").encode())

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            snapshot = STATUS.socket_snapshot(path, 2.0)
            thread.join(2)
            server.close()
            self.assertEqual(seen["request"]["method"], "session.snapshot")
            self.assertEqual(snapshot["agents"], SNAPSHOT["agents"])
            self.assertIsNone(STATUS.socket_snapshot(str(Path(tmp) / "missing.sock"), 0.2))

    def test_socket_snapshot_rejects_a_frame_above_the_byte_ceiling(self):
        import socket as socket_module
        import threading
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "oversized.sock")
            server = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
            server.bind(path)
            server.listen(1)

            def serve():
                connection, _ = server.accept()
                with connection:
                    connection.recv(4096)
                    try:
                        connection.sendall(b"x" * (STATUS.MAX_SOCKET_BYTES + 1))
                    except BrokenPipeError:
                        pass

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            self.assertIsNone(STATUS.socket_snapshot(path, 2.0))
            thread.join(2)
            server.close()

    def test_serialized_status_and_model_cardinality_are_hard_capped(self):
        agents = [
            {
                "key": f"local|default|p{index}", "host": "local", "session": "default",
                "paneId": f"p{index}", "status": "working", "title": "x" * 4000,
            }
            for index in range(STATUS.MAX_AGENTS * 3)
        ]
        result = STATUS.aggregate([{
            "host": "local", "hostname": "desktop", "local": True,
            "installed": True, "running": True, "sessions": [], "agents": agents,
            "error": "",
        }])
        output = STATUS.serialize_status(result)
        parsed = json.loads(output)
        self.assertLessEqual(len(output.encode("utf-8")), STATUS.MAX_STATUS_BYTES)
        self.assertLessEqual(len(parsed["agents"]), STATUS.MAX_AGENTS)
        self.assertTrue(parsed["hasErrors"])
        self.assertIn("limit", parsed["lastError"])
        self.assertNotIn("agents", parsed["targets"][0])


if __name__ == "__main__":
    unittest.main()

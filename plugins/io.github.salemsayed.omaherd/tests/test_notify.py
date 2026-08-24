#!/usr/bin/env python3

import runpy
import contextlib
import io
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
NOTIFY = runpy.run_path(str(ROOT / "omaherd-notify"), run_name="omaherd_notify_test")


class NotifyTests(unittest.TestCase):
    def test_needs_input_toast_is_urgent_sticky_and_clickable(self):
        command = NOTIFY["build_command"](
            "blocked", "omarchy · claude needs input", "Fix the bar",
            exec_command="/x/omaherd-attach --focus", use_omarchy=True,
        )
        self.assertEqual(command[0], "omarchy-notification-send")
        self.assertIn("--app-name", command)
        self.assertEqual(command[command.index("-u") + 1], "critical")
        self.assertEqual(command[command.index("--exec") + 1], "/x/omaherd-attach --focus")
        self.assertEqual(command[command.index("-t") + 1], "0")
        self.assertIn("-p", command)
        self.assertNotIn("-r", command)

    def test_done_toast_replaces_the_agents_earlier_toast(self):
        command = NOTIFY["build_command"]("done", "claude finished", "", replace_id=42, use_omarchy=True)
        self.assertEqual(command[command.index("-u") + 1], "normal")
        self.assertEqual(command[command.index("-r") + 1], "42")
        self.assertEqual(command[command.index("-t") + 1], "12000")

    def test_falls_back_to_plain_notify_send(self):
        command = NOTIFY["build_command"]("blocked", "s", "b", exec_command="ignored", use_omarchy=False)
        self.assertEqual(command[0], "notify-send")
        self.assertNotIn("--exec", command)
        self.assertEqual(command[-2:], ["s", "b"])

    def test_withdrawing_asks_the_shell_by_summary_and_the_daemon_by_id(self):
        commands = NOTIFY["close_commands"](7, "omarchy · claude needs input", use_omarchy=True)
        self.assertEqual(commands[0], ["omarchy-shell", "notifications", "dismiss", "omarchy · claude needs input"])
        self.assertEqual(commands[1][-1], "7")
        self.assertIn("CloseNotification", " ".join(commands[1]))
        self.assertEqual(len(NOTIFY["close_commands"](7, "x", use_omarchy=False)), 1)
        self.assertEqual(NOTIFY["close_commands"](0, "", use_omarchy=True), [])
        self.assertEqual(NOTIFY["parse_id"]("\n 17\n"), 17)
        self.assertEqual(NOTIFY["parse_id"]("helper 1\n12\nnoise\n 17\n"), 17)
        self.assertEqual(NOTIFY["parse_id"]("error"), 0)

    def test_id_store_round_trips_and_reads_the_older_shape(self):
        path = Path(tempfile.mkdtemp()) / "n" / "ids.json"
        NOTIFY["save_ids"](path, {"k": {"id": 3, "summary": "s", "at": 100.0, "closing": False}})
        self.assertEqual(NOTIFY["load_ids"](path), {"k": {
            "id": 3, "summary": "s", "at": 100.0, "closing": False,
            "revision": 0, "closed": False,
        }})
        path.write_text('{"old": 9}')
        self.assertEqual(NOTIFY["load_ids"](path), {"old": {
            "id": 9, "summary": "", "at": 0.0, "closing": False,
            "revision": 0, "closed": False,
        }})
        self.assertEqual(NOTIFY["load_ids"](path.parent / "missing.json"), {})
        self.assertEqual(list(path.parent.glob("*.tmp")), [])
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)

    def test_stale_entries_are_swept_after_a_day(self):
        now = 1_000_000.0
        ids = {
            "fresh": {"id": 1, "summary": "a", "at": now - 60},
            "old": {"id": 2, "summary": "b", "at": now - 2 * 86400},
            "unstamped": {"id": 3, "summary": "c", "at": 0.0},
        }
        kept = NOTIFY["prune"](ids, now)
        self.assertEqual(sorted(kept), ["fresh", "unstamped"])
        pending = {"pending": {"id": 4, "summary": "s", "at": now - 2 * 86400,
                               "closing": True}}
        self.assertEqual(list(NOTIFY["prune"](pending, now)), ["pending"])
        self.assertEqual(NOTIFY["prune"]({}, now), {})

    def test_click_command_is_shell_safe(self):
        exec_command = NOTIFY["focus_exec"](
            "/p/Plugin Dir/omaherd-attach", "workbox", "default", "wJ:pKX", "Store Front", "build box",
        )
        self.assertTrue(exec_command.startswith("'/p/Plugin Dir/omaherd-attach'"))
        self.assertIn("--workspace 'Store Front'", exec_command)
        self.assertIn("--hostname 'build box'", exec_command)
        self.assertTrue(exec_command.endswith("--focus"))


    def test_failed_withdrawals_stay_pending_and_are_retried(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            class R:
                returncode = 0
                stdout = "" if command[0] == "omarchy-shell" and fake_run.down else "ok\n"
            return R()
        fake_run.down = True
        globals_ = NOTIFY["withdraw"].__globals__
        original = globals_["run_capped"]
        globals_["run_capped"] = fake_run
        try:
            entry = {"id": 4, "summary": "x needs input", "at": 1.0, "closing": True}
            # Shell mid-restart answers nothing: the entry must survive.
            ids = NOTIFY["settle"]({"k": dict(entry)}, use_omarchy=True)
            self.assertIn("k", ids)
            fake_run.down = False
            ids = NOTIFY["settle"](ids, use_omarchy=True)
            self.assertEqual(ids, {})
            # An entry not marked closing is left alone by settle.
            self.assertEqual(list(NOTIFY["settle"]({"j": dict(entry, closing=False)}, True)), ["j"])
            # Without the Omarchy shell only the D-Bus close is attempted.
            calls.clear()
            self.assertTrue(NOTIFY["withdraw"](entry, use_omarchy=False))
            self.assertEqual([c[0] for c in calls], ["gdbus"])
        finally:
            globals_["run_capped"] = original

    def test_nonzero_dbus_close_stays_pending(self):
        globals_ = NOTIFY["withdraw"].__globals__
        original = globals_["run_capped"]

        class R:
            returncode = 1
            stdout = ""

        globals_["run_capped"] = lambda *args, **kwargs: R()
        try:
            self.assertFalse(NOTIFY["withdraw"]({"id": 7, "summary": ""}, use_omarchy=False))
        finally:
            globals_["run_capped"] = original

    def test_reconcile_invalidates_stale_ids_and_revisions_drop_late_events(self):
        path = Path(tempfile.mkdtemp()) / "notifications.json"
        NOTIFY["save_ids"](path, {
            "k": {"id": 42, "summary": "agent needs input", "at": NOTIFY["time"].time(),
                  "closing": True, "revision": 10, "closed": False}
        })
        globals_ = NOTIFY["run"].__globals__
        original_run = globals_["run_capped"]
        original_which = NOTIFY["shutil"].which
        calls = []

        class R:
            def __init__(self, stdout="ok\n", returncode=0):
                self.stdout = stdout
                self.stderr = ""
                self.returncode = returncode

        def fake_run(command, **kwargs):
            calls.append(command)
            if command[0] in ("omarchy-notification-send", "notify-send"):
                return R("wrapper note\n77\n")
            return R()

        globals_["run_capped"] = fake_run
        NOTIFY["shutil"].which = lambda command: f"/usr/bin/{command}"
        try:
            reconcile = SimpleNamespace(kind="reconcile", keep=["k"], key="", revision=100)
            self.assertEqual(NOTIFY["run"](reconcile, path), 0)
            kept = NOTIFY["load_ids"](path)["k"]
            self.assertEqual(kept["id"], 0)
            self.assertFalse(kept["closing"])

            event = SimpleNamespace(
                kind="done", keep=[], key="k", revision=200,
                summary="agent finished", body="done", host="local", session="default",
                target="w1:p1", workspace="work", hostname="build-box",
            )
            self.assertEqual(NOTIFY["run"](event, path), 0)
            notify_command = next(command for command in calls
                                  if command[0] == "omarchy-notification-send")
            self.assertNotIn("-r", notify_command)
            self.assertIn("--hostname build-box", notify_command[notify_command.index("--exec") + 1])
            self.assertEqual(NOTIFY["load_ids"](path)["k"]["id"], 77)

            calls.clear()
            late = SimpleNamespace(**{**event.__dict__, "kind": "blocked", "revision": 150})
            self.assertEqual(NOTIFY["run"](late, path), 0)
            self.assertEqual(calls, [])
        finally:
            globals_["run_capped"] = original_run
            NOTIFY["shutil"].which = original_which

    def test_close_does_not_wait_for_an_absent_omarchy_shell(self):
        path = Path(tempfile.mkdtemp()) / "notifications.json"
        NOTIFY["save_ids"](path, {"k": {
            "id": 7, "summary": "s", "at": NOTIFY["time"].time()
        }})
        globals_ = NOTIFY["run"].__globals__
        original_run = globals_["run_capped"]
        original_which = NOTIFY["shutil"].which
        calls = []

        class R:
            returncode = 0
            stdout = "ok\n"
            stderr = ""

        globals_["run_capped"] = lambda command, **kwargs: calls.append(command) or R()
        NOTIFY["shutil"].which = lambda command: None if command == "omarchy-shell" else f"/x/{command}"
        try:
            args = SimpleNamespace(kind="close", keep=[], key="k", revision=50)
            self.assertEqual(NOTIFY["run"](args, path), 0)
        finally:
            globals_["run_capped"] = original_run
            NOTIFY["shutil"].which = original_which
        self.assertEqual([command[0] for command in calls], ["gdbus"])

    def test_failed_raise_preserves_the_last_withdrawable_notification(self):
        path = Path(tempfile.mkdtemp()) / "notifications.json"
        NOTIFY["save_ids"](path, {"k": {
            "id": 7, "summary": "still true", "at": NOTIFY["time"].time(),
            "revision": 10,
        }})
        globals_ = NOTIFY["run"].__globals__
        original_run = globals_["run_capped"]
        original_which = NOTIFY["shutil"].which

        class R:
            returncode = 1
            stdout = ""
            stderr = "notification server unavailable"

        globals_["run_capped"] = lambda *args, **kwargs: R()
        NOTIFY["shutil"].which = lambda command: f"/x/{command}"
        args = SimpleNamespace(
            kind="done", keep=[], key="k", revision=20, summary="now done", body="",
            host="local", session="default", target="w1:p1", workspace="work",
        )
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(NOTIFY["run"](args, path), 1)
        finally:
            globals_["run_capped"] = original_run
            NOTIFY["shutil"].which = original_which
        stored = NOTIFY["load_ids"](path)["k"]
        self.assertEqual(stored["id"], 7)
        self.assertEqual(stored["summary"], "still true")
        self.assertEqual(stored["revision"], 10)


    def test_concurrent_writers_take_turns_on_the_store(self):
        path = Path(tempfile.mkdtemp()) / "notifications.json"
        script = f"""
import runpy, sys, time
N = runpy.run_path({str(ROOT / "omaherd-notify")!r}, run_name="x")
from pathlib import Path
path = Path({str(path)!r})
with N["store_lock"](path):
    ids = N["load_ids"](path)
    time.sleep(0.01)
    ids[sys.argv[1]] = {{"id": int(sys.argv[1]), "summary": "s", "at": 1.0, "closing": False}}
    N["save_ids"](path, ids)
"""
        workers = [subprocess.Popen([sys.executable, "-c", script, str(i)]) for i in range(1, 25)]
        for worker in workers:
            self.assertEqual(worker.wait(timeout=30), 0)
        self.assertEqual(sorted(NOTIFY["load_ids"](path), key=int), [str(i) for i in range(1, 25)])


if __name__ == "__main__":
    unittest.main()

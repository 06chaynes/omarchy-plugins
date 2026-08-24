#!/usr/bin/env python3

import runpy
import contextlib
import io
import stat
import tempfile
from types import SimpleNamespace
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ATTACH = runpy.run_path(str(ROOT / "omaherd-attach"), run_name="omaherd_attach_test")
BUILD = ATTACH["build_command"]
FOCUS = ATTACH["focus_command"]
CLIENT_PIDS = ATTACH["herdr_client_pids"]
WINDOW_FOR = ATTACH["window_for_pids"]
WINDOW_FOR_LOCAL = ATTACH["window_for_local"]
WINDOW_FOR_REMOTE = ATTACH["window_for_remote"]
IS_CLIENT = ATTACH["is_herdr_client"]


def table(processes: dict[int, tuple[list[str], int]]) -> dict[int, tuple[int, list[str]]]:
    return {pid: (ppid, cmdline) for pid, (cmdline, ppid) in processes.items()}


class AttachTests(unittest.TestCase):
    def test_local_session_attach(self):
        self.assertEqual(BUILD("local", "review"), ["herdr", "--session", "review"])
        self.assertEqual(
            BUILD("local", "default", "w1:p1"),
            ["herdr", "--session", "default", "agent", "attach", "w1:p1"],
        )

    def test_remote_attach_uses_an_interactive_ssh_session(self):
        command = BUILD("workbox", "review", "w2:p1")
        self.assertEqual(command[:4], ["ssh", "-t", "--", "workbox"])
        self.assertIn("herdr --session review agent attach w2:p1", command[4])
        self.assertIn("PATH=", command[4])
        with self.assertRaises(SystemExit):
            BUILD("bad host", "default")

    def test_rejects_shell_metacharacters(self):
        with self.assertRaises(SystemExit):
            BUILD("local", "default", "w1:p1;reboot")
        with self.assertRaises(SystemExit):
            FOCUS("local", "default", "w1:p1 && reboot")
        for unusable in ("@", "-", ".", "..", "a@", "@b", "a@@b", "ssh://-host", "ssh://."):
            with self.subTest(unusable=unusable), self.assertRaises(SystemExit):
                BUILD(unusable, "default")

    def test_focus_targets_the_pane_in_its_session(self):
        self.assertEqual(
            FOCUS("local", "review", "w2:p1"),
            ["herdr", "--session", "review", "agent", "focus", "w2:p1"],
        )
        with tempfile.TemporaryDirectory() as tmp:
            old_runtime = ATTACH["os"].environ.get("XDG_RUNTIME_DIR")
            ATTACH["os"].environ["XDG_RUNTIME_DIR"] = tmp
            try:
                remote = FOCUS("workbox", "default", "wJ:pKX", timeout=4)
            finally:
                if old_runtime is None:
                    del ATTACH["os"].environ["XDG_RUNTIME_DIR"]
                else:
                    ATTACH["os"].environ["XDG_RUNTIME_DIR"] = old_runtime
        self.assertEqual(remote[:5], ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4"])
        self.assertIn("ControlMaster=auto", remote)
        separator = remote.index("--")
        self.assertEqual(remote[separator + 1], "workbox")
        self.assertIn("herdr --session default agent focus wJ:pKX", remote[separator + 2])
        uri = FOCUS("ssh://deploy@example.com:2222", "default", "w1:p1")
        self.assertEqual(uri[uri.index("--") + 1], "ssh://deploy@example.com:2222")
        self.assertEqual(BUILD("ssh://deploy@example.com:2222", "default", "w1:p1")[3], "ssh://deploy@example.com:2222")
        ipv6 = FOCUS("ssh://deploy@[2001:db8::1]:2222", "default", "w1:p1")
        self.assertEqual(ipv6[ipv6.index("--") + 1], "ssh://deploy@[2001:db8::1]:2222")
        with self.assertRaises(SystemExit):
            FOCUS("local", "default", "")
        with tempfile.TemporaryDirectory() as tmp:
            control = Path(tmp) / "control"
            ATTACH["ssh_options"](3, control)
            self.assertEqual(stat.S_IMODE(control.stat().st_mode), 0o700)

    def test_finds_the_terminal_window_holding_the_session_client(self):
        procs = table({
            100: (["kitty"], 1),
            101: (["/usr/bin/herdr"], 100),            # default-session client
            200: (["kitty"], 1),
            201: (["herdr", "--session", "review"], 200),
            300: (["/usr/bin/herdr", "server"], 1),    # the server is not a window
            301: (["herdr", "agent", "attach", "w1:p1"], 1),
            400: (["kitty"], 1),
            401: (["herdr", "--remote", "workbox"], 400),
        })
        self.assertEqual(CLIENT_PIDS("default", procs), [101])
        self.assertEqual(CLIENT_PIDS("review", procs), [201])
        self.assertEqual(CLIENT_PIDS("default", procs, "workbox"), [401])
        windows = [{"pid": 100, "address": "0xa"}, {"pid": 200, "address": "0xb"}, {"pid": 400, "address": "0xc"}]
        self.assertEqual(WINDOW_FOR(CLIENT_PIDS("review", procs), windows, procs)["address"], "0xb")
        self.assertIsNone(WINDOW_FOR(CLIENT_PIDS("other", procs), windows, procs))
        self.assertEqual(WINDOW_FOR_REMOTE("workbox", "default", "", windows, procs)["address"], "0xc")
        # A session name that happens to equal a subcommand is still an option
        # value, not evidence that this process is a one-shot command.
        self.assertTrue(IS_CLIENT(["herdr", "--session", "agent"]))
        self.assertFalse(IS_CLIENT(["herdr", "--session", "default", "agent", "attach", "w1:p1"]))
        self.assertFalse(IS_CLIENT(["herdr", "--version"]))

    def test_recognises_a_remote_session_by_its_ssh_or_mosh_window_title(self):
        procs = table({
            500: (["kitty", "--working-directory", "/home/me"], 1),
            501: (["bash"], 500),
            502: (["mosh-client", "-# workbox", "1.2.3.4", "60001"], 501),
            550: (["kitty"], 1),
            551: (["ssh", "workbox"], 550),
            600: (["kitty"], 1),
            601: (["vim", "notes: storefront"], 600),
        })
        windows = [
            {"pid": 500, "address": "0xwrong", "title": "[mosh] otherbox: storefront"},
            {"pid": 550, "address": "0xm", "title": "[ssh] workbox: storefront"},
            {"pid": 600, "address": "0xv", "title": "vim: storefront"},
        ]
        found = WINDOW_FOR_REMOTE("workbox", "default", "storefront", windows, procs)
        self.assertEqual(found["address"], "0xm")
        self.assertIsNone(WINDOW_FOR_REMOTE("workbox", "default", "other", windows, procs))
        self.assertIsNone(WINDOW_FOR_REMOTE("workbox", "default", "", windows, procs))

    def test_multiple_local_clients_are_selected_by_workspace_not_pid(self):
        procs = table({
            100: (["kitty"], 1), 101: (["herdr"], 100),
            200: (["kitty"], 1), 201: (["herdr"], 200),
        })
        windows = [
            {"pid": 100, "address": "0xold", "title": "desktop: other"},
            {"pid": 200, "address": "0xtarget", "title": "desktop: storefront"},
        ]
        self.assertEqual(
            WINDOW_FOR_LOCAL("default", "storefront", "desktop", windows, procs)["address"],
            "0xtarget",
        )
        self.assertIsNone(WINDOW_FOR_LOCAL("default", "missing", "desktop", windows, procs))
        self.assertEqual(
            WINDOW_FOR_LOCAL("default", "missing", "desktop", windows[:1], procs)["address"],
            "0xold",
        )

    def test_a_lone_carrier_window_for_the_workspace_wins_when_no_title_names_the_host(self):
        # The alias resolves to an IP and the remote titles itself by its own
        # hostname, so nothing can match by label — but there is only one
        # ssh/mosh window for this workspace, and it is the right one.
        procs = table({
            500: (["kitty"], 1),
            501: (["bash"], 500),
            502: (["mosh-client", "-# workbox", "46.0.0.1", "60001"], 501),
            600: (["kitty"], 1),
            601: (["vim", "notes: storefront"], 600),
        })
        windows = [
            {"pid": 500, "address": "0xm", "title": "[mosh] ubuntu-8gb: storefront"},
            {"pid": 600, "address": "0xv", "title": "vim: storefront"},
        ]
        found = WINDOW_FOR_REMOTE("workbox", "default", "storefront", windows, procs, {"workbox", "46.0.0.1"})
        self.assertEqual(found["address"], "0xm")
        # Two carrier windows for the same workspace and no host label to
        # tell them apart: refuse, so the caller falls back to a terminal.
        procs[700] = (1, ["kitty"]); procs[701] = (700, ["ssh", "otherbox"])
        windows.append({"pid": 700, "address": "0xo", "title": "[ssh] otherbox-hostname: storefront"})
        self.assertIsNone(WINDOW_FOR_REMOTE("workbox", "default", "storefront", windows, procs, {"workbox"}))

    def test_multiple_managed_remote_clients_are_selected_by_workspace(self):
        procs = table({
            400: (["kitty"], 1), 401: (["herdr", "--remote", "workbox"], 400),
            500: (["kitty"], 1), 501: (["herdr", "--remote", "workbox"], 500),
        })
        windows = [
            {"pid": 400, "address": "0xold", "title": "build-box: other"},
            {"pid": 500, "address": "0xtarget", "title": "build-box: storefront"},
        ]
        self.assertEqual(
            WINDOW_FOR_REMOTE(
                "workbox", "default", "storefront", windows, procs,
                {"workbox", "build-box"},
            )["address"],
            "0xtarget",
        )
        self.assertIsNone(WINDOW_FOR_REMOTE(
            "workbox", "default", "missing", windows, procs, {"workbox", "build-box"},
        ))

    def test_resolves_an_ssh_alias_for_precise_window_title_matching(self):
        globals_ = ATTACH["configured_title_hosts"].__globals__
        original = globals_["run_capped"]

        class Result:
            returncode = 0
            stdout = "host workbox\nhostname ubuntu-8gb.example.net\nport 22\n"

        try:
            globals_["run_capped"] = lambda *args, **kwargs: Result()
            labels = ATTACH["configured_title_hosts"]("workbox")
        finally:
            globals_["run_capped"] = original
        self.assertEqual(labels, {"workbox", "ubuntu-8gb.example.net", "ubuntu-8gb"})

    def test_raise_window_checks_hyprctl_and_tolerates_its_disappearance(self):
        globals_ = ATTACH["raise_window"].__globals__
        original = globals_["run_capped"]
        calls = []

        class Result:
            def __init__(self, returncode):
                self.returncode = returncode

        try:
            globals_["run_capped"] = lambda command, **kwargs: calls.append(command) or Result(0)
            self.assertTrue(ATTACH["raise_window"]({"address": "0xa"}))
            self.assertEqual(calls[0], [
                "hyprctl", "dispatch", 'hl.dsp.focus({ window = "address:0xa" })',
            ])
            calls.clear()
            responses = iter([Result(1), Result(0)])
            globals_["run_capped"] = lambda command, **kwargs: calls.append(command) or next(responses)
            self.assertTrue(ATTACH["raise_window"]({"address": "0xa"}))
            self.assertEqual(calls[-1], ["hyprctl", "dispatch", "focuswindow", "address:0xa"])
            calls.clear()
            globals_["run_capped"] = lambda command, **kwargs: calls.append(command) or Result(1)
            self.assertFalse(ATTACH["raise_window"]({"address": "0xa"}))
            self.assertEqual(calls[-1], ["hyprctl", "dispatch", "focuswindow", "address:0xa"])
            globals_["run_capped"] = lambda *args, **kwargs: (_ for _ in ()).throw(FileNotFoundError())
            self.assertFalse(ATTACH["raise_window"]({"address": "0xa"}))
            self.assertEqual(ATTACH["hyprland_windows"](), [])
        finally:
            globals_["run_capped"] = original

    def test_focus_fallback_uses_an_absolute_helper_and_reports_missing_launcher(self):
        globals_ = ATTACH["main"].__globals__
        originals = {name: globals_[name] for name in
                     ("arguments", "process_table", "hyprland_windows", "exec_or_error")}
        commands = []
        try:
            globals_["arguments"] = lambda: SimpleNamespace(
                host="local", session="default", target="w1:p1", workspace="", timeout=999,
                focus=True,
            )
            globals_["process_table"] = lambda: {}
            globals_["hyprland_windows"] = lambda: []
            globals_["exec_or_error"] = lambda command: commands.append(command) or 127
            self.assertEqual(ATTACH["main"](), 127)
        finally:
            globals_.update(originals)
        self.assertEqual(commands[0][0], "omarchy-launch-terminal")
        self.assertTrue(Path(commands[0][1]).is_absolute())
        original_exec = ATTACH["os"].execvp
        try:
            ATTACH["os"].execvp = lambda *_: (_ for _ in ()).throw(FileNotFoundError())
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ATTACH["exec_or_error"](["missing-launcher"]), 127)
        finally:
            ATTACH["os"].execvp = original_exec

    def test_focus_returns_the_herdr_command_failure(self):
        globals_ = ATTACH["main"].__globals__
        originals = {name: globals_[name] for name in
                     ("arguments", "process_table", "hyprland_windows", "window_for_local",
                      "windows_for_pids",
                      "raise_window", "run_capped")}

        class Result:
            returncode = 4
            stdout = ""
            stderr = "pane disappeared"

        try:
            globals_["arguments"] = lambda: SimpleNamespace(
                host="local", session="default", target="w1:p1", workspace="", timeout=3,
                focus=True,
            )
            globals_["process_table"] = lambda: {}
            globals_["hyprland_windows"] = lambda: [{"pid": 1, "address": "0xa"}]
            globals_["window_for_local"] = lambda *args: {"address": "0xa"}
            globals_["windows_for_pids"] = lambda *args: [{"address": "0xa"}]
            globals_["raise_window"] = lambda window: True
            globals_["run_capped"] = lambda *args, **kwargs: Result()
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(ATTACH["main"](), 4)
        finally:
            globals_.update(originals)

    def test_remote_focus_updates_the_title_before_falling_back_to_a_terminal(self):
        globals_ = ATTACH["main"].__globals__
        originals = {name: globals_[name] for name in
                     ("arguments", "process_table", "hyprland_windows",
                      "configured_title_hosts", "raise_window", "run_capped")}
        original_sleep = ATTACH["time"].sleep
        procs = table({
            500: (["kitty"], 1),
            501: (["bash"], 500),
            502: (["mosh-client", "-# workbox", "1.2.3.4", "60001"], 501),
        })
        window_sets = [
            [{"pid": 500, "address": "0xa", "title": "build-box: other"}],
            [{"pid": 500, "address": "0xa", "title": "build-box: storefront"}],
        ]
        focus_commands = []
        raised = []

        class Result:
            returncode = 0
            stdout = ""
            stderr = ""

        try:
            globals_["arguments"] = lambda: SimpleNamespace(
                host="workbox", session="default", target="w1:p1",
                workspace="storefront", hostname="build-box", timeout=3,
                focus=True, peek=False, reply=None,
            )
            globals_["process_table"] = lambda: procs
            globals_["hyprland_windows"] = lambda: window_sets.pop(0) if window_sets else [
                {"pid": 500, "address": "0xa", "title": "build-box: storefront"}
            ]
            globals_["configured_title_hosts"] = lambda host: {host}
            globals_["raise_window"] = lambda window: raised.append(window) or True
            globals_["run_capped"] = lambda command, **kwargs: focus_commands.append(command) or Result()
            ATTACH["time"].sleep = lambda *_: None
            self.assertEqual(ATTACH["main"](), 0)
        finally:
            globals_.update(originals)
            ATTACH["time"].sleep = original_sleep
        self.assertEqual(len(focus_commands), 1)
        self.assertIn("agent focus w1:p1", focus_commands[0][-1])
        self.assertEqual(raised[0]["address"], "0xa")

    def test_local_focus_updates_multiple_client_titles_before_raising(self):
        globals_ = ATTACH["main"].__globals__
        originals = {name: globals_[name] for name in
                     ("arguments", "process_table", "hyprland_windows", "raise_window", "run_capped")}
        original_sleep = ATTACH["time"].sleep
        procs = table({
            100: (["kitty"], 1), 101: (["herdr"], 100),
            200: (["kitty"], 1), 201: (["herdr"], 200),
        })
        window_sets = [
            [
                {"pid": 100, "address": "0xa", "title": "desktop: other"},
                {"pid": 200, "address": "0xb", "title": "desktop: another"},
            ],
            [
                {"pid": 100, "address": "0xa", "title": "desktop: target"},
                {"pid": 200, "address": "0xb", "title": "desktop: another"},
            ],
        ]
        focus_commands = []
        raised = []

        class Result:
            returncode = 0
            stdout = ""
            stderr = ""

        try:
            globals_["arguments"] = lambda: SimpleNamespace(
                host="local", session="default", target="w1:p1", workspace="target",
                hostname="desktop", timeout=3, focus=True, peek=False, reply=None,
            )
            globals_["process_table"] = lambda: procs
            globals_["hyprland_windows"] = lambda: window_sets.pop(0) if window_sets else []
            globals_["raise_window"] = lambda window: raised.append(window) or True
            globals_["run_capped"] = lambda command, **kwargs: focus_commands.append(command) or Result()
            ATTACH["time"].sleep = lambda *_: None
            self.assertEqual(ATTACH["main"](), 0)
        finally:
            globals_.update(originals)
            ATTACH["time"].sleep = original_sleep
        self.assertEqual(focus_commands, [["herdr", "--session", "default", "agent", "focus", "w1:p1"]])
        self.assertEqual(raised[0]["address"], "0xa")

    def test_every_supported_remote_carrier_can_identify_a_titled_window(self):
        for carrier in sorted(ATTACH["REMOTE_CARRIERS"]):
            with self.subTest(carrier=carrier):
                procs = table({
                    500: (["kitty"], 1),
                    501: ([carrier, "workbox"], 500),
                })
                windows = [{"pid": 500, "address": "0xa", "title": "workbox: storefront"}]
                self.assertEqual(
                    WINDOW_FOR_REMOTE("workbox", "default", "storefront", windows, procs)["address"],
                    "0xa",
                )

    def test_remote_title_retry_exhaustion_falls_back_once(self):
        globals_ = ATTACH["main"].__globals__
        originals = {name: globals_[name] for name in
                     ("arguments", "process_table", "hyprland_windows",
                      "configured_title_hosts", "window_for_remote",
                      "wait_for_remote_window", "run_quiet", "raise_window",
                      "exec_or_error")}
        focused = []
        launched = []
        try:
            globals_["arguments"] = lambda: SimpleNamespace(
                host="workbox", session="default", target="w1:p1",
                workspace="storefront", hostname="build-box", timeout=3,
                focus=True, peek=False, reply=None,
            )
            globals_["process_table"] = lambda: {}
            globals_["hyprland_windows"] = lambda: []
            globals_["configured_title_hosts"] = lambda host: {host}
            globals_["window_for_remote"] = lambda *args: None
            globals_["wait_for_remote_window"] = lambda *args: None
            globals_["run_quiet"] = lambda command, timeout: focused.append(command) or 0
            globals_["raise_window"] = lambda window: False
            globals_["exec_or_error"] = lambda command: launched.append(command) or 127
            self.assertEqual(ATTACH["main"](), 127)
        finally:
            globals_.update(originals)
        self.assertEqual(len(focused), 1)
        self.assertEqual(len(launched), 1)
        self.assertEqual(launched[0][0], "omarchy-launch-terminal")

    def test_window_disappearing_during_raise_falls_back_once(self):
        globals_ = ATTACH["main"].__globals__
        originals = {name: globals_[name] for name in
                     ("arguments", "process_table", "hyprland_windows",
                      "windows_for_pids", "window_for_local", "raise_window",
                      "exec_or_error")}
        launched = []
        try:
            globals_["arguments"] = lambda: SimpleNamespace(
                host="local", session="default", target="w1:p1",
                workspace="storefront", hostname="desktop", timeout=3,
                focus=True, peek=False, reply=None,
            )
            globals_["process_table"] = lambda: {}
            globals_["hyprland_windows"] = lambda: [{"address": "0xgone"}]
            globals_["windows_for_pids"] = lambda *args: [{"address": "0xgone"}]
            globals_["window_for_local"] = lambda *args: {"address": "0xgone"}
            globals_["raise_window"] = lambda window: False
            globals_["exec_or_error"] = lambda command: launched.append(command) or 127
            self.assertEqual(ATTACH["main"](), 127)
        finally:
            globals_.update(originals)
        self.assertEqual(len(launched), 1)
        self.assertEqual(launched[0][0], "omarchy-launch-terminal")


class PeekAndReplyTests(unittest.TestCase):
    def test_peek_reads_recent_plain_text_lines(self):
        local = ATTACH["peek_command"]("local", "default", "w1:p1", 8)
        self.assertEqual(local, ["herdr", "--session", "default", "agent", "read", "w1:p1",
                                 "--lines", "8", "--format", "text", "--source", "recent"])
        remote = ATTACH["peek_command"]("workbox", "default", "w1:p1", 500)
        self.assertEqual(remote[0], "ssh")
        self.assertIn("agent read w1:p1 --lines 200", remote[-1])
        with self.assertRaises(SystemExit):
            ATTACH["peek_command"]("local", "default", "")

    def test_peek_discards_partial_output_when_the_byte_cap_is_crossed(self):
        globals_ = ATTACH["main"].__globals__
        originals = {name: globals_[name] for name in ("arguments", "run_capped")}
        calls = []

        class Result:
            returncode = 125
            stdout = "x" * ATTACH["MAX_PEEK_STDOUT_BYTES"]
            stderr = "Command stdout exceeded the safety limit"

        try:
            globals_["arguments"] = lambda: SimpleNamespace(
                host="local", session="default", target="w1:p1", workspace="",
                hostname="", timeout=3, focus=False, peek=True, reply=None, lines=14,
            )
            globals_["run_capped"] = lambda command, **kwargs: calls.append(kwargs) or Result()
            output = io.StringIO()
            errors = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(ATTACH["main"](), 125)
        finally:
            globals_.update(originals)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("exceeded", errors.getvalue())
        self.assertEqual(calls[0]["stdout_limit"], ATTACH["MAX_PEEK_STDOUT_BYTES"])
        self.assertEqual(calls[0]["stderr_limit"], ATTACH["MAX_PEEK_STDERR_BYTES"])

    def test_reply_types_text_then_enter_at_pane_level(self):
        commands = ATTACH["reply_commands"]("local", "default", "w1:p1", " yes, go ahead\n")
        self.assertEqual(commands, [
            ["herdr", "--session", "default", "pane", "send-text", "w1:p1", "yes, go ahead"],
            ["herdr", "--session", "default", "pane", "send-keys", "w1:p1", "enter"],
        ])
        remote = ATTACH["reply_commands"]("workbox", "default", "w1:p1", "2")
        self.assertEqual([c[0] for c in remote], ["ssh", "ssh"])
        self.assertIn("pane send-text w1:p1 2", remote[0][-1])
        with self.assertRaises(SystemExit):
            ATTACH["reply_commands"]("local", "default", "w1:p1", "   ")
        with self.assertRaises(SystemExit):
            ATTACH["reply_commands"]("local", "default", "w1:p1", "x" * 2001)

    def test_the_remote_hostname_makes_a_title_match_exact(self):
        procs = table({
            500: (["kitty"], 1), 501: (["bash"], 500), 502: (["mosh-client", "1.2.3.4", "60001"], 501),
            700: (["kitty"], 1), 701: (["ssh", "otherbox"], 700),
        })
        windows = [
            {"pid": 500, "address": "0xm", "title": "[mosh] ubuntu-8gb: storefront"},
            {"pid": 700, "address": "0xo", "title": "[ssh] otherbox-hostname: storefront"},
        ]
        candidates = {"workbox"} | ATTACH["remote_title_hosts"]("ubuntu-8gb")
        found = WINDOW_FOR_REMOTE("workbox", "default", "storefront", windows, procs, candidates)
        self.assertEqual(found["address"], "0xm")


if __name__ == "__main__":
    unittest.main()

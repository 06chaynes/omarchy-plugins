#!/usr/bin/env python3

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from omaherd_io import OUTPUT_LIMIT_RETURN_CODE, private_runtime_directory, run_capped


class BoundedIoTests(unittest.TestCase):
    def test_stdout_and_stderr_overflow_kill_the_producer_at_the_byte_cap(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream):
                descriptor = "1" if stream == "stdout" else "2"
                command = [
                    sys.executable, "-c",
                    f"import os; os.write({descriptor}, b'x' * 200000)",
                ]
                result = run_capped(
                    command, 3, stdout_limit=4096, stderr_limit=4096,
                )
                self.assertEqual(result.returncode, OUTPUT_LIMIT_RETURN_CODE)
                self.assertLessEqual(len(result.stdout.encode()), 4096)
                self.assertLessEqual(len(result.stderr.encode()), 4096)
                self.assertIn(f"Command {stream} exceeded", result.stderr)

    def test_timeout_does_not_wait_for_a_child_that_holds_both_pipes(self):
        result = run_capped(
            [sys.executable, "-c", "import time; time.sleep(5)"],
            0.1, stdout_limit=1024, stderr_limit=1024,
        )
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stderr, "Command timed out")

    def test_runtime_directory_rejects_symlinks_and_is_mode_0700(self):
        previous = os.environ.get("XDG_RUNTIME_DIR")
        try:
            with tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                os.environ["XDG_RUNTIME_DIR"] = str(base)
                runtime = private_runtime_directory()
                self.assertEqual(runtime, base / "omaherd")
                self.assertEqual(stat.S_IMODE(runtime.stat().st_mode), 0o700)

                linked = base / "linked-runtime"
                linked.symlink_to(base)
                os.environ["XDG_RUNTIME_DIR"] = str(linked)
                self.assertIsNone(private_runtime_directory())
                os.environ["XDG_RUNTIME_DIR"] = "relative/runtime"
                self.assertIsNone(private_runtime_directory())
        finally:
            if previous is None:
                os.environ.pop("XDG_RUNTIME_DIR", None)
            else:
                os.environ["XDG_RUNTIME_DIR"] = previous

    def test_runtime_fallback_is_namespaced_by_uid(self):
        previous = os.environ.pop("XDG_RUNTIME_DIR", None)
        try:
            runtime = private_runtime_directory()
            self.assertEqual(runtime, Path("/tmp") / f"omaherd-{os.getuid()}" / "omaherd")
            self.assertEqual(stat.S_IMODE(runtime.stat().st_mode), 0o700)
        finally:
            if previous is not None:
                os.environ["XDG_RUNTIME_DIR"] = previous

    def test_hook_log_is_atomic_bounded_and_does_not_follow_a_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            runtime = base / "runtime"
            runtime.mkdir(mode=0o700)
            binaries = base / "bin"
            binaries.mkdir()
            shell = binaries / "omarchy-shell"
            shell.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            shell.chmod(0o755)
            environment = dict(
                os.environ,
                XDG_RUNTIME_DIR=str(runtime),
                PATH=f"{binaries}:{os.environ.get('PATH', '')}",
                HERDR_PLUGIN_EVENT="pane.agent_status_changed",
            )
            state = runtime / "omaherd"
            state.mkdir(mode=0o700)
            victim = base / "victim"
            victim.write_text("untouched", encoding="utf-8")
            (state / "hook.log").symlink_to(victim)

            for _ in range(40):
                subprocess.run([str(ROOT / "omaherd-hook")], env=environment, check=True)

            log = state / "hook.log"
            self.assertFalse(log.is_symlink())
            self.assertEqual(victim.read_text(encoding="utf-8"), "untouched")
            self.assertLess(log.stat().st_size, 80)
            self.assertEqual(len(log.read_text(encoding="utf-8").splitlines()), 1)

            linked_runtime = base / "runtime-link"
            linked_runtime.symlink_to(runtime)
            log.unlink()
            environment["XDG_RUNTIME_DIR"] = str(linked_runtime)
            subprocess.run([str(ROOT / "omaherd-hook")], env=environment, check=True)
            self.assertFalse(log.exists())


if __name__ == "__main__":
    unittest.main()

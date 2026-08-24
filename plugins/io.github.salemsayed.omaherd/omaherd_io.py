"""Bounded process I/O and private runtime-directory helpers for Omaherd."""

from __future__ import annotations

import os
import selectors
import signal
import stat
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


OUTPUT_LIMIT_RETURN_CODE = 125
READ_CHUNK_BYTES = 64 * 1024


@dataclass(frozen=True)
class CappedResult:
    returncode: int
    stdout: str
    stderr: str


def _kill_process_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except OSError:
            pass


def run_capped(
    command: Sequence[str],
    timeout: float,
    *,
    stdout_limit: int,
    stderr_limit: int,
    env: Mapping[str, str] | None = None,
) -> CappedResult:
    """Run a child while retaining at most the stated bytes from each pipe.

    Both pipes are drained concurrently. The whole process group is killed as
    soon as either stream crosses its cap, so a producer cannot keep writing
    discarded data until the ordinary timeout.
    """
    limits = {
        "stdout": max(0, int(stdout_limit)),
        "stderr": max(0, int(stderr_limit)),
    }
    process = subprocess.Popen(
        list(command),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=dict(env) if env is not None else None,
        start_new_session=True,
    )
    assert process.stdout is not None and process.stderr is not None
    streams = {"stdout": process.stdout, "stderr": process.stderr}
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    selector = selectors.DefaultSelector()
    for name, stream in streams.items():
        selector.register(stream, selectors.EVENT_READ, name)

    deadline = time.monotonic() + max(0.05, float(timeout))
    exceeded = ""
    timed_out = False
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                _kill_process_group(process)
                break
            events = selector.select(min(0.1, remaining))
            for key, _ in events:
                name = str(key.data)
                available = limits[name] - len(buffers[name])
                try:
                    chunk = os.read(key.fd, min(READ_CHUNK_BYTES, available + 1))
                except OSError:
                    chunk = b""
                if not chunk:
                    try:
                        selector.unregister(key.fileobj)
                    except (KeyError, ValueError):
                        pass
                    continue
                if len(chunk) > available:
                    if available > 0:
                        buffers[name].extend(chunk[:available])
                    exceeded = name
                    _kill_process_group(process)
                    break
                buffers[name].extend(chunk)
            if exceeded:
                break
    finally:
        selector.close()
        for stream in streams.values():
            try:
                stream.close()
            except OSError:
                pass

    if process.poll() is None:
        _kill_process_group(process)
    try:
        returncode = process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        _kill_process_group(process)
        returncode = process.wait()

    stdout = bytes(buffers["stdout"]).decode("utf-8", "replace")
    stderr = bytes(buffers["stderr"]).decode("utf-8", "replace")
    if exceeded:
        return CappedResult(
            OUTPUT_LIMIT_RETURN_CODE,
            stdout,
            f"Command {exceeded} exceeded the {limits[exceeded]}-byte safety limit",
        )
    if timed_out:
        return CappedResult(124, stdout, "Command timed out")
    return CappedResult(returncode, stdout, stderr)


def ensure_private_directory(path: Path) -> bool:
    """Create one directory level and verify it is owned by this uid, 0700.

    Symlinks and directories owned by another account are rejected before any
    files are opened below them. Callers create the per-uid fallback parent
    first, then the application child, so no recursive symlink following is
    needed.
    """
    candidate = Path(path)
    try:
        try:
            os.mkdir(candidate, 0o700)
        except FileExistsError:
            pass
        metadata = os.lstat(candidate)
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            return False
        if metadata.st_uid != os.getuid():
            return False
        if stat.S_IMODE(metadata.st_mode) != 0o700:
            os.chmod(candidate, 0o700, follow_symlinks=False)
        verified = os.lstat(candidate)
        return (
            stat.S_ISDIR(verified.st_mode)
            and not stat.S_ISLNK(verified.st_mode)
            and verified.st_uid == os.getuid()
            and stat.S_IMODE(verified.st_mode) == 0o700
        )
    except OSError:
        return False


def private_runtime_directory() -> Path | None:
    """Return a verified private runtime directory, never a shared /tmp path."""
    configured = os.environ.get("XDG_RUNTIME_DIR")
    if configured:
        base = Path(configured)
        if not base.is_absolute():
            return None
        try:
            metadata = os.lstat(base)
        except OSError:
            return None
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) & 0o077
        ):
            return None
    else:
        base = Path("/tmp") / f"omaherd-{os.getuid()}"
        if not ensure_private_directory(base):
            return None
    application = base / "omaherd"
    return application if ensure_private_directory(application) else None

#!/usr/bin/env python3
"""Collect a normalized attention inbox from local and remote HerdR sessions."""

from __future__ import annotations

import argparse
import concurrent.futures
import glob
import json
import os
import re
import shlex
import shutil
import socket
import sys
import time
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
from omaherd_io import ensure_private_directory, private_runtime_directory, run_capped


REMOTE_HOST_RE = re.compile(r"^[A-Za-z0-9_.@-]+$")
SSH_USER_RE = re.compile(r"^[A-Za-z0-9._~-]+$")
SSH_HOST_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")
SESSION_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
STATE_RANK = {"blocked": 0, "done": 1, "working": 2, "unknown": 3, "idle": 4}
MAX_CHILD_STDOUT_BYTES = 1024 * 1024
MAX_CHILD_STDERR_BYTES = 64 * 1024
MAX_SOCKET_BYTES = 1024 * 1024
MAX_FIXTURE_BYTES = 512 * 1024
MAX_STATUS_BYTES = 512 * 1024
MAX_AGENTS = 512
MAX_SESSIONS_PER_TARGET = 128
MAX_DISCOVERED_HOSTS = 50
MAX_CONFIG_BYTES = 1024 * 1024
MAX_ID_CHARS = 160
MAX_LABEL_CHARS = 256
MAX_CWD_CHARS = 1024
MAX_TITLE_CHARS = 512
PLUGIN_ID = "io.github.salemsayed.omaherd"
REMOTE_PATH = (
    '"$HOME/.local/bin:$HOME/bin:$HOME/.local/share/mise/shims:'
    '$HOME/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:'
    '/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:$PATH"'
)

Runner = Callable[[list[str], float], tuple[int, str, str]]


def compact_error(text: str, fallback: str) -> str:
    line = " ".join(str(text or "").split())
    if not line:
        return fallback
    return line[:197] + "…" if len(line) > 200 else line


def command_runner(command: list[str], timeout: float) -> tuple[int, str, str]:
    try:
        result = run_capped(
            command,
            timeout=timeout,
            env=os.environ.copy(),
            stdout_limit=MAX_CHILD_STDOUT_BYTES,
            stderr_limit=MAX_CHILD_STDERR_BYTES,
        )
        return result.returncode, result.stdout, result.stderr
    except FileNotFoundError:
        return 127, "", f"{command[0]} is not installed"
    except OSError as error:
        return 126, "", str(error)


def bounded_text(value: Any, limit: int) -> str:
    return str(value or "")[:max(0, int(limit))]


def parse_json(text: str) -> dict[str, Any] | None:
    try:
        value = json.loads(text)
    except (TypeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def record_list(value: Any) -> list[dict[str, Any]]:
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []


def safe_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError, OverflowError):
        return 0


def valid_remote_target(value: str) -> bool:
    if len(value) > MAX_LABEL_CHARS:
        return False
    if "://" not in value:
        if value.count("@") > 1:
            return False
        user, separator, host = value.rpartition("@")
        if not separator:
            user = ""
        return bool(SSH_HOST_RE.fullmatch(host)) and (
            not separator or bool(SSH_USER_RE.fullmatch(user))
        )
    if not value.startswith("ssh://") or any(character.isspace() for character in value):
        return False
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        return False
    hostname = parsed.hostname or ""
    # urlsplit validates bracketed IPv6 literals while parsing. Ordinary
    # hostnames and aliases use the same useful-leading-character rule as
    # the plain form above.
    valid_host = ":" in hostname or bool(SSH_HOST_RE.fullmatch(hostname))
    return (
        parsed.scheme == "ssh"
        and valid_host
        and parsed.password is None
        and (parsed.username is None or bool(SSH_USER_RE.fullmatch(parsed.username)))
        and parsed.path in ("", "/")
        and not parsed.query
        and not parsed.fragment
        and (port is None or 1 <= port <= 65535)
    )


def discover_ssh_hosts(config_path: Path | None = None) -> list[dict[str, Any]]:
    home = Path(os.environ.get("HOME") or Path.home())
    root = (config_path or home / ".ssh" / "config").expanduser()
    ssh_dir = root.parent
    seen_files: set[Path] = set()
    seen_hosts: set[str] = set()
    hosts: list[dict[str, Any]] = []

    def read_config(path: Path) -> None:
        if len(hosts) >= 50:
            return
        try:
            resolved = path.expanduser().resolve()
        except OSError:
            return
        if resolved in seen_files or not resolved.is_file():
            return
        seen_files.add(resolved)
        try:
            with resolved.open("rb") as handle:
                raw_config = handle.read(MAX_CONFIG_BYTES + 1)
            if len(raw_config) > MAX_CONFIG_BYTES:
                return
            lines = raw_config.decode("utf-8", "replace").splitlines()
        except OSError:
            return

        pending_aliases: list[str] = []
        pending_user = ""

        def flush_host_block() -> None:
            nonlocal pending_aliases, pending_user
            # Entries dedicated to Git transport are not interactive machines
            # and would only add noise to a HerdR connection picker.
            if pending_user.lower() != "git":
                for alias in pending_aliases:
                    if alias in seen_hosts or len(hosts) >= 50:
                        continue
                    seen_hosts.add(alias)
                    hosts.append({
                        "host": bounded_text(alias, MAX_LABEL_CHARS),
                        "source": "SSH config",
                        "detail": "Configured SSH host",
                    })
            pending_aliases = []
            pending_user = ""

        for line in lines:
            if len(hosts) >= 50:
                break
            try:
                fields = shlex.split(line, comments=True, posix=True)
            except ValueError:
                continue
            if len(fields) < 2:
                continue
            keyword = fields[0].lower()
            if keyword == "include":
                for pattern in fields[1:]:
                    expanded = Path(os.path.expandvars(pattern)).expanduser()
                    if not expanded.is_absolute():
                        expanded = ssh_dir / expanded
                    for match in sorted(glob.glob(str(expanded))):
                        read_config(Path(match))
            elif keyword == "host":
                flush_host_block()
                pending_aliases = [
                    alias for alias in fields[1:]
                    if not alias.startswith("!")
                    and not any(marker in alias for marker in "*?!")
                    and REMOTE_HOST_RE.fullmatch(alias)
                ]
            elif keyword == "user" and pending_aliases:
                pending_user = fields[1]
            elif keyword == "match":
                flush_host_block()

        flush_host_block()

    read_config(root)
    return hosts[:50]


def discover_tailscale_hosts(
    runner: Runner = command_runner,
    available: bool | None = None,
) -> list[dict[str, Any]]:
    if available is None:
        available = shutil.which("tailscale") is not None
    if not available:
        return []
    try:
        code, stdout, _ = runner(["tailscale", "status", "--json"], 2.0)
    except Exception:
        return []
    status = parse_json(stdout)
    if code != 0 or not status or not isinstance(status.get("Peer"), dict):
        return []
    hosts: list[dict[str, Any]] = []
    for peer in status["Peer"].values():
        if not isinstance(peer, dict) or peer.get("Online") is not True:
            continue
        operating_system = str(peer.get("OS") or "").lower()
        if operating_system not in ("linux", "darwin"):
            continue
        hostname = str(peer.get("DNSName") or peer.get("HostName") or "").rstrip(".")
        if not REMOTE_HOST_RE.fullmatch(hostname):
            continue
        hosts.append({
            "host": bounded_text(hostname, MAX_LABEL_CHARS),
            "source": "Tailscale",
            "detail": bounded_text(peer.get("HostName") or hostname, MAX_LABEL_CHARS),
        })
    return sorted(hosts, key=lambda item: item["host"].lower())[:50]


def discover_hosts(
    configured_hosts: list[str],
    runner: Runner = command_runner,
    ssh_config_path: Path | None = None,
) -> list[dict[str, Any]]:
    configured = set(configured_hosts)
    seen = set(configured)
    discovered: list[dict[str, Any]] = []
    for item in [*discover_ssh_hosts(ssh_config_path), *discover_tailscale_hosts(runner)]:
        host = str(item.get("host") or "")
        if not host or host in seen:
            continue
        seen.add(host)
        discovered.append(item)
    return discovered


def basename(path: Any) -> str:
    value = str(path or "").rstrip("/")
    return Path(value).name if value else ""


def snapshot_from_response(response: dict[str, Any] | None) -> dict[str, Any] | None:
    if not response:
        return None
    result = response.get("result")
    if not isinstance(result, dict):
        return None
    snapshot = result.get("snapshot")
    return snapshot if isinstance(snapshot, dict) else None


def normalize_snapshot(host: str, session: str, snapshot: dict[str, Any]) -> list[dict[str, Any]]:
    workspaces = {
        item.get("workspace_id"): item
        for item in record_list(snapshot.get("workspaces"))[:MAX_AGENTS]
        if isinstance(item.get("workspace_id"), (str, int, float)) and item.get("workspace_id")
    }
    tabs = {
        item.get("tab_id"): item
        for item in record_list(snapshot.get("tabs"))[:MAX_AGENTS]
        if isinstance(item.get("tab_id"), (str, int, float)) and item.get("tab_id")
    }
    agents: list[dict[str, Any]] = []

    for raw in record_list(snapshot.get("agents"))[:MAX_AGENTS]:
        if not raw.get("pane_id"):
            continue
        workspace_id = raw.get("workspace_id")
        tab_id = raw.get("tab_id")
        workspace = workspaces.get(workspace_id, {}) if isinstance(workspace_id, (str, int, float)) else {}
        tab = tabs.get(tab_id, {}) if isinstance(tab_id, (str, int, float)) else {}
        status = str(raw.get("agent_status") or "unknown").lower()
        if status not in STATE_RANK:
            status = "unknown"
        kind = bounded_text(raw.get("display_agent") or raw.get("agent") or "agent", MAX_LABEL_CHARS)
        name = bounded_text(raw.get("name") or kind, MAX_LABEL_CHARS)
        cwd = bounded_text(raw.get("foreground_cwd") or raw.get("cwd") or "", MAX_CWD_CHARS)
        workspace_label = bounded_text(workspace.get("label") or "Workspace", MAX_LABEL_CHARS)
        pane_id = bounded_text(raw["pane_id"], MAX_ID_CHARS)

        agents.append(
            {
                "key": bounded_text(f"{host}|{session}|{pane_id}", MAX_LABEL_CHARS * 2),
                "host": bounded_text(host, MAX_LABEL_CHARS),
                "session": bounded_text(session, MAX_ID_CHARS),
                "paneId": pane_id,
                "terminalId": bounded_text(raw.get("terminal_id"), MAX_ID_CHARS),
                "workspaceId": bounded_text(raw.get("workspace_id"), MAX_ID_CHARS),
                "workspaceLabel": workspace_label,
                "workspaceNumber": safe_int(workspace.get("number")),
                "tabId": bounded_text(raw.get("tab_id"), MAX_ID_CHARS),
                "tabLabel": bounded_text(tab.get("label"), MAX_LABEL_CHARS),
                "tabNumber": safe_int(tab.get("number")),
                "agent": bounded_text(raw.get("agent"), MAX_LABEL_CHARS),
                "displayAgent": kind,
                "name": name,
                "status": status,
                "focused": raw.get("focused") is True,
                "stateChangeSeq": safe_int(raw.get("state_change_seq")),
                "cwd": cwd,
                "cwdLabel": bounded_text(basename(cwd), MAX_LABEL_CHARS),
                "title": bounded_text(
                    raw.get("title") or raw.get("terminal_title_stripped"), MAX_TITLE_CHARS,
                ),
            }
        )

    return sorted(
        agents,
        key=lambda item: (
            STATE_RANK.get(item["status"], STATE_RANK["unknown"]),
            item["workspaceNumber"],
            item["tabNumber"],
            item["paneId"],
        ),
    )


def control_dir() -> Path | None:
    return private_runtime_directory()


def ssh_options(timeout: int, control: Path | None = None) -> list[str]:
    """Noninteractive SSH, sharing one connection per host across polls.

    Omaherd asks every remote host twice per session every few seconds; a
    persisted control master turns that into one TCP/SSH handshake a minute
    instead of one per question. ControlPersist keeps the master alive only
    briefly, so nothing lingers after monitoring stops.
    """
    options = ["-o", "BatchMode=yes", "-o", f"ConnectTimeout={timeout}"]
    path = control if control is not None else control_dir()
    if path is None:
        return options
    try:
        if control is not None and not ensure_private_directory(path):
            return options
    except OSError:
        return options
    return options + [
        "-o", "ControlMaster=auto",
        "-o", f"ControlPath={path}/ssh-%C",
        "-o", "ControlPersist=60",
    ]


HOSTNAME_MARKER = "__omaherd_hostname__"


def target_command(
    host: str, remote: bool, timeout: int, arguments: list[str], with_hostname: bool = False,
) -> tuple[list[str], float]:
    if not remote:
        return ["herdr", *arguments], 2.0
    herdr = shlex.join(["herdr", *arguments])
    if with_hostname:
        # The remote names its own windows "<hostname>: <workspace>", and that
        # hostname is rarely the SSH alias. Asking for it on the same trip as
        # the session list costs nothing and lets a focus find the exact window.
        script = (f"PATH={REMOTE_PATH}; export PATH; {herdr}; "
                  f"printf '\\n{HOSTNAME_MARKER} %s\\n' \"$(hostname 2>/dev/null || uname -n)\"")
    else:
        script = f"PATH={REMOTE_PATH}; export PATH; exec {herdr}"
    command = [
        "ssh",
        *ssh_options(timeout),
        "--",
        host,
        f"exec /bin/sh -lc {shlex.quote(script)}",
    ]
    return command, max(3.0, float(timeout + 2))


def split_hostname_trailer(stdout: str) -> tuple[str, str]:
    """Separate the hostname line the listing command appends from the JSON."""
    text = str(stdout or "")
    marker = text.rfind(HOSTNAME_MARKER)
    if marker < 0:
        return text, ""
    hostname = text[marker + len(HOSTNAME_MARKER):].strip().split("\n", 1)[0].strip()
    if not REMOTE_HOST_RE.fullmatch(hostname):
        hostname = ""
    return text[:marker], hostname


def socket_snapshot(path: str, timeout: float = 1.0) -> dict[str, Any] | None:
    """`session.snapshot` straight from the session socket.

    Two milliseconds instead of a process spawn. One request per connection,
    newline-delimited JSON, exactly as the socket API documents. Any trouble
    returns None and the caller falls back to the CLI.
    """
    if not path or not os.path.exists(path):
        return None
    request = json.dumps({"id": "omaherd", "method": "session.snapshot", "params": {}}) + "\n"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(max(0.1, float(timeout)))
            client.connect(path)
            client.sendall(request.encode("utf-8"))
            response_bytes = bytearray()
            while True:
                remaining = MAX_SOCKET_BYTES - len(response_bytes)
                chunk = client.recv(min(1 << 16, remaining + 1))
                if not chunk:
                    break
                if len(chunk) > remaining:
                    return None
                response_bytes.extend(chunk)
                if b"\n" in chunk:
                    break
    except (OSError, ValueError):
        return None
    line = bytes(response_bytes).split(b"\n", 1)[0]
    response = parse_json(line.decode("utf-8", "replace"))
    if not response or "error" in response:
        return None
    result = response.get("result")
    if isinstance(result, dict) and isinstance(result.get("snapshot"), dict):
        return result["snapshot"]
    if isinstance(result, dict) and isinstance(result.get("agents"), list):
        return result
    return None


SnapshotReader = Callable[[str, float], "dict[str, Any] | None"]


def collect_target(
    host: str, remote: bool, timeout: int, runner: Runner = command_runner,
    budget: float | None = None, snapshot_reader: SnapshotReader | None = socket_snapshot,
) -> dict[str, Any]:
    target: dict[str, Any] = {
        "host": host,
        "local": not remote,
        "reachable": True,
        "installed": True,
        "running": False,
        "hostname": "" if remote else socket.gethostname(),
        "sessions": [],
        "agents": [],
        "error": "",
    }

    if remote and not valid_remote_target(host):
        target.update(reachable=False, installed=False, error="Invalid SSH target")
        return target
    # Only the real runner needs a real binary; a test's fake runner answers
    # for HerdR itself, on machines (CI) that have never installed it.
    if not remote and runner is command_runner and shutil.which("herdr") is None:
        target.update(installed=False, error="")
        return target

    total_budget = float(budget) if budget is not None else (float(timeout + 2) if remote else 2.0)
    deadline = time.monotonic() + max(0.05, total_budget)

    def run(arguments: list[str], with_hostname: bool = False) -> tuple[int, str, str]:
        command, command_timeout = target_command(host, remote, timeout, arguments, with_hostname)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return 124, "", "Collection deadline exceeded"
        try:
            return runner(command, min(command_timeout, max(0.05, remaining)))
        except Exception as error:
            return 126, "", compact_error(str(error), "Command failed")

    code, stdout, stderr = run(["session", "list", "--json"], with_hostname=remote)
    if remote:
        stdout, hostname = split_hostname_trailer(stdout)
        if hostname:
            target["hostname"] = hostname
    listing = parse_json(stdout)
    if code != 0 or not listing or not isinstance(listing.get("sessions"), list):
        if remote:
            target["reachable"] = False
            target["installed"] = code not in (127,)
            target["error"] = compact_error(stderr or stdout, "SSH host unavailable")
        else:
            target["error"] = compact_error(stderr or stdout, "Could not list HerdR sessions")
        return target

    raw_sessions = record_list(listing["sessions"])
    for raw_session in raw_sessions[:MAX_SESSIONS_PER_TARGET]:
        name = bounded_text(raw_session.get("name") or "default", MAX_ID_CHARS)
        if not SESSION_RE.fullmatch(name):
            continue
        session = {
            "name": name,
            "default": raw_session.get("default") is True,
            "running": raw_session.get("running") is True,
            "agentCount": 0,
            "error": "",
            "socketPath": bounded_text(raw_session.get("socket_path"), MAX_CWD_CHARS) if not remote else "",
            "transport": "",
        }
        target["sessions"].append(session)
        if session["running"]:
            target["running"] = True

    # Every command for one host shares one deadline. A host with hundreds of
    # named sessions can no longer hold the whole shell poll open for hundreds
    # of individual SSH timeouts; sessions not reached carry a clear error and
    # are retried on the next refresh.
    for session in target["sessions"]:
        if not session["running"]:
            continue
        if len(target["agents"]) >= MAX_AGENTS:
            session["error"] = f"Agent safety limit reached ({MAX_AGENTS})"
            continue
        name = session["name"]
        snapshot = None
        # Locally the session socket answers in microseconds; the CLI spawn is
        # only for sessions whose socket is missing or mid-restart.
        if not remote and snapshot_reader is not None and session["socketPath"]:
            remaining = deadline - time.monotonic()
            if remaining > 0:
                try:
                    snapshot = snapshot_reader(session["socketPath"], min(1.0, remaining))
                except Exception:
                    snapshot = None
            if snapshot is not None:
                session["transport"] = "socket"
        if snapshot is None:
            code, stdout, stderr = run(["--session", name, "api", "snapshot"])
            response = parse_json(stdout)
            snapshot = snapshot_from_response(response)
            if code != 0 or snapshot is None:
                session["error"] = compact_error(stderr or stdout, "Could not read session snapshot")
                continue
            session["transport"] = "cli"
        try:
            session_agents = normalize_snapshot(host, name, snapshot)
        except Exception as error:
            session["error"] = compact_error(str(error), "Could not normalize session snapshot")
            continue
        remaining_agents = MAX_AGENTS - len(target["agents"])
        kept_agents = session_agents[:remaining_agents]
        session["agentCount"] = len(kept_agents)
        target["agents"].extend(kept_agents)
        if len(kept_agents) < len(session_agents):
            session["error"] = f"Agent safety limit reached ({MAX_AGENTS})"

    target["agents"].sort(
        key=lambda item: (
            STATE_RANK.get(item["status"], STATE_RANK["unknown"]),
            item["session"],
            item["workspaceNumber"],
            item["tabNumber"],
        )
    )
    return target


def aggregate(
    targets: list[dict[str, Any]],
    discovered_hosts: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    agents = []
    for target in targets:
        for agent in target.get("agents", []):
            # The machine's own name rides along so a focus can match the
            # window title HerdR writes there.
            agent["hostname"] = bounded_text(target.get("hostname"), MAX_LABEL_CHARS)
            if len(agents) < MAX_AGENTS:
                agents.append(agent)
    agents.sort(
        key=lambda item: (
            0 if item.get("host") == "local" else 1,
            str(item.get("host") or ""),
            STATE_RANK.get(item.get("status"), STATE_RANK["unknown"]),
            str(item.get("session") or ""),
            int(item.get("workspaceNumber") or 0),
            int(item.get("tabNumber") or 0),
        )
    )
    counts = {"total": len(agents), "attention": 0, "blocked": 0, "done": 0, "working": 0, "idle": 0, "unknown": 0}
    for agent in agents:
        state = agent.get("status", "unknown")
        counts[state if state in counts else "unknown"] += 1
    counts["attention"] = counts["blocked"] + counts["done"]

    local = next((target for target in targets if target.get("local") is True), None)
    installed = bool(local and local.get("installed"))
    any_running = any(target.get("running") for target in targets)
    has_errors = any(target.get("error") for target in targets) or any(
        session.get("error")
        for target in targets
        for session in target.get("sessions", [])
        if isinstance(session, dict)
    )

    if counts["attention"]:
        status_text = f"{counts['attention']} need attention"
    elif counts["working"]:
        status_text = f"{counts['working']} working"
    elif counts["total"]:
        status_text = f"{counts['total']} {'agent' if counts['total'] == 1 else 'agents'}"
    elif any_running:
        status_text = "No active agents"
    elif not installed and len(targets) == 1:
        status_text = "HerdR is not installed"
    else:
        status_text = "HerdR is stopped"

    target_errors = [
        f"{target.get('host')}: {target.get('error')}"
        for target in targets
        if target.get("error")
    ]
    public_targets = []
    for target in targets:
        public_target = {key: value for key, value in target.items() if key != "agents"}
        public_target["host"] = bounded_text(public_target.get("host"), MAX_LABEL_CHARS)
        public_target["hostname"] = bounded_text(public_target.get("hostname"), MAX_LABEL_CHARS)
        public_target["error"] = compact_error(str(public_target.get("error") or ""), "")
        public_target["sessions"] = record_list(public_target.get("sessions"))[:MAX_SESSIONS_PER_TARGET]
        public_targets.append(public_target)

    truncated = sum(len(record_list(target.get("agents"))) for target in targets) > len(agents)
    if truncated:
        has_errors = True
        if not target_errors:
            target_errors.append(f"Showing the first {MAX_AGENTS} agents (safety limit)")

    return {
        "ok": True,
        "installed": installed,
        "generatedAt": int(time.time()),
        "statusText": status_text,
        "targets": public_targets[:9],
        "discoveredHosts": record_list(discovered_hosts)[:MAX_DISCOVERED_HOSTS],
        "agents": agents,
        "counts": counts,
        "hasErrors": has_errors,
        "lastError": target_errors[0] if target_errors else "",
    }


def collect(
    remote_hosts: list[str], timeout: int, runner: Runner = command_runner,
    include_discovery: bool = True,
) -> dict[str, Any]:
    unique_hosts: list[str] = []
    for host in remote_hosts:
        if host and host not in unique_hosts:
            unique_hosts.append(host)
    unique_hosts = unique_hosts[:8]

    if not unique_hosts:
        return aggregate(
            [collect_target("local", False, timeout, runner)],
            discover_hosts([], runner) if include_discovery else [],
        )

    targets: list[dict[str, Any]] = []
    target_specs = [("local", False)] + [(host, True) for host in unique_hosts]
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(target_specs))) as executor:
        future_targets = [
            executor.submit(collect_target, host, remote, timeout, runner)
            for host, remote in target_specs
        ]
        # Local is submitted first and starts in the first wave, so a
        # disconnected fleet cannot postpone it behind remote work.
        for (host, remote), future in zip(target_specs, future_targets):
            try:
                targets.append(future.result())
            except Exception as error:
                targets.append({
                    "host": host, "local": not remote, "reachable": not remote,
                    "installed": False, "running": False, "sessions": [], "agents": [],
                    "error": compact_error(str(error), "Target collection failed"),
                })
    return aggregate(targets, discover_hosts(unique_hosts, runner) if include_discovery else [])


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remote-host", action="append", default=[], help="SSH config alias to query")
    parser.add_argument("--timeout", type=int, default=3, help="SSH connection timeout in seconds")
    parser.add_argument("--skip-discovery", action="store_true",
                        help="Skip SSH/Tailscale host discovery for background-only refreshes")
    parser.add_argument("--ensure-hook", default="",
                        help="Link this plugin directory in HerdR if it is not already linked")
    parser.add_argument("--pretty", action="store_true")
    return parser.parse_args()


def fixture_path() -> Path | None:
    """A developer drop-in that replaces live collection with a saved status.

    Set OMAHERD_FIXTURE to a JSON file, or drop one at
    $XDG_RUNTIME_DIR/omaherd/fixture.json, to drive the panel with any herd
    you like — twenty agents, an offline host, a stopped server — without
    needing those conditions for real. The runtime directory is private to
    the user, so nothing else can plant one.
    """
    configured = os.environ.get("OMAHERD_FIXTURE", "")
    if configured:
        # An explicit fixture wins even when it is missing or malformed. A
        # typo must fail clearly instead of silently reading the live herd (or
        # falling through to a different drop-in fixture).
        return Path(configured)
    runtime = control_dir()
    if runtime is None:
        return None
    drop_in = runtime / "fixture.json"
    if drop_in.is_file():
        return drop_in
    return None


def load_fixture(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("rb") as handle:
            raw_fixture = handle.read(MAX_FIXTURE_BYTES + 1)
        if len(raw_fixture) > MAX_FIXTURE_BYTES:
            return None
        fixture = parse_json(raw_fixture.decode("utf-8", "replace"))
    except OSError:
        return None
    if not fixture:
        return None
    fixture.setdefault("ok", True)
    fixture["generatedAt"] = int(time.time())
    fixture.setdefault("fixture", str(path))
    return fixture


def ensure_hook(plugin_root: str) -> int:
    """Idempotently link the HerdR hook without exposing its output to QML."""
    root = Path(plugin_root)
    if not root.is_dir() or not (root / "herdr-plugin.toml").is_file():
        print("Invalid Omaherd plugin directory", file=sys.stderr)
        return 2
    code, stdout, stderr = command_runner(["herdr", "plugin", "list"], 3.0)
    if code != 0:
        if stderr:
            print(compact_error(stderr, "Could not list HerdR plugins"), file=sys.stderr)
        return code
    if PLUGIN_ID in stdout:
        return 0
    code, stdout, stderr = command_runner(
        ["herdr", "plugin", "link", str(root.resolve()), "--enabled"], 5.0,
    )
    if code != 0:
        print(compact_error(stderr or stdout, "Could not link the HerdR hook"), file=sys.stderr)
    return code


def _recount_status(result: dict[str, Any], limited: bool = False) -> None:
    agents = record_list(result.get("agents"))
    counts = {"total": len(agents), "attention": 0, "blocked": 0, "done": 0,
              "working": 0, "idle": 0, "unknown": 0}
    for agent in agents:
        state = str(agent.get("status") or "unknown")
        counts[state if state in counts else "unknown"] += 1
    counts["attention"] = counts["blocked"] + counts["done"]
    result["counts"] = counts
    if limited:
        result["hasErrors"] = True
        result["lastError"] = f"Status output limited to {len(agents)} agents for safety"


def serialize_status(result: dict[str, Any], pretty: bool = False) -> str:
    """Serialize a model envelope that can never exceed MAX_STATUS_BYTES."""
    indent = 2 if pretty else None
    separators = None if pretty else (",", ":")

    def encode() -> str:
        return json.dumps(
            result, indent=indent, sort_keys=pretty, separators=separators,
            ensure_ascii=False,
        ) + "\n"

    try:
        output = encode()
        while len(output.encode("utf-8")) > MAX_STATUS_BYTES and result.get("agents"):
            agents = record_list(result.get("agents"))
            result["agents"] = agents[:len(agents) // 2]
            _recount_status(result, limited=True)
            output = encode()
        if len(output.encode("utf-8")) > MAX_STATUS_BYTES:
            for target in record_list(result.get("targets")):
                target["sessions"] = []
            result["discoveredHosts"] = []
            result["hasErrors"] = True
            result["lastError"] = "Status metadata reduced to the safe output limit"
            output = encode()
        if len(output.encode("utf-8")) <= MAX_STATUS_BYTES:
            return output
    except (TypeError, ValueError, RecursionError):
        pass
    return json.dumps(error_status("Status exceeded the safe output limit"), separators=(",", ":")) + "\n"


def main() -> int:
    args = arguments()
    if args.ensure_hook:
        return ensure_hook(args.ensure_hook)
    timeout = max(1, min(15, args.timeout))
    fixture = fixture_path()
    exit_code = 0
    if fixture:
        result = load_fixture(fixture)
        if result is None:
            message = f"Could not load Omaherd fixture: {fixture}"
            result = error_status(message)
            print(message, file=sys.stderr)
            exit_code = 1
    else:
        try:
            result = collect(args.remote_host, timeout, include_discovery=not args.skip_discovery)
            result["discoveryIncluded"] = not args.skip_discovery
        except Exception as error:
            message = compact_error(str(error), "Could not collect HerdR status")
            result = error_status(message)
            print(message, file=sys.stderr)
            exit_code = 1
    sys.stdout.write(serialize_status(result, args.pretty))
    return exit_code


def error_status(message: str) -> dict[str, Any]:
    return {
        "ok": False,
        "installed": False,
        "generatedAt": int(time.time()),
        "statusText": "Omaherd status failed",
        "targets": [],
        "discoveredHosts": [],
        "agents": [],
        "counts": {"total": 0, "attention": 0, "blocked": 0, "done": 0,
                   "working": 0, "idle": 0, "unknown": 0},
        "hasErrors": True,
        "lastError": message,
    }


if __name__ == "__main__":
    raise SystemExit(main())

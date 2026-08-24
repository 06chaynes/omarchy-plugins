#!/usr/bin/env python3

import importlib.util
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("omaherd_status_stress", ROOT / "omaherd-status.py")
STATUS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(STATUS)


class StatusStressTests(unittest.TestCase):
    def test_twenty_five_thousand_agents_are_cut_at_the_producer_boundary(self):
        states = ("blocked", "done", "working", "idle", "unknown")
        workspaces = [
            {"workspace_id": f"w{index}", "number": index, "label": f"workspace-{index}"}
            for index in range(100)
        ]
        tabs = [
            {"tab_id": f"t{index}", "workspace_id": f"w{index % 100}",
             "number": index, "label": f"tab-{index}"}
            for index in range(500)
        ]
        raw_agents = [
            {"pane_id": f"w{index % 100}:p{index}", "workspace_id": f"w{index % 100}",
             "tab_id": f"t{index % 500}", "agent_status": states[index % len(states)],
             "agent": "codex", "foreground_cwd": f"/work/project-{index % 100}"}
            for index in range(25_000)
        ]

        agents = STATUS.normalize_snapshot("local", "stress", {
            "workspaces": workspaces, "tabs": tabs, "agents": raw_agents,
        })
        self.assertEqual(len(agents), STATUS.MAX_AGENTS)
        self.assertEqual(len({agent["key"] for agent in agents}), STATUS.MAX_AGENTS)

        result = STATUS.aggregate([{
            "host": "local", "local": True, "installed": True, "running": True,
            "hostname": "stressbox", "sessions": [], "agents": agents, "error": "",
        }])
        self.assertEqual(result["counts"]["total"], STATUS.MAX_AGENTS)
        self.assertEqual(result["counts"]["attention"], sum(
            agent["status"] in ("blocked", "done") for agent in agents
        ))
        self.assertLessEqual(
            len(STATUS.serialize_status(result).encode("utf-8")), STATUS.MAX_STATUS_BYTES,
        )
        self.assertTrue(all(agent["hostname"] == "stressbox" for agent in result["agents"]))

    def test_maximum_host_fanout_is_deduplicated_capped_and_bounded(self):
        lock = threading.Lock()
        active = 0
        maximum_active = 0
        original_collect_target = STATUS.collect_target

        def fake_collect_target(host, remote, timeout, runner):
            nonlocal active, maximum_active
            with lock:
                active += 1
                maximum_active = max(maximum_active, active)
            try:
                time.sleep(0.01)
                return {
                    "host": host, "local": not remote, "reachable": True,
                    "installed": True, "running": False, "hostname": host,
                    "sessions": [], "agents": [], "error": "",
                }
            finally:
                with lock:
                    active -= 1

        STATUS.collect_target = fake_collect_target
        try:
            result = STATUS.collect(
                ["host-0", "host-0", *[f"host-{index}" for index in range(12)]],
                3, lambda *_: (0, "", ""), include_discovery=False,
            )
        finally:
            STATUS.collect_target = original_collect_target

        self.assertEqual([target["host"] for target in result["targets"]],
                         ["local", *[f"host-{index}" for index in range(8)]])
        self.assertEqual(maximum_active, 4)


if __name__ == "__main__":
    unittest.main()

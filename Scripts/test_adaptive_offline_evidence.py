#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import time
import unittest


def load_script():
    script_path = Path(__file__).with_name("adaptive_offline_evidence.py")
    spec = importlib.util.spec_from_file_location("adaptive_offline_evidence", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def iso(stamp):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(stamp))


def token_count(stamp, used, resets_at, limit_id="codex"):
    return {
        "timestamp": iso(stamp),
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {"total_token_usage": {"input_tokens": 123}},
            "rate_limits": {
                "limit_id": limit_id,
                "plan_type": "plus",
                "primary": {"used_percent": used, "window_minutes": 10080, "resets_at": resets_at},
                "secondary": None,
            },
        },
    }


class AdaptiveOfflineEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script()
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.sessions = self.root / "codex" / "sessions" / "2026" / "09" / "29"
        self.sessions.mkdir(parents=True)
        self.now = time.time()

    def tearDown(self):
        self.directory.cleanup()

    def write_rollout(self, name, events):
        lines = [json.dumps(event, separators=(",", ":")) for event in events]
        (self.sessions / name).write_text("\n".join(lines) + "\n", encoding="utf-8")

    def export(self):
        output = self.root / "evidence.jsonl"
        with contextlib.redirect_stdout(io.StringIO()):
            status = self.module.main([
                "export", "--codex-home", str(self.root / "codex"), "--output", str(output),
            ])
        self.assertEqual(status, 0)
        return [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]

    def test_export_writes_only_allowlisted_fields(self):
        start = self.now - 3600
        self.write_rollout("rollout-private.jsonl", [
            {"timestamp": iso(start), "type": "session_meta",
             "payload": {"id": "019f-secret-session", "cwd": "/Users/someone/secret-project"}},
            {"timestamp": iso(start + 5), "type": "event_msg", "payload": {"type": "task_started"}},
            {"timestamp": iso(start + 6), "type": "response_item",
             "payload": {"type": "message", "content": "private prompt text"}},
            token_count(start + 60, 10.0, start + 86400, limit_id="limit-secret-id"),
            token_count(start + 600, 11.0, start + 86400, limit_id="limit-secret-id"),
        ])

        records = self.export()
        text = json.dumps(records)

        allowed = {"kind", "schema", "days", "bucketMinutes", "sources", "t", "stream", "windowMinutes",
                   "usedPercent", "first"}
        self.assertTrue(all(set(record) <= allowed for record in records))
        for private in ["secret-project", "019f-secret-session", "private prompt", "plus", "limit-secret-id", "2026-"]:
            self.assertNotIn(private, text)
        self.assertEqual(records[0]["schema"], self.module.SCHEMA)

    def test_accounts_sharing_a_limit_id_stay_separate_and_flicker_is_ignored(self):
        start = self.now - 7200
        self.write_rollout("rollout-a.jsonl", [
            token_count(start, 40.0, start + 3 * 86400),
            token_count(start + 60, 41.0, start + 3 * 86400),
            token_count(start + 120, 40.0, start + 3 * 86400),
            token_count(start + 180, 41.0, start + 3 * 86400),
        ])
        self.write_rollout("rollout-b.jsonl", [
            token_count(start + 30, 5.0, start + 6 * 86400),
            token_count(start + 90, 6.0, start + 6 * 86400),
        ])

        quota = [record for record in self.export() if record["kind"] == "quota"]

        self.assertEqual(len({record["stream"] for record in quota}), 2)
        self.assertEqual([record["usedPercent"] for record in quota if not record["first"]], [41.0, 6.0])

    def test_accounts_resetting_within_the_same_hour_stay_separate_despite_reset_jitter(self):
        start = self.now - 7200
        hour = (int(start) // 3600 + 72) * 3600
        self.write_rollout("rollout-a.jsonl", [
            token_count(start, 20.0, hour + 5 * 60),
            token_count(start + 60, 21.0, hour + 5 * 60 + 2),
            token_count(start + 120, 22.0, hour + 5 * 60 - 1),
        ])
        self.write_rollout("rollout-b.jsonl", [
            token_count(start + 30, 3.0, hour + 25 * 60),
            token_count(start + 90, 4.0, hour + 25 * 60 + 3),
        ])

        quota = [record for record in self.export() if record["kind"] == "quota"]

        self.assertEqual(len({record["stream"] for record in quota}), 2)
        self.assertEqual([record["usedPercent"] for record in quota if not record["first"]], [21.0, 4.0, 22.0])

    def test_quota_increase_at_the_end_of_a_trace_is_measured_for_every_policy(self):
        records = [
            {"kind": "header"},
            {"t": 0, "kind": "quota", "stream": "s0", "windowMinutes": 10080, "usedPercent": 10.0, "first": True},
            {"t": 100, "kind": "quota", "stream": "s0", "windowMinutes": 10080, "usedPercent": 11.0, "first": False},
        ]

        rows = {row["policy"]: row for row in self.module.summarize(records)["policies"]}

        self.assertEqual(rows["fixed30"]["lagMaxMinutes"], 20.0)
        self.assertTrue(all("lagMaxMinutes" in row for row in rows.values()))
        self.assertEqual(rows["fixed30"]["refreshesPerDay"], round(4 / (100 / 1440), 1))

    def test_percentiles_use_the_replay_kit_nearest_rank(self):
        self.assertEqual(self.module.percentile([float(value) for value in range(1, 21)], 0.95), 19.0)
        self.assertEqual(self.module.percentile([1.0, 2.0, 3.0, 4.0], 0.5), 2.0)
        self.assertEqual(self.module.percentile([7.0], 0.95), 7.0)

    def test_agent_aware_replay_catches_quota_increases_that_long_idle_misses(self):
        records = [{"kind": "header"}]
        records += [{"t": minute, "kind": "codexActivity"} for minute in range(100, 140)]
        records += [
            {"t": 100, "kind": "quota", "stream": "s0", "windowMinutes": 10080, "usedPercent": 10.0, "first": True},
            {"t": 112, "kind": "quota", "stream": "s0", "windowMinutes": 10080, "usedPercent": 11.0, "first": False},
            {"t": 131, "kind": "quota", "stream": "s0", "windowMinutes": 10080, "usedPercent": 12.0, "first": False},
            {"t": 600, "kind": "codexActivity"},
        ]

        rows = {row["policy"]: row for row in self.module.summarize(records)["policies"]}

        self.assertEqual(rows["agentAwareNoMenu"]["withinFiveMinutes"], 1.0)
        self.assertLess(rows["adaptiveNoMenu"]["withinFiveMinutes"], 1.0)
        self.assertLess(rows["agentAwareNoMenu"]["refreshesPerDay"], rows["fixed5"]["refreshesPerDay"])


if __name__ == "__main__":
    unittest.main()

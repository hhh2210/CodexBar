#!/usr/bin/env python3
"""Offline evidence for adaptive refresh from local agent transcripts.

`export` reads Codex rollouts (and, with --include-claude, Claude Code transcripts) that already exist on this Mac and
writes a small JSONL file. Each record holds only a minute offset from the first record, an activity kind, or a Codex
quota observation (opaque stream index, window minutes, rising used percent). It never writes paths, working
directories, session or account identifiers, model or plan names, prompts, absolute dates, or the time zone. Nothing
is uploaded. The file still holds a daily activity rhythm, so it defaults to CodexBar's per-user directory,
~/.codexbar, outside any checkout. Keep it on this Mac, share only the `replay` table, and delete it when done.

`replay` compares refresh policies on an exported file: refreshes per day, and how long each quota increase seen in a
rollout waits for the next simulated refresh. The Adaptive rows are an unconstrained counterfactual. They assume no
menu opens, so they are upper bounds on delay; no Low Power Mode or thermal pressure, under which the app refreshes
every 30 minutes and may pause activity scanning; and perfect activity detection.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
from datetime import datetime
from pathlib import Path
import re
import sys
import tempfile
import time

SCHEMA = "codexbar-adaptive-offline-evidence/1"
TIMESTAMP = re.compile(r'"timestamp":\s*"([0-9T:.\-]+Z?)"')
POLICIES = ("fixed2", "fixed5", "fixed15", "fixed30", "adaptiveNoMenu", "agentAwareNoMenu")
SCAN_INTERVAL_MINUTES = 0.5
CODING_ACTIVITY_MINUTES = 5.0
CODING_ACTIVITY_DELAY_MINUTES = 5.0
LONG_IDLE_DELAY_MINUTES = 30.0
# Longest gap any compared policy leaves between refreshes, so increases near the end of a trace are still measured.
LAG_HORIZON_MINUTES = LONG_IDLE_DELAY_MINUTES + SCAN_INTERVAL_MINUTES
# Codex reports the same reset instant up to a few seconds apart across observations.
RESET_TOLERANCE_SECONDS = 300.0
REPLAY_ASSUMPTIONS = "no menu opens, no Low Power Mode or thermal pressure, perfect activity detection"


def parse_timestamp(text: str) -> float | None:
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def recent_files(root: Path, pattern: str, since: float) -> list[Path]:
    if not root.is_dir():
        return []
    return sorted(path for path in root.rglob(pattern) if path.is_file() and path.stat().st_mtime >= since)


def read_codex(sessions: Path, since: float) -> tuple[set[int], list[tuple[float, str, int, float, float | None]]]:
    activity: set[int] = set()
    quota: list[tuple[float, str, int, float, float | None]] = []  # stamp, limit key, window, used, reset
    limit_keys: dict[str, str] = {}
    for path in recent_files(sessions, "rollout-*.jsonl", since):
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                is_token_count = '"token_count"' in line
                if not is_token_count and '"task_started"' not in line:
                    continue
                match = TIMESTAMP.search(line, 0, 80)
                stamp = parse_timestamp(match.group(1)) if match else None
                if stamp is None or stamp < since:
                    continue
                activity.add(int(stamp // 60))
                if not is_token_count:
                    continue
                try:
                    limits = json.loads(line)["payload"].get("rate_limits") or {}
                except (ValueError, KeyError, AttributeError):
                    continue
                key = limit_keys.setdefault(str(limits.get("limit_id")), f"l{len(limit_keys)}")
                for window in ("primary", "secondary"):
                    entry = limits.get(window) or {}
                    used, minutes = entry.get("used_percent"), entry.get("window_minutes")
                    if used is None or minutes is None:
                        continue
                    reset = entry.get("resets_at")
                    quota.append((stamp, key, int(minutes), float(used),
                                  float(reset) if isinstance(reset, (int, float)) else None))
    return activity, quota


def read_claude(projects: Path, since: float) -> set[int]:
    activity: set[int] = set()
    for path in recent_files(projects, "*.jsonl", since):
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if '"assistant"' not in line:
                    continue
                match = TIMESTAMP.search(line)
                stamp = parse_timestamp(match.group(1)) if match else None
                if stamp is not None and stamp >= since:
                    activity.add(int(stamp // 60))
    return activity


def same_reset(latest: float | None, reset: float | None) -> bool:
    if latest is None or reset is None:
        return latest is None and reset is None
    return abs(reset - latest) <= RESET_TOLERANCE_SECONDS


def build_records(
    activity: dict[str, set[int]],
    quota: list[tuple[float, str, int, float, float | None]],
) -> list[dict]:
    minutes = [minute for bucket in activity.values() for minute in bucket] + [int(q[0] // 60) for q in quota]
    if not minutes:
        return []
    origin = min(minutes)
    records: list[dict] = []
    for kind, bucket in activity.items():
        records += [{"t": minute - origin, "kind": f"{kind}Activity"} for minute in sorted(bucket)]
    # Accounts can share a limit id but not a reset instant, and a reset starts a new window, so each
    # (limit, window, reset instant) is its own stream. An observation joins the stream whose latest reset is within
    # the tolerance. Only rising usage counts: concurrent sessions report slightly stale snapshots that would
    # otherwise flicker by one percent.
    latest_resets: dict[tuple[str, int], dict[str, float | None]] = {}
    peaks: dict[str, float] = {}
    stream_count = 0
    for stamp, key, window, used, reset in sorted(quota, key=lambda observation: observation[0]):
        streams = latest_resets.setdefault((key, window), {})
        stream = next((stream for stream, latest in streams.items() if same_reset(latest, reset)), None)
        if stream is None:
            stream, stream_count = f"s{stream_count}", stream_count + 1
        streams[stream] = reset
        if stream in peaks and used <= peaks[stream]:
            continue
        first = stream not in peaks
        peaks[stream] = used
        records.append({
            "t": int(stamp // 60) - origin,
            "kind": "quota",
            "stream": stream,
            "windowMinutes": window,
            "usedPercent": used,
            "first": first,
        })
    return sorted(records, key=lambda record: record["t"])


def default_evidence_path() -> Path:
    return Path.home() / ".codexbar" / "adaptive-evidence.jsonl"


def export(args: argparse.Namespace) -> int:
    since = time.time() - args.days * 86400
    codex_home = Path(args.codex_home or os.environ.get("CODEX_HOME") or Path.home() / ".codex")
    codex_activity, quota = read_codex(codex_home / "sessions", since)
    activity = {"codex": codex_activity}
    if args.include_claude:
        activity["claude"] = read_claude(Path.home() / ".claude" / "projects", since)
    records = build_records(activity, quota)
    if not records:
        print("no local agent activity found in the requested window", file=sys.stderr)
        return 1
    header = {
        "kind": "header",
        "schema": SCHEMA,
        "days": args.days,
        "bucketMinutes": 1,
        "sources": [kind for kind, bucket in activity.items() if bucket],
    }
    output = Path(args.output) if args.output else default_evidence_path()
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # The file holds a personal activity rhythm, so it is written owner-only (mkstemp) and then renamed into place.
    # The rename replaces whatever the output name held, so a symlink or hard link there is never written through.
    descriptor, staging = tempfile.mkstemp(prefix=".", suffix=f"-{output.name}", dir=output.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            for record in [header, *records]:
                handle.write(json.dumps(record, separators=(",", ":")) + "\n")
        os.replace(staging, output)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(staging)
        raise
    quota_records = sum(record["kind"] == "quota" for record in records)
    print(f"wrote {output}: {len(records) - quota_records} activity minutes, {quota_records} quota records")
    print("keep this file local, share only the replay table, and delete the file when done")
    return 0


def simulate(policy: str, end: float, activity: list[int]) -> list[float]:
    # Timer ticks only: like the app timer, each policy waits one delay before its first automatic refresh.
    if policy.startswith("fixed"):
        step = float(policy.removeprefix("fixed"))
        return [index * step for index in range(1, int(end // step) + 1)]
    aware = policy == "agentAwareNoMenu"
    last_activity: float | None = None
    pending = iter(activity)
    next_activity = next(pending, None)

    def delay(now: float) -> float:
        # AdaptiveRefreshPolicyCore without menu opens: longIdle, capped while coding activity is recent.
        # Rollouts do not record Low Power Mode or thermal pressure, under which the app would use its 30-minute
        # constrained delay.
        if aware and last_activity is not None and now - last_activity < CODING_ACTIVITY_MINUTES:
            return CODING_ACTIVITY_DELAY_MINUTES
        return LONG_IDLE_DELAY_MINUTES

    refreshes: list[float] = []
    scheduled = delay(0.0)
    clock = 0.0
    while clock <= end:
        clock += SCAN_INTERVAL_MINUTES
        observed = False
        while next_activity is not None and next_activity <= clock:
            last_activity, observed = float(next_activity), True
            next_activity = next(pending, None)
        if aware and observed:
            # noteCodingActivityObserved only ever pulls the next tick earlier.
            scheduled = min(scheduled, clock + delay(clock))
        if clock >= scheduled:
            refreshes.append(clock)
            scheduled = clock + delay(clock)
    return refreshes


def detection_lags(refreshes: list[float], changes: list[float]) -> list[float]:
    lags: list[float] = []
    index = 0
    for change in sorted(changes):
        while index < len(refreshes) and refreshes[index] < change:
            index += 1
        if index < len(refreshes):
            lags.append(refreshes[index] - change)
    return lags


def percentile(values: list[float], fraction: float) -> float:
    # Nearest rank, matching StalenessStats in AdaptiveReplayKit.
    rank = math.ceil(fraction * len(values))
    return values[max(0, min(len(values) - 1, rank - 1))]


def summarize(records: list[dict]) -> dict:
    body = [record for record in records if record.get("kind") != "header"]
    end = max((record["t"] for record in body), default=0)
    activity = sorted({record["t"] for record in body if record["kind"].endswith("Activity")})
    changes = [record["t"] for record in body if record["kind"] == "quota" and not record.get("first")]
    days = max(end / 1440, 1 / 24)
    rows = []
    for policy in POLICIES:
        refreshes = simulate(policy, end + LAG_HORIZON_MINUTES, activity)
        lags = sorted(detection_lags(refreshes, changes))
        row = {"policy": policy, "refreshesPerDay": round(sum(refresh <= end for refresh in refreshes) / days, 1)}
        if lags:
            row |= {
                "lagP50Minutes": percentile(lags, 0.5),
                "lagP95Minutes": percentile(lags, 0.95),
                "lagMaxMinutes": lags[-1],
                "withinFiveMinutes": round(sum(lag <= 5 for lag in lags) / len(lags), 3),
            }
        rows.append(row)
    return {
        "spanDays": round(days, 2),
        "activityMinutes": len(activity),
        "quotaStreams": len({record["stream"] for record in body if record["kind"] == "quota"}),
        "quotaIncreases": len(changes),
        "assumes": REPLAY_ASSUMPTIONS,
        "policies": rows,
    }


def replay(args: argparse.Namespace) -> int:
    lines = Path(args.trace or default_evidence_path()).read_text(encoding="utf-8").splitlines()
    summary = summarize([json.loads(line) for line in lines if line.strip()])
    if args.json:
        print(json.dumps(summary, indent=2))
        return 0
    print(f"span {summary['spanDays']} days, activity minutes {summary['activityMinutes']}, "
          f"quota streams {summary['quotaStreams']}, quota increases {summary['quotaIncreases']}")
    print(f"unconstrained counterfactual: assumes {summary['assumes']}")
    print(f"{'policy':<17} {'refresh/day':>11} {'lag p50':>8} {'lag p95':>8} {'lag max':>8} {'<=5min':>7}")
    for row in summary["policies"]:
        if "lagP50Minutes" in row:
            print(f"{row['policy']:<17} {row['refreshesPerDay']:>11.1f} {row['lagP50Minutes']:>8.1f} "
                  f"{row['lagP95Minutes']:>8.1f} {row['lagMaxMinutes']:>8.1f} {row['withinFiveMinutes']:>7.0%}")
        else:
            print(f"{row['policy']:<17} {row['refreshesPerDay']:>11.1f} {'-':>8} {'-':>8} {'-':>8} {'-':>7}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    export_parser = commands.add_parser("export", help="write a local offline evidence file")
    export_parser.add_argument("--days", type=int, default=7)
    export_parser.add_argument("--include-claude", action="store_true", help="add Claude Code activity minutes")
    export_parser.add_argument("--codex-home", help="defaults to $CODEX_HOME or ~/.codex")
    export_parser.add_argument("--output", help="defaults to ~/.codexbar/adaptive-evidence.jsonl")
    replay_parser = commands.add_parser("replay", help="compare refresh policies on an evidence file")
    replay_parser.add_argument("trace", nargs="?", help="defaults to the export location")
    replay_parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    return export(args) if args.command == "export" else replay(args)


if __name__ == "__main__":
    sys.exit(main())

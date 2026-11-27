"""Evaluate a native Windows GUI capture against an approved OD-07 record."""

import argparse
import json
import math
from datetime import datetime
from pathlib import Path

from preflight_native_debug_workloads import PROPOSAL, digest, load_json, require


def instant(value):
    parsed = datetime.fromisoformat(value)
    require(parsed.utcoffset() is not None, "Measurement timestamps require a UTC offset")
    return parsed


def elapsed(value):
    require(
        type(value) in (float, int) and math.isfinite(value) and value > 0,
        "Missing or invalid positive duration",
    )
    return value


def check_approval(path):
    proposed = load_json(PROPOSAL)
    approved = load_json(path)
    require(
        approved.get("approval_status") == "APPROVED"
        and approved.get("approval_reference")
        and approved.get("proposal_sha256") == digest(PROPOSAL),
        "The frozen OD-07 proposal needs a separate, recorded approval",
    )
    differences = {"approval_status", "approval_reference", "proposal_sha256", "approved_at"}
    require(
        {key: value for key, value in approved.items() if key not in differences}
        == {key: value for key, value in proposed.items() if key not in differences},
        "The approved record changed the frozen workload or limits",
    )
    return approved, instant(approved["approved_at"])


def check_interaction(run, reference):
    transcript = run["interaction_transcript"]
    ready = {
        "action": "window_ready",
        "frame": reference["initial_viewport"]["frame"],
        "painted_lanes": len(reference["selected_signals"]),
    }
    require(transcript and transcript[0] == ready, "Missing initial visible-window interaction")
    checked_frames = {viewport["frame"] for viewport in reference["viewports"]}
    require(
        any(event.get("action") == "move_cursor" and event.get("frame") in checked_frames
            for event in transcript),
        "Missing cursor movement to a checked frame",
    )
    if not reference["source_backed_witness"]:
        return
    require(
        {"action": "source_cross_probe", "assertion": reference["assertion"]} in transcript,
        "Missing source cross-probe transcript for the verified assertion",
    )
    require(
        any(event.get("action") == "restore_session" and event.get("state_matched") is True
            for event in transcript),
        "Missing matched session restoration in the interaction transcript",
    )


def compare(approved, approved_at, limits_sha, preflight, capture):
    require(
        capture["schema"] == "Q3AFORMAL_PHASE1_NATIVE_GUI_CAPTURE_1"
        and capture["method"] == "VISIBLE_WIN32_WORKSPACE"
        and capture["limits_sha256"] == limits_sha,
        "Capture must identify the visible Windows workspace and the exact approved limits",
    )
    require(
        preflight["schema"] == "Q3AFORMAL_NATIVE_DEBUG_WORKLOAD_PREFLIGHT_2"
        and preflight["status"] == "FUNCTIONAL_INPUTS_REVALIDATED"
        and preflight["proposal_sha256"] == approved["proposal_sha256"]
        and all(capture[key] == preflight[key] for key in ("archive_sha256", "executable_sha256")),
        "Capture, package, and workload preflight identities differ",
    )
    host = capture["host"]
    require(
        all(host[key] == value for key, value in approved["host"].items())
        and bool(host["windows_build"]) and bool(host["gui_runtime"]),
        "Capture does not identify the approved host and GUI runtime",
    )
    interval = elapsed(capture["working_set_sample_interval_ms"])
    expected = {entry["workload"]: entry for entry in preflight["checks"]}
    workload_ids = {entry["id"] for entry in approved["workloads"]}
    require(set(expected) == workload_ids and len(preflight["checks"]) == len(expected), "Preflight workload roster differs")
    repetitions = approved["repetitions_per_workload"]
    required_runs = {(key, repeat) for key in workload_ids for repeat in range(1, repetitions + 1)}
    seen = set()
    evaluated = []
    periods = []
    for run in capture["runs"]:
        identity = (run["workload"], run["repeat"])
        require(type(run["repeat"]) is int and identity in required_runs and identity not in seen,
                f"Unexpected or duplicate run {identity}")
        seen.add(identity)
        reference = expected[run["workload"]]
        started, ended = instant(run["started_at"]), instant(run["completed_at"])
        require(approved_at < started < ended, f"Capture predates approval or has an invalid interval: {identity}")
        periods.append((started, ended))
        require(
            run["trace_sha256"] == reference["trace_sha256"]
            and run["visible_signals"] == reference["selected_signals"],
            f"Trace or visible signal selection differs: {identity}",
        )
        fields = ("frame", "first", "last", "values", "access")
        require(
            [tuple(view[key] for key in fields) for view in (run["initial_viewport"], *run["viewports"])]
            == [tuple(view[key] for key in fields) for view in (reference["initial_viewport"], *reference["viewports"])],
            f"Rendered viewport evidence differs from the independent value oracle: {identity}",
        )
        durations = {"cold": [], "adjacent_cached": []}
        for view in run["viewports"]:
            kind = view["access"]
            elapsed_ms = elapsed(view["elapsed_ms"])
            durations[kind].append(elapsed_ms)
        require(all(durations.values()), f"Missing cold or cached viewport timing: {identity}")
        readings = run["process_tree_working_set_bytes"]
        require(
            bool(readings) and all(type(sample) is int and sample > 0 for sample in readings),
            f"Missing positive process-tree working set measurements: {identity}",
        )
        check_interaction(run, reference)
        observed = {
            "initial_visible_ms": elapsed(run["initial_visible_ms"]),
            "cold_indexed_viewport_ms": max(durations["cold"]),
            "adjacent_cached_viewport_ms": max(durations["adjacent_cached"]),
            "peak_gui_working_set_bytes": max(readings),
        }
        misses = [key for key, value in observed.items() if value > approved["limits"][key]]
        evaluated.append({
            "workload": identity[0], "repeat": identity[1], "measurements": observed,
            "exceeded_limits": misses, "within_limits": not misses,
        })
    require(seen == required_runs, "One or more required post-approval repetitions are missing")
    periods.sort()
    require(all(current[1] <= following[0] for current, following in zip(periods, periods[1:])),
            "Isolated GUI repetitions must not overlap")
    return {
        "schema": "Q3AFORMAL_PHASE1_NATIVE_GUI_LIMIT_VERDICT_1",
        "status": "APPROVED_LIMITS_MET" if all(run["within_limits"] for run in evaluated) else "LIMITS_EXCEEDED",
        "limits_sha256": limits_sha,
        "approved_at": approved_at.isoformat(),
        "archive_sha256": preflight["archive_sha256"],
        "executable_sha256": preflight["executable_sha256"],
        "working_set_sample_interval_ms": interval,
        "runs": evaluated,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("limits", "preflight", "capture", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    args = parser.parse_args()
    try:
        approved, approved_at = check_approval(args.limits)
        verdict = compare(approved, approved_at, digest(args.limits), load_json(args.preflight), load_json(args.capture))
        verdict["capture_sha256"] = digest(args.capture)
        verdict["preflight_sha256"] = digest(args.preflight)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(verdict, stream, indent=2)
            stream.write("\n")
    except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError) as error:
        parser.exit(1, f"Native GUI limit evaluation failed: {error}\n")
    print(verdict["status"])
    return 0 if verdict["status"] == "APPROVED_LIMITS_MET" else 1


if __name__ == "__main__":
    raise SystemExit(main())


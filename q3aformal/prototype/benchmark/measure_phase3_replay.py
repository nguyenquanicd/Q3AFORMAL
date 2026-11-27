"""Collect exploratory replay measurements with no performance verdict."""

import argparse
import json
import os
import platform
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from preflight_native_debug_workloads import digest
from run_phase1_debug_capture import tree_working_set, windows_api


def measure(exe, args, directory, repeats, diagnostics):
    kernel = windows_api()
    env = {**os.environ, "Q3A_REPLAY_TIMING": "1" if diagnostics else "0"}
    records = []
    directory.mkdir()
    for repeat in range(1, repeats + 1):
        stdout_path = directory / f"{repeat}.stdout"
        stderr_path = directory / f"{repeat}.stderr"
        samples = []
        with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
            start = time.perf_counter_ns()
            process = subprocess.Popen([str(exe), *map(str, args)], env=env, stdout=stdout, stderr=stderr)
            try:
                while process.poll() is None:
                    sample = tree_working_set(kernel, process.pid)
                    if sample:
                        samples.append(sample)
                    if time.perf_counter_ns() - start > 120_000_000_000:
                        raise TimeoutError(f"Replay watchdog expired for repetition {repeat}")
                    time.sleep(0.005)
                elapsed = time.perf_counter_ns() - start
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()
        if process.returncode != 0:
            raise ValueError(f"Replay exited with {process.returncode}: {stderr_path}")
        timings = {}
        for line in stderr_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("Q3A_REPLAY_TIMING "):
                _, stage, ns = line.split()
                if stage in timings:
                    raise ValueError(f"Duplicate replay stage: {stage}")
                timings[stage] = int(ns)
        records.append({
            "repeat": repeat, "elapsed_ns": elapsed,
            "peak_sampled_tree_working_set_bytes": max(samples, default=None),
            "working_set_samples": len(samples), "stages_ns": timings,
            "stdout_sha256": digest(stdout_path), "stderr_sha256": digest(stderr_path),
        })
    if len({row["stdout_sha256"] for row in records}) != 1:
        raise ValueError(f"Repetition output differed: {directory}")
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("executable", "bundle", "project", "evidence", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--diagnostics", action="store_true")
    parser.add_argument("--steps", type=int, default=2)
    args = parser.parse_args()
    if not 2 <= args.steps <= 128:
        parser.error("--steps must be in [2, 128] for the nested first-match fixture")
    args.output.mkdir()
    exe = args.executable.resolve()
    manifest = args.bundle / "manifest.json"
    bundle = json.loads(manifest.read_text(encoding="utf-8"))
    jobs = [
        ("bmc", ["--verify-bundle", args.bundle, "--require-source-model"],
         {item["path"]: item["sha256"] for item in bundle["artifacts"]}),
        ("four-state", ["dev-verify-four-state", args.project, "--property", "c_nested",
                        "--evidence-dir", args.evidence, "--steps", str(args.steps)],
         {file.name: digest(file) for file in (args.project, args.project.with_suffix(".sv"),
                                             args.evidence / "cover.q3awitness")}),
    ]
    result = {"classification": "EXPLORATORY_NO_ACCEPTANCE_VERDICT",
              "captured_at": datetime.now(timezone.utc).isoformat(), "windows": platform.version(),
              "architecture": platform.machine(), "executable_sha256": digest(exe),
              "bundle_manifest_sha256": digest(manifest), "requested_interval_ms": 5,
              "cpu": platform.processor(), "four_state_steps": args.steps, "workloads": {}}
    for name, command, identities in jobs:
        directory = args.output / name
        runs = measure(exe, command, directory, 3, args.diagnostics)
        text = (directory / "1.stdout").read_text(encoding="utf-8")
        if name == "bmc":
            expected = {"Q3A_BUNDLE_SOURCE_MODEL VERIFIED",
                        "Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=321 candidate_frame=320",
                        "Q3A_BUNDLE_BMC_WITNESS_QUERY VERIFIED", "Q3A_BUNDLE_STATUS REVALIDATED"}
            if not expected.issubset(text.splitlines()):
                raise ValueError("The source, query or terminal witness did not revalidate")
        else:
            replay = json.loads(text)
            if not (replay["status"] == "COVERED" and replay["witness_revalidated"]
                    and replay["source_replayed"] and len(replay["trace"]) == args.steps + 1
                    and (replay["attempt_sample"], replay["match_sample"]) == (0, 2)
                    and replay["witness_sha256"] == identities["cover.q3awitness"]):
                raise ValueError("Unexpected four-state match or witness identity")
        expected_stages = {"artifact_integrity", "source_model", "witness_decode",
                           "witness_consistency", "rtl_and_property", "query_regeneration"} if name == "bmc" else {
                               "source_model", "query_regeneration", "witness_decode",
                               "rtl_evaluation", "property_check", "witness_digest"}
        if name == "bmc" and any(item["role"] == "vcd_export" for item in bundle["artifacts"]):
            expected_stages.add("waveform_validation")
        if args.diagnostics and any(set(run["stages_ns"]) != expected_stages
                                    or any(ns < 0 for ns in run["stages_ns"].values())
                                    or sum(run["stages_ns"].values()) > run["elapsed_ns"] for run in runs):
            raise ValueError(f"Incomplete timing diagnostics: {name}")
        if not args.diagnostics and any(run["stages_ns"] for run in runs):
            raise ValueError("Replay emitted timing diagnostics without opt-in")
        result["workloads"][name] = {"input_sha256": identities, "runs": runs}
    with (args.output / "qualification.json").open("x", encoding="utf-8") as file:
        json.dump(result, file, indent=2)
        file.write("\n")


if __name__ == "__main__":
    main()

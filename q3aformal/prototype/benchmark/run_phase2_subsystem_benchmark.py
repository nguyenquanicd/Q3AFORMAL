"""Capture and audit the approved Phase 2 Windows subsystem workloads."""

import argparse
import json
import math
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

from preflight_native_debug_workloads import ROOT, digest, load_json, require
from run_phase1_debug_capture import host_profile, tree_working_set, windows_api, write_json

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures/phase2"
WORKLOADS = HERE / "phase2-subsystem-workloads.json"
PROPOSAL = HERE / "phase2-subsystem-limits.proposed.json"
STAGES = tuple(f"stage{i}" for i in range(4))


def instant(value):
    parsed = datetime.fromisoformat(value)
    require(parsed.utcoffset() is not None, "Benchmark timestamps require a timezone")
    return parsed


def approval(path):
    approved = load_json(path)
    proposal = load_json(PROPOSAL)
    fields = {"approval_status", "approval_reference", "approved_at", "proposal_sha256"}
    require(approved.get("approval_status") == "APPROVED"
            and bool(approved.get("approval_reference"))
            and approved.get("proposal_sha256") == digest(PROPOSAL)
            and {key: value for key, value in approved.items() if key not in fields}
            == {key: value for key, value in proposal.items() if key not in fields},
            "Phase 2 measurement requires approval of the exact frozen proposal")
    require(approved["workloads_sha256"] == digest(WORKLOADS), "Approved workload bytes differ")
    return approved, instant(approved["approved_at"])


def validate_inputs(workloads, preflight, exe):
    expected = workloads["fixture_sha256"]
    require(len(expected) == 7 and all(Path(name).name == name for name in expected),
            "Invalid Phase 2 fixture roster")
    require({name: digest(FIXTURES / name) for name in expected} == expected,
            "Frozen Phase 2 fixture bytes differ")
    require(preflight["status"] == "FUNCTIONAL_PREFLIGHT_PASSED"
            and preflight["workload_sha256"] == expected
            and preflight["executable_sha256"] == digest(exe)
            and preflight["composition_obligations"] == 9
            and preflight["equivalence_scope"] == "MATCHED_INITIAL_STATES",
            "Functional preflight must use these workloads and this executable")


def run_process(exe, arguments, folder, sampler, timeout_ms, interval_ms):
    """Measure only the target process tree, leaving both raw streams on disk."""
    stdout, stderr = folder / "measured.stdout", folder / "measured.stderr"
    samples = []
    failure = None
    with stdout.open("xb") as out, stderr.open("xb") as err:
        started_at = datetime.now(timezone.utc)
        started = time.perf_counter()
        process = subprocess.Popen([str(exe), *arguments], cwd=ROOT, stdout=out, stderr=err,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            while process.poll() is None:
                elapsed = (time.perf_counter() - started) * 1000
                if elapsed >= timeout_ms:
                    failure = "WALL_LIMIT"
                    break
                sample = sampler(process.pid)
                if sample > 0:
                    samples.append({"offset_ms": elapsed, "working_set_bytes": sample})
                remaining = timeout_ms - (time.perf_counter() - started) * 1000
                if remaining <= 0:
                    continue
                try:
                    process.wait(timeout=min(interval_ms, remaining) / 1000)
                except subprocess.TimeoutExpired:
                    pass
        except OSError as error:
            failure = f"WORKING_SET_SAMPLER: {error}"
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
        elapsed = (time.perf_counter() - started) * 1000
        completed_at = datetime.now(timezone.utc)
    return {"started_at": started_at.isoformat(), "completed_at": completed_at.isoformat(),
            "wall_time_ms": elapsed, "exit_code": process.returncode, "capture_failure": failure,
            "samples": samples, "stdout_sha256": digest(stdout), "stderr_sha256": digest(stderr)}


def bundle_identity(stdout, property_name):
    require("Q3A_BUNDLE_STATUS REVALIDATED" in stdout.splitlines()
            and "Q3A_BUNDLE_RESULT_STATUS PROVEN" in stdout.splitlines()
            and "Q3A_BUNDLE_SOURCE_MODEL VERIFIED" in stdout.splitlines(),
            f"Source proof did not revalidate: {property_name}")
    matches = re.findall(r"^Q3A_BUNDLE_MODEL_SHA256 ([0-9a-f]{64})$", stdout, re.MULTILINE)
    require(len(matches) == 1, f"Missing verified model: {property_name}")
    return matches[0]


def revalidation_commands(case, folder):
    project = str(FIXTURES / "p2_transport_subsystem.q3a")
    if case == "monolithic":
        return [("p_subsystem", ["--verify-bundle", str(folder / "bundle"), "--require-source-model"])]
    if case == "composed":
        return [("composition", ["verify-composition", project, "--plan",
                                  str(FIXTURES / "p2_transport_subsystem.q3c"),
                                  "--evidence-dir", str(folder / "composition")])]
    if case == "equivalence":
        return [("equivalence", ["verify-equivalence", project, str(FIXTURES / "p2_transport_encoded.q3a"),
                                   "--plan", str(FIXTURES / "p2_transport_equivalence.q3e"),
                                   "--evidence-dir", str(folder / "equivalence")])]
    return [(f"p_{stage}", ["--verify-bundle", str(folder / "batch/attempt-1" / f"job-{stage}" / "bundle"),
                           "--require-source-model"]) for stage in STAGES]


def artifacts(case, folder):
    directory = {"monolithic": "bundle", "composed": "composition", "equivalence": "equivalence"}.get(case, "batch")
    root = folder / directory
    return {path.relative_to(folder).as_posix(): digest(path)
            for path in sorted(root.rglob("*")) if path.is_file()}


def arguments_match(recorded, expected):
    # A Windows junction can preserve a capture's paths after moving the workspace.
    if not isinstance(recorded, list) or len(recorded) != len(expected):
        return False
    for saved, current in zip(recorded, expected):
        if saved == current:
            continue
        if not isinstance(saved, str):
            return False
        left, right = Path(saved), Path(current)
        if not left.is_absolute() or not right.is_absolute():
            return False
        try:
            if left.resolve() != right.resolve():
                return False
        except (OSError, RuntimeError):
            return False
    return True


def check_result(case, job, folder, measured, verifiers, model, logs=None):
    logs = folder if logs is None else logs
    require(measured["status"] == job["expected_status"], f"{case}: unexpected formal status")
    expected = revalidation_commands(case, folder)
    require(len(verifiers) == len(expected), f"{case}: verifier count differs")
    for record, (name, args) in zip(verifiers, expected):
        stdout = logs / f"{name}.verified.stdout"
        stderr = logs / f"{name}.verified.stderr"
        require(record["obligation"] == name and arguments_match(record["arguments"], args) and record["exit_code"] == 0
                and record["stdout_sha256"] == digest(stdout) and record["stderr_sha256"] == digest(stderr),
                f"{case}: verifier identity or exit differs for {name}")
        if args[0] == "--verify-bundle":
            manifest = load_json(Path(args[1]) / "manifest.json")
            require(manifest["result"]["property"] == name and manifest["result"]["status"] == "PROVEN"
                    and bundle_identity(stdout.read_text(encoding="utf-8"), name) == model,
                    f"{case}: source bundle property or model differs")
        else:
            verified = load_json(stdout)
            require(verified["context_sha256"] == measured["context_sha256"], f"{case}: checked scope differs")
            if case == "composed":
                require(verified["status"] == "REVALIDATED" and verified["checked_obligations"] == 9
                        and verified["target"] == "p_subsystem" and verified["model_sha256"] == model,
                        "Composed proof differs from the frozen source target")
            else:
                require(verified["status"] == "CERTIFICATE_REVALIDATED"
                        and verified["scope"] == "MATCHED_INITIAL_STATES"
                        and verified["state_certificate_model_sha256"] == measured["state_certificate_model_sha256"]
                        and verified["certificate_model_sha256"] == measured["certificate_model_sha256"],
                        "Verified paired state and output proof identities differ")
    if case.endswith("-batch"):
        workers = 2 if case == "parallel-batch" else 1
        require(measured["workers"] == workers
                and measured["plan_sha256"] == digest(FIXTURES / "p2_transport_subsystem.q3b")
                and [item["id"] for item in measured["jobs"]] == list(STAGES)
                and all(item["result"]["status"] == "PROVEN" and item["reused"] is False
                        and item["result_directory"] == f"attempt-1/job-{item['id']}" for item in measured["jobs"]),
                f"{case}: batch order, plan, proof or worker count differs")


def verify_outputs(exe, case, folder, logs=None):
    logs = folder if logs is None else logs
    verifiers = []
    for name, args in revalidation_commands(case, folder):
        stdout = logs / f"{name}.verified.stdout"
        stderr = logs / f"{name}.verified.stderr"
        with stdout.open("xb") as out, stderr.open("xb") as err:
            try:
                code = subprocess.run([str(exe), *args], cwd=ROOT, stdout=out, stderr=err, timeout=120,
                                      creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).returncode
            except subprocess.TimeoutExpired:
                code = None
        verifiers.append({"obligation": name, "arguments": args, "exit_code": code,
                          "stdout_sha256": digest(stdout), "stderr_sha256": digest(stderr)})
    return verifiers


def arguments(job, folder):
    return [item.replace("{FIXTURES}", str(FIXTURES)).replace("{OUTPUT}", str(folder)) for item in job["arguments"]]


def evaluate(approved, approved_at, workloads, capture, root):
    cases = {row["id"]: row for row in workloads["workloads"]}
    require(set(cases) == set(approved["cases"]), "Approved Phase 2 case roster differs")
    required = {(key, repeat) for key in cases for repeat in range(1, approved["repetitions_per_workload"] + 1)}
    seen, checked = set(), []
    previous_end = approved_at
    for run in capture["runs"]:
        case, repeat = key = (run["workload"], run["repeat"])
        require(type(repeat) is int and key in required and key not in seen, f"Invalid subsystem repeat {key}")
        seen.add(key)
        started, completed = instant(run["started_at"]), instant(run["completed_at"])
        require(previous_end <= started and approved_at < started < completed, f"Invalid capture interval: {key}")
        previous_end = completed
        folder = root / case / f"repeat-{repeat}"
        require(arguments_match(run["arguments"], arguments(cases[case], folder))
                and run["stdout_sha256"] == digest(folder / "measured.stdout")
                and run["stderr_sha256"] == digest(folder / "measured.stderr"), f"Measured transcript differs: {key}")
        elapsed = run["wall_time_ms"]
        require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed > 0, f"Invalid wall time: {key}")
        latest = -1
        for sample in run["samples"]:
            offset, amount = sample["offset_ms"], sample["working_set_bytes"]
            require(type(offset) in (int, float) and math.isfinite(offset) and latest <= offset <= elapsed
                    and offset >= 0 and type(amount) is int and amount > 0, f"Invalid process sample: {key}")
            latest = offset
        peak = max((sample["working_set_bytes"] for sample in run["samples"]), default=0)
        misses = []
        if run["capture_failure"] or run["exit_code"] != 0:
            misses.append("capture")
        limit = approved["cases"][case]
        if elapsed > limit["wall_time_ms"]:
            misses.append("wall_time_ms")
        if peak == 0 or peak > limit["peak_working_set_bytes"]:
            misses.append("peak_working_set_bytes")
        try:
            require(run["artifact_sha256"] and run["artifact_sha256"] == artifacts(case, folder),
                    f"{case}: saved evidence files changed")
            check_result(case, cases[case], folder, load_json(folder / "measured.stdout"), run["verifiers"],
                         workloads["transport_model_sha256"])
        except (OSError, ValueError, KeyError, TypeError) as error:
            misses.append(f"source_evidence: {error}")
        checked.append({"workload": case, "repeat": repeat, "wall_time_ms": elapsed,
                        "peak_working_set_bytes": peak, "failed_checks": misses, "passed": not misses})
    require(seen == required, "Incomplete capture. Retain the raw rows and run a fresh capture.")
    return {"status": "APPROVED_LIMITS_MET" if all(row["passed"] for row in checked) else "ACCEPTANCE_FAILED",
            "evaluated": checked}


def audit_source_evidence(exe, workloads, verdict, root):
    # The saved verdict checks the original transcript. Reopen the proofs as well,
    # so regenerated evidence hashes cannot substitute for a live source check.
    jobs = {job["id"]: job for job in workloads["workloads"]}
    with TemporaryDirectory(prefix="q3a-phase2-audit-") as scratch:
        for run in verdict["evaluated"]:
            if not run["passed"]:
                continue
            case, repeat = run["workload"], run["repeat"]
            folder = root / case / f"repeat-{repeat}"
            logs = Path(scratch) / f"{case}-{repeat}"
            logs.mkdir()
            measured = load_json(folder / "measured.stdout")
            verifiers = verify_outputs(exe, case, folder, logs)
            check_result(case, jobs[case], folder, measured, verifiers,
                         workloads["transport_model_sha256"], logs)


def capture(args, approved, approved_at, workloads):
    require(os.name == "nt", "Phase 2 subsystem collection requires Windows")
    require(datetime.now(timezone.utc) > approved_at, "Benchmark approval is in the future")
    exe = args.executable.resolve()
    validate_inputs(workloads, load_json(args.preflight), exe)
    kernel = windows_api()
    host = host_profile(kernel, approved, args.installed_memory_label)
    host.pop("gui_runtime")
    host["runtime"] = "Q3AFormal Windows x64 command line"
    root = args.capture_dir.resolve()
    root.mkdir()
    record = {"schema": "Q3AFORMAL_PHASE2_SUBSYSTEM_CAPTURE_1", "host": host, "executable_sha256": digest(exe),
              "approval_sha256": digest(args.limits), "workloads_sha256": digest(WORKLOADS),
              "preflight_sha256": digest(args.preflight), "sample_interval_ms": approved["sample_interval_ms"], "runs": []}
    try:
        for job in workloads["workloads"]:
            case = job["id"]
            (root / case).mkdir()
            for repeat in range(1, approved["repetitions_per_workload"] + 1):
                folder = root / case / f"repeat-{repeat}"
                folder.mkdir()
                validate_inputs(workloads, load_json(args.preflight), exe)
                command = arguments(job, folder)
                result = run_process(exe, command, folder, lambda pid: tree_working_set(kernel, pid),
                                     approved["cases"][case]["wall_time_ms"], approved["sample_interval_ms"])
                result.update(workload=case, repeat=repeat, arguments=command, verifiers=[], artifact_sha256={})
                record["runs"].append(result)
                if result["exit_code"] == 0 and not result["capture_failure"]:
                    result["verifiers"] = verify_outputs(exe, case, folder)
                    result["artifact_sha256"] = artifacts(case, folder)
                validate_inputs(workloads, load_json(args.preflight), exe)
    finally:
        write_json(root / "capture.json", record)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("capture", "audit"))
    for name in ("limits", "preflight", "executable", "capture-dir"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--installed-memory-label")
    args = parser.parse_args()
    try:
        approved, approved_at = approval(args.limits)
        workloads = load_json(WORKLOADS)
        preflight = load_json(args.preflight)
        validate_inputs(workloads, preflight, args.executable)
        root = args.capture_dir.resolve()
        record = capture(args, approved, approved_at, workloads) if args.mode == "capture" else load_json(root / "capture.json")
        require(record["schema"] == "Q3AFORMAL_PHASE2_SUBSYSTEM_CAPTURE_1"
                and record["approval_sha256"] == digest(args.limits)
                and record["workloads_sha256"] == digest(WORKLOADS)
                and record["executable_sha256"] == digest(args.executable)
                and record["preflight_sha256"] == digest(args.preflight)
                and record["sample_interval_ms"] == approved["sample_interval_ms"]
                and all(record["host"][key] == value for key, value in approved["host"].items()),
                "Capture host or executable identity differs")
        verdict = evaluate(approved, approved_at, workloads, record, root)
        verdict.update(capture_sha256=digest(root / "capture.json"), limits_sha256=digest(args.limits),
                       executable_sha256=record["executable_sha256"])
        if args.mode == "capture":
            write_json(root / "verdict.json", verdict)
        else:
            require(load_json(root / "verdict.json") == verdict, "Saved verdict differs from the recomputed result")
            audit_source_evidence(args.executable.resolve(), workloads, verdict, root)
            validate_inputs(workloads, preflight, args.executable)
        print(verdict["status"])
        return 0 if verdict["status"] == "APPROVED_LIMITS_MET" else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f"Phase 2 benchmark rejected: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())

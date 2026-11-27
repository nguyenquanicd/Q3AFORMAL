"""Compare the 300-transition cover on two builds under explicit private-memory limits."""

import argparse
import ctypes
import json
import os
import subprocess
import time
from pathlib import Path

from preflight_native_debug_workloads import ROOT, digest
from run_phase1_debug_capture import MemoryCounters, windows_api


class ExtendedCounters(MemoryCounters):
    _fields_ = [("private_bytes", ctypes.c_size_t)]


def run_cover(kernel, exe, cap, output, bundle=False):
    command = [str(exe), "--bmc", "prototype/bmc-cover-implication.q3a", "--property",
               "c_converging_repeat_paths", "--frames", "300"]
    if bundle:
        command += ["--bundle-dir", str(output.with_suffix(".bundle"))]
    peak_private = 0
    peak_working_set = 0
    samples = 0
    env = {**os.environ, "Q3A_MEMORY_LIMIT_MIB": str(cap)}
    start = time.perf_counter()
    with output.with_suffix(".stdout").open("xb") as stdout, output.with_suffix(".stderr").open("xb") as stderr:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stdout, stderr=stderr)
        handle = kernel.OpenProcess(0x0410, False, process.pid)
        try:
            while process.poll() is None:
                counters = ExtendedCounters()
                counters.size = ctypes.sizeof(counters)
                base = ctypes.cast(ctypes.byref(counters), ctypes.POINTER(MemoryCounters))
                if handle and kernel.K32GetProcessMemoryInfo(handle, base, counters.size):
                    peak_private = max(peak_private, counters.private_bytes)
                    peak_working_set = max(peak_working_set, counters.peak_working_set)
                    samples += 1
                if time.perf_counter() - start > 120:
                    raise TimeoutError(f"Watch storage measurement expired: {output.name}")
                time.sleep(0.01)
        finally:
            if handle:
                kernel.CloseHandle(handle)
            if process.poll() is None:
                process.kill()
            process.wait()
    lines = output.with_suffix(".stdout").read_text(encoding="utf-8").splitlines()
    return {
        "memory_limit_mib": cap, "exit_code": process.returncode,
        "elapsed_ms": (time.perf_counter() - start) * 1000,
        "working_set_peak_bytes": peak_working_set, "private_commit_sampled_peak_bytes": peak_private,
        "memory_samples": samples, "status": next((s for s in lines if s.startswith("Q3A_BMC_STATUS ")), None),
        "solver_statistics": next((s for s in lines if s.startswith("Q3A_BMC_STATS ")), None),
        "witness_validated": "Q3A_BMC_REPLAY VALIDATED" in lines,
        "stdout_sha256": digest(output.with_suffix(".stdout")),
        "stderr_sha256": digest(output.with_suffix(".stderr")),
    }


def evidence_hashes(directory):
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    hashes = {}
    for entry in manifest["artifacts"]:
        filename = entry["path"]
        if filename.endswith((".cnf", ".q3atrace")) or entry["role"] == "canonical_tir":
            actual = digest(directory / filename)
            if actual != entry["sha256"]:
                raise ValueError(f"Bundle evidence identity mismatch: {filename}")
            hashes[filename] = actual
    if not any(path.endswith(".cnf") for path in hashes) or not any(path.endswith(".q3atrace") for path in hashes):
        raise ValueError("A cover archive must contain its formula and indexed witness")
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("previous", "candidate", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir()
    kernel = windows_api()
    comparison = {"classification": "EXPLORATORY_PRIVATE_MEMORY_COMPARISON", "cases": {}}
    for key, executable in (("previous", args.previous), ("candidate", args.candidate)):
        exe = executable.resolve()
        runs = [run_cover(kernel, exe, cap, root / f"{key}-{cap}") for cap in (192, 256)]
        prefix = root / f"{key}-archive"
        archive = run_cover(kernel, exe, 384, prefix, bundle=True)
        hashes = evidence_hashes(prefix.with_suffix(".bundle")) if archive["witness_validated"] else {}
        comparison["cases"][key] = {"executable_sha256": digest(exe), "runs": runs,
                                     "archive_run": archive, "artifact_sha256": hashes}
    old = comparison["cases"]["previous"]
    new = comparison["cases"]["candidate"]
    comparison["identical_formula_and_witness"] = bool(
        old["artifact_sha256"] and old["artifact_sha256"] == new["artifact_sha256"])
    with (root / "comparison.json").open("x", encoding="utf-8") as out:
        json.dump(comparison, out, indent=2)
        out.write("\n")
    print(json.dumps(comparison, indent=2))


if __name__ == "__main__":
    main()

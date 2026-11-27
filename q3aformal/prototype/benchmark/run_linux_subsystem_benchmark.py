"""Compare Linux process-tree resident memory and run time with the frozen Phase 2 limits."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

from run_phase2_subsystem_benchmark import (
    FIXTURES, ROOT, WORKLOADS, approval, arguments, artifacts, check_result, digest,
    load_json, require, verify_outputs,
)

PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")


def session_rss(session):
    pages = 0
    for directory in Path("/proc").iterdir():
        if not directory.name.isdecimal():
            continue
        try:
            # /proc/PID/stat begins with PID and a parenthesized command name.
            fields = (directory / "stat").read_text().rsplit(")", 1)[1].split()
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        if int(fields[3]) == session:
            pages += int(fields[21])
    return pages * PAGE_SIZE


def measure(exe, args, folder, timeout_ms, interval_ms):
    report = folder / "peak-kib.txt"
    command = ["/usr/bin/time", "-f", "%M", "-o", str(report), str(exe), *args]
    with (folder / "measured.stdout").open("xb") as out, (folder / "measured.stderr").open("xb") as err:
        started = time.perf_counter()
        process = subprocess.Popen(command, cwd=ROOT, stdout=out, stderr=err, start_new_session=True)
        peak = 0
        try:
            while process.poll() is None:
                peak = max(peak, session_rss(process.pid))
                remaining = timeout_ms / 1000 - (time.perf_counter() - started)
                if remaining <= 0:
                    raise TimeoutError(f"Benchmark exceeded {timeout_ms} ms")
                try:
                    process.wait(timeout=min(interval_ms / 1000, remaining))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    elapsed = (time.perf_counter() - started) * 1000
    # GNU time supplies the per-process high-water mark for short-lived runs.
    return process.returncode, elapsed, max(peak, int(report.read_text().strip()) * 1024)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("output", type=Path)
    options = parser.parse_args()
    require(platform.system() == "Linux" and platform.machine() == "x86_64"
            and "microsoft" not in platform.release().lower() and not os.environ.get("WSL_INTEROP"),
            "A Linux x86-64 host outside WSL is required")
    exe = options.executable.resolve(strict=True)
    output = options.output.resolve()
    output.mkdir(parents=True)
    limits, accepted_at = approval(WORKLOADS.with_name("phase2-subsystem-limits.approved.json"))
    require(datetime.now(timezone.utc) > accepted_at, "Benchmark host clock predates approval")
    suite = load_json(WORKLOADS)
    require({name: digest(FIXTURES / name) for name in suite["fixture_sha256"]} == suite["fixture_sha256"],
            "Frozen Phase 2 fixture bytes differ")
    jobs = suite["workloads"]
    require({job["id"] for job in jobs} == set(limits["cases"]), "Unexpected workload roster")

    rows = []
    for job in jobs:
        name = job["id"]
        limit = limits["cases"][name]
        for repeat in range(1, limits["repetitions_per_workload"] + 1):
            folder = output / name / f"repeat-{repeat}"
            folder.mkdir(parents=True)
            args = arguments(job, folder)
            code, elapsed, peak = measure(exe, args, folder, limit["wall_time_ms"], limits["sample_interval_ms"])
            require(code == 0, f"{name}: unexpected process exit {code}")
            verifiers = verify_outputs(exe, name, folder)
            check_result(name, job, folder, load_json(folder / "measured.stdout"), verifiers,
                         suite["transport_model_sha256"])
            rows.append({"workload": name, "repeat": repeat, "wall_time_ms": elapsed,
                         "peak_rss_bytes": peak, "wall_limit_ms": limit["wall_time_ms"],
                         "rss_limit_bytes": limit["peak_working_set_bytes"],
                         "passed": 0 < elapsed <= limit["wall_time_ms"] and
                                   0 < peak <= limit["peak_working_set_bytes"],
                         "verification_checks": len(verifiers), "artifact_sha256": artifacts(name, folder)})
    passed = all(row["passed"] for row in rows)
    verdict = {"status": "PASSED" if passed else "FAILED", "platform": platform.platform(),
               "cpu": next(row.split(":", 1)[1].strip() for row in Path("/proc/cpuinfo").read_text().splitlines()
                           if row.startswith("model name")),
               "mem_total": Path("/proc/meminfo").read_text().splitlines()[0],
               "commit": os.environ.get("GITHUB_SHA"), "executable_sha256": digest(exe),
               "workloads_sha256": digest(WORKLOADS),
               "metric": "Maximum sampled process-session RSS with a GNU time per-process high-water floor",
               "runs": rows}
    (output / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
    for row in rows:
        print(row["workload"], row["repeat"], f'{row["wall_time_ms"]:.1f} ms',
              f'{row["peak_rss_bytes"] / 2**20:.1f} MiB')
    require(passed, "Linux benchmark exceeded a resource limit")


if __name__ == "__main__":
    main()

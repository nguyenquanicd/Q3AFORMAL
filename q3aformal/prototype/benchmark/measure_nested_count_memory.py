
"""Compare native Windows high-water memory on the same nested count model."""

import argparse
import ctypes
import json
import os
import platform
import statistics
import subprocess
import time
from ctypes import wintypes
from pathlib import Path
from tempfile import TemporaryDirectory

from preflight_native_debug_workloads import digest, require


class ProcessMemoryCounters(ctypes.Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("page_faults", wintypes.DWORD),
        ("peak_working_set", ctypes.c_size_t),
        ("working_set", ctypes.c_size_t),
        ("peak_paged_pool", ctypes.c_size_t),
        ("paged_pool", ctypes.c_size_t),
        ("peak_nonpaged_pool", ctypes.c_size_t),
        ("nonpaged_pool", ctypes.c_size_t),
        ("pagefile_usage", ctypes.c_size_t),
        ("peak_pagefile_usage", ctypes.c_size_t),
    ]


def peak_counter():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    get_memory = kernel.K32GetProcessMemoryInfo
    get_memory.argtypes = [
        wintypes.HANDLE, ctypes.POINTER(ProcessMemoryCounters), wintypes.DWORD
    ]
    get_memory.restype = wintypes.BOOL
    return get_memory


def measure(exe, manifest, folder, get_memory):
    model = folder / "model.json"
    with model.open("wb") as out:
        started = time.perf_counter()
        with subprocess.Popen(
            [str(exe), "--lower-project", str(manifest)],
            stdout=out, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW,
        ) as process:
            try:
                _, diagnostics = process.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                raise
            elapsed = (time.perf_counter() - started) * 1_000
            require(process.returncode == 0, diagnostics.decode(errors="replace"))
            # CPython retains the Windows process handle through context exit.
            stats = ProcessMemoryCounters()
            stats.cb = ctypes.sizeof(stats)
            if not get_memory(int(process._handle), ctypes.byref(stats), stats.cb):
                raise ctypes.WinError(ctypes.get_last_error())
            require(stats.peak_working_set > 0 and stats.peak_pagefile_usage > 0,
                    "Windows did not return the process memory high-water counters")
    return {
        "wall_time_ms": round(elapsed, 3),
        "peak_working_set_bytes": stats.peak_working_set,
        "peak_process_commit_bytes": stats.peak_pagefile_usage,
        "serialized_model_bytes": model.stat().st_size,
        "serialized_model_sha256": digest(model),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expanded", type=Path, required=True)
    parser.add_argument("--compact", type=Path, required=True)
    parser.add_argument("--fixture-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    require(os.name == "nt" and platform.python_implementation() == "CPython",
            "Windows with CPython is required to read the retained child handle")
    require(not args.output.exists(), "Use an unused report path")
    fixture = args.fixture_dir.resolve(strict=True)
    manifest = fixture / "nested.q3a"
    source = fixture / "nested.sv"
    builds = {
        "expanded": args.expanded.resolve(strict=True),
        "compact": args.compact.resolve(strict=True),
    }
    fingerprints = {name: digest(exe) for name, exe in builds.items()}
    require(fingerprints["expanded"] != fingerprints["compact"], "Use two distinct builds")
    input_hashes = {"manifest_sha256": digest(manifest), "source_sha256": digest(source)}
    get_memory = peak_counter()
    samples = {name: [] for name in builds}
    with TemporaryDirectory(dir=args.output.resolve().parent, prefix="q3a-count-memory-") as temp:
        for repeat in range(3):
            order = list(builds) if repeat % 2 == 0 else list(reversed(builds))
            for name in order:
                samples[name].append(measure(builds[name], manifest, Path(temp), get_memory))
    for name, entries in samples.items():
        require(len({entry["serialized_model_sha256"] for entry in entries}) == 1,
                f"The {name} model changed during the runs")
        require(digest(builds[name]) == fingerprints[name], f"The {name} executable changed")
    require(digest(manifest) == input_hashes["manifest_sha256"]
            and digest(source) == input_hashes["source_sha256"], "The fixture changed")
    metrics = ("peak_working_set_bytes", "peak_process_commit_bytes", "wall_time_ms")
    medians = {
        name: {metric: statistics.median(row[metric] for row in entries) for metric in metrics}
        for name, entries in samples.items()
    }
    report = {
        "scope": "DEVELOPMENT_LOWERING_COMPARISON",
        "phase2_acceptance": "NOT_APPLICABLE",
        "counter_api": "K32GetProcessMemoryInfo on the retained child handle after exit",
        "command": "--lower-project nested.q3a",
        "host": {"architecture": platform.machine(), "windows_build": platform.version()},
        "inputs": input_hashes,
        "executable_sha256": fingerprints,
        "runs": samples,
        "median": medians,
    }
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
    print(json.dumps(medians, indent=2))


if __name__ == "__main__":
    main()


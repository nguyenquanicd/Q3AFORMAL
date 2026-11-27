"""Collect the approved OD-07 GUI benchmark on a Windows host."""

import argparse
import ctypes
import json
import os
import platform
import subprocess
import time
from ctypes import wintypes
from datetime import datetime, timezone
from pathlib import Path

from compare_phase1_debug_limits import check_approval, compare
from preflight_native_debug_workloads import INPUTS, ROOT, digest, load_json, repository_path, require


class ProcessEntry(ctypes.Structure):
    _fields_ = [
        ("size", wintypes.DWORD), ("usage", wintypes.DWORD), ("pid", wintypes.DWORD),
        ("heap_id", ctypes.c_size_t), ("module", wintypes.DWORD), ("threads", wintypes.DWORD),
        ("parent_pid", wintypes.DWORD), ("priority", wintypes.LONG), ("flags", wintypes.DWORD),
        ("name", wintypes.WCHAR * 260),
    ]


class MemoryCounters(ctypes.Structure):
    _fields_ = [
        ("size", wintypes.DWORD), ("page_faults", wintypes.DWORD),
        ("peak_working_set", ctypes.c_size_t), ("working_set", ctypes.c_size_t),
        ("quota_peak_paged", ctypes.c_size_t), ("quota_paged", ctypes.c_size_t),
        ("quota_peak_non_paged", ctypes.c_size_t), ("quota_non_paged", ctypes.c_size_t),
        ("pagefile", ctypes.c_size_t), ("peak_pagefile", ctypes.c_size_t),
    ]


def windows_api():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)

    def signature(name, returned, *parameters):
        function = getattr(kernel, name)
        function.restype, function.argtypes = returned, parameters

    handle, word = wintypes.HANDLE, wintypes.DWORD
    boolean = wintypes.BOOL
    signature("CreateToolhelp32Snapshot", handle, word, word)
    signature("Process32FirstW", boolean, handle, ctypes.POINTER(ProcessEntry))
    signature("Process32NextW", boolean, handle, ctypes.POINTER(ProcessEntry))
    signature("CloseHandle", boolean, handle)
    signature("OpenProcess", handle, word, boolean, word)
    signature("K32GetProcessMemoryInfo", boolean, handle, ctypes.POINTER(MemoryCounters), word)
    signature("GetPhysicallyInstalledSystemMemory", boolean, ctypes.POINTER(ctypes.c_ulonglong))
    return kernel


def tree_working_set(kernel, root_pid):
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)  # TH32CS_SNAPPROCESS
    if snapshot == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    children = {}
    try:
        row = ProcessEntry()
        row.size = ctypes.sizeof(row)
        more = kernel.Process32FirstW(snapshot, ctypes.byref(row))
        while more:
            children.setdefault(row.parent_pid, []).append(row.pid)
            more = kernel.Process32NextW(snapshot, ctypes.byref(row))
    finally:
        kernel.CloseHandle(snapshot)

    working_set = 0
    remaining = [root_pid]
    visited = set()
    while remaining:
        pid = remaining.pop()
        if pid in visited:
            continue
        visited.add(pid)
        remaining.extend(children.get(pid, ()))
        # PROCESS_QUERY_INFORMATION and PROCESS_VM_READ report the working set.
        handle = kernel.OpenProcess(0x0410, False, pid)
        if not handle:
            if ctypes.get_last_error() == 87:  # Process exited after the snapshot.
                continue
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            counters = MemoryCounters()
            counters.size = ctypes.sizeof(counters)
            if kernel.K32GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.size):
                working_set += counters.working_set
            elif ctypes.get_last_error() not in (6, 299):  # Handle or address space closed during sampling.
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            kernel.CloseHandle(handle)
    return working_set


def host_profile(kernel, approved, memory_override):
    import winreg

    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0") as cpu:
        cpu_model = winreg.QueryValueEx(cpu, "ProcessorNameString")[0].strip()
    amount = ctypes.c_ulonglong()
    if kernel.GetPhysicallyInstalledSystemMemory(ctypes.byref(amount)):
        require(amount.value > 0, "Windows did not report installed memory")
        label = f"{amount.value / 1048576:g} GB"
        provenance = "GetPhysicallyInstalledSystemMemory"
    else:
        require(bool(memory_override), "The installed memory API needs the owner-reported label")
        label = memory_override
        provenance = "owner-reported installed memory label"
    profile = {
        "architecture": platform.machine(), "cpu_model": cpu_model, "installed_memory_label": label,
        "installed_memory_provenance": provenance, "windows_build": platform.version(),
        "gui_runtime": "Q3AFormal native Win32 / GDI",
    }
    require(all(profile[key] == value for key, value in approved["host"].items()), "The approved benchmark host differs")
    return profile


def write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def collect_run(kernel, exe, role, path, plan, folder, repeat, interval, watchdog):
    prefix = folder / f"repeat-{repeat}"
    args = [
        str(exe), "--capture-native-workload", role, str(path), str(plan),
        str(prefix.with_suffix(".session.json")), "visible",
    ]
    start = datetime.now(timezone.utc)
    samples = []
    with (prefix.with_suffix(".stdout")).open("xb") as stdout, (prefix.with_suffix(".stderr")).open("xb") as stderr:
        process = subprocess.Popen(args, cwd=ROOT, stdout=stdout, stderr=stderr)
        try:
            deadline = time.monotonic() + watchdog
            while process.poll() is None:
                sample = tree_working_set(kernel, process.pid)
                if sample > 0:
                    samples.append(sample)
                if time.monotonic() >= deadline:
                    raise TimeoutError("Native GUI capture exceeded its collection watchdog")
                time.sleep(interval / 1000)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
    end = datetime.now(timezone.utc)
    require(process.returncode == 0 and bool(samples), f"Native capture failed or no memory sample was collected: {prefix}")
    result = json.loads(prefix.with_suffix(".stdout").read_text(encoding="utf-8"))
    require(result["mode"] == "VISIBLE_WIN32_WORKSPACE", "The product did not run a visible GUI capture")
    return result, start, end, samples


def collect(args):
    approved, approved_at = check_approval(args.limits)
    require(os.name == "nt", "The visible native benchmark needs Windows")
    require(datetime.now(timezone.utc) > approved_at, "The recorded approval is in the future")
    kernel = windows_api()
    host = host_profile(kernel, approved, args.installed_memory_label)
    package = args.archive.resolve()
    executable = args.executable.resolve()
    oracle = load_json(args.preflight)
    require(
        digest(package) == oracle["archive_sha256"]
        and digest(executable) == oracle["executable_sha256"]
        and approved["proposal_sha256"] == oracle["proposal_sha256"],
        "Approved input, candidate package, and oracle identities differ",
    )
    paths = {row["id"]: repository_path(row["trace"]) for row in load_json(INPUTS)["inputs"]}
    models = {workload["id"]: workload for workload in approved["workloads"]}
    output = args.output.resolve()
    output.mkdir()
    limits_sha = digest(args.limits)
    capture = {
        "schema": "Q3AFORMAL_PHASE1_NATIVE_GUI_CAPTURE_1", "method": "VISIBLE_WIN32_WORKSPACE",
        "limits_sha256": limits_sha, "archive_sha256": oracle["archive_sha256"],
        "executable_sha256": oracle["executable_sha256"], "host": host,
        "working_set_sample_interval_ms": args.interval_ms, "runs": [],
    }
    try:
        for workload in oracle["checks"]:
            workload_id = workload["workload"]
            path = paths[workload_id]
            require(digest(path) == workload["trace_sha256"], "Frozen trace changed before the capture")
            folder = output / workload_id
            folder.mkdir()
            plan = folder / "viewport-schedule.txt"
            span = workload["initial_viewport"]["last"] - workload["initial_viewport"]["first"] + 1
            steps = workload["viewports"]
            plan.write_text(
                "\n".join([
                    f"Q3A_WIN32_VIEWPORT_SCHEDULE_1 {span} {len(steps)}",
                    " ".join(workload["selected_signals"]),
                    *(f"{step['first']} {step['frame']}" for step in steps),
                ]) + "\n", encoding="ascii",
            )
            has_source = workload["source_backed_witness"]
            role, source = ("witness", path.parents[2]) if has_source else ("synthetic", path)
            for repeat in range(1, approved["repetitions_per_workload"] + 1):
                observed, start, end, samples = collect_run(
                    kernel, executable, role, source, plan, folder, repeat, args.interval_ms, args.watchdog_seconds,
                )
                require(observed["signal_count"] == models[workload_id]["signals"], "Native signal inventory differs")
                start_frame = observed["initial_viewport"]["frame"]
                interaction = [
                    {"action": "window_ready", "frame": start_frame, "painted_lanes": len(observed["initial_viewport"]["values"])},
                    *({"action": "move_cursor", "frame": view["frame"]} for view in observed["viewports"]),
                ]
                if has_source and observed["source_cross_probe"] and observed["session_restore"]:
                    require(observed["assertion"] == workload["assertion"], "Observed assertion differs from the frozen source oracle")
                    interaction.extend([
                        {"action": "source_cross_probe", "assertion": observed["assertion"]},
                        {"action": "restore_session", "state_matched": True},
                    ])
                capture["runs"].append({
                    "workload": workload_id, "repeat": repeat, "started_at": start.isoformat(), "completed_at": end.isoformat(),
                    "trace_sha256": workload["trace_sha256"], "visible_signals": workload["selected_signals"],
                    "initial_viewport": observed["initial_viewport"], "initial_visible_ms": observed["initial_viewport"]["elapsed_ms"],
                    "viewports": observed["viewports"], "process_tree_working_set_bytes": samples,
                    "interaction_transcript": interaction,
                })
                require(digest(path) == workload["trace_sha256"], "Frozen trace changed during the capture")
                require(digest(executable) == oracle["executable_sha256"], "Candidate executable changed during the capture")
    except Exception as error:
        capture["capture_failure"] = str(error)
        raise
    finally:
        write_json(output / "capture.json", capture)
    verdict = compare(approved, approved_at, limits_sha, oracle, capture)
    verdict["capture_sha256"] = digest(output / "capture.json")
    verdict["preflight_sha256"] = digest(args.preflight)
    write_json(output / "verdict.json", verdict)
    return verdict["status"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("limits", "archive", "executable", "preflight", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--installed-memory-label", help="Owner-reported label when Windows cannot query installed RAM")
    parser.add_argument("--interval-ms", default=10, type=int, choices=range(1, 101), metavar="1..100")
    parser.add_argument("--watchdog-seconds", default=120, type=int, choices=range(10, 601), metavar="10..600")
    args = parser.parse_args()
    try:
        status = collect(args)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        parser.exit(1, f"Native GUI capture failed: {error}\n")
    print(status)
    return 0 if status == "APPROVED_LIMITS_MET" else 1


if __name__ == "__main__":
    raise SystemExit(main())


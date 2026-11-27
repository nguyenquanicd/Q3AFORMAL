"""Revalidate the frozen Phase 1 GUI inputs without measuring GUI performance."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path, PureWindowsPath
from zipfile import BadZipFile, ZipFile

ROOT = Path(__file__).resolve().parents[2]
PROPOSAL = ROOT / "prototype/benchmark/phase1-debug-limits.proposed.json"
INPUTS = ROOT / "evidence/release/debug-benchmark-inputs-2026-11-26/readiness.json"


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def repository_path(path):
    result = (ROOT / Path(*PureWindowsPath(path).parts)).resolve()
    require(result.is_relative_to(ROOT), f"Input escapes the repository: {path}")
    return result


def run(executable, *argv):
    return subprocess.run(
        [str(executable), *map(str, argv)], cwd=ROOT, encoding="utf-8",
        capture_output=True, check=True, timeout=45,
    ).stdout


def checked_viewport(executable, trace, model, names, span, step, *, centered=False):
    frame = step["frame"]
    offset = max(0, frame - span // 2) if centered else frame - frame % span
    first = min(offset, model["frames"] - span)
    last = first + span - 1
    selection = [item for name in names for item in ("--signal", name)]
    window = json.loads(run(
        executable, "trace", "window", trace, "--first", first, "--last", last, *selection
    ))
    require(
        window["schema"] == "Q3A-TRACE-WINDOW-1"
        and (window["first"], window["last"], window["frame_count"]) == (first, last, model["frames"])
        and window["candidate_frame"] == model.get("first_witness_sample", 0),
        f"{model['id']}: unexpected viewport identity at frame {frame}",
    )
    lanes = window["signals"]
    require(
        [lane["name"] for lane in lanes] == names and len(lanes) == model["visible_lanes"],
        f"{model['id']}: viewport signal set or order differs",
    )
    actual = []
    for lane in lanes:
        changes = lane["changes"]
        require(changes and changes[0][0] == first, "Missing viewport checkpoint")
        actual.append(next(value for cycle, value in reversed(changes) if cycle <= frame))
    require(actual == step["values"], f"{model['id']}: value oracle mismatch at frame {frame}")
    return {"frame": frame, "first": first, "last": last, "values": actual}


def mark_expected_access(initial, viewports):
    cache = []
    for view in (initial, *viewports):
        key = (view["first"], view["last"])
        view["access"] = "cold"
        if key in cache:
            cache.remove(key)
            view["access"] = "adjacent_cached"
        cache.append(key)
        if len(cache) > 4:
            cache.pop(0)


def verify(args):
    proposal = load_json(PROPOSAL)
    readiness = load_json(INPUTS)
    require(digest(PROPOSAL) == readiness["proposal_sha256"], "Frozen proposal hash differs")
    executable = args.executable.resolve()
    archive = args.archive.resolve()
    exe_sha = digest(executable)
    with ZipFile(archive) as package:
        manifest = json.loads(package.read("package-manifest.json"))
        # The release package uses a list of file records in its manifest.
        payload = next(
            entry for entry in manifest["files"]
            if entry["path"] == "prototype/bin/q3aformal-sourcecheck.exe"
        )
        require(exe_sha == payload["sha256"], "Executable differs from the package")
        require(hashlib.sha256(package.read(payload["path"])).hexdigest() == exe_sha, "Package payload digest differs")
    workloads = {item["id"]: item for item in readiness["inputs"]}
    checks = []
    for model in proposal["workloads"]:
        recorded = workloads[model["id"]]
        trace = repository_path(recorded["trace"])
        metadata = load_json(repository_path(recorded["description"]))
        trace_sha = digest(trace)
        require(trace_sha == metadata["trace_sha256"], f"{model['id']}: frozen trace hash differs")
        if model["source_required"]:
            for source in model["input_files"]:
                require(digest(repository_path(source["path"])) == source["sha256"], "Frozen workload input differs")
            bundle = trace.parents[2]
            require(digest(bundle / "manifest.json") == metadata["bundle_manifest_sha256"], "Witness bundle digest differs")
            replay = run(executable, "--verify-bundle", bundle, "--require-source-model")
            require("Q3A_BUNDLE_SOURCE_MODEL VERIFIED" in replay.splitlines(), "Source model did not revalidate")
            require("Q3A_BUNDLE_STATUS REVALIDATED" in replay.splitlines(), "Witness did not revalidate")
            plan = load_json(repository_path(model["input_files"][-1]["path"]))
            reset_index = plan["signals"].index(plan["resetSignal"])
            require(
                all((step["values"][reset_index] == "0x1") is step["resetActive"] for step in plan["steps"]),
                "Frozen reset oracle disagrees with its signal values",
            )
            initial_step = next(step for step in plan["steps"] if step["frame"] == model["first_witness_sample"])
        else:
            require(digest(repository_path(model["generator"])) == model["generator_sha256"], "Synthetic generator digest differs")
            lanes = range(0, 400, 25)
            plan = {
                "signals": [f"lane_{lane:03}" for lane in lanes],
                "span": 64,
                "steps": [
                    {"frame": frame, "values": [hex(frame * 1024 + lane) for lane in lanes]}
                    for frame in (512, 513, 2560, 4608, 6656, 512, 513)
                ],
            }
            initial_step = {"frame": 0, "values": [hex(lane) for lane in lanes]}
        initial = checked_viewport(
            executable, trace, model, plan["signals"], plan["span"], initial_step, centered=True
        )
        viewports = [
            checked_viewport(executable, trace, model, plan["signals"], plan["span"], step)
            for step in plan["steps"]
        ]
        mark_expected_access(initial, viewports)
        row = {
            "workload": model["id"],
            "trace_sha256": trace_sha,
            "frames": model["frames"],
            "selected_signals": plan["signals"],
            "initial_viewport": initial,
            "source_backed_witness": model["source_required"],
            "viewports": viewports,
        }
        if model["source_required"]:
            row["assertion"] = plan["assertion"]
        checks.append(row)
    return {
        "schema": "Q3AFORMAL_NATIVE_DEBUG_WORKLOAD_PREFLIGHT_2",
        "status": "FUNCTIONAL_INPUTS_REVALIDATED",
        "proposal_sha256": readiness["proposal_sha256"],
        "archive_sha256": digest(archive),
        "executable_sha256": exe_sha,
        "scope": "Indexed value and witness checks through the candidate executable",
        "native_gui_timing": "NOT_MEASURED",
        "checks": checks,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(args)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, indent=2)
            stream.write("\n")
    except (OSError, ValueError, KeyError, StopIteration, BadZipFile, subprocess.SubprocessError) as error:
        parser.exit(1, f"Native debug input preflight failed: {error}\n")
    checks = result["checks"]
    values = sum(
        len(view["values"]) for check in checks for view in (check["initial_viewport"], *check["viewports"])
    )
    print(f"Revalidated {len(checks)} frozen trace workloads and {values} selected signal values.")


if __name__ == "__main__":
    main()


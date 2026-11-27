"""Stage the repository regression with the exact executables from a Windows package."""
import argparse
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
EXECUTABLES = {
    "prototype/bin/q3aformal-sourcecheck.exe",
    "prototype/bin/q3aformal-proofcheck.exe",
}
HISTORICAL_FIXTURES = (
    "known-pass", "known-fail", "checker-corpus",
    "release/run-control-timeout-2026-11-24.json",
    "release/run-control-cancelled-2026-11-24.json",
    "release/archive-run-options-baseline-2026-11-25/first-bundle",
    "release/pdr-certificate-only-configuration-baseline-2026-11-25/first-evidence",
    "benchmark/runs/phase0-final-gate-b-2026-11-24/B-02-counter4-fail-artifacts/bundle",
    "benchmark/runs/phase1-prove-cli-regression-2026-11-24/B-02-counter4-fail-artifacts/trace.vcd",
    "benchmark/preflight/B-01-counter4-2026-11-19",
    "benchmark/preflight/B-03-casez-2026-11-19",
    "conformance/rtl-015-concat-three-2026-11-19",
    "conformance/rtl-007-fill-literals-2026-11-19",
    "conformance/rtl-005-decimal-context-2026-11-19",
)


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def ignored(parent, names):
    excluded = {"__pycache__"}
    if Path(parent) == REPO / "prototype":
        excluded.add("bin")
    return excluded.intersection(names)


def stage_regression(archive, build_header, stage, record):
    stage = stage.resolve()
    record = record.resolve()
    if not (stage.is_relative_to(REPO / "evidence") and record.is_relative_to(REPO / "evidence")):
        raise ValueError("stage and record must be under the repository evidence directory")
    if stage.exists() or record.exists():
        raise ValueError("stage and record must use new paths")

    with zipfile.ZipFile(archive) as package:
        manifest = json.loads(package.read("package-manifest.json"))
        executable_records = [item for item in manifest["files"] if item["path"] in EXECUTABLES]
        if len(executable_records) != len(EXECUTABLES) or {item["path"] for item in executable_records} != EXECUTABLES:
            raise ValueError("the package does not contain exactly the required executable records")
        binaries = {}
        for item in executable_records:
            data = package.read(item["path"])
            if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
                raise ValueError(f"invalid package executable identity: {item['path']}")
            binaries[item["path"]] = data
    header = build_header.read_text(encoding="ascii")
    if f'kBuildId[] = "{manifest["source_build_id"]}"' not in header:
        raise ValueError("the build header does not identify the package build")

    stage.mkdir()
    for name in ("prototype", "scripts", "docs", "specs"):
        shutil.copytree(REPO / name, stage / name, ignore=ignored)
    for name in ("README.md", "USER_GUIDE.md"):
        shutil.copyfile(REPO / name, stage / name)
    for name in HISTORICAL_FIXTURES:
        source = REPO / "evidence" / name
        target = stage / "evidence" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target, ignore=ignored)
        else:
            shutil.copyfile(source, target)
    (stage / "prototype/bin").mkdir()
    for name, data in binaries.items():
        (stage / name).write_bytes(data)
    shutil.copyfile(build_header, stage / "prototype/bin/q3a_build_info.hpp")

    tests = sorted((REPO / "prototype/tests").glob("test_*.ps1"))
    roster = {}
    for test in tests:
        test_hash = digest(test)
        if digest(stage / test.relative_to(REPO)) != test_hash:
            raise ValueError(f"a regression suite changed during staging: {test.name}")
        roster[test.stem] = test_hash
    with record.open("x", encoding="utf-8", newline="\n") as output:
        json.dump({
            "archive_sha256": digest(archive),
            "build_id": manifest["source_build_id"],
            "executables": executable_records,
            "fixture_groups": list(HISTORICAL_FIXTURES),
            "suites": roster,
        }, output, indent=2)
        output.write("\n")
    print(f"Staged {len(roster)} regression suites with the package executable pair.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for field in ("archive", "build-header", "stage", "record"):
        parser.add_argument(f"--{field}", type=Path, required=True)
    args = parser.parse_args()
    stage_regression(args.archive, args.build_header, args.stage, args.record)


if __name__ == "__main__":
    main()

import argparse
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import sys

import run_phase2_subsystem_benchmark as bench

parser = argparse.ArgumentParser(description="Qualify the collector without recording acceptance measurements.")
for name in ("executable", "preflight", "output"):
    parser.add_argument(f"--{name}", type=Path, required=True)
parser.add_argument("--installed-memory-label", default="16 GB")
args = parser.parse_args()
root = args.output.resolve()
exe = args.executable.resolve()
preflight = args.preflight
root.mkdir()
# Equivalent absolute spellings preserve a recorded capture; changed options and files do not.
same_root = root / ".." / root.name
assert bench.arguments_match(["--output-dir", str(same_root)], ["--output-dir", str(root)])
assert bench.arguments_match([str(same_root / "new-proof-prefix")], [str(root / "new-proof-prefix")])
assert not bench.arguments_match(["--bundle-dir", str(root)], ["--output-dir", str(root)])
assert not bench.arguments_match(["--output-dir", str(root.parent)], ["--output-dir", str(root)])

workloads = bench.load_json(bench.WORKLOADS)
proposal = bench.load_json(bench.PROPOSAL)
bench.validate_inputs(workloads, bench.load_json(preflight), exe)
try:
    bench.approval(bench.PROPOSAL)
except ValueError as error:
    assert "requires approval" in str(error)
else:
    raise AssertionError("The approval gate accepted a proposal.")

kernel = bench.windows_api()
host = bench.host_profile(kernel, proposal, args.installed_memory_label)
sampler = lambda pid: bench.tree_working_set(kernel, pid)
for tag, delay, threshold, expected in (
    ("native-sampler", 0.18, 3000, None),
    ("native-watchdog", 1.0, 60, "WALL_LIMIT"),
):
    sample_path = root / tag
    sample_path.mkdir()
    sample = bench.run_process(Path(sys.executable),
        ["-c", f"import time; time.sleep({delay}); print('probe')"],
        sample_path, sampler, threshold, 10)
    assert sample["capture_failure"] == expected
    assert sample["samples"] and max(item["working_set_bytes"] for item in sample["samples"]) > 0
    if expected is None:
        assert sample["exit_code"] == 0
    else:
        assert sample["exit_code"] != 0
    bench.write_json(sample_path / "probe.json", sample)

for case in workloads["workloads"]:
    directory = root / "untimed" / case["id"] / "repeat-1"
    directory.mkdir(parents=True)
    command = bench.arguments(case, directory)
    stdout, stderr = directory / "measured.stdout", directory / "measured.stderr"
    with stdout.open("xb") as out, stderr.open("xb") as err:
        status = subprocess.run([str(exe), *command], cwd=bench.ROOT, stdout=out, stderr=err,
                                creationflags=subprocess.CREATE_NO_WINDOW, timeout=120).returncode
    assert status == 0, (case["id"], stderr.read_text(encoding="utf-8"))
    verifiers = bench.verify_outputs(exe, case["id"], directory)
    bench.check_result(case["id"], case, directory, bench.load_json(stdout), verifiers,
                       workloads["transport_model_sha256"])
    bench.write_json(directory / "functional-proof-identities.json",
                     {"measurement": "FUNCTIONAL_ONLY", "case": case["id"], "verifiers": verifiers,
                      "artifact_sha256": bench.artifacts(case["id"], directory)})

# Artificial numbers exercise threshold logic in memory only. They are never written as a run.
approved_at = datetime(2000, 1, 1, tzinfo=timezone.utc)
sim = deepcopy(proposal)
sim["repetitions_per_workload"] = 1
runs = []
for number, case in enumerate(workloads["workloads"], 1):
    directory = root / "untimed" / case["id"] / "repeat-1"
    identities = bench.load_json(directory / "functional-proof-identities.json")
    begin = approved_at + timedelta(seconds=number * 10)
    runs.append({"workload": case["id"], "repeat": 1, "started_at": begin.isoformat(),
                 "completed_at": (begin + timedelta(milliseconds=50)).isoformat(),
                 "arguments": bench.arguments(case, directory),
                 "wall_time_ms": 50.0, "exit_code": 0, "capture_failure": None,
                 "samples": [{"offset_ms": 20.0, "working_set_bytes": 1024}],
                 "stdout_sha256": bench.digest(directory / "measured.stdout"),
                 "stderr_sha256": bench.digest(directory / "measured.stderr"),
                 "verifiers": identities["verifiers"], "artifact_sha256": identities["artifact_sha256"]})

def verdict(rows):
    return bench.evaluate(sim, approved_at, workloads, {"runs": rows}, root / "untimed")

assert verdict(runs)["status"] == "APPROVED_LIMITS_MET"
for field, value in (("wall_time_ms", 30001.0), ("samples", [])):
    changed = deepcopy(runs)
    changed[0][field] = value
    assert verdict(changed)["status"] == "ACCEPTANCE_FAILED"
wrong = deepcopy(runs)
wrong[0]["started_at"] = approved_at.isoformat()
for invalid in (runs[:-1], wrong, [runs[0], *runs]):
    try:
        verdict(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid run roster or date passed.")
bench.audit_source_evidence(exe, workloads, verdict(runs), root / "untimed")
damaged = root / "untimed/equivalence/repeat-1/equivalence/certificate/safety.q3adrat"
original = damaged.read_bytes()
try:
    damaged.write_bytes(b"invalid proof header\n" + original)
    assert verdict(runs)["status"] == "ACCEPTANCE_FAILED"
    # A refreshed file roster is insufficient if the saved verifier is stale.
    refreshed = deepcopy(runs)
    equivalence = next(run for run in refreshed if run["workload"] == "equivalence")
    equivalence["artifact_sha256"] = bench.artifacts("equivalence", root / "untimed/equivalence/repeat-1")
    stale_verdict = verdict(refreshed)
    assert stale_verdict["status"] == "APPROVED_LIMITS_MET"
    try:
        bench.audit_source_evidence(exe, workloads, stale_verdict, root / "untimed")
    except ValueError as error:
        assert "verifier identity or exit differs" in str(error)
    else:
        raise AssertionError("Live audit accepted changed proof evidence with refreshed evidence hashes.")
finally:
    damaged.write_bytes(original)
assert verdict(runs)["status"] == "APPROVED_LIMITS_MET"

bench.write_json(root / "qualification.json",
    {"status": "PASS", "actual_benchmark": "NOT_RUN", "host": host,
     "product_executable_sha256": bench.digest(exe), "real_functional_revalidations": len(runs),
     "native_sampler_probe": "PASS", "native_watchdog_probe": "PASS",
     "synthetic_threshold_evaluation": "IN_MEMORY_ONLY",
     "rejected": ["unapproved proposal", "missing repeat", "duplicate repeat", "preapproval data",
                  "timeout", "missing samples", "modified proof bytes", "refreshed damaged proof hashes"]})
print("PASS: Phase 2 benchmark collection and verdict harness qualified without acceptance measurements.")

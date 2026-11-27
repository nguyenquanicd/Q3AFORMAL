"""Reconcile the Phase 3 evidence for one packaged build before scope review."""

import argparse
import json
import re
import zipfile
from hashlib import sha256 as digest_bytes
from pathlib import Path

from audit_four_state_conformance import read_json, require, sha256


REPO = Path(__file__).resolve().parents[2]


def audit(path):
    qualification = read_json(path)
    root = path.parent
    archive = REPO / qualification["archive"]
    archive_sha = sha256(archive)
    require(archive_sha == qualification["archive_sha256"], "Candidate archive differs")
    for filename, digest in qualification["evidence"].items():
        require(sha256(REPO / filename) == digest, f"Candidate evidence differs: {filename}")

    profile_root = root / "profile-check"
    profile = read_json(profile_root / "qualification.json")
    source_sha, checker_sha = profile["executable_sha256"], profile["standalone_checker_sha256"]
    require(profile["archive_sha256"] == archive_sha and profile["build_id"] == qualification["build_id"],
            "Profile and candidate archive identities differ")
    with zipfile.ZipFile(archive) as package:
        for filename, expected in (("q3aformal-sourcecheck.exe", source_sha),
                                   ("q3aformal-proofcheck.exe", checker_sha)):
            member = f"prototype/bin/{filename}"
            require(digest_bytes(package.read(member)).hexdigest() == expected
                    and sha256(profile_root / "extracted preview" / member) == expected,
                    f"Extracted executable differs: {filename}")

    evidence = {}

    def record(filepath):
        data = read_json(filepath)
        evidence[filepath.relative_to(REPO).as_posix()] = sha256(filepath)
        if "executable_sha256" in data:
            require(data["executable_sha256"] == source_sha, f"Wrong source executable: {filepath}")
        if "checker_sha256" in data:
            require(data["checker_sha256"] == checker_sha, f"Wrong checker executable: {filepath}")
        return data

    suites = profile["suite_evidence"]
    require(len({row["path"] for row in suites}) == len(suites) == qualification["profile_suites_passed"],
            "Profile suite roster differs")
    for suite in suites:
        target = profile_root / suite["path"]
        data = record(target)
        status = data["status"]
        require(status in {"PASS", "FUNCTIONAL_PREFLIGHT_PASSED"} or status.endswith("_QUALIFIED"),
                f"Profile suite has no qualification verdict: {target}")
        if "executables" in data:
            require(data["executables"]["development"] == source_sha and data["executables"]["checker"] == checker_sha,
                    f"Profile executable pair differs: {target}")
        require(sha256(target) == suite["sha256"], f"Profile suite changed: {target}")
    application = record(root / "apps/qualification.json")
    require(application["archive_sha256"] == archive_sha
            and len(application["checks"]) == qualification["application_suites_passed"], "Application roster differs")
    apps = {}
    for name, entry in application["checks"].items():
        target = REPO / entry["record"]
        apps[name] = record(target)
        require(sha256(target) == entry["sha256"], f"Application evidence changed: {name}")

    def suite(name):
        return record(profile_root / name / "qualification.json")

    model = record(root / "four-state-conformance.json")
    require(model["archive_sha256"] == archive_sha and model["suite_count"] == profile["four_state_suites"]
            and model["matched_reports"] >= 437 and len(model["typed_expression_checks"]) >= 87
            and len(model["timing_cases"]) >= 6 and model["first_match_guard"]["property"] == "p_first",
            "The source-to-model evidence is missing required checks")
    sequenced = suite("four-state-sequences")
    history = suite("four-state-history")
    named = suite("four-state-named_property")
    proof = suite("four-state-proof")
    assumptions = suite("four-state-assumptions")
    counter = suite("four-state-counterexample")
    cover = suite("four-state-cover")
    trace = suite("four-state-vcd")
    pruning = suite("four-state-window-pruning")
    require(len(sequenced["proof_sha256"]) >= 4 and sequenced["replayed_counterexamples"] >= 3
            and history["replayed_counterexamples"] >= 4 and named["rejected_cases"] >= 9,
            "Sequential or named-property controls differ")
    require(proof["cancelled_cases"] >= 1 and proof["rejected_claims_or_artifacts"] >= 6
            and len(proof["proof_sha256"]) >= 5 and pruning["wider_window_resource_limit"],
            "Proof, cancellation or resource-limit evidence differs")
    require(assumptions["inconsistent_environments"] >= 3 and assumptions["provisional_witnesses"] >= 2
            and assumptions["changed_environment_rejected"] and cover["provisional_case"] == "pending",
            "The assumption evidence lacks a contradiction or provisional check")
    require(len(counter["witnesses_sha256"]) >= 3 and counter["rejected_cases"] >= 10
            and cover["witness_reopen_cases"] >= 7 and trace["value_checks"] >= 42
            and trace["cover_vcd_sha256"] == trace["reopened_vcd_sha256"],
            "The witness reopening or waveform evidence differs")

    liveness = suite("liveness")
    liveness_archive = suite("liveness/direct")
    liveness_source = suite("liveness/direct/source")
    named_live = suite("liveness/sva")
    require(liveness["evidence_suite_sha256"] == sha256(profile_root / "liveness/direct/qualification.json")
            and liveness["named_suite_sha256"] == sha256(profile_root / "liveness/sva/qualification.json")
            and liveness_archive["source_regression_sha256"] == sha256(
                profile_root / "liveness/direct/source/qualification.json")
            and liveness_source["independently_replayed_lassos"] >= 2 and named_live["command_cases"] >= 19
            and len(liveness["waveforms"]) >= 3, "Liveness qualification is incomplete")
    for row in liveness_source["reports"]:
        require(sha256(profile_root / "liveness/direct/source" / row["name"]) == row["sha256"],
                f"Liveness report bytes differ: {row['name']}")

    sweep = apps["sweep"]
    require(sweep["resumed_points"] >= 10 and sweep["checkpoint_rejected_wrong_configuration"]
            and sweep["isolated_invalid_parameter"], "Sweep isolation or resume evidence differs")
    for axis in ("axi-read", "axi-write"):
        app = apps[axis]
        require(len(app["source_revalidated_proofs"]) >= 10 and len(app["source_replayed_faults"]) >= 3
                and len(app["standalone_obligations"]) >= 6, f"Protocol evidence is incomplete: {axis}")
    paired = apps["paired"]
    require(len(paired["waveforms"]) == 2 and paired["changed_marker_rejected"]
            and paired["missing_waveform_rejected"], "Paired waveform controls differ")

    runtime = read_json(root / "package-construction.json")["extracted_runtime_audit"]
    require(runtime["source_build_id"] == profile["build_id"] and runtime["fresh_working_directory"]
            and runtime["standalone_drat_roundtrip"] == "ACCEPTED" and runtime["pdr_certificate"] == "ACCEPTED"
            and {item["name"]: item["sha256"] for item in runtime["executables"]} ==
            {"q3aformal-sourcecheck.exe": source_sha, "q3aformal-proofcheck.exe": checker_sha},
            "Package runtime and checker inventory differs")
    require(all(not item["delay_imports"] for item in runtime["executables"]),
            "Package runtime includes unexpected delay imports")

    specification = REPO.parent / "Q3AFORMAL_SPECIFICATION.md"
    criteria = re.findall(r"^\| (Q3AF-AC-\d{2}) \|", specification.read_text(encoding="utf-8-sig"), re.MULTILINE)
    require(sorted(criteria) == [f"Q3AF-AC-{i:02d}" for i in range(1, 21)], "The product acceptance criteria changed")
    return {"status": "PHASE3_EVIDENCE_RECONCILED_FOR_REVIEW", "archive_sha256": archive_sha,
            "build_id": profile["build_id"], "source_executable_sha256": source_sha,
            "checker_sha256": checker_sha, "criteria_to_review": sorted(criteria),
            "specification_sha256": sha256(specification), "audit_script_sha256": sha256(Path(__file__)),
            "profile_suites_verified": len(suites), "application_suites_verified": len(apps),
            "owner_scope_approval": "PENDING", "phase2_timed_acceptance": "PENDING",
            "compatibility_qualification_at_audit": qualification["status"], "evidence": evidence}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qualification", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = audit(args.qualification.resolve())
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print(f"{result['status']} ({result['profile_suites_verified']} profile suites)")


if __name__ == "__main__":
    main()

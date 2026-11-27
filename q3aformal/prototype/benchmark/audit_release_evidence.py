"""Verify the requirement map and build evidence for a Phase 1 Windows candidate."""

import argparse
import csv
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sys
from zipfile import BadZipFile, ZipFile

from compare_phase1_debug_limits import check_approval, compare


ROOT = Path(__file__).resolve().parents[2]
SPECIFICATION = ROOT.parent / "Q3AFORMAL_SPECIFICATION.md"
TRACEABILITY = ROOT / "specs/003-phase1-block-mvp/requirements-traceability.md"
ACCEPTANCE = ROOT / "specs/003-phase1-block-mvp/release-acceptance.md"
MATRIX = ROOT / "prototype/corpus/phase1-conformance-additions.csv"
BASELINE_MATRIX = ROOT / "prototype/corpus/conformance-matrix.csv"
SOURCE_COVERAGE = ROOT / "prototype/corpus/source-model-vectors/coverage-map.md"
LOCAL_LINK = re.compile(r"\[([^\]]+)\](?:\(([^)]+)\)|\[([^\]]+)\])")


def file_hash(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def read_csv(path):
    with path.open(encoding="utf-8-sig", newline="") as source:
        return list(csv.DictReader(source))


def heading_anchors(path):
    anchors = set()
    in_code = False
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if re.match(r"^[ ]{0,3}(?:`{3,}|~{3,})", line):
            in_code = not in_code
        if in_code:
            continue
        heading = re.match(r"^#{1,6} (.+?)\s*#*\s*$", line)
        if heading:
            title = heading.group(1).strip().lower()
            anchor = re.sub(r"[^\w -]", "", title).replace(" ", "-")
            unique = anchor
            number = 1
            while unique in anchors:
                unique = f"{anchor}-{number}"
                number += 1
            anchors.add(unique)
    return anchors


def mapped_requirements(spec, matrix_path):
    criterion_ids = set(re.findall(r"^\| Q3AF-(AC-\d+) \|", spec, re.MULTILINE))
    requirement_ids = set(re.findall(r"^\| Q3AF-(FR-\d+) \|", spec, re.MULTILINE))
    phase_ids = set(re.findall(r"^### 16\.\d+ Phase (\d+)\b", spec, re.MULTILINE))
    require(criterion_ids and requirement_ids and phase_ids, "Specification tables or roadmap missing.")

    matrix = matrix_path.read_text(encoding="utf-8-sig")
    labels = dict(re.findall(r"^\[([^\]]+)\]: (.+)$", matrix, re.MULTILINE))
    rows = {}
    links = set()
    anchors = {}
    for line in matrix.splitlines():
        if not line.startswith("| FR-"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        require(len(cells) == 5, f"Unexpected matrix row structure: {line[:32]}")
        requirement, phase, criterion_list, scope, evidence = cells
        require(requirement not in rows, f"Duplicate requirement: {requirement}")
        phases = re.findall(r"(?:^|, )(\d+)\b", phase)
        criteria = [value.strip() for value in criterion_list.split(",")]
        require(phases and set(phases) <= phase_ids, f"Unknown phase for {requirement}: {phase}")
        require(criteria and set(criteria) <= criterion_ids, f"Unknown criterion for {requirement}")
        require(scope, f"Missing reported scope for {requirement}")
        locations = []
        for label, inline, reference in LOCAL_LINK.findall(evidence):
            target = inline or labels.get(reference)
            require(target is not None, f"Unknown evidence reference: {reference}")
            location, _, anchor = target.partition("#")
            path = (matrix_path.parent / location).resolve()
            require(path.exists(), f"Missing evidence for {requirement}: {target}")
            if anchor:
                if path not in anchors:
                    anchors[path] = heading_anchors(path)
                require(anchor in anchors[path], f"Missing heading for {requirement}: {target}")
            links.add((path, anchor))
            locations.append({"label": label, "location": target})
        require(locations, f"Missing evidence for {requirement}")
        rows[requirement] = {"id": requirement, "phase": phase, "criteria": criteria, "evidence": locations}

    require(set(rows) == requirement_ids, f"Unmapped or unknown requirements: {sorted(set(rows) ^ requirement_ids)}")
    mapped_criteria = {criterion for row in rows.values() for criterion in row["criteria"]}
    require(mapped_criteria == criterion_ids, f"Unmapped criteria: {sorted(criterion_ids - mapped_criteria)}")
    return list(rows.values()), len(criterion_ids), len(links)





def audit_module_suites(acceptance, expected_modules, passing_suites):
    """Resolve every module contract's regression evidence against the tested roster."""
    coverage = {}
    rows = re.findall(r"^\| (M\d+) [^|]+\|[^|]+\|([^|\r\n]+)\|[ \t]*$",
                      acceptance, re.MULTILINE)
    for module_id, evidence in rows:
        suites = sorted({Path(target.partition("#")[0]).stem
                         for _, target in re.findall(r"\[([^\]]+)\]\(([^)]+)\)", evidence)
                         if target.partition("#")[0].endswith(".ps1")})
        require(module_id not in coverage and suites,
                f"Duplicate module or missing suite evidence: {module_id}.")
        require(set(suites) <= passing_suites.keys(),
                f"Module {module_id} references an unqualified suite.")
        coverage[module_id] = suites
    require(coverage.keys() == expected_modules,
            f"Module-to-suite coverage differs: {sorted(coverage.keys() ^ expected_modules)}.")
    return coverage



def audit_baseline_profile(suite_roots, passing_suites):
    """Bind the Phase 0 language baseline to the current package regression."""
    rows = read_csv(BASELINE_MATRIX)
    authored = SOURCE_COVERAGE.read_text(encoding="utf-8-sig")
    links = re.findall(r"^\| ((?:RTL|SVA)-\d+) \|([^\r\n]+)", authored, re.MULTILINE)
    by_rule = dict(links)
    rules = {row["ID"] for row in rows}
    rejected = {row["ID"] for row in rows if row["Status"] == "Rejected"}
    supported = {row["ID"] for row in rows if row["Status"] == "Supported"}
    require(len(rules) == len(rows) and rules == rejected | supported
            and len(links) == len(by_rule) and set(by_rule) == supported,
            "Baseline matrix and source-to-model roster differ.")
    for row in rows:
        require(row["Required evidence"].strip() and row["Limitations"].strip(),
                f"Missing scoped baseline evidence for {row['ID']}.")

    matches = {}
    for rule, evidence in by_rule.items():
        names = sorted(set(re.findall(r"\b(test_[a-z0-9_]+)\.ps1\b", evidence)))
        require(names and set(names) <= passing_suites.keys(),
                f"No complete passing package evidence for baseline construct {rule}.")
        matches[rule] = names

    suite = "test_gate_a_rejections"
    require(suite in passing_suites, "The package does not qualify the rejected profile cases.")
    transcript = (suite_roots[suite] / f"{suite}.stdout.txt").read_text(encoding="utf-8-sig")
    rejection_rows = re.findall(r"^((?:RTL|SVA)-\d+) [^\r\n]+case\.sv:[1-4]:\d+:",
                                transcript, re.MULTILINE)
    require(set(rejection_rows) == rejected
            and f"PASS: all {len(rejection_rows)} Gate A negative examples" in transcript,
            "The source-located rejection transcript does not cover the baseline exclusions.")
    return {"supported_rows": matches, "rejected_rows": sorted(rejected),
            "source_located_rejections": len(rejection_rows),
            "matrix_sha256": file_hash(BASELINE_MATRIX),
            "coverage_map_sha256": file_hash(SOURCE_COVERAGE)}


def audit_conformance_rows(rows, roster):
    """Require unique conformance rows with a registered suite and all evidence classes."""
    required = ("Area", "Construct", "Positive evidence", "Negative evidence",
                "Boundary evidence", "Source and model evidence", "Limitations")
    require(rows and len({row.get("ID") for row in rows}) == len(rows),
            "Empty or duplicate Phase 1 conformance roster.")
    for row in rows:
        identifier = row.get("ID") or ""
        require(re.fullmatch(r"P1-[A-Z]+-\d{3}", identifier),
                f"Invalid Phase 1 conformance identifier: {identifier}.")
        missing = [field for field in required if not (row.get(field) or "").strip()]
        require(not missing, f"Phase 1 conformance row {identifier} lacks: {', '.join(missing)}.")
        require(row["Regression suite"] in roster,
                f"Phase 1 conformance row {identifier} lacks passing suite evidence.")
    return len(rows)


def audit_result_identity(suite_roots, binary_sha, build_id):
    """Cross-check the recorded model, run, and cache identities for AC-08."""
    def qualification(suite):
        root = suite_roots[f"test_{suite}"] / f"test_{suite}-artifacts"
        result = read_json(root / "qualification.json")
        require(result["executable_sha256"] == binary_sha, f"Identity evidence uses another build: {suite}.")
        return root, result

    relocation, record = qualification("relocated_project_determinism")
    first_model = relocation / "model-0.txt"
    require(file_hash(first_model) == file_hash(relocation / "model-1.txt")
            and read_json(first_model)["input_sha256"] == record["source_hash"]
            and read_json(relocation / "changed-model.txt")["input_sha256"] == record["changed_source_hash"]
            and record["source_hash"] != record["changed_source_hash"]
            and record["cross_root_certificate_checks"] == ["VERIFIED", "VERIFIED"]
            and record["standalone_drat_passed"] == 3,
            "Relocated or header-modified source identity differs.")
    proof_files = {"invariant.txt", *(f"{stem}.{suffix}"
                    for stem in ("initiation", "consecution", "safety")
                    for suffix in ("cnf", "q3adrat"))}
    require(set(record["identical_proof_artifacts"]) == proof_files,
            "The relocation proof artifact roster differs.")
    for name, digest in record["identical_proof_artifacts"].items():
        require(all(file_hash(relocation / root / "proof" / name) == digest
                    for root in ("first root", "second root")),
                f"The relocated proof artifact digest differs: {name}.")

    witness, record = qualification("bundle_run_configuration")
    first, second = record["cases"]
    require(first["replay_query_sha256"] == second["replay_query_sha256"]
            and first["configuration_sha256"] != second["configuration_sha256"]
            and record["historical_witness_verified"] is True
            and record["rehashed_property_substitutions_rejected"] == 2,
            "The witness artifact must distinguish the initiating search and replay identities.")
    for case, name in zip((first, second), ("first", "second")):
        bundle = witness / f"{name}-bundle"
        config = bundle / "reports/run-configuration.json"
        manifest = read_json(bundle / "manifest.json")
        require(file_hash(config) == case["configuration_sha256"]
                and read_json(config) == case["configuration"]
                and case["configuration"]["build_id"] == build_id
                and manifest["queries"][0]["cnf_sha256"] == case["replay_query_sha256"],
                f"The saved witness configuration digest or context differs: {name}.")

    certificate, record = qualification("pdr_certificate_configuration")
    first, second = record["cases"]
    require(first["core_proof_files"] == second["core_proof_files"]
            and len(first["core_proof_files"]) == len(proof_files)
            and first["model_sha256"] == second["model_sha256"]
            and first["provenance_sha256"] != second["provenance_sha256"]
            and record["rejected_substitutions"] == 8
            and record["historical_certificate_verified"] is True,
            "PDR certificate provenance differs from its recorded run or proof.")
    for case, name in zip((first, second), ("first", "second")):
        folder = certificate / f"{name}-certificate"
        config = folder / "run-configuration.json"
        descriptor = read_json(config)
        require(file_hash(config) == case["provenance_sha256"]
                and descriptor["model_sha256"] == case["model_sha256"]
                and descriptor["run_configuration"]["build_id"] == build_id

                and descriptor["run_configuration"]["maximum_depth"] == case["depth"]
                and descriptor["run_configuration"]["maximum_search_queries"] == case["query_limit"]
                and [file_hash(folder / artifact) for artifact in sorted(proof_files)]
                == case["core_proof_files"],
                f"The PDR configuration or proof digest differs: {name}.")

    _, record = qualification("manifest_bound_proof_cache")
    cases = {case["case"]: case for case in record["cases"]}
    require(set(cases) == {"original", "identical-bytes", "changed", "changed-repeat"}
            and len(record["cases"]) == len(cases)
            and len({case["model_sha256"] for case in cases.values()}) == 1
            and len({tuple(case["query_sha256"]) for case in cases.values()}) == 1
            and cases["original"]["manifest_sha256"] != cases["changed"]["manifest_sha256"]
            and cases["original"]["keys"] != cases["changed"]["keys"],
            "The cache does not distinguish different manifest contents for the same proof model.")
    for original, replay in (("original", "identical-bytes"), ("changed", "changed-repeat")):
        require(cases[original]["result"] == "STORED" and cases[replay]["result"] == "HIT"
                and all(cases[original][field] == cases[replay][field] for field in ("manifest_sha256", "keys")),
                f"An identical manifest did not reuse its cache identity: {replay}.")

    controls = read_json(suite_roots["test_product_run_control"] / "test_product_run_control.json")
    limits = {"bmc": {"transition_count"}, "induction": {"induction_depth"},
              "pdr": {"maximum_depth", "maximum_search_queries", "minimum_feasibility_bound"}}
    require(controls["executable_sha256"] == binary_sha and len(controls["cases"]) == len(limits)
            and {case["engine"] for case in controls["cases"]} == set(limits),
            "Interruption evidence does not cover the candidate's three engines.")
    for case in controls["cases"]:
        config = case["resolved_configuration"]
        require(case["build_id"] == build_id and case["status"] == "TIMEOUT"
                and limits[case["engine"]] <= config.keys()
                and all(re.fullmatch(r"[0-9a-f]{64}", config[field])
                        for field in ("configuration_sha256", "project_manifest_sha256")),
                f"Missing resolved timeout identity: {case['engine']}.")
    return {"relocation_proof_artifacts": len(proof_files), "witness_configurations": 2,
            "certificate_configurations": 2, "cache_configurations": len(cases),
            "controlled_engines": sorted(limits)}


def audit_regression_attempts(root, retries, regression):
    """Retain every result and use a later pass only for an initially unsuccessful suite."""
    roster = {path.stem: file_hash(path) for path in (ROOT / "prototype/tests").glob("test_*.ps1")}
    pending = set(roster)
    passing, suite_roots = {}, {}
    attempts = []
    seen = set()
    runner_hash = file_hash(ROOT / "prototype/benchmark/run_product_regression.ps1")
    for directory in (root, *retries):
        directory = directory.resolve()
        require(directory not in seen, "Repeated regression evidence directory.")
        seen.add(directory)
        ledger_path = directory / "suites.csv"
        identity_path = directory / "run-identity.json"
        summary_path = directory / "summary.json"
        identity = read_json(identity_path)
        summary = read_json(summary_path)
        rows = read_csv(ledger_path)
        names = {row["suite"] for row in rows}
        passed = {row["suite"] for row in rows if row["status"] == "PASS"}
        require(all(summary[field] == identity[field] == regression[field]
                    for field in ("package_sha256", "build_id", "executables")),
                "Regression attempt uses a different package or executable pair.")
        watchdog = identity["per_suite_timeout_seconds"]
        require(summary["per_suite_timeout_seconds"] == watchdog and type(watchdog) is int and watchdog > 0,
                "Regression attempt watchdog differs from its recorded run identity.")
        require(identity["schema"] == "Q3AFORMAL_PRODUCT_REGRESSION_RUN_1"
                and identity["runner_sha256"] == runner_hash
                and names and names <= pending
                and (attempts or names == pending)
                and len(rows) == len(names) == summary["suites"]
                and len(passed) == summary["passed"]
                and len(names - passed) == summary["failed_or_timed_out"]
                and identity["roster"] == {name: roster[name] for name in names},
                "Regression attempt roster, runner, or aggregate verdict differs.")
        for row in rows:
            name = row["suite"]
            require(row["script_sha256"] == roster[name] and row["status"] in {"PASS", "FAIL", "TIMEOUT"}
                    and (row["exit_code"] == "0") == (row["status"] == "PASS"),
                    f"Invalid recorded verdict or source digest: {name}.")
            if name in passed:
                passing[name] = row
                suite_roots[name] = directory
        pending -= passed
        attempts.append({
            "evidence_directory": directory.relative_to(ROOT).as_posix() if directory.is_relative_to(ROOT) else directory.name,
            "suites": len(names), "passed": len(passed), "unsuccessful": sorted(names - passed),
            "per_suite_timeout_seconds": watchdog,
            "ledger_sha256": file_hash(ledger_path), "summary_sha256": file_hash(summary_path),
            "run_identity_sha256": file_hash(identity_path),
        })
    require(not pending, f"Exact-build regression evidence remains unsuccessful: {sorted(pending)}.")
    return passing, suite_roots, attempts


def audit_standalone_drat(report, phase1, archive_sha, checker_sha):
    """Verify the standalone checker's current block benchmark evidence."""
    recorded = read_json(report)
    require(recorded["package_sha256"] == archive_sha and recorded["checker_sha256"] == checker_sha,
            "Independent proof evidence uses another package or checker.")
    pdr = phase1 / "P1-04-registered-grant-pdr-artifacts/certificate"
    induction = phase1 / "P1-01-elastic-induction-artifacts"
    pdr_model = read_json(pdr / "run-configuration.json")["model_sha256"]
    induction_model = read_json(induction / "bundle/manifest.json")["model"]["sha256"]
    proofs = {f"pdr-{kind}": (pdr / kind, pdr_model)
              for kind in ("initiation", "consecution", "safety")}
    proofs.update({f"induction-k2-{kind}": (induction / f"proof.{kind}", induction_model)
                   for kind in ("base", "step")})
    checks = {row["obligation"]: row for row in recorded["checks"]}
    require(len(checks) == len(recorded["checks"]) and checks.keys() == proofs.keys(),
            "Independent checker evidence does not cover the five approved proof obligations.")
    for obligation, (stem, model) in proofs.items():
        check = checks[obligation]
        transcript = report.parent / f"{obligation}.rerun.stdout.txt"
        require(check["verdict"] == "ACCEPTED" and check["model_sha256"] == model
                and check["cnf_sha256"] == file_hash(Path(f"{stem}.cnf"))
                and check["proof_sha256"] == file_hash(Path(f"{stem}.q3adrat"))
                and "Q3A_PROOF_CHECK ACCEPTED" in transcript.read_text(encoding="utf-8-sig").splitlines(),
                f"Independent checker evidence differs: {obligation}.")
    return {"qualification_sha256": file_hash(report), "verified_obligations": sorted(checks)}


def audit_gui_functional(path, archive_sha, binary_sha):
    record = read_json(path)
    viewer = ROOT / "prototype/source/bundle/native_debug_win32.cpp"
    require(record["criterion"] == "Q3AF-AC-12"
            and record["status"] == "FUNCTIONAL_QUALIFIED"
            and record["package_sha256"] == archive_sha
            and record["package_executable_sha256"] == binary_sha
            and record["production_viewer_source_sha256"] == file_hash(viewer),
            "Native GUI functional evidence uses another candidate or viewer source.")
    entries = {entry["path"]: entry["sha256"] for entry in record["evidence"]}
    require(len(entries) == len(record["evidence"]) == 5,
            "Native GUI functional evidence must retain its five distinct records.")
    linked_paths = []
    for relative, digest in entries.items():
        linked = (ROOT / relative).resolve()
        require(linked.is_relative_to(ROOT) and file_hash(linked) == digest,
                f"Native GUI functional evidence digest differs: {relative}.")
        linked_paths.append(linked)

    def one_file(name, parent=None):
        matches = [item for item in linked_paths if item.name == name and
                   (parent is None or item.parent == parent)]
        require(len(matches) == 1, f"Native GUI functional evidence is missing or ambiguous: {name}.")
        return matches[0]

    package = read_json(one_file("package-audit.json", path.resolve().parent))
    require(package["status"] == "INTERNAL_CANDIDATE_VERIFIED" and package["sha256"] == archive_sha,
            "Native GUI functional evidence recorded a different verified archive.")
    modal_root = one_file("source-overlay.json").parent
    dialogs = read_json(one_file("qualification.json", modal_root))
    overlay = read_json(one_file("source-overlay.json", modal_root))
    packaged = read_json(one_file("qualification.json", path.resolve().parent / "native-targeted"))
    indexed = read_json(one_file("qualification.json", path.resolve().parent / "untimed-capture"))
    require(dialogs["status"] == "PASS" and dialogs["observed_visible"] == 3
            and dialogs["confirmed"] == 2 and dialogs["cancelled"] == 1
            and dialogs["production_source_sha256"] == file_hash(viewer)
            and dialogs["session_sha256"] == file_hash(modal_root / "system-modal-roundtrip.json")
            and overlay["test_source_sha256"] == file_hash(modal_root / "native_debug_win32.cpp")
            and packaged["executable_sha256"] == indexed["executable_sha256"] == binary_sha
            and packaged["checks"] == record["packaged_checks"]
            and indexed["status"] == "PASS" and indexed["mode"] == "OFFSCREEN_UNTIMED"
            and indexed["checks"] == record["indexed_workloads"]
            and len(indexed["checks"]) == 2 and sum(check["values"] for check in indexed["checks"]) == 240,
            "Native GUI control, system dialog, or indexed waveform qualification differs.")
    return {"qualification_sha256": file_hash(path), "visible_system_dialogs": 3,
            "verified_viewport_values": 240}


def audit_gui_performance(capture_dir, preflight_path, archive_sha, binary_sha):
    limits_path = ROOT / "prototype/benchmark/phase1-debug-limits.approved.json"
    capture_path = capture_dir / "capture.json"
    verdict_path = capture_dir / "verdict.json"
    approved, approved_at = check_approval(limits_path)
    evaluated = compare(approved, approved_at, file_hash(limits_path),
                        read_json(preflight_path), read_json(capture_path))
    evaluated["capture_sha256"] = file_hash(capture_path)
    evaluated["preflight_sha256"] = file_hash(preflight_path)
    require(evaluated == read_json(verdict_path) and evaluated["status"] == "APPROVED_LIMITS_MET"
            and evaluated["archive_sha256"] == archive_sha and evaluated["executable_sha256"] == binary_sha,
            "Approved visible Windows GUI measurements do not pass for the candidate.")
    return {"verdict_sha256": file_hash(verdict_path), "capture_sha256": evaluated["capture_sha256"],
            "preflight_sha256": evaluated["preflight_sha256"], "limit_sha256": evaluated["limits_sha256"],
            "runs": len(evaluated["runs"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--package-audit", required=True, type=Path)
    parser.add_argument("--regression", required=True, type=Path)
    parser.add_argument("--regression-retry", action="append", default=[], type=Path,
                        help="Separate same-build run for suites that did not pass in an earlier attempt")
    parser.add_argument("--phase0", required=True, type=Path)
    parser.add_argument("--phase1", required=True, type=Path)
    parser.add_argument("--standalone-drat", type=Path)
    parser.add_argument("--gui-functional", type=Path)
    parser.add_argument("--gui-capture", type=Path)
    parser.add_argument("--gui-preflight", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    spec = SPECIFICATION.read_text(encoding="utf-8-sig")
    requirements, criteria, links = mapped_requirements(spec, TRACEABILITY)
    acceptance = ACCEPTANCE.read_text(encoding="utf-8-sig")
    dispositions = re.findall(r"^\| (AC-\d+) \| ([^|]+) \|", acceptance, re.MULTILINE)
    dispositions = [(criterion, label.strip()) for criterion, label in dispositions]
    criterion_ids = {item for row in requirements for item in row["criteria"]}
    require(len(dispositions) == criteria and {item for item, _ in dispositions} == criterion_ids
            and {label for _, label in dispositions} <= {"Open", "Phase 0", "Supported", "Supported for this package"},
            "The release acceptance ledger does not cover each criterion exactly once.")
    module_ids = set(re.findall(r"^\| (M\d+) \|", spec, re.MULTILINE))
    contract_rows = re.findall(r"^\| (M\d+) [^|]+\|", acceptance, re.MULTILINE)
    require(module_ids and len(contract_rows) == len(module_ids) and set(contract_rows) == module_ids,
            "The release ledger does not cover each architecture module exactly once.")
    for _, target in re.findall(r"\[([^\]]+)\]\(([^)]+)\)", acceptance):
        location, _, anchor = target.partition("#")
        path = (ACCEPTANCE.parent / location).resolve()
        if path == args.output.resolve():
            continue
        require(path.exists(), f"Missing release ledger evidence: {target}")
        require(not anchor or anchor in heading_anchors(path), f"Missing release ledger heading: {target}")
    package = read_json(args.package_audit)
    regression = read_json(args.regression / "summary.json")
    archive_sha = file_hash(args.archive)
    require(package["status"] == "INTERNAL_CANDIDATE_VERIFIED"
            and archive_sha == package["sha256"] == regression["package_sha256"],
            "Package, extracted-runtime audit, and regression digests differ.")
    with ZipFile(args.archive) as archive:
        manifest = json.loads(archive.read("package-manifest.json"))
        payloads = {entry["path"]: entry for entry in manifest["files"]}
        names = archive.namelist()
        require(manifest["source_build_id"] == package["source_build_id"] == regression["build_id"]
                and len(names) == len(set(names)) == len(payloads) + 1
                and set(names) == {*payloads, "package-manifest.json"}
                and len(payloads) == len(manifest["files"]) == package["files"],
                "Archive payload roster or build identity differs.")
        for name, entry in payloads.items():
            with archive.open(name) as payload:
                require(hashlib.file_digest(payload, "sha256").hexdigest() == entry["sha256"]
                        and archive.getinfo(name).file_size == entry["bytes"],
                        f"Archive payload digest or size differs: {name}.")
    suites, suite_roots, regression_attempts = audit_regression_attempts(
        args.regression, args.regression_retry, regression
    )
    binary = next(row for row in regression["executables"] if row["path"].endswith("sourcecheck.exe"))
    binary_sha = binary["sha256"]
    extracted = {entry["name"]: entry["sha256"] for entry in package["extracted_runtime_audit"]["executables"]}
    require({Path(item["path"]).name: item["sha256"] for item in regression["executables"]} == extracted,
            "Regression did not use the extracted-runtime binary pair.")
    require(all(payloads[item["path"]]["sha256"] == item["sha256"] for item in regression["executables"]),
            "Archived binary digest differs from the regression.")
    require(all(file_hash(ROOT / item["path"]) == item["sha256"] for item in regression["executables"]),
            "Current workspace executable differs from the tested binary.")

    identity = None
    if dict(dispositions)["AC-08"].startswith("Supported"):
        identity = audit_result_identity(suite_roots, binary_sha, regression["build_id"])

    phase0 = read_csv(args.phase0 / "threshold-verdicts.csv")
    bundles = read_csv(args.phase0 / "bundle-verdicts.csv")
    phase1 = read_json(args.phase1 / "approved-limit-verdict.json")
    limits_path = ROOT / "prototype/benchmark/phase1-block-limits.approved.json"
    limits = read_json(limits_path)
    by_job = {job["id"]: job for job in limits["jobs"]}
    require(len(phase0) == 8 and all(row["Verdict"] == "PASS" for row in phase0)
            and len(bundles) == 4 and all(row["Verification"] == "REVALIDATED"
                                         and row["ExecutableSha256"] == binary_sha for row in bundles),
            "Phase 0 compatibility or bundle verification differs.")
    require(phase1["status"] == "APPROVED_LIMITS_MET" and phase1["executable_sha256"] == binary_sha
            and limits["approval_status"] == "APPROVED" and phase1["limits_sha256"] == file_hash(limits_path)
            and phase1["workload_sha256"] == limits["workload_sha256"]
            and datetime.fromisoformat(limits["approved_at"]) < datetime.fromisoformat(phase1["measurements_captured_at"])
            and len(phase1["jobs"]) == len(by_job) == 5
            and {job["id"] for job in phase1["jobs"]} == set(by_job),
            "Approved Phase 1 native measurements do not pass for the candidate.")
    for job in phase1["jobs"]:
        limit = by_job[job["id"]]
        require(job["within_limits"]
                and 0 < job["elapsed_ms"] <= job["max_wall_ms"] == limit["max_wall_ms"]
                and 0 < job["peak_working_set_bytes"] <= job["max_peak_working_set_bytes"]
                == limit["max_peak_working_set_bytes"], f"Benchmarked limits differ: {job['id']}.")

    qualified_gui = {}
    if dict(dispositions)["AC-10"].startswith("Supported") or args.gui_capture or args.gui_preflight:
        require(args.gui_capture and args.gui_preflight, "AC-10 requires the raw GUI capture and its preflight.")
        qualified_gui["AC-10"] = audit_gui_performance(args.gui_capture, args.gui_preflight, archive_sha, binary_sha)
    if dict(dispositions)["AC-12"].startswith("Supported") or args.gui_functional:
        require(args.gui_functional, "AC-12 requires the candidate's native GUI functional qualification.")
        qualified_gui["AC-12"] = audit_gui_functional(args.gui_functional, archive_sha, binary_sha)

    conformance_count = audit_conformance_rows(read_csv(MATRIX), suites)
    baseline_profile = audit_baseline_profile(suite_roots, suites)
    module_suite_coverage = audit_module_suites(acceptance, module_ids, suites)
    result = {
        "schema": "Q3AFORMAL_RELEASE_EVIDENCE_AUDIT_1",
        "package_sha256": archive_sha,
        "specification_sha256": file_hash(SPECIFICATION),
        "requirement_map_sha256": file_hash(TRACEABILITY),
        "acceptance_ledger_sha256": file_hash(ACCEPTANCE),
        "conformance_matrix_sha256": file_hash(MATRIX),
        "requirement_count": len(requirements),
        "criteria_referenced": criteria,
        "architecture_module_contracts": len(contract_rows),
        "architecture_module_suite_coverage": module_suite_coverage,
        "criteria_open": [item for item, disposition in dispositions if disposition == "Open"],
        "criteria_supported_for_candidate": [item for item, disposition in dispositions if disposition.startswith("Supported")],
        "criteria_satisfied_by_phase0_gate": [item for item, disposition in dispositions if disposition == "Phase 0"],
        "unique_evidence_targets": links,
        "passing_suites": len(suites),
        "regression_attempts": regression_attempts,
        "phase0_compatibility": len(phase0),
        "phase0_source_verified_bundles": len(bundles),
        "phase1_approved_native_cases": len(phase1["jobs"]),
        "phase1_conformance_rows_with_passing_suites": conformance_count,
        "baseline_language_profile": baseline_profile,
        "scope": "Mapping, link and candidate evidence verification. Individual criterion acceptance is reviewed separately.",
        "requirements": requirements,
    }
    if args.standalone_drat:
        checker_sha = extracted["q3aformal-proofcheck.exe"]
        result["standalone_drat_evidence"] = audit_standalone_drat(
            args.standalone_drat, args.phase1, archive_sha, checker_sha
        )
    if qualified_gui:
        result["qualified_gui_evidence"] = qualified_gui
    if identity is not None:
        result["result_identity_evidence"] = identity
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"Verified {len(requirements)} requirements, {criteria} criteria, and {len(suites)} suites.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, StopIteration, BadZipFile) as error:
        sys.exit(f"Evidence audit failed: {error}")

"""Audit four-state evidence from an extracted Windows development preview."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


PROFILE = "Q3A-FOUR-STATE-DEVELOPMENT"
QUERY_OUTCOMES = {
    "EVALUATED", "PROVEN", "BOUNDED_PASS", "REVALIDATED", "COUNTEREXAMPLE",
    "COVERED", "NOT_FOUND_WITHIN_BOUND", "WITNESS_PENDING_ASSUMPTION",
    "INCONSISTENT",
}

# Expected sampled paths derived from the fixture source intervals.
TIMING_CASES = (
    ("four-state-sequence_or/sequence-or.q3a", "c_early", ((0, 1), (0, 3))),
    ("four-state-sequence_and/conjunction.q3a", "c_late", ((0, 0, 1, 2),)),
    ("four-state-sequence_intersect/intersection.q3a", "c_equal", ((0, 0, 1, 2, 2, 2),)),
    ("four-state-sequence_within/within.q3a", "c_inside",
     ((0, 0, 1, 3), (0, 1, 2, 3), (0, 2, 3, 3))),
    ("four-state-sequence_throughout/throughout.q3a", "c_protocol", ((0, 0, 1, 2, 2),)),
)
NAMED_SEQUENCE_TIMING = (
    "four-state-named_sequence/sequence.q3a", "c_twice", ((0, 1, 2, 3),), "named.sv",
)
DIVISION_MODEL = "four-state-divide/division.q3a"
DIVISION_EQUATIONS = {
    "uq": ("/", 4, False), "ur": ("%", 4, False),
    "sq": ("/", 4, True), "sr": ("%", 4, True),
    "mixed": ("/", 4, False), "overflow": ("/", 64, True),
    "negative_remainder": ("%", 64, True),
}

# Source-derived expectations use paths into each equation's typed expression.
# An empty path selects the root. Width and signedness describe the selected node.
EXPRESSION_CASES = {
    "four-state-evaluation/four.q3a": {
        "mux": [((), "conditional", "?:", 4, False),
                ((0,), "signal", "sel", 1, False), ((1,), "signal", "intermediate", 4, False),
                ((2,), "signal", "b", 4, False)],
        "fill": [((), "literal", "'Z", 4, False)],
        "padded": [((), "literal", "4'bx", 4, False)],
        "joined": [((), "concatenation", "{}", 4, False), ((0,), "signal", "a", 2, True),
                   ((1,), "select", "part", 2, False), ((1, 1), "constant", "0", 32, False)],
        "eq": [((), "binary", "==", 1, False), ((0,), "signal", "a", 2, True),
               ((1,), "signal", "b", 4, False)],
    },
    "four-state-arithmetic/arithmetic.q3a": {
        "sum": [((), "binary", "+", 4, True), ((0,), "signal", "a", 2, True),
                ((1,), "signal", "b", 4, True)],
        "diff": [((), "binary", "-", 4, True)],
        "neg": [((), "unary", "-", 2, True)],
        "wide_sum": [((), "binary", "+", 64, False)],
        "signed_order": [((i,), "binary", op, 1, False) for i, op in enumerate(("<", ">", "<=", ">="))]
                        + [((0, 1), "signal", "b", 4, True)],
        "mixed_order": [((0,), "binary", "<", 1, False), ((0, 1), "signal", "u", 4, False)],
    },
    "four-state-shifts/shifts.q3a": {
        "shl": [((), "binary", "<<", 4, True)],
        "shr": [((), "binary", ">>", 4, True)],
        "ashl": [((), "binary", "<<<", 4, True)],
        "ashr": [((), "binary", ">>>", 4, True)],
        "unsigned_right": [((), "binary", ">>>", 4, False)],
        "widened": [((), "binary", ">>>", 8, True), ((0,), "assignment_resize", "expression_width", 8, True),
                    ((0, 0), "signal", "v", 4, True), ((1,), "signal", "amount", 2, True)],
        "high_distance": [((1,), "signal", "wide_count", 64, False)],
    },
    "four-state-reductions/reduction.q3a": {
        "gates": [((i,), "unary", op, 1, False) for i, op in enumerate(("&", "~&", "|", "~|", "^", "~^", "^~"))],
    },
    "four-state-indexed_bits/indexed.q3a": {
        "a": [((), "indexed_bit", "packed", 1, False), ((2,), "constant", "4", 64, True),
              ((3,), "constant", "7", 64, True)],
        "d": [((), "indexed_bit", "packed", 1, False), ((2,), "constant", "7", 64, True),
              ((3,), "constant", "4", 64, True)],
        "signed_read": [((1,), "signal", "idx", 4, True), ((3,), "constant", "-2", 64, True)],
        "wide_read": [((1,), "signal", "wide_idx", 64, False)],
    },
    "four-state-indexed_parts/indexed.q3a": {
        "a_plus": [((), "indexed_part", "+:", 3, False), ((2,), "constant", "4", 64, True),
                   ((3,), "constant", "7", 64, True)],
        "d_plus": [((), "indexed_part", "+:", 3, False), ((2,), "constant", "7", 64, True),
                   ((3,), "constant", "4", 64, True)],
        "d_minus": [((), "indexed_part", "-:", 3, False)],
        "a_minus": [((), "indexed_part", "-:", 3, False)],
        "signed_plus": [((1,), "signal", "signed_base", 4, True), ((3,), "constant", "-2", 64, True)],
        "limit_slice": [((), "indexed_part", "-:", 2, False), ((1,), "signal", "wide", 64, False),
                        ((2,), "constant", "9223372036854775807", 64, True),
                        ((3,), "constant", "9223372036854775806", 64, True)],
    },
    "four-state-casex/sampled.q3a": {
        "q": [((), "conditional", "case", 2, False), ((0,), "casex_match", "four-state-xz-wildcard", 1, False),
              ((1,), "literal", "2'd1", 2, False), ((2,), "signal", "q", 2, False)],
    },
    "four-state-case/case.q3a": {
        "plain": [((0,), "binary", "===", 1, False), ((1,), "literal", "2'b01", 2, False),
                  ((2,), "conditional", "if", 2, False)],
        "w": [((0,), "casez_match", "four-state-z-wildcard", 1, False),
              ((1,), "literal", "2'b00", 2, False)],
    },
    "four-state-wildcard_equality/wildcards.q3a": {
        "comparison": [((0,), "binary", "==?", 1, False), ((1,), "binary", "!=?", 1, False)],
        "signed_match": [((0,), "signal", "sa", 2, True)],
    },
    "four-state-hierarchy/seq.q3a": {
        "qx": [((), "concatenation", "{}", 2, False), ((0, 0), "signal", "d", 2, False),
               ((0, 1), "constant", "0", 32, False), ((1, 1), "constant", "1", 32, False)],
        "qy": [((), "signal", "e", 2, False)],
    },
    "four-state-sequential/sampled.q3a": {
        "a": [((), "signal", "b", 1, False)],
        "b": [((), "conditional", "?:", 1, False)],
        "hold": [((), "conditional", "if", 1, False)],
        "phase": [((), "literal", "1'b1", 1, False)],
    },
}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def export_model(executable, manifest):
    run = subprocess.run(
        [str(executable), "dev-lower-four-state", str(manifest)],
        capture_output=True,
        timeout=30,
    )
    if run.returncode == 2 and not run.stdout:
        return None
    require(run.returncode == 0 and not run.stderr, f"Unexpected model export result: {manifest}")
    payload = run.stdout.rstrip(b"\r\n")
    model = json.loads(payload)
    require(model["semantic_profile"] == PROFILE, f"Incorrect model profile: {manifest}")
    return hashlib.sha256(payload).hexdigest(), model


def fixed_paths(sequence, source_name):
    terms = sequence["terms"]
    automaton = sequence["automaton"]
    transitions = automaton["transitions"]
    require(len(terms) == len(transitions), "The automaton lost a source term")
    paths = []
    samples = []
    current_state = automaton["start_state"]
    sample = 0
    for term, transition in zip(terms, transitions):
        require(transition["source_state"] == current_state, "Disconnected automaton transition")
        require(term["delay_from_previous"] == transition["delay_cycles"] and
                term["repeat_min"] == term["repeat_max"] == 1 and
                transition["repeat_min"] == transition["repeat_max"] == 1 and
                term["predicate"] == transition["predicate"], "Term and transition disagree")
        source = term["predicate"]["source"]
        require(source["file"] == source_name and source["line"] > 0 and source["column"] > 0,
                "Predicate has no source location in the fixture")
        sample += transition["delay_cycles"]
        samples.append(sample)
        current_state = transition["target_state"]
        if current_state == automaton["accepting_state"]:
            paths.append(tuple(samples))
            samples = []
            current_state = automaton["start_state"]
            sample = 0
    require(not samples, "The last automaton path does not terminate")
    return tuple(sorted(paths))


def typed_division_equations(model):
    equations = {item["target"]: item for item in model["combinational_equations"]}
    results = []
    for name, (operator, width, signed) in DIVISION_EQUATIONS.items():
        equation = equations[name]
        expression = equation["expression"]
        location = expression["source"]
        require(expression["kind"] == "binary" and expression["value"] == operator and
                expression["width"] == equation["target_width"] == width and
                expression["signed"] == signed and len(expression["operands"]) == 2 and
                all(operand["signed"] == signed for operand in expression["operands"]) and
                location["file"] == "division.sv" and location["line"] > 0 and location["column"] > 0,
                f"Incorrect division type or source location: {name}")
        results.append({"target": name, "operator": operator, "bits": width, "signed": signed,
                        "source": location})
    return results


def first_match_equations(model):
    item = next(prop for prop in model["properties"] if prop["name"] == "p_first")
    sequence = item["antecedent"]
    paths = fixed_paths(sequence, "first.sv")
    require(paths == ((0, 1, 1), (0, 1, 2, 2, 2)), "First-match timing alternatives differ")
    guards = [term["predicate"] for term in sequence["terms"]
              if term["predicate"]["kind"] == "history_ref"]
    require(len(guards) == 1 and guards[0]["source"]["line"] == 11,
            "Only the later named-sequence endpoint should carry a sampled guard")
    equations = {item["target"]: item["expression"] for item in model["next_state_equations"]}
    guard = equations[guards[0]["value"]]
    require(guard["kind"] == "unary" and guard["value"] == "!" and guard["width"] == 1,
            "The later endpoint must negate the earlier endpoint's match")
    conjunction, = guard["operands"]
    clauses = []
    while conjunction["value"] == "&&":
        conjunction, clause = conjunction["operands"]
        clauses.append(clause)
    clauses.append(conjunction)
    require(len(clauses) == 3 and all(eq["value"] == "===" and eq["operands"][1]["value"] == "1'b1"
                                      for eq in clauses), "An earlier match requires all its predicates to be true")
    history = [eq["operands"][0] for eq in clauses if eq["operands"][0]["kind"] == "history_ref"]
    require(len(history) == 1, "The earlier endpoint must use the captured attempt-start predicate")
    captured = equations[history[0]["value"]]
    require(captured["value"] == "===" and [e["value"] for e in captured["operands"]] == ["q", "1'bx"]
            and captured["source"]["file"] == "first.sv" and captured["source"]["line"] == 9,
            "The sampled guard lost the original named-sequence predicate")
    return {"property": item["name"], "sample_paths": paths, "guard": guards[0]["value"],
            "captured_predicate": captured["source"]}


def audit_expression_cases(models, root, suites):
    inspected = []
    for relative, cases in EXPRESSION_CASES.items():
        if relative.split("/", 1)[0] not in suites:
            continue
        require(relative in models, f"Missing structural fixture: {relative}")
        digest, model = models[relative]
        clocked = relative in {"four-state-casex/sampled.q3a", "four-state-hierarchy/seq.q3a",
                               "four-state-sequential/sampled.q3a"}
        equations = {eq["target"]: eq for eq in model[
            "next_state_equations" if clocked else "combinational_equations"]}
        project_dir = (root / relative).parent
        source_lines = {}
        for target, expectations in cases.items():
            equation = equations[target]
            expression = equation["expression"]
            require(expression["width"] == equation["target_width"], f"Target width differs for {relative}/{target}")
            for path, kind, value, width, signed in expectations:
                node = expression
                for index in path:
                    node = node["operands"][index]
                detail = f"{relative}/{target}/{path}"
                require((node["kind"], node["value"], node["width"], node["signed"]) ==
                        (kind, value, width, signed), f"Unexpected typed expression: {detail}")
                source = node["source"]
                require(Path(source["file"]).name == source["file"], f"Unexpected fixture source: {detail}")
                if source["file"] not in source_lines:
                    source_lines[source["file"]] = (project_dir / source["file"]).read_text(
                        encoding="utf-8-sig").splitlines()
                lines = source_lines[source["file"]]
                line, column = source["line"], source["column"]
                require(1 <= line <= len(lines) and 1 <= column <= len(lines[line - 1]),
                        f"Invalid source position: {detail}")
                inspected.append({"manifest": relative, "model_sha256": digest, "target": target,
                                  "equation": "next-state" if clocked else "combinational",
                                  "operand_path": path, "kind": kind, "value": value,
                                  "bits": width, "signed": signed, "source": source})
    return inspected


def audit_history(model):
    equations = {eq["target"]: eq["expression"] for eq in model["next_state_equations"]}
    properties = {item["name"]: item for item in model["properties"]}
    initial = properties["p_initial"]["antecedent"]["terms"][0]["predicate"]
    pipeline = properties["p_pipeline"]["antecedent"]["terms"][0]["predicate"]
    first = pipeline["operands"][1]
    second = initial["operands"][0]
    require(first["kind"] == second["kind"] == "history_ref" and first["width"] == second["width"] == 2,
            "The history predicates lost the two-bit sampled value")
    require(first["value"] != second["value"] and
            equations[first["value"]]["value"] == "d" and
            equations[second["value"]]["value"] == first["value"],
            "The two-sample history must advance from the previous one-sample register")
    require(initial["value"] == "===" and initial["operands"][1]["value"] == "2'bxx" and
            initial["source"]["file"] == "history.sv" and initial["source"]["line"] == 4,
            "The startup history check lost its source location or unknown comparison")
    return {"source_signal": "d", "samples": [first["value"], second["value"]],
            "startup_comparison": initial["source"]}


def audit(archive, qualification_path):
    root = qualification_path.parent
    profile = read_json(qualification_path)
    require(profile["status"] == "DEVELOPMENT_PREVIEW_FUNCTIONAL_QUALIFICATION_PASSED",
            "Expected a completed package profile qualification")
    require(sha256(archive) == profile["archive_sha256"], "The archive digest differs")
    executable = (root / "extracted preview/prototype/bin/q3aformal-sourcecheck.exe").resolve()
    require(sha256(executable) == profile["executable_sha256"], "The executable digest differs")

    suites = []
    models = {}
    for entry in profile["suite_evidence"]:
        suite_record = root / entry["path"]
        folder = suite_record.parent
        if not folder.name.startswith("four-state-"):
            continue
        require(sha256(suite_record) == entry["sha256"], f"Changed suite record: {folder.name}")
        record = read_json(suite_record)
        require(record["status"].endswith("_QUALIFIED") and
                record["executable_sha256"] == profile["executable_sha256"],
                f"Suite was not qualified on this executable: {folder.name}")

        by_digest = {}
        for manifest in sorted(folder.glob("*.q3a")):
            exported = export_model(executable, manifest.resolve())
            if exported is None:
                continue
            digest, _ = exported
            models[manifest.relative_to(root).as_posix()] = exported
            by_digest.setdefault(digest, []).append(manifest.name)

        matched = []
        reports = sorted([*folder.glob("*.json"), *folder.glob("*.stdout.txt")])
        for path in reports:
            payload = path.read_text(encoding="utf-8-sig")
            if path.suffix == ".txt" and not payload.lstrip().startswith("{"):
                continue
            outcome = json.loads(payload)
            if not isinstance(outcome, dict) or outcome.get("status") not in QUERY_OUTCOMES:
                continue
            digest = outcome.get("model_sha256")
            require(digest in by_digest, f"Runtime model has no matching source export: {path}")
            matched.append({"report": path.name, "model_sha256": digest,
                            "manifests": by_digest[digest]})
        # The export-only suite records its two reference hashes in the ledger.
        if folder.name == "four-state-model-export":
            for key in ("sampled_model_sha256", "combinational_model_sha256"):
                digest = record[key]
                require(digest in by_digest, f"Unmatched model-export reference: {key}")
                matched.append({"report": key, "model_sha256": digest, "manifests": by_digest[digest]})
        require(matched, f"No source-bound query reports in {folder.name}")
        suites.append({"suite": folder.name, "matched_reports": matched})

    require(len(suites) == profile["four_state_suites"], "Four-state suite inventory differs")
    timing = []
    cases = [(relative, label, expected, Path(relative).with_suffix(".sv").name)
             for relative, label, expected in TIMING_CASES]
    if any(suite["suite"] == "four-state-named_sequence" for suite in suites):
        cases.append(NAMED_SEQUENCE_TIMING)
    for relative, label, expected, source_name in cases:
        digest, model = models[relative]
        item = next(prop for prop in model["properties"] if prop["name"] == label)
        actual = fixed_paths(item["antecedent"], source_name)
        require(actual == expected, f"Unexpected source-to-model timing: {relative}/{label}")
        timing.append({"manifest": relative, "property": label, "model_sha256": digest,
                       "sample_paths": actual})
    result = {
        "status": "FOUR_STATE_SOURCE_TO_MODEL_AUDIT_PASSED",
        "archive_sha256": profile["archive_sha256"],
        "build_id": profile["build_id"],
        "executable_sha256": profile["executable_sha256"],
        "suite_count": len(suites),
        "models_exported": len(models),
        "matched_reports": sum(len(suite["matched_reports"]) for suite in suites),
        "timing_cases": timing,
        "typed_expression_checks": audit_expression_cases(models, root, {suite["suite"] for suite in suites}),
        "suites": suites,
    }
    if any(suite["suite"] == "four-state-divide" for suite in suites):
        digest, model = models[DIVISION_MODEL]
        result["division_equations"] = {"manifest": DIVISION_MODEL, "model_sha256": digest,
                                        "equations": typed_division_equations(model)}
    if any(suite["suite"] == "four-state-history" for suite in suites):
        path = "four-state-history/history.q3a"
        digest, model = models[path]
        result["sampled_history"] = {"manifest": path, "model_sha256": digest, **audit_history(model)}
    if any(suite["suite"] == "four-state-first_match" for suite in suites):
        path = "four-state-first_match/first.q3a"
        digest, model = models[path]
        result["first_match_guard"] = {"manifest": path, "model_sha256": digest,
                                       **first_match_equations(model)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--qualification", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    result = audit(arguments.archive, arguments.qualification)
    with arguments.output.open("x", encoding="utf-8") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(f"Verified {result['matched_reports']} model identities, {len(result['timing_cases'])} timing cases "
          f"and {len(result['typed_expression_checks'])} typed expression nodes.")


if __name__ == "__main__":
    main()

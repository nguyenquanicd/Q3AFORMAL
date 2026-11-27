"""Unix command-line regression using the published RTL fixtures."""

from hashlib import sha256
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(sys.argv[1]).resolve()
CHECKER = Path(sys.argv[2]).resolve()
FIXTURES = ROOT / "prototype/benchmark/fixtures/phase2"


def run(*args, cwd, code=0, executable=SOURCE, env=None):
    result = subprocess.run([executable, *args], cwd=cwd, capture_output=True, text=True, timeout=60, env=env)
    if result.returncode != code:
        raise AssertionError(f"{args}\nExpected exit {code}, got {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def claim(*args, cwd, code=0, env=None):
    return json.loads(run(*args, cwd=cwd, code=code, env=env))


def baseline(cwd):
    fixtures = cwd / "examples"
    vectors = fixtures / "corpus/source-model-vectors"
    vectors.mkdir(parents=True)
    for name in ("pdr-pipeline", "pdr-cover", "four-state-cover"):
        shutil.copyfile(ROOT / "prototype" / (name + ".q3a"), fixtures / (name + ".q3a"))
        name = name.replace("-", "_") + ".sv"
        shutil.copyfile(ROOT / "prototype/corpus/source-model-vectors" / name, vectors / name)
    project = fixtures / "pdr-pipeline.q3a"
    proof = cwd / "proof"
    assert claim("prove", project, "--evidence-dir", proof, cwd=cwd)["status"] == "PROVEN"
    assert "Q3A_PDR_CERTIFICATE VERIFIED" in run(
        "verify-pdr", project, "--property", "p_safe", "--evidence-dir", proof, cwd=cwd)
    model = (proof / "invariant.txt").read_text().splitlines()[1]
    assert "Q3A_PROOF_CHECK ACCEPTED" in run(
        "--check-drat", proof / "safety.cnf", proof / "safety.q3adrat",
        "--model-sha256", model, "--query-kind", "pdr-safety", cwd=cwd, executable=CHECKER)
    cover = fixtures / "pdr-cover.q3a"
    witness = cwd / "witness"
    assert claim("prove", cover, "--engine", "pdr", "--property", "p_hit", "--evidence-dir",
                 cwd / "unused-proof", "--bundle-dir", witness, cwd=cwd)["status"] == "COVERED"
    assert "Q3A_BUNDLE_STATUS REVALIDATED" in run("--verify-bundle", witness, "--require-source-model", cwd=cwd)
    assert "<html" in run("debug", witness, cwd=cwd).lower()
    assert claim("prove", project, "--evidence-dir", cwd / "limited", cwd=cwd, code=1,
                 env=dict(os.environ, Q3A_MEMORY_RESERVE_MIB=str(1 << 30)))["status"] == "RESOURCE_LIMIT"
    cancel = cwd / "cancel"
    cancel.write_text("cancel\n")
    assert claim("prove", project, "--cancel-file", cancel, "--evidence-dir", cwd / "cancelled",
                 cwd=cwd, code=1)["status"] == "CANCELLED"

    four = fixtures / "four-state-cover.q3a"
    saved = cwd / "four-state"
    assert claim("dev-prove-four-state", four, "--property", "c_xz_then_zx", "--evidence-dir", saved,
                 "--steps", "1", cwd=cwd)["status"] == "COVERED"
    vcd = cwd / "four.vcd"
    replay = claim("dev-verify-four-state", four, "--property", "c_xz_then_zx", "--evidence-dir", saved,
                   "--steps", "1", "--vcd", vcd, cwd=cwd)
    assert replay["status"] == "COVERED" and replay["source_replayed"]
    assert claim("trace", "import-vcd", vcd, cwd=cwd)["four_state"]


def subsystem(cwd):
    frozen = json.loads((ROOT / "prototype/benchmark/phase2-subsystem-workloads.json").read_text())
    for filename, expected in frozen["fixture_sha256"].items():
        assert sha256((FIXTURES / filename).read_bytes()).hexdigest() == expected, filename
    workloads = {job["id"]: job for job in frozen["workloads"]}
    project = FIXTURES / "p2_transport_subsystem.q3a"
    for name, job in workloads.items():
        case_dir = cwd / name
        case_dir.mkdir()
        args = [piece.replace("{FIXTURES}", str(FIXTURES)).replace("{OUTPUT}", str(case_dir))
                for piece in job["arguments"]]
        result = claim(*args, cwd=cwd)
        assert result["status"] == job["expected_status"], name
        if name == "monolithic":
            assert "Q3A_BUNDLE_STATUS REVALIDATED" in run(
                "--verify-bundle", case_dir / "bundle", "--require-source-model", cwd=cwd)
        if name == "composed":
            reopened = claim("verify-composition", project, "--plan", FIXTURES / "p2_transport_subsystem.q3c",
                             "--evidence-dir", case_dir / "composition", cwd=cwd)
            assert reopened["status"] == "REVALIDATED" and reopened["checked_obligations"] == 9
        if name == "equivalence":
            reopened = claim("verify-equivalence", project, FIXTURES / "p2_transport_encoded.q3a",
                             "--plan", FIXTURES / "p2_transport_equivalence.q3e",
                             "--evidence-dir", case_dir / "equivalence", cwd=cwd)
            assert reopened["status"] == "CERTIFICATE_REVALIDATED"
        if name == "parallel-batch":
            assert result["peak_workers"] == 2
            resume = ["--resume" if arg == "--checkpoint" else arg for arg in args]
            reopened = claim(*resume, cwd=cwd)
            assert reopened["status"] == "COMPLETED" and all(item["reused"] for item in reopened["jobs"])


def project_from(cwd, top, rtl):
    (cwd / f"{top}.sv").write_text(rtl, encoding="utf-8")
    project = cwd / f"{top}.q3a"
    project.write_text(
        f'Q3AFORMAL_PROJECT 2\ntop {top}\nsource systemverilog "{top}.sv"\n', encoding="utf-8")
    return project


def extended(cwd):
    memory = project_from(cwd, "mem", """
module mem(input logic clk, re, we, input logic [1:0] ra, wa, din,
           output logic [1:0] dout);
    logic [1:0] words [3:0];
    always_ff @(posedge clk) begin
        if (re) dout <= words[ra];
        if (we) words[wa] <= din;
    end
    p_hold: assert property (@(posedge clk) !re |=> (dout == $past(dout)));
endmodule
""")
    saved = cwd / "memory-proof"
    assert claim("dev-prove-memory", memory, "--property", "p_hold", "--output-dir", saved,
                 "--max-cells", "4", cwd=cwd)["status"] == "PROVEN"
    assert claim("dev-verify-memory", memory, "--property", "p_hold", "--evidence-dir", saved,
                 "--max-cells", "4", cwd=cwd)["status"] == "REVALIDATED"
    events = project_from(cwd, "event_cli", """
module event_cli(input logic clk_a, clk_b, data, output logic x, y);
    always_ff @(posedge clk_a) begin x <= data; end
    always_ff @(posedge clk_b) begin y <= data; end
    c_hit: cover property (@(posedge clk_b) 1'b1);
endmodule
""")
    saved = cwd / "event-witness"
    assert claim("dev-check-events", events, "--property", "c_hit", "--output-dir", saved,
                 "--frames", "0", cwd=cwd)["status"] == "COVERED"
    reopened = claim("dev-verify-events", events, "--property", "c_hit", "--evidence-dir", saved, cwd=cwd)
    assert reopened["status"] == "REVALIDATED" and reopened["domain"] == "clk_b"
    liveness = project_from(cwd, "liveness_demo", """
module liveness_demo(input logic clk, request, grant, output logic response);
    logic active, pending;
    assign response = active && grant;
    assign active = pending || request;
    always_ff @(posedge clk) begin
        pending <= active && !grant;
    end
endmodule
""")
    args = ("dev-check-liveness", liveness, "--request", "request", "--response", "response")
    failed = claim(*args, cwd=cwd)
    fair = claim(*args, "--justice", "grant", cwd=cwd)
    assert failed["status"] == "VIOLATION" and failed["checked_graph_evidence"]
    assert fair["status"] == "NO_VIOLATION" and fair["checked_graph_evidence"]
    assert failed["model_sha256"] == fair["model_sha256"]


with tempfile.TemporaryDirectory(prefix="q3a-unix-Đồng-") as scratch:
    root = Path(scratch)
    assert len(claim("--version", cwd=root)["build_id"]) == 64
    baseline(root)
    subsystem(root)
    extended(root)
print("Unix CLI proof, DRAT, replay, HTML, limits frozen subsystem workloads and extended profiles passed.")

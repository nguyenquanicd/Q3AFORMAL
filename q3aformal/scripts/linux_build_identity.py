"""Generate Unix build identities from source bytes and compiler settings."""

from hashlib import sha256
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "prototype/source"
COMPONENTS = {
    "source_manager": SOURCE / "source_manager",
    "frontend": SOURCE / "frontend",
    "elaborator": SOURCE / "elaborator",
    "lowering_sva": SOURCE / "lowering",
    "sat_bit_blaster": SOURCE / "sat",
    "witness_replay": SOURCE / "replay",
    "proof_checker": ROOT / "prototype/checker",
    "result_bundle": SOURCE / "bundle",
    "proof_cache": SOURCE / "cache",
    "explicit_liveness": SOURCE / "liveness",
    "four_state": SOURCE / "four_state",
}


def fingerprint(directory):
    files = sorted(p for p in directory.rglob("*") if p.suffix in {".cpp", ".hpp", ".inc"})
    records = (f"{p.relative_to(ROOT).as_posix()}\t{sha256(p.read_bytes()).hexdigest()}\n" for p in files)
    return sha256("".join(records).encode()).hexdigest()


def main():
    output, compiler, configuration = sys.argv[1:]
    components = {f"kComponentHash_{name}": fingerprint(path) for name, path in COMPONENTS.items()}
    values = {"kCompiler": compiler, "kBuildConfiguration": Path(configuration).read_text(), **components}
    provenance = sha256((ROOT / "CMakeLists.txt").read_bytes() + Path(__file__).read_bytes()).hexdigest()
    values["kBuildId"] = sha256(json.dumps([provenance, values], sort_keys=True).encode()).hexdigest()
    declarations = "".join(f"inline constexpr char {name}[] = {json.dumps(value)};\n" for name, value in values.items())
    Path(output).write_text("#pragma once\nnamespace q3a::build_info {\n" + declarations + "}\n", encoding="utf-8")


if __name__ == "__main__":
    main()

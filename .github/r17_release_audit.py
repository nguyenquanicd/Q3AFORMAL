"""Test the public R17 Preview assets in a fresh installation."""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
from urllib.request import Request, urlopen

RELEASE = "https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview"
WINDOWS = platform.system() == "Windows"
ROOT = Path.cwd() / "r17-audit"
DOWNLOADS = ROOT / "downloads"
EVIDENCE = ROOT / "evidence"
INSTALL = ROOT / "installed"
PROGRAM = INSTALL / "prototype/bin" / ("q3aformal-sourcecheck.exe" if WINDOWS else "q3aformal-sourcecheck")
VCD = """$date Test fixture $end
$version Q3AFORMAL release audit $end
$timescale 1ns $end
$scope module audit $end
$var wire 1 ! clk $end
$upscope $end
$enddefinitions $end
#0
$dumpvars
0!
$end
#5
1!
#10
0!
"""


def run(name, command, cwd=INSTALL):
    result = subprocess.run(command, cwd=cwd, capture_output=True, timeout=90, check=False)
    (EVIDENCE / f"{name}.stdout").write_bytes(result.stdout)
    (EVIDENCE / f"{name}.stderr").write_bytes(result.stderr)
    if result.returncode:
        raise RuntimeError(f"{name} exited {result.returncode}: {result.stderr.decode(errors='replace')}")
    return result.stdout


def browser():
    if WINDOWS:
        for key in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
            root = os.environ.get(key)
            if root:
                chrome = Path(root) / "Google/Chrome/Application/chrome.exe"
                if chrome.is_file():
                    return str(chrome)
    return next(path for name in ("google-chrome", "chromium", "chromium-browser")
                if (path := shutil.which(name)))


def render(name, page):
    chrome = browser()
    args = [chrome, "--headless", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
            "--disable-background-networking", f"--user-data-dir={ROOT / (name + '-chrome')}",
            "--no-first-run", "--dump-dom", page.as_uri()]
    dom = run(name, args)
    if name == "cover-browser":
        assert re.search(rb'<path[^>]*class="wave"', dom), "Missing rendered cover signal path"
        assert re.search(rb'<line[^>]*class="witness"', dom), "Missing rendered cover marker"
    else:
        assert b'<option value="0">audit.clk</option>' in dom, "Missing VCD signal"
        ticks = re.findall(rb'<div class="tick[^"]*"><span title="([0-9]+)">.*?</span>'
                           rb'<span class="bits (low|high)" title="[01]">[01]</span></div>', dom)
        assert ticks == [(b"0", b"low"), (b"5", b"high"), (b"10", b"low")], ticks


def main():
    DOWNLOADS.mkdir(parents=True)
    EVIDENCE.mkdir()
    machine = platform.machine().lower()
    assert machine in ("amd64", "x86_64")
    if not WINDOWS:
        assert platform.system() == "Linux" and "microsoft" not in platform.release().lower()
        assert not any(name.startswith("WSL_") for name in os.environ)
        print("Linux virtualization:", run("virtualization", ["systemd-detect-virt"], ROOT).decode().strip())
    print("Host:", platform.platform(), machine)
    archive = "q3aformal-windows-x64-development-preview-r16.zip" if WINDOWS else "q3aformal-linux-x64.tar.gz"
    hashes = {}
    for name in ("install.py", "INSTALL_SHA256SUMS", archive):
        request = Request(f"{RELEASE}/{name}", headers={"User-Agent": "Q3AFORMAL-public-release-audit"})
        with urlopen(request, timeout=50) as response:
            data = response.read()
        (DOWNLOADS / name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
        print(f"Downloaded {name} {len(data)} bytes SHA-256 {hashes[name]}")
    assert f"{hashes[archive]}  {archive}" in (DOWNLOADS / "INSTALL_SHA256SUMS").read_text().splitlines()
    run("install", [sys.executable, "install.py", "--prefix", INSTALL], DOWNLOADS)
    version = json.loads(run("version", [PROGRAM, "--version"]))
    safe = json.loads(run("safety", [PROGRAM, "prove", "prototype/pdr-pipeline.q3a",
                                     "--evidence-dir", "safety-proof"]))
    assert safe["status"] == "PROVEN"
    assert b"Q3A_PDR_CERTIFICATE VERIFIED" in run("verify-pdr", [PROGRAM, "verify-pdr", "prototype/pdr-pipeline.q3a",
                                                              "--property", "p_safe", "--evidence-dir", "safety-proof"])
    cover = json.loads(run("cover", [PROGRAM, "prove", "prototype/pdr-cover.q3a", "--engine", "pdr",
                                      "--property", "p_hit", "--evidence-dir", "cover-proof",
                                      "--bundle-dir", "cover-witness"]))
    assert cover["status"] == "COVERED"
    verified = run("verify-bundle", [PROGRAM, "--verify-bundle", "cover-witness", "--require-source-model"])
    assert b"Q3A_BUNDLE_SOURCE_MODEL VERIFIED" in verified and b"Q3A_BUNDLE_STATUS REVALIDATED" in verified
    if WINDOWS:
        run("native", [PROGRAM, "--qualify-native-gui", "cover-witness", EVIDENCE / "native-session.json"])
        native = json.loads((EVIDENCE / "native-session.json").read_text(encoding="utf-8"))
        manifest_hash = hashlib.sha256((INSTALL / "cover-witness/manifest.json").read_bytes()).hexdigest()
        assert native["schema"] == 2 and native["key"] == f"q3a-debug:{manifest_hash}:bounded"
        assert native["signals"] and native["source"]["file"] and len(native["markers"]) == 1
        print("Windows native GUI smoke passed")
    cover_page = EVIDENCE / "cover-witness.html"
    cover_page.write_bytes(run("cover-html", [PROGRAM, "debug", "cover-witness"]))
    (ROOT / "input.vcd").write_text(VCD, encoding="ascii")
    vcd_page = EVIDENCE / "input.html"
    vcd_page.write_bytes(run("vcd-html", [PROGRAM, "trace", "view-vcd", ROOT / "input.vcd"]))
    render("cover-browser", cover_page)
    render("vcd-browser", vcd_page)
    (EVIDENCE / "verdict.json").write_text(json.dumps({
        "status": "PASSED", "host": platform.platform(), "hashes": hashes, "build_id": version["build_id"],
        "safety": safe["status"], "cover": cover["status"], "source_bundle": "REVALIDATED",
        "browser_cover_waveform": "RENDERED", "browser_vcd_waveform": "RENDERED",
        "windows_native_gui": "PASSED" if WINDOWS else None,
    }, indent=2), encoding="utf-8")
    print("PASS: installer, examples, verified bundle, and both rendered waveforms")


if __name__ == "__main__":
    main()

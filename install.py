"""Install the verified Q3AFORMAL archive for the current OS and CPU."""

import argparse
from hashlib import sha256
from pathlib import Path, PurePosixPath, PureWindowsPath
import os
import platform
import re
import shutil
import stat
import sys
import tarfile
import tempfile
import zipfile

ASSETS = {
    "Windows": "q3aformal-windows-x64-development-preview-r16.zip",
    "Linux": "q3aformal-linux-x64.tar.gz",
}
DEFAULT_ASSETS = Path(__file__).resolve().parent / "q3aformal/dist"


def select_archive(system, machine):
    if system not in ASSETS or machine.lower() not in {"amd64", "x86_64"}:
        raise ValueError(f"No qualified package is available for {system} {machine}")
    return ASSETS[system]


def checked_path(name):
    path = PurePosixPath(name)
    windows = PureWindowsPath(name)
    if path.is_absolute() or windows.drive or not path.parts or "\\" in name or ".." in path.parts:
        raise ValueError(f"Unsafe archive member {name!r}")
    if any(not re.fullmatch(r"[A-Za-z0-9_.+ -]+", component) or component.endswith((".", " "))
           or PureWindowsPath(component).is_reserved() for component in path.parts):
        raise ValueError(f"Unsupported archive name {name!r}")
    return path


def extract(archive, filename, destination, system):
    seen = set()
    is_zip = filename.endswith(".zip")
    package = zipfile.ZipFile(archive) if is_zip else tarfile.open(fileobj=archive, mode="r:gz")
    with package:
        for member in package.infolist() if is_zip else package:
            name = member.filename if is_zip else member.name
            if name in (".", "./") and not is_zip and member.isdir():
                continue
            path = checked_path(name)
            key = path.as_posix().casefold() if system == "Windows" else path.as_posix()
            if key in seen:
                raise ValueError(f"Duplicate archive path {name!r}")
            seen.add(key)
            out = destination.joinpath(*path.parts)
            mode = stat.S_IFMT(member.external_attr >> 16) if is_zip else 0
            is_directory = member.is_dir() if is_zip else member.isdir()
            if (is_zip and mode not in {0, stat.S_IFREG, stat.S_IFDIR}) or (
                    not is_zip and not (is_directory or member.isfile())):
                raise ValueError(f"Unsupported archive member type for {name!r}")
            if is_directory:
                out.mkdir(parents=True, exist_ok=True)
                continue
            out.parent.mkdir(parents=True, exist_ok=True)
            with (package.open(member) if is_zip else package.extractfile(member)) as source:
                with out.open("xb") as target:
                    shutil.copyfileobj(source, target)
    suffix = ".exe" if system == "Windows" else ""
    for name in ("q3aformal-sourcecheck", "q3aformal-proofcheck"):
        executable = destination / "prototype/bin" / (name + suffix)
        if not executable.is_file():
            raise ValueError(f"Missing executable {executable.name}")
        if system == "Linux":
            executable.chmod(0o755)


def install(system, filename, assets, destination):
    manifest = assets / "INSTALL_SHA256SUMS"
    entries = {}
    for line in manifest.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([a-fA-F0-9]{64})  ([A-Za-z0-9_.-]+)", line)
        if not match or match[2] in entries:
            raise ValueError("Invalid or duplicate checksum entry")
        entries[match[2]] = match[1].lower()
    if filename not in entries:
        raise ValueError(f"Missing checksum for {filename}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock = destination.with_name(destination.name + ".install.lock")
    lock.touch(exist_ok=False)
    try:
        if os.path.lexists(destination):
            raise FileExistsError(f"Install destination already exists: {destination}")
        with (assets / filename).open("rb") as archive:
            fingerprint = sha256()
            for chunk in iter(lambda: archive.read(1024 * 1024), b""):
                fingerprint.update(chunk)
            if fingerprint.hexdigest() != entries[filename]:
                raise ValueError(f"Checksum mismatch for {filename}")
            archive.seek(0)
            with tempfile.TemporaryDirectory(prefix=".q3a-install-", dir=destination.parent) as work:
                payload = Path(work) / "payload"
                payload.mkdir()
                extract(archive, filename, payload, system)
                payload.rename(destination)
    finally:
        lock.unlink()
    return destination / "prototype/bin" / ("q3aformal-sourcecheck.exe" if system == "Windows" else "q3aformal-sourcecheck")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets-dir", type=Path, default=DEFAULT_ASSETS)
    parser.add_argument("--prefix", type=Path, help="New installation directory")
    args = parser.parse_args()
    system = platform.system()
    try:
        filename = select_archive(system, platform.machine())
        if system == "Windows":
            default = Path(os.getenv("LOCALAPPDATA") or Path.home() / "AppData/Local") / "Q3AFORMAL"
        else:
            default = Path.home() / ".local/opt/q3aformal"
        destination = (args.prefix or default).expanduser().absolute()
        executable = install(system, filename, args.assets_dir, destination)
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Q3AFORMAL installation failed: {error}\n")
    print(f"Installed {filename}")
    print(f"Run {executable} --version")


if __name__ == "__main__":
    main()

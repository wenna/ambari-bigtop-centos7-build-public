"""Assemble checked, locally downloaded release assets into a new yum repository."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def checked_packages(directory):
    manifests = [p for p in directory.iterdir() if p.name in
                 {"SHA256SUMS", "AMBARI-SHA256SUMS", "HADOOP-SHA256SUMS"}]
    if len(manifests) != 1:
        raise ValueError(f"Expected exactly one release checksum manifest in {directory}")
    entries = {}
    for line in manifests[0].read_text().splitlines():
        digest, raw_name = line.split(maxsplit=1)
        if not raw_name.endswith(".rpm"):
            continue
        if not re.fullmatch(r"[a-zA-Z0-9_.+~-]+\.rpm", raw_name) or raw_name in entries:
            raise ValueError(f"Unexpected or duplicate RPM name: {raw_name}")
        if not re.fullmatch(r"[a-fA-F0-9]{64}", digest):
            raise ValueError(f"Invalid SHA-256 for {raw_name}")
        entries[raw_name] = digest.lower()
    if not entries or set(entries) != {p.name for p in directory.glob("*.rpm")}:
        raise ValueError(f"Missing or unlisted RPM in {directory}")
    for name, expected in entries.items():
        source = directory / name
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Not a regular file: {source}")
        digest = hashlib.sha256()
        with source.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError(f"Checksum mismatch: {source}")
        yield source, expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("release_dirs", type=Path, nargs="+")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output must be a new directory")
    tool = shutil.which("createrepo_c") or shutil.which("createrepo")
    if not tool:
        parser.error("Install createrepo_c or createrepo")
    output = args.output.resolve()
    seen = {}
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        stage = Path(temp) / "repo"
        stage.mkdir()
        for directory in args.release_dirs:
            for source, digest in checked_packages(directory):
                if source.name.endswith((".src.rpm", ".nosrc.rpm")):
                    continue
                if source.name in seen:
                    if seen[source.name] != digest:
                        raise ValueError(f"Conflicting builds of {source.name}; select one release source for this RPM")
                    continue
                shutil.copyfile(source, stage / source.name)
                seen[source.name] = digest
        if not seen:
            parser.error("No binary RPMs")
        subprocess.run([tool, str(stage)], check=True)
        if not (stage / "repodata/repomd.xml").is_file():
            raise RuntimeError("Missing yum metadata")
        (stage / "SHA256SUMS").write_text("".join(f"{seen[n]}  {n}\n" for n in sorted(seen)))
        os.rename(stage, output)
    print(f"{len(seen)} binary RPMs in {output}")


if __name__ == "__main__":
    main()

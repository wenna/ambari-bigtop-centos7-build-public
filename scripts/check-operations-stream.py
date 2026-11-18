"""Check the published partition layout from a concatenated tar stream."""
import hashlib
import sys
import tarfile
from pathlib import PurePosixPath

def digest(stream):
    hasher = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        hasher.update(block)
    return hasher.hexdigest()

actual = {}
expected = {}
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as archive:
    for entry in archive:
        path = PurePosixPath(entry.name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("Unexpected archive path: " + entry.name)
        if entry.isdir():
            continue
        name = str(path)
        if not entry.isfile() or name in actual:
            raise ValueError("Unexpected entry: " + name)
        stream = archive.extractfile(entry)
        if name == "SHA256SUMS":
            if expected:
                raise ValueError("Duplicate manifest")
            for line in stream.read().decode().splitlines():
                value, filename = line.split("  ", 1)
                expected[str(PurePosixPath(filename))] = value
        else:
            actual[name] = digest(stream)
if actual != expected or not expected:
    raise ValueError("Archive files or checksums differ from the delivery manifest")
for directory, count in (("yum-staging/", 60), ("runtime-repo/", 283)):
    found = sum(n.startswith(directory) and n.endswith(".rpm") for n in expected)
    if found != count:
        raise ValueError("{} contains {} RPMs".format(directory, found))
print("Verified all {} files, including 60 application and 283 runtime RPMs".format(len(actual)))

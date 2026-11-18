"""Validate every RPM in a downloaded artifact before copying any for installation."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import shutil


def verify_bundle(root):
    root = Path(root)
    manifest = {}
    for row in (root / 'SHA256SUMS').read_text().splitlines():
        digest, raw_path = row.split(maxsplit=1)
        name = PurePosixPath(raw_path.strip()).name
        if not re.fullmatch(r'[0-9a-fA-F]{64}', digest) or not name.endswith('.rpm') or name in manifest:
            raise ValueError('Invalid or duplicate RPM checksum record')
        manifest[name] = digest.lower()
    files = list((root / 'rpms').rglob('*.rpm'))
    if not files or len(files) != len(manifest) or {p.name for p in files} != set(manifest):
        raise ValueError('RPM inventory does not match checksum manifest')
    for path in files:
        if path.is_symlink():
            raise ValueError('Symbolic links are not accepted as RPM artifacts')
        digest = hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != manifest[path.name]:
            raise ValueError('RPM checksum mismatch: ' + path.name)
    return sorted(files)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('bundle')
    parser.add_argument('--copy-to')
    options = parser.parse_args()
    packages = verify_bundle(options.bundle)
    if options.copy_to:
        target = Path(options.copy_to)
        if target.exists() and any(target.iterdir()):
            raise ValueError('Copy destination must be empty to prevent stale unverified packages')
        target.mkdir(parents=True, exist_ok=True)
        for package in packages:
            shutil.copy2(package, target / package.name)
    print(f'Verified all {len(packages)} RPM/SRPM files')

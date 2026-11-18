"""Inspect registry metadata without pulling the large build image."""
import json
from pathlib import Path
import shutil
import sys


def compressed_bytes(manifest):
    if isinstance(manifest, list):
        matches = [item for item in manifest if item.get('Descriptor', {}).get('platform', {})
                   == {'architecture': 'amd64', 'os': 'linux'}]
        # Platform descriptors may also include variant or OS metadata.
        if not matches:
            matches = [item for item in manifest
                       if item.get('Descriptor', {}).get('platform', {}).get('architecture') == 'amd64'
                       and item.get('Descriptor', {}).get('platform', {}).get('os') == 'linux']
        if len(matches) != 1:
            raise ValueError('Exactly one linux/amd64 manifest is required')
        return compressed_bytes(matches[0])
    payload = manifest.get('SchemaV2Manifest') or manifest.get('OCIManifest') or manifest
    layers = payload.get('layers')
    if not layers or any(not isinstance(layer.get('size'), int) or layer['size'] < 0 for layer in layers):
        raise ValueError('Manifest does not contain valid layer sizes')
    return sum(layer['size'] for layer in layers)


if __name__ == '__main__':
    manifest = json.loads(Path(sys.argv[1]).read_text())
    compressed = compressed_bytes(manifest)
    free = shutil.disk_usage(Path.cwd()).free
    print(json.dumps({
        'image': 'bigtop/slaves:3.3.0-centos-7',
        'compressed_layer_bytes': compressed,
        'compressed_layer_gib': round(compressed / 1024**3, 2),
        'free_disk_gib': round(free / 1024**3, 2),
        'expanded_size': 'unknown; compressed size is not installed size',
        'compressed_exceeds_free_disk': compressed >= free,
        'full_image_pull_attempted': False,
    }, indent=2))

import importlib.util
from pathlib import Path
import unittest


class ImageCapacityTests(unittest.TestCase):
    def parse(self, manifest):
        path = Path(__file__).parents[1] / 'scripts' / 'image_capacity.py'
        self.assertTrue(path.is_file(), 'image capacity implementation is missing')
        spec = importlib.util.spec_from_file_location('image_capacity', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.compressed_bytes(manifest)

    def test_single_arch_manifest(self):
        self.assertEqual(self.parse({'SchemaV2Manifest': {'layers': [{'size': 50}, {'size': 70}]}}), 120)

    def test_select_only_linux_amd64(self):
        entries = [
            {'Descriptor': {'platform': {'os': 'linux', 'architecture': 'arm64'}},
             'SchemaV2Manifest': {'layers': [{'size': 800}]}},
            {'Descriptor': {'platform': {'os': 'linux', 'architecture': 'amd64'}},
             'SchemaV2Manifest': {'layers': [{'size': 200}]}},
        ]
        self.assertEqual(self.parse(entries), 200)

    def test_unrecognized_manifest_does_not_claim_zero_size(self):
        with self.assertRaises(ValueError):
            self.parse({'unknown': True})


if __name__ == '__main__':
    unittest.main()

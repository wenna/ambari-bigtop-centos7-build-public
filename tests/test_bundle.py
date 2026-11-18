import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


class BundleTests(unittest.TestCase):
    def verify(self, root):
        path = Path(__file__).parents[1] / 'scripts' / 'verify_bundle.py'
        self.assertTrue(path.is_file(), 'bundle verifier is missing')
        spec = importlib.util.spec_from_file_location('verify_bundle', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.verify_bundle(root)

    def fixture(self, root):
        (root / 'rpms').mkdir()
        data = b'fixture package'
        (root / 'rpms' / 'package.rpm').write_bytes(data)
        (root / 'SHA256SUMS').write_text(hashlib.sha256(data).hexdigest() + '  artifacts/rpms/package.rpm\n')

    def test_valid_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.assertEqual([p.name for p in self.verify(root)], ['package.rpm'])

    def test_unlisted_package_is_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / 'rpms' / 'unlisted.rpm').write_bytes(b'extra')
            with self.assertRaises(ValueError):
                self.verify(root)

    def test_modified_package_is_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / 'rpms' / 'package.rpm').write_bytes(b'modified')
            with self.assertRaises(ValueError):
                self.verify(root)


if __name__ == '__main__':
    unittest.main()

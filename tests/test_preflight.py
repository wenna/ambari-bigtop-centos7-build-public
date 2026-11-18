import importlib.util
from pathlib import Path
import unittest


class ResourceGateTests(unittest.TestCase):
    def assess(self, **changes):
        module_path = Path(__file__).parents[1] / 'scripts' / 'preflight.py'
        self.assertTrue(module_path.is_file(), 'preflight implementation is missing')
        spec = importlib.util.spec_from_file_location('preflight', module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        values = dict(system='Linux', arch='x86_64', cpus=4, memory_gib=16, free_disk_gib=20)
        values.update(changes)
        return module.assess_resources(**values)

    def test_small_machine_allows_probe_but_not_full_stack(self):
        result = self.assess()
        self.assertTrue(result['probe_ready'])
        self.assertFalse(result['full_stack_recommended'])

    def test_wrong_architecture_is_blocked(self):
        self.assertFalse(self.assess(arch='aarch64')['probe_ready'])

    def test_insufficient_disk_is_blocked(self):
        self.assertFalse(self.assess(free_disk_gib=7)['probe_ready'])

    def test_windows_is_blocked(self):
        self.assertFalse(self.assess(system='Windows')['probe_ready'])


if __name__ == '__main__':
    unittest.main()

import importlib.util
from pathlib import Path
import unittest


class QuorumEvidenceTests(unittest.TestCase):
    def classify(self, replies):
        path = Path(__file__).parents[1] / 'scripts' / 'verify_zk_quorum.py'
        self.assertTrue(path.is_file(), 'quorum verifier is missing')
        spec = importlib.util.spec_from_file_location('verify_zk_quorum', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.is_quorum(replies)

    def test_one_leader_and_two_followers(self):
        self.assertTrue(self.classify(['Mode: leader\n', 'Mode: follower\n', 'Mode: follower\n']))

    def test_three_standalone_servers_are_not_a_quorum(self):
        self.assertFalse(self.classify(['Mode: standalone\n'] * 3))

    def test_missing_follower_or_duplicate_leader_is_not_healthy(self):
        self.assertFalse(self.classify(['Mode: leader\n', '', 'Mode: follower\n']))
        self.assertFalse(self.classify(['Mode: leader\n', 'Mode: leader\n']))


if __name__ == '__main__':
    unittest.main()

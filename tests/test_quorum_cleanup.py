import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import call, patch


class CleanupTests(unittest.TestCase):
    def test_log_timeout_still_removes_all_own_containers(self):
        source = Path(__file__).parents[1] / 'scripts' / 'verify_zk_quorum.py'
        spec = importlib.util.spec_from_file_location('quorum_cleanup', source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        prefix = 'zk-probe-' + 'a' * 12
        nodes = [prefix + '-' + str(n) for n in range(1, 4)]
        snapshots = [{nodes[0]: 'Mode: leader', nodes[1]: 'Mode: follower', nodes[2]: 'Mode: follower'},
                     {nodes[1]: 'Mode: leader', nodes[2]: 'Mode: follower'}]
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(module.Path, 'cwd', return_value=Path(directory)), \
                 patch.object(module.uuid, 'uuid4', return_value=SimpleNamespace(hex='a' * 32)), \
                 patch.object(module, 'command', return_value='') as command, \
                 patch.object(module, 'wait_quorum', side_effect=snapshots), \
                 patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired('docker logs', 20)), \
                 contextlib.redirect_stdout(io.StringIO()):
                module.main()
                for node in nodes:
                    self.assertIn(call(['docker', 'rm', '-f', node], timeout=30), command.call_args_list)
                self.assertIn(call(['docker', 'network', 'rm', prefix]), command.call_args_list)


if __name__ == '__main__':
    unittest.main()

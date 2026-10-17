import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'launch.py'
spec = importlib.util.spec_from_file_location('dsh_supervisor', MODULE)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)
REPO = MODULE.parents[2]


class SupervisorTests(unittest.TestCase):
    def test_corrupt_state_fails_closed(self):
        with self.assertRaises(ValueError):
            launcher.health({'schema':0}, 0, 100)

    def test_blocked_checkpoint_stops_supervisor(self):
        problem = launcher.health({'schema':1,'sessions':{'s':{'phase':'blocked','checkpoint':'cp1'}}},0,100)
        self.assertIn('cp1',problem)

    def test_normal_state_is_healthy(self):
        self.assertIsNone(launcher.health({'schema':1,'sessions':{}},0,100))

    def test_rotating_diagnostics_preserve_full_session_logs(self):
        with tempfile.TemporaryDirectory(dir=REPO / '.tmp') as tmp:
            root = Path(tmp)
            original = root / 'session.jsonl'
            original.write_text('scientific decision\n')
            log = root / 'supervisor.jsonl'
            for index in range(7):
                log.write_text(str(index) * 100)
                launcher.rotate(log,limit=50)
            self.assertEqual(original.read_text(),'scientific decision\n')
            self.assertEqual((root / 'supervisor.jsonl.1').read_text(),'6'*100)
            self.assertEqual(len(list(root.glob('supervisor.jsonl.*'))),4)


if __name__ == '__main__':
    unittest.main()

class GlobalSupervisorTests(unittest.TestCase):
    def test_corrupt_persistence_terminates_child_and_does_not_replay_headless(self):
        from unittest.mock import patch, Mock
        import sys
        spec = importlib.util.spec_from_file_location('global_supervisor', MODULE.parent / 'global-supervisor.py')
        global_launcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(global_launcher)
        with tempfile.TemporaryDirectory(dir=REPO / '.tmp') as tmp:
            root = Path(tmp)
            child = Mock()
            child.returncode = None
            child.poll.side_effect = lambda: child.returncode
            child.terminate.side_effect = lambda: setattr(child, 'returncode', -15)
            child.wait.return_value = -15
            def corrupt(_):
                (root / 'state.json').write_text('{')
            with patch.object(global_launcher,'ROOT',root), \
                 patch.object(global_launcher,'INSTALLED',Path.home() / '.local/share/deepseek-harness'), \
                 patch.object(global_launcher.subprocess,'run'), \
                 patch.object(global_launcher.subprocess,'Popen',return_value=child) as spawn, \
                 patch.object(global_launcher.time,'sleep',side_effect=corrupt), \
                 patch.object(global_launcher.signal,'signal'), \
                 patch.object(sys,'argv',['global-supervisor','original-dsh','--profile','headless','--task','task']):
                result = global_launcher.main()
            self.assertEqual(result,-15)
            self.assertEqual(spawn.call_count,1)
            child.terminate.assert_called_once()

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
                 patch.object(global_launcher,'select_instance',return_value=(root,['--profile','headless','--task','task'],False)), \
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


class InstanceIsolationTests(unittest.TestCase):
    def setUp(self):
        spec=importlib.util.spec_from_file_location('instance_supervisor',MODULE.parent/'global-supervisor.py')
        self.launcher=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.launcher)

    def test_only_immediate_native_tui_handoff_reuses_state(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            root=Path(tmp)
            (root/'state.json').write_text('{"schema":1,"sessions":{}}')
            env={'DSH_WATCHDOG_SUPERVISED':'1','DSH_WATCHDOG_ROOT':str(root),
                 'DSH_TUI_SESSION_ROOT':str(root/'sessions')}
            package=Path.home()/'.dsh/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui'
            for suffix in ['bin/dsh-tui.js','lib/types/dsh-adapter/host-entry.js']:
                with patch.object(self.launcher.subprocess,'check_output',return_value=f'/opt/homebrew/bin/node {package/suffix} --profile dsh-tui'):
                    self.assertTrue(self.launcher.internal_handoff('123',env))
            for command in ['/bin/zsh',f'/bin/zsh -c "node {package}/bin/dsh-tui.js"',
                            '/opt/homebrew/bin/node /some/user-script.js',
                            f'/opt/homebrew/bin/node /outside/dsh-tui/bin/dsh-tui.js']:
                with patch.object(self.launcher.subprocess,'check_output',return_value=command):
                    self.assertFalse(self.launcher.internal_handoff('123',env))
            self.assertFalse(self.launcher.internal_handoff('123',{}))
            self.assertFalse(self.launcher.internal_handoff('123',{**env,'DSH_TUI_SESSION_ROOT':'stale'}))

    def test_new_launches_do_not_touch_blocked_legacy_or_each_other(self):
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            base=Path(tmp)/'.dsh-watchdog'
            base.mkdir()
            old={'schema':1,'sessions':{'old':{'phase':'blocked','checkpoint':'retained'}}}
            state=base/'state.json'
            state.write_text(json.dumps(old))
            first,args,fresh=self.launcher.select_instance(base,['--model','model-a'])
            (first/'state.json').write_text(json.dumps(old))
            second,args2,fresh2=self.launcher.select_instance(base,['--model','model-b'])
            self.assertNotEqual(first,second)
            self.assertTrue(fresh and fresh2)
            self.assertEqual(args,['--model','model-a'])
            self.assertEqual(args2,['--model','model-b'])
            self.assertEqual(json.loads(state.read_text()),old)
            self.assertEqual(json.loads((first/'state.json').read_text()),old)

    def test_explicit_resume_selects_existing_instance_and_preserves_recovery_gate(self):
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            base=Path(tmp)
            first,_,_=self.launcher.select_instance(base,[])
            (first/'state.json').write_text('{"schema":1,"sessions":{"old":{"phase":"blocked"}}}')
            selected,args,fresh=self.launcher.select_instance(base,['--watchdog-resume',first.name,'--model','local'])
            self.assertEqual(selected,first)
            self.assertFalse(fresh)
            self.assertEqual(args,['--model','local'])
            self.assertEqual(json.loads((selected/'state.json').read_text())['sessions']['old']['phase'],'blocked')
            (base/'state.json').write_text('{"schema":1,"sessions":{}}')
            self.assertEqual(self.launcher.select_instance(base,['--watchdog-resume=legacy'])[0],base)

    def test_resume_typos_and_paths_never_initialize_empty_state(self):
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            for args in [['--watchdog-resume'],['--watchdog-resume=../escape'],
                         ['--watchdog-resume=00000000-0000-0000-0000-000000000000'],
                         ['--watchdog-resume=legacy','--watchdog-resume=legacy']]:
                with self.assertRaises(ValueError):self.launcher.select_instance(Path(tmp),args)

    def test_startup_ignores_other_instances_but_explicit_resume_still_blocks(self):
        from unittest.mock import patch, Mock
        import sys
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            base=Path(tmp)/'.dsh-watchdog'
            base.mkdir()
            legacy='{"schema":1,"currentSession":"s","sessions":{"s":{"phase":"blocked","checkpoint":"old-cp"}}}'
            (base/'state.json').write_text(legacy)
            child=Mock(returncode=0)
            child.poll.return_value=0
            roots=[]
            for model in ['model-a','model-b']:
                with patch.object(self.launcher,'ROOT',base), \
                     patch.object(self.launcher,'INSTALLED',Path.home()/'.local/share/deepseek-harness'), \
                     patch.object(self.launcher.subprocess,'run'), \
                     patch.object(self.launcher.subprocess,'Popen',return_value=child) as spawn, \
                     patch.object(self.launcher.signal,'signal'), \
                     patch.dict(self.launcher.os.environ,{'DSH_TUI_RESUME_SESSION':'stale'}), \
                     patch.object(sys,'argv',['supervisor','original-dst','--model',model]):
                    self.assertEqual(self.launcher.main(),0)
                    self.assertEqual(spawn.call_args.args[0],['original-dst','--model',model])
                    env=spawn.call_args.kwargs['env']
                    self.assertNotIn('DSH_TUI_RESUME_SESSION',env)
                    root=Path(env['DSH_WATCHDOG_ROOT'])
                    self.assertEqual(env['DSH_TUI_SESSION_ROOT'],str(root/'sessions'))
                    self.assertTrue((root/'progress.md').is_file())
                    roots.append(root)
                    (root/'state.json').write_text(legacy)
            self.assertNotEqual(*roots)
            self.assertEqual((base/'state.json').read_text(),legacy)
            with patch.object(self.launcher,'ROOT',base), \
                 patch.object(self.launcher,'INSTALLED',Path.home()/'.local/share/deepseek-harness'), \
                 patch.object(self.launcher.subprocess,'run'), \
                 patch.object(self.launcher.subprocess,'Popen') as spawn, \
                 patch.object(sys,'argv',['supervisor','original-dst','--watchdog-resume',roots[0].name]):
                with self.assertRaisesRegex(SystemExit,'old-cp'):self.launcher.main()
                spawn.assert_not_called()

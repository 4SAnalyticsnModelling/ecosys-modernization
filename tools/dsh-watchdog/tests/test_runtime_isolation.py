import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE=Path(__file__).resolve().parents[1]
REPO=MODULE.parents[1]
sys.path.insert(0,str(MODULE))
import isolation
spec=importlib.util.spec_from_file_location('isolated_supervisor',MODULE/'global-supervisor.py')
supervisor=importlib.util.module_from_spec(spec);spec.loader.exec_module(supervisor)

class RuntimeIsolationTests(unittest.TestCase):
    def test_private_environment_never_reuses_inherited_caches(self):
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            a=isolation.private_env(Path(tmp)/'a',{'TMPDIR':'/old','HF_HOME':'/old','PATH':'original'})
            b=isolation.private_env(Path(tmp)/'b',a)
            for key in ['TMPDIR','XDG_CACHE_HOME','XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_STATE_HOME','UV_CACHE_DIR','HF_HOME','NODE_COMPILE_CACHE']:
                self.assertNotEqual(a[key],b[key])
                self.assertTrue(Path(b[key]).is_relative_to(Path(tmp)/'b'))
            self.assertEqual(b['PATH'],'original')
            self.assertNotIn('HOME',b)

    def test_same_model_conversations_use_distinct_worker_roots_and_process_objects(self):
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            created=[]
            class FakeWorker:
                def __init__(self,root,installed,session,model):
                    self.root=root;self.session=session;self.model=model;self.closed=False;created.append(self)
                def close(self):self.closed=True
            with patch.object(isolation,'Worker',FakeWorker):
                gateway=isolation.Gateway(Path(tmp),Path('/installed'))
                a=gateway.worker('conversation-a','same-model')
                self.assertIs(gateway.worker('conversation-a','same-model'),a)
                b=gateway.worker('conversation-b','same-model')
                self.assertNotEqual(a.root,b.root)
                self.assertTrue(a.closed)
                self.assertFalse(b.closed)
                gateway.close()
                self.assertTrue(b.closed)
                self.assertEqual(len(created),2)

    def test_missing_request_identity_cannot_fall_back_to_shared_worker(self):
        gateway=isolation.Gateway(Path('.tmp/never-materialized'),Path('/installed'))
        for identity in [None,'',123]:
            with self.assertRaises(ValueError):gateway.worker(identity,'same-model')
        self.assertEqual(gateway.workers,{})

    def test_child_block_does_not_pollute_selected_root_recovery(self):
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            root=Path(tmp)
            for identity,phase in [('root','running'),('child','blocked')]:
                directory=root/'agents'/hashlib.sha256(identity.encode()).hexdigest();directory.mkdir(parents=True)
                (directory/'state.json').write_text(json.dumps({'schema':1,'sessions':{identity:{'phase':phase}}}))
            with patch.object(supervisor,'ROOT',root):
                self.assertEqual(supervisor.selected_records({'schema':1,'layout':'per-agent-v1','sessions':{},'currentSession':'root'}),[{'phase':'running'}])

    def test_private_tui_package_preferences_and_switch_contract(self):
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            root=Path(tmp)/'launch';root.mkdir()
            entry=isolation.copy_tui(root,Path.home())
            text=entry.read_text()
            self.assertNotIn("join(homedir(), '.dsh-tui'",text)
            self.assertIn('join(process.env.DSH_TUI_DATA_DIR',text)
            paths=(root/'tui/lib/types/utils/paths.js').read_text()
            self.assertIn('join(process.env.DSH_TUI_DATA_DIR)',paths)
            self.assertTrue((root/'tui/node_modules/@dsh-std').exists())
            switch=(root/'tui/lib/types/dsh-adapter/channel/model-switch.js').read_text()
            self.assertLess(switch.index('await deps.newSession()'),switch.index('deps.selection.current = { provider, model }'))
            isolation.copy_profiles(root,Path.home())
            package=root/'dsh/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui'
            self.assertEqual(package.resolve(),(root/'tui').resolve())

    def test_interrupted_preparation_is_never_reused_as_a_complete_tui(self):
        with tempfile.TemporaryDirectory(dir=REPO/'.tmp') as tmp:
            root=Path(tmp)
            (root/'tui').mkdir()
            with self.assertRaisesRegex(ValueError,'Incomplete private TUI'):
                isolation.copy_tui(root,Path.home())
            (root/'dsh/profiles').mkdir(parents=True)
            with self.assertRaisesRegex(ValueError,'Incomplete private profile'):
                isolation.copy_profiles(root,Path.home())


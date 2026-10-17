"""Evaluate installed ownership predicates without touching any process."""
import ast
import json
from pathlib import Path
import unittest

HERE=Path.home()/'.local/share/deepseek-harness/local-mlx'


class ProductionDeploymentTests(unittest.TestCase):
    def test_rc1_orphan_recognized_without_accepting_unrelated_command(self):
        tree=ast.parse((HERE/'router.py').read_text())
        assignment=next(node for node in ast.walk(tree) if isinstance(node,ast.Assign)
                        and any(isinstance(t,ast.Name) and t.id=='owned' for t in node.targets)
                        and 'qwen_flash_rc1.py' in ast.unparse(node))
        expression=compile(ast.Expression(assignment.value),'<installed ownership>','eval')
        self.assertTrue(eval(expression,{'HERE':HERE,'cmd':f'python {HERE}/qwen_flash_rc1.py 8192 serve'}))
        self.assertFalse(eval(expression,{'HERE':HERE,'cmd':'python /unrelated/qwen_flash_rc1.py 8192 serve'}))
        self.assertFalse(eval(expression,{'HERE':HERE,'cmd':f'python {HERE}/qwen_flash_rc1.py --help'}))

    def test_recycled_pid_fails_identity_gate(self):
        tree=ast.parse((HERE/'router.py').read_text())
        gate=next(n.test for n in ast.walk(tree) if isinstance(n,ast.If)
                  and 'owned and' in ast.unparse(n.test) and 'os.getpgid(pid)' in ast.unparse(n.test))
        class OS:
            @staticmethod
            def getpgid(pid):return pid
        expression=compile(ast.Expression(gate),'<installed pid identity>','eval')
        env={'owned':True,'record':{'started':'old'},'started':'new','pid':123,'os':OS}
        self.assertFalse(eval(expression,env))
        env['record']['started']='new'
        self.assertTrue(eval(expression,env))

    def test_other_profiles_unchanged_and_qwen_pinned(self):
        before=json.loads((Path(__file__).resolve().parents[2]/'watchdog/rc1-production-backup/profiles.json').read_text())
        after=json.loads((HERE/'profiles.json').read_text())
        target=str(Path.home()/'models/mlx-community/Qwen3.8-Flash-Next-oQ8e-mtp')
        self.assertEqual({k:v for k,v in before.items() if k!=target},{k:v for k,v in after.items() if k!=target})
        self.assertEqual(after[target]['qwen_runtime_version'],'0.7.1rc1')
        self.assertEqual(after[target]['moe_expert_offload_resident_fraction'],.6)
        self.assertEqual(after[target]['prefill_step_size'],8192)
        self.assertEqual(after[target]['mtp_adaptive_max_depth'],3)
        state=HERE/'omlx-state-qwen-flash-rc1'
        settings=json.loads((state/'settings.json').read_text())
        self.assertEqual(settings['cache']['ssd_cache_dir'],str(state/'cache'))


if __name__=='__main__':unittest.main()

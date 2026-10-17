"""Production Qwen Flash: the native rc1 serving path validated by the 16K run."""
from importlib.metadata import version
from pathlib import Path
import sys

if version('omlx') != '0.7.1rc1' or version('mlx') != '0.32.4':
    raise RuntimeError('Qwen Flash production requires oMLX0.7.1rc1 and MLX0.32.4')
HERE=Path(__file__).resolve().parent
if Path(sys.prefix).resolve() != (HERE/'venv-0.7.1rc1').resolve():
    raise RuntimeError('Qwen Flash production interpreter is not pinned rc1')
if '--base-path' not in sys.argv or Path(sys.argv[sys.argv.index('--base-path')+1]).resolve() != (HERE/'omlx-state-qwen-flash-rc1').resolve():
    raise RuntimeError('Qwen Flash rc1 requires its isolated production state')
size=int(sys.argv.pop(1))
if size != 8192:raise RuntimeError('Qwen Flash rc1 prefill chunk must be8192')
from omlx.settings import GlobalSettings
original=GlobalSettings.to_scheduler_config

def scheduler(self):
    result=original(self)
    result.prefill_step_size=size
    return result
GlobalSettings.to_scheduler_config=scheduler
print('Qwen Flash production: native oMLX0.7.1rc1 / MLX0.32.4; prefill8192; isolated rc1 cache',flush=True)
# No production_runtime/select_runtime import and no scheduler/Metal monkeypatch.
from omlx.cli import main
if __name__=='__main__':sys.exit(main())

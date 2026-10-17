"""Native rc1 serving with an explicit production-sized prefill chunk."""
from importlib.metadata import version
import sys
assert version('omlx') == '0.7.1rc1', version('omlx')
print('BENCHMARK_RUNTIME omlx='+version('omlx')+' mlx='+version('mlx'), flush=True)
from pathlib import Path
import functools
import omlx.cluster.worker_shim as worker_shim
worker_shim.ensure_cluster_python_shim = functools.partial(worker_shim.ensure_cluster_python_shim,
    home=Path(__file__).resolve().parents[2] / '.tmp/qwen-rc1-16k-20261017/state')
from omlx.settings import GlobalSettings
original = GlobalSettings.to_scheduler_config

def scheduler(self):
    result = original(self)
    result.prefill_step_size = 8192
    print('BENCHMARK_PREFILL_CHUNK 8192', flush=True)
    return result
GlobalSettings.to_scheduler_config = scheduler
from omlx.cli import main
if __name__ == '__main__':
    sys.exit(main())

"""Serve the tested six-bit baseline through the session-owned Harness router."""
import functools
import importlib.util
import json
import os
from pathlib import Path
import sys
import threading
import time

HERE=Path(__file__).resolve().parent
from glm6_profile import NAME,STATE_NAME,CAP_BYTES,validate_profile
profile=json.loads((HERE/'performance-overrides.json').read_text())[NAME]
validate_profile(profile)
state=HERE/STATE_NAME
if '--base-path' not in sys.argv or Path(sys.argv[sys.argv.index('--base-path')+1]).resolve()!=state.resolve():
    raise RuntimeError('GLM6 production requires its separate measured-memory state')
if Path(sys.prefix).resolve()!=(HERE/'venv-0.7.1rc1').resolve():
    raise RuntimeError('GLM6 production requires the qualified rc1 runtime')
from importlib.metadata import version
if version('omlx')!='0.7.1rc1' or version('mlx')!='0.32.4':
    raise RuntimeError('GLM rc1 production requires oMLX0.7.1rc1 with MLX0.32.4')
print('GLM production runtime verified: oMLX0.7.1rc1 / MLX0.32.4',flush=True)
from omlx.patches.mlx_vlm_glm5_next_compat import apply_mlx_vlm_glm5_next_compat_patch
apply_mlx_vlm_glm5_next_compat_patch()
from glm_resident_prefill import install as resident_first
resident_first()
spec=importlib.util.spec_from_file_location('dsh_glm6_async',HERE/'glm-rc1-production/overlap.py')
pipeline=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=pipeline
spec.loader.exec_module(pipeline)
pipeline.install(shared=False,prefill_enabled=True,stats_path=str(state/'prefill-stats.json'))
from glm_expert_cache import install as frequency
frequency()

import omlx_prefill_probe
from omlx.scheduler import Scheduler,PrefillMemoryExceededError

def actual_limit(self):
    return min(CAP_BYTES,self._memory_abort_limit_bytes or self._memory_hard_limit_bytes or CAP_BYTES)

def fixed_guard(self,n_tokens,**kwargs):
    cap=actual_limit(self)
    current=self._current_usage_bytes()
    if current>=cap:
        current=self._reclaim_prefill_headroom()
        if current>=cap:
            raise PrefillMemoryExceededError(message='Measured memory exceeds GLM6 production ceiling',
                request_id=kwargs.get('request_id'),estimated_bytes=current,limit_bytes=cap)
    print(f'MEASURED guard: requested={n_tokens} allowed={n_tokens} current_bytes={current} ceiling_bytes={cap} kv_len={kwargs.get("kv_len")}',flush=True)
    return n_tokens

Scheduler._guard_prefill_chunk=fixed_guard
Scheduler._adaptive_chunk_size=lambda self,requested,**kwargs:requested
Scheduler._admission_estimate=lambda self,**kwargs:None
Scheduler._prefill_peak_target=actual_limit
print('GLM6 measured-memory policy: prediction-only rejection and adaptive shrinking disabled; full-chunk and actual memory checks retained; decode lookahead disabled',flush=True)

import omlx.patches.deepseek_v4.moe_offload as offload
original_apply=offload.apply_deepseek_v4_moe_expert_offload
@functools.wraps(original_apply)
def audited_apply(model,*args,**kwargs):
    result=original_apply(model,*args,**kwargs)
    slots=[dict(capacity=m.cache.capacity,total=m.cache.n_experts)
           for m in model.modules() if isinstance(m,offload.OffloadedSwitchGLU)]
    if len(slots)!=42 or any(s!=dict(capacity=101,total=288) for s in slots):
        raise RuntimeError('GLM6 production must retain uniform 101/288 slots per routed layer')
    (state/'residency.json').write_text(json.dumps(slots,indent=2))
    print('GLM6 production residency verified: 42 x 101/288 slots, fixed uniform 35%; existing MTP head resident',flush=True)
    return result
offload.apply_deepseek_v4_moe_expert_offload=audited_apply

from omlx.utils.proc_memory import get_phys_footprint,get_lifetime_max_phys_footprint
def monitor():
    peak=0;last=0
    while True:
        current=get_phys_footprint()
        peak=max(peak,current,get_lifetime_max_phys_footprint())
        if time.monotonic()-last>=2:
            tmp=state/'physical-memory.tmp'
            tmp.write_text(json.dumps(dict(pid=os.getpid(),physical_bytes=current,peak_physical_bytes=peak,hard_limit_bytes=CAP_BYTES,time=time.time())))
            tmp.replace(state/'physical-memory.json')
            last=time.monotonic()
        if current>=CAP_BYTES:
            print(f'GLM6 actual hard memory cap reached: {current} >= {CAP_BYTES}; terminating owned backend',flush=True)
            os._exit(137)
        time.sleep(.25)
threading.Thread(target=monitor,name='glm6-physical-memory-cap',daemon=True).start()

if __name__=='__main__':
    sys.exit(omlx_prefill_probe.main())

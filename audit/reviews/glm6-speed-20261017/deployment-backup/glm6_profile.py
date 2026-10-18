"""CPU-only launch policy for the qualified uniform-35% six-bit GLM target."""
import json
from pathlib import Path

NAME='GLM-5.3-Flash-MLX-6bit'
STATE_NAME='omlx-state-glm6-r35'
CAP_BYTES=114_000_000_000


def validate_profile(profile):
    required=dict(backend='omlx',glm_runtime_version='0.7.1rc1',moe_expert_offload_enabled=True,
        moe_expert_offload_resident_fraction=.35,mtp_enabled=True,mtp_fixed_depth=1,
        glm_mtp_overlay=True,glm_nightly_runtime=True,glm_resident_first_prefill=True,
        glm_async_prefill=True,glm_expert_cache_policy='lfu',prefill_step_size=5632,
        turboquant_kv_enabled=False,moe_offload_io_workers=12,glm6_measured_memory=True)
    for key,value in required.items():
        if profile.get(key)!=value:
            raise ValueError('Unqualified GLM6 production setting: '+key)
    if abs(profile.get('memory_guard_gb',0)*1024**3-CAP_BYTES)>1:
        raise ValueError('GLM6 requires the measured 114 decimal GB guard')


def resolve_runtime(target, profile, here):
    from glm_mtp_identity import validate
    validate_profile(profile)
    here=Path(here)
    overlay=here/'glm6-production/mtp-overlay'
    receipt=json.loads((here/'glm6-production/draft-overlay.json').read_text())
    validate(target,overlay,receipt)
    return overlay,here/STATE_NAME/'cache-rc1'


def configure_environment(env, target, profile, models_root):
    if Path(target).resolve()!=(Path(models_root)/NAME).resolve():
        raise ValueError('GLM6 launch policy is target-specific')
    validate_profile(profile)
    env.update(DSH_LONG_TASK_GUARD='1',DSH_LONG_TASK_MAX_PREFILL_WORK=str(1<<27),
        DSH_LONG_TASK_PREFILL_TARGET_SECONDS='10.0',DSH_LONG_TASK_PREFILL_DURATION_FLOOR='5632',
        DSH_LONG_TASK_DURATION_ENABLED='1',DSH_LONG_TASK_PREFILL_MEMORY_FLOOR='0',
        MLX_MAX_OPS_PER_BUFFER='20',AGX_RELAX_CDM_CTXSTORE_TIMEOUT='1')

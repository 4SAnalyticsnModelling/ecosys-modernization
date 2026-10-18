"""Bounded aging-frequency eviction for the qualified full mixed-4/8 GLM.

Only eviction order changes. The original oMLX loader retains responsibility
for protected experts, reads, slot writes, synchronization, and failure handling.
"""
import functools
from pathlib import Path


def configure_environment(env, target, profile, models_root):
    env.pop('DSH_GLM_EXPERT_CACHE_POLICY', None)
    policy = profile.get('glm_expert_cache_policy', 'lru')
    if policy not in ('lru', 'lfu'):
        raise ValueError('GLM expert cache policy must be lru or lfu')
    if policy == 'lru':
        return
    expected = Path(models_root) / 'GLM-5.3-Flash-MLX-mixed-4_8bit'
    if (Path(target).resolve() != expected.resolve()
            or profile.get('backend') != 'omlx'
            or profile.get('moe_expert_offload_enabled') is not True):
        raise ValueError('Frequency cache requires the full mixed-4/8 GLM oMLX offload profile')
    env['DSH_GLM_EXPERT_CACHE_POLICY'] = 'lfu'


def prepare(cache, ids):
    """Order eviction candidates by aging frequency, breaking ties by recency.

    The existing loader still protects every currently requested expert and
    owns all reads, writes, slot maps, synchronization, and error handling.
    """
    ids = [int(e) for e in ids]
    if any(e < 0 or e >= cache.n_experts for e in ids):
        raise ValueError('Expert index outside checkpoint range')
    if not hasattr(cache, '_frequency'):
        cache._frequency = [0] * cache.n_experts
        cache._last_use = [0] * cache.n_experts
        cache._frequency_clock = 0
    cache._frequency_clock += 1
    clock = cache._frequency_clock
    if clock % 1024 == 0:
        cache._frequency = [n // 2 for n in cache._frequency]
    for expert in ids:
        cache._frequency[expert] += 1
        cache._last_use[expert] = clock
    cache.slot_of = dict(sorted(cache.slot_of.items(), key=lambda item:
        (cache._frequency[item[0]], cache._last_use[item[0]])))
    return ids


def install():
    from omlx.patches.deepseek_v4.moe_offload import _SlotCache
    original = _SlotCache.ensure_ids
    if getattr(original, '_glm_frequency_policy', False):
        return
    @functools.wraps(original)
    def ensure_ids(self, ids):
        return original(self, prepare(self, ids))
    ensure_ids._glm_frequency_policy = True
    _SlotCache.ensure_ids = ensure_ids
    print('GLM expert cache: bounded aging-frequency eviction enabled', flush=True)

"""Bounded decode prefetch. Predictions only fetch bytes; native routing installs them."""
from concurrent.futures import wait
import atexit
import functools
import re
import time

TARGETS = {}
STATS = dict(predictions=0, predicted_experts=0, useful_experts=0,
             wasted_experts=0, demand_calls=0, misses=0, ensure_seconds=0.0,
             prediction_seconds=0.0)
IN_PREFILL = 0
CACHES = []
WIDTH = 0


def bind(model):
    from mlx_vlm.models.glm5_next.language import Glm5NextMoE
    from omlx.patches.deepseek_v4.moe_offload import OffloadedSwitchGLU
    modules = [m for m in model.modules() if isinstance(m, Glm5NextMoE)
               and isinstance(m.switch_mlp, OffloadedSwitchGLU)]
    modules.sort(key=lambda m: tuple(int(s) if s.isdigit() else s for s in
        re.split(r'(\d+)', m.switch_mlp.cache.view._prefix)))
    if len(modules) != 42:
        raise RuntimeError('Expected 42 routed GLM backbone layers')
    TARGETS.clear()
    TARGETS.update((id(a.switch_mlp.cache), b) for a, b in zip(modules, modules[1:]))
    CACHES[:] = [m.switch_mlp.cache for m in modules]


def install(asynchronous, *, width=2):
    global WIDTH
    import mlx.core as mx
    from omlx.patches.deepseek_v4.moe_offload import _SlotCache, OffloadedSwitchGLU
    from omlx.scheduler import Scheduler
    if width not in (0, 2, 4):
        raise ValueError('Qualified lookahead widths are 0, 2 and 4')
    WIDTH = width
    def drain():
        for cache in CACHES:
            asynchronous.reader(cache).close()
    atexit.register(drain)
    old_prefill = Scheduler._do_external_prefill
    @functools.wraps(old_prefill)
    def prefill(*args, **kwargs):
        global IN_PREFILL
        drain()
        IN_PREFILL += 1
        try:
            return old_prefill(*args, **kwargs)
        finally:
            IN_PREFILL -= 1
    Scheduler._do_external_prefill = prefill
    # The qualified single-request scheduler calls these on its inference thread.
    # Drain outstanding bytes on completion, cancellation, errors and cache resets.
    def with_cleanup(method):
        @functools.wraps(method)
        def cleanup(*args, **kwargs):
            drain()
            return method(*args, **kwargs)
        return cleanup
    for name in ('_do_abort_request', '_cleanup_finished', 'fail_all_requests',
                 '_reset_request_for_reprefill'):
        setattr(Scheduler, name, with_cleanup(getattr(Scheduler, name)))

    previous_ensure = _SlotCache.ensure_ids
    @functools.wraps(previous_ensure)
    def ensure(cache, ids):
        # Preserve native validation before launching reads or touching metadata.
        reader = asynchronous.reader(cache)
        before = cache.misses
        start = time.perf_counter()
        try:
            ids = [int(e) for e in ids]
            if len(set(ids)) > cache.capacity or any(e < 0 or e >= cache.n_experts for e in ids):
                raise ValueError('Expert selection exceeds native cache contract')
            needed = {e for e in ids if e not in cache.slot_of}
            if not IN_PREFILL:
                STATS['demand_calls'] += 1
                # Submit demand before draining incorrect speculation.
                reader.prime(ids)
                for expert, (group, _, predicted) in list(reader.pending.items()):
                    if expert not in needed:
                        futures = [f for _, _, f in group]
                        for future in futures:
                            future.cancel()
                        if futures:
                            wait(futures)
                        reader.release(expert)
                        STATS['wasted_experts'] += int(predicted)
                    elif predicted:
                        STATS['useful_experts'] += 1
            return previous_ensure(cache, ids)
        finally:
            if not IN_PREFILL:
                STATS['misses'] += cache.misses - before
                STATS['ensure_seconds'] += time.perf_counter() - start
            # Native loader closes tickets too; this also covers preparation errors.
            reader.close()
    _SlotCache.ensure_ids = ensure

    previous_call = OffloadedSwitchGLU.__call__
    @functools.wraps(previous_call)
    def forward(self, x, indices, *args, **kwargs):
        following = TARGETS.get(id(self.cache))
        if WIDTH and following is not None and not IN_PREFILL and indices.size < 64:
            current = asynchronous.reader(self.cache)
            target_reader = None
            try:
                current.prime(indices.reshape(-1).tolist())
                target_reader = asynchronous.reader(following.switch_mlp.cache)
                started = time.perf_counter()
                prediction, confidence = following.gate(x)
                if confidence is not None:
                    order = mx.argsort(-confidence, axis=-1)
                    prediction = mx.take_along_axis(prediction, order, axis=-1)
                predicted = list(dict.fromkeys(prediction.reshape(-1).tolist()))
                candidates = [e for e in predicted if e not in following.switch_mlp.cache.slot_of][:WIDTH]
                STATS['prediction_seconds'] += time.perf_counter() - started
                if not target_reader.pending:
                    target_reader.prime(candidates, prefetch=True)
                    STATS['predictions'] += 1
                    STATS['predicted_experts'] += len(target_reader.pending)
                return previous_call(self, x, indices, *args, **kwargs)
            except BaseException:
                current.close()
                if target_reader is not None:
                    target_reader.close()
                drain()
                raise
        return previous_call(self, x, indices, *args, **kwargs)
    OffloadedSwitchGLU.__call__ = forward
    print(f'GLM6 bounded decode lookahead: {width}; native routing and slot writes retained', flush=True)

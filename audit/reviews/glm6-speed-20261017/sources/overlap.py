"""Opt-in GLM read/compute overlap; checkpoint bytes and GPU arithmetic stay native.

Workers only read raw bytes. Cache metadata, MLX arrays and slot writes remain
on the inference thread. A process-wide byte ledger includes prefetched and
demand payloads until installation or cancellation has completed.
"""
from concurrent.futures import wait
import atexit
import functools
import hashlib
import json
from pathlib import Path
import threading
import time

import mlx.core as mx
import numpy as np

LIMIT = 512 * 1024**2
STATS = dict(staged_bytes=0, peak_staged_bytes=0, prefetched_experts=0,
             reused_prefetches=0, shared_dispatches=0, read_wait_s=0.0,
             installed_bytes=0, prefill_groups=0)


class Reads:
    """One layer's immutable read tickets; never reserves or mutates GPU slots."""
    def __init__(self, cache):
        self.cache = cache
        self.pending = {}

    def prime(self, ids, *, prefetch=False):
        from omlx.patches.deepseek_v4.moe_offload import _io_pool, _io_batch
        c, pool = self.cache, _io_pool()
        if pool is None:
            return
        width = min(_io_batch(), max(1, LIMIT // c.expert_bytes))
        for expert in dict.fromkeys(int(e) for e in ids):
            if expert in c.slot_of or expert in self.pending:
                continue
            if len(self.pending) >= width or STATS['staged_bytes'] + c.expert_bytes > LIMIT:
                break
            plans = [(w, c.view.plan(w[2], w[1], expert)) for w in c._writes]
            size = sum(p.nbytes for _, p in plans)
            if size != c.expert_bytes or size > LIMIT:
                raise ValueError('Unexpected expert read size')
            # Charge before submitting; a failed submission is drained by close().
            self.pending[expert] = ([], size, prefetch)
            STATS['staged_bytes'] += size
            STATS['peak_staged_bytes'] = max(STATS['peak_staged_bytes'], STATS['staged_bytes'])
            group = self.pending[expert][0]
            try:
                for write, plan in plans:
                    group.append((write, plan, pool.submit(c.view._store.read, plan)))
            except BaseException:
                self.close()
                raise
            if prefetch:
                STATS['prefetched_experts'] += 1

    def consume(self, expert):
        group, size, prefetched = self.pending[expert]
        started = time.perf_counter()
        raw = [(write, plan, future.result()) for write, plan, future in group]
        STATS['read_wait_s'] += time.perf_counter() - started
        if any(len(data) != plan.nbytes for _, plan, data in raw):
            raise OSError('Short expert read')
        if prefetched:
            STATS['reused_prefetches'] += 1
        return raw

    def release(self, expert):
        group, size, _ = self.pending.pop(expert)
        # Caller has dropped its raw views; drop the futures' result references too.
        group.clear()
        STATS['staged_bytes'] -= size

    def close(self):
        for expert, (group, _, _) in list(self.pending.items()):
            futures = [f for _, _, f in group]
            for future in futures:
                future.cancel()
            if futures:
                wait(futures)
            self.release(expert)


def reader(cache):
    if not hasattr(cache, '_glm_async_reads'):
        cache._glm_async_reads = Reads(cache)
    return cache._glm_async_reads


def ensure_ids(self, ids):
    """Original slot and LRU transition order, with reusable bounded read tickets."""
    from omlx.patches.moe_expert_offload import CheckpointExpertStore
    needed = list(dict.fromkeys(int(e) for e in ids))
    r = reader(self)
    try:
        if len(needed) > self.capacity or any(e < 0 or e >= self.n_experts for e in needed):
            raise ValueError('Expert selection exceeds cache capacity or checkpoint range')
        misses = []
        for expert in needed:
            if expert in self.slot_of:
                self.slot_of[expert] = self.slot_of.pop(expert)
                self.hits += 1
            else:
                misses.append(expert)
        protected = set(needed)
        # Drop tickets not demanded now (e.g. a reset or a cancelled prefill).
        if any(e not in misses for e in r.pending):
            r.close()
        r.prime(misses)
        for index, expert in enumerate(misses):
            if expert in r.pending:
                raws = r.consume(expert)
            else:
                raws = [(w, self.view.plan(w[2], w[1], expert), None) for w in self._writes]
                raws = [(w, plan, CheckpointExpertStore.read(plan)) for w, plan, _ in raws]
            if self.free:
                slot = self.free.pop()
            else:
                victim = next(v for v in self.slot_of if v not in protected)
                slot = self.slot_of.pop(victim)
                self.map[victim] = -1
            for (proj, field, _), plan, raw in raws:
                self.glu[proj][field][slot] = CheckpointExpertStore.to_mx(plan, raw)
            # Publish only after all projections/fields have been installed.
            self.slot_of[expert] = slot
            self.map[expert] = slot
            self.misses += 1
            size = sum(plan.nbytes for _, plan, _ in raws)
            self.fetched_bytes += size
            STATS['installed_bytes'] += size
            del raws, raw
            if expert in r.pending:
                r.release(expert)
            r.prime(misses[index + 1:])
        self.warm = len(self.slot_of) == self.n_experts
    finally:
        r.close()


def prefill(self, flat_x, ids, k):
    """Same resident-first groups and GEMM shapes, with next-group raw read-ahead."""
    c = self.cache
    r = reader(c)
    ids_np = np.asarray(ids, dtype=np.int64)
    original_order = np.argsort(ids_np, kind='stable')
    original_ids = ids_np[original_order]
    starts = np.concatenate(([0], np.flatnonzero(np.diff(original_ids)) + 1))
    cuts = starts[::c.capacity].tolist() + [len(ids)]
    groups = list(zip(cuts[:-1], cuts[1:]))
    resident = set(c.slot_of)
    groups.sort(key=lambda pair: -sum(int(e) in resident
        for e in np.unique(original_ids[pair[0]:pair[1]])))
    order = np.concatenate([original_order[a:b] for a, b in groups])
    sorted_ids = ids_np[order]
    cuts = [0]
    for a, b in groups:
        cuts.append(cuts[-1] + b-a)
    outs = []
    try:
        for index, (start, end) in enumerate(zip(cuts[:-1], cuts[1:])):
            chunk_ids = sorted_ids[start:end]
            c.ensure_ids(np.unique(chunk_ids).tolist())
            slots = mx.take(c.map, mx.array(chunk_ids, dtype=mx.int32))
            t_idx = mx.array(order[start:end] // k, dtype=mx.int32)
            xe = mx.take(flat_x, t_idx, axis=0)
            out = c.glu(xe, slots.reshape(-1, 1))[:, 0, :]
            if index + 2 < len(cuts):
                r.prime(np.unique(sorted_ids[cuts[index+1]:cuts[index+2]]), prefetch=True)
            mx.eval(out)  # next group's reads run; slots stay untouched until this finishes
            outs.append(out)
            STATS['prefill_groups'] += 1
        out = mx.concatenate(outs, axis=0)
        inverse = mx.array(np.argsort(order, kind='stable'), dtype=mx.int32)
        return mx.take(out, inverse, axis=0).reshape(-1, k, flat_x.shape[-1])
    finally:
        r.close()


def install(*, shared=True, prefill_enabled=True, stats_path=None):
    import omlx
    root = Path(omlx.__file__).resolve().parent.parent
    manifest = json.loads(Path(__file__).with_name('runtime-manifest.json').read_text())
    for relative, expected in manifest.items():
        if hashlib.sha256((root / relative).read_bytes()).hexdigest() != expected:
            raise RuntimeError('GLM overlap needs requalification after runtime update: '+relative)
    from omlx.patches.deepseek_v4.moe_offload import _SlotCache, OffloadedSwitchGLU
    from omlx.patches.mlx_vlm_glm5_next_compat import apply_mlx_vlm_glm5_next_compat_patch
    apply_mlx_vlm_glm5_next_compat_patch()
    from mlx_vlm.models.glm5_next.language import Glm5NextMoE
    if getattr(_SlotCache.ensure_ids, '_glm_async', False):
        raise RuntimeError('GLM overlap already installed')
    ensure_ids._glm_async = True
    _SlotCache.ensure_ids = ensure_ids
    if prefill_enabled:
        OffloadedSwitchGLU._forward_expert_major = prefill
    if shared:
        original = Glm5NextMoE.__call__
        @functools.wraps(original)
        def forward(self, x):
            sw = self.switch_mlp
            if not isinstance(sw, OffloadedSwitchGLU) or self.shared_experts is None or x.size // x.shape[-1] > 2:
                return original(self, x)
            indices, scores = self.gate(x)
            ids = indices.reshape(-1).tolist()  # exact picks, ready before starting I/O
            r = reader(sw.cache)
            try:
                r.prime(ids, prefetch=True)
                shared_out = None
                if r.pending:
                    shared_out = self.shared_experts(x)
                    mx.async_eval(shared_out)
                    STATS['shared_dispatches'] += 1
                y = sw(x, indices, scores=scores, weighted_sum=True)
                if y.ndim == x.ndim + 1:
                    y = (y * scores[..., None]).sum(axis=-2).astype(x.dtype)
                return y + (self.shared_experts(x) if shared_out is None else shared_out)
            finally:
                r.close()
        Glm5NextMoE.__call__ = forward
    if stats_path:
        save_lock = threading.Lock()
        def save():
            with save_lock:
                path = Path(stats_path)
                temporary = path.with_suffix('.tmp')
                temporary.write_text(json.dumps(dict(STATS), indent=2) + '\n')
                temporary.replace(path)
        # oMLX can exit without Python atexit; retain periodic diagnostic receipts.
        def snapshots():
            while True:
                save()
                time.sleep(5)
        threading.Thread(target=snapshots, name='glm-overlap-stats', daemon=True).start()
        atexit.register(save)
    print(f'GLM overlap installed: shared={shared}, prefill={prefill_enabled}, staging={LIMIT}', flush=True)

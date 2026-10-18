"""GLM experiment: consume resident expert runs before streaming misses.

Uses the installed GLM adapter's original SwitchGLU arithmetic and slot cache.
Only expert execution order changes; each route is restored to its original
token/top-k position before weighted reduction. Enabled only for the qualified local GLM profile.
"""
import logging
import mlx.core as mx
import numpy as np

log = logging.getLogger(__name__)


def forward(self, flat_x, ids, k):
    c = self.cache
    # Keep the upstream groups and their route counts: splitting groups by
    # residency changed BF16 kernel selection in the fixture check. Reorder
    # whole groups instead, so every GEMM keeps its original operand shape.
    ids_np = np.asarray(ids, dtype=np.int64)
    original_order = np.argsort(ids_np, kind='stable')
    original_ids = ids_np[original_order]
    starts = np.concatenate(([0], np.flatnonzero(np.diff(original_ids)) + 1))
    cuts = starts[::c.capacity].tolist() + [len(ids)]
    groups = list(zip(cuts[:-1], cuts[1:]))
    resident = set(c.slot_of)
    groups.sort(key=lambda pair: -sum(int(e) in resident
        for e in np.unique(original_ids[pair[0]:pair[1]])))
    order = np.concatenate([original_order[start:end] for start, end in groups])
    sorted_ids = ids_np[order]
    cuts = [0]
    for start, end in groups:
        cuts.append(cuts[-1]+end-start)
    before = c.fetched_bytes
    outs = []
    for start, end in zip(cuts[:-1], cuts[1:]):
        chunk_ids = sorted_ids[start:end]
        c.ensure_ids(np.unique(chunk_ids).tolist())
        slots = mx.take(c.map, mx.array(chunk_ids, dtype=mx.int32))
        t_idx = mx.array(order[start:end] // k, dtype=mx.int32)
        xe = mx.take(flat_x, t_idx, axis=0)
        out = c.glu(xe, slots.reshape(-1, 1))[:, 0, :]
        mx.eval(out)
        outs.append(out)
    out = mx.concatenate(outs, axis=0)
    inverse = mx.array(np.argsort(order, kind='stable'), dtype=mx.int32)
    log.debug('GLM resident-first: routes=%d groups=%d read_bytes=%d',
             len(ids), len(cuts)-1, c.fetched_bytes-before)
    return mx.take(out, inverse, axis=0).reshape(-1, k, flat_x.shape[-1])


def install():
    from omlx.patches.deepseek_v4.moe_offload import OffloadedSwitchGLU
    OffloadedSwitchGLU._forward_expert_major = forward
    print('GLM resident-first expert prefill enabled', flush=True)

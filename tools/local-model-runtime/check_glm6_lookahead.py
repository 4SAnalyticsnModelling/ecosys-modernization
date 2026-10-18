"""Exercise real six-bit native GLU arithmetic, evictions and slot updates."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import types

import mlx.core as mx
import numpy as np

HERE = Path('/Users/4sanalyticsnmodelling/.local/share/deepseek-harness/local-mlx')
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location('parity_async', HERE/'glm-rc1-production/overlap.py')
asynchronous = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = asynchronous
spec.loader.exec_module(asynchronous)
from omlx.patches.mlx_vlm_glm5_next_compat import apply_mlx_vlm_glm5_next_compat_patch
apply_mlx_vlm_glm5_next_compat_patch()
asynchronous.install(shared=False, prefill_enabled=True)
from glm_expert_cache import install as install_frequency
install_frequency()
from omlx.patches.deepseek_v4.switch_layers import SwitchGLU, QuantizedSwitchLinear
from omlx.patches.deepseek_v4.moe_offload import OffloadedSwitchGLU
from omlx.patches.moe_expert_offload import _ReadPlan, CheckpointExpertStore
import glm6_lookahead as strategies


def main():
    mode = 'lookahead'
    mx.random.seed(73)
    arrays = {}
    for proj in ('gate_proj', 'up_proj', 'down_proj'):
        q = QuantizedSwitchLinear(128, 128, 20, bias=False, bits=6, group_size=64)
        arrays[proj] = {name: (a if name == 'weight' else a.astype(mx.bfloat16))
                        for name, a in q.parameters().items()}
    mx.eval(arrays)
    with tempfile.TemporaryFile() as f:
        plans = {}
        offset = 0
        for proj, fields in arrays.items():
            for field, a in fields.items():
                for e in range(20):
                    part = a[e]
                    if part.dtype == mx.bfloat16:
                        raw = np.array(part.view(mx.uint16)).tobytes()
                        dt, view = np.uint16, mx.bfloat16
                    else:
                        raw = np.array(part).tobytes()
                        dt, view = np.uint32, None
                    f.write(raw)
                    plans[proj, field, e] = _ReadPlan(f.fileno(), offset, len(raw), dt, view, part.shape)
                    offset += len(raw)
        f.flush()
        class View:
            _store = CheckpointExpertStore
            def plan(self, proj, field, e):
                return plans[proj, field, e]
        def make():
            g = SwitchGLU(128, 128, 20)
            for proj, fields in arrays.items():
                q = QuantizedSwitchLinear(128, 128, 20, bias=False, bits=6, group_size=64)
                for name, a in fields.items():
                    setattr(q, name, a)
                g[proj] = q
            w = OffloadedSwitchGLU(g, 16, View())
            w.cache._layer_probe_decode = True
            return w
        reference = make()
        inputs = []
        for i in range(40):
            n = 1 if i % 2 == 0 else 2
            ids = [((i * 3) + j) % 20 for j in range(n * 8)]
            indices = mx.array(ids, dtype=mx.int32).reshape(1, n, 8)
            x = mx.random.normal((1, n, 128)).astype(mx.bfloat16)
            mx.eval(x, indices)
            inputs.append((x, indices))
        expected = []
        for x, ids in inputs:
            y = reference(x, ids)
            mx.eval(y)
            expected.append((y, dict(reference.cache.slot_of)))
        test = make()
        strategies.install(asynchronous, width=4)
        companion = make() if mode == 'lookahead' else None
        gate_state = {}
        if companion is not None:
            target = types.SimpleNamespace(switch_mlp=companion,
                gate=lambda x: (gate_state['prediction'],
                    mx.broadcast_to(mx.arange(8,dtype=mx.float32),gate_state['prediction'].shape)))
            strategies.TARGETS[id(test.cache)] = target
        # Exercise the delayed-read branch even though these test slabs are tiny.
        old_read = CheckpointExpertStore.read
        if mode in ('overlap', 'overlap_compact', 'keepalive', 'batch_keepalive'):
            def slow_read(plan):
                time.sleep(.002)
                return old_read(plan)
            CheckpointExpertStore.read = staticmethod(slow_read)
        for i, ((x, ids), (want, slots)) in enumerate(zip(inputs, expected)):
            if companion is not None:
                if i%3 == 0:
                    outside = [e for e in range(20) if e not in ids.reshape(-1).tolist()]
                    predicted = (outside*((ids.size+len(outside)-1)//len(outside)))[:ids.size]
                    gate_state['prediction'] = mx.array(predicted,dtype=mx.int32).reshape(ids.shape)
                else:
                    gate_state['prediction'] = ids
            y = test(x, ids)
            mx.eval(y)
            if mode != 'phase':
                assert test.cache.slot_of == slots, ('slot mapping differs', i)
            assert bool(mx.array_equal(y, want)), ('native output differs', i,
                    float(mx.max(mx.abs(y.astype(mx.float32)-want.astype(mx.float32)))))
            if companion is not None:
                z = companion(x, ids)
                mx.eval(z)
                assert bool(mx.array_equal(z, want)), ('lookahead companion output differs', i)
                assert companion.cache.slot_of == slots, ('lookahead changed actual routing/cache state', i)
        if companion is not None:
            assert strategies.STATS['predicted_experts'] > 0
            assert strategies.STATS['useful_experts'] > 0
            assert strategies.STATS['wasted_experts'] > 0
        # Real pending futures must be drained even when prefill raises before
        # entering any MoE layer. Prefill phase must be restored on exceptions.
        from omlx.scheduler import Scheduler
        strategies.CACHES[:] = [test.cache, companion.cache]
        missing = next(e for e in range(20) if e not in companion.cache.slot_of)
        asynchronous.reader(companion.cache).prime([missing], prefetch=True)
        assert asynchronous.STATS['staged_bytes'] > 0
        try:
            Scheduler._do_external_prefill(object(), None)
        except (AttributeError, TypeError):
            pass
        else:
            raise AssertionError('Expected invalid scheduler receiver to raise')
        assert strategies.IN_PREFILL == 0
        assert not asynchronous.reader(companion.cache).pending
        # A corrupt/short expert read must fail and release its byte charge.
        original_read = CheckpointExpertStore.read
        CheckpointExpertStore.read = staticmethod(lambda plan: b'')
        try:
            bad = make()
            try:
                bad(inputs[0][0], inputs[0][1])
            except OSError:
                pass
            else:
                raise AssertionError('Short expert read was silently accepted')
            assert not asynchronous.reader(bad.cache).pending
        finally:
            CheckpointExpertStore.read = original_read
        # Planning can fail after an earlier expert has queued real futures.
        # Direct forward failure must release those tickets immediately.
        planning = make()
        absent = [e for e in range(20) if e not in planning.cache.slot_of]
        assert len(absent)>=2
        first,second=absent[:2]
        original_plan=planning.cache.view.plan
        def fail_second(proj,field,expert):
            if expert==second:
                assert asynchronous.STATS['staged_bytes']>0
                raise RuntimeError('Injected later expert plan failure')
            return original_plan(proj,field,expert)
        planning.cache.view.plan=fail_second
        strategies.TARGETS[id(planning.cache)]=types.SimpleNamespace(switch_mlp=companion,
            gate=lambda x: (gate_state['prediction'],None))
        demand_before=strategies.STATS['demand_calls']
        try:
            planning(inputs[0][0],mx.array([first,second]*4,dtype=mx.int32).reshape(1,1,8))
        except RuntimeError as error:
            assert 'Injected later expert plan failure' in str(error)
        else:
            raise AssertionError('Planning exception was silently accepted')
        assert not asynchronous.reader(planning.cache).pending
        assert strategies.STATS['demand_calls']==demand_before
        assert asynchronous.STATS['staged_bytes']==0
        planning.cache.view.plan=original_plan
        asynchronous.reader(planning.cache).prime([first],prefetch=True)
        try:
            planning.cache.ensure_ids([-1])
        except ValueError:
            pass
        else:
            raise AssertionError('Invalid expert selection was accepted')
        assert not asynchronous.reader(planning.cache).pending
        assert asynchronous.STATS['staged_bytes'] == 0, 'Leaked read tickets'
        row = dict(mode=mode, steps=40, six_bit=True, exact_output=True,
                   exact_slot_mapping=mode != 'phase', stats=strategies.STATS,
                   short_read_cleanup=True,planning_failure_cleanup=True,
                   invalid_selection_cleanup=True,prefill_failure_cleanup=True,
                   implementation_sha256=hashlib.sha256(Path(strategies.__file__).read_bytes()).hexdigest(),
                   check_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
        (Path(__file__).resolve().parents[2]/'audit/reviews/glm6-speed-20261017/parity.json').write_text(json.dumps(row, indent=2))
        print(json.dumps(row), flush=True)


if __name__ == '__main__':
    main()

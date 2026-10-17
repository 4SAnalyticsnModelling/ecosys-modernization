# Qwen Flash Next Q8 — one 16K rc1 test

2026-10-17; oMLX **0.7.1rc1**, MLX **0.32.4**. Exactly **one inference**,
**16,384 input tokens**, **zero cached tokens**, **128 generated tokens**.
Model: `mlx-community/Qwen3.8-Flash-Next-oQ8e-mtp`.

| Measurement | Result |
| --- | ---: |
| Server prefill | **307.73 tokens/s** |
| Server decode | **12.04 tokens/s** |
| Server time to first token | **53.24 s** |
| Client time to first streamed token | **53.63 s** |
| Client decode (127 tokens / first-to-last interval) | 12.29 tokens/s |
| Request duration reported by server | 63.88 s |
| Model preload, separately timed | 7.65 s |

Fresh isolated cache; model loaded before timed request. Native rc1 serving,
8,192-token prefill chunks, 60% expert residency, native KV and adaptive MTP up
to depth 3; 112GiB process memory ceiling. The normal dev1 production settings
were not switched. A fused attention kernel requested 1,024 threads where this
GPU permits 896; **rc1 logged its native fallback to MLX and completed**. Cold
first-request kernel setup/fallback is included in these timings.

Artifacts: `audit/runs/qwen-rc1-16k-20261017/` contains the request, full SSE
stream, output, server/client logs and result. Server shut down and unloaded the
model after completion. `tools/local-model-benchmark/rc1_once.py` is the runner;
its existing-state guard prevents accidentally repeating this single test.
No second inference, warm-cache pass or dev1 comparison was run. CPU tokenizer
and model-load endpoint setup corrections occurred before the sole inference.

During an initial load-only preparation, native rc1 published its standard
cluster-interpreter helper under `~/.omlx/bin`; subsequent helper writes were
redirected into the isolated state. The normal dev1 model route/profile was
not changed. This setup-side write is separate from the measured inference.

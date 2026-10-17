# Qwen3.8 27B: extracted historical speed and current setup

Extracted 2026-10-17 from existing local records; no new inference or benchmark run.
Exact samples, source paths and SHA-256 are in `records.json`; copied source files
are under `sources/`. Scan covered 165 sample records in the documented benchmark
locations; these are the best found within that scope, not universal maxima.

| Historical sample | Decode tokens/s | Prompt / output tokens | Notes |
| --- | ---: | --- | --- |
| MTPLX Optimized Quality FP16 27B, chunk4096-short-1 | 47.14 client | 86 / 384 | 0 cached tokens; TTFT 0.636 s; distinct from official BF16 |
| Official Qwen3.8 27B BF16, oMLX MTP depth 4, baseline 4k-0 | 31.80 client / 32.01 server | 3,731 / 128 | 0 cached tokens; TTFT 15.341 s |
| Official BF16 best fresh-prefill sample found | 255.11 prefill | 3,729 / 128 | MTP depth 4, chunk8192, CPU prefill fraction 0.1; decode 29.80 client |

The displayed 98.28 server decode tokens/s in the October 2 production verification
is a **one-output-token** cached trial with a rounded 0.01-second generation duration;
it is excluded from meaningful decode ranking. The 6,978.01 prompt tokens/s record
restored 3,690 of 3,697 input tokens from cache and is not fresh-prefill throughput.
Short samples and differing precision, context, thinking and speculative settings
must not be presented as comparable sustained coding performance. Historical winning
settings are not necessarily the settings active today.

## Current configured setup

Source snapshot: `current-setup.json` (configuration, not a live memory measurement).

| Setting | Current value |
| --- | --- |
| Model / serving backend | Official `Qwen/Qwen3.8-27B`, BF16, oMLX via local gateway |
| Native model context / harness route | 262,144 / 131,072 tokens |
| Maximum output | 32,768 tokens |
| Thinking | Enabled and preserved; reasoning effort `xhigh` |
| Sampling | temperature 1.0; top_p 0.95; top_k 20; min_p 0 |
| Penalties | repetition 1.0; presence 0 |
| MTP | Enabled, adaptive maximum depth 3; fixed depth unset |
| Prefill | 8,192 tokens; CPU BF16 prefill fraction 0.1; long-prefill guard enabled |
| Precision / kernels | Native BF16 KV, FP32 recurrent state per installed deployment documentation; TurboQuant KV, ANE prefill and OQ-A8 disabled |
| Memory / cache | 112 GB configured memory guard; 2 GB hot cache; persistent prefix cache |
| Scheduling | inference QoS enabled; balanced burst decode |
| Code mode | `run_code` plus ordinary tools on all three harness profiles |

The model serving profile still declares `request_timeout_seconds: 7200`; provider
transport separately declares a 4-hour request timeout and 2-hour idle timeout.
Those external serving/transport safeguards were not changed by the repository
instruction revision. The new code-mode runtime itself has no elapsed deadline.
The 262K native setting is not proof of a qualified 262K harness context.

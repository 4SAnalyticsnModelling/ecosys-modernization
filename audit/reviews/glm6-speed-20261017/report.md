# GLM Flash six-bit tuning, 2026-10-18

Production uses bounded two-expert decode lookahead and8192-token prefill.
Maximum thinking is default in all three GLM profile layers. Original six-bit
weights, native KV, MTP depth1,101/288 resident expert slots and114GB decimal
physical-memory cap remain unchanged. CPU disk-I/O workers remain12; MLX/Metal
schedules computation on the single Apple GPU without a GPU-worker knob.

## Matched16K results

Each strategy used exactly16384 prompt tokens, maximum thinking and128 output
tokens, with a fresh request and full warm-prefix request (16382 cached tokens).
All three strategies returned identical output hashes, using the same prompt
and WezTerm Software-renderer configuration.

| Strategy | Prefill tokens/s | Fresh decode tokens/s | Cached decode tokens/s | Fresh elapsed seconds |
| --- | ---: | ---: | ---: | ---: |
| Original5632 chunk |85.88|2.28|2.98|247.10|
| Two-expert lookahead |84.44|2.59|3.30|243.60|
| Lookahead plus8192 chunk |100.70|2.57|3.29|212.49|

Combined fresh-request time fell14.0%; prefill rose17.3%; cached decode rose10.4%.
Time to first token fell191.10→163.02seconds. Single matched runs establish
these observed gains; they do not establish a statistical confidence interval.
Historical production was90.93prefill and2.31decode tokens/s at16.8K; the matched
baseline above is the appropriate comparison for this tuning.

A separate16K retrieval check returned the correct midpoint marker79146283,
with8192 cached prefix tokens and8192 processed suffix tokens. It generated159
tokens including154 reasoning tokens and stopped normally. Peak physical use
across the selected/retrieval tests was111.134GB, below114GB; original checkpoint
metadata was unchanged. Source weights were never rewritten.

## Why utilization has gaps

The offloaded model waits for SSD expert reads. The baseline warm run read about
171.79GB per128 output tokens (1.34GB/token), so low GPU activity can reflect
waiting for data. Two-expert lookahead overlaps some reads with computation;
larger prefill chunks improve prompt computation efficiency. More CPU threads
or a higher utilization percentage alone would not establish faster inference.

WezTerm now uses `front_end='Software'`,30FPS/10animationFPS. Samples of its
GPU elapsed-time counter fell from49.79% to2.71%; these are elapsed-time ratios,
not additive shares of GPU cores. Window presentation can still involve the GPU.
The before/after terminal samples are observational, separate from the matched
model comparison.

## Verification and scope

Synthetic native six-bit arithmetic/slot parity and failure-cleanup tests passed
(`parity.json`). Selected16K completion, identical-output and retrieval receipts
passed. The real-router startup/load smoke passed with zero generation requests
and stopped its owned backend (`production-smoke.json`). An initial startup
failure exposed an unsupported8192 duration-floor environment setting; retaining
the measured5632 environment floor fixed it while keeping the actual8192 chunk.
The failed smoke is retained separately. `deployment.json` pins installed hashes
and `deployment-backup/` preserves original runtime/config bytes.

Per user instruction final strategy qualification is16K only. Earlier32K
exploration is historical;64K was explicitly canceled and is not a success.
No larger-context reliability claim follows from these tests. No ecosys science,
Fortran, Zig source or scientific tolerance changed.

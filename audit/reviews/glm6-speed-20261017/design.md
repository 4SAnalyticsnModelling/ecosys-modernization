GLM-5.3-Flash six-bit speed qualification, 2026-10-17

Final scope override: user explicitly requested only16K prompt tests per
strategy to save time. Both larger-context controllers were stopped and the
owned64K run was interrupted orderly. Its receipt is interrupted evidence,
not a successful long-context qualification. Active qualification is now
glm6_16k_suite.py: exactly16384 input tokens, baseline/prefetch/larger-chunk,
fresh plus cached repeat, and a separate16K retrieval check. All these runs
use stable Software-rendered WezTerm and maximum thinking. Deployment gates
follow this explicit user scope; no64K success is required or claimed.

User authorization: inspect historical production results, apply relevant
glm-flash-lite strategies, and test long context. The mixed model was deleted;
only the original six-bit checkpoint is in scope. Installed model/runtime access
and final deployment are necessary to this explicit request. New code, benchmark
state, cache, scratch and evidence live in this repository. The unrelated Ottawa
science cycle and its untracked replay artifacts are not part of this change.

Additional user requirement: highest thinking mode is the production default.
All throughput and retrieval payloads retain reasoning_effort=max. Deployment
explicitly preserves max effort and enable_thinking=true in each GLM6 profile.

Hardware: Apple M1 Ultra, 137438953472 bytes unified memory (128 GiB).
Historical rc1 production receipt: sources/glm6-production-profile-omlx071rc1-16k-20261015/result.json.
Fresh 16766-token prompt: 90.93 prompt tokens/s, 184.69 seconds first-token
latency, 2.31 generated tokens/s. Reused 16764-token prefix: 1.44 seconds
first-token latency, 3.04 generated tokens/s. Peak physical footprint
110738682960 bytes. These are historical measurements, not a new live baseline.

Historical strategies were already tested on October15. Four-expert lookahead
was modestly faster for 128 output tokens, but at512 output tokens improved
fresh decode only2.56 to2.59 tokens/s and persisted-prefix decode2.48 to2.78.
Packed storage, batching, keepalive, alternative overlap and weighted residency
did not establish a useful overall improvement. See historical-summary.json
and copied source receipts; errors and partial-cache trials remain recorded.

Experiment preserves:

- All original six-bit checkpoint shards and verified resident MTP head.
- Uniform101/288 resident experts at each of42 routed layers.
- Existing114000000000-byte physical memory cap and runtime enforcer.
- Native routing, native arithmetic, LFU state, protected cache slots and depth1 MTP.
- oMLX0.7.1rc1 and MLX0.32.4.
- Production maximum reasoning and sampling for throughput comparisons.

Bounded prediction uses the next routed layer's gate on current inputs only to
schedule raw expert reads. It does not replace the real router or install
speculative slots. Enqueue actual demand before draining incorrect predictions;
retain correct read tickets. Existing512MiB shared staging ledger remains in
force. Disable prediction throughout external prefill, and drain reads on
completion, cancellation, failure, reset and shutdown. Measure useful/wasted
reads, prediction time, native-loader waiting, physical footprint and disk reads.

Qualification: real6bit cache arithmetic/eviction parity, wrong predictions,
short reads and failure cleanup; paired32K coding-context baseline/candidate
with128 output tokens and cold/warm prefixes; selected candidate at64K and a
separate retrieval check. Larger prefill chunk may be tried without raising the
cap. Actual prompt/cache counts, complete output streams and source shard
metadata are recorded. Check deterministic output hashes across matched arms.
Promote only an evidenced improvement; retain/revert baseline on regression.

Fresh-context read-only verifier reviewed the design and implementation. Its
findings drove explicit prefill phase, individual prediction cancellation,
request lifecycle cleanup and stream/cache/retrieval validation. Historical
strategy `_layer_probe_decode` depended on telemetry absent in production;
this implementation does not depend on that flag.

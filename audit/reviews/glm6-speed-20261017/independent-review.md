Fresh-context read-only review, 2026-10-17

Scope: tools/local-model-runtime/glm6_lookahead.py,
benchmark_glm6.py, check_glm6_lookahead.py,
glm6_speed_suite.py and deploy_glm6_lookahead.py.
Reviewer ran no model inference and edited no files.

Final verdict: "PASS on the reviewed runtime and deployment safeguards;
performance acceptance remains pending."

Findings addressed before qualification:

- Historical lookahead depended on a telemetry flag absent from production.
  The new wrapper explicitly tracks external prefill and never relies on it.
- Retain individually useful predictions; submit real demand before draining
  incorrect futures, and retain staging charges until those futures finish.
- Drain reads on prefill entry, model errors, cancellation, completion, request
  reset and shutdown. Synthetic six-bit tests cover actual read futures and
  failures, in addition to native arithmetic and slot parity.
- Validate full completion streams, actual token counts and cache coverage;
  retrieval failure prevents qualification. Do not confuse partial prefix
  restore with a full warm-cache result.
- Pin long-context receipts to the actual proposed width/chunk; reject failed
  or memory-aborted tests and changed checkpoint metadata. Hold session.lock
  during final deployment. Preserve max thinking in all profile layers.

Evidence of speed, long-context completion and retrieval comes from the run
receipts, not this code review. No ecosys scientific source or Zig build changed.

Final fresh-context read-only verification,2026-10-18:

VERDICT: PASS for the requested16K scope. Reviewer independently checked the
matched token/cache/output hashes and computed14.0% lower fresh latency,
17.3% higher prefill throughput and10.4% higher warm decode throughput.
Retrieval passed with unchanged shards and111.134GB peak below114GB.

The reviewer reproduced the initial production startup failure caused by an
unsupported8192 duration-floor environment setting. After retaining the measured
5632 floor, the corrected actual-router smoke passed: model loaded,chunk8192,
lookahead2,42x101/288slots,114GB cap,zero generation requests,owned backend
stopped. All installed hashes match deployment.json and rollback bytes exist.
Maximum thinking and12CPU I/O workers remain configured. Native arithmetic,
slot parity and failure-cleanup tests pass with current implementation hashes.

Limits: one matched fresh/warm pair per strategy and one retrieval case at16K;
larger contexts excluded. Reviewer ran no inference and edited no files.

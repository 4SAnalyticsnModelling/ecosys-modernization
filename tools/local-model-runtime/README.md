**Continuous autonomy:** No elapsed-time timeout at any stage of autonomous work. Follow
`.agent/continuous-autonomy.md` and `.agent/protocol.md`; older time/session/tool budgets
and timeout examples are superseded. Poll limits yield control; preserve and resume work.

# Qwen Flash rc1 production route

`deploy_rc1.py` promotes the installed Qwen Flash Next Q8 route to
**oMLX0.7.1rc1 / MLX0.32.4**. It updates the session-owned router, fallback
runtime selector and profile generator, and installs `qwen_flash_rc1.py` as the
native serving entry. Normal dsh/dst/dsh-tui sessions use it automatically;
there is no separate always-on daemon. Existing GLM and dense Qwen profiles
retain their settings.

The route uses `omlx-state-qwen-flash-rc1/` and its own cache, 60% expert
residency, 8192-token prefill chunks, native KV, adaptive MTP<=3 and a112GiB
memory guard. The earlier dev1 scheduler monkeypatch entry is not used. Startup
checks both package versions and interpreter/state identity. Orphan-process
recovery recognizes the new entry and requires the recorded start identity,
so recycled PIDs are not treated as owned.

Deployment is explicitly authorized to update the installed local-model runtime.
Original files are retained privately in `watchdog/rc1-production-backup/`;
`deployment.json` lists hashes and changed paths. No weights or upstream package
source are edited. Run `python3 tools/local-model-runtime/deploy_rc1.py` to
reapply this reviewed deployment. Its syntax/version checks run before writes.
If deployment fails, original configuration/source bytes are restored.

The production startup/load check is `smoke_rc1.py`, run with the installed rc1
Python. It takes the native session lock, refuses existing model listeners,
loads through the actual router, records command/status/server logs and stops
its owned backend. It issues **zero generation requests**. The earlier requested
single16K performance test remains the only speed benchmark.

Evidence: `audit/reviews/dsh-rc1-production-20261017/`.
Tests: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/local-model-runtime -p 'test_*.py'`.

# GLM Flash 6-bit tuning

The GLM6 route retains oMLX0.7.1rc1 / MLX0.32.4, the original six-bit
checkpoint, native KV, MTP depth1, LFU and101/288 resident experts per layer.
Qualified settings are12 CPU disk-I/O workers, bounded two-expert decode
lookahead,8192-token prefill and maximum thinking by default. GPU execution
uses MLX/Metal on one Apple GPU; there is no configurable GPU-worker count.

`glm6_lookahead.py` stages raw checkpoint reads only, with a shared512MiB
budget. True routing, expert arithmetic and slot writes remain native.
`check_glm6_lookahead.py` checks six-bit arithmetic/slot parity and exception
cleanup. `benchmark_glm6.py` isolates caches and records completion, memory,
cache coverage and checkpoint metadata; `glm6_16k_suite.py` compares the
strategies at exactly16384 prompt tokens. Only16K is qualified by this study.

`deploy_glm6_lookahead.py --candidate chunk8192-16 --width 2 --chunk 8192`
validates receipts and preserves original installed files before promotion.
It requires the predeployment source hashes and an unused backup directory;
it is intentionally not an idempotent reapply command. Keep the duration-floor
environment value5632: the existing guard accepts it, and GLM6 replaces the
adaptive scheduler after import. Actual fixed prefill width is8192.
`smoke_glm6.py` loads through the real router, issues zero generation requests,
and stops its owned backend. Normal sessions use the installed settings.

Evidence and rollback bytes: `audit/reviews/glm6-speed-20261017/`.

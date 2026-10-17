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

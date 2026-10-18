Task: user requires no shared mutable harness/runtime state between Herdr launches, local-model conversations, nested agents, or two instances of the same model. Actual smoke tests requested for every installed model and same-model isolation.
Verified shared paths: global TUI preferences/profile writes; installed session/router locks and ports; installed backend KV caches; launch-wide watchdog notes/index/checkpoints; parent supervisor reacting to child failures.
Design: immutable installed programs/model weights only; private copied controller/TUI configuration and runtime paths per launch, per-native-session watchdog notes/state/checkpoints, per-(session,model) backend worker with separate process/cache/ports, explicitly tagged requests and no missing-identity fallback. Public nested launches allocate new namespace. Read-only project workspace remains shared as user-opened workspace, not used for runtime state.
Evidence pending: unit/integration regressions, independent review, all-local-model live tasks, same-model two-instance check, global installation and Git sync.

Current continuation checkpoint:
- Source changes implemented under tools/dsh-watchdog; no science files touched. New isolation.py, session-paths.mjs, transport.mjs, execution-isolation.mjs; per-agent plugin/checkpoint/hygiene + isolated bootstrapPath for actual Node code mode; installer updated globally (latest TUI dependency/host-discovery fix still awaiting redeploy after Python tests).
- User additionally requires Qwen3.8 27B allowed prefill floor8192 plus16K fresh/cache prefill+decode speed. Tracked long_task_guard.py and installer now pin model-specific duration+memory floors8192; preserve bounded-work/memory guards (reject instead of silently lowering full chunks). Installed long-task-protections.json contains8192. Original first dense live check used old floor; last dense repeat and dedicated speed benchmark use new floor.
- Live sequential harness runner: tools in .tmp/model-isolation-live/run_checks.py, exec session3481. Read audit/reviews/dsh-full-isolation-20261017/live/{running,results,complete}.json. Dense Qwen and Qwen Flash passed real bash+answer385+private env tasks. Mixed GLM currently running with backend activity and private paths; six-bitGLM and dense-repeat next. Do not start competing GPU work or kill healthy tests due time.
- Benchmark driver tools/dsh-watchdog/benchmark-isolated.py is running in exec session52811, waiting for live/complete.json. Then performs exact16384-token fresh/cache and independent-same-model-fresh API requests, each128 generated tokens. Loads model beforeTTFT, uses private gateway routes, saves qwen16k/results.json and runner log. Must inspect actual cachedTokens and server prompt count, floor logs; cached effective throughput is distinct from recomputed-token throughput.
- 31Node tests passed (latest test runner session57467 completed PASS; earlier failures were fixtures missing root/runtime/sessionPersistence and were corrected). 17Python tests previously passed; current tests with latest copy_tui dependency fix session99252 pending.
- Native PTC independent verifier PASS after reproducing and fixing /tmp fallback: actual simultaneous runtimes use privateos.tmpdir and do not inherit secret sentinel. Receipts .tmp/ptc-isolation-verifier/{receipt,credential-receipt}.json. Need copy final receipts into review.
- TUI smoke first attempt found missing native package resolution in private copy; stopped only that owned failed test viaCtrlC (exec36801 exit254). Fixed private node_modules fallback to installed runtime, profile root fallback, direct installed native host discovery in private copy. Need redeploy and rerun actual tty dst startup, check no unresolved entries/socket failure and exit gracefully after ready. Copy_tui now includes perlaunch socket identity under repo/.s with <=103-byte path and .complete failclosed manifests. .s/ added.gitignore.
- Still needed: CPU socket/model-switch unit checks; independent final review of full runtime and8192floor; actual TUI smoke; finish all-model+same-model live checks; finalspeed report; docs update; commit only task files (unrelated audit/runs/zig017-replay-h4556-20261017 remains unstaged), pushmain verifysha.

## Superseding user scope and final validation

The user cancelled Qwen27 and GLM mixed4/8 and requested deletion. The earlier
8192floor and16K benchmark work above is superseded: benchmark controller stopped
before running, benchmark helper/floor changes removed.17 model/checkpoint/cache
paths deleted; GLM6's required4.3GB MTP head moved same-inode into its own directory
and validated. Only Qwen Flash Q8 and GLM6 remain in catalog/discovery/profiles.
Final installer regenerates Python profiles before rebuilding the model picker.

Real harness checks: Qwen Flash passed bash answer385 and privateTMPDIR; GLM6
native final/turn_end completed with ISOLATION_SMOKE_OK. Its parent runner had been
cancelled to prevent running the removed dense case, so no supervisor exit code
is inferred from that orphaned test. Fresh post-removal raw generations run each
retained model twice with separate session IDs, router processes and cache roots.

Python16 tests passed. Node28 passed initially,3 composition assertions still
expected4 models; updated those expectations to the user-selected2 and rechecked.
Fresh Node suite result is in node-tests.log. Independent read-only architecture
review G7PASS; retained overlay/dependency reviewPASS with no broken links.
No science changes; Zig/conservation gates are inapplicable to this harness task.
Unrelated audit/runs/zig017-replay-h4556-20261017 remains unstaged.

Final: all4fresh retained-model generationsPASS, distinctroots/PIDs and cachedTokens0.
31Node+16Python testsPASS, final installationPASS, post-removal TUI boot/exit0.

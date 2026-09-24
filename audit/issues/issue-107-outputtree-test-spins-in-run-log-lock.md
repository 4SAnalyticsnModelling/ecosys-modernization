# Issue 107 -- executable-root test 109 (OutputTree init) spins indefinitely after the run-log ownership test

Status: **OPEN** (found in run-034; reproduced in two consecutive runs).

- 109/115 `stages.run_support.test.OutputTree creates the full structured layout under a fresh output root` never finishes. CPU rises continuously (up to 1,063 CPU-s) with no output. It runs right after 108/115 `second active run-log writer is rejected without stealing ownership`, which passes and logs `first-owner-still-active`.
- `run_support.zig:322-331` `lockActiveRunLog` is a non-reentrant `cmpxchgWeak` spin/yield loop with no timeout. Candidates, neither verified: the lock is left held on a path through 108's rejection/replacement sequence, or it is re-entered (logging while holding the lock inside `OutputTree.init`). A leaked `active` registration would give `ActiveRunLogAlreadyRegistered`, not a spin, so a held lock is the likelier explanation.
- Production impact unknown. Production runs start normally, which suggests the path is sequence-dependent. Worth knowing because a spin with no timeout inside a logger would present in production as a silent hang.
- Next: run `--test-filter "OutputTree creates"` alone (does it pass in isolation?), then 108 and 109 together. Then find the unreleased or re-entered path. Tests 110-115 cannot be assessed until this is fixed.

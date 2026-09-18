# Issue 008 -- underscore-to-hyphen root rename via robocopy /MOVE deleted the whole tree as one unit mid-move; fully recovered from Recycle Bin

Status: **RESOLVED 2026-09-18.**
Owner: this session (ecosys-modernization-88), coordinating with `ecosys-modernization-af` (which owns/owned the git repo and issue-005/001/007 fixes described below).

## Summary

Separate from and later than issue-005 (missing `src/validation`/`src/index`, root-caused as an incomplete copy). After issue-005's fix (and issue-001/issue-007's fixes) were committed to a real git repo (7 commits) at `D:\ecosys_modernization` (underscore), the user asked that session to rename the root to `D:\ecosys-modernization` (hyphen, matching this project's actual final location) and sync to a newly created GitHub remote (`https://github.com/4SAnalyticsnModelling/ecosys-modernization`). It ran `robocopy /MOVE /E`; the driving tool call was interrupted by the user partway through; something (not root-caused; possibly Explorer, an AV scan, or the interrupted robocopy's own cleanup pass) then deleted the **entire destination folder as one unit** at approximately 2026-09-18 08:58:22, routed to the Recycle Bin (not permanently lost).

## Failure signature and evidence

Observed by this session and independently corroborated by `ecosys-modernization-af`:
- `.git` absent from both `D:\ecosys_modernization` and `D:\ecosys-modernization`.
- `D:\ecosys_modernization\.claude` present but recursively empty (0 files).
- `ecosys-ng` file counts nearly identical between old/new roots (~1094 vs 1093) -- the bulk `ecosys-ng/src` content copy had already completed before the deletion; only root-level dotfiles/docs/audit folders and `.git` were affected.
- `ecosys-ng/build.zig` and `ecosys-ng/build.zig.zon` were missing from the live tree (these ARE tracked in git; they came back via `git checkout HEAD --` once `.git` was restored -- see Resolution).
- GitHub remote `https://github.com/4SAnalyticsnModelling/ecosys-modernization` (created by the user the same day) had exactly one unrelated "Initial commit" (LICENSE + README) with no common ancestor to the local history -- initially alarming, but this is simply because the remote was brand new, not evidence of further loss.

## Resolution

`ecosys-modernization-af` located the pre-deletion snapshot in `D:\$Recycle.Bin\$R56SHGC`, independently verified via `git --git-dir=...\$R56SHGC\.git fsck --full` (clean, no corruption) and `git log --oneline --all` (all 7 commits present: `b9a7afc` gitignore/managed-instructions -> `ca20a64` preserve legacy Fortran -> `514dd68` add ecosys-ng+prod example deck -> `d602587` add audit skill pack -> `a780908` mark binaries explicit -> `5add7de` issue-007 fix -> `97a33a9` issue-001 fix).

This session performed the actual restore, by explicit user instruction to proceed (after a period of both sessions waiting on each other's confirmation loops caused unnecessary delay -- see below):
1. `robocopy $src $dst /E /COPY:DAT` (no `/MOVE`, no `/MIR`, no `/PURGE` -- strictly additive merge, nothing at the destination deleted) for `.git`, `.agents`, `.claude`, `audit`, `ecosys-audit`, `ecosys-audit-skill-pack`.
2. Plain `Copy-Item -Force` for the four root files: `.gitattributes`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`.
3. `git config --global --add safe.directory D:/ecosys-modernization` (needed once, dubious-ownership check on this filesystem).
4. `git status --porcelain -uall` against the now-present `.git` and the already-correct `ecosys-ng`/`ecosys-ng-prod-examples`/`f77example`/`f77src` content: exactly 3 differences -- `ecosys-ng/build.zig` deleted, `ecosys-ng/build.zig.zon` deleted, one new untracked file (this session's own preliminary git-loss note, since superseded by this issue file).
5. `git checkout HEAD -- ecosys-ng/build.zig ecosys-ng/build.zig.zon` restored both tracked files exactly. Working tree then clean except the one new untracked file, which was staged by explicit path and committed (`cccd155`).

## Verification (new, real evidence -- supersedes/confirms issue-005's last recorded number)

`zig test src\module_index.zig` (direct invocation, from `D:\ecosys-modernization\ecosys-ng`, full run to completion, not filtered): **4286 passed; 1 skipped; 0 failed** (4287 total), exit code 0. This is a full-suite confirmation, not the 52-test filtered check issue-005 recorded, and confirms the issue-005 and issue-001/007 fixes all survived the move/recovery intact. `ecosys-modernization-af` independently re-verified `git log`/`git status --porcelain -uall` clean after this session's restore.

## Process notes worth keeping (both sessions made the same mistake independently)

Both this session and `ecosys-modernization-af` separately misdiagnosed a long-running `zig build test` / direct `zig test` invocation as "hung" based on `Get-Process`'s cumulative `CPU(s)` counter staying flat across multi-minute windows, and killed multiple legitimate runs on that basis. The counter is not a reliable liveness signal for this workload (many cheap, short tests; buffered output not flushed until exit or a large threshold). The correct check is to inspect actual output content (`Tee-Object`/redirected log tail showing `N/4287 ...OK` advancing), not process CPU-seconds alone. Recommend this as a standing note for any future session running this test suite: **do not kill a `zig test`/`zig build test` invocation based on flat CPU alone; check the output log first.**

## Remaining follow-up (not blocking)

- The GitHub remote merge (`fetch` + `--allow-unrelated-histories`, keeping the remote's LICENSE/README and this project's 8 commits on top) was performed by `ecosys-modernization-af`; the actual `push` to `origin/main` was intentionally held pending that session's own user confirmation (single-owner discipline for the one genuinely hard-to-reverse shared-state step). Check `git log --oneline --all` / `git remote -v` / `git status` fresh before assuming the push has landed by the time this is read.
- `D:\ecosys_modernization` (old, underscore) still exists on disk as of this writing and has not been cleaned up; it may still hold the now-redundant partial copy. Do not delete it without confirming the hyphenated copy is fully verified and pushed first.

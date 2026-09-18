# Issue 000: prior git history not recoverable from disk or GitHub (open, sync blocked)

**Status:** open — documented per contract ("if sync is blocked, document why and continue local work"); local audit work continues without git in the meantime.

**Date:** 2026-09-18

## Summary

A peer session (`ecosys-modernization-af`) reported having built a git repo at the (then-canonical) `D:\ecosys_modernization` root with 5+ real commits: audit setup, `issue-005` fix (restoring `src/validation`/`src/index`), `issue-007` ammonium-multiplier fix, `issue-001` `build.zig.zon` fix. The user asked that peer to rename `D:\ecosys_modernization` → `D:\ecosys-modernization` and sync to `https://github.com/4SAnalyticsnModelling/ecosys-modernization`. The peer ran `robocopy /MOVE /E`, was interrupted mid-tool-call, and reported the underlying `robocopy.exe` process might still be running unattended.

## Verified facts (this session, read-only checks only)

- `.git` does **not** exist under `D:\ecosys_modernization` or `D:\ecosys-modernization` (`Test-Path` both false).
- `D:\ecosys_modernization\.claude` exists but is recursively **empty** (0 files).
- `ecosys-ng` file counts are consistent between old/new roots (1094 vs 1093 files) — the bulk content copy largely completed.
- No `robocopy.exe` process is currently running (checked via `Get-Process`).
- The GitHub remote `https://github.com/4SAnalyticsnModelling/ecosys-modernization` exists and is reachable, but contains exactly **one** commit (`637b757`, "Initial commit", `LICENSE` + `README.md` only) — not the peer's claimed 5+ commits. Checked via `git ls-remote` and a clone into an isolated scratch directory; **no writes were made to either project root or to the remote**.

## Interpretation

The claimed git history (audit setup + 3 fixes) is not currently recoverable from either local disk path or from GitHub. It may exist in a reflog, stash, bundle, or a location not yet checked by either session. Recovery is the peer's investigation to complete — pinging back and forth to re-verify disk state does not change the facts above.

## Guard-rail while open

- Do not `git init` at `D:\ecosys-modernization` root in a way that fabricates fresh history in place of the real one.
- Do not push/force-push to the GitHub remote until recovery is confirmed one way or the other.
- Do not delete or overwrite anything under `D:\ecosys_modernization` (old path) until it's confirmed safe to do so — it may still hold recoverable state.

## Unblocked work in the meantime

Per contract: local audit work (reading references, building the contract docs, Fortran-side verification, inventory) proceeds without git. `ecosys-audit/` itself, `AGENTS.md`, `CLAUDE.md`, and `PROJECT_CONTRACT.md` are being authored fresh in this session since none were found on disk anywhere reachable (confirmed via targeted search of `D:\ecosys-modernization`, `D:\ecosys_modernization`, `D:\EcosysModernization`, `D:\ecosys_source_codes_June10_2026`, and the OneDrive reference copy). If the peer's original versions resurface, reconcile by diff — do not silently overwrite either version.

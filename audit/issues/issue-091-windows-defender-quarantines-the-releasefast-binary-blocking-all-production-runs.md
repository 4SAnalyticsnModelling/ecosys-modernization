# Issue 091 -- Windows Defender quarantines the `ReleaseFast` binary as `Trojan:Win32/Bearfoos.A!ml`, blocking every production run

Status: **OPEN, ENVIRONMENT BLOCKER, REQUIRES A USER DECISION (filed 2026-09-22, adversarial Claude/Pi session).** This is not a code defect and cannot be resolved from inside the audit. **No production run can be executed until it is resolved**, so `issue-090`'s fix is committed and unit-validated but has **no production validation**.

## What happens

Windows Defender detects the freshly built `ecosys_ng.exe` as malware and blocks read access to it, which both kills runs in flight and prevents staging a new copy.

```
ThreatName : Trojan:Win32/Bearfoos.A!ml
ThreatID   : 2147731250
SeverityID : 5
```

Three detections, in order, from `Get-MpThreatDetection`:

| time | resource |
|---|---|
| 2026-09-22 03:09:48 | `<scratchpad>\ecosys_ng_run020.exe` |
| 2026-09-22 03:09:56 | `<scratchpad>\ecosys_ng_run020.exe` |
| 2026-09-22 03:21:01 | `D:\ecosys-modernization\ecosys-ng\ecosys-ng-bin\ecosys_ng.exe` |

Observed symptoms, in the order they appeared and were misread:

1. `run-020` launched normally and advanced to hour ~103, then died. Its stderr log ends **mid-write** (`... l4=`) with **no `error:` line** -- not a model failure.
2. The staged executable had vanished from the scratchpad.
3. Re-staging failed: `Copy-Item` and `Get-FileHash` on the build output both return *"Operation did not complete successfully because the file contains a virus or potentially unwanted software."*
4. `Get-Item` still succeeds (metadata), but `[System.IO.File]::OpenRead` is blocked, so the file appears to exist while being unreadable.

The `!ml` suffix marks this a **machine-learning heuristic** detection, which is the usual signature of a false positive on a freshly compiled, unsigned executable. Nothing about the build changed in a way that would plausibly introduce malware: the binary is produced by `zig build -Doptimize=ReleaseFast` from this repository's own source, and the immediately preceding builds of the same tree ran fine (`run-013` through `run-019`).

## Non-privileged workarounds

> ### CORRECTION 2026-09-22: the claim below that "all three" were tested is OVERSTATED
>
> Three were tested. **A fourth and fifth were never tried: `ReleaseSafe` and `ReleaseSmall`.**
> That is a real omission, not a quibble, because this issue's own key observation is that
> **the detection follows the binary's *content*, not its path** -- and a different
> optimisation mode is precisely a change of content. Workaround 3 already demonstrated the
> principle by showing the **Debug** binary is readable while ReleaseFast is not. `ReleaseSafe`
> sits between them in codegen and is far faster than Debug.
>
> It matters doubly because `tools/production_performance_reference.json` (reference tree,
> `issue-097`) has id **`strict-releasesafe-throughput-pending-v3`** and requires "a passing
> strict-production **ReleaseSafe** run". So `ReleaseSafe` is not merely an untested
> workaround -- **it is the build the performance baseline is specified against**, and every
> attempt recorded in this issue targeted the wrong optimisation mode for criterion 3.
>
> A `ReleaseSafe` build is under way; result recorded below when it completes. See
> `audit/analysis/criterion-3-performance-status-reconciliation-2026-09-22.md`.

Tried before escalating, so the blocker is substantiated rather than assumed. None of these changes the machine's security posture.

1. **Build to a different output path** (`zig build -Doptimize=ReleaseFast --prefix <scratchpad>/build021`). **Fails.** The install step cannot copy the artifact out: `error: unable to update file from 'C:\zig-local-cache\ecosys-ng\o\639dd8...\ecosys_ng.exe' to ...`.
2. **Run the artifact directly from the Zig cache**, where the build put it. **Fails.** `Get-FileHash` on `C:\zig-local-cache\ecosys-ng\o\639dd8433923fcf565419de00c9bcb79\ecosys_ng.exe` returns the same virus error. So the detection follows the **content**, not the path -- an alternate location cannot help.
3. **Build in Debug instead** (different content, so potentially under the heuristic). **The Debug binary IS readable** -- hash `296EFE4358750853CCDC5C8E88DD8FD23870BDDA9ED7E9B6050E65A2E22B5C34` -- so the detection is specific to the `ReleaseFast` output. But Debug is **far too slow to reach the frontier**: measured at **~87 s per simulated hour** (`elapsed_ms=87142` at `scene_weather_hours=8`), which puts hour 3,276 at roughly **79 hours** of wall clock, and it emitted **63 MB of log in 7 minutes**. Run stopped and its log deleted to reclaim disk.

Result: the ReleaseFast binary is unusable, and the only readable build is ~1000x too slow for this frontier. There is no non-privileged path to a production run.

**Useful side finding**: since the Debug build is readable, unit tests, `zig build`, and short diagnostic replays all still work. Only full-deck production runs are blocked. Source work can continue; only `run-*` validation cannot.

## Why it is not being worked around here

Adding a Defender exclusion, disabling real-time protection, or restoring the file from quarantine all require elevated privileges and change the security posture of the user's machine. `PROJECT_CONTRACT.md` prohibits installing privileged tools or altering the environment as a side effect of an audit, and an antivirus exclusion is precisely that kind of change. It is the user's call, not the audit's.

Repeatedly rebuilding is also not a workaround: the detection fired on the build output directly, so a rebuild lands in the same place.

## Impact

- **`issue-090`'s fix is committed and unit-validated but NOT production-validated.** Full suite 4376 passed / 1 skipped / 0 failed (zero regressions), `zig build` and `-Doptimize=ReleaseFast` both exit 0, and the activation is pinned by a test against hand arithmetic -- but whether hour 3,276 actually clears is **unknown**.
- `run-019` (the previous binary, before the NO3 gate correction) did produce a real result: hour 3,276 failing `MineralNitrogenInZeroWaterDomain`, which is what identified the gate defect. So the diagnosis chain is sound; only the confirmation of the final fix is missing.
- Every future production run is blocked until resolved.

## What the user can choose

1. **Add a Defender exclusion** for `D:\ecosys-modernization\ecosys-ng\ecosys-ng-bin\` and the session scratchpad path, which is the narrowest change that unblocks runs. Folder exclusions are preferable to disabling real-time protection.
2. **Submit the binary to Microsoft as a false positive** (the durable fix for an `!ml` heuristic hit) and add an interim exclusion.
3. **Sign the binary**, which usually stops heuristic detections on self-built executables, if a code-signing certificate is available.

Option 1 is the minimum needed to resume. Whichever is chosen, note that Defender may have already **quarantined or deleted** earlier staged copies, so a fresh `zig build -Doptimize=ReleaseFast` will be needed after the exclusion is in place.

## Reproduction / verification

```
Get-MpThreatDetection | Sort-Object InitialDetectionTime -Descending | Select-Object -First 3 InitialDetectionTime,ThreatID,Resources
Get-MpThreat | Where-Object ThreatID -eq 2147731250 | Select-Object ThreatName,SeverityID
Get-FileHash 'D:\ecosys-modernization\ecosys-ng\ecosys-ng-bin\ecosys_ng.exe'   # fails while blocked
```

## Note for whoever resumes

Do not mistake this for a model defect. The signature is distinctive: a run that stops at an arbitrary hour with a **truncated final log line and no `error:` record**, plus a missing or unreadable executable. Every genuine model failure in this project's run records ends with an explicit `error: <ErrorName>` line and a complete stage census. If those are absent, check `Get-MpThreatDetection` before diagnosing anything else.

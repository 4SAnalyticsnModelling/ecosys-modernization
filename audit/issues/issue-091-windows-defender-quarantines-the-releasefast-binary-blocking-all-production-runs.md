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

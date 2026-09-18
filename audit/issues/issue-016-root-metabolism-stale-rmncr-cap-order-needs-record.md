# Issue 016 -- root growth-respiration RMNCR cap uses stale prior-axis value in legacy; Zig deliberately corrected but has no formal review record

Status: **CLOSED (fix already correct and live), documentation gap only.** Found via a `grosub.f` root-growth-section deep-dive; the underlying behavior is right, but per contract's evidence discipline a defect correction needs its own record, not just an inline comment.

Owner: found by this session's audit fork, 2026-09-18.

## What's wrong (in the legacy oracle) and how Zig corrects it

`f77src/grosub.f:6544-6559` (primary-root growth-respiration branch): the O2-unlimited substrate respiration cap is applied as `RCO2RM=AMIN1(RMNCR,RCO2RM)` (`:6546-6553`) **before** `RMNCR` is reassigned for the current axis on the very next statement (`RMNCR=AMAX1(0.0,RMPLT*...)`). This means the cap consumes a **stale `RMNCR` left over from the previous loop iteration/axis**, not the current axis's actual maintenance demand -- a genuine legacy traversal-order artifact, independently re-verified this session by direct reread of `grosub.f:6544-6559`.

`ecosys-ng/src/plant/root/plant_root_metabolism_growth.zig:238-241` (sha256 `DAEACE7CA6C7AE5315CF667242338B00CD5144563093A99A2C189810D8CFA302`) explicitly documents this as a legacy traversal-order artifact and deliberately uses the **current** axis's maintenance demand instead, gated by `cap_substrate_to_current_maintenance` -- only `true` for a primary tip at/below the profile bottom, matching `RTDP1X.GE.CDPTHZ(NJ,...)` at `grosub.f:6550`. Call site verified: `ecosys-ng/src/stages/root_processes_metabolism.zig` (sha256 `AE91A24A5A86697C2DFEBC7C686398BFBC1348BB29D68B110554999391421C20`, `:406-407`), gate condition `layer+1 == active_soil_layer_count` matches the cited Fortran condition.

## Why this is filed as an issue despite being correct

Grep of `ecosys-ng/src/plant/root/*`, `ecosys-audit/`, and `audit/` found **no `BIND-GROSUB-###`-style issue tag or filed feature-register entry** for this specific correction -- only the inline code comment. Per `PROJECT_CONTRACT.md`'s "Completion and honest status" section, a defect correction needs its own reproducer/review record, not just a comment living in the source. This issue exists to give it that record.

## Disposition

`legacy-defect-corrected`, **already fixed and live** -- this is a paperwork/traceability gap, not a runtime defect. No further code action needed.

## Evidence

`D:\ecosys-modernization\f77src\grosub.f:6544-6559` (also see the near-duplicate secondary-axis block at `:6119-6125` for context, unaffected by this specific ordering issue); `D:\ecosys-modernization\ecosys-ng\src\plant\root\plant_root_metabolism_growth.zig:208-281,238-241`; `D:\ecosys-modernization\ecosys-ng\src\stages\root_processes_metabolism.zig:406-407`.

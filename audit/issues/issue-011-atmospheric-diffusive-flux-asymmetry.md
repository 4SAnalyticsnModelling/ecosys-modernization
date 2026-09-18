# Issue 011 -- atmospheric diffusive gas flux asymmetry (fixed; giving it a proper record)

Status: **CLOSED.** This is a real fix that was already applied and tested in the Zig codebase, but had no `audit/issues/` or `audit/features/` entry -- found via source-embedded evidence during a `trnsfr.f`/`trnsfrs.f` audit pass and given a proper record here per this project's evidence discipline (a fix should not live only in a code comment).

Owner: found by this session's audit fork, 2026-09-18.

## What was wrong

`ecosys-ng/src/soil/gas/transport.zig`'s `atmosphericDiffusiveFluxG` (mapping to `f77src/trnsfr.f:5303-5306,5777-5778`) previously used an unconditional `min` to select between two candidate equilibrium endpoints when computing the atmosphere-soil diffusive gas flux. Per the Zig doc comment at `transport.zig:470-473`: "The former unconditional `min` was correct only for inward diffusion; on an outward gradient it selected the more-negative equilibrium endpoint and evacuated the pool regardless of conductance."

## Fix

The function now branches on gradient direction so an outward-diffusing gas pool is bounded by its actual conductance rather than always taking the more-negative candidate. Regression test at `transport.zig:481` (name not independently re-read in full this pass, but its presence confirms behavioral coverage of both directions).

## Disposition

`legacy-defect-corrected`. This is a genuine Zig-side translation-defect fix (not a change to the underlying legacy equation's intent), already applied and tested. No further action needed beyond this record existing.

## Evidence

`D:\ecosys-modernization\f77src\trnsfr.f:5303-5306,5777-5778`; `D:\ecosys-modernization\ecosys-ng\src\soil\gas\transport.zig:450-479,547-567,586-645` (also documents a second, deliberately-`preserved` legacy quirk in `adjacentPressureDrivenFluxesGFromValidatedInputs`: `trnsfr.f`'s "dimensionally inconsistent mol-vs-g `AMIN1`" bound, intentionally kept rather than fixed -- not a defect, called out as deliberate).

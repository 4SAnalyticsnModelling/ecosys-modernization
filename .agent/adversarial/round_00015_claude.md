# Round 00015 — CLAUDE synthesis: freeze-thaw relayering drained the top layer's solids (hour 4037)

Symptom: hour 4037 `SoilHeatRenormalizedTemperatureOutsidePhysicalDomain` (layer 0, 127 K) because layer 0's
dry heat capacity was 1e-8 MJ/K; Richards then moved 2.6e-3 m3 UP from layer 1 into it (not rain; external 0).

Measured (fresh hour-0 diagnostic run r00006-diag, deck ecf5e61a):
- layer-0 dry density 1.108 MJ m-3 K-1 and BD 1.28 through hour ~1600; from spring thaw (~hour 1608) relayering
  pushed layer 0 → layer 1 at fx = 5%, 9%, 14.6% ... per hour while layer 0 grew only ~3%; by hour 2160 dry density
  was 1.9e-3 and BD 0.586; by hour 4037, 1e-6.
- Cause: `relayering.zig` DDLYRX = pond + freeze_thaw + erosion + SOC. `assembleFreezeThawBoundaryChangeM` makes
  the layer-0/1 boundary shift the cumulative DVOLI of the whole column below, so every thaw hour moved
  |sum| / DLYR(NU) of the top layer's material downward.
- Legacy `redist.f:8186-8187`: for soil (BKDS>0, IFLGM=1) DDLYRX = CDPTHY − CDPTHX, and CDPTHY excludes freeze-thaw
  (8065/8087: CDPTHY=CDPTHX for NN=2). Freeze-thaw moves CDPTH only; material crosses boundaries through
  freeze-thaw only when IFLGK(L)=1 (pond layer at/below L, 8194-8195).

DEEPSEEK r00015 correctly identified relayering as the drain and the rebase design issue, but blamed the
remap's FX split itself; the defect is the driver (freeze-thaw leg), not the split.

Fix: `freezeThawDrivesTransfer` (IFLGK) gates the freeze-thaw leg out of the material driver; geometry still
applies it. Three tests that used freeze-thaw as a generic driver now use the SOC leg; new regression test
"REDIST freeze-thaw moves soil boundaries without transferring soil material". Filters REDIST, DISC-WATSUB-002,
EXEC-002, freeze, relayer, geometry, thaw all pass.

Not ported (noted): legacy DDLYRY restore of DLYR to DLYRI (8188/8199) and the IFLGM=0 DDLYRX=DLYRI−DLYR1 branch.
Also open: Richards→rebase intermediate temperature can still leave the domain for a genuinely low-capacity layer.

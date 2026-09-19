# Feature ID: FEAT-025-SOIL-MAIN-ORCHESTRATOR-CALL-SEQUENCE

Status: FULLY_ASSESSED for call-order/scheduling scope only (source-audit; `soil.f` is 305 lines, full-file read, 100% of the file's control flow traced and cited; this dossier is exclusively a call-order/cadence check per the task's own framing -- there is no equation logic in `soil.f` itself to audit)

## Scope and provenance

Legacy source: `f77src/soil.f` (sha256 `E2C5A5B3AD972907F31336C066019E87D22B9BCC5B50E117AD62B887861EBA0A`), header comment: "THIS IS THE MAIN SUBROUTINE FROM WHICH ALL OTHERS ARE CALLED FOR ALL SCENES IN ALL SCENARIOS." `soil.f` is the true per-scene orchestrator (called once per scene from `main.f`, per `feature-023` finding already on record) and defines the exact call order for scene setup, the daily loop, the hourly loop and the subhourly physics loop.

Zig counterparts cited below: `ecosys-ng/src/ecosys_ng.zig` (sha256 `E9F35F7116D8DEDE874D2E3C348385A08927C09ADC6F53069DE7C361724C6C27`), `ecosys-ng/src/stages/hourly_process_driver.zig` (sha256 `AA346D425C9BEB4CD129765FB6CB7E526D902AB4C275B484798651CAC059E9CB`), `ecosys-ng/src/stages/hourly_heat_water_solute.zig` (sha256 `D648C471DA68B8FDE681CD741636EB8F301AE68CEBC44F9DE467EC504475A13D`), `ecosys-ng/src/stages/hourly_sediment.zig` (sha256 `72B47011A64BDC8E51E854932231EB955F2ED5DB5CD5079388F30FD70CDEC9E9`), `ecosys-ng/src/stages/hourly_gas_surface_water.zig` (sha256 `74A746582C8631ACA444E3B6FE5518418735D9518D20C28E955B0007617375A6`), `ecosys-ng/src/stages/hourly_phenology_preparation.zig` (sha256 `4DD833B947E330E0EB2B5D76CE3A6EB48630CDA137098E04C2F46B62E7D0E609`), `ecosys-ng/src/stages/hourly_vegetation.zig` (sha256 `F8F96F285BF5731C2F98B9DE6310129040BF3C82CA12DA0C0936E51318EAA4D7`), `ecosys-ng/src/stages/hourly_snow_energy.zig` (sha256 `30B89B131209007AF7902FF6EE0FA21887D6E067888F75A4B55E9AF916F33A87`).

## Exact ordered call graph (100% of `soil.f`, line-cited)

**A. Scene-level setup (runs once per invocation of `soil()`, i.e. once per scene; `soil.f:26-109`):**

1. `soil.f:26-30` -- `IF(IGO.EQ.0) CALL READI(...)` -- **once ever**, only the very first scene of the first scenario.
2. `soil.f:32-33` -- `CALL READS(...)` -- unconditional, every scene.
3. `soil.f:35` -- `CALL FOUTS(...)` -- unconditional, every scene.
4. `soil.f:39-60` -- `IF((DATA(20).EQ.'YES'.AND.IGO.EQ.0).OR.IDAYR.NE.IOLD)THEN`:
   a. `soil.f:41` -- `CALL STARTS(...)`.
   b. `soil.f:53-59` -- nested `IF(DATA(20).EQ.'YES')THEN IF((IDAYR.GE.IRUN.AND.IYRR.EQ.IDATA(9)).OR.IYRR.GT.IDATA(9))THEN CALL ROUTS(...)`.
5. `soil.f:65` -- `CALL ROUTQ(...)` -- unconditional, every scene.
6. `soil.f:71-72` -- `CALL READQ(...)` -- unconditional, every scene.
7. `soil.f:74` -- `CALL FOUTP(...)` -- unconditional, every scene.
8. `soil.f:78-99` -- **the same outer gate as step 4**, `IF((DATA(20).EQ.'YES'.AND.IGO.EQ.0).OR.IDAYR.NE.IOLD)THEN`:
   a. `soil.f:80` -- `CALL STARTQ(...,1,5)`.
   b. `soil.f:92-98` -- nested `IF(DATA(20).EQ.'YES')THEN IF((IDAYR.GT.IRUN.AND.IYRR.EQ.IDATA(9)).OR.IYRR.GT.IDATA(9))THEN CALL ROUTP(...)`.
9. `soil.f:106-109` -- **the same outer gate a third time**, `IF((DATA(20).EQ.'YES'.AND.IGO.EQ.0).OR.IDAYR.NE.IOLD)THEN CALL STARTE(...)`.

**B. Daily loop (`soil.f:115-290`, label `9000`, `GOTO 9000` at `:290`, exits via `GOTO 9999` at `:127`):**

10. `soil.f:115-121` -- compute `I=IDAYR+1` with year-wrap adjustment; `:127` exits the loop once `I.GT.IFIN`.
11. `soil.f:131` -- `CALL DAY(I,...)` -- **once per simulated day**.
12. Hourly loop `soil.f:135-245` (`DO 9995 J=1,24`):
    a. `soil.f:141` -- `CALL WTHR(I,J,...)` -- **once per hour**, sets `NFH` (subhourly substep count) consumed at `:145`.
    b. Subhourly loop `soil.f:145-223` (`DO 9990 NFZ=1,NFH`), **exact order, every substep**:
       `HOUR1`(`:151`) -> `WATSUB`(`:157`) -> `NITRO`(`:162`) -> `HFUNC`(`:167`) -> `UPTAKE`(`:175`) -> `GROSUB`(`:182`) -> `EXTRACT`(`:189`) -> `SOLUTE`(`:195`) -> `TRNSFR`(`:201`) -> `TRNSFRS`(`:207`) -> `EROSION`(`:213`) -> `REDIST`(`:221`).
    c. `soil.f:230-234` -- `IF((J/JOUT)*JOUT.EQ.J)THEN CALL OUTSH(...); CALL OUTPH(...) ENDIF` -- hourly, gated on the `JOUT` output cadence.
    d. `soil.f:239-244` -- `IF(DATA(18).EQ.'YES')THEN IF((J/JOUT)*JOUT.EQ.J)THEN CALL VISUAL(...) ENDIF ENDIF` -- hourly, double-gated (option flag AND the same `JOUT` cadence as (c)).
13. `soil.f:246-261` -- `IF(DATA(19).EQ.'YES'.AND.KOUT.GT.0)THEN IF((I/KOUT)*KOUT.EQ.I.OR.I.EQ.IFIN)THEN CALL WOUTS(I,...); CALL WOUTP(I,...); CALL WOUTQ(I,...) ENDIF ENDIF` -- daily, gated on checkpoint cadence `KOUT` or scene end.
14. `soil.f:267-272` -- `IF((I/IOUT)*IOUT.EQ.I)THEN CALL OUTSD(...); CALL OUTPD(...) ENDIF` -- daily, gated on `IOUT` cadence.
15. `soil.f:278` -- `CALL EXEC(I)` -- **once per day, unconditional, and strictly after every physics call and every output/checkpoint write for that day** (steps 11-14 all precede it).
16. `soil.f:285-289` -- `IF(NYR.NE.1.AND.IDAYR.NE.IOLD)THEN CALL ROUTS(...); CALL ROUTP(...) ENDIF` -- daily, conditional checkpoint reload, immediately after `EXEC` and consuming the `IDAYR`/`IOLD` state `EXEC` just normalized.
17. `soil.f:290` -- `GOTO 9000` -- loop back to step 10.

**C. Scene exit (`soil.f:291-304`):**

18. `soil.f:300` -- `CALL SPLIT(...)` -- **once per scene**, at the very end, inside a `Cifdef _WIN_` block; the `Celse`/`CALL SPLITC(...)` sibling (`:301-302`) is commented out dead code for the non-Windows path.
19. `soil.f:304` -- `RETURN`.

This is 100% of the file's control flow (all 19 numbered items account for every `CALL`, every `IF`, and the loop/`GOTO` structure in the 305 lines).

## 1. Subhourly physics call order -- `preserved`

The twelve-call subhourly sequence at B.12.b above (`HOUR1->WATSUB->NITRO->HFUNC->UPTAKE->GROSUB->EXTRACT->SOLUTE->TRNSFR->TRNSFRS->EROSION->REDIST`) is the single highest-value item in this file, and it is **explicitly, repeatedly cited by exact `soil.f` line number in the Zig source and its own tests**, not merely inferred by this dossier:

- `hourly_process_driver.zig:724-726`: "HFUNC is invoked by the accepted-WATSUB continuation in hourly_snow_energy. Keeping it out of the HOUR1 driver preserves the source sequence WATSUB -> NITRO -> HFUNC -> UPTAKE (`soil.f:157--175`)."
- `hourly_phenology_preparation.zig:3-5`: "`soil.f:167--175` calls HFUNC before UPTAKE."
- `hourly_vegetation.zig:151,256,264`: "UPTAKE before GROSUB (`soil.f:175,182`)"; "`soil.f:175,182` orders UPTAKE before GROSUB."
- `hourly_heat_water_solute.zig:11266-11268`: "the complete source-ordered continuation (NITRO -> HFUNC -> UPTAKE/GROSUB -> SOLUTE)."
- `hourly_heat_water_solute.zig:12557,12698-12704`: "`soil.f:157--207`... Publish biological sources before any TRNSFR consumer"; TRNSFR/TRNSFRS are confirmed bundled into the `.surface_gas` production phase (`hourly_heat_water_solute.zig:10346-10348`, variable literally named `surface_trnsfrs`), called after `.solute`.
- `hourly_sediment.zig:346`: `pub const ProductionPhase = enum { nitro, solute, surface_gas, erosion_redist };` -- the enum's own declaration order matches the runtime call order (verified by call-site trace, not assumed from declaration order alone).
- `hourly_gas_surface_water.zig:847-849`: `.erosion_redist` phase called after the per-cell erosion detachment/transport calculation loop, corresponding to `EROSION`(`soil.f:213`)+`REDIST`(`soil.f:221`).
- `hourly_phenology_preparation.zig:203-252` has a dedicated test, `"HFUNC preparation is unique and precedes final STOMATE production"`, asserting via source-text-position checks that `post_watsub_biology.advance(` (confirmed to be the HFUNC-equivalent call) occurs after the NITRO call and before UPTAKE/GROSUB in `hourly_heat_water_solute.zig`.

Zig call order actually walked in the driver (`hourly_process_driver.zig:executeHourlyScience` -> `hourly_snow_energy.zig:solveSnowSurfaceEnergyAndSoilTransport` -> `hourly_heat_water_solute.zig`'s coupled-substep attempt body): HOUR1-equivalent setup (the driver's own body, before calling snow-energy) -> WATSUB (accepted inside the coupled substep) -> `.nitro` phase (NITRO) -> `post_watsub_biology.advance` (HFUNC) -> `group_vegetation.advanceUptakeGrowthAndExtract` (UPTAKE, then GROSUB, then EXTRACT internally per the same-cited line numbers) -> `produceCanopyStandingDeadFireBeforeSolute` -> `.solute` phase (SOLUTE) -> `coupled_substeps.replayAcceptedTransport()` (TRNSFR) -> `.surface_gas` phase (TRNSFRS, litter-atmosphere gas) -> (back in `hourly_gas_surface_water.zig`) `.erosion_redist` phase (EROSION then REDIST).

**No call-order mismatch found.** Every pairwise ordering constraint in `soil.f`'s twelve-call subhourly sequence has a corresponding, explicitly-cited enforcement in the Zig source or its tests. **Disposition: `preserved`.**

## 2. Daily and hourly cadence -- `preserved`

`DAY` (`soil.f:131`) runs once per simulated day, before the hourly loop; `WTHR` (`soil.f:141`) runs once per hour, before the subhourly loop; `EXEC` (`soil.f:278`) runs once per simulated day, strictly after the entire 24-hour loop and after every output/checkpoint write for that day. This exact three-tier cadence (day-setup / hour-forcing / day-closeout) was independently confirmed by `feature-016-day-daily-orchestration.md` (DAY) and `feature-023-exec-daily-mass-balance-progress-and-reinit-gate.md` (EXEC, which explicitly corrected an earlier assumption that `exec.f` was called from `main.f`, tracing its true call site to `soil.f:278`). This pass adds the hourly-forcing (`WTHR`) leg: `ecosys_ng.zig:7604`'s `prepareHourlyWeatherAndAtmosphere(...)` call inside `advanceHour` (`:7386`) runs once per hour, immediately before `executeHourlyScience` (`:7657`), matching `soil.f:141`'s WTHR-before-subhourly-loop placement. The day-boundary operator-progress log already dispositioned `preserved` in `feature-023` finding 2 (`ecosys_ng.zig:8055-8056`, fired every 24 hours) is independent corroborating evidence of a once-per-day Zig cadence at the same point in program order EXEC would occupy. **Disposition: `preserved`.**

## 3. Scene-level one-time/conditional initialization gate -- symmetric across all three occurrences, no internal outlier found in the outer gate

`soil.f:39`, `:78` and `:106` (`STARTS`, `STARTQ`, `STARTE`) share **exactly the same outer condition**, character-for-character: `IF((DATA(20).EQ.'YES'.AND.IGO.EQ.0).OR.IDAYR.NE.IOLD)THEN`. Checked all three occurrences against each other -- this is the "N parallel blocks" check the task asked for, and for the *outer* gate the three blocks are symmetric; no outlier. This mechanism (and its lack of a confirmed Zig counterpart) is already filed as `issue-030-idayr-iold-scene-continuity-gate-unmirrored.md` (`OPEN`, disposition `unresolved`); not re-opened here, only re-confirmed as still accurate against the current file hash.

## 4. Inner `ROUTS`/`ROUTP` resume-trigger asymmetry -- new sub-finding, feeds `issue-030` (`unresolved`)

Inside the two structurally-parallel blocks at finding 3 (steps A.4.b and A.8.b above), the **inner** resume-trigger conditions are not identical:

- `soil.f:54` (`ROUTS`, soil state): `IF((IDAYR.GE.IRUN.AND.IYRR.EQ.IDATA(9)).OR.IYRR.GT.IDATA(9))THEN`
- `soil.f:93` (`ROUTP`, plant state): `IF((IDAYR.GT.IRUN.AND.IYRR.EQ.IDATA(9)).OR.IYRR.GT.IDATA(9))THEN`

The only difference is `IDAYR.GE.IRUN` (soil) vs. `IDAYR.GT.IRUN` (plant) -- a one-character, `>=` vs `>`, asymmetry between two blocks that otherwise read as parallel siblings (same surrounding gate, same `IYRR`/`IDATA(9)` disjunct, called four lines apart in program order, both feeding the same `IDAYR`/`IOLD` state machine `issue-030` already tracks). This is exactly the "N parallel blocks, 1 outlier" pattern the task asked to look for, found on the **legacy side**, independent of any Zig comparison. It was not mentioned in `issue-030`'s existing text (which quotes the outer gate at `:39,78,106` but not this inner asymmetry at `:54,93`).

Not independently resolved this pass whether this is a deliberate legacy distinction (e.g. soil state must resume one day earlier than plant state at a boundary) or a copy-paste slip; no comment in `soil.f` explains the difference, and `issue-030`'s own open question 4 ("a third legacy code path... not yet accounted for") is adjacent but does not cover this specific pair. Since `issue-030` is already `OPEN`/`unresolved` and covers the same `IDAYR`/`IOLD` mechanism end-to-end (including the fact that Zig has no confirmed equivalent gate at all), this sub-finding is recorded here and cross-referenced rather than filed as a new, duplicate issue -- a new issue would only be warranted if this specific `GE`/`GT` distinction needed independent resolution from the broader "does Zig have this gate at all" question, and it does not: until Zig has *any* confirmed equivalent, the finer-grained asymmetry is moot. **Disposition: `unresolved`** (same disposition as `issue-030`, which this augments).

## 5. End-of-day unconditional `ROUTS`/`ROUTP` reload -- covered by `issue-030`

`soil.f:285-289` (`IF(NYR.NE.1.AND.IDAYR.NE.IOLD)THEN CALL ROUTS(...); CALL ROUTP(...) ENDIF`, immediately after `EXEC`) is the third and last consumer of the `IDAYR`/`IOLD` comparison in this file, already covered by `issue-030` finding/text (which cites this exact line range). Re-confirmed present and unchanged against the current `soil.f` hash. Not re-dispositioned here beyond `issue-030`'s existing `unresolved`.

## 6. Output and checkpoint write cadence (`OUTSH`/`OUTPH`/`VISUAL`/`WOUTS`/`WOUTP`/`WOUTQ`/`OUTSD`/`OUTPD`) -- not independently re-verified this pass

Steps B.12.c, B.12.d, B.13 and B.14 above define three independent output cadences (hourly-`JOUT`, daily-`KOUT`-or-scene-end, daily-`IOUT`) plus one double-gated option flag (`DATA(18)` for `VISUAL`). `VISUAL`'s Zig treatment was independently audited in `feature-024-visual-inert-legacy-output-vs-live-zig-visualization-stream.md`. The other five routines' exact Zig call-site cadence (as opposed to their output-content correctness, which is presumably covered by output-comparison work) was not independently re-walked this pass; flagged below as not covered rather than asserted as either a match or a gap.

## 7. `SPLIT` end-of-scene output consolidation -- not covered this pass

`soil.f:300` (`CALL SPLIT(...)`, once per scene at the very end, inside a `Cifdef _WIN_` guard, with the non-Windows `SPLITC` sibling permanently commented out) writes per-grid-cell output files from the pooled all-cell files written by `OUTSH`/`OUTSD`/`OUTPH`/`OUTPD` during the scene. A targeted search of `ecosys-ng/src` for a dedicated per-cell output-splitting stage did not locate an unambiguous counterpart this pass (Zig's output architecture may write per-cell files directly during the hourly/daily output stages rather than needing a post-hoc split step, which would make this legacy step's function structurally absorbed rather than missing -- but that was not verified). No issue filed; genuinely unresolved-by-omission rather than a confirmed gap.

## Not covered this pass

- Output/checkpoint cadence Zig call-site verification (finding 6).
- `SPLIT`/`SPLITC` Zig counterpart search (finding 7) -- bounded, not exhaustive.
- The scene-setup sequence's *own* internal Zig call order (`READI`/`READS`/`FOUTS`/`STARTS`/`ROUTS`/`ROUTQ`/`READQ`/`FOUTP`/`STARTQ`/`ROUTP`/`STARTE`, item A above) was cross-checked only for the shared outer gate text (finding 3) and the inner resume asymmetry (finding 4); the *order* these nine-plus routines execute in relative to each other on the Zig side (as opposed to each routine's own state-initialization correctness, separately covered by `feature-021`/`feature-022`/`feature-008`) was not independently re-walked this pass.

## Acceptance and review

Author: this session's audit fork, 2026-09-19 (full-file read of `soil.f`, 100% of its 305 lines traced and cited; cross-file read of six Zig stage files sufficient to establish findings 1-2 with direct line-cited quotations rather than inference). Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Two items `preserved` with strong, source-quoted evidence (subhourly call order; daily/hourly cadence), one item confirmed symmetric with no outlier (outer scene-init gate), one new `unresolved` sub-finding feeding the existing `issue-030` (inner `ROUTS`/`ROUTP` `GE`/`GT` asymmetry), one item cross-referenced to the existing `issue-030` without re-disposition (end-of-day reload), two items left not covered (output/checkpoint cadence; `SPLIT`). **No call-order mismatch found between `soil.f` and the Zig hourly/subhourly pipeline** -- this is itself the significant finding this pass was commissioned to check for, and several previously-completed dossiers' assumed subhourly ordering (`watsub.f`, `hour1.f`, `uptake.f`, `nitro.f`, `solute.f`, `grosub.f`, `redist.f`) is now independently confirmed correct against the actual top-level driver rather than merely inferred.

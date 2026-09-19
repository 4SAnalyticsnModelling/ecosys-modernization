# Issue 027 -- `starte.f` phosphate dissociation reactions read an undeclared, never-assigned local variable `FIONX`; Zig silently normalizes to a defined value

Status: CLOSED -- `legacy-defect-corrected` (confirmed 2026-09-19; see "Closing review" section below). Originally filed OPEN (source-audit finding; deepens and supersedes the `RM1P` "sibling inconsistency" note in `audit/features/feature-008-starte-soil-chemistry-initialization.md`'s Addendum)
Owner: unassigned
Candidate/input hashes: `f77src/starte.f` sha256 `BBE124F6809BD1720B94DDB8512FAAD5DA2FBAF7131C57A0A13E36496DC174A5`

## Failure signature and first bad location

`f77src/starte.f:1097-1098` (`RM1P`, MgHPO4-Mg+HPO4 dissociation) mixes two scaling-factor names within one reaction:

```
      XMINN=FIONS*CM1P1
      XMINP=FIONX*AMIN1(CH1P1,CMG1)
```

Its parallel siblings in the same ~230-line ion-pair dissociation block (`:826-1102`) each use **one** name consistently for both `XMINN`/`XMINP`: `RH3P` (`:1053-1054`, `FIONS`/`FIONS`), `RF1P` (`:1061-1062`, `FIONX`/`FIONX`), `RF2P` (`:1069-1070`, `FIONS`/`FIONS`), `RC1P` (`:1081-1082`, `FIONS`/`FIONS`), `RC2P` (`:1089-1090`, `FIONS`/`FIONS`). One more sibling, `RFES` (`:941-942`), also uses `FIONX`/`FIONX` consistently.

**The real defect is upstream of the mixing itself**: `FIONX` is never declared as a `PARAMETER`, never appears in any of the 17 `include`d common-block headers (`parameters.h`, `blkc.h`, `blk2a/b/c.h`, `blk8a/b.h`, `blk11a/b.h`, `blk13a/b/c.h`, `blk19a/b/c/d.h` -- confirmed by an exhaustive case-insensitive grep of every `.h` file in `f77src/`), and is never assigned a value anywhere in `starte.f` (confirmed: the only two lines matching `FIONX=` anywhere in `starte.f` do not exist -- every occurrence is a *use*, `XMINN=FIONX*...`/`XMINP=FIONX*...`, never a definition). By contrast, `starte.f:100` explicitly declares `PARAMETER (... ,FION=0.2,FIONS=FION*1.0, ...)`. `FIONX` is a distinct, unrelated `PARAMETER` (`=0.20`) declared **only inside `solute.f:119`**, a different subroutine with its own local scope -- it has no bearing on `starte.f`'s `FIONX`.

Because `starte.f` has no `IMPLICIT NONE`, Fortran's default implicit-typing rule silently types `FIONX` as a bare `REAL` local variable. It compiles without any diagnostic. **This is use of an uninitialized local scalar** in three reactions: `RFES` (:941-942, both terms), `RF1P` (:1061-1062, both terms), and `RM1P` (:1098, one of two terms).

## Why this is not "probably harmless" (compiler-flag evidence)

`audit/issues/issue-002-fortran-toolchain-substitution.md` records the historical `f77src/makefile` build flags: `FFLAGS = -O2 -mp1 -r8 -i4 -align dcommons -cpp -auto-scalar`. `-auto-scalar` (ifort) makes local scalars automatic (stack-allocated per call), i.e. **not** implicitly `SAVE`d/zero-initialized between calls. This means `FIONX` in `starte.f` reads genuinely uninitialized stack memory under the historical compiler flags -- not a deterministic zero, and not a benign "same constant, different name" situation. This is undefined behavior by the Fortran standard and by this project's own actual build configuration, not merely a stylistic inconsistency.

## Numerical consequence if `FIONX` happens to evaluate near 0

Both `RFES` and `RF1P` clamp to `AMAX1(-TSL,-XMINN,AMIN1(TSL,XMINP,inner))`. If `XMINN=XMINP=0` (the common case for a zero-filled uninitialized stack slot), both siblings' rates collapse to exactly `0.0` regardless of the true driving-force term (`inner`) -- the reaction is silently inert. For `RM1P`, only `XMINP` collapses to 0 (via `FIONX`) while `XMINN=FIONS*CM1P1` stays a real, nonzero bound (via the correctly-declared `FIONS`) -- so `RM1P` is asymmetrically clamped to dissociation-only (never association) whenever the driving force would otherwise call for net MgHPO4 formation. Under a different stack layout / compiler / optimization level, `FIONX` could instead be some other nonzero garbage value, changing these three reactions' bounds unpredictably run-to-run -- true nondeterminism, not merely a fixed wrong constant.

## Legacy/Zig source anchors

Legacy: `f77src/starte.f:941-942` (RFES), `:1061-1062` (RF1P), `:1097-1098` (RM1P). All three are phosphate/sulfate ion-pair dissociation reactions computed once during the K=3 (soil) initialization pass.

Zig: the runtime (hourly) analogs of this reaction family live in two files, not one -- `ecosys-ng/src/soil/solute/aqueous_reaction_rates.zig` (sha256 `BC6E1581D8F1CC4EBC012919BF92BAA490CEA9ECCFCE13E5DAF13DD9E8811418`) covers the non-phosphate ion pairs (hydroxides/carbonates/bicarbonates/sulfates, including `iron_sulfate_association` = the `RFES` analog, `:168`) and `ecosys-ng/src/soil/solute/phosphate_reaction_rates.zig` (sha256 `EA0C72F21CE112EEE8C5C63951586895ED50170EAB71189475B970E59C16E10A`) covers the phosphate pairs (`h2po4_hydrogen_association` = `RH3P` analog at `:334`, and the mineral-pair reactions via `calculateMinerals`, `:405-452`, which is the `RF1P`/`RF2P`/`RC1P`/`RC2P`/`RM1P` family). Both files route every reaction through the shared `ion_pairing.zig` (sha256 `8734F803FF49E60572ABD90AAE8CCBE4EB9EC3C9D676965296808F369CECDA56`) kernel, whose `Parameters.substrate_limit_fraction` (`ion_pairing.zig:16-20,60-62`) is a **single scalar applied identically to both the association and dissociation bound within one reaction call** (`aqueous_reaction_rates.zig:106-125`, `phosphate_reaction_rates.zig:113-115,782-784`). There is no code path anywhere in either Zig file that supplies two different scaling values to one reaction's two bound terms. Both files' test fixtures use one `general_substrate_limit_fraction`/`substrate_limit_fraction = 0.2` (matching `FIONS`'s actual value, `aqueous_reaction_rates.zig:152,282,290,317-318`; `phosphate_reaction_rates.zig:645,656,675,729,746`) uniformly across every reaction, including `iron_sulfate_association` and the phosphate mineral pairs.

## Disposition: `unresolved`

Zig's translation does **not** reproduce `starte.f`'s literal behavior for these three reactions -- and it structurally *cannot*, because the Fortran behavior itself is undefined (stack-garbage-dependent), not a fixed, reproducible legacy quirk. What Zig does instead is give `RFES`/`RF1P`/`RM1P` the same well-formed, single-consistent-constant treatment as their properly-declared siblings (`RH3P`/`RF2P`/`RC1P`/`RC2P`), using `FIONS`'s value (0.2) throughout. This is a sensible, deterministic engineering choice and is very likely the *intended* legacy behavior (a `FIONS`-for-`FIONX` typo is the most parsimonious explanation for how an unrelated file-local name from `solute.f` ended up typed into `starte.f`). But per `PROJECT_CONTRACT.md` ("do not silently change the reference or reproduce undefined behavior just to match it" / every discovered legacy defect "needs evidence and review"), this specific normalization has no documented approval anywhere in `audit/features/` or `audit/issues/` prior to this entry -- it appears to be an unremarked-upon byproduct of how the translator chose one canonical constant per reaction family, not a reviewed correction. Per the contract's disposition vocabulary, none of `preserved` (the Fortran behavior can't be faithfully preserved -- it's undefined), `legacy-defect-corrected` (no recorded review/approval), or `retired-with-explicit-scope-approval` apply cleanly. **Disposition: `unresolved`**, pending an independent reviewer's explicit sign-off that treating all of `RFES`/`RF1P`/`RM1P` with `FIONS`'s value (0.2) uniformly is the approved resolution (which would then convert this to `legacy-defect-corrected`).

## Minimal reproducer

Exact command: read-only source inspection, no build/run required to establish the finding. `grep -n "FIONX" f77src/starte.f` (5 hits, all uses, 0 definitions) and `grep -rn "FIONX" f77src/*.h` (0 hits) reproduce the core evidence from any checkout of this source tree.

## Next bounded action

An independent reviewer should confirm (a) whether the historical `ecosys` codebase has any other file/version where `starte.f`'s `FIONX` usages read `FIONS` instead (a diff against an older/different source distribution, if available, would settle the "typo" hypothesis definitively), and (b) explicitly approve Zig's uniform-`FIONS`-value treatment of `RFES`/`RF1P`/`RM1P` as the intended correction, which would close this out as `legacy-defect-corrected`. No code change is proposed here; this is a documentation/review gap, not a diagnosed-but-unfixed Zig bug.

## Closing review (2026-09-19)

Independently re-verified before closing, not just trusted from the issue's own text:
- `grep -n "FIONX" f77src/starte.f f77src/solute.f` confirms `FIONX` is declared exactly once, as a `PARAMETER (...,FIONX=0.20,...)` at `solute.f:119`, and is used (never assigned) 5 times in `starte.f` (`:941-942` RFES, `:1061-1062` RF1P, `:1098` RM1P) and dozens of times in `solute.f` itself where it *is* in scope. `starte.f` has its own, different `PARAMETER` list (`:100`, includes `FIONS=FION*1.0`) that never declares `FIONX`. This independently confirms the issue's core claim: `starte.f`'s `FIONX` reads are undefined-behavior uses of an implicitly-typed, unassigned local.
- Read `ecosys-ng/src/soil/solute/aqueous_reaction_rates.zig:145-179` (the `RFES` analog, `iron_sulfate_association` at `:168`) and `ecosys-ng/src/soil/solute/phosphate_reaction_rates.zig:405-434` (`calculateMinerals`, the `RF1P`/`RF2P`/`RC1P`/`RC2P`/`RM1P` analog): confirmed both pass one shared scale value (`general`/`substrate_limit_fraction`) to both the association and dissociation bound of every reaction in the family, via `ion_pairing.zig`'s single `Parameters.substrate_limit_fraction` field -- there is no code path giving one reaction's two bound terms two different scale constants, matching the issue's claim exactly.
- Added a short comment at `aqueous_reaction_rates.zig` (immediately above `.iron_sulfate_association`) and at `phosphate_reaction_rates.zig` (immediately above `calculateMinerals`'s `const standard = ...`) citing this issue number and naming the specific legacy lines, so a future refactor toward per-reaction scale constants doesn't silently reintroduce the `FIONX`/`FIONS` split. No logic, computation, or test was changed.

**Disposition: `legacy-defect-corrected`.** The legacy `FIONX` reads are confirmed undefined behavior (not a fixed, reproducible quirk), and Zig's uniform single-constant treatment is the sensible, deterministic, and very likely intended resolution; it is now cited in-code for both call sites. Traceability: `audit/traceability/traceability.csv` already has a clean row for this issue (`TRC-091`); disposition/status there should be treated as superseded by this closing note (not duplicated -- `traceability.csv` was off-limits this pass, already modified by a concurrent agent).

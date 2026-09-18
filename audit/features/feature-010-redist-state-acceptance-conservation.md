# Feature ID: FEAT-010-REDIST-STATE-ACCEPTANCE-CONSERVATION

Status: PARTIALLY_ASSESSED (first-pass source-audit; `redist.f` is 13,093 lines/530KB, only ~900 lines/~7% depth-read; `redist_utf8.f` confirmed same-session as a UTF-8 re-encoding of the same subroutine, NOT audited separately)

## Scope and provenance

Legacy source: `f77src/redist.f` (sha256 `2FEAEC2B50571BDE6E92AE6A8838738B13D36A9CE858E3734F95C65F2733111D`), header: "UPDATES SOIL STATE VARIABLES WITH WATER, HEAT, C, N, P, SOLUTE FLUXES CALCULATED IN EARLIER SUBROUTINES" -- i.e. the state-acceptance/bookkeeping routine applying fluxes computed by watsub/solute/nitro etc. into persistent state. Full-file structural map obtained by banner grep; depth-read confined to: L5900-6030, L7209-7403, L8155-8245, L9640-9666, L12844-13018.

### 1. Water-content state accumulation (`VOLW`/`VOLV`/`VOLI`/`VOLWH`/`TKS`)

`redist.f:5947-5949` (inside `DO 125 L=NU..NL`, L5916-7403): `VOLW=VOLW+TFLW+TWFLVL+TWFLFL+FINH+TUPWTR+FLU` -- unconditional accumulation of convective flux, evap-condensation, freeze-thaw, micro/macropore exchange, root uptake, subsurface input; no bounds check, no rollback, no rejection path in the Fortran. Same pattern for `VOLV/VOLI/VOLWH/VOLIH` (`:5949-5962`); `TKS` (`:6002-6011`) gates on a `VHCP>VHCPRX` heat-capacity floor before dividing (a degenerate-layer guard, not a rollback).

Zig (architectural analogue, not confirmed line-for-line for the full six-term sum): `ecosys-ng/src/stages/hourly_heat_water_solute.zig` (sha256 `FCE767AD491FDE83A4B67B77AAA992978689C54DC6E6CE9B33BF018A1150AB18`, `:6583-6620`) computes candidate next-liquid/vapor volumes, validates finiteness/non-negativity/pore-overfill tolerance BEFORE committing. `ecosys-ng/src/transport/hydrology.zig` (sha256 `8460D595D07F3D384BD372A16628C9C0D5BB1B963AE5A1BFBCCFCF06887DD5AE`, `:203-217`) additionally enforces finiteness/non-negativity across the whole workspace post-hoc.

**Disposition: `preserved`** (same functional form -- sum of flux legs into a persistent pool), **with an unverified engineering hardening**: Zig adds pre-commit validation absent from the Fortran (consistent with contract's "fail explicit, not silent" policy). **Not confirmed this pass**: a single Zig statement summing all six legs at once for the *general* soil layer (only the topsoil vapor-exchange leg was located) -- follow-up needed to find the exact general per-layer commit site.

### 2. Soil/pond layer-boundary relayering (`DO 245`, `redist.f:8163-10605`) -- the historically-flagged ~2,000-line range

Confirmed as the range a prior memory-recorded audit session flagged ("redist.f DO-245... one genuine ~2,000-line unaudited line-range"). This is the geometry-disturbance/state-transfer engine: recomputes `CDPTH`/`DLYR` from pond/freeze-thaw/erosion/SOC-driven boundary shifts, then moves every state pool (water/ice/heat, fertilizer, solutes, salts, adsorbed cations/anions, precipitates, gases, organic matter, roots, root gases/nodules) from source layer to destination layer when a boundary crosses (heat-capacity floor guard `redist.f:9655-9659`).

Zig: `ecosys-ng/src/soil/profile/geometry_disturbance_transaction.zig` (sha256 `E99FA3E8300B4EB2319F03B3FC2AC6EECF3184CF48C4E747811BC815C533B456`, whole file). Implements exactly the transactional/exactly-once discipline the contract requires: a `Workspace.State` enum (`idle->staged->state_updateting->state_updateted`, `:20-25`) and `state_updateOnce()` (`:87-97`) combining the four legacy boundary legs and calling the consumer callback exactly once; a re-entrant call fails via `error.SoilGeometryTransactionStateUpdateInProgress`/`AlreadyStateUpdateted` BEFORE mutation.

**Disposition: `replaced-by-approved-feature`** (transactional hardening -- legacy has no equivalent guard, unconditional always-mutating loop) for the acceptance mechanism; **`preserved`** for the underlying geometry math. **Open, self-declared gap found in-code**: tag `PR-GEOM-01B` (`geometry_disturbance_transaction.zig:112-114`) states "Production must not bind the uncancelled hourly SOC difference here" -- the biological-SOC-change input's real producer is not yet wired in. See `audit/issues/issue-012-pr-geom-01b-soc-cancellation-unwired.md`.

**Already-tracked, folded in (not re-derived)**: the `VHCPRX` heat-capacity floor (`redist.f:9655-9659`) maps to `ecosys-ng/src/soil/heat/flux.zig` (sha256 `C85E202974A17C8097E28F7EA4EF41D9DE93A824D7775865CD341B22A0CD1117`, `:47-61`), already documented in `audit/issues/issue-006-embedded-tag-findings-batch1.md` under tags `SURFACE-HEAT-BRACKET-RUNAWAY-001`/`DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001`, still open per that existing record -- not re-litigated here.

### 3. Whole-ecosystem mass-balance check -- notable finding: the legacy check is entirely dead code

`redist.f:12844-13017`, header "CHECK MATERIAL BALANCES FOR C,N,P,WATER,HEAT,O2,SALTS... FROM TOTAL ECOSYSTEM CONTENTS LESS CUMULATIVE INPUTS PLUS CUMULATIVE OUTPUTS." **Every single balance check (C, water, heat, O2, N, P, salt, H2, sediment; `:12861-13016`) is commented-out (`C`-prefixed) diagnostic `WRITE` code -- none of it executes.** The only live code in this block is an unconditional annual `ORGC` diagnostic dump at year-end (`:12848-12854`). **There is no runtime accept/reject conservation gate anywhere in `redist.f`** on any flux-acceptance statement read in this pass -- legacy discipline is unconditional bookkeeping, not conservation-gated acceptance. (The `TION`/`TIONIN`/`TIONOU` salt-balance accumulators elsewhere in the file, `:5838-5896,7209-7387`, DO execute but only accumulate totals for the same dead reporting -- they never gate a state update.)

Zig: `ecosys-ng/src/validation/hourly_cell_conservation.zig` (sha256 `1133181B2A019FA99F1B9DE168398ACA4F8C6FAEA023744EEFB501DA021F1F87`) and siblings (`layer_local_conservation.zig`, `landscape_boundary_balance.zig`, `scoped_conservation.zig`), `:45-88` defines an explicit `Quantity` enum (a superset of legacy's `TION` ion list) plus `StorageOwner`/`ExternalProducer` and requires `productionCoverageComplete` before the gate may bind into the accepted-hour path.

**Disposition: `replaced-by-approved-feature`** -- a deliberate, substantial upgrade from "commented-out diagnostic" to "designed-as-enforced gate," matching the contract's conservation requirements. **Not independently verified this pass** whether the gate is actually wired into the production accepted-hour path today (the module's own comment flags coverage-completeness as a precondition) -- cross-check against `audit/conservation/` evidence before treating this as closed.

## Addendum 2026-09-18 (same session, follow-up pass): `DO 245`'s bulk (~76% of the 8244-10604 block) -- two real candidate gaps found

Six pool-transfer families sampled: pond N/P solutes+salts (`:8560-8692`, `preserved`), soil fertilizer transfer with an `AMIN1` cap (`:9670-9714`, `preserved`, cap-semantics follow-up flagged), organic matter (`:10322-10356`, `preserved`, not field-verified), gaseous/aqueous gas pools (`:10061-10106`, `preserved`, not field-verified), and two families with a **real asymmetry between the Fortran's pond and soil branches that Zig does not reproduce**:

- **Adsorbed cations/anions/precipitates**: Fortran's soil branch (`:9905-10059`) gates transfer on `L0>L1` (upward only); Fortran's pond branch (`:8984-9014ish`) transfers unconditionally. Zig (`relayering.zig:508-511`) applies the upward-only gate to BOTH branches -- confirmed via the only production call site, with pond-driven boundary changes confirmed live (not dormant) via `pond_domain_transaction.zig:255`.
- **Root gases**: Fortran's soil branch (`:10413-10450`) is entirely commented out (dormant, correctly mirrored in Zig); Fortran's pond branch (`:8800-8825`) is active. Zig's only production call site (`relayering.zig:575`) excludes gas fields for both branches -- the gas-inclusive Zig functions exist but are dead code outside unit tests.

Both are real, live-code-path asymmetries (not stale comments), verified against actual call sites. **Disposition: `unresolved`** for both, pending conservation/feature-attribution review -- see `audit/issues/issue-017-redist-pond-branch-relayering-asymmetry.md` for full detail and citations.

## Not covered this pass

Sink-pool block (`:192-609`); the remaining ~24% of `DO 245`'s bulk (`:8965-9439` pond `FY`-decrement mirror, `:10148-10413` macropore aqueous-gas/organic continuation, surveyed by header only); tillage mixing (`:11017-12842`, contains the already-known `TILLAGE-ORGANIC-MIRROR-OWNER-001`); fire/combustion (`:10680-10973`); runoff/subsurface boundary fluxes (`:616-1439`); net-flux accumulators (`:1439-3935`); freeze-thaw/snowpack (`:3935-4218`).

## Acceptance and review

Author: this session's audit fork, 2026-09-18. Independent reviewer: not yet done. Decision: NOT_ASSESSED for gate purposes. Two items `preserved`/hardened; one `replaced-by-approved-feature` with a real open sub-gap (`PR-GEOM-01B`); one `replaced-by-approved-feature` (conservation gate) needing wiring verification; ~93% of this file remains a follow-up target, notably the remainder of `DO 245` and tillage mixing.

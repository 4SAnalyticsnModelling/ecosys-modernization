# Round 00031 Audit: Ion Conservation & Closure Gates below ZEROC Floor

Comprehensive audit of all conservation/closure gates in `ecosys-ng` checking ion/solute/element quantities (Al, Fe, Ca, Mg, Na, K, S, Cl, Si, P species, mineral N):

| File:Line | Scope / Gate | Tolerance Formula | Has $\ge 10^{-32}$ Floor? | Restored from Checkpoint? |
| :--- | :--- | :--- | :--- | :--- |
| `ecosys_ng.zig:5906-5916` | Hourly cell conservation (`evaluate`) | `.absolute = @max(tol.ions_mol_m2, 1e-32) * area` | **Yes** (commit a2860fa) | No (applied to local copy per hour) |
| `ecosys_ng.zig:6096-6109` | Hourly layer conservation (`evaluate`) | `.absolute = @max(tol.ions_mol_m2, 1e-32) * area` | **Yes** (commit a2860fa) | No (applied to local copy per hour) |
| `ecosys_ng.zig:6463-6471` | Accumulated cell closure (`evaluateAndCommit`) | `.absolute = cell_absolute_per_area * area` | **Yes** (commit a2860fa, shares `cell_absolute_per_area`) | No (re-evaluated per hour) |
| `ecosys_ng.zig:6480-6488` | Accumulated layer closure (`evaluateAndCommitAccumulated`) | `.absolute = layer_absolute_per_area * area` | **Yes** (commit a2860fa, shares `layer_absolute_per_area`) | No (re-evaluated per hour) |
| `validation/mass_balance_audit.zig:415-425` | Daily landscape mass-balance audit (S, Cl, Si, cations) | `acceptanceLimit(@max(tol.ions_mol_m2, 1e-32), rel, act, area)` | **Yes** (commit 0140028) | **Yes** (monitor restored via `readNumericStruct`, but check site applies `@max`) |
| `driver/transport_step.zig:573-580` | Solute transport local conservation (layer $\times$ species) | `.absolute = @max(ions_mol_m2 * area, 64*eps*max(\|S_pre\|, \|S_post\|))` | **NO** (representation floor only; for $S \approx 10^{-46}$, floor is $\sim 10^{-60} \ll 10^{-32}$) | No (configured per step from `mass_balance_absolute_tolerance.ions_mol_m2`) |
| `soil/solute/litter_soil_interface.zig:731-732` | Litter-soil solute/mineral interface closure | `denom = @max(abs_tol, 32*eps*max(1.0, scale)) + rel*scale` | **Yes** (hardcoded `32*eps*1.0` $\approx 7\times 10^{-15} \gg 10^{-32}$) | No (transient step parameter) |
| `stages/hourly_heat_water_solute.zig:2453-2464` | Snow disappearance litter transfer (`LiveConservationTolerances`) | `salt_absolute_mol_per_m2 = @max(ions_mol_m2, ...)` | **NO** (unfloored if `ions_mol_m2` configured $< 10^{-32}$ or zero) | No (constructed dynamically each hour) |
| `soil/gas/aqueous_extensive_transport.zig:732-734` | Aqueous gas transport local closure | `@max(direct, per_area, 64*eps*max(1, \|S\|))` | **Yes** (hardcoded $\ge 64\times \text{eps} \times 1.0 \approx 1.4\times 10^{-14}$) | No (runtime option) |
| `soil/biogeochemistry/mineral_nitrogen_transport.zig:604-616` | Mineral N ($NH_4, NO_3$) transport closure | `@max(nitrogen_g_m2 * area / 14, 64*eps*max(1, \|S\|))` | **Yes** (hardcoded $\ge 64\times \text{eps} \times 1.0 \approx 1.4\times 10^{-14}$) | No (runtime option) |

### Key Exposure Point
`driver/transport_step.zig:573-580` is **unfloored against ZEROC**: if `configured_absolute` is 0 (or $< 10^{-32}$) and STARTE dust ($S \sim 10^{-46}\text{ mol}$) undergoes dual-domain or macropore transport, `representation_floor` collapses to $64 \times \text{eps} \times 10^{-46} \sim 10^{-60}\text{ mol}$, exposing the transport solve to immediate failure on sub-resolution roundoff.

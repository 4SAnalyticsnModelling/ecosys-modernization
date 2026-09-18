// **A8a DISPOSITION: NOT A BINDING CANDIDATE. This file is test
// infrastructure, not a translated module, and it must never be bound.**
//
// Why the census lists it. `tools/census_reach.py` enumerates `.zig` files
// under `src` and reports any file with no production caller as unbound. This
// file has no production caller and must not acquire one. It is one of the
// sixteen per-subsystem test indexes in `src/index/`, all sixteen of which
// appear in the unbound list for the same reason and none of which is a
// translation of any Fortran routine. There is no `.f` source to cite here
// because there is no science in this file.
//
// What it actually does, and why the mechanism is easy to misread. It holds
// 122 `_ = <module>;` references. It is imported at `module_index.zig:1379`,
// and the decisive detail is that the import sits *inside* the `test {}` block
// opened at `module_index.zig:1360` and closed at `:1382`, alongside the other
// fifteen indexes at `:1366--1381`. That placement is load-bearing in a way
// that is easy to get wrong: `@import` alone does not pull a module's tests
// into analysis, only an explicit `_ = module;` reference does. So this file
// is the thing that makes 122 modules' tests actually compile and run under
// `zig build test`, and it does its job precisely by having no production
// caller.
//
// Consequence for anyone draining the unbound list. Binding this file, or
// adding a `pub const` for it outside the test block, would not raise
// coverage; it would move test-only code into the production graph. Deleting
// it, or dropping a `_ =` line from it, silently removes modules from test
// analysis while every gate and build still passes, because nothing fails when
// a test simply stops being compiled. That is the most dangerous possible edit
// in this directory and it leaves no trace. Treat the `_ =` lines as append-
// only.
//
// Census false positive of the CENSUS-ORPHAN-FP-001 kind, already filed. The
// sixteen index files are a known and permanent residue in the unbound count:
// they can never be bound, so the count can never reach zero by binding alone,
// and any future report of remaining unbound modules should subtract them
// rather than treat them as outstanding work. The same reasoning applies to
// per-module test sidecars such as
// `soil/solute/concentration_initialization_test.zig`, which carries its own
// banner to that effect.
//
// A8a phase 2, src/index directory sweep. See
// docs/traceability/a8a_index_dispositions.md for the directory-level record.
//! Compiles the surface and litter modules so `zig build test` runs their tests.
//!
//! Referencing a module here is what pulls it into analysis. The
//! namespace itself still lives in `module_index.zig`; this file only
//! carries the references, grouped by directory so the list is
//! reviewable and a missing module is visible.

const ecosys = @import("../module_index.zig");

test {
    _ = ecosys.ground_air_exchange;
    _ = ecosys.ground_radiation;
    _ = ecosys.ground_surface_vapor_water_state_update;
    _ = ecosys.ground_vapor_exchange;
    _ = ecosys.surface_aerodynamics;
    _ = ecosys.surface_aqueous_runoff_transport;
    _ = ecosys.surface_autotrophic_complex_step;
    _ = ecosys.surface_denitrification_step;
    _ = ecosys.surface_dissolved_gas_transport;
    _ = ecosys.surface_energy;
    _ = ecosys.surface_gas_boundary_conductance;
    _ = ecosys.surface_gas_parameters;
    _ = ecosys.surface_litter_chemistry;
    _ = ecosys.surface_litter_chemistry_carrier_rebase;
    _ = ecosys.surface_litter_chemistry_step;
    _ = ecosys.surface_litter_colonization_step;
    _ = ecosys.surface_litter_extensive_changes;
    _ = ecosys.surface_litter_fertilizer;
    _ = ecosys.surface_litter_fertilizer_step;
    _ = ecosys.surface_litter_freeze_thaw_energy_limit;
    _ = ecosys.surface_litter_gas_transport_step;
    _ = ecosys.surface_litter_geometry;
    _ = ecosys.surface_litter_geometry_step;
    _ = ecosys.surface_litter_ion_complex_initialization;
    _ = ecosys.surface_litter_organic_heat_rebase;
    _ = ecosys.surface_litter_reaction_ledger;
    _ = ecosys.surface_litter_reaction_rates;
    _ = ecosys.surface_litter_removal;
    _ = ecosys.surface_litter_water_environment;
    _ = ecosys.surface_metabolism_state_update;
    _ = ecosys.surface_microbial_assimilation_step;
    _ = ecosys.surface_microbial_environment;
    _ = ecosys.surface_microbial_environment_step;
    _ = ecosys.surface_microbial_maintenance_step;
    _ = ecosys.surface_microbial_mineral_exchange_step;
    _ = ecosys.surface_microbial_oxygen;
    _ = ecosys.surface_microbial_oxygen_driver;
    _ = ecosys.surface_microbial_respiration_step;
    _ = ecosys.surface_microbial_substrate_uptake_step;
    _ = ecosys.surface_microbial_turnover_step;
    _ = ecosys.surface_mineral_transport;
    _ = ecosys.surface_nonsymbiotic_nitrogen_fixation_step;
    _ = ecosys.surface_organic_decomposition_step;
    _ = ecosys.surface_organic_priming_step;
    _ = ecosys.surface_organic_sorption_step;
    _ = ecosys.surface_organic_transport;
    _ = ecosys.surface_pond_chemistry_transfer;
    _ = ecosys.surface_pond_conservation_sidecar;
    _ = ecosys.surface_pond_domain_transaction;
    _ = ecosys.surface_pond_inventory_transfer;
    _ = ecosys.surface_pond_particulate_settling;
    _ = ecosys.surface_pond_transition_step;
    _ = ecosys.surface_pond_water_heat_transfer;
    _ = ecosys.surface_precipitation;
    _ = ecosys.surface_residue_diffusivity;
    _ = ecosys.surface_runoff;
    _ = ecosys.surface_runoff_carrier;
    _ = ecosys.surface_temperature_solver;
    _ = ecosys.surface_topsoil_microbial_mixing;
    _ = ecosys.surface_topsoil_mineral_exchange_step;
    _ = ecosys.surface_water_flow;
}

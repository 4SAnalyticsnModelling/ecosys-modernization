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
// 132 `_ = <module>;` references. It is imported at `module_index.zig:1367`,
// and the decisive detail is that the import sits *inside* the `test {}` block
// opened at `module_index.zig:1360` and closed at `:1382`, alongside the other
// fifteen indexes at `:1366--1381`. That placement is load-bearing in a way
// that is easy to get wrong: `@import` alone does not pull a module's tests
// into analysis, only an explicit `_ = module;` reference does. So this file
// is the thing that makes 132 modules' tests actually compile and run under
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
//! Compiles the canopy modules so `zig build test` runs their tests.
//!
//! Referencing a module here is what pulls it into analysis. The
//! namespace itself still lives in `module_index.zig`; this file only
//! carries the references, grouped by directory so the list is
//! reviewable and a missing module is visible.

const ecosys = @import("../module_index.zig");

test {
    _ = ecosys.absent_species_canopy_state;
    _ = ecosys.absent_standing_dead_canopy_state;
    _ = ecosys.c4_leaf_nonstructural_carbon_senescence;
    _ = ecosys.canopy_air_exchange;
    _ = ecosys.canopy_airflow;
    _ = ecosys.canopy_ammonia_state_update;
    _ = ecosys.canopy_aqueous_gas_environment;
    _ = ecosys.canopy_biochemistry;
    _ = ecosys.canopy_branch_leaf_orchestration;
    _ = ecosys.canopy_c4_capacity;
    _ = ecosys.canopy_c4_mesophyll_bundle_exchange;
    _ = ecosys.canopy_c4_node_exchange_eligibility;
    _ = ecosys.canopy_carbon_exchange;
    _ = ecosys.canopy_carbon_state_update;
    _ = ecosys.canopy_carboxylation;
    _ = ecosys.canopy_carboxylation_water_response;
    _ = ecosys.canopy_emergence_layer_reset;
    _ = ecosys.canopy_energy;
    _ = ecosys.canopy_exposure;
    _ = ecosys.canopy_fire_state_update;
    _ = ecosys.canopy_geometry;
    _ = ecosys.canopy_height_hourly_rollover;
    _ = ecosys.canopy_interception;
    _ = ecosys.canopy_irradiance_interception_geometry;
    _ = ecosys.canopy_layer_distribution;
    _ = ecosys.canopy_layer_transmission_finalization;
    _ = ecosys.canopy_minimum_stomatal_resistance;
    _ = ecosys.canopy_maximum_turgor_carboxylation;
    _ = ecosys.canopy_optics;
    _ = ecosys.canopy_photosynthesis;
    _ = ecosys.canopy_precipitation_retention;
    _ = ecosys.canopy_precipitation_retention_source_order;
    _ = ecosys.canopy_radiation;
    _ = ecosys.canopy_stomatal_resistance;
    _ = ecosys.canopy_structure;
    _ = ecosys.canopy_surface_exchange;
    _ = ecosys.canopy_symbiotic_respiration_fixation;
    _ = ecosys.canopy_temperature_solver;
    _ = ecosys.canopy_coupled_convergence;
    _ = ecosys.canopy_top_down_layer_eligibility;
    _ = ecosys.canopy_upward_scattering_traversal;
    _ = ecosys.canopy_water_energy_state_update;
    _ = ecosys.canopy_conservation_sidecar;
    _ = ecosys.canopy_water_stress_response;
    _ = ecosys.daily_canopy_gas_exchange;
    _ = ecosys.internode_senescence_state_update;
    _ = ecosys.leaf_co2_solver;
    _ = ecosys.leaf_node_growth_state_update;
    _ = ecosys.leaf_senescence_snapshot;
    _ = ecosys.leaf_senescence_state_update;
    _ = ecosys.leaf_structural_nutrient_recycling;
    _ = ecosys.living_canopy_layer_state_update;
    _ = ecosys.plant_symbiotic_fixation;
    _ = ecosys.sheath_senescence_fraction;
    _ = ecosys.sheath_senescence_litter_partition;
    _ = ecosys.sheath_senescence_snapshot_and_stalk_transfer;
    _ = ecosys.sheath_senescence_state_update;
    _ = ecosys.convergence_pass_control;
    _ = ecosys.fixed_terms;
    _ = ecosys.inactive_water_energy;
    _ = ecosys.radiation_iteration;
    _ = ecosys.stomatal_call_boundary;
    _ = ecosys.substep_initialization;
    _ = ecosys.temperature_stress;
    _ = ecosys.water_aggregation;
    _ = ecosys.water_heat_initialization;
    _ = ecosys.water_osmotic_potential;
}

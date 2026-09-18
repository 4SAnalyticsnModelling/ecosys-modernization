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
// 230 `_ = <module>;` references. It is imported at `module_index.zig:1375`,
// and the decisive detail is that the import sits *inside* the `test {}` block
// opened at `module_index.zig:1360` and closed at `:1382`, alongside the other
// fifteen indexes at `:1366--1381`. That placement is load-bearing in a way
// that is easy to get wrong: `@import` alone does not pull a module's tests
// into analysis, only an explicit `_ = module;` reference does. So this file
// is the thing that makes 230 modules' tests actually compile and run under
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
//! Compiles the plant modules so `zig build test` runs their tests.
//!
//! Referencing a module here is what pulls it into analysis. The
//! namespace itself still lives in `module_index.zig`; this file only
//! carries the references, grouped by directory so the list is
//! reviewable and a missing module is visible.

const ecosys = @import("../module_index.zig");

test {
    _ = ecosys.annual_plant_flux_rollover;
    _ = ecosys.branch_base_height;
    _ = ecosys.branch_organ_growth_state_update;
    _ = ecosys.branch_reserve_equilibration;
    _ = ecosys.end_of_season_reproductive_turnover;
    _ = ecosys.final_grain_number;
    _ = ecosys.grid_cell_litter_standing_dead_state_update;
    _ = ecosys.main_stalk_death_propagation;
    _ = ecosys.maximum_individual_grain_size;
    _ = ecosys.node_senescence_cascade_progress;
    _ = ecosys.node_senescence_remobilization_request;
    _ = ecosys.perennial_stalk_senescence_setup;
    _ = ecosys.plant_active_species_feedback_initialization;
    _ = ecosys.plant_balance_ledger_initialization;
    _ = ecosys.plant_balance_state_update;
    _ = ecosys.plant_branch_biomass_initialization;
    _ = ecosys.plant_canopy_aggregate_initialization;
    _ = ecosys.plant_combustion_state_update;
    _ = ecosys.plant_concurrent_node_initialization;
    _ = ecosys.plant_daily_flux_ledger;
    _ = ecosys.plant_daily_pool_aggregation;
    _ = ecosys.plant_development;
    _ = ecosys.plant_dormancy;
    _ = ecosys.plant_energy_state_update;
    _ = ecosys.plant_growth_stages;
    _ = ecosys.plant_growth_temperature;
    _ = ecosys.plant_initialization;
    _ = ecosys.plant_initialization_admission;
    _ = ecosys.plant_litter_kinetic_partition_initialization;
    _ = ecosys.plant_litter_partition;
    _ = ecosys.plant_litter_salt_ingress;
    _ = ecosys.plant_litterfall_state_update;
    _ = ecosys.plant_mortality;
    _ = ecosys.plant_organ_partition;
    _ = ecosys.plant_phenology;
    _ = ecosys.plant_phenology_branch_initialization;
    _ = ecosys.plant_pool_aggregation;
    _ = ecosys.plant_population_numerical_thresholds;
    _ = ecosys.plant_reproduction;
    _ = ecosys.plant_root_disturbance;
    _ = ecosys.plant_root_exudation;
    _ = ecosys.plant_root_gas_exchange;
    _ = ecosys.plant_root_gas_transport;
    _ = ecosys.plant_root_ion_balance;
    _ = ecosys.plant_root_layer_remap;
    _ = ecosys.plant_root_litter_ledger;
    _ = ecosys.plant_root_litterfall;
    _ = ecosys.plant_root_metabolism;
    _ = ecosys.plant_root_mycorrhizal_exchange;
    _ = ecosys.plant_root_nutrient_uptake;
    _ = ecosys.plant_root_porosity;
    _ = ecosys.plant_root_porosity_sweep;
    _ = ecosys.plant_root_salt_exchange;
    _ = ecosys.plant_root_soil_exchange_accumulation;
    _ = ecosys.plant_root_symbiotic_fixation;
    _ = ecosys.plant_root_system;
    _ = ecosys.plant_root_water_storage_state_update;
    _ = ecosys.plant_salt_harvest;
    _ = ecosys.plant_salt_harvest_adapter;
    _ = ecosys.plant_shoot_fire;
    _ = ecosys.plant_shoot_root_exchange;
    _ = ecosys.plant_internal_root_shoot_activity;
    _ = ecosys.plant_soil_exchange;
    _ = ecosys.plant_species_hourly_diagnostic_reset;
    _ = ecosys.plant_storage_remobilization;
    _ = ecosys.plant_thermal_acclimation_initialization;
    _ = ecosys.plant_water_balance;
    _ = ecosys.plant_water_state_update;
    _ = ecosys.potential_seed_site_accumulation;
    _ = ecosys.primary_root_axis_scaling;
    _ = ecosys.reserve_maintenance_respiration;
    _ = ecosys.residual_stalk_senescence_state_update;
    _ = ecosys.residual_stalk_senescence_request;
    _ = ecosys.root_atmosphere_gas_state_update;
    _ = ecosys.root_combustion_boundary_state_update;
    _ = ecosys.root_combustion_salt_state_update;
    _ = ecosys.root_competition_demand_state_update;
    _ = ecosys.root_exudate_state_update;
    _ = ecosys.root_gas_content_state_update;
    _ = ecosys.root_gas_withdrawal_state_update;
    _ = ecosys.root_internal_gas_state_update;
    _ = ecosys.root_nitrogen_fixation_state_update;
    _ = ecosys.root_nutrient_uptake_state_update;
    _ = ecosys.root_oxygen_constraint;
    _ = ecosys.root_oxygen_uptake_solver;
    _ = ecosys.root_pool_transaction_replay;
    _ = ecosys.root_salt_uptake_state_update;
    _ = ecosys.root_soil_ammonia_exchange_state_update;
    _ = ecosys.root_soil_element_exchange_state_update;
    _ = ecosys.root_soil_gas_state_update;
    _ = ecosys.root_uptake_ledger;
    _ = ecosys.root_water_uptake_state_update;
    _ = ecosys.rooted_layer_eligibility;
    _ = ecosys.seasonal_growth_flag_reset;
    _ = ecosys.seasonal_stalk_standing_dead_turnover;
    _ = ecosys.shoot_growing_node_window;
    _ = ecosys.shoot_growth_coefficient_basis;
    _ = ecosys.shoot_growth_metabolism;
    _ = ecosys.shoot_growth_nutrient_limitation;
    _ = ecosys.shoot_growth_runtime;
    _ = ecosys.shoot_litter_bridge;
    _ = ecosys.shoot_recycling_fraction;
    _ = ecosys.shoot_total_senescence_setup;
    _ = ecosys.spring_reproductive_litterfall;
    _ = ecosys.stalk_growing_node_window;
    _ = ecosys.stalk_layer_state_update;
    _ = ecosys.stalk_node_growth_state_update;
    _ = ecosys.standing_dead_area_state_update;
    _ = ecosys.standing_dead_litterfall;
    _ = ecosys.standing_dead_surface_exchange;
    _ = ecosys.storage_carbon_branch_survival;
    _ = ecosys.biological_climate_acclimation;
    _ = ecosys.daily_activity;
    _ = ecosys.hourly_flux;
    _ = ecosys.uptake_flux;
}

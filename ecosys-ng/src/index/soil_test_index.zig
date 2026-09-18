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
// 427 `_ = <module>;` references. It is imported at `module_index.zig:1377`,
// and the decisive detail is that the import sits *inside* the `test {}` block
// opened at `module_index.zig:1360` and closed at `:1382`, alongside the other
// fifteen indexes at `:1366--1381`. That placement is load-bearing in a way
// that is easy to get wrong: `@import` alone does not pull a module's tests
// into analysis, only an explicit `_ = module;` reference does. So this file
// is the thing that makes 427 modules' tests actually compile and run under
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
//! Compiles the soil modules so `zig build test` runs their tests.
//!
//! Referencing a module here is what pulls it into analysis. The
//! namespace itself still lives in `module_index.zig`; this file only
//! carries the references, grouped by directory so the list is
//! reviewable and a missing module is visible.

const ecosys = @import("../module_index.zig");
const reaction_solver_numerics2 = @import("../soil/solute/reaction_solver_numerics2.zig");

test {
    _ = ecosys.aqueous_extensive_transport;
    _ = ecosys.coupled_gas_solver;
    _ = ecosys.gas_atmosphere_exchange;
    _ = ecosys.gas_face_assembly;
    _ = ecosys.gas_transport;
    _ = ecosys.heat_failure_snapshot;
    _ = ecosys.humus_resistance_partition_initialization;
    _ = ecosys.litter_salt_state_update;
    _ = ecosys.litter_soil_convective_solute_flux;
    _ = ecosys.litter_soil_diffusive_solute_flux;
    _ = ecosys.litter_soil_solute_concentration;
    _ = ecosys.litter_soil_solute_diffusivity;
    _ = ecosys.litter_soil_solute_flux_accumulation;
    _ = ecosys.litter_soil_total_solute_flux;
    _ = ecosys.litter_soil_interface;
    _ = ecosys.microbial_humus_allocation;
    _ = ecosys.microbial_thermal_adaptation_initialization;
    _ = ecosys.mineral_nitrogen_transport;
    _ = ecosys.organic_matter_fire_exchange;
    _ = ecosys.organic_priming_exchange;
    _ = ecosys.organic_substrate_decomposition;
    _ = ecosys.overland_flow_state_update_gate;
    _ = ecosys.snow_base_thermal_coupling;
    _ = ecosys.snow_compaction;
    _ = ecosys.snow_cover_fraction;
    _ = ecosys.snow_drift_boundary_accounting;
    _ = ecosys.snow_drift_routing;
    _ = ecosys.snow_heat_conduction;
    _ = ecosys.snow_inactive_temperature;
    _ = ecosys.snow_melt_water_routing;
    _ = ecosys.snow_phase_change;
    _ = ecosys.snow_source_order_energy;
    _ = ecosys.snow_relayering;
    _ = ecosys.snow_solute_transport;
    _ = ecosys.snow_chemistry_initialization;
    _ = ecosys.snow_surface_discharge;
    _ = ecosys.snow_surface_transfer_heat;
    _ = ecosys.snow_transport_solver;
    _ = ecosys.snow_vapor_diffusion;
    _ = ecosys.snow_vapor_equilibrium;
    _ = ecosys.snow_surface_atmosphere_exchange;
    _ = ecosys.snowpack_chemical_inventory_initialization;
    _ = ecosys.snowpack_geometry_temperature_update;
    _ = ecosys.snowpack_initial_state;
    _ = ecosys.snowpack_internal_salt_aggregation;
    _ = ecosys.snowpack_internal_solute_aggregation;
    _ = ecosys.snowpack_litter_heat_water_transfer;
    _ = ecosys.snowpack_phase_inventory_update;
    _ = ecosys.snowpack_surface_input_accounting;
    _ = ecosys.snowpack_top_layer_drift_state_update;
    _ = ecosys.snowpack_water_heat_aggregation;
    _ = ecosys.soil_air_porosity_dry_end_water;
    _ = ecosys.soil_anaerobic_growth_respiration;
    _ = ecosys.soil_aqueous_transport_bridge;
    _ = ecosys.soil_autotrophic_carbon_step;
    _ = ecosys.soil_autotrophic_denitrification_step;
    _ = ecosys.soil_biochemical_acidity;
    _ = ecosys.soil_biogeochemical_gas_aggregation;
    _ = ecosys.soil_biogeochemistry_output;
    _ = ecosys.soil_boundary_topology;
    _ = ecosys.soil_carboxyl_exchange_initialization;
    _ = ecosys.soil_carboxyl_proton_exchange;
    _ = ecosys.soil_catalog;
    _ = ecosys.soil_chemistry_initialization;
    _ = ecosys.soil_chemistry_layer_remap;
    _ = ecosys.soil_chemistry_parameters;
    _ = ecosys.soil_chemistry_water_carrier_rebase;
    _ = ecosys.soil_chemodenitrification;
    _ = ecosys.soil_chemodenitrification_step;
    _ = ecosys.soil_combustion;
    _ = ecosys.soil_daily_carbon_export;
    _ = ecosys.soil_daily_carbon_pools;
    _ = ecosys.soil_daily_ecosystem_carbon;
    _ = ecosys.soil_daily_fire_phosphorus;
    _ = ecosys.soil_daily_gas_flux;
    _ = ecosys.soil_daily_heat_ledger;
    _ = ecosys.soil_daily_heterotrophic_respiration;
    _ = ecosys.soil_daily_mineral_nitrogen;
    _ = ecosys.soil_daily_nitrogen_export;
    _ = ecosys.soil_daily_nitrogen_pools;
    _ = ecosys.soil_daily_output;
    _ = ecosys.soil_daily_phosphorus_export;
    _ = ecosys.soil_daily_phosphorus_pools;
    _ = ecosys.soil_daily_plant_carbon_flux;
    _ = ecosys.soil_daily_water_ledger;
    _ = ecosys.soil_denitrification;
    _ = ecosys.soil_depth_disturbance;
    _ = ecosys.soil_dissolved_gas_face_parameters;
    _ = ecosys.soil_dissolved_gas_transport;
    _ = ecosys.soil_enthalpy_balance;
    _ = ecosys.soil_erosion;
    _ = ecosys.soil_erosion_chemistry_bridge;
    _ = ecosys.soil_erosion_fertilizer_bridge;
    _ = ecosys.soil_erosion_mineral_bridge;
    _ = ecosys.soil_erosion_mineral_fertilizer_bridge;
    _ = ecosys.soil_erosion_organic_bridge;
    _ = ecosys.soil_face_geometry;
    _ = ecosys.soil_fertilizer_dissolution;
    _ = ecosys.soil_fertilizer_layer_remap;
    _ = ecosys.soil_gas_inventory_initialization;
    _ = ecosys.soil_gas_layer_remap;
    _ = ecosys.soil_gas_transport_step;
    _ = ecosys.soil_geometry_change_assembly;
    _ = ecosys.soil_geometry_disturbance_transaction;
    _ = ecosys.soil_heat_flux;
    _ = ecosys.soil_heat_output;
    _ = ecosys.soil_heat_solver;
    _ = ecosys.soil_heterotrophic_denitrification_step;
    _ = ecosys.soil_heterotrophic_respiration_step;
    _ = ecosys.soil_hourly_output_binding;
    _ = ecosys.soil_hourly_workspace;
    _ = ecosys.soil_hydraulic_conductivity;
    _ = ecosys.soil_hydrology;
    _ = ecosys.soil_initial_numerical_scales;
    _ = ecosys.soil_initial_water_ice_state;
    _ = ecosys.soil_initialization;
    _ = ecosys.soil_inorganic_carbon_storage;
    _ = ecosys.soil_ionic_strength_conductivity;
    _ = ecosys.soil_layer_geometry;
    _ = ecosys.soil_layer_geometry_phase_fractions;
    _ = ecosys.soil_litter_colonization_step;
    _ = ecosys.soil_mass_texture_concentration;
    _ = ecosys.soil_methane_oxidation;
    _ = ecosys.soil_methane_step;
    _ = ecosys.soil_methanogenesis;
    _ = ecosys.soil_microbial_assimilation_step;
    _ = ecosys.soil_microbial_inventory_bridge;
    _ = ecosys.soil_microbial_layer_mixing;
    _ = ecosys.soil_microbial_maintenance_step;
    _ = ecosys.soil_microbial_metabolism;
    _ = ecosys.soil_microbial_nitrogen_exchange_step;
    _ = ecosys.soil_microbial_phosphorus_exchange_step;
    _ = ecosys.soil_microbial_phosphorus_state;
    _ = ecosys.soil_microbial_respiration_activity;
    _ = ecosys.soil_microbial_state;
    _ = ecosys.soil_microbial_substrate_uptake_step;
    _ = ecosys.soil_microbial_turnover_step;
    _ = ecosys.soil_micropore_hydraulic_conductivity_classes;
    _ = ecosys.soil_mineral_layer_remap;
    _ = ecosys.soil_nitrification;
    _ = ecosys.soil_nitrification_step;
    _ = ecosys.soil_nitrifier_environment_step;
    _ = ecosys.soil_nitrite_layer_remap;
    _ = ecosys.soil_nitrogen_state_update;
    _ = ecosys.soil_nutrient_competition_history;
    _ = ecosys.soil_nitrogen_flux_workspace;
    _ = ecosys.soil_nitrogen_parameters;
    _ = ecosys.soil_nonsymbiotic_nitrogen_fixation_step;
    _ = ecosys.soil_organic_carbon_change;
    _ = ecosys.soil_organic_decomposition_step;
    _ = ecosys.soil_organic_face_parameters;
    _ = ecosys.soil_organic_initialization;
    _ = ecosys.soil_organic_layer_remap;
    _ = ecosys.soil_organic_parameters;
    _ = ecosys.soil_organic_priming_step;
    _ = ecosys.soil_organic_sorption;
    _ = ecosys.soil_organic_sorption_step;
    _ = ecosys.soil_organic_transport;
    _ = ecosys.soil_output_catalog;
    _ = ecosys.soil_oxygen_allocation;
    _ = ecosys.soil_oxygen_solver;
    _ = ecosys.soil_oxygen_step;
    _ = ecosys.soil_phase_solver;
    _ = ecosys.soil_phosphate_inventory;
    _ = ecosys.soil_plant_available_nutrients;
    _ = ecosys.soil_pore_gas_concentrations;
    _ = ecosys.soil_process_science;
    _ = ecosys.soil_profile_derivation;
    _ = ecosys.soil_profile_relayering;
    _ = ecosys.soil_profile_relayering_activity;
    _ = ecosys.soil_reactive_nitrogen_state;
    _ = ecosys.soil_respiration_products_step;
    _ = ecosys.soil_saturated_hydraulic_conductivity_defaults;
    _ = ecosys.soil_sediment_change;
    _ = ecosys.soil_silicate_inventory_initialization;
    _ = ecosys.soil_solute_face_parameters;
    _ = ecosys.soil_solver_properties;
    _ = ecosys.soil_runtime_material_refresh;
    _ = ecosys.soil_thermal;
    _ = ecosys.soil_vapor_solver;
    _ = ecosys.soil_water_boundary;
    _ = ecosys.soil_water_flux;
    _ = ecosys.soil_water_gas_solubility;
    _ = ecosys.soil_water_heat_layer_remap;
    _ = ecosys.soil_water_heat_step;
    _ = ecosys.soil_water_output;
    _ = ecosys.soil_water_phase_change;
    _ = ecosys.soil_water_potential_components;
    _ = ecosys.soil_water_retention;
    _ = ecosys.soil_water_solver;
    _ = ecosys.solute_activity_coefficients;
    _ = ecosys.solute_aqueous_network;
    _ = ecosys.solute_aqueous_reaction_rates;
    _ = ecosys.solute_carboxyl_exchange;
    _ = ecosys.solute_cation_exchange;
    _ = ecosys.solute_charge_classification;
    _ = ecosys.solute_chemistry_state;
    _ = ecosys.solute_conservative_reaction_span;
    _ = ecosys.solute_external_boundaries;
    _ = ecosys.solute_failure_reporter;
    _ = ecosys.solute_failure_snapshot;
    _ = ecosys.solute_geochemistry_network;
    _ = ecosys.solute_geochemistry_reaction_rates;
    _ = ecosys.solute_ion_pairing;
    _ = ecosys.solute_mineral_precipitation;
    _ = ecosys.solute_phosphate_exchange;
    _ = ecosys.solute_phosphate_network;
    _ = ecosys.solute_phosphate_precipitation;
    _ = ecosys.solute_phosphate_reaction_rates;
    _ = ecosys.solute_reaction_solver;
    _ = reaction_solver_numerics2;
    _ = ecosys.solute_silicate_weathering;
    _ = ecosys.solute_solid_carrier_rebase;
    _ = ecosys.solute_transport;
    _ = ecosys.solute_transport_solver;
    _ = ecosys.solute_transport_species;
    _ = ecosys.solute_water_equilibrium;
    _ = ecosys.surface_solute_routing;
    _ = ecosys.thin_layer_pore_solute_reset;
    _ = ecosys.thin_soil_boundary_solute_flux_reset;
    _ = ecosys.uptake_coupled_transaction;
    _ = ecosys.water_table_depth_mode_adjustment;
    _ = ecosys.input_climate_forcing;
}

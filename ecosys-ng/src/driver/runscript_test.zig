//! Tests for `runscript.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.

const canopy_biochemistry = @import("../canopy/photosynthesis/biochemistry.zig");
const canopy_optics = @import("../canopy/radiation/optics.zig");
const canopy_photosynthesis = @import("../canopy/photosynthesis/photosynthesis.zig");
const canopy_precipitation_retention = @import("../canopy/energy/precipitation_retention.zig");
const canopy_surface_exchange = @import("../canopy/energy/surface_exchange.zig");
const delimited_input = @import("../io/input/delimited_input.zig");
const ground_air_exchange = @import("../surface/ground_air_exchange.zig");
const plant_initialization = @import("../plant/initialization/seed_and_population.zig");
const plant_organ_partition = @import("../plant/partition/organ.zig");
const plant_phenology = @import("../plant/lifecycle/phenology.zig");
const plant_pool_aggregation = @import("../plant/accounting/pool_aggregation.zig");
const plant_root_disturbance = @import("../plant/root/plant_root_disturbance.zig");
const plant_root_exudation = @import("../plant/root/plant_root_exudation.zig");
const plant_root_gas_exchange = @import("../plant/root/plant_root_gas_exchange.zig");
const plant_root_metabolism = @import("../plant/root/plant_root_metabolism.zig");
const plant_root_mycorrhizal_exchange = @import("../plant/root/plant_root_mycorrhizal_exchange.zig");
const plant_root_nutrient_uptake = @import("../plant/root/plant_root_nutrient_uptake.zig");
const plant_root_porosity = @import("../plant/root/plant_root_porosity.zig");
const plant_root_salt_exchange = @import("../plant/root/plant_root_salt_exchange.zig");
const plant_root_system = @import("../plant/root/plant_root_system.zig");
const plant_shoot_root_exchange = @import("../plant/exchange/shoot_root.zig");
const plant_soil_exchange = @import("../plant/exchange/soil.zig");
const plant_storage_remobilization = @import("../plant/growth/storage_remobilization.zig");
const plant_symbiotic_fixation = @import("../canopy/symbiosis/plant_symbiotic_fixation.zig");
const shoot_growth_metabolism = @import("../plant/growth/shoot_growth_metabolism.zig");
const shoot_growth_runtime = @import("../plant/growth/shoot_growth_runtime.zig");
const snow_compaction = @import("../soil/water/snow_compaction.zig");
const snow_heat_conduction = @import("../soil/water/snow_heat_conduction.zig");
const snow_vapor_diffusion = @import("../soil/water/snow_vapor_diffusion.zig");
const snow_vapor_equilibrium = @import("../soil/water/snow_vapor_equilibrium.zig");
const soil_chemistry_initialization = @import("../soil/chemistry/initialization.zig");
const soil_combustion = @import("../soil/organic/combustion.zig");
const soil_gas_transport_step = @import("../soil/gas/transport_step.zig");
const soil_hourly_workspace = @import("../soil/runtime/hourly_workspace.zig");
const soil_plant_available_nutrients = @import("../soil/nutrients/plant_available_nutrients.zig");
const soil_process_science = @import("../soil/runtime/process_pipeline.zig");
const soil_solver_properties = @import("../soil/water/solver_properties.zig");
const spatial_grid = @import("../state/spatial_grid.zig");
const std = @import("std");
const surface_aerodynamics = @import("../surface/aerodynamics.zig");
const surface_gas_boundary_conductance = @import("../surface/gas_boundary_conductance.zig");
const surface_precipitation = @import("../surface/precipitation.zig");
const surface_runoff = @import("../surface/runoff.zig");
const runscript = @import("runscript.zig");
test "mandatory runscript records are line aware mixed delimiter and case insensitive" {
    const valid_prefix =
        "# heading\r\n\r\n1, 1|2 # dimensions\r\n" ++
        "GeOsPaTiAl_GrId|45|46|-75|-74|1|1 # degrees\r\n" ++
        "TiLe_LaYoUt\t1\t1\t2\r\n" ++
        "RuNtImE 1 1 1e-8 1e-11 40 0.5 # solver\r\n" ++
        "grid_inputs cells\r\n";
    try std.testing.expectError(error.MissingSoilSolverRecord, runscript.parse(std.testing.allocator, valid_prefix));
}

test "mandatory runscript records reject legacy headers missing tags and split values" {
    try std.testing.expectError(error.LongRunscriptRecord, runscript.parse(std.testing.allocator, "1,1,1,1\ngeospatial_grid,45,46,-75,-74,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-8,1e-11,40,0.5\n"));
    try std.testing.expectError(error.MissingGeospatialGridRecord, runscript.parse(std.testing.allocator, "1,1,2\ntile_layout,1,1,2\nruntime,1,1,1e-8,1e-11,40,0.5\n"));
    try std.testing.expectError(error.MissingTileLayoutRecord, runscript.parse(std.testing.allocator, "1,1,2\ngeospatial_grid,45,46,-75,-74,1,1\nruntime,1,1,1e-8,1e-11,40,0.5\n"));
    try std.testing.expectError(error.MissingRuntimeRecord, runscript.parse(std.testing.allocator, "1,1,2\ngeospatial_grid,45,46,-75,-74,1,1\ntile_layout,1,1,2\ngrid_inputs cells\n"));
    try std.testing.expectError(error.ShortRunscriptRecord, runscript.parse(std.testing.allocator, "1,1,2\ngeospatial_grid,45,46,-75,-74,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-8,1e-11,40\n0.5\n"));
}

test "mandatory runscript records reject joined and long records" {
    try std.testing.expectError(error.LongRunscriptRecord, runscript.parse(std.testing.allocator, "1,1,2,geospatial_grid,45,46,-75,-74,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-8,1e-11,40,0.5\n"));
    try std.testing.expectError(error.LongRunscriptRecord, runscript.parse(std.testing.allocator, "1,1,2\ngeospatial_grid,45,46,-75,-74,1,1\ntile_layout,1,1,2\nruntime,1,1,1e-8,1e-11,40,0.5,soil_solver\n"));
}

test "four-value domain header is rejected" {
    const source =
        \\1,1,2,3
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    try std.testing.expectError(error.LongRunscriptRecord, runscript.parse(std.testing.allocator, source));
}

test "five-value bounds and species header is rejected" {
    const source =
        \\1|1|1|1|37
        \\grid_inputs grid_inputs
        \\1|1
        \\1|1
        \\weather_grid|weather|options|NO|plants|o1|o2|o3|o4|o5|o6|o7|o8|o9|o10
        \\0|0
    ;
    try std.testing.expectError(error.LongRunscriptRecord, runscript.parse(std.testing.allocator, source));
}

test "runscript rejects empty explicit delimiter fields before token collapse" {
    inline for (.{
        "1,1,,1,1\ngrid_inputs grid_inputs\n",
        "1|1| |1|1\ngrid_inputs grid_inputs\n",
        "1\t1\t\t1\t1\ngrid_inputs grid_inputs\n",
        "1,1,1,1, # missing species before comment\ngrid_inputs grid_inputs\n",
    }) |source| try std.testing.expectError(
        error.EmptyRunscriptRecordValue,
        runscript.parse(std.testing.allocator, source),
    );
}

test "modern compact header defines horizontal cells vertical cells and species" {
    const source =
        \\99,99,12
        \\geospatial_grid,45,48,-80,-76,1,1
        \\tile_layout,2,3,2
        \\runtime,6,128,1e-9,1e-12,55,0.6
        \\soil_solver,-0.0005,-1.5e12,250000,0.2576,-0.20,0.36,0.60e-6,0.0260,0.50,0.32e-6,0.075,0.195,0.27,0.62,0.71,0.04,0.15,0.22,0.75,0.75,0.5,0.5,100,1.33,0.1,1.54,0.033,0.10,75,1e-15,0.067,0.125,890,10000,0.80,0.0125,120,10000,0.52,10,1.82,200,80,20,5,1,1
        \\soil_process,0.0098,8.96e-2,298.15,1.75,0.66,0.03,0.5e-3,1e-6,0.533,0.0267
        \\macropore_van_genuchten,0,15,2.68,0.5
        \\dual_domain_exchange,3,0.4
        \\frozen_hydraulic_impedance,7
        \\surface_residue_freeze_thaw,0,400,2.5
        \\soil_gas_transport,298.15,1.75,4.68e-2,7.80e-2,6.43e-2,5.57e-2,5.57e-2,6.67e-2,5.57e-2,0.66,1e-12,1e6,18
        \\soil_phase_heat,2.173e-3,0.61,5360,3.661e-3,18,8.3143,2450,9.0959e4,333,0.917,6.2913e-3,273.15,0.333,0.333,13990344827.5862,89223880597.0149,1.09495999584408,4.77823246449888,10000,4.19,1.9274
        \\geothermal,yes,10,1,8.1e-3,2.052e-4
        \\subsurface_state,1e-3,1e-6
        \\soil_geometry,1.82e-6,110000,0.083,1e-9
        \\surface_pond_energy,2.496e-6,0.838e-3
        \\surface_energy,0.97,0.97,0.97,0.07,0.43,0,1,173.15,373.15
        \\snow_layers,5,0.05,0.125,0.25,0.50,1.00,0.05,0.92,333,2.7185
        \\snow_compaction,0.25,1e-5,0.04,0.25,-0.08,23,-15,2,1.7e-3
        \\snow_thermal,0.0036,2.650,-1.652,0.6
        \\snow_vapor,2.173e-3,0.61,5360,3.661e-3,2465,2834
        \\snow_vapor_transport,8.96e-2,298.15,1.75,0,4.19
        \\surface_gas_resistance,-0.10,0.05,10,1e-6,1e6,2e-4,1e-6
        \\surface_runoff,0.005,0.011,1e-3,3600,1e-12
        \\rainfall_impact,8.95,8.44,15.8,5.87,2.5,2,1e-3,5e-4
        \\surface_aerodynamics,0.5,2,0.005,0.025,1.27e8,0.168,1e-12,0.00139,no
        \\ground_air,1.25e-3,5,1.25e-3,2465,2.173e-3,0.61,5360,3.661e-3
        \\canopy_surface_exchange,0.00139,0.0278,0.00139,0.0139,18,8.3143,4.19,0.00278,0.0278
        \\canopy_ammonia_exchange,0.16,0.10,0.05,2,1e-4,0.1,0.513,0.0171
        \\plant_structure,10
        \\canopy_layers,10
        \\canopy_geometry,4e-6
        \\canopy_discretization,4,4,4
        \\standing_dead_partition,0,0.045,0.660,0.295,0.020,0.010,0.010,0.020,0.0020,0.0010,0.0010,0.0020
        \\plant_initial_heat_water,273.15,2.173e-3,0.61,5360,3.661e-3,-1e-3
        \\plant_initial_geometry,5e-6,2,0.75,3.1416,0.33,4,1e-6,0.05,0.01,3.142
        \\plant_initial_phenology,0.005,1,24,10,15,3,4,5
        \\root_initialization,2.5,25,2.5e-6,-0.01,-0.01,1e-3,1
        \\root_morphology,1e-2,5
        \\standing_dead_energy,0.0025,2.496,0.97,0.838e-3,0.838e-4
        \\woody_optics,0.1,0.1,0.1,0.1
        \\canopy_retention,5e-4,2.5e-4,2.5e-4,2.5e-4,0.65,0.05
        \\shoot_controls,3600,1.56,2.10e5,3.96e5
        \\c4_carbon,1.2,4.8,0.083e9,0.025,1000,0.02,5e-7,5e6,0.5,3
        \\thermal_controls,3,2.5,1.25,5,12.5,15,35,27.5,30,2,0.002,0.005,0.010,0.002
        \\canopy_stress,24,60,0.02,8.3143,710,25.229,62500,197500,222500
        \\phenology_controls,8.3143,710,24.269,60000,197500,218500,0.1,0.25,2,0.667,-0.1,-150,-1.5,3600,1e-6,1e-6
        \\plant_pool_controls,no,1e-15,1e-6,1e-6,1e-6,1e-2,1e-3
        \\seed_set_controls,2.5e-2,0.5e-2,0.1e-2
        \\root_gas,298.15,8.57e-6,6,2.925e-2,0.31,0.516,0.0172,5.56e4,2.667,1e-6,0.5,-13.833,-0.857
        \\root_gas_transport,1.75,4.68e-2,7.80e-2,5.57e-2,6.67e-2,5.57e-2,6.43e-2,4.25e-6,7.08e-6,5.72e-6,4.00e-6,7.34e-6,8.57e-6,7.391e-1,3.156e-2,5.241e-1,2.852e2,3.156e-2,2.925e-2,0.14,0.14,0.23,0.07,0.14,0.31,0.843,0.597,0.897,0.513,0.597,0.516,0.0281,0.0199,0.0299,0.0171,0.0199,0.0172
        \\root_nutrients,298.15,4e-6,6e-6,3e-6,6,0.7,1,1,0.01,0.01,1e-4,31
        \\root_salts,298.15,4e-6,4e-6,4e-6,4e-6,4e-6,4e-6,4e-6,4e-6,6,1,1,1,1,1,1,1,1
        \\root_mycorrhizal_exchange,0.05,0.5
        \\root_exudation,1e3,0.1,0.1,1e-3
        \\root_porosity,0.75,0.1,0.01
        \\root_metabolism,0.015,0.025,0.1,0.01,0.010,1.70,0.167,0.333,0.667,0.667,2.5e-5,0.167,8.3143,710,62500,197500,25.216,1e3,0.05,0.10,0.25,1e-3,1,4,0.25,1,2,4,336,2.5,25,0.86,0.75,0.5,480
        \\organ_partition,0.75,0.25,0.0200,0.0500,0.0067,0.0167,0.75,1.50,2,2,1.75,1.50,0.25,0.50,0.67,0.67,0.58,0.50,0.10,0.10
        \\shoot_metabolism,0.015,0.025,0.010,0.333,1.70,0.025,0.1,0.01
        \\shoot_node_growth,2.5,25,-0.333,-0.50,-0.667,0.002,2,2,1e-3,5e-3,5e-2,0.75,0.005,0.001,72,23,360,1440,720,720,5e-3,5e-3,5e-6,5e-6,5e-5,5e-4
        \\seasonal_turnover,2.884e-3,240
        \\branch_mobile_exchange,0.01,0.01,0.05
        \\symbiotic_fixation,1e-4,0.125,0.010,0.25,0.1,0.01,1e-4,1e-5,10,1000,1e-2,0.167,0.333,0.333,0.333,0.20,0.10,0.05,0.20,0.10,0.05,0.50,0.25,0.125,0.050,0.025,0.0125
        \\plant_fire_combustion,473.15,2,8.3143,60000,12.028,1000,1000,1000,1000,2500,120000,20.620,1,2.667,0,0.5,2100,10,0.0375,0.0125,0.0743
        \\soil_fire_combustion,473.15,2,8.3143,60000,12.028,120000,20.620,1000,5000,1000,1000,1000,1000,1,2.667,0,0.5,2.8,0.005,0.0375,0.0125,0.0743
        \\shoot_root_exchange,0.05,0.005,0.25,1
        \\storage_remobilization,45.8,138.4,0.015,0.005,0.25,0.25,0.75,0.75,0.100,0.100,0.010,0.100,0.100,0.100,0.050,0.20,0.005,0.020,0.10
        \\plant_nutrients,0,0,0,1,1,1,1
        \\microbial_dimensions,6,7
        \\organic_initialization_file,organic-parameters
        \\surface_gas_parameter_file,surface-gas-parameters
        \\soil_nitrogen_parameter_file,soil-nitrogen-parameters
        \\chemistry_initialization,0.01,1e-8,1.9e-21,6.3e-26,7.5,6.2e-5,4.8e-10
        \\chemistry_units,14,31,27,56,40,24.3,23,39.1,32,35.5,1,1,0.01,1
        \\chemistry_reaction_file,chemistry-reaction-parameters
        \\fertilizer_units,14
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather
        \\options
        \\NO
        \\plants
        \\o1
        \\o2
        \\o3
        \\o4
        \\o5
        \\o6
        \\o7
        \\o8
        \\o9
        \\o10
        \\0,0
    ;
    var script = try runscript.parse(std.testing.allocator, source);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 12), try script.gridCellCount());
    try std.testing.expectEqual(@as(usize, 12), script.plant_species_count);
    try std.testing.expectEqual(@as(usize, 2), script.tile_row_count);
    try std.testing.expectEqual(@as(usize, 3), script.tile_column_count);
    try std.testing.expectEqual(@as(usize, 2), script.lateral_flow_halo_cell_count);
    try std.testing.expectEqual(@as(usize, 6), script.worker_count);
    try std.testing.expectEqual(@as(usize, 128), script.tile_cell_count);
    try std.testing.expectEqual(@as(u16, 55), script.max_nonlinear_iterations);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), script.picard_relaxation, 1.0e-15);
    try std.testing.expectEqual(@as(usize, 10), script.root_axes_per_plant);
}

test "geospatial runscript requires explicit improved water and freeze controls" {
    const source =
        \\1,1,1
        \\geospatial_grid,45,46,-80,-79,1,1
        \\tile_layout,1,1,2
        \\runtime,1,1,1e-9,1e-12,40,0.5
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    try std.testing.expectError(error.MissingSoilSolverRecord, runscript.parse(std.testing.allocator, source));
}

test "geospatial runscript requires explicit soil gas transport controls" {
    const source =
        \\1,1,1
        \\geospatial_grid,45,46,-80,-79,1,1
        \\tile_layout,1,1,2
        \\runtime,1,1,1e-9,1e-12,40,0.5
        \\soil_solver,-0.0005,-1.5e12,250000,0.2576,-0.20,0.36,0.60e-6,0.0260,0.50,0.32e-6,0.075,0.195,0.27,0.62,0.71,0.04,0.15,0.22,0.75,0.75,0.5,0.5,100,1.33,0.1,1.54,0.033,0.10,75,1e-15,0.067,0.125,890,10000,0.80,0.0125,120,10000,0.52,10,1.82,200,80,20,5,1,1
        \\soil_process,0.0098,8.96e-2,298.15,1.75,0.66,0.03,0.5e-3,1e-6,0.533,0.0267
        \\macropore_van_genuchten,0,15,2.68,0.5
        \\dual_domain_exchange,3,0.4
        \\frozen_hydraulic_impedance,7
        \\surface_residue_freeze_thaw,0,400,2.5
        \\grid_inputs grid_inputs
        \\1,1
        \\1,1
        \\weather_grid weather options NO plants o1 o2 o3 o4 o5 o6 o7 o8 o9 o10
        \\0,0
    ;
    try std.testing.expectError(error.MissingSoilGasTransportRecord, runscript.parse(std.testing.allocator, source));
}

//! Tests for `landscape_mass_inventory.zig`.
//!
//! Extracted verbatim so the module beside it contains only the model
//! code. Tests that use private declarations of that module stay there,
//! since a sibling file can only reach `pub` declarations.

const audit = @import("mass_balance_audit.zig");
const canopy_retention = @import("../canopy/energy/precipitation_retention.zig");
const gas = @import("../soil/gas/transport.zig");
const grid_module = @import("../state/grid.zig");
const litter_chemistry = @import("../surface/litter_chemistry.zig");
const litter_fertilizer = @import("../surface/litter_fertilizer.zig");
const mineral_fertilizer = @import("../management/mineral_fertilizer_inventory.zig");
const mineral_nitrogen = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const nitrogen_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
const organic = @import("../soil/organic/initialization.zig");
const organic_transport = @import("../soil/organic/transport.zig");
const plant_roots = @import("../plant/root/plant_root_system.zig");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const soil_chemistry = @import("../soil/solute/chemistry_state.zig");
const soil_reactive_nitrogen = @import("../soil/nutrients/reactive_nitrogen_state.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const solute_transport = @import("../soil/solute/transport.zig");
const std = @import("std");
const surface_precipitation = @import("../surface/precipitation.zig");
const surface_solute_routing = @import("../soil/solute/surface_solute_routing.zig");
const surface_aqueous = @import("../surface/aqueous_runoff_transport.zig");
const zone_classification = @import("../soil/solute/charge_classification.zig");
const landscape_mass_inventory = @import("landscape_mass_inventory.zig");

fn expectStoragePartition(
    whole: landscape_mass_inventory.Storage,
    parts: []const landscape_mass_inventory.Storage,
) !void {
    var sum: landscape_mass_inventory.Storage = .{};
    for (parts) |part| try sum.add(part);
    inline for (std.meta.fields(landscape_mass_inventory.Storage)) |field| {
        const expected = @field(whole, field.name);
        const actual = @field(sum, field.name);
        try std.testing.expectApproxEqAbs(expected, actual, 1e-10 * @max(1, @abs(expected)));
    }
}

test "surface transport inventory counts authoritative complexes and PO4 H3PO4 once" {
    var state = try surface_solute_routing.State.init(
        std.testing.allocator,
        1,
        1,
        surface_aqueous.species_count,
    );
    defer state.deinit();
    state.amount_mol[@intFromEnum(surface_aqueous.Species.calcium_carbonate)] = 2;
    state.amount_mol[@intFromEnum(surface_aqueous.Species.non_band_iron_hpo4)] = 3;
    // Free cations are mirrored in litter chemistry and must not be counted.
    // PO4 is distinct from the mineral owner's HPO4/H2PO4 and must be counted.
    state.amount_mol[@intFromEnum(surface_aqueous.Species.calcium)] = 100;
    state.amount_mol[@intFromEnum(surface_aqueous.Species.non_band_phosphate)] = 100;
    state.amount_mol[@intFromEnum(surface_aqueous.Species.band_phosphate)] = 100;

    const result = try landscape_mass_inventory.aggregateSurfaceTransportComplexes(&state, 12, 31);
    try std.testing.expectEqual(@as(f64, 24), result.carbon_dioxide_carbon_g);
    try std.testing.expectEqual(@as(f64, 3193), result.phosphate_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 2), result.calcium_mol);
    try std.testing.expectEqual(@as(f64, 3), result.iron_mol);
    try std.testing.expectEqual(@as(f64, 0), result.sodium_mol);
    try std.testing.expectEqual(@as(f64, 113), result.ion_inventory_mol);
}
test "snow inventory rejects hidden non-finite inactive-layer mass" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    state.amount_g[snow.species_count] = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteSnowInventory,
        landscape_mass_inventory.aggregateSnow(&state, 0.92, 333, 2.095, 4.19, 1.9274, 273.15, .{
            .nitrogen = 14,
            .phosphorus = 31,
            .ions = .{ .aluminum = 27, .iron = 56, .calcium = 40, .magnesium = 24.3, .sodium = 23, .potassium = 39.1, .sulfur = 32, .chloride = 35.5 },
        }),
    );
}

test "REDIST soil inventory uses runtime active layers and all gas phases" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 2,
            .lat_count = 1,
            .soil_layers = 3,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 2;
    grid.active_soil_layer_count[1] = 1;
    for (0..grid.layer_count) |index| {
        grid.matrix_liquid_water_m3[index] = 1;
        grid.macropore_liquid_water_m3[index] = 2;
        grid.matrix_ice_water_m3[index] = 3;
        grid.macropore_ice_water_m3[index] = 4;
        grid.water_vapor_volume_m3[index] = 5;
        grid.soil_temperature_k[index] = 250;
    }
    var gas_state = try gas.State.init(std.testing.allocator, grid.layer_count);
    defer gas_state.deinit();
    for (0..grid.layer_count) |layer| {
        const first = layer * gas.species_count;
        inline for (.{ gas_state.gaseous_mass_g, gas_state.dissolved_mass_g, gas_state.macropore_dissolved_mass_g, gas_state.band_dissolved_mass_g }) |phase| {
            phase[first + @intFromEnum(gas.Species.carbon_dioxide)] = 1;
            phase[first + @intFromEnum(gas.Species.methane)] = 2;
            phase[first + @intFromEnum(gas.Species.oxygen)] = 3;
            phase[first + @intFromEnum(gas.Species.nitrogen)] = 4;
            phase[first + @intFromEnum(gas.Species.nitrous_oxide)] = 5;
            phase[first + @intFromEnum(gas.Species.ammonia)] = 6;
            phase[first + @intFromEnum(gas.Species.hydrogen)] = 7;
        }
    }
    const dry_heat_capacity = [_]f64{2} ** 6;
    const volume = [_]f64{0.5} ** 6;
    const inventory = try landscape_mass_inventory.aggregateSoilPhysicalAndGas(
        &grid,
        &dry_heat_capacity,
        &volume,
        4,
        1.5,
        0.92,
        333,
        273.15,
        &gas_state,
    );
    const cell_inventory = [_]landscape_mass_inventory.Storage{
        try landscape_mass_inventory.aggregateSoilPhysicalAndGasCell(&grid, &dry_heat_capacity, &volume, 4, 1.5, 0.92, 333, 273.15, &gas_state, 0),
        try landscape_mass_inventory.aggregateSoilPhysicalAndGasCell(&grid, &dry_heat_capacity, &volume, 4, 1.5, 0.92, 333, 273.15, &gas_state, 1),
    };
    try expectStoragePartition(inventory, &cell_inventory);
    const active: f64 = 3;
    try std.testing.expectEqual(active * 15, inventory.water_m3);
    // HEAT-001 resolution A, second layer: enthalpy relative to LIQUID water at
    // 0 K. Frozen carriers do not sit exactly `L` below liquid at the same
    // temperature; they follow the liquid branch to the melting point and the
    // ice branch back down, giving `C_l*Tm - L + C_i*(T - Tm)` per cubic metre.
    //
    // Note this test's heat capacities are the deliberately non-physical
    // `C_l = 4`, `C_i_phys = 1.5`, and `rho_i = 0.92`. The WE coefficient is
    // therefore `1.5/0.92`; this independently pins the F77 physical-volume
    // conversion instead of allowing raw `C_i_phys*WE` to pass.
    const frozen_water_equivalent_m3: f64 = 3 + 4;
    try std.testing.expectEqual(
        active * ((2 * 0.5 + 4 * (1 + 2 + 5)) * 250 +
            (4 * 273.15 - 333 + (1.5 / 0.92) * (250 - 273.15)) * frozen_water_equivalent_m3),
        inventory.heat_megajoules,
    );
    try std.testing.expectEqual(active * 4 * 3, inventory.carbon_dioxide_carbon_g);
    try std.testing.expectEqual(active * 4 * 3, inventory.oxygen_g);
    try std.testing.expectEqual(active * 4 * 7, inventory.hydrogen_g);
    try std.testing.expectEqual(active * 4 * 9, inventory.dinitrogen_nitrogen_g);
    // Only gaseous NH3 is gas-owned; the three aqueous slots are transient
    // mirrors of mineral-N and must not enter this census.
    try std.testing.expectEqual(active * 6, inventory.ammonium_nitrogen_g);
}

test "REDIST root gas inventory includes both root phases" {
    var roots = try plant_roots.State.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    roots.gaseous_carbon_dioxide_g_c[0] = 1;
    roots.aqueous_carbon_dioxide_g_c[0] = 2;
    roots.gaseous_methane_g_c[0] = 3;
    roots.aqueous_methane_g_c[0] = 4;
    roots.gaseous_oxygen_g_o[0] = 5;
    roots.aqueous_oxygen_g_o[0] = 6;
    roots.gaseous_nitrous_oxide_g_n[0] = 7;
    roots.aqueous_nitrous_oxide_g_n[0] = 8;
    roots.gaseous_ammonia_g_n[0] = 9;
    roots.aqueous_ammonia_g_n[0] = 10;
    roots.gaseous_hydrogen_g_h[0] = 11;
    roots.aqueous_hydrogen_g_h[0] = 12;

    const inventory = try landscape_mass_inventory.aggregateRootGas(&roots);
    try expectStoragePartition(inventory, &.{try landscape_mass_inventory.aggregateRootGasCell(&roots, 1, 0)});
    try std.testing.expectEqual(@as(f64, 10), inventory.carbon_dioxide_carbon_g);
    try std.testing.expectEqual(@as(f64, 11), inventory.oxygen_g);
    try std.testing.expectEqual(@as(f64, 23), inventory.hydrogen_g);
    try std.testing.expectEqual(@as(f64, 15), inventory.dinitrogen_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 19), inventory.ammonium_nitrogen_g);
}

test "REDIST surface organic all-storage split includes humus microbial pool" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    // Both ordinary and K=4 humus microbial pools are persistent owners.
    state.microbial[0] = .{
        .carbon_g_c = 1,
        .nitrogen_g_n = 2,
        .phosphorus_g_p = 3,
    };
    const humus_microbial =
        4 * organic.microbial_population_count * organic.kinetic_fraction_count;
    state.microbial[humus_microbial] = .{
        .carbon_g_c = 100,
        .nitrogen_g_n = 100,
        .phosphorus_g_p = 100,
    };
    state.residue[0] = .{
        .carbon_g_c = 4,
        .nitrogen_g_n = 5,
        .phosphorus_g_p = 6,
    };
    state.dissolved[0] = .{
        .carbon_g_c = 7,
        .nitrogen_g_n = 8,
        .phosphorus_g_p = 9,
    };
    state.adsorbed[0] = .{
        .carbon_g_c = 10,
        .nitrogen_g_n = 11,
        .phosphorus_g_p = 12,
    };
    state.dissolved_acetate_carbon_g_c[0] = 13;
    state.adsorbed_acetate_carbon_g_c[0] = 14;
    // Fifth structural fraction is persistent charcoal and must be included.
    state.structural[organic.structural_fraction_count - 1] = .{
        .carbon_g_c = 15,
        .nitrogen_g_n = 16,
        .phosphorus_g_p = 17,
    };
    state.colonized_structural_carbon_g_c[
        organic.structural_fraction_count - 1
    ] = 9; // subset diagnostic; must not be counted a second time.
    const inventory = try landscape_mass_inventory.aggregateSurfaceOrganic(&state);
    try expectStoragePartition(inventory, &.{
        try landscape_mass_inventory.aggregateSurfaceOrganicCell(&state, 0),
        try landscape_mass_inventory.aggregateSurfaceOrganicCell(&state, 1),
    });
    try std.testing.expectEqual(@as(f64, 164), inventory.residue_carbon_g);
    try std.testing.expectEqual(@as(f64, 142), inventory.residue_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 147), inventory.residue_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 0), inventory.organic_carbon_g);
}

test "REDIST soil organic split assigns only K=4 to humus" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 1,
            .lat_count = 1,
            .soil_layers = 2,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    var state = try organic.State.init(std.testing.allocator, grid.layer_count);
    defer state.deinit();

    state.microbial[0] = .{
        .carbon_g_c = 1,
        .nitrogen_g_n = 2,
        .phosphorus_g_p = 3,
    };
    const humus_microbial =
        4 * organic.microbial_population_count * organic.kinetic_fraction_count;
    state.microbial[humus_microbial] = .{
        .carbon_g_c = 4,
        .nitrogen_g_n = 5,
        .phosphorus_g_p = 6,
    };
    const humus_mobile = 4;
    state.dissolved[humus_mobile] = .{
        .carbon_g_c = 7,
        .nitrogen_g_n = 8,
        .phosphorus_g_p = 9,
    };
    state.dissolved_acetate_carbon_g_c[humus_mobile] = 10;
    state.structural[organic.structural_fraction_count - 1] = .{
        .carbon_g_c = 11,
        .nitrogen_g_n = 12,
        .phosphorus_g_p = 13,
    };
    const humus_charcoal =
        4 * organic.structural_fraction_count +
        organic.structural_fraction_count - 1;
    state.structural[humus_charcoal] = .{
        .carbon_g_c = 14,
        .nitrogen_g_n = 15,
        .phosphorus_g_p = 16,
    };
    // Inactive capacity must not enter the profile inventory.
    const inactive_first =
        organic.microbial_substrate_count *
        organic.microbial_population_count *
        organic.kinetic_fraction_count;
    state.microbial[inactive_first].carbon_g_c = 1000;

    const inventory = try landscape_mass_inventory.aggregateSoilOrganic(&state, &grid);
    try expectStoragePartition(inventory, &.{try landscape_mass_inventory.aggregateSoilOrganicCell(&state, &grid, 0)});
    try std.testing.expectEqual(@as(f64, 12), inventory.residue_carbon_g);
    try std.testing.expectEqual(@as(f64, 14), inventory.residue_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 16), inventory.residue_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 35), inventory.organic_carbon_g);
    try std.testing.expectEqual(@as(f64, 28), inventory.organic_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 31), inventory.organic_phosphorus_g);
}

test "REDIST surface chemistry retains N P and TION stoichiometry" {
    var chemistry = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var fertilizer = try litter_fertilizer.State.init(std.testing.allocator, 1);
    defer fertilizer.deinit();
    const cell = &chemistry.cells[0];
    cell.ammonium_mol_per_m3 = 1;
    cell.ammonia_mol_per_m3 = 2;
    cell.nitrate_mol_per_m3 = 3;
    cell.hpo4_mol_p_per_m3 = 4;
    cell.h2po4_mol_p_per_m3 = 5;
    cell.calcium_mol_per_m3 = 6;
    cell.bicarbonate_mol_per_m3 = 7;
    cell.exchange.ammonium_mol_per_megagram = 8;
    cell.exchange.calcium_mol_per_megagram = 9;
    cell.carboxyl_hydrogen_mol_per_megagram = 20;
    cell.phosphate_surface.protonated_site_mol_per_megagram = 21;
    cell.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram = 10;
    cell.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram = 11;
    cell.phosphate_minerals.monocalcium_phosphate_mol_per_m3 = 12;
    cell.phosphate_minerals.hydroxyapatite_mol_per_m3 = 13;
    cell.salt_minerals.gypsum_mol_per_m3 = 14;
    chemistry.mineral_reference_water_m3[0] = 2;
    fertilizer.cells[0].ammonium_mol_n = 15;
    fertilizer.cells[0].ammonia_mol_n = 16;
    fertilizer.cells[0].urea_mol_n = 17;
    fertilizer.cells[0].nitrate_mol_n = 18;

    const inventory = try landscape_mass_inventory.aggregateSurfaceChemistry(
        &chemistry,
        &fertilizer,
        &.{19},
        &.{2},
        &.{3},
        12,
        14,
        31,
    );
    try expectStoragePartition(inventory, &.{try landscape_mass_inventory.aggregateSurfaceChemistryCell(
        &chemistry,
        &fertilizer,
        &.{19},
        &.{2},
        &.{3},
        12,
        14,
        31,
        0,
    )});
    try std.testing.expectEqual(
        @as(f64, 14 * (2 * (1 + 2) + 3 * 8 + 15 + 16 + 17)),
        inventory.ammonium_nitrogen_g,
    );
    try std.testing.expectEqual(
        @as(f64, 14 * (2 * 3 + 18) + 19),
        inventory.nitrate_nitrogen_g,
    );
    try std.testing.expectEqual(
        @as(f64, 31 * (2 * (4 + 5 + 2 * 12 + 3 * 13) + 3 * (10 + 11))),
        inventory.phosphate_phosphorus_g,
    );
    try std.testing.expectEqual(
        @as(f64, 12 * 2 * 7),
        inventory.carbon_dioxide_carbon_g,
    );
    const expected_ions =
        2 * ((6 + 2 * 7 + 2 * 4 + 3 * 5) +
            (2 * 14 + 7 * 12 + 9 * 13)) +
        3 * (2 * 8 + 9 + 20 + 6 * 21 + 3 * 10 + 4 * 11) +
        (2 * 15 + 16 + 17 + 18);
    try std.testing.expectEqual(
        @as(f64, expected_ions),
        inventory.ion_inventory_mol,
    );
    try std.testing.expectEqual(@as(f64, 221), inventory.calcium_mol);
    try std.testing.expectEqual(@as(f64, 28), inventory.sulfur_mol);
}

test "storage state_update cannot overwrite cumulative EXEC ledgers" {
    var totals = std.mem.zeroes(audit.Totals);
    totals.landscape_area_m2 = 10;
    totals.cumulative_rain_m3 = 17;
    totals.cumulative_nitrogen_output_g = 19;
    try landscape_mass_inventory.publishStorage(&totals, .{
        .water_m3 = 1,
        .organic_carbon_g = 2,
        .ion_inventory_mol = 3,
        .plant_carbon_g = 5,
        .plant_nitrogen_g = 7,
        .plant_phosphorus_g = 11,
    });
    try std.testing.expectEqual(@as(f64, 1), totals.water_storage_m3);
    try std.testing.expectEqual(@as(f64, 2), totals.organic_carbon_g);
    try std.testing.expectEqual(@as(f64, 3), totals.ion_inventory_mol);
    try std.testing.expectEqual(@as(f64, 5), totals.plant_carbon_g);
    try std.testing.expectEqual(@as(f64, 7), totals.plant_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 11), totals.plant_phosphorus_g);
    try std.testing.expectEqual(@as(f64, 17), totals.cumulative_rain_m3);
    try std.testing.expectEqual(
        @as(f64, 19),
        totals.cumulative_nitrogen_output_g,
    );
}

test "REDIST surface physical inventory includes vapor and gas-owned phases" {
    var surface = try surface_precipitation.RuntimeState.init(
        std.testing.allocator,
        2,
    );
    defer surface.deinit();
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 2,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    var gas_state = try gas.State.init(std.testing.allocator, 2);
    defer gas_state.deinit();
    var organic_state = try organic.State.init(std.testing.allocator, 2);
    defer organic_state.deinit();
    surface.litter_water_m3[0] = 1;
    surface.litter_water_m3[1] = 2;
    grid.surface_temperature_k[0] = 250;
    grid.surface_temperature_k[1] = 300;
    gas_state.water_vapor_mol[0] = 10;
    gas_state.water_vapor_mol[1] = 20;
    organic_state.structural[0].carbon_g_c = 100;
    organic_state.structural[
        organic.substrate_count * organic.structural_fraction_count
    ].carbon_g_c = 200;
    for (0..2) |cell| {
        const first = cell * gas.species_count;
        inline for (.{ gas_state.gaseous_mass_g, gas_state.dissolved_mass_g, gas_state.macropore_dissolved_mass_g, gas_state.band_dissolved_mass_g }) |phase| {
            phase[first + @intFromEnum(gas.Species.carbon_dioxide)] = 1;
            phase[first + @intFromEnum(gas.Species.methane)] = 2;
            phase[first + @intFromEnum(gas.Species.oxygen)] = 3;
            phase[first + @intFromEnum(gas.Species.nitrogen)] = 4;
            phase[first + @intFromEnum(gas.Species.nitrous_oxide)] = 5;
            phase[first + @intFromEnum(gas.Species.ammonia)] = 6;
            phase[first + @intFromEnum(gas.Species.hydrogen)] = 7;
        }
    }
    const ice = [_]f64{ 0.5, 0.25 };
    const parameters: landscape_mass_inventory.SurfacePhysicalParameters = .{
        .dry_organic_heat_capacity_megajoules_per_g_c_k = 2.5e-6,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .ice_density_megagrams_per_m3 = 0.917,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .pure_water_melting_temperature_k = 273.15,
        .water_molar_mass_g_per_mol = 18,
        .liquid_water_density_g_per_m3 = 1e6,
    };
    const inventory = try landscape_mass_inventory.aggregateSurfacePhysicalAndGas(
        &surface,
        &ice,
        &grid,
        &gas_state,
        &organic_state,
        parameters,
    );
    try expectStoragePartition(inventory, &.{
        try landscape_mass_inventory.aggregateSurfacePhysicalAndGasCell(&surface, &ice, &grid, &gas_state, &organic_state, parameters, 0),
        try landscape_mass_inventory.aggregateSurfacePhysicalAndGasCell(&surface, &ice, &grid, &gas_state, &organic_state, parameters, 1),
    });
    const vapor0 = 10.0 * 18.0 / 1e6;
    const vapor1 = 20.0 * 18.0 / 1e6;
    try std.testing.expectApproxEqAbs(
        1 + 2 + 0.5 + 0.25 + vapor0 + vapor1,
        inventory.water_m3,
        1e-14,
    );
    // HEAT-001 resolution A, second layer. Surface litter/pond ice is a frozen
    // carrier and carries `C_l*Tm - L + C_i*(T - Tm)` per cubic metre, not
    // `C_i*T - L`. The two cells sit at 250 K and 300 K, so this expectation
    // also pins that the ice branch is evaluated at each cell's own
    // temperature rather than at the melting point.
    const frozen_enthalpy_at = struct {
        fn f(temperature_k: f64) f64 {
            return 4.19 * 273.15 - 333 + (1.9274 / 0.917) * (temperature_k - 273.15);
        }
    }.f;
    const expected_heat =
        (2.5e-6 * 100 + 4.19 * (1 + vapor0)) * 250 +
        (2.5e-6 * 200 + 4.19 * (2 + vapor1)) * 300 +
        frozen_enthalpy_at(250) * 0.5 +
        frozen_enthalpy_at(300) * 0.25;
    try std.testing.expectApproxEqAbs(expected_heat, inventory.heat_megajoules, 1e-10);
    try std.testing.expectEqual(@as(f64, 24), inventory.carbon_dioxide_carbon_g);
    try std.testing.expectEqual(@as(f64, 24), inventory.oxygen_g);
    try std.testing.expectEqual(@as(f64, 56), inventory.hydrogen_g);
    try std.testing.expectEqual(@as(f64, 72), inventory.dinitrogen_nitrogen_g);
    // Aqueous NH3 is chemistry-owned and must not be counted again here.
    try std.testing.expectEqual(@as(f64, 12), inventory.ammonium_nitrogen_g);
}

test "dry litter ammonia inventory uses persisted chemistry carrier exactly once" {
    var chemistry = try litter_chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var fertilizer = try litter_fertilizer.State.init(std.testing.allocator, 1);
    defer fertilizer.deinit();
    chemistry.cells[0].ammonia_mol_per_m3 = 2;
    chemistry.dry_reference_water_m3[0] = 3;
    const inventory = try landscape_mass_inventory.aggregateSurfaceChemistry(
        &chemistry,
        &fertilizer,
        &.{0},
        &.{0},
        &.{0},
        12,
        14,
        31,
    );
    try std.testing.expectEqual(@as(f64, 84), inventory.ammonium_nitrogen_g);
}

test "EXTRACT canopy inventory supports more than five runtime species" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 2,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 7,
        },
        .{ .worker_threads = 3, .tile_cells = 2 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var plants = try grid_module.PlantState.init(std.testing.allocator, config);
    defer plants.deinit();
    var retention = try canopy_retention.State.init(
        std.testing.allocator,
        2,
        7,
    );
    defer retention.deinit();
    for (0..14) |plant| {
        plants.canopy_water_storage_m_per_m2[plant] = 0.001;
        retention.living_surface_water_m3[plant] = 0.01;
        retention.standing_dead_surface_water_m3[plant] = 0.02;
        retention.previous_water_energy_megajoules[plant] = 4.19 *
            (0.01 + 0.02) * 280;
    }
    const inventory = try landscape_mass_inventory.aggregateCanopyWaterAndHeat(
        &plants,
        &retention,
        &.{ 10, 20 },
    );
    try expectStoragePartition(inventory, &.{
        try landscape_mass_inventory.aggregateCanopyWaterAndHeatCell(&plants, &retention, &.{ 10, 20 }, 0),
        try landscape_mass_inventory.aggregateCanopyWaterAndHeatCell(&plants, &retention, &.{ 10, 20 }, 1),
    });
    try std.testing.expectApproxEqAbs(
        7 * (0.001 * 10 + 0.01 + 0.02) +
            7 * (0.001 * 20 + 0.01 + 0.02),
        inventory.water_m3,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        4.19 * (14 * (0.01 + 0.02)) * 280,
        inventory.heat_megajoules,
        1e-12,
    );
}

test "hour-one census sees initialized transport mineral nitrogen before capture" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 1,
            .lat_count = 1,
            .soil_layers = 1,
            .plant_populations = 1,
        },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.matrix_liquid_water_m3[0] = 2;

    var transport = try mineral_nitrogen.State.init(std.testing.allocator, 1);
    defer transport.deinit();
    var chemistry = try soil_chemistry.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    var reactive = try soil_reactive_nitrogen.State.init(std.testing.allocator, 1, 1);
    defer reactive.deinit();
    var fertilizer = try nitrogen_fertilizer.State.init(std.testing.allocator, 1, 1);
    defer fertilizer.deinit();

    chemistry.aqueous[0].ammonium_non_band = 2;
    chemistry.aqueous[0].ammonium_band = 4;
    chemistry.aqueous[0].ammonia_non_band = 0.5;
    chemistry.aqueous[0].ammonia_band = 1;
    chemistry.aqueous[0].nitrate_non_band = 3;
    chemistry.aqueous[0].nitrate_band = 5;
    reactive.non_band_nitrite_g_n[0] = 7;
    reactive.band_nitrite_g_n[0] = 14;

    const transport_fractions: mineral_nitrogen.ZoneFractions = .{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
    };
    const census_fractions: zone_classification.ZoneFractions = .{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.8,
        .phosphate_band = 0.2,
    };
    try transport.initializeMatrix(
        &chemistry,
        &reactive,
        grid.matrix_liquid_water_m3,
        transport_fractions,
        14,
    );

    const before_capture = try landscape_mass_inventory.aggregateProfileMineralNitrogenCell(
        &grid,
        &transport,
        &chemistry,
        &fertilizer,
        &.{1},
        census_fractions,
        14,
        0,
    );
    try std.testing.expectEqual(@as(f64, 87.5), before_capture.ammonium_nitrogen_g);
    try std.testing.expectApproxEqAbs(@as(f64, 127.4), before_capture.nitrate_nitrogen_g, 1e-13);

    const initialized_amounts = try std.testing.allocator.dupe(f64, transport.matrix.amount_mol);
    defer std.testing.allocator.free(initialized_amounts);
    try transport.captureHourStartMatrix(
        &chemistry,
        &reactive,
        grid.matrix_liquid_water_m3,
        transport_fractions,
        14,
    );
    try std.testing.expectEqualSlices(f64, initialized_amounts, transport.matrix.amount_mol);
    const after_capture = try landscape_mass_inventory.aggregateProfileMineralNitrogenCell(
        &grid,
        &transport,
        &chemistry,
        &fertilizer,
        &.{1},
        census_fractions,
        14,
        0,
    );
    try std.testing.expectEqualDeep(before_capture, after_capture);
}

test "REDIST profile mineral nitrogen counts each runtime owner once" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 2,
            .lat_count = 1,
            .soil_layers = 2,
            .plant_populations = 1,
        },
        .{ .worker_threads = 2, .tile_cells = 2 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.active_soil_layer_count[1] = 1;

    var transport = try mineral_nitrogen.State.init(
        std.testing.allocator,
        grid.layer_count,
    );
    defer transport.deinit();
    var chemistry = try soil_chemistry.State.init(
        std.testing.allocator,
        grid.layer_count,
    );
    defer chemistry.deinit();
    var fertilizer = try nitrogen_fertilizer.State.init(
        std.testing.allocator,
        grid.cell_count,
        grid.soil_layer_capacity,
    );
    defer fertilizer.deinit();

    // Active profile cells are 0 and 2. Matrix and macropore are both
    // authoritative and must be included.
    for ([_]usize{ 0, 2 }) |profile_cell| {
        const matrix = try transport.matrix.cellAmounts(profile_cell);
        const macropore = try transport.macropore.cellAmounts(profile_cell);
        matrix[@intFromEnum(mineral_nitrogen.Species.ammonium_non_band)] = 1;
        macropore[@intFromEnum(mineral_nitrogen.Species.ammonia_band)] = 2;
        matrix[@intFromEnum(mineral_nitrogen.Species.nitrate_non_band)] = 3;
        macropore[@intFromEnum(mineral_nitrogen.Species.nitrite_band)] = 4;
        chemistry.cation_exchange_mol_per_megagram[profile_cell]
            .ammonium_non_band = 0.5;
        fertilizer.soil[profile_cell].broadcast_ammonium_mol_n = 5;
        fertilizer.soil[profile_cell].banded_urea_mol_n = 6;
        fertilizer.soil[profile_cell].broadcast_nitrate_mol_n = 7;
    }
    // Inactive allocated capacity must never enter an authoritative total.
    (try transport.matrix.cellAmounts(1))[0] = 1_000_000;
    chemistry.cation_exchange_mol_per_megagram[3].ammonium_band = 1_000_000;
    fertilizer.soil[1].broadcast_ammonium_mol_n = 1_000_000;

    const fractions = @import("../soil/solute/charge_classification.zig").ZoneFractions{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.8,
        .phosphate_band = 0.2,
    };
    const inventory = try landscape_mass_inventory.aggregateProfileMineralNitrogen(
        &grid,
        &transport,
        &chemistry,
        &fertilizer,
        &.{ 2, 2, 2, 2 },
        fractions,
        14,
    );
    try expectStoragePartition(inventory, &.{
        try landscape_mass_inventory.aggregateProfileMineralNitrogenCell(&grid, &transport, &chemistry, &fertilizer, &.{ 2, 2, 2, 2 }, fractions, 14, 0),
        try landscape_mass_inventory.aggregateProfileMineralNitrogenCell(&grid, &transport, &chemistry, &fertilizer, &.{ 2, 2, 2, 2 }, fractions, 14, 1),
    });
    // Per active cell: NHx=(1+2)+(0.75*0.5*2)+(5+6)=14.75 mol N.
    // NOx=(3+4)+7=14 mol N.
    try std.testing.expectEqual(@as(f64, 2 * 14.75 * 14), inventory.ammonium_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 2 * 14 * 14), inventory.nitrate_nitrogen_g);
    // Per cell: exchange NH4 2*(0.75*0.5*2) + dry NH4 2*5 + urea 6 + nitrate 7.
    try std.testing.expectEqual(@as(f64, 2 * 24.5), inventory.ion_inventory_mol);
}

test "REDIST profile phosphorus and ions include matrix macropore and immobile owners" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{
            .lon_count = 2,
            .lat_count = 1,
            .soil_layers = 2,
            .plant_populations = 1,
        },
        .{ .worker_threads = 2, .tile_cells = 2 },
        .{
            .relative_tolerance = 1e-8,
            .absolute_tolerance = 1e-11,
            .max_nonlinear_iterations = 20,
        },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.active_soil_layer_count[1] = 1;

    var micropore = try solute_transport.State.init(
        std.testing.allocator,
        grid.layer_count,
        solute_species.AqueousSpecies.count,
    );
    defer micropore.deinit();
    var macropore = try solute_transport.State.init(
        std.testing.allocator,
        grid.layer_count,
        solute_species.AqueousSpecies.count,
    );
    defer macropore.deinit();
    var chemistry = try soil_chemistry.State.init(
        std.testing.allocator,
        grid.layer_count,
    );
    defer chemistry.deinit();
    var pending = try mineral_fertilizer.State.init(
        std.testing.allocator,
        grid.cell_count,
        grid.soil_layer_capacity,
    );
    defer pending.deinit();

    for ([_]usize{ 0, 2 }) |profile_cell| {
        const matrix = try micropore.cellAmounts(profile_cell);
        const macro = try macropore.cellAmounts(profile_cell);
        matrix[solute_species.index(.aluminum)] = 1;
        matrix[solute_species.index(.bicarbonate)] = 2;
        matrix[solute_species.index(.aluminum_hydroxide_2)] = 3;
        matrix[solute_species.index(.aluminum_hydroxide_3)] = 4;
        matrix[solute_species.index(.aluminum_hydroxide_4)] = 5;
        matrix[solute_species.index(.non_band_phosphate)] = 6;
        matrix[solute_species.index(.band_iron_hpo4)] = 7;
        macro[solute_species.index(.band_phosphoric_acid)] = 8;

        const non_band = &chemistry.non_band_phosphate[profile_cell];
        non_band.dissolved_hpo4_mol_p_per_m3 = 1;
        non_band.adsorbed_hpo4_mol_p_per_megagram = 2;
        non_band.deprotonated_site_mol_per_megagram = 1;
        non_band.monocalcium_phosphate_solid_mol_per_m3 = 1;
        const band = &chemistry.band_phosphate[profile_cell];
        band.dissolved_h2po4_mol_p_per_m3 = 2;
        band.adsorbed_h2po4_mol_p_per_megagram = 1;
        band.hydroxyl_site_mol_per_megagram = 1;
        band.hydroxyapatite_solid_mol_per_m3 = 2;

        chemistry.cation_exchange_mol_per_megagram[profile_cell].hydrogen = 1;
        chemistry.cation_exchange_mol_per_megagram[profile_cell].calcium = 2;
        chemistry.carboxyl_bound_hydrogen_mol_per_megagram[profile_cell] = 0.5;
        chemistry.geochemistry_solids[profile_cell]
            .calcite_solid_mol_per_m3 = 1;
        chemistry.geochemistry_solids[profile_cell]
            .gibbsite_solid_mol_per_m3 = 2;
        chemistry.geochemistry_solids[profile_cell]
            .aluminum_natural_silicate_mol_per_m3 = 3;

        pending.soil[profile_cell].broadcast_monocalcium_phosphate_mol = 1;
        pending.soil[profile_cell].hydroxyapatite_mol = 2;
        pending.soil[profile_cell].calcite_mol = 3;
        pending.soil[profile_cell].aluminum_ground_silicate_mol = 4;
    }
    // Capacity layers 1 and 3 are not part of the runtime profile.
    (try micropore.cellAmounts(1))[solute_species.index(.band_phosphate)] =
        1_000_000;
    chemistry.non_band_phosphate[3]
        .hydroxyapatite_solid_mol_per_m3 = 1_000_000;
    pending.soil[1].hydroxyapatite_mol = 1_000_000;

    const fractions: zone_classification.ZoneFractions = .{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.75,
        .nitrate_band = 0.25,
        .phosphate_non_band = 0.75,
        .phosphate_band = 0.25,
    };
    const inventory = try landscape_mass_inventory.aggregateProfilePhosphorusAndIons(
        &grid,
        &micropore,
        &macropore,
        &chemistry,
        &pending,
        &.{ 3, 3, 3, 3 },
        &.{ 2, 2, 2, 2 },
        fractions,
        12,
        31,
    );
    try expectStoragePartition(inventory, &.{
        try landscape_mass_inventory.aggregateProfilePhosphorusAndIonsCell(&grid, &micropore, &macropore, &chemistry, &pending, &.{ 3, 3, 3, 3 }, &.{ 2, 2, 2, 2 }, fractions, 12, 31, 0),
        try landscape_mass_inventory.aggregateProfilePhosphorusAndIonsCell(&grid, &micropore, &macropore, &chemistry, &pending, &.{ 3, 3, 3, 3 }, &.{ 2, 2, 2, 2 }, fractions, 12, 31, 1),
    });
    // Per cell: 21 mol transported phosphate + 12.5 mol adsorbed/solid
    // chemistry phosphate + 8 mol pending fertilizer phosphate. The
    // chemistry owner's bare dissolved HPO4/H2PO4 coordinates are excluded:
    // their extensive amounts are already present in the transport carrier.
    try std.testing.expectEqual(
        @as(f64, 2 * 41.5 * 31),
        inventory.phosphate_phosphorus_g,
    );
    // The same ownership rule removes 9 legacy ion-atoms per cell that the
    // old expectation double-counted from those bare dissolved coordinates.
    // REDIST profile SSX also counts the exchange site in XH1P/XH2P, adding
    // 3.5 pseudo-ions per cell for this fixture.
    try std.testing.expectEqual(
        @as(f64, 2 * 237.75),
        inventory.ion_inventory_mol,
    );
    try std.testing.expectEqual(
        @as(f64, 2 * 96),
        inventory.carbon_dioxide_carbon_g,
    );
}

test "REDIST dry surface mineral fertilizer remains in landscape storage" {
    var state = try mineral_fertilizer.State.init(
        std.testing.allocator,
        2,
        3,
    );
    defer state.deinit();
    state.surface[0].broadcast_monocalcium_phosphate_mol = 2;
    state.surface[0].banded_monocalcium_phosphate_mol = 3;
    state.surface[0].hydroxyapatite_mol = 4;
    state.surface[0].calcite_mol = 5;
    state.surface[0].gypsum_mol = 6;
    state.surface[0].aluminum_ground_silicate_mol = 7;
    state.surface[1].potassium_ground_silicate_mol = 8;

    const inventory = try landscape_mass_inventory.aggregatePendingSurfaceMinerals(&state, 12, 31);
    try expectStoragePartition(inventory, &.{
        try landscape_mass_inventory.aggregatePendingSurfaceMineralsCell(&state, 12, 31, 0),
        try landscape_mass_inventory.aggregatePendingSurfaceMineralsCell(&state, 12, 31, 1),
    });
    try std.testing.expectEqual(
        @as(f64, (2 * (2 + 3) + 3 * 4) * 31),
        inventory.phosphate_phosphorus_g,
    );
    try std.testing.expectEqual(
        @as(f64, 5 * 12),
        inventory.carbon_dioxide_carbon_g,
    );
    try std.testing.expectEqual(
        @as(f64, 7 * (2 + 3) + 9 * 4 + 2 * (5 + 6) + 7 + 8),
        inventory.ion_inventory_mol,
    );
    try std.testing.expectEqual(@as(f64, 7), inventory.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 8), inventory.potassium_mol);
    try std.testing.expectEqual(@as(f64, 36), inventory.calcium_mol);
    try std.testing.expectEqual(@as(f64, 6), inventory.sulfur_mol);
    try std.testing.expectEqual(@as(f64, 7.25), inventory.silicon_mol);
}

test "per-cell organic macropore inventory partitions the global census" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 2, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 2 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.active_soil_layer_count[1] = 1;
    var transport = try organic_transport.State.init(std.testing.allocator, grid.layer_count);
    defer transport.deinit();
    transport.macropore_amount_g[@intFromEnum(organic_transport.Component.dissolved_organic_carbon)] = 2;
    const second_cell_base = grid.soil_layer_capacity * organic_transport.component_count;
    transport.macropore_amount_g[second_cell_base + @intFromEnum(organic_transport.Component.dissolved_organic_nitrogen)] = 3;

    const whole = try landscape_mass_inventory.aggregateSoilOrganicTransportMacropore(&transport, &grid);
    try expectStoragePartition(whole, &.{
        try landscape_mass_inventory.aggregateSoilOrganicTransportMacroporeCell(&transport, &grid, 0),
        try landscape_mass_inventory.aggregateSoilOrganicTransportMacroporeCell(&transport, &grid, 1),
    });
}

test "SOIL-CHEM-DRY-CARRIER-001 census uses remembered water for a vanished layer carrier" {
    const config = try @import("../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    var micropore = try solute_transport.State.init(std.testing.allocator, grid.layer_count, solute_species.AqueousSpecies.count);
    defer micropore.deinit();
    var macropore = try solute_transport.State.init(std.testing.allocator, grid.layer_count, solute_species.AqueousSpecies.count);
    defer macropore.deinit();
    var chemistry = try soil_chemistry.State.init(std.testing.allocator, grid.layer_count);
    defer chemistry.deinit();
    var pending = try mineral_fertilizer.State.init(std.testing.allocator, grid.cell_count, grid.soil_layer_capacity);
    defer pending.deinit();
    chemistry.geochemistry_solids[0].calcite_solid_mol_per_m3 = 2;
    chemistry.geochemistry_solids[0].gibbsite_solid_mol_per_m3 = 3;
    const fractions: zone_classification.ZoneFractions = .{
        .ammonium_non_band = 1,
        .ammonium_band = 0,
        .nitrate_non_band = 1,
        .nitrate_band = 0,
        .phosphate_non_band = 1,
        .phosphate_band = 0,
    };
    const wet = try landscape_mass_inventory.aggregateProfilePhosphorusAndIons(
        &grid,
        &micropore,
        &macropore,
        &chemistry,
        &pending,
        &.{4},
        &.{1},
        fractions,
        12,
        31,
    );
    chemistry.dry_reference_water_m3[0] = 4;
    const dry = try landscape_mass_inventory.aggregateProfilePhosphorusAndIons(
        &grid,
        &micropore,
        &macropore,
        &chemistry,
        &pending,
        &.{0},
        &.{1},
        fractions,
        12,
        31,
    );
    try std.testing.expectEqual(wet.carbon_dioxide_carbon_g, dry.carbon_dioxide_carbon_g);
    try std.testing.expectEqual(wet.aluminum_mol, dry.aluminum_mol);
    try std.testing.expectEqual(@as(f64, 8 * 12), dry.carbon_dioxide_carbon_g);
}

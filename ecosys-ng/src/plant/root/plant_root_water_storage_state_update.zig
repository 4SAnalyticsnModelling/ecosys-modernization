const std = @import("std");
const GridState = @import("../../state/grid.zig").GridState;
const root_system = @import("plant_root_system.zig");
const RootState = root_system.State;
const chemistry_rebase = @import("../../soil/chemistry/water_carrier_rebase.zig");
const ChemistryState = @import("../../soil/solute/chemistry_state.zig").State;
const soil_water_solver = @import("../../soil/water/solver.zig");
const SoilThermalState = @import("../../soil/heat/thermal.zig").State;

/// StateUpdates accepted UPTAKE root-water fluxes to soil matrix storage. Root
/// fluxes use the source convention: negative removes water from soil and
/// positive returns water to soil.
pub fn state_update(
    roots: *const RootState,
    grid: *GridState,
    chemistry: *ChemistryState,
    thermal: *SoilThermalState,
    biological_domain_count_by_plant: []const u8,
    chemistry_rebase_inventory_fractions: []const chemistry_rebase.InventoryFractions,
    cell_area_m2: []const f64,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    ice_density_megagrams_per_m3: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    accepted_water_change_m3: []f64,
    convective_water_heat_megajoules: []f64,
    chemistry_rebase_roundoff: []chemistry_rebase.RoundoffAllowance,
    root_water_storage_roundoff_m3: []f64,
    root_heat_storage_roundoff_megajoules: []f64,
) !void {
    if (grid.cell_count == 0 or roots.plant_count % grid.cell_count != 0 or
        roots.soil_layer_count != grid.soil_layer_capacity or
        biological_domain_count_by_plant.len != roots.plant_count or
        chemistry.cell_count != grid.layer_count or
        thermal.cell_count != grid.cell_count or
        thermal.soil_layer_capacity != grid.soil_layer_capacity or
        thermal.layer_volume_m3.len != grid.layer_count or
        thermal.total_heat_capacity_megajoules_per_m3_k.len != grid.layer_count or
        accepted_water_change_m3.len != grid.layer_count or
        convective_water_heat_megajoules.len != grid.layer_count or
        chemistry_rebase_inventory_fractions.len != grid.layer_count or
        chemistry_rebase_roundoff.len != grid.layer_count or
        root_water_storage_roundoff_m3.len != grid.layer_count or
        root_heat_storage_roundoff_megajoules.len != grid.layer_count or
        cell_area_m2.len != grid.cell_count)
        return error.PlantRootWaterStorageDimensionMismatch;
    if (!std.math.isFinite(ice_density_megagrams_per_m3) or
        ice_density_megagrams_per_m3 <= 0)
        return error.InvalidPlantRootWaterIceDensity;
    if (!std.math.isFinite(liquid_water_heat_capacity_megajoules_per_m3_k) or
        liquid_water_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidPlantRootWaterHeatCapacity;
    const species_count = roots.plant_count / grid.cell_count;

    // Validate every accepted layer transaction before changing storage.
    for (0..grid.cell_count) |cell| for (0..grid.active_soil_layer_count[cell]) |layer| {
        const soil = try grid.layerIndex(cell, layer);
        const change_m3 = try layerWaterChange(
            roots,
            biological_domain_count_by_plant,
            species_count,
            cell,
            layer,
        );
        const next = grid.matrix_liquid_water_m3[soil] + change_m3;
        if (!std.math.isFinite(next) or next < 0)
            return error.PlantRootWaterUptakeExceedsSoilStorage;
        _ = try additionRoundoffAllowanceM3(
            grid.matrix_liquid_water_m3[soil],
            change_m3,
        );
        _ = soil_water_solver.derivedPhysicalAirVolumeM3(
            grid.matrix_pore_capacity_m3[soil],
            next,
            grid.matrix_ice_water_m3[soil],
            ice_density_megagrams_per_m3,
        ) catch return error.PlantRootWaterReleaseExceedsSoilStorage;
        _ = try chemistry_rebase.previewLayerRoundoff(
            chemistry,
            soil,
            grid.matrix_liquid_water_m3[soil],
            next,
            chemistry_rebase_inventory_fractions[soil],
            carbon_g_per_mol,
            phosphorus_g_per_mol,
            chemistry_rebase.legacyNegligibleWaterVolumeM3(cell_area_m2[cell]),
        );
        const layer_volume_m3 = thermal.layer_volume_m3[soil];
        const old_heat_capacity_megajoules_per_k =
            thermal.total_heat_capacity_megajoules_per_m3_k[soil] * layer_volume_m3;
        const capacity_change_megajoules_per_k =
            change_m3 * liquid_water_heat_capacity_megajoules_per_m3_k;
        const next_heat_capacity_megajoules_per_k =
            old_heat_capacity_megajoules_per_k + capacity_change_megajoules_per_k;
        const convective_heat_megajoules = capacity_change_megajoules_per_k *
            grid.soil_temperature_k[soil];
        inline for (.{
            layer_volume_m3,
            thermal.total_heat_capacity_megajoules_per_m3_k[soil],
            old_heat_capacity_megajoules_per_k,
            next_heat_capacity_megajoules_per_k,
            grid.soil_temperature_k[soil],
            convective_heat_megajoules,
        }) |value| if (!std.math.isFinite(value))
            return error.InvalidPlantRootWaterEnergyState;
        if (layer_volume_m3 <= 0 or
            thermal.total_heat_capacity_megajoules_per_m3_k[soil] <= 0 or
            next_heat_capacity_megajoules_per_k <= 0 or
            grid.soil_temperature_k[soil] <= 0)
            return error.InvalidPlantRootWaterEnergyState;
        const old_enthalpy_megajoules = old_heat_capacity_megajoules_per_k *
            grid.soil_temperature_k[soil];
        const next_enthalpy_megajoules = next_heat_capacity_megajoules_per_k *
            grid.soil_temperature_k[soil];
        const water_roundoff_m3 = try additionRoundoffAllowanceM3(
            grid.matrix_liquid_water_m3[soil],
            change_m3,
        );
        const representation_tolerance = try heatStorageRoundoffAllowanceMegajoules(
            old_enthalpy_megajoules,
            next_enthalpy_megajoules,
            convective_heat_megajoules,
            water_roundoff_m3,
            liquid_water_heat_capacity_megajoules_per_m3_k,
            grid.soil_temperature_k[soil],
        );
        if (@abs(next_enthalpy_megajoules - old_enthalpy_megajoules - convective_heat_megajoules) >
            representation_tolerance)
            return error.PlantRootWaterEnergyConservationFailure;
    };

    // Publish the producer-owned layer partition only after every water,
    // chemistry, pore-capacity, and enthalpy candidate has preflighted.
    @memset(accepted_water_change_m3, 0);
    @memset(convective_water_heat_megajoules, 0);
    @memset(chemistry_rebase_roundoff, .{});
    @memset(root_water_storage_roundoff_m3, 0);
    @memset(root_heat_storage_roundoff_megajoules, 0);
    for (0..grid.cell_count) |cell| for (0..grid.active_soil_layer_count[cell]) |layer| {
        const soil = try grid.layerIndex(cell, layer);
        const old_water_m3 = grid.matrix_liquid_water_m3[soil];
        const change_m3 = try layerWaterChange(
            roots,
            biological_domain_count_by_plant,
            species_count,
            cell,
            layer,
        );
        const new_water_m3 = old_water_m3 + change_m3;
        root_water_storage_roundoff_m3[soil] = additionRoundoffAllowanceM3(
            old_water_m3,
            change_m3,
        ) catch unreachable;
        accepted_water_change_m3[soil] = change_m3;
        chemistry_rebase_roundoff[soil] = chemistry_rebase.rebaseLayerWithRoundoff(
            chemistry,
            soil,
            old_water_m3,
            new_water_m3,
            chemistry_rebase_inventory_fractions[soil],
            carbon_g_per_mol,
            phosphorus_g_per_mol,
            chemistry_rebase.legacyNegligibleWaterVolumeM3(cell_area_m2[cell]),
        ) catch unreachable;
        const layer_volume_m3 = thermal.layer_volume_m3[soil];
        const capacity_change_megajoules_per_k =
            change_m3 * liquid_water_heat_capacity_megajoules_per_m3_k;
        const old_heat_capacity_megajoules_per_k =
            thermal.total_heat_capacity_megajoules_per_m3_k[soil] * layer_volume_m3;
        const next_heat_capacity_megajoules_per_k =
            old_heat_capacity_megajoules_per_k + capacity_change_megajoules_per_k;
        const old_enthalpy_megajoules = old_heat_capacity_megajoules_per_k *
            grid.soil_temperature_k[soil];
        const next_enthalpy_megajoules = next_heat_capacity_megajoules_per_k *
            grid.soil_temperature_k[soil];
        const convective_heat_megajoules = capacity_change_megajoules_per_k *
            grid.soil_temperature_k[soil];
        root_heat_storage_roundoff_megajoules[soil] =
            heatStorageRoundoffAllowanceMegajoules(
                old_enthalpy_megajoules,
                next_enthalpy_megajoules,
                convective_heat_megajoules,
                root_water_storage_roundoff_m3[soil],
                liquid_water_heat_capacity_megajoules_per_m3_k,
                grid.soil_temperature_k[soil],
            ) catch unreachable;
        thermal.total_heat_capacity_megajoules_per_m3_k[soil] =
            next_heat_capacity_megajoules_per_k / layer_volume_m3;
        convective_water_heat_megajoules[soil] = convective_heat_megajoules;
        grid.matrix_liquid_water_m3[soil] = new_water_m3;
        grid.liquid_water_m3[soil] = new_water_m3 + grid.macropore_liquid_water_m3[soil];
        grid.matrix_air_volume_m3[soil] = soil_water_solver.derivedPhysicalAirVolumeM3(
            grid.matrix_pore_capacity_m3[soil],
            new_water_m3,
            grid.matrix_ice_water_m3[soil],
            ice_density_megagrams_per_m3,
        ) catch unreachable;
        grid.air_volume_m3[soil] = grid.matrix_air_volume_m3[soil] +
            grid.macropore_air_volume_m3[soil];
    };
}

/// Forward-error certificate for the eight rounded operations in the local
/// `C*T` update plus propagation of the independently certified water-storage
/// addition through `C_liquid*T`. It is computed before mutation and never
/// observes the closure residual when choosing its scale.
fn heatStorageRoundoffAllowanceMegajoules(
    old_enthalpy_megajoules: f64,
    next_enthalpy_megajoules: f64,
    convective_heat_megajoules: f64,
    water_roundoff_m3: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    temperature_k: f64,
) !f64 {
    inline for (.{ old_enthalpy_megajoules, next_enthalpy_megajoules, convective_heat_megajoules, water_roundoff_m3, liquid_water_heat_capacity_megajoules_per_m3_k, temperature_k }) |value|
        if (!std.math.isFinite(value)) return error.InvalidPlantRootWaterEnergyState;
    if (water_roundoff_m3 < 0 or liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or temperature_k <= 0)
        return error.InvalidPlantRootWaterEnergyState;
    const scaled_epsilon = 8.0 * std.math.floatEps(f64);
    const identity_magnitude = @abs(old_enthalpy_megajoules) +
        @abs(next_enthalpy_megajoules) + @abs(convective_heat_megajoules);
    var identity_bound = scaled_epsilon / (1 - scaled_epsilon) * identity_magnitude;
    var carrier_bound = water_roundoff_m3 *
        @abs(liquid_water_heat_capacity_megajoules_per_m3_k * temperature_k);
    if (!std.math.isFinite(identity_bound) or !std.math.isFinite(carrier_bound))
        return error.InvalidPlantRootWaterEnergyState;
    if (identity_bound > 0)
        identity_bound = std.math.nextAfter(f64, identity_bound, std.math.inf(f64));
    if (carrier_bound > 0)
        carrier_bound = std.math.nextAfter(f64, carrier_bound, std.math.inf(f64));
    const total = identity_bound + carrier_bound;
    if (!std.math.isFinite(total)) return error.InvalidPlantRootWaterEnergyState;
    return if (total == 0) 0 else std.math.nextAfter(f64, total, std.math.inf(f64));
}

fn additionRoundoffAllowanceM3(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or !std.math.isFinite(right))
        return error.InvalidPlantRootWaterArithmeticProvenance;
    if (left == 0 or right == 0) return 0;
    const unit_roundoff = std.math.floatEps(f64) / 2;
    const gamma_one = std.math.nextAfter(
        f64,
        unit_roundoff / (1 - unit_roundoff),
        std.math.inf(f64),
    );
    var magnitude = @abs(left) + @abs(right);
    if (!std.math.isFinite(magnitude))
        return error.InvalidPlantRootWaterArithmeticProvenance;
    magnitude = std.math.nextAfter(f64, magnitude, std.math.inf(f64));
    var allowance = gamma_one * magnitude;
    if (!std.math.isFinite(allowance))
        return error.InvalidPlantRootWaterArithmeticProvenance;
    allowance = std.math.nextAfter(f64, allowance, std.math.inf(f64));
    allowance += std.math.floatTrueMin(f64);
    if (!std.math.isFinite(allowance))
        return error.InvalidPlantRootWaterArithmeticProvenance;
    return std.math.nextAfter(f64, allowance, std.math.inf(f64));
}

fn layerWaterChange(
    roots: *const RootState,
    domain_count_by_plant: []const u8,
    species_count: usize,
    cell: usize,
    layer: usize,
) !f64 {
    var change_m3: f64 = 0;
    for (0..species_count) |species| {
        const plant = cell * species_count + species;
        const domain_count = domain_count_by_plant[plant];
        if (domain_count == 0 or domain_count > root_system.biological_domain_count)
            return error.InvalidPlantRootBiologicalDomainCount;
        for (0..domain_count) |domain| {
            const root = try roots.layerIndex(plant, domain, layer);
            const flux = roots.water_uptake_m3_per_h[root];
            if (!std.math.isFinite(flux)) return error.NonFinitePlantRootWaterFlux;
            change_m3 += flux;
        }
    }
    if (!std.math.isFinite(change_m3)) return error.NonFinitePlantRootWaterFlux;
    return change_m3;
}

test "root uptake removes soil water and preserves dissolved moles" {
    const config = @import("../../core/config.zig");
    const cfg = try config.SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 },
    );
    var grid = try GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    var roots = try RootState.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    var chemistry = try ChemistryState.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    var thermal_values: [2]f64 = @splat(0);
    var thermal_volume = [_]f64{ 20, 20 };
    var thermal_capacity = [_]f64{ 5, 5 };
    var thermal: SoilThermalState = .{
        .allocator = std.testing.allocator,
        .cell_count = 1,
        .soil_layer_capacity = 2,
        .layer_volume_m3 = &thermal_volume,
        .layer_thickness_m = &thermal_values,
        .porosity_fraction = &thermal_values,
        .dry_solid_heat_capacity_megajoules_per_m3_k = &thermal_values,
        .solid_thermal_conductivity_numerator_m_megajoules_per_h_k = &thermal_values,
        .solid_thermal_conductivity_denominator = &thermal_values,
        .total_heat_capacity_megajoules_per_m3_k = &thermal_capacity,
        .thermal_conductivity_m_megajoules_per_h_k = &thermal_values,
    };
    var root_water_change = [_]f64{ 8, 8 };
    var root_heat = [_]f64{ 9, 9 };
    var chemistry_roundoff: [2]chemistry_rebase.RoundoffAllowance = @splat(.{});
    var water_roundoff = [_]f64{ 6, 6 };
    var heat_roundoff = [_]f64{ 7, 7 };
    const chemistry_inventory_fractions = [_]chemistry_rebase.InventoryFractions{
        .{ .phosphate_non_band = 0.8, .phosphate_band = 0.2 },
        .{ .phosphate_non_band = 0.6, .phosphate_band = 0.4 },
    };
    grid.matrix_liquid_water_m3[0] = 10;
    grid.matrix_liquid_water_m3[1] = 8;
    grid.matrix_pore_capacity_m3[0] = 20;
    grid.matrix_pore_capacity_m3[1] = 20;
    grid.soil_temperature_k[0] = 280;
    grid.soil_temperature_k[1] = 285;
    chemistry.aqueous[0].nitrate_non_band = 2;
    roots.water_uptake_m3_per_h[try roots.layerIndex(0, 0, 0)] = -3;
    roots.water_uptake_m3_per_h[try roots.layerIndex(0, 0, 1)] = -1;
    const old_domain_water_m3 = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1];
    const old_enthalpy_0 = thermal_capacity[0] * thermal_volume[0] * grid.soil_temperature_k[0];
    const old_domain_enthalpy = old_enthalpy_0 +
        thermal_capacity[1] * thermal_volume[1] * grid.soil_temperature_k[1];
    try state_update(&roots, &grid, &chemistry, &thermal, &.{1}, &chemistry_inventory_fractions, &.{1}, 12, 31, 0.917, 4.19, &root_water_change, &root_heat, &chemistry_roundoff, &water_roundoff, &heat_roundoff);
    try std.testing.expectEqual(@as(f64, 7), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 7), grid.matrix_liquid_water_m3[1]);
    const new_domain_water_m3 = grid.matrix_liquid_water_m3[0] + grid.matrix_liquid_water_m3[1];
    try std.testing.expectEqual(@as(f64, -4), new_domain_water_m3 - old_domain_water_m3);
    try std.testing.expectEqualSlices(f64, &.{ -3, -1 }, &root_water_change);
    try std.testing.expect(water_roundoff[0] > 0 and water_roundoff[1] > 0);
    try std.testing.expect(heat_roundoff[0] > 0 and heat_roundoff[1] > 0);
    try std.testing.expectEqual(
        roots.water_uptake_m3_per_h[try roots.layerIndex(0, 0, 0)] +
            roots.water_uptake_m3_per_h[try roots.layerIndex(0, 0, 1)],
        new_domain_water_m3 - old_domain_water_m3,
    );
    try std.testing.expectEqual(@as(f64, 7), grid.liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 13), grid.matrix_air_volume_m3[0]);
    try std.testing.expectApproxEqAbs(20.0 / 7.0, chemistry.aqueous[0].nitrate_non_band, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, -3 * 4.19 * 280), root_heat[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1 * 4.19 * 285), root_heat[1], 1e-12);
    const new_enthalpy_0 = thermal_capacity[0] * thermal_volume[0] * grid.soil_temperature_k[0];
    try std.testing.expectApproxEqAbs(root_heat[0], new_enthalpy_0 - old_enthalpy_0, 1e-10);
    const new_domain_enthalpy = new_enthalpy_0 +
        thermal_capacity[1] * thermal_volume[1] * grid.soil_temperature_k[1];
    try std.testing.expectApproxEqAbs(
        root_heat[0] + root_heat[1],
        new_domain_enthalpy - old_domain_enthalpy,
        1e-10,
    );

    // An uptake that would overdraw any layer rejects the entire transaction;
    // a valid earlier layer must not retain a partial water/chemistry update.
    roots.water_uptake_m3_per_h[try roots.layerIndex(0, 0, 0)] = -1;
    roots.water_uptake_m3_per_h[try roots.layerIndex(0, 0, 1)] = -20;
    const water_before = grid.matrix_liquid_water_m3[0..2].*;
    const concentration_before = chemistry.aqueous[0].nitrate_non_band;
    const thermal_before = thermal_capacity;
    const water_change_before = root_water_change;
    const heat_before = root_heat;
    const roundoff_before = chemistry_roundoff;
    const water_roundoff_before = water_roundoff;
    const heat_roundoff_before = heat_roundoff;
    try std.testing.expectError(
        error.PlantRootWaterUptakeExceedsSoilStorage,
        state_update(&roots, &grid, &chemistry, &thermal, &.{1}, &chemistry_inventory_fractions, &.{1}, 12, 31, 0.917, 4.19, &root_water_change, &root_heat, &chemistry_roundoff, &water_roundoff, &heat_roundoff),
    );
    try std.testing.expectEqualDeep(water_before, grid.matrix_liquid_water_m3[0..2].*);
    try std.testing.expectEqual(concentration_before, chemistry.aqueous[0].nitrate_non_band);
    try std.testing.expectEqualDeep(thermal_before, thermal_capacity);
    try std.testing.expectEqualDeep(water_change_before, root_water_change);
    try std.testing.expectEqualDeep(heat_before, root_heat);
    try std.testing.expectEqualDeep(roundoff_before, chemistry_roundoff);
    try std.testing.expectEqualDeep(water_roundoff_before, water_roundoff);
    try std.testing.expectEqualDeep(heat_roundoff_before, heat_roundoff);
}

test "root water addition roundoff certificate covers an adversarial tie" {
    const allowance = try additionRoundoffAllowanceM3(1, std.math.floatEps(f64) / 2);
    try std.testing.expect(allowance >= std.math.floatEps(f64) / 2);
    try std.testing.expect(std.math.isFinite(allowance));
    try std.testing.expectEqual(@as(f64, 0), try additionRoundoffAllowanceM3(1, 0));
}

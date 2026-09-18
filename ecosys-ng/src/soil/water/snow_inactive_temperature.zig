//! Source-compatible temperature ownership for sub-threshold snow layers.
//!
//! WATSUB assigns ground-air temperature to layer one and the preceding snow
//! temperature to deeper layers whenever `VHCPWM2 <= VHCPWX`. Such a layer can
//! still contain canonical water and chemistry, especially while the ground is
//! too cold for warm-thin-pack disappearance. Therefore the assignment is not
//! a zero-storage metadata operation. This owner publishes its exact signed
//! sensible-energy change so conservation cannot hide the source reset.

const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");

pub fn apply(
    allocator: std.mem.Allocator,
    state: *snow.State,
    ground_surface_temperature_k_by_cell: []const f64,
    accepted_reference_heat_megajoules_by_layer: []f64,
) !void {
    const layer_count = try std.math.mul(
        usize,
        state.cell_count,
        state.layer_capacity,
    );
    if (ground_surface_temperature_k_by_cell.len != state.cell_count or
        accepted_reference_heat_megajoules_by_layer.len != layer_count or
        state.temperature_k.len != layer_count or
        state.heat_capacity_megajoules_per_k.len != layer_count or
        state.horizontal_area_m2.len != layer_count or
        state.active.len != layer_count)
        return error.SnowInactiveTemperatureDimensionMismatch;

    const candidate_temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(candidate_temperature);
    const candidate_heat = try allocator.alloc(f64, layer_count);
    defer allocator.free(candidate_heat);
    @memset(candidate_heat, 0);

    for (0..state.cell_count) |cell| {
        const ground_temperature_k = ground_surface_temperature_k_by_cell[cell];
        if (!std.math.isFinite(ground_temperature_k) or ground_temperature_k <= 0)
            return error.InvalidSnowInactiveReferenceTemperature;
        const base = cell * state.layer_capacity;
        for (0..state.layer_capacity) |local_layer| {
            const layer = base + local_layer;
            const capacity = state.heat_capacity_megajoules_per_k[layer];
            const area = state.horizontal_area_m2[layer];
            const old_temperature_k = state.temperature_k[layer];
            inline for (.{ capacity, area, old_temperature_k }) |value|
                if (!std.math.isFinite(value))
                    return error.InvalidSnowInactiveTemperatureState;
            if (capacity < 0 or area <= 0 or old_temperature_k <= 0)
                return error.InvalidSnowInactiveTemperatureState;
            if (!state.active[layer] and capacity != 0)
                return error.InactiveSnowLayerHasHeatStorage;

            const threshold = snow.activation_heat_capacity_megajoules_per_m2_k * area;
            if (!std.math.isFinite(threshold))
                return error.InvalidSnowInactiveTemperatureState;
            if (capacity > threshold) continue;

            const reference_temperature_k = if (local_layer == 0)
                ground_temperature_k
            else
                candidate_temperature[layer - 1];
            const signed_heat = capacity *
                (reference_temperature_k - old_temperature_k);
            if (!std.math.isFinite(reference_temperature_k) or
                reference_temperature_k <= 0 or !std.math.isFinite(signed_heat))
                return error.InvalidSnowInactiveTemperatureCandidate;
            candidate_temperature[layer] = reference_temperature_k;
            candidate_heat[layer] = signed_heat;
        }
    }

    // Atomic publication: every source and every output was preflighted.
    @memcpy(state.temperature_k, candidate_temperature);
    @memcpy(accepted_reference_heat_megajoules_by_layer, candidate_heat);
}

test "sub-threshold temperature reset preserves all mass and publishes exact heat" {
    var state = try snow.State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    try state.initializePhysicalState(
        &.{0.0005},
        &.{1},
        &.{260},
        &.{ 0.001, 0.002, 0.003 },
        0.1,
        snow.test_thermodynamics,
    );
    state.temperature_k[0] = 260;
    state.temperature_k[1] = 250;
    state.temperature_k[2] = 240;
    // Layers zero and one remain canonical but below VHCPWX. Layer two is an
    // ordinary active layer and must retain its prognostic temperature.
    state.solid_snow_water_equivalent_m3[0] = 0.0001;
    state.solid_snow_water_equivalent_m3[1] = 0.0002;
    state.solid_snow_water_equivalent_m3[2] = 0.001;
    for (0..3) |layer| {
        state.active[layer] = true;
        state.heat_capacity_megajoules_per_k[layer] =
            snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k *
            state.solid_snow_water_equivalent_m3[layer];
        state.amount_g[layer * snow.species_count] =
            @as(f64, @floatFromInt(layer + 1));
        state.salt_amount_mol[layer * snow.salt_species_count] =
            0.1 * @as(f64, @floatFromInt(layer + 1));
    }
    state.refreshAllGeometry();
    const solid_before = state.solid_snow_water_equivalent_m3[0..3].*;
    const amounts_before = state.amount_g[0 .. 3 * snow.species_count].*;
    const salts_before = state.salt_amount_mol[0 .. 3 * snow.salt_species_count].*;
    var energy_before: f64 = 0;
    for (state.heat_capacity_megajoules_per_k, state.temperature_k) |capacity, temperature|
        energy_before += capacity * temperature;

    var reference_heat = [_]f64{ 99, 99, 99 };
    try apply(std.testing.allocator, &state, &.{274}, &reference_heat);

    var energy_after: f64 = 0;
    for (state.heat_capacity_megajoules_per_k, state.temperature_k) |capacity, temperature|
        energy_after += capacity * temperature;
    var published_heat: f64 = 0;
    for (reference_heat) |value| published_heat += value;
    try std.testing.expectEqualSlices(f64, &solid_before, state.solid_snow_water_equivalent_m3);
    try std.testing.expectEqualSlices(f64, &amounts_before, state.amount_g);
    try std.testing.expectEqualSlices(f64, &salts_before, state.salt_amount_mol);
    try std.testing.expectEqual(@as(f64, 274), state.temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 274), state.temperature_k[1]);
    try std.testing.expectEqual(@as(f64, 240), state.temperature_k[2]);
    try std.testing.expectEqual(@as(f64, 0), reference_heat[2]);
    try std.testing.expectApproxEqAbs(
        energy_after - energy_before,
        published_heat,
        32 * std.math.floatEps(f64) * @max(1, @abs(energy_before)),
    );
}

test "invalid later cell leaves temperatures and sidecar unchanged" {
    var state = try snow.State.init(std.testing.allocator, 2, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{ 0.0001, 0.0001 }, &.{ 1, 1 }, &.{ 260, 261 }, &.{0.001}, 0.1, snow.test_thermodynamics);
    const before = state.temperature_k[0..2].*;
    var sidecar = [_]f64{ 7, 8 };
    try std.testing.expectError(
        error.InvalidSnowInactiveReferenceTemperature,
        apply(std.testing.allocator, &state, &.{ 274, std.math.nan(f64) }, &sidecar),
    );
    try std.testing.expectEqualSlices(f64, &before, state.temperature_k);
    try std.testing.expectEqualSlices(f64, &.{ 7, 8 }, &sidecar);
}

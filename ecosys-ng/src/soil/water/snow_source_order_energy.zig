const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");
const ice_units = @import("../../core/ice_units.zig");

/// Deep copy used by the fused WATSUB transaction. No accepted producer is
/// allowed to mutate the live snow state until the complete top-down schedule
/// and every late donor check have succeeded.
pub fn cloneState(allocator: std.mem.Allocator, source: *const snow.State) !snow.State {
    var result = try snow.State.init(allocator, source.cell_count, source.layer_capacity);
    errdefer result.deinit();
    try copyState(&result, source);
    return result;
}

pub fn copyState(destination: *snow.State, source: *const snow.State) !void {
    if (destination.cell_count != source.cell_count or
        destination.layer_capacity != source.layer_capacity)
        return error.SnowSourceOrderDimensionMismatch;
    @memcpy(destination.active, source.active);
    inline for (.{
        .{ destination.solid_snow_water_equivalent_m3, source.solid_snow_water_equivalent_m3 },
        .{ destination.liquid_water_volume_m3, source.liquid_water_volume_m3 },
        .{ destination.vapor_water_equivalent_m3, source.vapor_water_equivalent_m3 },
        .{ destination.ice_volume_m3, source.ice_volume_m3 },
        .{ destination.air_filled_volume_m3, source.air_filled_volume_m3 },
        .{ destination.total_layer_volume_m3, source.total_layer_volume_m3 },
        .{ destination.target_layer_volume_m3, source.target_layer_volume_m3 },
        .{ destination.layer_thickness_m, source.layer_thickness_m },
        .{ destination.cumulative_depth_m, source.cumulative_depth_m },
        .{ destination.snow_density_megagrams_per_m3, source.snow_density_megagrams_per_m3 },
        .{ destination.temperature_k, source.temperature_k },
        .{ destination.heat_capacity_megajoules_per_k, source.heat_capacity_megajoules_per_k },
        .{ destination.horizontal_area_m2, source.horizontal_area_m2 },
        .{ destination.amount_g, source.amount_g },
        .{ destination.salt_amount_mol, source.salt_amount_mol },
    }) |pair| @memcpy(pair[0], pair[1]);
    @memcpy(destination.dynamic_salts_by_cell, source.dynamic_salts_by_cell);
}

/// One accepted WATSUB layer turn. Face water and signed face heat were all
/// calculated from the same frozen layer-entry state. Positive signed face
/// quantities move from this layer to the lower layer; negative vapor/heat
/// moves upward. Bottom discharge is external and nonnegative. Local phase
/// deltas are applied before the one final capacity/temperature update.
pub const LayerStep = struct {
    cell: usize,
    local_layer: usize,
    /// True only when the next logical slot is an accepted active snow
    /// receiver. Snow columns may end before the runtime capacity; using the
    /// raw capacity here would turn a real lower-boundary discharge into an
    /// unowned transfer to an inactive slot.
    has_active_lower: bool = true,
    liquid_to_lower_m3: f64 = 0,
    vapor_to_lower_m3: f64 = 0,
    signed_face_heat_to_lower_megajoules: f64 = 0,
    discharge_water_m3: f64 = 0,
    discharge_heat_megajoules: f64 = 0,
    /// WATSUB 1793 `HFLWS1` plus 2031 `HFLWSRX`: continuous conduction from
    /// the lowest active layer into the surface litter and top soil layer.
    /// Signed, positive out of the snowpack, and carries no water, so it is
    /// kept separate from `discharge_heat_megajoules`. Only the bottom turn may
    /// hold it.
    base_conduction_heat_megajoules: f64 = 0,
    local_solid_change_m3: f64 = 0,
    local_liquid_change_m3: f64 = 0,
    local_vapor_change_m3: f64 = 0,
    local_ice_change_m3: f64 = 0,
    local_process_heat_megajoules: f64 = 0,
};

/// Applies a complete accepted snow schedule atomically. Destination mass and
/// pending energy are updated during an upper-layer turn, but destination C/T
/// remain frozen until that layer's own turn, exactly matching WATSUB
/// 1423--2446. Each active runtime layer must appear exactly once per cell in
/// ascending order; absent/inactive layers may still appear as zero turns.
pub fn apply(
    allocator: std.mem.Allocator,
    state: *snow.State,
    thermodynamics: snow.ThermodynamicParameters,
    steps: []const LayerStep,
) !void {
    inline for (std.meta.fields(snow.ThermodynamicParameters)) |field| {
        const value = @field(thermodynamics, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSnowSourceOrderThermodynamics;
    }
    const layer_count = try std.math.mul(usize, state.cell_count, state.layer_capacity);
    if (steps.len != layer_count) return error.SnowSourceOrderDimensionMismatch;
    const solid = try allocator.dupe(f64, state.solid_snow_water_equivalent_m3);
    defer allocator.free(solid);
    const liquid = try allocator.dupe(f64, state.liquid_water_volume_m3);
    defer allocator.free(liquid);
    const vapor = try allocator.dupe(f64, state.vapor_water_equivalent_m3);
    defer allocator.free(vapor);
    const ice = try allocator.dupe(f64, state.ice_volume_m3);
    defer allocator.free(ice);
    const capacity = try allocator.dupe(f64, state.heat_capacity_megajoules_per_k);
    defer allocator.free(capacity);
    const temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(temperature);
    const pending_energy = try allocator.alloc(f64, layer_count);
    defer allocator.free(pending_energy);
    @memset(pending_energy, 0);
    const next_local_layer = try allocator.alloc(usize, state.cell_count);
    defer allocator.free(next_local_layer);
    @memset(next_local_layer, 0);

    for (steps) |step| {
        if (step.cell >= state.cell_count or step.local_layer >= state.layer_capacity or
            step.local_layer != next_local_layer[step.cell])
            return error.InvalidSnowSourceLayerOrder;
        next_local_layer[step.cell] += 1;
        inline for (std.meta.fields(LayerStep)) |field| {
            if (field.type == f64 and !std.math.isFinite(@field(step, field.name)))
                return error.NonFiniteSnowSourceOrderStep;
        }
        if (step.liquid_to_lower_m3 < 0 or step.discharge_water_m3 < 0 or
            step.discharge_heat_megajoules < 0)
            return error.InvalidSnowSourceOrderStep;
        const source = step.cell * state.layer_capacity + step.local_layer;
        const has_lower = step.has_active_lower;
        if (has_lower and step.local_layer + 1 >= state.layer_capacity)
            return error.SnowSourceOrderInternalFaceOutOfBounds;
        if (!has_lower and (step.liquid_to_lower_m3 != 0 or
            step.vapor_to_lower_m3 != 0 or step.signed_face_heat_to_lower_megajoules != 0))
            return error.SnowSourceOrderBottomHasInternalFace;
        if (has_lower and (step.discharge_water_m3 != 0 or step.discharge_heat_megajoules != 0 or
            step.base_conduction_heat_megajoules != 0))
            return error.SnowSourceOrderInteriorHasDischarge;

        const old_energy = capacity[source] * temperature[source];
        if (!std.math.isFinite(old_energy) or capacity[source] < 0 or temperature[source] <= 0)
            return error.InvalidSnowSourceOrderState;
        if (has_lower) {
            const destination = source + 1;
            liquid[source] -= step.liquid_to_lower_m3;
            liquid[destination] += step.liquid_to_lower_m3;
            vapor[source] -= step.vapor_to_lower_m3;
            vapor[destination] += step.vapor_to_lower_m3;
            pending_energy[destination] += step.signed_face_heat_to_lower_megajoules;
            if (!std.math.isFinite(pending_energy[destination]))
                return error.SnowSourceOrderEnergyOverflow;
        } else {
            liquid[source] -= step.discharge_water_m3;
        }
        solid[source] += step.local_solid_change_m3;
        liquid[source] += step.local_liquid_change_m3;
        vapor[source] += step.local_vapor_change_m3;
        ice[source] += step.local_ice_change_m3;
        inline for (.{ solid[source], liquid[source], vapor[source], ice[source] }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSnowSourceOrderCandidate;

        const next_capacity = thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid[source] +
            thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (liquid[source] + vapor[source]) +
            thermodynamics.ice_heat_capacity_megajoules_per_m3_k * ice[source];
        const next_energy = old_energy + pending_energy[source] -
            step.signed_face_heat_to_lower_megajoules - step.discharge_heat_megajoules -
            step.base_conduction_heat_megajoules +
            step.local_process_heat_megajoules;
        if (!std.math.isFinite(next_capacity) or next_capacity < 0 or !std.math.isFinite(next_energy))
            return error.InvalidSnowSourceOrderCandidate;
        if (next_capacity > 0) {
            const next_temperature = next_energy / next_capacity;
            if (!std.math.isFinite(next_temperature) or next_temperature <= 0)
                return error.InvalidSnowSourceOrderCandidate;
            capacity[source] = next_capacity;
            temperature[source] = next_temperature;
        } else if (next_energy != 0) {
            return error.SnowSourceOrderEnergyWithoutCapacity;
        } else {
            capacity[source] = 0;
        }
        pending_energy[source] = 0;
    }
    for (next_local_layer) |next|
        if (next != state.layer_capacity) return error.IncompleteSnowSourceLayerOrder;
    for (pending_energy) |energy|
        if (energy != 0) return error.UnconsumedSnowSourceOrderEnergy;

    @memcpy(state.solid_snow_water_equivalent_m3, solid);
    @memcpy(state.liquid_water_volume_m3, liquid);
    @memcpy(state.vapor_water_equivalent_m3, vapor);
    @memcpy(state.ice_volume_m3, ice);
    @memcpy(state.heat_capacity_megajoules_per_k, capacity);
    @memcpy(state.temperature_k, temperature);
    state.refreshAllGeometry();
}

test "source ordered melt energy waits for destination layer turn" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{270}, &.{ 0.05, 0.1 }, 0.1, snow.test_thermodynamics);
    state.liquid_water_volume_m3[0] = 0.01;
    state.heat_capacity_megajoules_per_k[0] += 4.19 * 0.01;
    state.temperature_k[0] = 280;
    state.temperature_k[1] = 260;
    const lower_capacity_before = state.heat_capacity_megajoules_per_k[1];
    const flux: f64 = 0.004;
    const heat = 4.19 * 280 * flux;
    try apply(std.testing.allocator, &state, snow.test_thermodynamics, &.{
        .{ .cell = 0, .local_layer = 0, .liquid_to_lower_m3 = flux, .signed_face_heat_to_lower_megajoules = heat },
        .{ .cell = 0, .local_layer = 1, .has_active_lower = false },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 280), state.temperature_k[0], 1e-12);
    const expected_lower_temperature = (lower_capacity_before * 260 + heat) /
        (lower_capacity_before + 4.19 * flux);
    try std.testing.expectApproxEqAbs(expected_lower_temperature, state.temperature_k[1], 1e-12);
}

test "source ordered phase replay uses the complete frozen carrier reference" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(
        &.{0.1},
        &.{1},
        &.{270},
        &.{0.1},
        0.05,
        snow.test_thermodynamics,
    );
    const density: f64 = 0.92;
    const latent: f64 = 333;
    const liquid_to_ice_we_m3: f64 = 0.004;
    state.liquid_water_volume_m3[0] = 0.01;
    state.heat_capacity_megajoules_per_k[0] +=
        snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
        state.liquid_water_volume_m3[0];
    const solid_reference = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k,
        snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        latent,
        snow.test_thermodynamics.pure_water_melting_temperature_k,
    );
    const ice_capacity_per_we = try ice_units.heatCapacityPerWaterEquivalentM3K(
        snow.test_thermodynamics.ice_heat_capacity_megajoules_per_m3_k,
        density,
    );
    const ice_reference = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        ice_capacity_per_we,
        snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
        latent,
        snow.test_thermodynamics.pure_water_melting_temperature_k,
    );
    const before = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] +
        solid_reference * state.solid_snow_water_equivalent_m3[0];
    const phase_sensible_heat = -ice_reference * liquid_to_ice_we_m3;
    try apply(std.testing.allocator, &state, snow.test_thermodynamics, &.{.{
        .cell = 0,
        .local_layer = 0,
        .has_active_lower = false,
        .local_liquid_change_m3 = -liquid_to_ice_we_m3,
        .local_ice_change_m3 = liquid_to_ice_we_m3 / density,
        .local_process_heat_megajoules = phase_sensible_heat,
    }});
    const after = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] +
        solid_reference * state.solid_snow_water_equivalent_m3[0] +
        ice_reference * state.ice_volume_m3[0] * density;
    try std.testing.expectApproxEqAbs(before, after, 256 * std.math.floatEps(f64));
    try std.testing.expect(@abs(phase_sensible_heat - latent * liquid_to_ice_we_m3) > 1);
}

test "source ordered base conduction leaves only the bottom layer, in both signs" {
    for ([_]f64{ 0.02, -0.02 }) |signed_heat| {
        var state = try snow.State.init(std.testing.allocator, 1, 2);
        defer state.deinit();
        try state.initializePhysicalState(&.{0.1}, &.{1}, &.{270}, &.{ 0.05, 0.1 }, 0.1, snow.test_thermodynamics);
        state.liquid_water_volume_m3[0] = 0.01;
        state.vapor_water_equivalent_m3[0] = 0.002;
        state.ice_volume_m3[0] = 0.003;
        state.heat_capacity_megajoules_per_k[0] =
            snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k *
            state.solid_snow_water_equivalent_m3[0] +
            snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                (state.liquid_water_volume_m3[0] + state.vapor_water_equivalent_m3[0]) +
            snow.test_thermodynamics.ice_heat_capacity_megajoules_per_m3_k *
                state.ice_volume_m3[0];
        const solid_before = state.solid_snow_water_equivalent_m3[0];
        const liquid_before = state.liquid_water_volume_m3[0];
        const vapor_before = state.vapor_water_equivalent_m3[0];
        const ice_before = state.ice_volume_m3[0];
        const capacity_before = state.heat_capacity_megajoules_per_k[0];
        const energy_before = capacity_before * state.temperature_k[0];
        try apply(std.testing.allocator, &state, snow.test_thermodynamics, &.{
            .{
                .cell = 0,
                .local_layer = 0,
                .has_active_lower = false,
                .base_conduction_heat_megajoules = signed_heat,
            },
            .{ .cell = 0, .local_layer = 1, .has_active_lower = false },
        });
        try std.testing.expectEqual(capacity_before, state.heat_capacity_megajoules_per_k[0]);
        try std.testing.expectApproxEqAbs(
            energy_before - signed_heat,
            state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0],
            1e-12,
        );
        // Energy only: the base face moves no snow mass in any phase, so the
        // water census cannot see this transfer at all.
        try std.testing.expectEqual(solid_before, state.solid_snow_water_equivalent_m3[0]);
        try std.testing.expectEqual(liquid_before, state.liquid_water_volume_m3[0]);
        try std.testing.expectEqual(vapor_before, state.vapor_water_equivalent_m3[0]);
        try std.testing.expectEqual(ice_before, state.ice_volume_m3[0]);
    }
    var interior = try snow.State.init(std.testing.allocator, 1, 2);
    defer interior.deinit();
    try interior.initializePhysicalState(&.{0.15}, &.{2}, &.{270}, &.{ 0.05, 0.1 }, 0.1, snow.test_thermodynamics);
    try std.testing.expectError(error.SnowSourceOrderInteriorHasDischarge, apply(
        std.testing.allocator,
        &interior,
        snow.test_thermodynamics,
        &.{
            .{ .cell = 0, .local_layer = 0, .base_conduction_heat_megajoules = 0.01 },
            .{ .cell = 0, .local_layer = 1, .has_active_lower = false },
        },
    ));
}

test "late source ordered overdraw leaves live snow state unchanged" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{270}, &.{ 0.05, 0.1 }, 0.1, snow.test_thermodynamics);
    const liquid_before = state.liquid_water_volume_m3[0..2].*;
    const temperature_before = state.temperature_k[0..2].*;
    try std.testing.expectError(error.InvalidSnowSourceOrderCandidate, apply(
        std.testing.allocator,
        &state,
        snow.test_thermodynamics,
        &.{
            .{ .cell = 0, .local_layer = 0 },
            .{ .cell = 0, .local_layer = 1, .has_active_lower = false, .discharge_water_m3 = 1 },
        },
    ));
    try std.testing.expectEqualSlices(f64, &liquid_before, state.liquid_water_volume_m3);
    try std.testing.expectEqualSlices(f64, &temperature_before, state.temperature_k);
}

test "source ordered discharge uses actual last active layer before capacity end" {
    var state = try snow.State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    try state.initializePhysicalState(
        &.{0.1},
        &.{1},
        &.{270},
        &.{ 0.05, 0.10, 0.20 },
        0.1,
        snow.test_thermodynamics,
    );
    try std.testing.expect(!state.active[2]);
    state.liquid_water_volume_m3[1] = 0.01;
    state.heat_capacity_megajoules_per_k[1] += 4.19 * 0.01;
    state.temperature_k[1] = 275;
    const before_energy = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] +
        state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1];
    const discharge_m3: f64 = 0.004;
    const discharge_heat = 4.19 * 275 * discharge_m3;
    try apply(std.testing.allocator, &state, snow.test_thermodynamics, &.{
        .{ .cell = 0, .local_layer = 0 },
        .{
            .cell = 0,
            .local_layer = 1,
            .has_active_lower = false,
            .discharge_water_m3 = discharge_m3,
            .discharge_heat_megajoules = discharge_heat,
        },
        .{ .cell = 0, .local_layer = 2, .has_active_lower = false },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.006), state.liquid_water_volume_m3[1], 1e-15);
    try std.testing.expectEqual(@as(f64, 0), state.liquid_water_volume_m3[2]);
    const after_energy = state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] +
        state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1];
    try std.testing.expectApproxEqAbs(before_energy, after_energy + discharge_heat, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 275), state.temperature_k[1], 1e-12);
}

const std = @import("std");
const canopy_senescence = @import("../../canopy/photosynthesis/photosynthesis_senescence.zig");

pub const kinetic_fraction_count: usize = 4;
pub const litter_position_count: usize = 2;

pub const State = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    carbon_litterfall_g_c_by_plant_fraction_position: []f64,
    nitrogen_litterfall_g_n_by_plant_fraction_position: []f64,
    phosphorus_litterfall_g_p_by_plant_fraction_position: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !State {
        if (plant_count == 0)
            return error.InvalidStandingDeadLitterfallDimensions;
        const transaction_count = try std.math.mul(
            usize,
            try std.math.mul(usize, plant_count, kinetic_fraction_count),
            litter_position_count,
        );
        const values = try allocator.alloc(
            f64,
            try std.math.mul(usize, transaction_count, 3),
        );
        @memset(values, 0);
        return .{
            .allocator = allocator,
            .plant_count = plant_count,
            .carbon_litterfall_g_c_by_plant_fraction_position = values[0..transaction_count],
            .nitrogen_litterfall_g_n_by_plant_fraction_position = values[transaction_count .. 2 * transaction_count],
            .phosphorus_litterfall_g_p_by_plant_fraction_position = values[2 * transaction_count ..],
        };
    }

    pub fn deinit(self: *State) void {
        const transaction_count =
            self.plant_count * kinetic_fraction_count * litter_position_count;
        self.allocator.free(
            self.carbon_litterfall_g_c_by_plant_fraction_position.ptr[0 .. 3 * transaction_count],
        );
        self.* = undefined;
    }
};

pub const Inputs = struct {
    biomass_turnover_type_by_plant: []const u8,
    root_profile_type_by_plant: []const u8,
    canopy_growth_temperature_response_by_plant: []const f64,
    timestep_h: f64,
    carbon_partition_by_plant_and_position: []const f64,
    nitrogen_partition_by_plant_and_position: []const f64,
    phosphorus_partition_by_plant_and_position: []const f64,
};

/// Reconstructs one plant's exact position-resolved standing-dead contribution
/// to the common GROSUB CSNC/ZSNC/PSNC producer. Position zero is woody and
/// position one is nonwoody, matching GROSUB 12609--12614.
pub fn productsForPlant(state: *const State, plant: usize) !canopy_senescence.SenescenceProducts {
    if (plant >= state.plant_count) return error.StandingDeadLitterfallPlantOutOfBounds;
    var products: canopy_senescence.SenescenceProducts = .{};
    for (0..kinetic_fraction_count) |fraction| {
        const base = (plant * kinetic_fraction_count + fraction) * litter_position_count;
        inline for (.{
            .{ "woody_carbon_g", state.carbon_litterfall_g_c_by_plant_fraction_position[base] },
            .{ "woody_nitrogen_g", state.nitrogen_litterfall_g_n_by_plant_fraction_position[base] },
            .{ "woody_phosphorus_g", state.phosphorus_litterfall_g_p_by_plant_fraction_position[base] },
            .{ "nonwoody_carbon_g", state.carbon_litterfall_g_c_by_plant_fraction_position[base + 1] },
            .{ "nonwoody_nitrogen_g", state.nitrogen_litterfall_g_n_by_plant_fraction_position[base + 1] },
            .{ "nonwoody_phosphorus_g", state.phosphorus_litterfall_g_p_by_plant_fraction_position[base + 1] },
        }) |field_value| {
            const value = field_value[1];
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidStandingDeadLitterfallProduct;
            @field(products, field_value[0])[fraction] = value;
        }
    }
    return products;
}

const Removal = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

/// grosub.f lines 12598–12626. Fortran axes `M=1..5` and position
/// `K=0..1` map to zero-based kinetic-fraction and litter-position axes.
pub fn apply(
    state: *State,
    inputs: Inputs,
    standing_dead_carbon_g_c_by_plant_and_fraction: []f64,
    standing_dead_nitrogen_g_n_by_plant_and_fraction: []f64,
    standing_dead_phosphorus_g_p_by_plant_and_fraction: []f64,
) !void {
    const pool_count = try std.math.mul(
        usize,
        state.plant_count,
        kinetic_fraction_count,
    );
    const partition_count = try std.math.mul(
        usize,
        state.plant_count,
        litter_position_count,
    );
    if (inputs.biomass_turnover_type_by_plant.len != state.plant_count or
        inputs.root_profile_type_by_plant.len != state.plant_count or
        inputs.canopy_growth_temperature_response_by_plant.len != state.plant_count or
        inputs.carbon_partition_by_plant_and_position.len != partition_count or
        inputs.nitrogen_partition_by_plant_and_position.len != partition_count or
        inputs.phosphorus_partition_by_plant_and_position.len != partition_count or
        standing_dead_carbon_g_c_by_plant_and_fraction.len != pool_count or
        standing_dead_nitrogen_g_n_by_plant_and_fraction.len != pool_count or
        standing_dead_phosphorus_g_p_by_plant_and_fraction.len != pool_count)
        return error.InvalidStandingDeadLitterfallDimensions;
    if (!std.math.isFinite(inputs.timestep_h) or inputs.timestep_h < 0)
        return error.InvalidStandingDeadLitterfallInput;

    for (0..state.plant_count) |plant| {
        try validatePartitions(inputs, plant);
        for (0..kinetic_fraction_count) |fraction| {
            _ = try removalFor(
                inputs,
                plant,
                standing_dead_carbon_g_c_by_plant_and_fraction[
                    plant * kinetic_fraction_count + fraction
                ],
                standing_dead_nitrogen_g_n_by_plant_and_fraction[
                    plant * kinetic_fraction_count + fraction
                ],
                standing_dead_phosphorus_g_p_by_plant_and_fraction[
                    plant * kinetic_fraction_count + fraction
                ],
            );
        }
    }

    @memset(state.carbon_litterfall_g_c_by_plant_fraction_position, 0);
    @memset(state.nitrogen_litterfall_g_n_by_plant_fraction_position, 0);
    @memset(state.phosphorus_litterfall_g_p_by_plant_fraction_position, 0);
    for (0..state.plant_count) |plant| {
        for (0..kinetic_fraction_count) |fraction| {
            const pool = plant * kinetic_fraction_count + fraction;
            const removal = removalFor(
                inputs,
                plant,
                standing_dead_carbon_g_c_by_plant_and_fraction[pool],
                standing_dead_nitrogen_g_n_by_plant_and_fraction[pool],
                standing_dead_phosphorus_g_p_by_plant_and_fraction[pool],
            ) catch unreachable;
            standing_dead_carbon_g_c_by_plant_and_fraction[pool] -= removal.carbon_g_c;
            standing_dead_nitrogen_g_n_by_plant_and_fraction[pool] -= removal.nitrogen_g_n;
            standing_dead_phosphorus_g_p_by_plant_and_fraction[pool] -= removal.phosphorus_g_p;
            for (0..litter_position_count) |position| {
                const output =
                    (pool * litter_position_count) + position;
                const partition = plant * litter_position_count + position;
                state.carbon_litterfall_g_c_by_plant_fraction_position[output] =
                    removal.carbon_g_c *
                    inputs.carbon_partition_by_plant_and_position[partition];
                state.nitrogen_litterfall_g_n_by_plant_fraction_position[output] =
                    removal.nitrogen_g_n *
                    inputs.nitrogen_partition_by_plant_and_position[partition];
                state.phosphorus_litterfall_g_p_by_plant_fraction_position[output] =
                    removal.phosphorus_g_p *
                    inputs.phosphorus_partition_by_plant_and_position[partition];
            }
        }
    }
}

fn removalFor(
    inputs: Inputs,
    plant: usize,
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
) !Removal {
    inline for (.{ carbon_g_c, nitrogen_g_n, phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidStandingDeadLitterfallPool;
    const temperature_response =
        inputs.canopy_growth_temperature_response_by_plant[plant];
    if (!std.math.isFinite(temperature_response) or temperature_response < 0)
        return error.InvalidStandingDeadLitterfallInput;
    const rate_per_h: f64 =
        if (inputs.biomass_turnover_type_by_plant[plant] == 0 or
        inputs.root_profile_type_by_plant[plant] <= 1)
            1.5814e-4
        else
            1.5814e-5;
    const temperature_factor = @sqrt(temperature_response);
    const fraction = rate_per_h * temperature_factor * inputs.timestep_h;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.InvalidStandingDeadLitterfallFraction;
    return .{
        .carbon_g_c = rate_per_h * temperature_factor * carbon_g_c *
            inputs.timestep_h,
        .nitrogen_g_n = rate_per_h * temperature_factor * nitrogen_g_n *
            inputs.timestep_h,
        .phosphorus_g_p = rate_per_h * temperature_factor * phosphorus_g_p *
            inputs.timestep_h,
    };
}

fn validatePartitions(inputs: Inputs, plant: usize) !void {
    const first = plant * litter_position_count;
    inline for (.{
        inputs.carbon_partition_by_plant_and_position,
        inputs.nitrogen_partition_by_plant_and_position,
        inputs.phosphorus_partition_by_plant_and_position,
    }) |partitions| {
        var sum: f64 = 0;
        for (partitions[first .. first + litter_position_count]) |value| {
            if (!std.math.isFinite(value) or value < 0 or value > 1)
                return error.InvalidStandingDeadLitterfallPartition;
            sum += value;
        }
        if (@abs(sum - 1) > 1.0e-12)
            return error.InvalidStandingDeadLitterfallPartition;
    }
}

test "standing dead litterfall preserves five fractions and two positions" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var carbon = [_]f64{ 10, 20, 30, 40 };
    var nitrogen = [_]f64{ 1, 2, 3, 4 };
    var phosphorus = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
    try apply(
        &state,
        .{
            .biomass_turnover_type_by_plant = &.{0},
            .root_profile_type_by_plant = &.{3},
            .canopy_growth_temperature_response_by_plant = &.{4},
            .timestep_h = 0.5,
            .carbon_partition_by_plant_and_position = &.{ 0.25, 0.75 },
            .nitrogen_partition_by_plant_and_position = &.{ 0.4, 0.6 },
            .phosphorus_partition_by_plant_and_position = &.{ 0.1, 0.9 },
        },
        &carbon,
        &nitrogen,
        &phosphorus,
    );
    const fraction = 1.5814e-4;
    try std.testing.expectApproxEqAbs(
        @as(f64, 10) * (1 - fraction),
        carbon[0],
        1.0e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 10) * fraction * 0.25,
        state.carbon_litterfall_g_c_by_plant_fraction_position[0],
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 10) * fraction * 0.75,
        state.carbon_litterfall_g_c_by_plant_fraction_position[1],
        1.0e-15,
    );
    const initial_carbon_g_c: f64 = 100;
    var final_carbon_g_c: f64 = 0;
    for (carbon) |value| final_carbon_g_c += value;
    for (state.carbon_litterfall_g_c_by_plant_fraction_position) |value|
        final_carbon_g_c += value;
    try std.testing.expectApproxEqAbs(
        initial_carbon_g_c,
        final_carbon_g_c,
        1.0e-12,
    );
}

test "woody deep-root rate preserves source branch" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var carbon = [_]f64{1} ** kinetic_fraction_count;
    var nitrogen = [_]f64{1} ** kinetic_fraction_count;
    var phosphorus = [_]f64{1} ** kinetic_fraction_count;
    try apply(
        &state,
        .{
            .biomass_turnover_type_by_plant = &.{2},
            .root_profile_type_by_plant = &.{2},
            .canopy_growth_temperature_response_by_plant = &.{1},
            .timestep_h = 1,
            .carbon_partition_by_plant_and_position = &.{ 1, 0 },
            .nitrogen_partition_by_plant_and_position = &.{ 1, 0 },
            .phosphorus_partition_by_plant_and_position = &.{ 1, 0 },
        },
        &carbon,
        &nitrogen,
        &phosphorus,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.5814e-5),
        state.carbon_litterfall_g_c_by_plant_fraction_position[0],
        1.0e-18,
    );
}

test "late invalid plant preserves pools and state_update" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    @memset(state.carbon_litterfall_g_c_by_plant_fraction_position, 7);
    @memset(state.nitrogen_litterfall_g_n_by_plant_fraction_position, 7);
    @memset(state.phosphorus_litterfall_g_p_by_plant_fraction_position, 7);
    var carbon = [_]f64{1} ** (2 * kinetic_fraction_count);
    var nitrogen = [_]f64{1} ** (2 * kinetic_fraction_count);
    var phosphorus = [_]f64{1} ** (2 * kinetic_fraction_count);
    phosphorus[phosphorus.len - 1] = std.math.nan(f64);
    const original_carbon = carbon;
    const original_nitrogen = nitrogen;
    const original_phosphorus = phosphorus;
    try std.testing.expectError(
        error.InvalidStandingDeadLitterfallPool,
        apply(
            &state,
            .{
                .biomass_turnover_type_by_plant = &.{ 0, 0 },
                .root_profile_type_by_plant = &.{ 0, 0 },
                .canopy_growth_temperature_response_by_plant = &.{ 1, 1 },
                .timestep_h = 1,
                .carbon_partition_by_plant_and_position = &.{ 1, 0, 1, 0 },
                .nitrogen_partition_by_plant_and_position = &.{ 1, 0, 1, 0 },
                .phosphorus_partition_by_plant_and_position = &.{ 1, 0, 1, 0 },
            },
            &carbon,
            &nitrogen,
            &phosphorus,
        ),
    );
    try std.testing.expectEqualSlices(f64, &original_carbon, &carbon);
    try std.testing.expectEqualSlices(f64, &original_nitrogen, &nitrogen);
    try std.testing.expectEqualSlices(
        f64,
        original_phosphorus[0 .. original_phosphorus.len - 1],
        phosphorus[0 .. phosphorus.len - 1],
    );
    try std.testing.expect(std.math.isNan(phosphorus[phosphorus.len - 1]));
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (field.type == []f64)
            for (@field(state, field.name)) |value|
                try std.testing.expectEqual(@as(f64, 7), value);
}

test "standing dead products retain exact plant C N P positions for EXTRACT litter" {
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    const base = (1 * kinetic_fraction_count + 2) * litter_position_count;
    state.carbon_litterfall_g_c_by_plant_fraction_position[base] = 3;
    state.nitrogen_litterfall_g_n_by_plant_fraction_position[base + 1] = 0.4;
    state.phosphorus_litterfall_g_p_by_plant_fraction_position[base] = 0.05;
    const products = try productsForPlant(&state, 1);
    try std.testing.expectEqual(@as(f64, 3), products.woody_carbon_g[2]);
    try std.testing.expectEqual(@as(f64, 0.4), products.nonwoody_nitrogen_g[2]);
    try std.testing.expectEqual(@as(f64, 0.05), products.woody_phosphorus_g[2]);
    try std.testing.expectEqual(@as(f64, 0), products.nonwoody_carbon_g[2]);

    state.carbon_litterfall_g_c_by_plant_fraction_position[base + 1] = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidStandingDeadLitterfallProduct,
        productsForPlant(&state, 1),
    );
}

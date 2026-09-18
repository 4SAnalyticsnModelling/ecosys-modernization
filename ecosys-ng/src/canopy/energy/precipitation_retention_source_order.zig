const std = @import("std");

pub const Inputs = struct {
    precipitation_irrigation_m3_h: f64,
    retention_capacity_m3_per_m2_by_vegetation_type: []const f64,
    vegetation_type_by_species: []const u8,
    leaf_area_m2: []const f64,
    stalk_area_m2: []const f64,
    standing_dead_area_m2: []const f64,
    live_water_content_m3: []const f64,
    standing_dead_water_content_m3: []const f64,
    live_radiation_fraction: []const f64,
    standing_dead_radiation_fraction: []const f64,
};

pub const Outputs = struct {
    live_retention_flux_m3_h: []f64,
    standing_dead_retention_flux_m3_h: []f64,
};

pub const Totals = struct {
    potential_interception_m3_h: f64,
    retention_flux_m3_h: f64,
};

/// Isolated `hour1.f` lines 1844--1856. Runtime species retain the source capacity,
/// fill/overflow flux, potential interception, and retained-flux order.
pub fn compute(inputs: Inputs, outputs: Outputs) !Totals {
    const species_count = try validate(inputs, outputs);
    var totals: Totals = .{
        .potential_interception_m3_h = 0.0,
        .retention_flux_m3_h = 0.0,
    };
    for (0..species_count) |species| {
        const result = retentionForSpecies(inputs, species);
        if (!std.math.isFinite(result.live_flux_m3_h) or
            !std.math.isFinite(result.dead_flux_m3_h) or
            !std.math.isFinite(result.potential_m3_h))
            return error.InvalidCanopyRetentionResult;
        totals.potential_interception_m3_h += result.potential_m3_h;
        totals.retention_flux_m3_h +=
            result.live_flux_m3_h + result.dead_flux_m3_h;
        if (!std.math.isFinite(totals.potential_interception_m3_h) or
            !std.math.isFinite(totals.retention_flux_m3_h))
            return error.InvalidCanopyRetentionResult;
    }
    for (0..species_count) |species| {
        const result = retentionForSpecies(inputs, species);
        outputs.live_retention_flux_m3_h[species] = result.live_flux_m3_h;
        outputs.standing_dead_retention_flux_m3_h[species] =
            result.dead_flux_m3_h;
    }
    return totals;
}

const SpeciesRetention = struct {
    live_flux_m3_h: f64,
    dead_flux_m3_h: f64,
    potential_m3_h: f64,
};

fn retentionForSpecies(inputs: Inputs, species: usize) SpeciesRetention {
    const capacity_m3_per_m2 =
        inputs.retention_capacity_m3_per_m2_by_vegetation_type[
            inputs.vegetation_type_by_species[species]
        ];
    const live_capacity_m3 = capacity_m3_per_m2 *
        (inputs.leaf_area_m2[species] + inputs.stalk_area_m2[species]);
    const dead_capacity_m3 =
        capacity_m3_per_m2 * inputs.standing_dead_area_m2[species];
    return .{
        .live_flux_m3_h = @max(
            0.0,
            @min(
                inputs.precipitation_irrigation_m3_h *
                    inputs.live_radiation_fraction[species],
                live_capacity_m3 - inputs.live_water_content_m3[species],
            ),
        ) - @max(
            0.0,
            inputs.live_water_content_m3[species] - live_capacity_m3,
        ),
        .dead_flux_m3_h = @max(
            0.0,
            @min(
                inputs.precipitation_irrigation_m3_h *
                    inputs.standing_dead_radiation_fraction[species],
                dead_capacity_m3 -
                    inputs.standing_dead_water_content_m3[species],
            ),
        ) - @max(
            0.0,
            inputs.standing_dead_water_content_m3[species] - dead_capacity_m3,
        ),
        .potential_m3_h = inputs.precipitation_irrigation_m3_h *
            (inputs.live_radiation_fraction[species] +
                inputs.standing_dead_radiation_fraction[species]),
    };
}

fn validate(inputs: Inputs, outputs: Outputs) !usize {
    const species_count = inputs.vegetation_type_by_species.len;
    if (species_count == 0 or
        inputs.retention_capacity_m3_per_m2_by_vegetation_type.len == 0)
        return error.ZeroCanopyRetentionExtent;
    inline for (.{
        inputs.leaf_area_m2,
        inputs.stalk_area_m2,
        inputs.standing_dead_area_m2,
        inputs.live_water_content_m3,
        inputs.standing_dead_water_content_m3,
        inputs.live_radiation_fraction,
        inputs.standing_dead_radiation_fraction,
        outputs.live_retention_flux_m3_h,
        outputs.standing_dead_retention_flux_m3_h,
    }) |values| if (values.len != species_count)
        return error.CanopyRetentionDimensionMismatch;
    for (inputs.vegetation_type_by_species) |vegetation_type|
        if (vegetation_type >=
            inputs.retention_capacity_m3_per_m2_by_vegetation_type.len)
            return error.CanopyRetentionVegetationTypeOutOfRange;
    if (!std.math.isFinite(inputs.precipitation_irrigation_m3_h) or
        inputs.precipitation_irrigation_m3_h < 0)
        return error.InvalidCanopyRetentionInput;
    inline for (.{
        inputs.retention_capacity_m3_per_m2_by_vegetation_type,
        inputs.leaf_area_m2,
        inputs.stalk_area_m2,
        inputs.standing_dead_area_m2,
        inputs.live_water_content_m3,
        inputs.standing_dead_water_content_m3,
        inputs.live_radiation_fraction,
        inputs.standing_dead_radiation_fraction,
    }) |values| for (values) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidCanopyRetentionInput;
    return species_count;
}

test "canopy retention fills capacity and releases overflow in source order" {
    var live_flux: [1]f64 = undefined;
    var dead_flux: [1]f64 = undefined;
    const totals = try compute(.{
        .precipitation_irrigation_m3_h = 1,
        .retention_capacity_m3_per_m2_by_vegetation_type = &.{0.1},
        .vegetation_type_by_species = &.{0},
        .leaf_area_m2 = &.{2},
        .stalk_area_m2 = &.{1},
        .standing_dead_area_m2 = &.{1},
        .live_water_content_m3 = &.{0.1},
        .standing_dead_water_content_m3 = &.{0.2},
        .live_radiation_fraction = &.{0.2},
        .standing_dead_radiation_fraction = &.{0.1},
    }, .{
        .live_retention_flux_m3_h = &live_flux,
        .standing_dead_retention_flux_m3_h = &dead_flux,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), live_flux[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), dead_flux[0], 1e-15);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.3),
        totals.potential_interception_m3_h,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        totals.retention_flux_m3_h,
        1e-15,
    );
}

test "vegetation type bounds fail before output mutation" {
    var live_flux = [_]f64{42};
    var dead_flux = [_]f64{43};
    try std.testing.expectError(
        error.CanopyRetentionVegetationTypeOutOfRange,
        compute(.{
            .precipitation_irrigation_m3_h = 0,
            .retention_capacity_m3_per_m2_by_vegetation_type = &.{0.1},
            .vegetation_type_by_species = &.{1},
            .leaf_area_m2 = &.{0},
            .stalk_area_m2 = &.{0},
            .standing_dead_area_m2 = &.{0},
            .live_water_content_m3 = &.{0},
            .standing_dead_water_content_m3 = &.{0},
            .live_radiation_fraction = &.{0},
            .standing_dead_radiation_fraction = &.{0},
        }, .{
            .live_retention_flux_m3_h = &live_flux,
            .standing_dead_retention_flux_m3_h = &dead_flux,
        }),
    );
    try std.testing.expectEqual(@as(f64, 42), live_flux[0]);
    try std.testing.expectEqual(@as(f64, 43), dead_flux[0]);
}

test "overflow fails before output mutation" {
    var live_flux = [_]f64{42};
    var dead_flux = [_]f64{43};
    try std.testing.expectError(
        error.InvalidCanopyRetentionResult,
        compute(.{
            .precipitation_irrigation_m3_h = std.math.floatMax(f64),
            .retention_capacity_m3_per_m2_by_vegetation_type = &.{std.math.floatMax(f64)},
            .vegetation_type_by_species = &.{0},
            .leaf_area_m2 = &.{2},
            .stalk_area_m2 = &.{0},
            .standing_dead_area_m2 = &.{0},
            .live_water_content_m3 = &.{0},
            .standing_dead_water_content_m3 = &.{0},
            .live_radiation_fraction = &.{2},
            .standing_dead_radiation_fraction = &.{0},
        }, .{
            .live_retention_flux_m3_h = &live_flux,
            .standing_dead_retention_flux_m3_h = &dead_flux,
        }),
    );
    try std.testing.expectEqual(@as(f64, 42), live_flux[0]);
    try std.testing.expectEqual(@as(f64, 43), dead_flux[0]);
}

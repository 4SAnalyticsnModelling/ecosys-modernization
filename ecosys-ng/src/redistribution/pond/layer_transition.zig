const std = @import("std");
const ice_units = @import("../../core/ice_units.zig");

pub const StorageLocation = union(enum) {
    surface_pond,
    soil_layer: usize,
};

pub const Transition = struct {
    source: StorageLocation,
    destination: StorageLocation,
    transfer_fraction: f64,
    boundary_change_m: f64,
    next_first_active_layer: usize,
};

pub const SurfaceInputs = struct {
    first_active_layer: usize,
    initial_first_active_layer: usize,
    active_layer_end: usize,
    uppermost_water_layer: usize,
    layer_thickness_m: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    total_heat_capacity_megajoules_per_k: []const f64,
    matrix_liquid_water_m3: []const f64,
    matrix_ice_water_m3: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
    minimum_heat_capacity_megajoules_per_k: f64,
    minimum_layer_thickness_m: f64,
    surface_pond_liquid_water_m3: f64,
    surface_pond_ice_m3: f64,
    surface_ponding_capacity_m3: f64,
    surface_litter_volume_m3: f64,
    surface_litter_water_capacity_m3: f64,
    horizontal_area_m2: f64,
    current_surface_boundary_depth_m: f64,
    initial_surface_boundary_depth_m: f64,
};

/// Exact REDIST surface-pond disappearance/reappearance decisions expressed
/// without sentinel layer zero. The returned surface_pond location is bound
/// by the caller to the separate runtime surface owners.
pub fn selectSurfaceTransition(inputs: SurfaceInputs) !?Transition {
    try validateSurfaceInputs(inputs);
    const first = inputs.first_active_layer;

    const first_is_pond = inputs.bulk_density_megagrams_per_m3[first] <= 0;
    if (first_is_pond and
        (inputs.total_heat_capacity_megajoules_per_k[first] <= inputs.minimum_heat_capacity_megajoules_per_k or inputs.uppermost_water_layer > first))
    {
        var next = first + 1;
        while (next < inputs.active_layer_end) : (next += 1) {
            if (inputs.layer_thickness_m[next] > inputs.minimum_layer_thickness_m) {
                const physical_ice_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(inputs.matrix_ice_water_m3[first], inputs.ice_density_megagrams_per_m3);
                const water_depth_m = (inputs.matrix_liquid_water_m3[first] + physical_ice_m3) / inputs.horizontal_area_m2;
                return .{
                    .source = .{ .soil_layer = first },
                    .destination = .{ .soil_layer = next },
                    .transfer_fraction = if (water_depth_m > 0) @min(1, inputs.layer_thickness_m[first] / water_depth_m) else 1,
                    .boundary_change_m = inputs.layer_thickness_m[first],
                    .next_first_active_layer = next,
                };
            }
        }
        return null;
    }

    const physical_surface_ice_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(inputs.surface_pond_ice_m3, inputs.ice_density_megagrams_per_m3);
    const excess_surface_water_m3 = @max(0, inputs.surface_pond_liquid_water_m3 + physical_surface_ice_m3 - inputs.surface_ponding_capacity_m3);
    if (!first_is_pond and
        first > inputs.initial_first_active_layer and
        inputs.current_surface_boundary_depth_m > inputs.initial_surface_boundary_depth_m and
        excess_surface_water_m3 > inputs.minimum_heat_capacity_megajoules_per_k / inputs.liquid_water_heat_capacity_megajoules_per_m3_k)
    {
        const boundary_change_m = -excess_surface_water_m3 / inputs.horizontal_area_m2;
        const pond_depth_m = (@max(0, inputs.surface_pond_liquid_water_m3 + physical_surface_ice_m3 - inputs.surface_litter_water_capacity_m3) +
            inputs.surface_litter_volume_m3) / inputs.horizontal_area_m2;
        const transferable_depth_m = @max(0, -boundary_change_m);
        const transfer_fraction = if (pond_depth_m > 0) @min(1, transferable_depth_m / pond_depth_m) else 1;
        return .{
            .source = .surface_pond,
            .destination = .{ .soil_layer = inputs.initial_first_active_layer },
            .transfer_fraction = transfer_fraction,
            .boundary_change_m = boundary_change_m,
            .next_first_active_layer = inputs.initial_first_active_layer,
        };
    }
    return null;
}

pub const SeparatedSurfaceInputs = struct {
    top_soil_layer: usize,
    surface_pond_liquid_water_m3: f64,
    surface_pond_ice_m3: f64,
    surface_ponding_capacity_m3: f64,
    surface_litter_volume_m3: f64,
    surface_litter_water_capacity_m3: f64,
    horizontal_area_m2: f64,
    minimum_heat_capacity_megajoules_per_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
};

/// Equivalent selector for ecosys-ng's separated surface representation.
/// Unlike Fortran's NU/NUI bookkeeping, the soil array remains zero-based and
/// the external surface owner transfers directly into the current topsoil.
pub fn selectSeparatedSurfacePondTransfer(inputs: SeparatedSurfaceInputs) !?Transition {
    inline for (@typeInfo(SeparatedSurfaceInputs).@"struct".fields) |field| if (field.type == f64) {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFinitePondTransitionInput;
    };
    if (inputs.surface_pond_liquid_water_m3 < 0 or inputs.surface_pond_ice_m3 < 0 or inputs.surface_ponding_capacity_m3 < 0 or inputs.surface_litter_volume_m3 < 0 or inputs.surface_litter_water_capacity_m3 < 0 or inputs.horizontal_area_m2 <= 0 or inputs.minimum_heat_capacity_megajoules_per_k < 0 or inputs.liquid_water_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidPondTransitionInput;
    if (inputs.ice_density_megagrams_per_m3 <= 0 or inputs.ice_density_megagrams_per_m3 > 1) return error.InvalidPondTransitionInput;
    const physical_ice_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(inputs.surface_pond_ice_m3, inputs.ice_density_megagrams_per_m3);
    const excess_m3 = @max(0, inputs.surface_pond_liquid_water_m3 + physical_ice_m3 - inputs.surface_ponding_capacity_m3);
    if (excess_m3 <= inputs.minimum_heat_capacity_megajoules_per_k / inputs.liquid_water_heat_capacity_megajoules_per_m3_k) return null;
    const boundary_change_m = -excess_m3 / inputs.horizontal_area_m2;
    const pond_depth_m = (@max(0, inputs.surface_pond_liquid_water_m3 + physical_ice_m3 - inputs.surface_litter_water_capacity_m3) + inputs.surface_litter_volume_m3) / inputs.horizontal_area_m2;
    return .{
        .source = .surface_pond,
        .destination = .{ .soil_layer = inputs.top_soil_layer },
        .transfer_fraction = if (pond_depth_m > 0) @min(1, -boundary_change_m / pond_depth_m) else 1,
        .boundary_change_m = boundary_change_m,
        .next_first_active_layer = inputs.top_soil_layer,
    };
}

pub const SubsurfaceInputs = struct {
    boundary_layer: usize,
    first_active_layer: usize,
    layer_thickness_m: []const f64,
    bulk_density_megagrams_per_m3: []const f64,
    matrix_liquid_water_m3: []const f64,
    matrix_ice_water_m3: []const f64,
    matrix_pore_capacity_m3: []const f64,
    horizontal_area_m2: f64,
    minimum_layer_thickness_m: f64,
    negligible_water_volume_m3: f64,
    ice_density_megagrams_per_m3: f64 = ice_units.reference_ice_density_megagrams_per_m3,
};

/// Exact REDIST uppermost-subsurface pond disappearance/reappearance gate.
pub fn selectSubsurfaceTransition(inputs: SubsurfaceInputs) !?Transition {
    try validateSubsurfaceInputs(inputs);
    const upper = inputs.boundary_layer;
    const lower = upper + 1;
    const upper_is_soil = inputs.bulk_density_megagrams_per_m3[upper] > 0;
    const lower_is_pond = inputs.bulk_density_megagrams_per_m3[lower] <= 0;
    if (upper_is_soil and lower_is_pond and
        inputs.layer_thickness_m[lower] <= inputs.minimum_layer_thickness_m and
        inputs.layer_thickness_m[lower] > 0)
    {
        const physical_ice_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(inputs.matrix_ice_water_m3[lower], inputs.ice_density_megagrams_per_m3);
        const water_depth_m = (inputs.matrix_liquid_water_m3[lower] + physical_ice_m3) / inputs.horizontal_area_m2;
        return .{
            .source = .{ .soil_layer = lower },
            .destination = .{ .soil_layer = upper },
            .transfer_fraction = if (water_depth_m > 0) @min(1, inputs.layer_thickness_m[lower] / water_depth_m) else 1,
            .boundary_change_m = inputs.layer_thickness_m[lower],
            .next_first_active_layer = inputs.first_active_layer,
        };
    }
    if (upper >= inputs.first_active_layer and upper_is_soil and lower_is_pond) {
        const physical_ice_m3 = try ice_units.physicalVolumeM3FromWaterEquivalent(inputs.matrix_ice_water_m3[upper], inputs.ice_density_megagrams_per_m3);
        const excess_water_m3 = @max(0, inputs.matrix_liquid_water_m3[upper] + physical_ice_m3 - inputs.matrix_pore_capacity_m3[upper]);
        if (excess_water_m3 > inputs.negligible_water_volume_m3) {
            const boundary_change_m = -excess_water_m3 / inputs.horizontal_area_m2;
            const water_depth_m = (inputs.matrix_liquid_water_m3[upper] + physical_ice_m3) / inputs.horizontal_area_m2;
            return .{
                .source = .{ .soil_layer = upper },
                .destination = .{ .soil_layer = lower },
                .transfer_fraction = if (water_depth_m > 0) @min(1, -boundary_change_m / water_depth_m) else 1,
                .boundary_change_m = boundary_change_m,
                .next_first_active_layer = inputs.first_active_layer,
            };
        }
    }
    return null;
}

fn validateSurfaceInputs(inputs: SurfaceInputs) !void {
    const count = inputs.layer_thickness_m.len;
    if (count == 0 or inputs.bulk_density_megagrams_per_m3.len != count or inputs.total_heat_capacity_megajoules_per_k.len != count or inputs.matrix_liquid_water_m3.len != count or inputs.matrix_ice_water_m3.len != count or inputs.first_active_layer >= count or inputs.initial_first_active_layer >= count or inputs.active_layer_end > count or inputs.first_active_layer >= inputs.active_layer_end) return error.PondTransitionDimensionMismatch;
    inline for (.{
        inputs.minimum_heat_capacity_megajoules_per_k,         inputs.minimum_layer_thickness_m,
        inputs.surface_pond_liquid_water_m3,                   inputs.surface_pond_ice_m3,
        inputs.surface_ponding_capacity_m3,                    inputs.surface_litter_volume_m3,
        inputs.surface_litter_water_capacity_m3,               inputs.horizontal_area_m2,
        inputs.current_surface_boundary_depth_m,               inputs.initial_surface_boundary_depth_m,
        inputs.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.ice_density_megagrams_per_m3,
    }) |value| if (!std.math.isFinite(value)) return error.NonFinitePondTransitionInput;
    if (inputs.minimum_heat_capacity_megajoules_per_k < 0 or inputs.minimum_layer_thickness_m <= 0 or inputs.surface_pond_liquid_water_m3 < 0 or inputs.surface_pond_ice_m3 < 0 or inputs.surface_ponding_capacity_m3 < 0 or inputs.surface_litter_volume_m3 < 0 or inputs.surface_litter_water_capacity_m3 < 0 or inputs.horizontal_area_m2 <= 0 or inputs.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or inputs.ice_density_megagrams_per_m3 <= 0 or inputs.ice_density_megagrams_per_m3 > 1) return error.InvalidPondTransitionInput;
    for (inputs.layer_thickness_m, inputs.bulk_density_megagrams_per_m3, inputs.total_heat_capacity_megajoules_per_k, inputs.matrix_liquid_water_m3, inputs.matrix_ice_water_m3) |thickness, density, capacity, liquid, ice| {
        if (!std.math.isFinite(thickness) or !std.math.isFinite(density) or !std.math.isFinite(capacity) or !std.math.isFinite(liquid) or !std.math.isFinite(ice) or thickness < 0 or density < 0 or capacity < 0 or liquid < 0 or ice < 0) return error.InvalidPondTransitionLayerState;
    }
}

fn validateSubsurfaceInputs(inputs: SubsurfaceInputs) !void {
    const count = inputs.layer_thickness_m.len;
    if (count < 2 or inputs.bulk_density_megagrams_per_m3.len != count or inputs.matrix_liquid_water_m3.len != count or inputs.matrix_ice_water_m3.len != count or inputs.matrix_pore_capacity_m3.len != count or inputs.boundary_layer + 1 >= count or inputs.first_active_layer >= count) return error.PondTransitionDimensionMismatch;
    inline for (.{ inputs.horizontal_area_m2, inputs.minimum_layer_thickness_m, inputs.negligible_water_volume_m3, inputs.ice_density_megagrams_per_m3 }) |value| if (!std.math.isFinite(value)) return error.NonFinitePondTransitionInput;
    if (inputs.horizontal_area_m2 <= 0 or inputs.minimum_layer_thickness_m <= 0 or inputs.negligible_water_volume_m3 < 0 or inputs.ice_density_megagrams_per_m3 <= 0 or inputs.ice_density_megagrams_per_m3 > 1) return error.InvalidPondTransitionInput;
    for (inputs.layer_thickness_m, inputs.bulk_density_megagrams_per_m3, inputs.matrix_liquid_water_m3, inputs.matrix_ice_water_m3, inputs.matrix_pore_capacity_m3) |thickness, density, liquid, ice, pore| {
        inline for (.{ thickness, density, liquid, ice, pore }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidPondTransitionLayerState;
    }
}

test "surface pond disappearance selects next material layer without fixed layer count" {
    const transition = (try selectSurfaceTransition(.{
        .first_active_layer = 1,
        .initial_first_active_layer = 0,
        .active_layer_end = 5,
        .uppermost_water_layer = 2,
        .layer_thickness_m = &.{ 0, 0.01, 0, 0.2, 0.3 },
        .bulk_density_megagrams_per_m3 = &.{ 1, 0, 0, 1.2, 1.3 },
        .total_heat_capacity_megajoules_per_k = &.{ 1, 0, 0, 2, 3 },
        .matrix_liquid_water_m3 = &.{ 0, 0.1, 0, 0, 0 },
        .matrix_ice_water_m3 = &.{ 0, 0, 0, 0, 0 },
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .minimum_heat_capacity_megajoules_per_k = 1e-6,
        .minimum_layer_thickness_m = 1e-4,
        .surface_pond_liquid_water_m3 = 0,
        .surface_pond_ice_m3 = 0,
        .surface_ponding_capacity_m3 = 0,
        .surface_litter_volume_m3 = 0,
        .surface_litter_water_capacity_m3 = 0,
        .horizontal_area_m2 = 10,
        .current_surface_boundary_depth_m = 0,
        .initial_surface_boundary_depth_m = 0,
    })).?;
    try std.testing.expectEqual(@as(usize, 3), transition.next_first_active_layer);
    try std.testing.expectEqual(@as(f64, 1), transition.transfer_fraction);
}

test "surface pond reappearance uses explicit surface owner and source water threshold" {
    const transition = (try selectSurfaceTransition(.{
        .first_active_layer = 1,
        .initial_first_active_layer = 0,
        .active_layer_end = 2,
        .uppermost_water_layer = 1,
        .layer_thickness_m = &.{ 0, 0.2 },
        .bulk_density_megagrams_per_m3 = &.{ 0, 1.2 },
        .total_heat_capacity_megajoules_per_k = &.{ 0, 2 },
        .matrix_liquid_water_m3 = &.{ 0, 0.2 },
        .matrix_ice_water_m3 = &.{ 0, 0 },
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .minimum_heat_capacity_megajoules_per_k = 0.0419,
        .minimum_layer_thickness_m = 1e-4,
        .surface_pond_liquid_water_m3 = 0.4,
        .surface_pond_ice_m3 = 0.1,
        .surface_ponding_capacity_m3 = 0.2,
        .surface_litter_volume_m3 = 0.1,
        .surface_litter_water_capacity_m3 = 0.1,
        .horizontal_area_m2 = 10,
        .current_surface_boundary_depth_m = 0.1,
        .initial_surface_boundary_depth_m = 0,
    })).?;
    try std.testing.expectEqual(StorageLocation.surface_pond, transition.source);
    try std.testing.expectEqual(@as(usize, 0), transition.next_first_active_layer);
    const physical_ice_m3 = 0.1 / ice_units.reference_ice_density_megagrams_per_m3;
    const expected_excess_m3 = 0.4 + physical_ice_m3 - 0.2;
    const expected_pond_volume_m3 = 0.4 + physical_ice_m3 - 0.1 + 0.1;
    try std.testing.expectApproxEqAbs(-expected_excess_m3 / 10.0, transition.boundary_change_m, 1e-14);
    try std.testing.expectApproxEqAbs(expected_excess_m3 / expected_pond_volume_m3, transition.transfer_fraction, 1e-14);
}

test "subsurface recharge selects fractional downward transfer" {
    const transition = (try selectSubsurfaceTransition(.{
        .boundary_layer = 0,
        .first_active_layer = 0,
        .layer_thickness_m = &.{ 0.2, 0.1 },
        .bulk_density_megagrams_per_m3 = &.{ 1.2, 0 },
        .matrix_liquid_water_m3 = &.{ 1.2, 0 },
        .matrix_ice_water_m3 = &.{ 0.3, 0 },
        .matrix_pore_capacity_m3 = &.{ 1, 0 },
        .horizontal_area_m2 = 10,
        .minimum_layer_thickness_m = 1e-4,
        .negligible_water_volume_m3 = 1e-12,
    })).?;
    const physical_ice_m3 = 0.3 / ice_units.reference_ice_density_megagrams_per_m3;
    const expected_excess_m3 = 1.2 + physical_ice_m3 - 1.0;
    try std.testing.expectApproxEqAbs(expected_excess_m3 / (1.2 + physical_ice_m3), transition.transfer_fraction, 1e-14);
    try std.testing.expectApproxEqAbs(-expected_excess_m3 / 10.0, transition.boundary_change_m, 1e-14);
}

test "separated surface pond routes to topsoil without changing soil indexing" {
    const transition = (try selectSeparatedSurfacePondTransfer(.{
        .top_soil_layer = 0,
        .surface_pond_liquid_water_m3 = 0.4,
        .surface_pond_ice_m3 = 0.1,
        .surface_ponding_capacity_m3 = 0.2,
        .surface_litter_volume_m3 = 0.1,
        .surface_litter_water_capacity_m3 = 0.1,
        .horizontal_area_m2 = 10,
        .minimum_heat_capacity_megajoules_per_k = 0.0419,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    })).?;
    try std.testing.expectEqual(@as(usize, 0), transition.next_first_active_layer);
    const physical_ice_m3 = 0.1 / ice_units.reference_ice_density_megagrams_per_m3;
    const expected_excess_m3 = 0.4 + physical_ice_m3 - 0.2;
    const expected_pond_volume_m3 = 0.4 + physical_ice_m3 - 0.1 + 0.1;
    try std.testing.expectApproxEqAbs(expected_excess_m3 / expected_pond_volume_m3, transition.transfer_fraction, 1e-14);
}

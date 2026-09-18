const std = @import("std");
const compute = @import("../../core/compute.zig");
const CellRange = compute.CellRange;
const spatial_grid = @import("../../state/spatial_grid.zig");

/// Radiation carried by the direct-solar and four-sector diffuse-sky beams.
/// Shortwave beam values are normal to the beam; horizontal totals include
/// the corresponding angular projection.
pub const Partition = struct {
    direct_shortwave_megajoules_per_m2: f64,
    diffuse_shortwave_megajoules_per_m2: f64,
    direct_par_micromol_per_m2_per_s: f64,
    diffuse_par_micromol_per_m2_per_s: f64,
    horizontal_shortwave_megajoules_per_m2: f64,
    horizontal_par_micromol_per_m2_per_s: f64,
};

/// Heap-backed structure-of-arrays consumed by canopy interception kernels.
pub const State = struct {
    allocator: std.mem.Allocator,
    direct_shortwave_megajoules_per_m2: []f64,
    diffuse_shortwave_megajoules_per_m2: []f64,
    direct_par_micromol_per_m2_per_s: []f64,
    diffuse_par_micromol_per_m2_per_s: []f64,
    horizontal_shortwave_megajoules_per_m2: []f64,
    horizontal_par_micromol_per_m2_per_s: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.EmptyGrid;
        var result: State = undefined;
        result.allocator = allocator;
        result.direct_shortwave_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.direct_shortwave_megajoules_per_m2);
        result.diffuse_shortwave_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.diffuse_shortwave_megajoules_per_m2);
        result.direct_par_micromol_per_m2_per_s = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.direct_par_micromol_per_m2_per_s);
        result.diffuse_par_micromol_per_m2_per_s = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.diffuse_par_micromol_per_m2_per_s);
        result.horizontal_shortwave_megajoules_per_m2 = try allocator.alloc(f64, cell_count);
        errdefer allocator.free(result.horizontal_shortwave_megajoules_per_m2);
        result.horizontal_par_micromol_per_m2_per_s = try allocator.alloc(f64, cell_count);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) @memset(@field(result, field.name), 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn cellCount(self: State) usize {
        return self.horizontal_shortwave_megajoules_per_m2.len;
    }
};

pub const ApplyContext = struct {
    state: *State,
    horizontal_shortwave_megajoules_per_m2: f64,
    extraterrestrial_horizontal_shortwave_megajoules_per_m2: f64,
    solar_angle_sine: f64,
    /// `Geometry.diffuse_sky_horizontal_projection` (Sigma of `sky_sine` over
    /// the caller's actual `diffuse_sky_sector_count`), never a hardcoded
    /// four-sector constant -- see RADIATION-DIFFUSE-SECTOR-COUNT-001.
    diffuse_sky_horizontal_projection: f64,
};

pub const MappedApplyContext = struct {
    state: *State,
    horizontal_shortwave_megajoules_per_m2: []const f64,
    extraterrestrial_horizontal_shortwave_megajoules_per_m2: []const f64,
    solar_angle_sine: []const f64,
    /// `Geometry.diffuse_sky_horizontal_projection` (Sigma of `sky_sine` over
    /// the caller's actual `diffuse_sky_sector_count`), never a hardcoded
    /// four-sector constant -- see RADIATION-DIFFUSE-SECTOR-COUNT-001.
    diffuse_sky_horizontal_projection: f64,
};

/// Allocation-free independent tile for CPU parallelism and future GPU dispatch.
pub fn applyUniformTile(context: *ApplyContext, range: CellRange) !void {
    if (range.end > context.state.cellCount()) return error.CanopyRadiationTileOutOfBounds;
    const value = try partition(context.horizontal_shortwave_megajoules_per_m2, context.extraterrestrial_horizontal_shortwave_megajoules_per_m2, context.solar_angle_sine, context.diffuse_sky_horizontal_projection);
    for (range.first..range.end) |cell| inline for (@typeInfo(Partition).@"struct".fields) |field| {
        @field(context.state.*, field.name)[cell] = @field(value, field.name);
    };
}

pub fn applyMappedTile(context: *MappedApplyContext, range: CellRange) !void {
    const cells = context.state.cellCount();
    if (range.end > cells or context.horizontal_shortwave_megajoules_per_m2.len != cells or
        context.extraterrestrial_horizontal_shortwave_megajoules_per_m2.len != cells or
        context.solar_angle_sine.len != cells)
        return error.CanopyRadiationTileOutOfBounds;
    for (range.first..range.end) |cell| {
        const value = try partition(
            context.horizontal_shortwave_megajoules_per_m2[cell],
            context.extraterrestrial_horizontal_shortwave_megajoules_per_m2[cell],
            context.solar_angle_sine[cell],
            context.diffuse_sky_horizontal_projection,
        );
        inline for (@typeInfo(Partition).@"struct".fields) |field| {
            @field(context.state.*, field.name)[cell] = @field(value, field.name);
        }
    }
}

/// Reference four-sector value (`TYSIN` under the frozen Fortran N=4 sky
/// discretization) for tests only. Production code must take the runtime
/// `Geometry.diffuse_sky_horizontal_projection` instead -- see
/// RADIATION-DIFFUSE-SECTOR-COUNT-001.
const four_sector_diffuse_sky_horizontal_projection = 4.0 * @sin(std.math.pi / 4.0);
const direct_visible_fraction = 0.42;
const diffuse_visible_fraction = 0.58;
const par_micromol_per_m2_per_s_per_megajoule_per_m2 = 1269.4;
const maximum_direct_beam_megajoules_per_m2 = 4.167;

/// Ports the direct/diffuse partition in HOUR1. Inputs are hourly horizontal
/// fluxes after atmospheric-radiation preparation and climate modification.
pub fn partition(
    horizontal_shortwave_megajoules_per_m2: f64,
    extraterrestrial_horizontal_shortwave_megajoules_per_m2: f64,
    solar_angle_sine: f64,
    diffuse_sky_horizontal_projection: f64,
) !Partition {
    if (!std.math.isFinite(horizontal_shortwave_megajoules_per_m2) or
        !std.math.isFinite(extraterrestrial_horizontal_shortwave_megajoules_per_m2) or
        !std.math.isFinite(solar_angle_sine) or
        !std.math.isFinite(diffuse_sky_horizontal_projection)) return error.NonFiniteCanopyRadiation;
    if (horizontal_shortwave_megajoules_per_m2 < 0 or
        extraterrestrial_horizontal_shortwave_megajoules_per_m2 < 0 or
        solar_angle_sine < 0 or solar_angle_sine > 1 or
        diffuse_sky_horizontal_projection <= 0) return error.InvalidCanopyRadiation;

    if (solar_angle_sine == 0) {
        // HOUR1's SSIN <= 0 branch explicitly zeros every canopy radiation
        // output even when the interpolated RADM carrier is nonzero.
        return zeroPartition();
    }
    const diffuse_horizontal_megajoules_per_m2 = std.math.clamp(
        0.5 * (extraterrestrial_horizontal_shortwave_megajoules_per_m2 - horizontal_shortwave_megajoules_per_m2),
        0.0,
        horizontal_shortwave_megajoules_per_m2,
    );
    const direct_beam_megajoules_per_m2 = @min(
        maximum_direct_beam_megajoules_per_m2,
        (horizontal_shortwave_megajoules_per_m2 - diffuse_horizontal_megajoules_per_m2) / solar_angle_sine,
    );
    const diffuse_beam_megajoules_per_m2 = diffuse_horizontal_megajoules_per_m2 / diffuse_sky_horizontal_projection;
    const direct_par = direct_beam_megajoules_per_m2 * direct_visible_fraction * par_micromol_per_m2_per_s_per_megajoule_per_m2;
    const diffuse_par = diffuse_beam_megajoules_per_m2 * diffuse_visible_fraction * par_micromol_per_m2_per_s_per_megajoule_per_m2;
    const reconstructed_shortwave = direct_beam_megajoules_per_m2 * solar_angle_sine + diffuse_beam_megajoules_per_m2 * diffuse_sky_horizontal_projection;
    const horizontal_par = direct_par * solar_angle_sine + diffuse_par * diffuse_sky_horizontal_projection;
    if (!std.math.isFinite(reconstructed_shortwave) or !std.math.isFinite(horizontal_par)) return error.NonFiniteCanopyRadiation;

    return .{
        .direct_shortwave_megajoules_per_m2 = direct_beam_megajoules_per_m2,
        .diffuse_shortwave_megajoules_per_m2 = diffuse_beam_megajoules_per_m2,
        .direct_par_micromol_per_m2_per_s = direct_par,
        .diffuse_par_micromol_per_m2_per_s = diffuse_par,
        .horizontal_shortwave_megajoules_per_m2 = reconstructed_shortwave,
        .horizontal_par_micromol_per_m2_per_s = horizontal_par,
    };
}

fn zeroPartition() Partition {
    return .{
        .direct_shortwave_megajoules_per_m2 = 0,
        .diffuse_shortwave_megajoules_per_m2 = 0,
        .direct_par_micromol_per_m2_per_s = 0,
        .diffuse_par_micromol_per_m2_per_s = 0,
        .horizontal_shortwave_megajoules_per_m2 = 0,
        .horizontal_par_micromol_per_m2_per_s = 0,
    };
}

test "direct and diffuse beams reconstruct ordinary horizontal shortwave" {
    const result = try partition(2.0, 4.0, 0.8, four_sector_diffuse_sky_horizontal_projection);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), result.horizontal_shortwave_megajoules_per_m2, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), result.direct_shortwave_megajoules_per_m2, 1.0e-12);
    try std.testing.expect(result.diffuse_shortwave_megajoules_per_m2 > 0);
    try std.testing.expect(result.horizontal_par_micromol_per_m2_per_s > 0);
}

test "diffuse beam reconstruction is invariant to the sky-sector-count normalizer" {
    // The same horizontal input must reconstruct to the same horizontal
    // output regardless of how many sky sectors the runtime `Geometry` was
    // configured with -- only the intermediate per-sector beam should scale.
    const four_sector = try partition(2.0, 4.0, 0.8, four_sector_diffuse_sky_horizontal_projection);
    const six_sector_projection = 6.0 * @sin(std.math.pi / 4.0);
    const six_sector = try partition(2.0, 4.0, 0.8, six_sector_projection);
    try std.testing.expectApproxEqAbs(four_sector.horizontal_shortwave_megajoules_per_m2, six_sector.horizontal_shortwave_megajoules_per_m2, 1.0e-12);
    try std.testing.expectApproxEqAbs(four_sector.diffuse_shortwave_megajoules_per_m2 * four_sector_diffuse_sky_horizontal_projection, six_sector.diffuse_shortwave_megajoules_per_m2 * six_sector_projection, 1.0e-12);
}

test "HOUR1 night branch zeros even a nonzero interpolated shortwave carrier" {
    const night = try partition(0, 0, 0, four_sector_diffuse_sky_horizontal_projection);
    try std.testing.expectEqual(@as(f64, 0), night.horizontal_par_micromol_per_m2_per_s);
    const nonzero_carrier = try partition(0.1, 0.1, 0, four_sector_diffuse_sky_horizontal_projection);
    try std.testing.expectEqual(@as(f64, 0), nonzero_carrier.horizontal_shortwave_megajoules_per_m2);
}

test "invalid and nonfinite radiation fail immediately" {
    try std.testing.expectError(error.NonFiniteCanopyRadiation, partition(std.math.nan(f64), 1, 0.5, four_sector_diffuse_sky_horizontal_projection));
    try std.testing.expectError(error.InvalidCanopyRadiation, partition(0, 1, 1.1, four_sector_diffuse_sky_horizontal_projection));
    try std.testing.expectError(error.InvalidCanopyRadiation, partition(0, 1, 0.5, 0));
}

test "serial tiles populate radiation with owned-cell parallelism" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator, 10_003);
    defer state.deinit();
    var context: ApplyContext = .{
        .state = &state,
        .horizontal_shortwave_megajoules_per_m2 = 2,
        .extraterrestrial_horizontal_shortwave_megajoules_per_m2 = 4,
        .solar_angle_sine = 0.8,
        .diffuse_sky_horizontal_projection = four_sector_diffuse_sky_horizontal_projection,
    };
    var plan = try spatial_grid.TilePlan.init(allocator, 1, state.cellCount(), 1, 113, 2);
    defer plan.deinit();
    const executor = try compute.CpuExecutor.init(allocator, 7, plan.ownedCellExecutorPlan());
    defer executor.deinit();
    for (plan.tiles, 0..) |_, tile_index|
        try executor.runOwnedCells(try plan.ownedCellTile(tile_index), &context, applyUniformTile);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.horizontal_shortwave_megajoules_per_m2[10_002], 1.0e-12);
    try std.testing.expect(state.horizontal_par_micromol_per_m2_per_s[10_002] > 0);
}

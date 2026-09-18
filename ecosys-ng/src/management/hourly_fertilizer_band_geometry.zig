const std = @import("std");

/// Persistent geometry for one nutrient family's fertilizer band in one cell.
/// Every slice is indexed by runtime soil layer.
pub const State = struct {
    active: bool,
    row_spacing_m: f64,
    upper_edge_depth_m: f64,
    lower_edge_depth_m: f64,
    band_depth_m: []f64,
    band_width_m: []f64,
    band_volume_fraction: []f64,
    non_band_volume_fraction: []f64,
};

pub const LayerGeometry = struct {
    upper_depth_m: []const f64,
    lower_depth_m: []const f64,
    thickness_m: []const f64,
    first_active_layer: usize,
    last_active_layer: usize,
    minimum_active_thickness_m: f64,
    structural_presence_threshold: f64,
};

pub const Forcing = struct {
    diffusivity_m2_per_h: []const f64,
    tortuosity: []const f64,
    timestep_h: f64,
    maximum_band_volume_fraction: f64 = 0.9999,
};

pub const Output = struct {
    /// Fortran FVL*: relative change in the non-band fraction (step-1).
    relative_non_band_change: []f64,
    /// True where the inactive-band branch requires inventory amalgamation.
    band_disappeared: []bool,
};

/// Heap-backed staging prevents partial mutation if any derived value fails.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    band_depth_m: []f64,
    band_width_m: []f64,
    band_volume_fraction: []f64,
    non_band_volume_fraction: []f64,
    relative_non_band_change: []f64,
    band_disappeared: []bool,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !Workspace {
        if (layer_count == 0) return error.ZeroFertilizerBandLayerCount;
        const depth = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(depth);
        const width = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(width);
        const band = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(band);
        const non_band = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(non_band);
        const relative = try allocator.alloc(f64, layer_count);
        errdefer allocator.free(relative);
        const disappeared = try allocator.alloc(bool, layer_count);
        return .{
            .allocator = allocator,
            .band_depth_m = depth,
            .band_width_m = width,
            .band_volume_fraction = band,
            .non_band_volume_fraction = non_band,
            .relative_non_band_change = relative,
            .band_disappeared = disappeared,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.band_disappeared);
        self.allocator.free(self.relative_non_band_change);
        self.allocator.free(self.non_band_volume_fraction);
        self.allocator.free(self.band_volume_fraction);
        self.allocator.free(self.band_width_m);
        self.allocator.free(self.band_depth_m);
        self.* = undefined;
    }
};

/// Applies the shared NH4, NO3, or PO4 band-growth equations.
///
/// Traceability: HOUR1 (`hour1.f`) lines 4888-5151. The caller invokes this
/// independently for each nutrient family with that family's diffusivity.
/// Layer traversal and every in-place dependency retain source order.
pub fn update(
    state: *State,
    geometry: LayerGeometry,
    forcing: Forcing,
    output: Output,
    workspace: *Workspace,
) !void {
    try validate(state.*, geometry, forcing, output, workspace);
    @memcpy(workspace.band_depth_m, state.band_depth_m);
    @memcpy(workspace.band_width_m, state.band_width_m);
    @memcpy(workspace.band_volume_fraction, state.band_volume_fraction);
    @memcpy(workspace.non_band_volume_fraction, state.non_band_volume_fraction);
    @memset(workspace.relative_non_band_change, 0);
    @memset(workspace.band_disappeared, false);

    var upper_edge_m = state.upper_edge_depth_m;
    var lower_edge_m = state.lower_edge_depth_m;
    var layer = geometry.first_active_layer;
    while (layer <= geometry.last_active_layer) : (layer += 1) {
        if (state.active and state.row_spacing_m > 0 and
            (layer == geometry.first_active_layer or
                geometry.upper_depth_m[layer] < lower_edge_m))
        {
            const growth_m = if (workspace.band_depth_m[layer] > 0)
                0.5 * @sqrt(forcing.diffusivity_m2_per_h[layer] *
                    forcing.tortuosity[layer]) * forcing.timestep_h
            else
                0;
            workspace.band_width_m[layer] =
                @min(
                    state.row_spacing_m,
                    workspace.band_width_m[layer] + growth_m,
                );

            if (containsDepth(geometry, layer, upper_edge_m)) {
                upper_edge_m = @max(0, upper_edge_m - growth_m);
                workspace.band_depth_m[layer] = @min(
                    geometry.thickness_m[layer],
                    workspace.band_depth_m[layer] + growth_m,
                );
            }
            if (layer > geometry.first_active_layer and
                upper_edge_m < geometry.upper_depth_m[layer] and
                workspace.band_volume_fraction[layer - 1] <
                    geometry.structural_presence_threshold)
            {
                workspace.band_depth_m[layer - 1] =
                    geometry.upper_depth_m[layer] - upper_edge_m;
                workspace.band_width_m[layer - 1] =
                    workspace.band_width_m[layer];
            }
            if (containsDepth(geometry, layer, lower_edge_m)) {
                lower_edge_m += growth_m;
                workspace.band_depth_m[layer] = @min(
                    geometry.thickness_m[layer],
                    workspace.band_depth_m[layer] + growth_m,
                );
            }
            if (lower_edge_m > geometry.lower_depth_m[layer] and
                upper_edge_m <= geometry.upper_depth_m[layer])
            {
                if (layer == geometry.last_active_layer)
                    return error.FertilizerBandGrowthBelowProfile;
                if (workspace.band_volume_fraction[layer + 1] <
                    geometry.structural_presence_threshold)
                {
                    workspace.band_width_m[layer + 1] =
                        workspace.band_width_m[layer];
                    workspace.band_depth_m[layer + 1] =
                        lower_edge_m - geometry.lower_depth_m[layer];
                }
            }

            const old_non_band = workspace.non_band_volume_fraction[layer];
            if (old_non_band <= 0) return error.InvalidFertilizerNonBandFraction;
            const band_fraction = if (geometry.thickness_m[layer] >
                geometry.minimum_active_thickness_m)
                @max(0, @min(
                    forcing.maximum_band_volume_fraction,
                    workspace.band_width_m[layer] / state.row_spacing_m *
                        workspace.band_depth_m[layer] /
                        geometry.thickness_m[layer],
                ))
            else
                0;
            const non_band_fraction = 1 - band_fraction;
            workspace.band_volume_fraction[layer] = band_fraction;
            workspace.non_band_volume_fraction[layer] = non_band_fraction;
            workspace.relative_non_band_change[layer] =
                @min(0, (non_band_fraction - old_non_band) / old_non_band);
        } else {
            workspace.band_depth_m[layer] = 0;
            workspace.band_width_m[layer] = 0;
            workspace.band_volume_fraction[layer] = 0;
            workspace.non_band_volume_fraction[layer] = 1;
            workspace.band_disappeared[layer] = true;
        }
        try validateDerivedLayer(workspace, layer);
    }

    @memcpy(state.band_depth_m, workspace.band_depth_m);
    @memcpy(state.band_width_m, workspace.band_width_m);
    @memcpy(state.band_volume_fraction, workspace.band_volume_fraction);
    @memcpy(state.non_band_volume_fraction, workspace.non_band_volume_fraction);
    @memcpy(output.relative_non_band_change, workspace.relative_non_band_change);
    @memcpy(output.band_disappeared, workspace.band_disappeared);
    state.upper_edge_depth_m = upper_edge_m;
    state.lower_edge_depth_m = lower_edge_m;
}

fn containsDepth(geometry: LayerGeometry, layer: usize, depth_m: f64) bool {
    return geometry.lower_depth_m[layer] >= depth_m and
        geometry.upper_depth_m[layer] < depth_m;
}

fn validate(
    state: State,
    geometry: LayerGeometry,
    forcing: Forcing,
    output: Output,
    workspace: *const Workspace,
) !void {
    const count = state.band_depth_m.len;
    if (count == 0 or state.band_width_m.len != count or
        state.band_volume_fraction.len != count or
        state.non_band_volume_fraction.len != count or
        geometry.upper_depth_m.len != count or
        geometry.lower_depth_m.len != count or
        geometry.thickness_m.len != count or
        forcing.diffusivity_m2_per_h.len != count or
        forcing.tortuosity.len != count or
        output.relative_non_band_change.len != count or
        output.band_disappeared.len != count or
        workspace.band_depth_m.len != count or
        workspace.band_width_m.len != count or
        workspace.band_volume_fraction.len != count or
        workspace.non_band_volume_fraction.len != count or
        workspace.relative_non_band_change.len != count or
        workspace.band_disappeared.len != count)
        return error.FertilizerBandDimensionMismatch;
    if (geometry.first_active_layer > geometry.last_active_layer or
        geometry.last_active_layer >= count)
        return error.InvalidFertilizerBandLayerRange;
    inline for (.{
        state.row_spacing_m,
        state.upper_edge_depth_m,
        state.lower_edge_depth_m,
        geometry.minimum_active_thickness_m,
        geometry.structural_presence_threshold,
        forcing.timestep_h,
        forcing.maximum_band_volume_fraction,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteFertilizerBandInput;
    if (state.row_spacing_m < 0 or state.upper_edge_depth_m < 0 or
        state.lower_edge_depth_m < state.upper_edge_depth_m or
        geometry.minimum_active_thickness_m < 0 or
        geometry.structural_presence_threshold < 0 or
        forcing.timestep_h < 0 or
        forcing.maximum_band_volume_fraction <= 0 or
        forcing.maximum_band_volume_fraction >= 1)
        return error.InvalidFertilizerBandInput;
    if (state.active and state.row_spacing_m <= 0)
        return error.InvalidActiveFertilizerBandRowSpacing;

    for (0..count) |layer| {
        inline for (.{
            state.band_depth_m[layer],
            state.band_width_m[layer],
            state.band_volume_fraction[layer],
            state.non_band_volume_fraction[layer],
            geometry.upper_depth_m[layer],
            geometry.lower_depth_m[layer],
            geometry.thickness_m[layer],
            forcing.diffusivity_m2_per_h[layer],
            forcing.tortuosity[layer],
        }) |value| if (!std.math.isFinite(value))
            return error.NonFiniteFertilizerBandInput;
        if (state.band_depth_m[layer] < 0 or state.band_width_m[layer] < 0 or
            state.band_volume_fraction[layer] < 0 or
            state.band_volume_fraction[layer] >= 1 or
            state.non_band_volume_fraction[layer] <= 0 or
            state.non_band_volume_fraction[layer] > 1 or
            @abs(state.band_volume_fraction[layer] +
                state.non_band_volume_fraction[layer] - 1) > 1e-12 or
            geometry.upper_depth_m[layer] < 0 or
            geometry.lower_depth_m[layer] < geometry.upper_depth_m[layer] or
            geometry.thickness_m[layer] <= 0 or
            forcing.diffusivity_m2_per_h[layer] < 0 or
            forcing.tortuosity[layer] < 0)
            return error.InvalidFertilizerBandInput;
    }
}

fn validateDerivedLayer(
    workspace: *const Workspace,
    layer: usize,
) !void {
    inline for (.{
        workspace.band_depth_m[layer],
        workspace.band_width_m[layer],
        workspace.band_volume_fraction[layer],
        workspace.non_band_volume_fraction[layer],
        workspace.relative_non_band_change[layer],
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteFertilizerBandResult;
    if (workspace.band_depth_m[layer] < 0 or
        workspace.band_width_m[layer] < 0 or
        workspace.band_volume_fraction[layer] < 0 or
        workspace.band_volume_fraction[layer] >= 1 or
        workspace.non_band_volume_fraction[layer] <= 0 or
        workspace.non_band_volume_fraction[layer] > 1 or
        workspace.relative_non_band_change[layer] > 0)
        return error.InvalidFertilizerBandResult;
}

fn makeState(
    depth: []f64,
    width: []f64,
    band: []f64,
    non_band: []f64,
) State {
    return .{
        .active = true,
        .row_spacing_m = 0.1,
        .upper_edge_depth_m = 0.04,
        .lower_edge_depth_m = 0.06,
        .band_depth_m = depth,
        .band_width_m = width,
        .band_volume_fraction = band,
        .non_band_volume_fraction = non_band,
    };
}

test "diffusion grows width and depth in source operation order" {
    var depth = [_]f64{ 0.02, 0 };
    var width = [_]f64{ 0.02, 0 };
    var band = [_]f64{ 0.004, 0 };
    var non_band = [_]f64{ 0.996, 1 };
    var relative = [_]f64{ 0, 0 };
    var disappeared = [_]bool{ false, false };
    var state = makeState(&depth, &width, &band, &non_band);
    var workspace = try Workspace.init(std.testing.allocator, 2);
    defer workspace.deinit();

    // 0.5 * sqrt(0.0001 * 1) * 1 h = 0.005 m.
    try update(&state, .{
        .upper_depth_m = &.{ 0, 0.1 },
        .lower_depth_m = &.{ 0.1, 0.2 },
        .thickness_m = &.{ 0.1, 0.1 },
        .first_active_layer = 0,
        .last_active_layer = 1,
        .minimum_active_thickness_m = 1e-6,
        .structural_presence_threshold = 1e-12,
    }, .{
        .diffusivity_m2_per_h = &.{ 0.0001, 0.0001 },
        .tortuosity = &.{ 1, 1 },
        .timestep_h = 1,
    }, .{
        .relative_non_band_change = &relative,
        .band_disappeared = &disappeared,
    }, &workspace);

    try std.testing.expectApproxEqAbs(@as(f64, 0.03), depth[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.025), width[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.075), band[0], 1e-15);
    try std.testing.expectApproxEqAbs(
        (@as(f64, 0.925) - 0.996) / 0.996,
        relative[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.035), state.upper_edge_depth_m, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.065), state.lower_edge_depth_m, 1e-15);
}

test "growth activates and then processes adjacent lower layer in source order" {
    var depth = [_]f64{ 0.1, 0 };
    var width = [_]f64{ 0.02, 0 };
    var band = [_]f64{ 0.2, 0 };
    var non_band = [_]f64{ 0.8, 1 };
    var relative = [_]f64{ 0, 0 };
    var disappeared = [_]bool{ false, false };
    var state = makeState(&depth, &width, &band, &non_band);
    state.upper_edge_depth_m = 0;
    state.lower_edge_depth_m = 0.1;
    var workspace = try Workspace.init(std.testing.allocator, 2);
    defer workspace.deinit();

    try update(&state, .{
        .upper_depth_m = &.{ 0, 0.1 },
        .lower_depth_m = &.{ 0.1, 0.2 },
        .thickness_m = &.{ 0.1, 0.1 },
        .first_active_layer = 0,
        .last_active_layer = 1,
        .minimum_active_thickness_m = 0,
        .structural_presence_threshold = 1e-12,
    }, .{
        .diffusivity_m2_per_h = &.{ 0.0001, 0.0001 },
        .tortuosity = &.{ 1, 1 },
        .timestep_h = 1,
    }, .{
        .relative_non_band_change = &relative,
        .band_disappeared = &disappeared,
    }, &workspace);

    try std.testing.expectApproxEqAbs(@as(f64, 0.01), depth[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), width[1], 1e-15);
    // The newly activated layer is processed when its source-order turn begins.
    try std.testing.expectApproxEqAbs(@as(f64, 0.03), band[1], 1e-15);
}

test "row spacing and volume fraction bounds are enforced" {
    var depth = [_]f64{0.1};
    var width = [_]f64{0.099};
    var band = [_]f64{0.99};
    var non_band = [_]f64{0.01};
    var relative = [_]f64{0};
    var disappeared = [_]bool{false};
    var state = makeState(&depth, &width, &band, &non_band);
    state.upper_edge_depth_m = 0.01;
    state.lower_edge_depth_m = 0.09;
    var workspace = try Workspace.init(std.testing.allocator, 1);
    defer workspace.deinit();

    try update(&state, .{
        .upper_depth_m = &.{0},
        .lower_depth_m = &.{0.1},
        .thickness_m = &.{0.1},
        .first_active_layer = 0,
        .last_active_layer = 0,
        .minimum_active_thickness_m = 0,
        .structural_presence_threshold = 0,
    }, .{
        .diffusivity_m2_per_h = &.{0},
        .tortuosity = &.{1},
        .timestep_h = 1,
    }, .{
        .relative_non_band_change = &relative,
        .band_disappeared = &disappeared,
    }, &workspace);
    try std.testing.expectEqual(@as(f64, 0.099), width[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.99), band[0], 1e-15);
}

test "non-finite forcing is rejected before state mutation" {
    var depth = [_]f64{0.02};
    var width = [_]f64{0.02};
    var band = [_]f64{0.004};
    var non_band = [_]f64{0.996};
    const before = depth;
    var relative = [_]f64{0};
    var disappeared = [_]bool{false};
    var state = makeState(&depth, &width, &band, &non_band);
    var workspace = try Workspace.init(std.testing.allocator, 1);
    defer workspace.deinit();
    try std.testing.expectError(error.NonFiniteFertilizerBandInput, update(
        &state,
        .{
            .upper_depth_m = &.{0},
            .lower_depth_m = &.{0.1},
            .thickness_m = &.{0.1},
            .first_active_layer = 0,
            .last_active_layer = 0,
            .minimum_active_thickness_m = 0,
            .structural_presence_threshold = 0,
        },
        .{
            .diffusivity_m2_per_h = &.{std.math.nan(f64)},
            .tortuosity = &.{1},
            .timestep_h = 1,
        },
        .{
            .relative_non_band_change = &relative,
            .band_disappeared = &disappeared,
        },
        &workspace,
    ));
    try std.testing.expectEqualSlices(f64, &before, &depth);
}

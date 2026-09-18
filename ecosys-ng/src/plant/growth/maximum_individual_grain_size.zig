const std = @import("std");

pub const State = struct {
    individual_grain_carbon_g_c: []f64,
};

pub const Inputs = struct {
    first_branch: usize,
    end_branch: usize,
    grain_fill_started: []const bool,
    maximum_grain_size_set: []const bool,
    nutrient_set_fraction: []const f64,
    reproductive_stage_increment: []const f64,
    water_growth_fraction: f64,
    maximum_individual_grain_carbon_g_c: f64,
};

/// grosub.f lines 4155--4164. Updates maximum individual grain size for runtime
/// branches after grain filling starts and before final size is set. SETW keeps
/// exact `(SET * WFNSG)**0.25` order and the source minimum response of 0.50.
pub fn apply(state: State, workspace_grain_carbon_g_c: []f64, inputs: Inputs) !void {
    const branch_count = state.individual_grain_carbon_g_c.len;
    inline for (.{ inputs.grain_fill_started, inputs.maximum_grain_size_set }) |values|
        if (values.len != branch_count) return error.GrainSizeDimensionMismatch;
    inline for (.{ inputs.nutrient_set_fraction, inputs.reproductive_stage_increment }) |values|
        if (values.len != branch_count) return error.GrainSizeDimensionMismatch;
    if (workspace_grain_carbon_g_c.len < branch_count) return error.GrainSizeWorkspaceTooSmall;
    if (inputs.first_branch > inputs.end_branch or inputs.end_branch > branch_count)
        return error.GrainSizeBranchRangeOutOfBounds;
    inline for (.{ inputs.water_growth_fraction, inputs.maximum_individual_grain_carbon_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidGrainSizeInput;

    @memcpy(workspace_grain_carbon_g_c[0..branch_count], state.individual_grain_carbon_g_c);
    for (inputs.first_branch..inputs.end_branch) |branch| {
        const current_g_c = workspace_grain_carbon_g_c[branch];
        const nutrient_set = inputs.nutrient_set_fraction[branch];
        const stage_increment = inputs.reproductive_stage_increment[branch];
        inline for (.{ current_g_c, nutrient_set, stage_increment }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidGrainSizeState;
        if (nutrient_set > 1) return error.InvalidGrainSizeState;
        if (!inputs.grain_fill_started[branch] or inputs.maximum_grain_size_set[branch]) continue;

        const nutrient_water_set = std.math.pow(f64, nutrient_set * inputs.water_growth_fraction, 0.25);
        const updated_g_c = @min(
            inputs.maximum_individual_grain_carbon_g_c,
            current_g_c + inputs.maximum_individual_grain_carbon_g_c *
                @max(0.50, nutrient_water_set) * stage_increment,
        );
        if (!std.math.isFinite(nutrient_water_set) or nutrient_water_set < 0 or
            !std.math.isFinite(updated_g_c) or updated_g_c < 0)
            return error.InvalidGrainSizeResult;
        workspace_grain_carbon_g_c[branch] = updated_g_c;
    }
    @memcpy(state.individual_grain_carbon_g_c, workspace_grain_carbon_g_c[0..branch_count]);
}

test "runtime branches use fourth root of nutrient-water product" {
    var grain_size = [_]f64{ 0.1, 0.2 };
    var workspace: [2]f64 = undefined;
    try apply(.{ .individual_grain_carbon_g_c = &grain_size }, &workspace, .{
        .first_branch = 0,
        .end_branch = 2,
        .grain_fill_started = &.{ true, true },
        .maximum_grain_size_set = &.{ false, false },
        .nutrient_set_fraction = &.{ 0.25, 1 },
        .reproductive_stage_increment = &.{ 0.1, 0.2 },
        .water_growth_fraction = 0.25,
        .maximum_individual_grain_carbon_g_c = 1,
    });
    // (0.25*0.25)^0.25=0.5; (1*0.25)^0.25=sqrt(0.5).
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), grain_size[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2 + 0.2 * std.math.sqrt(0.5)), grain_size[1], 1e-15);
}

test "stage gates leave individual size unchanged" {
    var grain_size = [_]f64{ 0.1, 0.2 };
    var workspace: [2]f64 = undefined;
    try apply(.{ .individual_grain_carbon_g_c = &grain_size }, &workspace, .{
        .first_branch = 0,
        .end_branch = 2,
        .grain_fill_started = &.{ false, true },
        .maximum_grain_size_set = &.{ false, true },
        .nutrient_set_fraction = &.{ 1, 1 },
        .reproductive_stage_increment = &.{ 1, 1 },
        .water_growth_fraction = 1,
        .maximum_individual_grain_carbon_g_c = 1,
    });
    try std.testing.expectEqualSlices(f64, &.{ 0.1, 0.2 }, &grain_size);
}

test "maximum grain carbon cap is exact" {
    var grain_size = [_]f64{0.9};
    var workspace: [1]f64 = undefined;
    try apply(.{ .individual_grain_carbon_g_c = &grain_size }, &workspace, .{ .first_branch = 0, .end_branch = 1, .grain_fill_started = &.{true}, .maximum_grain_size_set = &.{false}, .nutrient_set_fraction = &.{1}, .reproductive_stage_increment = &.{1}, .water_growth_fraction = 1, .maximum_individual_grain_carbon_g_c = 1 });
    try std.testing.expectEqual(@as(f64, 1), grain_size[0]);
}

test "runtime branch thirty is supported" {
    var grain_size: [31]f64 = @splat(0);
    var started: [31]bool = @splat(false);
    var finished: [31]bool = @splat(false);
    var set: [31]f64 = @splat(0);
    var increment: [31]f64 = @splat(0);
    var workspace: [31]f64 = undefined;
    started[30] = true;
    set[30] = 1;
    increment[30] = 0.1;
    try apply(.{ .individual_grain_carbon_g_c = &grain_size }, &workspace, .{ .first_branch = 30, .end_branch = 31, .grain_fill_started = &started, .maximum_grain_size_set = &finished, .nutrient_set_fraction = &set, .reproductive_stage_increment = &increment, .water_growth_fraction = 1, .maximum_individual_grain_carbon_g_c = 1 });
    try std.testing.expectEqual(@as(f64, 0.1), grain_size[30]);
}

test "late invalid branch leaves all sizes unchanged" {
    var grain_size = [_]f64{ 0.1, 0.2 };
    var workspace: [2]f64 = undefined;
    try std.testing.expectError(error.InvalidGrainSizeState, apply(
        .{ .individual_grain_carbon_g_c = &grain_size },
        &workspace,
        .{ .first_branch = 0, .end_branch = 2, .grain_fill_started = &.{ true, true }, .maximum_grain_size_set = &.{ false, false }, .nutrient_set_fraction = &.{ 1, std.math.nan(f64) }, .reproductive_stage_increment = &.{ 0.1, 0.1 }, .water_growth_fraction = 1, .maximum_individual_grain_carbon_g_c = 1 },
    ));
    try std.testing.expectEqualSlices(f64, &.{ 0.1, 0.2 }, &grain_size);
}

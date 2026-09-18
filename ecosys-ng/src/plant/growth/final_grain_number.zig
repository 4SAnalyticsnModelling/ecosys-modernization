const std = @import("std");

pub const State = struct { grain_count: []f64 };
pub const Workspace = struct {
    grain_count: []f64,
    nutrient_set_fraction: []f64,
    thermal_loss_fraction: []f64,
};
pub const Inputs = struct {
    first_branch: usize,
    end_branch: usize,
    anthesis_started: []const bool,
    grain_fill_started: []const bool,
    final_grain_number_set: []const bool,
    maximum_grain_size_set: []const bool,
    mobile_carbon_g_c_per_g_c: []const f64,
    mobile_nitrogen_g_n_per_g_c: []const f64,
    mobile_phosphorus_g_p_per_g_c: []const f64,
    potential_seed_sites: []const f64,
    reproductive_stage_increment: []const f64,
    carbon_half_saturation_g_c_per_g_c: f64,
    nitrogen_half_saturation_g_n_per_g_c: f64,
    phosphorus_half_saturation_g_p_per_g_c: f64,
    canopy_temperature_c: f64,
    chilling_temperature_c: f64,
    high_temperature_c: f64,
    seed_loss_fraction_per_c_h: f64,
    timestep_h: f64,
    water_growth_fraction: f64,
    maximum_seeds_per_site: f64,
};

/// grosub.f lines 4105--4141. Computes nutrient SET, stage-gated thermal loss,
/// and final grain number for runtime branches. SETG retains exact
/// `SET * WFNSG**0.25` order. All branches validate before state state_update.
pub fn apply(state: State, workspace: Workspace, inputs: Inputs) !void {
    const count = state.grain_count.len;
    inline for (.{ inputs.anthesis_started, inputs.grain_fill_started, inputs.final_grain_number_set, inputs.maximum_grain_size_set }) |values| if (values.len != count) return error.FinalGrainNumberDimensionMismatch;
    inline for (.{ inputs.mobile_carbon_g_c_per_g_c, inputs.mobile_nitrogen_g_n_per_g_c, inputs.mobile_phosphorus_g_p_per_g_c, inputs.potential_seed_sites, inputs.reproductive_stage_increment }) |values| if (values.len != count) return error.FinalGrainNumberDimensionMismatch;
    inline for (.{ workspace.grain_count, workspace.nutrient_set_fraction, workspace.thermal_loss_fraction }) |values| if (values.len < count) return error.FinalGrainNumberWorkspaceTooSmall;
    if (inputs.first_branch > inputs.end_branch or inputs.end_branch > count) return error.FinalGrainNumberBranchRangeOutOfBounds;
    inline for (.{ inputs.carbon_half_saturation_g_c_per_g_c, inputs.nitrogen_half_saturation_g_n_per_g_c, inputs.phosphorus_half_saturation_g_p_per_g_c, inputs.canopy_temperature_c, inputs.chilling_temperature_c, inputs.high_temperature_c, inputs.seed_loss_fraction_per_c_h, inputs.timestep_h, inputs.water_growth_fraction, inputs.maximum_seeds_per_site }) |value| if (!std.math.isFinite(value)) return error.NonFiniteFinalGrainNumberInput;
    if (inputs.carbon_half_saturation_g_c_per_g_c < 0 or inputs.nitrogen_half_saturation_g_n_per_g_c < 0 or inputs.phosphorus_half_saturation_g_p_per_g_c < 0 or inputs.seed_loss_fraction_per_c_h < 0 or inputs.timestep_h <= 0 or inputs.water_growth_fraction < 0 or inputs.maximum_seeds_per_site < 0) return error.InvalidFinalGrainNumberInput;

    @memcpy(workspace.grain_count[0..count], state.grain_count);
    @memset(workspace.nutrient_set_fraction[0..count], 0);
    @memset(workspace.thermal_loss_fraction[0..count], 0);
    for (inputs.first_branch..inputs.end_branch) |branch| {
        inline for (.{ workspace.grain_count[branch], inputs.mobile_carbon_g_c_per_g_c[branch], inputs.mobile_nitrogen_g_n_per_g_c[branch], inputs.mobile_phosphorus_g_p_per_g_c[branch], inputs.potential_seed_sites[branch], inputs.reproductive_stage_increment[branch] }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidFinalGrainNumberState;
        if (!inputs.anthesis_started[branch] or inputs.maximum_grain_size_set[branch]) continue;
        const set_c = try saturation(inputs.mobile_carbon_g_c_per_g_c[branch], inputs.carbon_half_saturation_g_c_per_g_c);
        const set_n = try saturation(inputs.mobile_nitrogen_g_n_per_g_c[branch], inputs.nitrogen_half_saturation_g_n_per_g_c);
        const set_p = try saturation(inputs.mobile_phosphorus_g_p_per_g_c[branch], inputs.phosphorus_half_saturation_g_p_per_g_c);
        const nutrient_set = @min(set_c, @min(set_n, set_p));
        workspace.nutrient_set_fraction[branch] = nutrient_set;

        var thermal_loss: f64 = 0;
        if (!inputs.grain_fill_started[branch] or !inputs.final_grain_number_set[branch]) {
            if (inputs.canopy_temperature_c < inputs.chilling_temperature_c)
                thermal_loss = inputs.seed_loss_fraction_per_c_h * (inputs.chilling_temperature_c - inputs.canopy_temperature_c) * inputs.timestep_h
            else if (inputs.canopy_temperature_c > inputs.high_temperature_c)
                thermal_loss = inputs.seed_loss_fraction_per_c_h * (inputs.canopy_temperature_c - inputs.high_temperature_c) * inputs.timestep_h;
        }
        if (!std.math.isFinite(thermal_loss) or thermal_loss < 0) return error.InvalidFinalGrainNumberResult;
        workspace.thermal_loss_fraction[branch] = thermal_loss;

        if (!inputs.final_grain_number_set[branch]) {
            const set_with_water = nutrient_set * std.math.pow(f64, inputs.water_growth_fraction, 0.25);
            const maximum_grains = inputs.maximum_seeds_per_site * inputs.potential_seed_sites[branch];
            const updated = @min(maximum_grains, workspace.grain_count[branch] +
                (maximum_grains * set_with_water * inputs.reproductive_stage_increment[branch] - thermal_loss * workspace.grain_count[branch]));
            if (!std.math.isFinite(updated) or updated < 0) return error.InvalidFinalGrainNumberResult;
            workspace.grain_count[branch] = updated;
        }
    }
    @memcpy(state.grain_count, workspace.grain_count[0..count]);
}

fn saturation(concentration: f64, half_saturation: f64) !f64 {
    const denominator = concentration + half_saturation;
    if (denominator <= 0) return error.InvalidFinalGrainNumberSaturation;
    const result = concentration / denominator;
    if (!std.math.isFinite(result) or result < 0) return error.InvalidFinalGrainNumberSaturation;
    return result;
}

fn testInputs() Inputs {
    return .{ .first_branch = 0, .end_branch = 2, .anthesis_started = &.{ true, true }, .grain_fill_started = &.{ false, true }, .final_grain_number_set = &.{ false, false }, .maximum_grain_size_set = &.{ false, false }, .mobile_carbon_g_c_per_g_c = &.{ 0.2, 0.2 }, .mobile_nitrogen_g_n_per_g_c = &.{ 0.1, 0.1 }, .mobile_phosphorus_g_p_per_g_c = &.{ 0.05, 0.05 }, .potential_seed_sites = &.{ 10, 20 }, .reproductive_stage_increment = &.{ 0.1, 0.2 }, .carbon_half_saturation_g_c_per_g_c = 0.2, .nitrogen_half_saturation_g_n_per_g_c = 0.1, .phosphorus_half_saturation_g_p_per_g_c = 0.05, .canopy_temperature_c = 42, .chilling_temperature_c = 5, .high_temperature_c = 40, .seed_loss_fraction_per_c_h = 0.01, .timestep_h = 1, .water_growth_fraction = 1, .maximum_seeds_per_site = 4 };
}

test "runtime branches preserve nutrient water thermal source order" {
    var grains = [_]f64{ 10, 10 };
    var wg: [2]f64 = undefined;
    var ws: [2]f64 = undefined;
    var wt: [2]f64 = undefined;
    try apply(.{ .grain_count = &grains }, .{ .grain_count = &wg, .nutrient_set_fraction = &ws, .thermal_loss_fraction = &wt }, testInputs());
    try std.testing.expectEqual(@as(f64, 0.5), ws[0]);
    try std.testing.expectEqual(@as(f64, 0.02), wt[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 11.8), grains[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 17.8), grains[1], 1e-15);
}
test "maximum-size-set outer gate leaves branch untouched" {
    var grains = [_]f64{ 10, 10 };
    var wg: [2]f64 = undefined;
    var ws: [2]f64 = undefined;
    var wt: [2]f64 = undefined;
    var input = testInputs();
    input.maximum_grain_size_set = &.{ true, false };
    try apply(.{ .grain_count = &grains }, .{ .grain_count = &wg, .nutrient_set_fraction = &ws, .thermal_loss_fraction = &wt }, input);
    try std.testing.expectEqual(@as(f64, 10), grains[0]);
    try std.testing.expectEqual(@as(f64, 0), ws[0]);
}
test "runtime branch thirty is supported" {
    var grains: [31]f64 = @splat(0);
    var b: [31]bool = @splat(false);
    var v: [31]f64 = @splat(0);
    var wg: [31]f64 = undefined;
    var ws: [31]f64 = undefined;
    var wt: [31]f64 = undefined;
    b[30] = true;
    v[30] = 1;
    var input = testInputs();
    input.first_branch = 30;
    input.end_branch = 31;
    input.anthesis_started = &b;
    input.grain_fill_started = &b;
    input.final_grain_number_set = &([_]bool{false} ** 31);
    input.maximum_grain_size_set = &([_]bool{false} ** 31);
    input.mobile_carbon_g_c_per_g_c = &v;
    input.mobile_nitrogen_g_n_per_g_c = &v;
    input.mobile_phosphorus_g_p_per_g_c = &v;
    input.potential_seed_sites = &v;
    input.reproductive_stage_increment = &v;
    try apply(.{ .grain_count = &grains }, .{ .grain_count = &wg, .nutrient_set_fraction = &ws, .thermal_loss_fraction = &wt }, input);
    try std.testing.expect(grains[30] > 0);
}
test "late invalid branch leaves grain counts unchanged" {
    var grains = [_]f64{ 10, 10 };
    var wg: [2]f64 = undefined;
    var ws: [2]f64 = undefined;
    var wt: [2]f64 = undefined;
    var input = testInputs();
    input.mobile_phosphorus_g_p_per_g_c = &.{ 0.05, std.math.nan(f64) };
    try std.testing.expectError(error.InvalidFinalGrainNumberState, apply(.{ .grain_count = &grains }, .{ .grain_count = &wg, .nutrient_set_fraction = &ws, .thermal_loss_fraction = &wt }, input));
    try std.testing.expectEqualSlices(f64, &.{ 10, 10 }, &grains);
}

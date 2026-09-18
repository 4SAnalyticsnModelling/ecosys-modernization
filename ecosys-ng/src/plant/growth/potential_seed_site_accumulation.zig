const std = @import("std");

pub const State = struct {
    potential_seed_site_count: []f64,
};

pub const Inputs = struct {
    first_branch: usize,
    end_branch: usize,
    stem_elongation_started: []const bool,
    anthesis_started: []const bool,
    branch_shoot_carbon_g_c: []const f64,
    canopy_shoot_carbon_g_c: f64,
    canopy_shoot_growth_g_c_per_timestep: f64,
    potential_seed_sites_per_g_c_growth: f64,
    structural_presence_threshold_g_c: f64,
};

/// grosub.f lines 4063--4073. Applies the pre-anthesis branch sweep to runtime
/// branches. DWTSHB is formed in exact multiply-then-divide order and GRNXB is
/// updated only after all branches validate, preventing partial plant updates.
pub fn apply(state: State, workspace_seed_sites: []f64, inputs: Inputs) !void {
    const branch_count = state.potential_seed_site_count.len;
    inline for (.{ inputs.stem_elongation_started, inputs.anthesis_started }) |values|
        if (values.len != branch_count) return error.PotentialSeedSiteDimensionMismatch;
    if (inputs.branch_shoot_carbon_g_c.len != branch_count)
        return error.PotentialSeedSiteDimensionMismatch;
    if (workspace_seed_sites.len < branch_count)
        return error.PotentialSeedSiteWorkspaceTooSmall;
    if (inputs.first_branch > inputs.end_branch or inputs.end_branch > branch_count)
        return error.PotentialSeedSiteBranchRangeOutOfBounds;
    inline for (.{ inputs.canopy_shoot_carbon_g_c, inputs.canopy_shoot_growth_g_c_per_timestep, inputs.potential_seed_sites_per_g_c_growth, inputs.structural_presence_threshold_g_c }) |value|
        if (!std.math.isFinite(value)) return error.InvalidPotentialSeedSiteInput;
    if (inputs.canopy_shoot_carbon_g_c < 0 or inputs.potential_seed_sites_per_g_c_growth < 0 or inputs.structural_presence_threshold_g_c < 0) return error.InvalidPotentialSeedSiteInput;

    @memcpy(workspace_seed_sites[0..branch_count], state.potential_seed_site_count);
    for (inputs.first_branch..inputs.end_branch) |branch| {
        const current_sites = workspace_seed_sites[branch];
        const branch_shoot_carbon_g_c = inputs.branch_shoot_carbon_g_c[branch];
        inline for (.{ current_sites, branch_shoot_carbon_g_c }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.InvalidPotentialSeedSiteState;
        if (!inputs.stem_elongation_started[branch] or
            inputs.anthesis_started[branch] or
            inputs.canopy_shoot_carbon_g_c <= inputs.structural_presence_threshold_g_c or
            inputs.canopy_shoot_growth_g_c_per_timestep <= inputs.structural_presence_threshold_g_c)
            continue;

        const branch_growth_g_c_per_timestep =
            inputs.canopy_shoot_growth_g_c_per_timestep *
            branch_shoot_carbon_g_c / inputs.canopy_shoot_carbon_g_c;
        const updated_sites = current_sites +
            inputs.potential_seed_sites_per_g_c_growth * branch_growth_g_c_per_timestep;
        if (!std.math.isFinite(branch_growth_g_c_per_timestep) or branch_growth_g_c_per_timestep < 0 or
            !std.math.isFinite(updated_sites) or updated_sites < 0)
            return error.InvalidPotentialSeedSiteResult;
        workspace_seed_sites[branch] = updated_sites;
    }
    @memcpy(state.potential_seed_site_count, workspace_seed_sites[0..branch_count]);
}

test "runtime branches receive shoot-growth-proportional potential sites" {
    var sites = [_]f64{ 10, 20, 30 };
    var workspace: [3]f64 = undefined;
    try apply(.{ .potential_seed_site_count = &sites }, &workspace, .{
        .first_branch = 0,
        .end_branch = 3,
        .stem_elongation_started = &.{ true, true, true },
        .anthesis_started = &.{ false, false, false },
        .branch_shoot_carbon_g_c = &.{ 20, 30, 50 },
        .canopy_shoot_carbon_g_c = 100,
        .canopy_shoot_growth_g_c_per_timestep = 5,
        .potential_seed_sites_per_g_c_growth = 3,
        .structural_presence_threshold_g_c = 1e-12,
    });
    try std.testing.expectEqualSlices(f64, &.{ 13, 24.5, 37.5 }, &sites);
}

test "stem and anthesis gates are branch local" {
    var sites = [_]f64{ 1, 1, 1 };
    var workspace: [3]f64 = undefined;
    try apply(.{ .potential_seed_site_count = &sites }, &workspace, .{
        .first_branch = 0,
        .end_branch = 3,
        .stem_elongation_started = &.{ false, true, true },
        .anthesis_started = &.{ false, true, false },
        .branch_shoot_carbon_g_c = &.{ 1, 1, 1 },
        .canopy_shoot_carbon_g_c = 3,
        .canopy_shoot_growth_g_c_per_timestep = 3,
        .potential_seed_sites_per_g_c_growth = 1,
        .structural_presence_threshold_g_c = 0,
    });
    try std.testing.expectEqualSlices(f64, &.{ 1, 1, 2 }, &sites);
}

test "negative canopy shoot growth follows the source presence gate as a no-op" {
    var sites = [_]f64{2};
    var workspace: [1]f64 = undefined;
    try apply(.{ .potential_seed_site_count = &sites }, &workspace, .{
        .first_branch = 0,
        .end_branch = 1,
        .stem_elongation_started = &.{true},
        .anthesis_started = &.{false},
        .branch_shoot_carbon_g_c = &.{1},
        .canopy_shoot_carbon_g_c = 1,
        .canopy_shoot_growth_g_c_per_timestep = -0.1,
        .potential_seed_sites_per_g_c_growth = 3,
        .structural_presence_threshold_g_c = 0,
    });
    try std.testing.expectEqual(@as(f64, 2), sites[0]);
}

test "runtime branch thirty is unrestricted" {
    var sites: [31]f64 = @splat(0);
    var growth_started: [31]bool = @splat(false);
    var anthesis: [31]bool = @splat(false);
    var shoot: [31]f64 = @splat(0);
    var workspace: [31]f64 = undefined;
    growth_started[30] = true;
    shoot[30] = 1;
    try apply(.{ .potential_seed_site_count = &sites }, &workspace, .{ .first_branch = 30, .end_branch = 31, .stem_elongation_started = &growth_started, .anthesis_started = &anthesis, .branch_shoot_carbon_g_c = &shoot, .canopy_shoot_carbon_g_c = 1, .canopy_shoot_growth_g_c_per_timestep = 2, .potential_seed_sites_per_g_c_growth = 3, .structural_presence_threshold_g_c = 0 });
    try std.testing.expectEqual(@as(f64, 6), sites[30]);
}

test "late invalid branch leaves all site counts unchanged" {
    var sites = [_]f64{ 10, 20, 30 };
    var workspace: [3]f64 = undefined;
    try std.testing.expectError(error.InvalidPotentialSeedSiteState, apply(.{ .potential_seed_site_count = &sites }, &workspace, .{
        .first_branch = 0,
        .end_branch = 3,
        .stem_elongation_started = &.{ true, true, true },
        .anthesis_started = &.{ false, false, false },
        .branch_shoot_carbon_g_c = &.{ 20, 30, std.math.nan(f64) },
        .canopy_shoot_carbon_g_c = 100,
        .canopy_shoot_growth_g_c_per_timestep = 5,
        .potential_seed_sites_per_g_c_growth = 3,
        .structural_presence_threshold_g_c = 0,
    }));
    try std.testing.expectEqualSlices(f64, &.{ 10, 20, 30 }, &sites);
}

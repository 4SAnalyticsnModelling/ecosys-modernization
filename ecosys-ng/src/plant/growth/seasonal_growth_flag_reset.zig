const std = @import("std");
const growth_stages = @import("../lifecycle/growth_stages.zig");

pub const BranchState = struct {
    accumulated_leafout_h: f64,
    accumulated_leafoff_h: f64,
    leafout_disabled: bool,
    leafoff_disabled: bool,
    reproductive_growth_disabled: bool,
    reproductive_litterfall_delay_h: f64,
    leafout_initialization_disabled: bool,
};

pub const BranchInputs = struct {
    required_leafout_h: f64,
    required_leafoff_h: f64,
    growth_habit: growth_stages.GrowthHabit,
    phenology: growth_stages.PhenologyType,
    first_biological_iteration: bool,
};

pub const Inputs = struct {
    required_leafout_h_by_branch: []const f64,
    growth_habit: growth_stages.GrowthHabit,
    phenology: growth_stages.PhenologyType,
};

/// Exact grosub.f lines 4393--4409 spring/fall flag reset in ascending NB
/// order. Hours are h. The caller owns the surrounding seasonal gates.
/// Validation of every runtime branch precedes mutation so a bad late branch
/// cannot leave an incompletely reset plant.
pub fn apply(branches: []BranchState, inputs: Inputs) !void {
    if (branches.len == 0 or
        inputs.required_leafout_h_by_branch.len != branches.len)
        return error.SeasonalGrowthFlagResetDimensionMismatch;

    for (branches, inputs.required_leafout_h_by_branch) |branch, required_leafout_h|
        try validateBranch(branch, required_leafout_h, 0);

    for (branches, inputs.required_leafout_h_by_branch) |*branch, required_leafout_h|
        resetAdmittedBranch(branch, required_leafout_h, inputs.growth_habit, inputs.phenology);
}

/// Applies the exact branch-local GROSUB 4182--4188 outer gate followed by
/// lines 4393--4409. The source has no main-branch restriction: every runtime
/// branch is independently eligible on the first biological iteration.
pub fn applyBranch(branch: *BranchState, inputs: BranchInputs) !bool {
    try validateBranch(branch.*, inputs.required_leafout_h, inputs.required_leafoff_h);
    if (!inputs.first_biological_iteration) return false;
    const eligible_plant = inputs.growth_habit == .perennial or
        (inputs.growth_habit == .annual and phenologyCode(inputs.phenology) > 1);
    if (!eligible_plant) return false;
    const leafout_transition = !branch.leafout_disabled and
        branch.accumulated_leafout_h >= inputs.required_leafout_h;
    const leafoff_transition = !branch.leafoff_disabled and
        branch.accumulated_leafoff_h >= inputs.required_leafoff_h;
    if (!leafout_transition and !leafoff_transition) return false;
    resetAdmittedBranch(branch, inputs.required_leafout_h, inputs.growth_habit, inputs.phenology);
    return true;
}

fn resetAdmittedBranch(branch: *BranchState, required_leafout_h: f64, growth_habit: growth_stages.GrowthHabit, phenology: growth_stages.PhenologyType) void {
    if (!branch.leafout_disabled and branch.accumulated_leafout_h >= required_leafout_h) {
        branch.leafout_disabled = true;
        branch.leafoff_disabled = false;
        branch.reproductive_growth_disabled = false;
        branch.reproductive_litterfall_delay_h = 0;
    } else {
        branch.leafout_disabled = growth_habit == .annual and phenology == .winter_deciduous;
        branch.leafoff_disabled = true;
        branch.reproductive_growth_disabled = true;
        branch.reproductive_litterfall_delay_h = 0;
        branch.leafout_initialization_disabled = false;
    }
}

fn validateBranch(branch: BranchState, required_leafout_h: f64, required_leafoff_h: f64) !void {
    inline for (.{ branch.accumulated_leafout_h, branch.accumulated_leafoff_h, branch.reproductive_litterfall_delay_h, required_leafout_h, required_leafoff_h }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteSeasonalGrowthFlagResetState;
        if (value < 0) return error.NegativeSeasonalGrowthFlagResetState;
    }
}

fn phenologyCode(value: growth_stages.PhenologyType) u8 {
    return switch (value) {
        .evergreen => 0,
        .winter_deciduous => 1,
        .drought_deciduous, .drought_shortening_day, .drought_lengthening_day => 2,
        .winter_and_drought_deciduous => 3,
    };
}

fn state(accumulated_leafout_h: f64, leafout_disabled: bool) BranchState {
    return .{
        .accumulated_leafout_h = accumulated_leafout_h,
        .accumulated_leafoff_h = 0,
        .leafout_disabled = leafout_disabled,
        .leafoff_disabled = true,
        .reproductive_growth_disabled = true,
        .reproductive_litterfall_delay_h = 19,
        .leafout_initialization_disabled = true,
    };
}

test "GROSUB completed leafout enables fall and reproductive growth" {
    var branches = [_]BranchState{
        state(10, false),
        state(12, false),
        state(13, true),
    };

    try apply(&branches, .{
        .required_leafout_h_by_branch = &.{ 10, 11, 12 },
        .growth_habit = .perennial,
        .phenology = .winter_deciduous,
    });

    for (branches[0..2]) |branch| {
        try std.testing.expect(branch.leafout_disabled);
        try std.testing.expect(!branch.leafoff_disabled);
        try std.testing.expect(!branch.reproductive_growth_disabled);
        try std.testing.expectEqual(@as(f64, 0), branch.reproductive_litterfall_delay_h);
        // IFLGA is not assigned in the completed-leafout arm.
        try std.testing.expect(branch.leafout_initialization_disabled);
    }
    try std.testing.expect(!branches[2].leafout_initialization_disabled);
    try std.testing.expect(branches[2].leafoff_disabled);
    try std.testing.expect(branches[2].reproductive_growth_disabled);
}

test "GROSUB winter annual alone keeps leafout disabled in reset arm" {
    var winter_annual = [_]BranchState{state(2, true)};
    try apply(&winter_annual, .{
        .required_leafout_h_by_branch = &.{10},
        .growth_habit = .annual,
        .phenology = .winter_deciduous,
    });
    try std.testing.expect(winter_annual[0].leafout_disabled);

    var perennial = [_]BranchState{state(2, true)};
    try apply(&perennial, .{
        .required_leafout_h_by_branch = &.{10},
        .growth_habit = .perennial,
        .phenology = .winter_deciduous,
    });
    try std.testing.expect(!perennial[0].leafout_disabled);

    var evergreen_annual = [_]BranchState{state(2, true)};
    try apply(&evergreen_annual, .{
        .required_leafout_h_by_branch = &.{10},
        .growth_habit = .annual,
        .phenology = .evergreen,
    });
    try std.testing.expect(!evergreen_annual[0].leafout_disabled);
}

test "runtime branch count has no source ceiling" {
    const allocator = std.testing.allocator;
    const count = 41;
    const branches = try allocator.alloc(BranchState, count);
    defer allocator.free(branches);
    const required = try allocator.alloc(f64, count);
    defer allocator.free(required);
    for (branches, required, 0..) |*branch, *required_h, index| {
        required_h.* = @floatFromInt(index + 1);
        branch.* = state(required_h.*, false);
    }

    try apply(branches, .{
        .required_leafout_h_by_branch = required,
        .growth_habit = .perennial,
        .phenology = .winter_and_drought_deciduous,
    });
    for (branches) |branch| {
        try std.testing.expect(branch.leafout_disabled);
        try std.testing.expect(!branch.reproductive_growth_disabled);
    }
}

test "invalid late branch leaves all flags unchanged" {
    var branches = [_]BranchState{
        state(10, false),
        state(std.math.nan(f64), false),
    };
    const before = branches;

    try std.testing.expectError(
        error.NonFiniteSeasonalGrowthFlagResetState,
        apply(&branches, .{
            .required_leafout_h_by_branch = &.{ 10, 10 },
            .growth_habit = .annual,
            .phenology = .winter_deciduous,
        }),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&before),
        std.mem.asBytes(&branches),
    );
}

test "dimensions and negative hours fail explicitly" {
    var branches = [_]BranchState{state(1, false)};
    try std.testing.expectError(
        error.SeasonalGrowthFlagResetDimensionMismatch,
        apply(&branches, .{
            .required_leafout_h_by_branch = &.{},
            .growth_habit = .annual,
            .phenology = .evergreen,
        }),
    );
    branches[0].reproductive_litterfall_delay_h = -1;
    try std.testing.expectError(
        error.NegativeSeasonalGrowthFlagResetState,
        apply(&branches, .{
            .required_leafout_h_by_branch = &.{1},
            .growth_habit = .annual,
            .phenology = .evergreen,
        }),
    );
}

test "scalar leafout threshold admits equality and preserves IFLGA" {
    var branch = state(10, false);
    branch.leafoff_disabled = true;
    try std.testing.expect(try applyBranch(&branch, .{
        .required_leafout_h = 10,
        .required_leafoff_h = 20,
        .growth_habit = .perennial,
        .phenology = .winter_deciduous,
        .first_biological_iteration = true,
    }));
    try std.testing.expect(branch.leafout_disabled);
    try std.testing.expect(!branch.leafoff_disabled);
    try std.testing.expect(!branch.reproductive_growth_disabled);
    try std.testing.expect(branch.leafout_initialization_disabled);
}

test "scalar leafoff threshold selects the end-of-season reset arm" {
    var branch = state(2, true);
    branch.accumulated_leafoff_h = 20;
    branch.leafoff_disabled = false;
    try std.testing.expect(try applyBranch(&branch, .{
        .required_leafout_h = 10,
        .required_leafoff_h = 20,
        .growth_habit = .perennial,
        .phenology = .winter_deciduous,
        .first_biological_iteration = true,
    }));
    try std.testing.expect(!branch.leafout_disabled);
    try std.testing.expect(branch.leafoff_disabled);
    try std.testing.expect(branch.reproductive_growth_disabled);
    try std.testing.expectEqual(@as(f64, 0), branch.reproductive_litterfall_delay_h);
    try std.testing.expect(!branch.leafout_initialization_disabled);
}

test "non-first iteration is an exact no-op" {
    var branch = state(10, false);
    const before = branch;
    try std.testing.expect(!try applyBranch(&branch, .{
        .required_leafout_h = 10,
        .required_leafoff_h = 20,
        .growth_habit = .perennial,
        .phenology = .winter_deciduous,
        .first_biological_iteration = false,
    }));
    try std.testing.expectEqualDeep(before, branch);
}

test "non-main runtime branch receives the same branch-local gate" {
    var branches = [_]BranchState{ state(1, true), state(10, false) };
    const main_before = branches[0];
    try std.testing.expect(try applyBranch(&branches[1], .{
        .required_leafout_h = 10,
        .required_leafoff_h = 20,
        .growth_habit = .perennial,
        .phenology = .winter_and_drought_deciduous,
        .first_biological_iteration = true,
    }));
    try std.testing.expectEqualDeep(main_before, branches[0]);
    try std.testing.expect(!branches[1].reproductive_growth_disabled);
}

test "scalar late invalid state is rejected atomically before flags change" {
    var branch = state(10, false);
    branch.accumulated_leafoff_h = std.math.nan(f64);
    const before = branch;
    try std.testing.expectError(error.NonFiniteSeasonalGrowthFlagResetState, applyBranch(&branch, .{
        .required_leafout_h = 10,
        .required_leafoff_h = 20,
        .growth_habit = .perennial,
        .phenology = .winter_deciduous,
        .first_biological_iteration = true,
    }));
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&branch));
}

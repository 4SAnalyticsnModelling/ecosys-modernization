// **A8a DISPOSITION: unwired pure kernel, superseded; do not bind piecemeal.**
// Source: `startq.f` 436--473.
// Covered by production: the bound `plant_initialization` owner, called across `ecosys_ng.zig:2393-2512`; note this is the ONE module in the family that already accepts production state, so it is the first to bind if INIT-004's consolidation is scheduled.
// This is NOT a double-mutation case. Nothing in `ecosys_ng.zig` names this
// module, and its entry point takes only structs it defines itself, so it has no
// path to production state and cannot compete for ownership. It is retained, not
// deleted, because it carries an exact source range and tests; binding it is part
// of the single consolidation refactor tracked as INIT-004, not an isolated wire.
// Group INDEX of docs/traceability/plant_initialization_unbound_family_are_unwired_kernels_not_competing_owners.md
const std = @import("std");

pub const GrowthHabit = enum { annual, perennial };
pub const PhenologyType = enum {
    evergreen,
    cold_deciduous,
    drought_deciduous,
    cold_and_drought_deciduous,
};

pub const BranchState = struct {
    apical_flag: i32,
    emergence_flag: i32,
    flowering_flag: i32,
    reproductive_flag: i32,
    flowering_progress: f64,
    maturity_group: i32,
    phenology_stage: f64,
    initial_phenology_stage: f64,
    final_phenology_stage: f64,
    vegetative_stage: f64,
    maximum_vegetative_stage: f64,
    leaf_index: usize,
    maximum_leaf_index: usize,
    vegetative_stage_index: usize,
    next_vegetative_stage_index: usize,
    initial_growth_stage: f64,
    final_growth_stage: f64,
    initial_growth_stage_thermal_time: f64,
    final_growth_stage_thermal_time: f64,
    vernalization_current: f64,
    vernalization_target: f64,
    vernalization_start: f64,
    vernalization_finish: f64,
    anthesis_progress: f64,
    feedback_factor: f64,
    previous_feedback_factor: f64,
    stage_four_flag: f64,
    stage_zero_flag: f64,
    branch_node_count: usize,
    branch_death_index: usize,
};

pub const PlantState = struct {
    initialization_flag: i32,
    shoot_death_index: usize,
    root_death_index: usize,
    tiller_count: usize,
    branch_count: usize,
    canopy_height_control_m: f64,
    canopy_height_m: f64,
};

pub const Inputs = struct {
    growth_habit: GrowthHabit,
    phenology_type: PhenologyType,
    maturity_group: i32,
    seed_node_number: f64,
    event_day_slot_count: usize,
};

pub const InitializationError = error{
    EventDayExtentMismatch,
    NonFiniteInput,
};

/// Translates `startq.f` lines 436--473 with runtime branch and event-day extents.
pub fn initialize(
    inputs: Inputs,
    branches: []BranchState,
    event_days: []i32,
) InitializationError!PlantState {
    if (!std.math.isFinite(inputs.seed_node_number)) return error.NonFiniteInput;
    const expected_event_days = std.math.mul(
        usize,
        branches.len,
        inputs.event_day_slot_count,
    ) catch return error.EventDayExtentMismatch;
    if (event_days.len != expected_event_days) return error.EventDayExtentMismatch;

    const emergence_flag: i32 =
        if (inputs.growth_habit == .annual and inputs.phenology_type == .cold_deciduous)
            1
        else
            0;
    for (branches) |*branch| {
        branch.* = .{
            .apical_flag = 0,
            .emergence_flag = emergence_flag,
            .flowering_flag = 0,
            .reproductive_flag = 0,
            .flowering_progress = 0.0,
            .maturity_group = inputs.maturity_group,
            .phenology_stage = inputs.seed_node_number,
            .initial_phenology_stage = inputs.seed_node_number,
            .final_phenology_stage = 0.0,
            .vegetative_stage = 0.0,
            .maximum_vegetative_stage = 0.0,
            .leaf_index = 1,
            .maximum_leaf_index = 1,
            .vegetative_stage_index = 1,
            .next_vegetative_stage_index = 0,
            .initial_growth_stage = 0.0,
            .final_growth_stage = 0.0,
            .initial_growth_stage_thermal_time = 0.0,
            .final_growth_stage_thermal_time = 0.0,
            .vernalization_current = 0.0,
            .vernalization_target = 0.0,
            .vernalization_start = 0.0,
            .vernalization_finish = 0.0,
            .anthesis_progress = 0.0,
            .feedback_factor = 1.0,
            .previous_feedback_factor = 1.0,
            .stage_four_flag = 0.0,
            .stage_zero_flag = 0.0,
            .branch_node_count = 0,
            .branch_death_index = 1,
        };
    }
    @memset(event_days, 0);
    return .{
        .initialization_flag = 0,
        .shoot_death_index = 0,
        .root_death_index = 0,
        .tiller_count = 0,
        .branch_count = 0,
        .canopy_height_control_m = 0.0,
        .canopy_height_m = 0.0,
    };
}

test "annual cold-deciduous branches start with emergence enabled" {
    var branches: [3]BranchState = undefined;
    var event_days: [6]i32 = undefined;
    const plant = try initialize(.{
        .growth_habit = .annual,
        .phenology_type = .cold_deciduous,
        .maturity_group = 12,
        .seed_node_number = 1.5,
        .event_day_slot_count = 2,
    }, &branches, &event_days);

    try std.testing.expectEqual(@as(usize, 0), plant.branch_count);
    for (branches) |branch| {
        try std.testing.expectEqual(@as(i32, 1), branch.emergence_flag);
        try std.testing.expectEqual(@as(f64, 1.5), branch.phenology_stage);
        try std.testing.expectEqual(@as(f64, 1.0), branch.feedback_factor);
        try std.testing.expectEqual(@as(usize, 1), branch.leaf_index);
        try std.testing.expectEqual(@as(usize, 1), branch.branch_death_index);
    }
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 0, 0, 0, 0 }, &event_days);
}

test "other phenology combinations start with emergence disabled" {
    var branches: [1]BranchState = undefined;
    var event_days: [1]i32 = undefined;
    _ = try initialize(.{
        .growth_habit = .perennial,
        .phenology_type = .cold_deciduous,
        .maturity_group = 4,
        .seed_node_number = 2.0,
        .event_day_slot_count = 1,
    }, &branches, &event_days);
    try std.testing.expectEqual(@as(i32, 0), branches[0].emergence_flag);
}

const std = @import("std");

pub const GrowthHabit = enum { annual, perennial };
pub const Phenology = enum { evergreen, seasonal };
pub const BranchStatus = enum { alive, dead };
pub const Outcome = enum { storage_satisfied, branch_died, leafoff_forced };

pub const State = struct {
    plant_storage_carbon_g_c: *f64,
    branch_stalk_carbon_g_c: *f64,
    branch_status: *BranchStatus,
    leafoff_accumulated_h: *f64,
};

pub const Inputs = struct {
    remaining_respiration_g_c_per_timestep: f64,
    growth_habit: GrowthHabit,
    phenology: Phenology,
    leafoff_required_h: f64,
};

pub const Result = struct {
    outcome: Outcome,
    remaining_excess_respiration_g_c_per_timestep: f64,
    storage_carbon_consumed_g_c: f64,
    stalk_carbon_consumed_g_c: f64,
};

/// grosub.f lines 3621--3639. Attempts to meet remaining SNCT from plant storage
/// C. Only storage strictly greater than demand takes the successful branch.
/// Equality exhausts storage and triggers branch death or forced leafoff even
/// though no stalk C is consumed. Invalid stalk overdraw fails atomically.
pub fn apply(state: State, inputs: Inputs) !Result {
    inline for (.{
        state.plant_storage_carbon_g_c.*,
        state.branch_stalk_carbon_g_c.*,
        state.leafoff_accumulated_h.*,
        inputs.remaining_respiration_g_c_per_timestep,
        inputs.leafoff_required_h,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteStorageCarbonSurvivalInput;
    if (state.plant_storage_carbon_g_c.* < 0 or
        state.branch_stalk_carbon_g_c.* < 0 or
        state.leafoff_accumulated_h.* < 0 or
        inputs.remaining_respiration_g_c_per_timestep < 0 or
        inputs.leafoff_required_h < 0)
        return error.InvalidStorageCarbonSurvivalInput;

    const demand = inputs.remaining_respiration_g_c_per_timestep;
    const storage_before = state.plant_storage_carbon_g_c.*;
    if (storage_before > demand) {
        const storage_after = storage_before - demand;
        if (!std.math.isFinite(storage_after) or storage_after < 0)
            return error.InvalidStorageCarbonSurvivalResult;
        state.plant_storage_carbon_g_c.* = storage_after;
        return .{
            .outcome = .storage_satisfied,
            .remaining_excess_respiration_g_c_per_timestep = 0,
            .storage_carbon_consumed_g_c = demand,
            .stalk_carbon_consumed_g_c = 0,
        };
    }

    const remaining = demand - storage_before;
    const stalk_after = state.branch_stalk_carbon_g_c.* - remaining;
    if (!std.math.isFinite(remaining) or remaining < 0 or
        !std.math.isFinite(stalk_after) or stalk_after < 0)
        return error.StorageCarbonSurvivalStalkOverdraw;
    const branch_dies = inputs.growth_habit == .perennial or inputs.phenology == .evergreen;
    const forced_leafoff_h = inputs.leafoff_required_h + 0.5;
    if (!branch_dies and !std.math.isFinite(forced_leafoff_h))
        return error.InvalidStorageCarbonSurvivalResult;

    state.plant_storage_carbon_g_c.* = 0;
    state.branch_stalk_carbon_g_c.* = stalk_after;
    if (branch_dies)
        state.branch_status.* = .dead
    else
        state.leafoff_accumulated_h.* = forced_leafoff_h;
    return .{
        .outcome = if (branch_dies) .branch_died else .leafoff_forced,
        .remaining_excess_respiration_g_c_per_timestep = remaining,
        .storage_carbon_consumed_g_c = storage_before,
        .stalk_carbon_consumed_g_c = remaining,
    };
}

fn testState(storage: *f64, stalk: *f64, status: *BranchStatus, leafoff: *f64) State {
    return .{
        .plant_storage_carbon_g_c = storage,
        .branch_stalk_carbon_g_c = stalk,
        .branch_status = status,
        .leafoff_accumulated_h = leafoff,
    };
}

test "storage strictly greater than demand exits without survival state changes" {
    var storage: f64 = 5;
    var stalk: f64 = 10;
    var status: BranchStatus = .alive;
    var leafoff_h: f64 = 2;
    const result = try apply(testState(&storage, &stalk, &status, &leafoff_h), .{
        .remaining_respiration_g_c_per_timestep = 3,
        .growth_habit = .perennial,
        .phenology = .evergreen,
        .leafoff_required_h = 100,
    });
    try std.testing.expectEqual(Outcome.storage_satisfied, result.outcome);
    try std.testing.expectEqual(@as(f64, 2), storage);
    try std.testing.expectEqual(@as(f64, 10), stalk);
    try std.testing.expectEqual(BranchStatus.alive, status);
    try std.testing.expectEqual(@as(f64, 2), leafoff_h);
}

test "storage equality follows source exhaustion and perennial death branch" {
    var storage: f64 = 3;
    var stalk: f64 = 10;
    var status: BranchStatus = .alive;
    var leafoff_h: f64 = 2;
    const result = try apply(testState(&storage, &stalk, &status, &leafoff_h), .{
        .remaining_respiration_g_c_per_timestep = 3,
        .growth_habit = .perennial,
        .phenology = .seasonal,
        .leafoff_required_h = 100,
    });
    try std.testing.expectEqual(Outcome.branch_died, result.outcome);
    try std.testing.expectEqual(@as(f64, 0), storage);
    try std.testing.expectEqual(@as(f64, 10), stalk);
    try std.testing.expectEqual(BranchStatus.dead, status);
    try std.testing.expectEqual(@as(f64, 0), result.remaining_excess_respiration_g_c_per_timestep);
}

test "annual seasonal exhaustion forces leafoff after consuming stalk carbon" {
    var storage: f64 = 1;
    var stalk: f64 = 10;
    var status: BranchStatus = .alive;
    var leafoff_h: f64 = 2;
    const result = try apply(testState(&storage, &stalk, &status, &leafoff_h), .{
        .remaining_respiration_g_c_per_timestep = 4,
        .growth_habit = .annual,
        .phenology = .seasonal,
        .leafoff_required_h = 100,
    });
    try std.testing.expectEqual(Outcome.leafoff_forced, result.outcome);
    try std.testing.expectEqual(@as(f64, 7), stalk);
    try std.testing.expectEqual(@as(f64, 100.5), leafoff_h);
    try std.testing.expectEqual(BranchStatus.alive, status);
    try std.testing.expectEqual(@as(f64, 3), result.stalk_carbon_consumed_g_c);
}

test "annual evergreen exhaustion kills branch" {
    var storage: f64 = 0;
    var stalk: f64 = 2;
    var status: BranchStatus = .alive;
    var leafoff_h: f64 = 0;
    const result = try apply(testState(&storage, &stalk, &status, &leafoff_h), .{
        .remaining_respiration_g_c_per_timestep = 1,
        .growth_habit = .annual,
        .phenology = .evergreen,
        .leafoff_required_h = 10,
    });
    try std.testing.expectEqual(Outcome.branch_died, result.outcome);
    try std.testing.expectEqual(BranchStatus.dead, status);
}

test "stalk overdraw fails before storage or survival mutation" {
    var storage: f64 = 1;
    var stalk: f64 = 2;
    var status: BranchStatus = .alive;
    var leafoff_h: f64 = 4;
    try std.testing.expectError(error.StorageCarbonSurvivalStalkOverdraw, apply(
        testState(&storage, &stalk, &status, &leafoff_h),
        .{
            .remaining_respiration_g_c_per_timestep = 5,
            .growth_habit = .annual,
            .phenology = .seasonal,
            .leafoff_required_h = 10,
        },
    ));
    try std.testing.expectEqual(@as(f64, 1), storage);
    try std.testing.expectEqual(@as(f64, 2), stalk);
    try std.testing.expectEqual(BranchStatus.alive, status);
    try std.testing.expectEqual(@as(f64, 4), leafoff_h);
}

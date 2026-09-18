const std = @import("std");

pub const BranchStatus = enum { alive, dead };
pub const AbovegroundTurnover = enum { none, active };
pub const RootProfile = enum { shallow, intermediate, deep, deeper };

pub const Inputs = struct {
    current_branch: usize,
    main_branch: usize,
    aboveground_turnover: AbovegroundTurnover,
    root_profile: RootProfile,
};

pub fn shouldPropagate(aboveground_turnover_active: bool, deep_root_profile: bool, main_branch_dead: bool) bool {
    return aboveground_turnover_active and deep_root_profile and main_branch_dead;
}

/// grosub.f lines 3664--3665. Marks the current runtime branch dead only when
/// aboveground turnover is nonzero, the root profile is deeper than
/// intermediate, and the explicitly identified main stalk is already dead.
pub fn apply(branch_status: []BranchStatus, inputs: Inputs) !bool {
    if (inputs.current_branch >= branch_status.len or inputs.main_branch >= branch_status.len)
        return error.BranchDeathPropagationIndexOutOfBounds;
    const propagates = shouldPropagate(
        inputs.aboveground_turnover == .active,
        inputs.root_profile == .deep or inputs.root_profile == .deeper,
        branch_status[inputs.main_branch] == .dead,
    );
    if (propagates) branch_status[inputs.current_branch] = .dead;
    return propagates;
}

test "explicit non-first main stalk death propagates to current branch" {
    var statuses = [_]BranchStatus{ .alive, .alive, .dead, .alive };
    try std.testing.expect(try apply(&statuses, .{
        .current_branch = 3,
        .main_branch = 2,
        .aboveground_turnover = .active,
        .root_profile = .deep,
    }));
    try std.testing.expectEqual(BranchStatus.dead, statuses[3]);
    try std.testing.expectEqual(BranchStatus.alive, statuses[0]);
}

test "each source gate independently suppresses propagation" {
    const cases = [_]Inputs{
        .{ .current_branch = 1, .main_branch = 0, .aboveground_turnover = .none, .root_profile = .deep },
        .{ .current_branch = 1, .main_branch = 0, .aboveground_turnover = .active, .root_profile = .intermediate },
        .{ .current_branch = 1, .main_branch = 0, .aboveground_turnover = .active, .root_profile = .shallow },
    };
    for (cases) |inputs| {
        var statuses = [_]BranchStatus{ .dead, .alive };
        try std.testing.expect(!try apply(&statuses, inputs));
        try std.testing.expectEqual(BranchStatus.alive, statuses[1]);
    }
    var living_main = [_]BranchStatus{ .alive, .alive };
    try std.testing.expect(!try apply(&living_main, .{
        .current_branch = 1,
        .main_branch = 0,
        .aboveground_turnover = .active,
        .root_profile = .deeper,
    }));
}

test "main branch may propagate death to itself without special casing" {
    var statuses = [_]BranchStatus{ .alive, .dead };
    try std.testing.expect(try apply(&statuses, .{
        .current_branch = 1,
        .main_branch = 1,
        .aboveground_turnover = .active,
        .root_profile = .deeper,
    }));
    try std.testing.expectEqual(BranchStatus.dead, statuses[1]);
}

test "runtime branch indexes fail before mutation" {
    var statuses = [_]BranchStatus{ .dead, .alive };
    try std.testing.expectError(error.BranchDeathPropagationIndexOutOfBounds, apply(&statuses, .{
        .current_branch = 2,
        .main_branch = 0,
        .aboveground_turnover = .active,
        .root_profile = .deep,
    }));
    try std.testing.expectEqualSlices(BranchStatus, &.{ .dead, .alive }, &statuses);
    try std.testing.expectError(error.BranchDeathPropagationIndexOutOfBounds, apply(&statuses, .{
        .current_branch = 1,
        .main_branch = 2,
        .aboveground_turnover = .active,
        .root_profile = .deep,
    }));
    try std.testing.expectEqualSlices(BranchStatus, &.{ .dead, .alive }, &statuses);
}

test "runtime branch count is unrestricted" {
    var statuses: [33]BranchStatus = @splat(.alive);
    statuses[31] = .dead;
    _ = try apply(&statuses, .{
        .current_branch = 32,
        .main_branch = 31,
        .aboveground_turnover = .active,
        .root_profile = .deep,
    });
    try std.testing.expectEqual(BranchStatus.dead, statuses[32]);
}

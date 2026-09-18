const std = @import("std");

pub const AbovegroundTurnover = enum { none, active };
pub const RootProfile = enum { shallow, intermediate, deep, deeper };

pub const Inputs = struct {
    current_branch: usize,
    main_branch: usize,
    attachment_node: usize,
    first_retained_main_node: usize,
    end_main_node: usize,
    aboveground_turnover: AbovegroundTurnover,
    root_profile: RootProfile,
    main_node_height_m: []const f64,
};

/// grosub.f lines 3758--3773. Returns the side-branch base height from its
/// explicit NBTB attachment ordinal on the main stalk. Runtime logical nodes
/// replace the modulo-25 ring; node zero remains ineligible as in KVSTG1>=1.
pub fn calculate(inputs: Inputs) !f64 {
    if (inputs.first_retained_main_node > inputs.end_main_node or
        inputs.end_main_node > inputs.main_node_height_m.len)
        return error.InvalidBranchBaseHeightNodeRange;

    if (inputs.aboveground_turnover == .none or
        (inputs.root_profile != .deep and inputs.root_profile != .deeper) or
        inputs.current_branch == inputs.main_branch)
        return 0;

    const first_eligible_node = @max(@as(usize, 1), inputs.first_retained_main_node);
    if (inputs.attachment_node < first_eligible_node or
        inputs.attachment_node >= inputs.end_main_node)
        return 0;
    const height_m = inputs.main_node_height_m[inputs.attachment_node];
    if (!std.math.isFinite(height_m) or height_m < 0)
        return error.InvalidBranchBaseHeightState;
    return height_m;
}

fn sampleInputs() Inputs {
    return .{
        .current_branch = 4,
        .main_branch = 2,
        .attachment_node = 3,
        .first_retained_main_node = 1,
        .end_main_node = 5,
        .aboveground_turnover = .active,
        .root_profile = .deep,
        .main_node_height_m = &.{ 0.1, 1, 2, 3, 4 },
    };
}

test "explicit attachment node determines side-branch base height" {
    try std.testing.expectEqual(@as(f64, 3), try calculate(sampleInputs()));
}

test "attachment before retained main window gives ground base" {
    var inputs = sampleInputs();
    inputs.first_retained_main_node = 3;
    inputs.attachment_node = 2;
    try std.testing.expectEqual(@as(f64, 0), try calculate(inputs));
}

test "main branch and each scientific gate give zero base" {
    var inputs = sampleInputs();
    inputs.current_branch = inputs.main_branch;
    try std.testing.expectEqual(@as(f64, 0), try calculate(inputs));
    inputs = sampleInputs();
    inputs.aboveground_turnover = .none;
    try std.testing.expectEqual(@as(f64, 0), try calculate(inputs));
    inputs = sampleInputs();
    inputs.root_profile = .intermediate;
    try std.testing.expectEqual(@as(f64, 0), try calculate(inputs));
}

test "node zero cannot anchor a side branch" {
    var inputs = sampleInputs();
    inputs.first_retained_main_node = 0;
    inputs.attachment_node = 0;
    try std.testing.expectEqual(@as(f64, 0), try calculate(inputs));
}

test "runtime attachment node beyond legacy ring is direct" {
    var heights: [40]f64 = @splat(0);
    heights[35] = 12.5;
    var inputs = sampleInputs();
    inputs.main_node_height_m = &heights;
    inputs.first_retained_main_node = 10;
    inputs.end_main_node = 40;
    inputs.attachment_node = 35;
    try std.testing.expectEqual(@as(f64, 12.5), try calculate(inputs));
}

test "invalid retained range and height fail explicitly" {
    var inputs = sampleInputs();
    inputs.end_main_node = 6;
    try std.testing.expectError(error.InvalidBranchBaseHeightNodeRange, calculate(inputs));
    inputs = sampleInputs();
    inputs.main_node_height_m = &.{ 0, 1, std.math.nan(f64), 3, 4 };
    inputs.attachment_node = 2;
    try std.testing.expectError(error.InvalidBranchBaseHeightState, calculate(inputs));
}

test "zero-base gates do not inspect unused main-node heights" {
    var inputs = sampleInputs();
    inputs.current_branch = inputs.main_branch;
    inputs.main_node_height_m = &.{ 0, 1, std.math.nan(f64), 3, 4 };
    try std.testing.expectEqual(@as(f64, 0), try calculate(inputs));
}

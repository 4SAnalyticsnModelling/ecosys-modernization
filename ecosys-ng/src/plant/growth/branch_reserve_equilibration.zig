const std = @import("std");

pub const State = struct {
    sapwood_carbon_g_c: []const f64,
    reserve_carbon_g_c: []f64,
    reserve_nitrogen_g_n: []f64,
    reserve_phosphorus_g_p: []f64,
};

pub const Workspace = struct {
    reserve_carbon_g_c: []f64,
    reserve_nitrogen_g_n: []f64,
    reserve_phosphorus_g_p: []f64,
};

pub const Inputs = struct {
    first_branch: usize,
    end_branch: usize,
    main_branch: usize,
    carbon_exchange_fraction_per_h: f64,
    nutrient_exchange_fraction_per_h: f64,
    timestep_h: f64,
    structural_presence_threshold_g_c: f64,
};

/// grosub.f lines 2860--2896. Sweeps runtime branches in ascending source order
/// from an explicit main-branch identity. Later pairs observe the main reserve
/// updated by earlier pairs. Caller-owned workspace makes the full sweep atomic.
pub fn apply(state: State, workspace: Workspace, inputs: Inputs) !void {
    const branch_count = state.reserve_carbon_g_c.len;
    inline for (.{ state.sapwood_carbon_g_c, state.reserve_nitrogen_g_n, state.reserve_phosphorus_g_p }) |values|
        if (values.len != branch_count) return error.BranchReserveEquilibrationDimensionMismatch;
    const sweep_count = inputs.end_branch -| inputs.first_branch;
    inline for (.{ workspace.reserve_carbon_g_c, workspace.reserve_nitrogen_g_n, workspace.reserve_phosphorus_g_p }) |values|
        if (values.len < sweep_count) return error.BranchReserveEquilibrationWorkspaceTooSmall;
    if (inputs.first_branch >= inputs.end_branch or inputs.end_branch > branch_count or
        inputs.main_branch < inputs.first_branch or inputs.main_branch >= inputs.end_branch)
        return error.InvalidBranchReserveEquilibrationRange;
    inline for (.{
        inputs.carbon_exchange_fraction_per_h,
        inputs.nutrient_exchange_fraction_per_h,
        inputs.timestep_h,
        inputs.structural_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteBranchReserveEquilibrationInput;
    if (inputs.carbon_exchange_fraction_per_h < 0 or inputs.nutrient_exchange_fraction_per_h < 0 or
        inputs.timestep_h <= 0 or inputs.structural_presence_threshold_g_c < 0)
        return error.InvalidBranchReserveEquilibrationInput;

    for (inputs.first_branch..inputs.end_branch, 0..) |branch, local| {
        inline for (.{
            state.sapwood_carbon_g_c[branch],   state.reserve_carbon_g_c[branch],
            state.reserve_nitrogen_g_n[branch], state.reserve_phosphorus_g_p[branch],
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidBranchReserveEquilibrationState;
        workspace.reserve_carbon_g_c[local] = state.reserve_carbon_g_c[branch];
        workspace.reserve_nitrogen_g_n[local] = state.reserve_nitrogen_g_n[branch];
        workspace.reserve_phosphorus_g_p[local] = state.reserve_phosphorus_g_p[branch];
    }
    const main_local = inputs.main_branch - inputs.first_branch;
    for (inputs.first_branch..inputs.end_branch, 0..) |other_branch, other_local| {
        if (other_branch == inputs.main_branch) continue;
        if (state.sapwood_carbon_g_c[other_branch] <= inputs.structural_presence_threshold_g_c) continue;
        try exchangePair(state, workspace, inputs, main_local, other_local, other_branch);
    }
    for (inputs.first_branch..inputs.end_branch, 0..) |branch, local| {
        state.reserve_carbon_g_c[branch] = workspace.reserve_carbon_g_c[local];
        state.reserve_nitrogen_g_n[branch] = workspace.reserve_nitrogen_g_n[local];
        state.reserve_phosphorus_g_p[branch] = workspace.reserve_phosphorus_g_p[local];
    }
}

fn exchangePair(state: State, workspace: Workspace, inputs: Inputs, main: usize, other: usize, other_branch: usize) !void {
    const total_sapwood_g_c = state.sapwood_carbon_g_c[inputs.main_branch] + state.sapwood_carbon_g_c[other_branch];
    if (!std.math.isFinite(total_sapwood_g_c) or total_sapwood_g_c <= 0)
        return error.InvalidBranchReserveSapwoodTotal;
    const initial_total_reserve_g_c = workspace.reserve_carbon_g_c[main] + workspace.reserve_carbon_g_c[other];
    const carbon_difference_g_c = (workspace.reserve_carbon_g_c[main] * state.sapwood_carbon_g_c[other_branch] -
        workspace.reserve_carbon_g_c[other] * state.sapwood_carbon_g_c[inputs.main_branch]) / total_sapwood_g_c;
    const carbon_flux_g_c = inputs.carbon_exchange_fraction_per_h * carbon_difference_g_c * inputs.timestep_h;
    workspace.reserve_carbon_g_c[main] -= carbon_flux_g_c;
    workspace.reserve_carbon_g_c[other] += carbon_flux_g_c;
    if (initial_total_reserve_g_c > inputs.structural_presence_threshold_g_c) {
        const nitrogen_difference_g_n = (workspace.reserve_nitrogen_g_n[main] * workspace.reserve_carbon_g_c[other] -
            workspace.reserve_nitrogen_g_n[other] * workspace.reserve_carbon_g_c[main]) / initial_total_reserve_g_c;
        const phosphorus_difference_g_p = (workspace.reserve_phosphorus_g_p[main] * workspace.reserve_carbon_g_c[other] -
            workspace.reserve_phosphorus_g_p[other] * workspace.reserve_carbon_g_c[main]) / initial_total_reserve_g_c;
        const nitrogen_flux_g_n = inputs.nutrient_exchange_fraction_per_h * nitrogen_difference_g_n * inputs.timestep_h;
        const phosphorus_flux_g_p = inputs.nutrient_exchange_fraction_per_h * phosphorus_difference_g_p * inputs.timestep_h;
        workspace.reserve_nitrogen_g_n[main] -= nitrogen_flux_g_n;
        workspace.reserve_nitrogen_g_n[other] += nitrogen_flux_g_n;
        workspace.reserve_phosphorus_g_p[main] -= phosphorus_flux_g_p;
        workspace.reserve_phosphorus_g_p[other] += phosphorus_flux_g_p;
    }
    inline for (.{
        workspace.reserve_carbon_g_c[main],     workspace.reserve_carbon_g_c[other],
        workspace.reserve_nitrogen_g_n[main],   workspace.reserve_nitrogen_g_n[other],
        workspace.reserve_phosphorus_g_p[main], workspace.reserve_phosphorus_g_p[other],
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.BranchReserveEquilibrationExhaustedPool;
}

test "GROSUB sweep honors explicit non-first main branch and source order" {
    const sapwood = [_]f64{ 1, 2, 1 };
    var carbon = [_]f64{ 0, 10, 4 };
    var nitrogen = [_]f64{ 0, 1, 0.4 };
    var phosphorus = [_]f64{ 0, 0.1, 0.04 };
    var work_c: [3]f64 = undefined;
    var work_n: [3]f64 = undefined;
    var work_p: [3]f64 = undefined;
    try apply(.{
        .sapwood_carbon_g_c = &sapwood,
        .reserve_carbon_g_c = &carbon,
        .reserve_nitrogen_g_n = &nitrogen,
        .reserve_phosphorus_g_p = &phosphorus,
    }, .{ .reserve_carbon_g_c = &work_c, .reserve_nitrogen_g_n = &work_n, .reserve_phosphorus_g_p = &work_p }, .{
        .first_branch = 0,
        .end_branch = 3,
        .main_branch = 1,
        .carbon_exchange_fraction_per_h = 0.5,
        .nutrient_exchange_fraction_per_h = 0,
        .timestep_h = 1,
        .structural_presence_threshold_g_c = 0,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 1.6666666666666667), carbon[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 8.277777777777779), carbon[1], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4.055555555555555), carbon[2], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 14), carbon[0] + carbon[1] + carbon[2], 1.0e-15);
}

test "nutrient gradient uses carbon after pair transfer" {
    const sapwood = [_]f64{ 2, 1 };
    var carbon = [_]f64{ 10, 2 };
    var nitrogen = [_]f64{ 1, 1 };
    var phosphorus = [_]f64{ 0.1, 0.1 };
    var work_c: [2]f64 = undefined;
    var work_n: [2]f64 = undefined;
    var work_p: [2]f64 = undefined;
    try apply(.{
        .sapwood_carbon_g_c = &sapwood,
        .reserve_carbon_g_c = &carbon,
        .reserve_nitrogen_g_n = &nitrogen,
        .reserve_phosphorus_g_p = &phosphorus,
    }, .{ .reserve_carbon_g_c = &work_c, .reserve_nitrogen_g_n = &work_n, .reserve_phosphorus_g_p = &work_p }, .{
        .first_branch = 0,
        .end_branch = 2,
        .main_branch = 0,
        .carbon_exchange_fraction_per_h = 0.5,
        .nutrient_exchange_fraction_per_h = 0.5,
        .timestep_h = 1,
        .structural_presence_threshold_g_c = 0,
    });
    // Carbon first becomes 9/3. N difference then uses (1*3 - 1*9)/12.
    try std.testing.expectEqual(@as(f64, 9), carbon[0]);
    try std.testing.expectEqual(@as(f64, 3), carbon[1]);
    try std.testing.expectEqual(@as(f64, 1.25), nitrogen[0]);
    try std.testing.expectEqual(@as(f64, 0.75), nitrogen[1]);
}

test "late pair failure leaves every branch unchanged" {
    const sapwood = [_]f64{ 1, 1, 1 };
    var carbon = [_]f64{ 10, 1, 1 };
    var nitrogen = [_]f64{ 1, 0.1, 0.1 };
    var phosphorus = [_]f64{ 0.1, 0.01, 0.01 };
    var work_c: [3]f64 = undefined;
    var work_n: [3]f64 = undefined;
    var work_p: [3]f64 = undefined;
    try std.testing.expectError(error.BranchReserveEquilibrationExhaustedPool, apply(.{
        .sapwood_carbon_g_c = &sapwood,
        .reserve_carbon_g_c = &carbon,
        .reserve_nitrogen_g_n = &nitrogen,
        .reserve_phosphorus_g_p = &phosphorus,
    }, .{ .reserve_carbon_g_c = &work_c, .reserve_nitrogen_g_n = &work_n, .reserve_phosphorus_g_p = &work_p }, .{
        .first_branch = 0,
        .end_branch = 3,
        .main_branch = 0,
        .carbon_exchange_fraction_per_h = 10,
        .nutrient_exchange_fraction_per_h = 0,
        .timestep_h = 1,
        .structural_presence_threshold_g_c = 0,
    }));
    try std.testing.expectEqual(@as(f64, 10), carbon[0]);
    try std.testing.expectEqual(@as(f64, 1), carbon[1]);
}

test "runtime dimensions workspace and main identity fail explicitly" {
    const sapwood = [_]f64{ 1, 1 };
    var carbon = [_]f64{ 1, 1 };
    var nitrogen = [_]f64{ 0.1, 0.1 };
    var phosphorus = [_]f64{ 0.01, 0.01 };
    var short: [1]f64 = undefined;
    try std.testing.expectError(error.BranchReserveEquilibrationWorkspaceTooSmall, apply(.{
        .sapwood_carbon_g_c = &sapwood,
        .reserve_carbon_g_c = &carbon,
        .reserve_nitrogen_g_n = &nitrogen,
        .reserve_phosphorus_g_p = &phosphorus,
    }, .{ .reserve_carbon_g_c = &short, .reserve_nitrogen_g_n = &short, .reserve_phosphorus_g_p = &short }, .{
        .first_branch = 0,
        .end_branch = 2,
        .main_branch = 0,
        .carbon_exchange_fraction_per_h = 0,
        .nutrient_exchange_fraction_per_h = 0,
        .timestep_h = 1,
        .structural_presence_threshold_g_c = 0,
    }));
}

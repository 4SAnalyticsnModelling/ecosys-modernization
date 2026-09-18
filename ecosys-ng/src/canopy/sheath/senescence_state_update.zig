// **PRODUCTION BOUND.** GROSUB 2757--2779 is projected before commit by the
// atomic selected-node transaction in `photosynthesis_node_layer`, preserving
// branch-before-node/mobile values and original-snapshot protein demand.
const std = @import("std");

pub const State = struct {
    branch_sheath_carbon_g_c: *f64,
    branch_sheath_nitrogen_g_n: *f64,
    branch_sheath_phosphorus_g_p: *f64,
    node_sheath_height_m: []f64,
    node_sheath_carbon_g_c: []f64,
    node_sheath_nitrogen_g_n: []f64,
    node_sheath_phosphorus_g_p: []f64,
    node_sheath_protein_g: []f64,
    branch_mobile_carbon_g_c: *f64,
    branch_mobile_nitrogen_g_n: *f64,
    branch_mobile_phosphorus_g_p: *f64,
};

pub const Snapshot = struct {
    sheath_height_m: f64,
    sheath_carbon_g_c: f64,
    sheath_nitrogen_g_n: f64,
    sheath_phosphorus_g_p: f64,
    remobilizable_carbon_g_c: f64,
    remobilizable_nitrogen_g_n: f64,
    remobilizable_phosphorus_g_p: f64,
};

pub const Inputs = struct {
    selected_node: usize,
    remobilization_fraction: f64,
    protein_per_nitrogen_g_per_g_n: f64,
    protein_per_phosphorus_g_per_g_p: f64,
    nonwoody_carbon_fraction: f64,
    nonwoody_nitrogen_fraction: f64,
    nonwoody_phosphorus_fraction: f64,
    snapshot: Snapshot,
};

pub const Result = struct {
    branch_carbon_g_c: f64,
    branch_nitrogen_g_n: f64,
    branch_phosphorus_g_p: f64,
    node_height_m: f64,
    node_carbon_g_c: f64,
    node_nitrogen_g_n: f64,
    node_phosphorus_g_p: f64,
    node_protein_g: f64,
    mobile_carbon_g_c: f64,
    mobile_nitrogen_g_n: f64,
    mobile_phosphorus_g_p: f64,
};

/// grosub.f lines 2757--2779. StateUpdates branch sheath totals, selected logical
/// node state, and mobile C/N/P in exact source order. Protein demand uses the
/// original senescing sheath N/P snapshot.
pub fn publish(state: State, inputs: Inputs) !void {
    const node_count = state.node_sheath_height_m.len;
    inline for (.{
        state.node_sheath_carbon_g_c,
        state.node_sheath_nitrogen_g_n,
        state.node_sheath_phosphorus_g_p,
        state.node_sheath_protein_g,
    }) |values| if (values.len != node_count)
        return error.SheathSenescenceStateDimensionMismatch;
    if (inputs.selected_node >= node_count)
        return error.SheathSenescenceStateIndexOutOfBounds;
    try validateInputs(inputs);
    const next = try calculate(state, inputs);

    state.branch_sheath_carbon_g_c.* = next.branch_carbon_g_c;
    state.branch_sheath_nitrogen_g_n.* = next.branch_nitrogen_g_n;
    state.branch_sheath_phosphorus_g_p.* = next.branch_phosphorus_g_p;
    state.node_sheath_height_m[inputs.selected_node] = next.node_height_m;
    state.node_sheath_carbon_g_c[inputs.selected_node] = next.node_carbon_g_c;
    state.node_sheath_nitrogen_g_n[inputs.selected_node] = next.node_nitrogen_g_n;
    state.node_sheath_phosphorus_g_p[inputs.selected_node] = next.node_phosphorus_g_p;
    state.node_sheath_protein_g[inputs.selected_node] = next.node_protein_g;
    state.branch_mobile_carbon_g_c.* = next.mobile_carbon_g_c;
    state.branch_mobile_nitrogen_g_n.* = next.mobile_nitrogen_g_n;
    state.branch_mobile_phosphorus_g_p.* = next.mobile_phosphorus_g_p;
}

fn validateInputs(inputs: Inputs) !void {
    inline for (.{
        inputs.remobilization_fraction,
        inputs.protein_per_nitrogen_g_per_g_n,
        inputs.protein_per_phosphorus_g_per_g_p,
        inputs.nonwoody_carbon_fraction,
        inputs.nonwoody_nitrogen_fraction,
        inputs.nonwoody_phosphorus_fraction,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSheathSenescenceStateInput;
    if (inputs.remobilization_fraction < 0 or inputs.remobilization_fraction > 1 or
        inputs.protein_per_nitrogen_g_per_g_n < 0 or inputs.protein_per_phosphorus_g_per_g_p < 0 or
        inputs.nonwoody_carbon_fraction < 0 or inputs.nonwoody_carbon_fraction > 1 or
        inputs.nonwoody_nitrogen_fraction < 0 or inputs.nonwoody_nitrogen_fraction > 1 or
        inputs.nonwoody_phosphorus_fraction < 0 or inputs.nonwoody_phosphorus_fraction > 1)
        return error.InvalidSheathSenescenceStateInput;
    inline for (@typeInfo(Snapshot).@"struct".fields) |field| {
        const value = @field(inputs.snapshot, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSheathSenescenceStateSnapshot;
    }
    if (inputs.snapshot.remobilizable_carbon_g_c > inputs.snapshot.sheath_carbon_g_c or
        inputs.snapshot.remobilizable_nitrogen_g_n > inputs.snapshot.sheath_nitrogen_g_n or
        inputs.snapshot.remobilizable_phosphorus_g_p > inputs.snapshot.sheath_phosphorus_g_p)
        return error.InvalidSheathSenescenceStateSnapshot;
}

/// Pure projection for composing the sheath update into an atomic selected-node
/// transaction. `publish` remains the standalone source-order state_update.
pub fn calculate(state: State, inputs: Inputs) !Result {
    const node = inputs.selected_node;
    const fraction = inputs.remobilization_fraction;
    const snapshot = inputs.snapshot;
    const protein_removal_g = fraction * @max(
        snapshot.sheath_nitrogen_g_n * inputs.protein_per_nitrogen_g_per_g_n,
        snapshot.sheath_phosphorus_g_p * inputs.protein_per_phosphorus_g_per_g_p,
    );
    const result: Result = .{
        .branch_carbon_g_c = state.branch_sheath_carbon_g_c.* - fraction * snapshot.sheath_carbon_g_c,
        .branch_nitrogen_g_n = state.branch_sheath_nitrogen_g_n.* - fraction * snapshot.sheath_nitrogen_g_n,
        .branch_phosphorus_g_p = state.branch_sheath_phosphorus_g_p.* - fraction * snapshot.sheath_phosphorus_g_p,
        .node_height_m = state.node_sheath_height_m[node] - fraction * snapshot.sheath_height_m,
        .node_carbon_g_c = state.node_sheath_carbon_g_c[node] - fraction * snapshot.sheath_carbon_g_c,
        .node_nitrogen_g_n = state.node_sheath_nitrogen_g_n[node] - fraction * snapshot.sheath_nitrogen_g_n,
        .node_phosphorus_g_p = state.node_sheath_phosphorus_g_p[node] - fraction * snapshot.sheath_phosphorus_g_p,
        // GROSUB 2771-2773/3177-3179 explicitly floors this derived protein
        // diagnostic. Conserved sheath C/N/P inventories remain fail-closed.
        .node_protein_g = @max(0, state.node_sheath_protein_g[node] - protein_removal_g),
        .mobile_carbon_g_c = state.branch_mobile_carbon_g_c.* + fraction * snapshot.remobilizable_carbon_g_c * inputs.nonwoody_carbon_fraction,
        .mobile_nitrogen_g_n = state.branch_mobile_nitrogen_g_n.* + fraction * snapshot.remobilizable_nitrogen_g_n * inputs.nonwoody_nitrogen_fraction,
        .mobile_phosphorus_g_p = state.branch_mobile_phosphorus_g_p.* + fraction * snapshot.remobilizable_phosphorus_g_p * inputs.nonwoody_phosphorus_fraction,
    };
    inline for (@typeInfo(Result).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSheathSenescenceStateResult;
    }
    return result;
}

fn sampleInputs(node: usize) Inputs {
    return .{
        .selected_node = node,
        .remobilization_fraction = 0.25,
        .protein_per_nitrogen_g_per_g_n = 2,
        .protein_per_phosphorus_g_per_g_p = 20,
        .nonwoody_carbon_fraction = 0.8,
        .nonwoody_nitrogen_fraction = 0.9,
        .nonwoody_phosphorus_fraction = 0.7,
        .snapshot = .{
            .sheath_height_m = 0.8,
            .sheath_carbon_g_c = 8,
            .sheath_nitrogen_g_n = 0.8,
            .sheath_phosphorus_g_p = 0.16,
            .remobilizable_carbon_g_c = 4,
            .remobilizable_nitrogen_g_n = 0.64,
            .remobilizable_phosphorus_g_p = 0.136,
        },
    };
}

fn makeState(storage: *[5][31]f64, branch: *[6]f64) State {
    return .{
        .branch_sheath_carbon_g_c = &branch[0],
        .branch_sheath_nitrogen_g_n = &branch[1],
        .branch_sheath_phosphorus_g_p = &branch[2],
        .node_sheath_height_m = &storage[0],
        .node_sheath_carbon_g_c = &storage[1],
        .node_sheath_nitrogen_g_n = &storage[2],
        .node_sheath_phosphorus_g_p = &storage[3],
        .node_sheath_protein_g = &storage[4],
        .branch_mobile_carbon_g_c = &branch[3],
        .branch_mobile_nitrogen_g_n = &branch[4],
        .branch_mobile_phosphorus_g_p = &branch[5],
    };
}

test "GROSUB sheath state_update uses original snapshot for protein" {
    var storage: [5][31]f64 = @splat(@splat(0));
    var branch = [_]f64{ 16, 1.6, 0.32, 1, 0.1, 0.01 };
    storage[0][2] = 0.8;
    storage[1][2] = 8;
    storage[2][2] = 0.8;
    storage[3][2] = 0.16;
    storage[4][2] = 3;
    try publish(makeState(&storage, &branch), sampleInputs(2));
    try std.testing.expectEqual(@as(f64, 6), storage[1][2]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), storage[2][2], 1.0e-15);
    // max(original N*2, original P*20)=3.2; removal=0.8.
    try std.testing.expectApproxEqAbs(@as(f64, 2.2), storage[4][2], 1.0e-15);
    try std.testing.expectEqual(@as(f64, 14), branch[0]);
    try std.testing.expectEqual(@as(f64, 1.8), branch[3]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.244), branch[4], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0338), branch[5], 1.0e-15);
}

test "runtime logical node beyond source ring publishes directly" {
    var storage: [5][31]f64 = @splat(@splat(0));
    var branch = [_]f64{ 8, 0.8, 0.16, 0, 0, 0 };
    storage[0][30] = 0.8;
    storage[1][30] = 8;
    storage[2][30] = 0.8;
    storage[3][30] = 0.16;
    storage[4][30] = 4;
    try publish(makeState(&storage, &branch), sampleInputs(30));
    try std.testing.expectEqual(@as(f64, 6), storage[1][30]);
    try std.testing.expectEqual(@as(f64, 0), storage[1][5]);
}

test "late mobile overflow leaves all state unchanged" {
    var storage: [5][31]f64 = @splat(@splat(0));
    var branch = [_]f64{ 8, 0.8, 0.16, 0, 0, std.math.floatMax(f64) };
    storage[0][0] = 0.8;
    storage[1][0] = 8;
    storage[2][0] = 0.8;
    storage[3][0] = 0.16;
    storage[4][0] = 4;
    var inputs = sampleInputs(0);
    inputs.snapshot.remobilizable_phosphorus_g_p = std.math.floatMax(f64);
    inputs.snapshot.sheath_phosphorus_g_p = std.math.floatMax(f64);
    inputs.nonwoody_phosphorus_fraction = 1;
    try std.testing.expectError(error.InvalidSheathSenescenceStateResult, publish(makeState(&storage, &branch), inputs));
    try std.testing.expectEqual(@as(f64, 8), branch[0]);
    try std.testing.expectEqual(@as(f64, 8), storage[1][0]);
}

test "dimension and index errors fail explicitly" {
    var storage: [5][31]f64 = @splat(@splat(0));
    var branch: [6]f64 = @splat(0);
    var state = makeState(&storage, &branch);
    state.node_sheath_protein_g = state.node_sheath_protein_g[0..30];
    try std.testing.expectError(error.SheathSenescenceStateDimensionMismatch, publish(state, sampleInputs(0)));
    try std.testing.expectError(error.SheathSenescenceStateIndexOutOfBounds, publish(makeState(&storage, &branch), sampleInputs(31)));
}

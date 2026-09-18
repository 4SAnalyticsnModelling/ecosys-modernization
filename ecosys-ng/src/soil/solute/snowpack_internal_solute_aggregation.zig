const std = @import("std");

/// Non-salt solute transport across a snow-layer face. Carbon, nitrogen,
/// oxygen, and phosphorus carriers use the elemental gram basis tracked by
/// ecosys and are integrated over one model step.
pub const SoluteFlux = struct {
    carbon_dioxide_g_c_per_step: f64 = 0,
    methane_g_c_per_step: f64 = 0,
    oxygen_g_o_per_step: f64 = 0,
    dinitrogen_g_n_per_step: f64 = 0,
    nitrous_oxide_g_n_per_step: f64 = 0,
    ammonium_g_n_per_step: f64 = 0,
    ammonia_g_n_per_step: f64 = 0,
    nitrate_g_n_per_step: f64 = 0,
    hydrogen_phosphate_g_p_per_step: f64 = 0,
    dihydrogen_phosphate_g_p_per_step: f64 = 0,
};

pub const Inputs = struct {
    /// Current snow heat capacity [snow_layer], MJ K^-1.
    heat_capacity_megajoules_per_k_by_layer: []const f64,
    /// Snow-layer presence threshold, MJ K^-1.
    minimum_heat_capacity_megajoules_per_k: f64,
    /// `X*BLS(LS)` at each layer's upper face [snow_layer].
    upper_face_flux_by_layer: []const SoluteFlux,
};

pub const State = struct {
    /// Accumulated `T*BLS` internal divergence [snow_layer].
    net_flux_by_layer: []SoluteFlux,
};

/// Caller-owned runtime scratch makes failure atomic without allocating in the
/// snow transport kernel.
pub const Workspace = struct {
    net_flux_by_layer: []SoluteFlux,
};

/// Aggregates non-salt solute divergence across internal snow-layer faces.
///
/// Traceability: REDIST.F lines 2455--2474 (`TCOBLS`--`TH2PBS`), under
/// the active current/lower snow-layer gates at lines 2417 and 2422. Runtime
/// slices replace `JS`. For each valid adjacent pair, the source association
/// `T(LS) + X(LS) - X(LS+1)` is retained for all ten species. The lowest
/// active layer and snow-surface input are separate source branches.
pub fn aggregate(inputs: Inputs, state: *State, workspace: Workspace) !void {
    try validateDimensions(inputs, state.*, workspace);
    try validateInputs(inputs, state.*, workspace);
    @memcpy(workspace.net_flux_by_layer, state.net_flux_by_layer);

    const layer_count = inputs.heat_capacity_megajoules_per_k_by_layer.len;
    for (0..layer_count - 1) |layer| {
        if (inputs.heat_capacity_megajoules_per_k_by_layer[layer] <=
            inputs.minimum_heat_capacity_megajoules_per_k or
            inputs.heat_capacity_megajoules_per_k_by_layer[layer + 1] <=
                inputs.minimum_heat_capacity_megajoules_per_k)
        {
            continue;
        }
        try updateLayer(
            &workspace.net_flux_by_layer[layer],
            inputs.upper_face_flux_by_layer[layer],
            inputs.upper_face_flux_by_layer[layer + 1],
        );
    }

    @memcpy(state.net_flux_by_layer, workspace.net_flux_by_layer);
}

fn validateDimensions(inputs: Inputs, state: State, workspace: Workspace) !void {
    const layer_count = inputs.heat_capacity_megajoules_per_k_by_layer.len;
    if (layer_count == 0) return error.InvalidSnowpackSoluteDimensions;
    if (inputs.upper_face_flux_by_layer.len != layer_count or
        state.net_flux_by_layer.len != layer_count or
        workspace.net_flux_by_layer.len != layer_count)
    {
        return error.SnowpackSoluteDimensionMismatch;
    }
}

fn validateInputs(inputs: Inputs, state: State, workspace: Workspace) !void {
    if (!std.math.isFinite(inputs.minimum_heat_capacity_megajoules_per_k))
        return error.NonFiniteSnowpackSoluteInput;
    if (inputs.minimum_heat_capacity_megajoules_per_k < 0)
        return error.InvalidSnowpackHeatCapacity;
    for (inputs.heat_capacity_megajoules_per_k_by_layer) |capacity| {
        if (!std.math.isFinite(capacity))
            return error.NonFiniteSnowpackSoluteInput;
        if (capacity < 0) return error.InvalidSnowpackHeatCapacity;
    }
    try validateFinite(inputs.upper_face_flux_by_layer);
    try validateFinite(state.net_flux_by_layer);
    if (overlap(workspace.net_flux_by_layer, state.net_flux_by_layer) or
        overlap(workspace.net_flux_by_layer, inputs.upper_face_flux_by_layer))
    {
        return error.SnowpackSoluteWorkspaceOverlap;
    }
}

fn validateFinite(values: []const SoluteFlux) !void {
    for (values) |value| {
        inline for (@typeInfo(SoluteFlux).@"struct".fields) |field|
            if (!std.math.isFinite(@field(value, field.name)))
                return error.NonFiniteSnowpackSoluteInput;
    }
}

fn updateLayer(
    candidate: *SoluteFlux,
    upper_face: SoluteFlux,
    lower_face: SoluteFlux,
) !void {
    inline for (@typeInfo(SoluteFlux).@"struct".fields) |field| {
        const after_upper = @field(candidate.*, field.name) +
            @field(upper_face, field.name);
        if (!std.math.isFinite(after_upper))
            return error.NonFiniteSnowpackSoluteResult;
        const after_lower = after_upper - @field(lower_face, field.name);
        if (!std.math.isFinite(after_lower))
            return error.NonFiniteSnowpackSoluteResult;
        @field(candidate.*, field.name) = after_lower;
    }
}

fn overlap(left: []const SoluteFlux, right: []const SoluteFlux) bool {
    if (left.len == 0 or right.len == 0) return false;
    const item_size = @sizeOf(SoluteFlux);
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, item_size) catch return true;
    const right_bytes = std.math.mul(usize, right.len, item_size) catch return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn filledFlux(value: f64) SoluteFlux {
    var result: SoluteFlux = undefined;
    inline for (@typeInfo(SoluteFlux).@"struct".fields) |field|
        @field(result, field.name) = value;
    return result;
}

fn expectFlux(actual: SoluteFlux, expected: f64) !void {
    inline for (@typeInfo(SoluteFlux).@"struct".fields) |field|
        try std.testing.expectEqual(expected, @field(actual, field.name));
}

test "internal snow solute faces retain source species and layer order" {
    const capacities = [_]f64{ 2, 2, 2, 2 };
    const face_fluxes = [_]SoluteFlux{
        filledFlux(10),
        filledFlux(6),
        filledFlux(2),
        filledFlux(1),
    };
    var totals = [_]SoluteFlux{.{}} ** 4;
    var scratch: [4]SoluteFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_flux_by_layer = &face_fluxes,
    }, &state, .{ .net_flux_by_layer = &scratch });

    try expectFlux(state.net_flux_by_layer[0], 4);
    try expectFlux(state.net_flux_by_layer[1], 4);
    try expectFlux(state.net_flux_by_layer[2], 1);
    try expectFlux(state.net_flux_by_layer[3], 0);
}

test "internal face cancellation closes every elemental carrier exactly" {
    const capacities = [_]f64{ 2, 2, 2, 2 };
    const face_fluxes = [_]SoluteFlux{
        filledFlux(10),
        filledFlux(6),
        filledFlux(2),
        filledFlux(1),
    };
    var totals = [_]SoluteFlux{.{}} ** 4;
    var scratch: [4]SoluteFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_flux_by_layer = &face_fluxes,
    }, &state, .{ .net_flux_by_layer = &scratch });

    var column_total = filledFlux(0);
    for (state.net_flux_by_layer) |layer_flux| {
        inline for (@typeInfo(SoluteFlux).@"struct".fields) |field|
            @field(column_total, field.name) += @field(layer_flux, field.name);
    }
    inline for (@typeInfo(SoluteFlux).@"struct".fields) |field| {
        const top_input = @field(face_fluxes[0], field.name);
        const lower_export = @field(face_fluxes[3], field.name);
        try std.testing.expectEqual(
            top_input - lower_export,
            @field(column_total, field.name),
        );
    }
}

test "inactive adjacent layers preserve REDIST snow presence gates" {
    const capacities = [_]f64{ 2, 0, 2, 2 };
    const face_fluxes = [_]SoluteFlux{
        filledFlux(10),
        filledFlux(6),
        filledFlux(4),
        filledFlux(1),
    };
    var totals = [_]SoluteFlux{filledFlux(100)} ** 4;
    var scratch: [4]SoluteFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_flux_by_layer = &face_fluxes,
    }, &state, .{ .net_flux_by_layer = &scratch });

    try expectFlux(state.net_flux_by_layer[0], 100);
    try expectFlux(state.net_flux_by_layer[1], 100);
    try expectFlux(state.net_flux_by_layer[2], 103);
    try expectFlux(state.net_flux_by_layer[3], 100);
}

test "runtime snow layer extent and ten source species are explicit" {
    try std.testing.expectEqual(
        @as(usize, 10),
        @typeInfo(SoluteFlux).@"struct".fields.len,
    );
    const capacities = [_]f64{2} ** 7;
    const face_fluxes = [_]SoluteFlux{filledFlux(1)} ** 7;
    var totals = [_]SoluteFlux{.{}} ** 7;
    var scratch: [7]SoluteFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_flux_by_layer = &face_fluxes,
    }, &state, .{ .net_flux_by_layer = &scratch });

    for (state.net_flux_by_layer) |layer| try expectFlux(layer, 0);
}

test "source floating point association is retained" {
    const capacities = [_]f64{ 2, 2 };
    const face_fluxes = [_]SoluteFlux{ filledFlux(-1.0e16), filledFlux(1) };
    var totals = [_]SoluteFlux{ filledFlux(1.0e16), .{} };
    var scratch: [2]SoluteFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };

    try aggregate(.{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_flux_by_layer = &face_fluxes,
    }, &state, .{ .net_flux_by_layer = &scratch });

    try expectFlux(state.net_flux_by_layer[0], -1);
}

test "invalid late input and overflow preserve state atomically" {
    const capacities = [_]f64{ 2, 2 };
    var face_fluxes = [_]SoluteFlux{ filledFlux(1), filledFlux(1) };
    face_fluxes[1].dihydrogen_phosphate_g_p_per_step = std.math.nan(f64);
    var totals = [_]SoluteFlux{filledFlux(3)} ** 2;
    var scratch: [2]SoluteFlux = undefined;
    var state = State{ .net_flux_by_layer = &totals };
    const workspace = Workspace{ .net_flux_by_layer = &scratch };

    try std.testing.expectError(
        error.NonFiniteSnowpackSoluteInput,
        aggregate(.{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_flux_by_layer = &face_fluxes,
        }, &state, workspace),
    );
    for (state.net_flux_by_layer) |layer| try expectFlux(layer, 3);

    face_fluxes[1] = filledFlux(0);
    face_fluxes[0] = filledFlux(std.math.floatMax(f64));
    totals[0] = filledFlux(std.math.floatMax(f64));
    try std.testing.expectError(
        error.NonFiniteSnowpackSoluteResult,
        aggregate(.{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_flux_by_layer = &face_fluxes,
        }, &state, workspace),
    );
    try expectFlux(state.net_flux_by_layer[0], std.math.floatMax(f64));
    try expectFlux(state.net_flux_by_layer[1], 3);
}

test "dimension and workspace alias errors precede mutation" {
    const capacities = [_]f64{ 2, 2 };
    const face_fluxes = [_]SoluteFlux{ filledFlux(1), filledFlux(1) };
    var totals = [_]SoluteFlux{filledFlux(5)} ** 2;
    var state = State{ .net_flux_by_layer = &totals };

    try std.testing.expectError(
        error.SnowpackSoluteWorkspaceOverlap,
        aggregate(.{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_flux_by_layer = &face_fluxes,
        }, &state, .{ .net_flux_by_layer = &totals }),
    );
    for (state.net_flux_by_layer) |layer| try expectFlux(layer, 5);

    var short_scratch: [1]SoluteFlux = undefined;
    try std.testing.expectError(
        error.SnowpackSoluteDimensionMismatch,
        aggregate(.{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_flux_by_layer = &face_fluxes,
        }, &state, .{ .net_flux_by_layer = &short_scratch }),
    );
    for (state.net_flux_by_layer) |layer| try expectFlux(layer, 5);
}

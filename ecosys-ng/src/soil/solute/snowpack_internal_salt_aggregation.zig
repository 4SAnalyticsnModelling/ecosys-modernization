const std = @import("std");

pub const SaltEquilibriumMode = enum {
    static,
    dynamic,
};

/// Snow salt species in the exact REDIST update order. Snow transport has no
/// runoff-only hydrogen-sulfate entry.
pub const SaltSpecies = enum {
    aluminum,
    iron,
    hydrogen,
    calcium,
    magnesium,
    sodium,
    potassium,
    hydroxide,
    sulfate,
    chloride,
    carbonate,
    bicarbonate,
    aluminum_monohydroxide,
    aluminum_dihydroxide,
    aluminum_trihydroxide,
    aluminum_tetrahydroxide,
    aluminum_sulfate,
    iron_monohydroxide,
    iron_dihydroxide,
    iron_trihydroxide,
    iron_tetrahydroxide,
    iron_sulfate,
    calcium_hydroxide,
    calcium_carbonate,
    calcium_bicarbonate,
    calcium_sulfate,
    magnesium_hydroxide,
    magnesium_carbonate,
    magnesium_bicarbonate,
    magnesium_sulfate,
    sodium_carbonate,
    sodium_sulfate,
    potassium_sulfate,
    phosphate,
    phosphoric_acid,
    iron_hydrogen_phosphate,
    iron_dihydrogen_phosphate,
    calcium_phosphate,
    calcium_hydrogen_phosphate,
    calcium_dihydrogen_phosphate,
    magnesium_hydrogen_phosphate,
};

pub const salt_species_count = @typeInfo(SaltSpecies).@"enum".fields.len;

pub const Inputs = struct {
    /// Current snow heat capacity [snow_layer], MJ K^-1.
    heat_capacity_megajoules_per_k_by_layer: []const f64,
    /// Snow-layer presence threshold, MJ K^-1.
    minimum_heat_capacity_megajoules_per_k: f64,
    /// `X*BLS(LS)` [snow_layer][salt_species], mol per model step.
    upper_face_mol_per_step_by_layer_species: []const f64,
};

pub const State = struct {
    /// Accumulated `T*BLS` [snow_layer][salt_species], mol per model step.
    net_mol_per_step_by_layer_species: []f64,
};

/// Caller-owned runtime scratch makes failure atomic without allocation inside
/// the snow transport kernel.
pub const Workspace = struct {
    net_mol_per_step_by_layer_species: []f64,
};

/// Aggregates dynamic salt divergence across internal snow-layer faces.
///
/// Traceability: REDIST.F lines 2500--2583 (`TALBLS`--`TM1PBS`), under
/// the active current/lower snow-layer gates at lines 2417 and 2422. Runtime
/// slices replace `JS`; species are layer-major in source update order. Each
/// adjacent active pair retains `T(LS) + X(LS) - X(LS+1)`. Static equilibrium
/// bypasses this block exactly. State state_updates only after all values are finite.
pub fn aggregate(
    equilibrium_mode: SaltEquilibriumMode,
    inputs: Inputs,
    state: *State,
    workspace: Workspace,
) !void {
    if (equilibrium_mode == .static) return;

    const layer_count = try validateDimensions(inputs, state.*, workspace);
    try validateInputs(inputs, state.*, workspace);
    @memcpy(
        workspace.net_mol_per_step_by_layer_species,
        state.net_mol_per_step_by_layer_species,
    );

    for (0..layer_count - 1) |layer| {
        if (inputs.heat_capacity_megajoules_per_k_by_layer[layer] <=
            inputs.minimum_heat_capacity_megajoules_per_k or
            inputs.heat_capacity_megajoules_per_k_by_layer[layer + 1] <=
                inputs.minimum_heat_capacity_megajoules_per_k)
        {
            continue;
        }
        const current_offset = layer * salt_species_count;
        const lower_offset = (layer + 1) * salt_species_count;
        for (0..salt_species_count) |species| {
            const index = current_offset + species;
            const after_upper = workspace.net_mol_per_step_by_layer_species[index] +
                inputs.upper_face_mol_per_step_by_layer_species[index];
            if (!std.math.isFinite(after_upper))
                return error.NonFiniteSnowpackSaltResult;
            const after_lower = after_upper -
                inputs.upper_face_mol_per_step_by_layer_species[lower_offset + species];
            if (!std.math.isFinite(after_lower))
                return error.NonFiniteSnowpackSaltResult;
            workspace.net_mol_per_step_by_layer_species[index] = after_lower;
        }
    }

    @memcpy(
        state.net_mol_per_step_by_layer_species,
        workspace.net_mol_per_step_by_layer_species,
    );
}

fn validateDimensions(inputs: Inputs, state: State, workspace: Workspace) !usize {
    const layer_count = inputs.heat_capacity_megajoules_per_k_by_layer.len;
    if (layer_count == 0) return error.InvalidSnowpackSaltDimensions;
    const value_count = std.math.mul(
        usize,
        layer_count,
        salt_species_count,
    ) catch return error.InvalidSnowpackSaltDimensions;
    if (inputs.upper_face_mol_per_step_by_layer_species.len != value_count or
        state.net_mol_per_step_by_layer_species.len != value_count or
        workspace.net_mol_per_step_by_layer_species.len != value_count)
    {
        return error.SnowpackSaltDimensionMismatch;
    }
    return layer_count;
}

fn validateInputs(inputs: Inputs, state: State, workspace: Workspace) !void {
    if (!std.math.isFinite(inputs.minimum_heat_capacity_megajoules_per_k))
        return error.NonFiniteSnowpackSaltInput;
    if (inputs.minimum_heat_capacity_megajoules_per_k < 0)
        return error.InvalidSnowpackHeatCapacity;
    for (inputs.heat_capacity_megajoules_per_k_by_layer) |capacity| {
        if (!std.math.isFinite(capacity))
            return error.NonFiniteSnowpackSaltInput;
        if (capacity < 0) return error.InvalidSnowpackHeatCapacity;
    }
    try validateFinite(inputs.upper_face_mol_per_step_by_layer_species);
    try validateFinite(state.net_mol_per_step_by_layer_species);
    if (overlap(
        workspace.net_mol_per_step_by_layer_species,
        state.net_mol_per_step_by_layer_species,
    ) or overlap(
        workspace.net_mol_per_step_by_layer_species,
        inputs.upper_face_mol_per_step_by_layer_species,
    )) {
        return error.SnowpackSaltWorkspaceOverlap;
    }
}

fn validateFinite(values: []const f64) !void {
    for (values) |value|
        if (!std.math.isFinite(value))
            return error.NonFiniteSnowpackSaltInput;
}

fn overlap(left: []const f64, right: []const f64) bool {
    if (left.len == 0 or right.len == 0) return false;
    const item_size = @sizeOf(f64);
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_bytes = std.math.mul(usize, left.len, item_size) catch return true;
    const right_bytes = std.math.mul(usize, right.len, item_size) catch return true;
    const left_end = std.math.add(usize, left_start, left_bytes) catch return true;
    const right_end = std.math.add(usize, right_start, right_bytes) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn layerValues(values: []f64, layer: usize) []f64 {
    const start = layer * salt_species_count;
    return values[start .. start + salt_species_count];
}

fn layerValuesConst(values: []const f64, layer: usize) []const f64 {
    const start = layer * salt_species_count;
    return values[start .. start + salt_species_count];
}

fn expectLayerValue(values: []const f64, layer: usize, expected: f64) !void {
    for (layerValuesConst(values, layer)) |value|
        try std.testing.expectEqual(expected, value);
}

test "dynamic internal salt divergence retains layer and species order" {
    const layer_count = 4;
    const capacities = [_]f64{2} ** layer_count;
    var face_fluxes = [_]f64{0} ** (layer_count * salt_species_count);
    for (layerValues(&face_fluxes, 0), 0..) |*value, species|
        value.* = 100 + @as(f64, @floatFromInt(species));
    for (layerValues(&face_fluxes, 1), 0..) |*value, species|
        value.* = 90 + @as(f64, @floatFromInt(species));
    for (layerValues(&face_fluxes, 2), 0..) |*value, species|
        value.* = 70 + @as(f64, @floatFromInt(species));
    for (layerValues(&face_fluxes, 3), 0..) |*value, species|
        value.* = 65 + @as(f64, @floatFromInt(species));
    var totals = [_]f64{0} ** (layer_count * salt_species_count);
    var scratch: [layer_count * salt_species_count]f64 = undefined;
    var state = State{ .net_mol_per_step_by_layer_species = &totals };

    try aggregate(.dynamic, .{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_mol_per_step_by_layer_species = &face_fluxes,
    }, &state, .{ .net_mol_per_step_by_layer_species = &scratch });

    try expectLayerValue(state.net_mol_per_step_by_layer_species, 0, 10);
    try expectLayerValue(state.net_mol_per_step_by_layer_species, 1, 20);
    try expectLayerValue(state.net_mol_per_step_by_layer_species, 2, 5);
    try expectLayerValue(state.net_mol_per_step_by_layer_species, 3, 0);
}

test "internal faces conserve every salt species exactly" {
    const layer_count = 4;
    const capacities = [_]f64{2} ** layer_count;
    var face_fluxes = [_]f64{0} ** (layer_count * salt_species_count);
    @memset(layerValues(&face_fluxes, 0), 10);
    @memset(layerValues(&face_fluxes, 1), 6);
    @memset(layerValues(&face_fluxes, 2), 2);
    @memset(layerValues(&face_fluxes, 3), 1);
    var totals = [_]f64{0} ** (layer_count * salt_species_count);
    var scratch: [layer_count * salt_species_count]f64 = undefined;
    var state = State{ .net_mol_per_step_by_layer_species = &totals };

    try aggregate(.dynamic, .{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_mol_per_step_by_layer_species = &face_fluxes,
    }, &state, .{ .net_mol_per_step_by_layer_species = &scratch });

    for (0..salt_species_count) |species| {
        var column_total: f64 = 0;
        for (0..layer_count) |layer|
            column_total += totals[layer * salt_species_count + species];
        try std.testing.expectEqual(
            face_fluxes[species] -
                face_fluxes[(layer_count - 1) * salt_species_count + species],
            column_total,
        );
    }
}

test "species layout and runtime snow layer extent are explicit" {
    try std.testing.expectEqual(@as(usize, 41), salt_species_count);
    try std.testing.expectEqual(
        @as(usize, 32),
        @intFromEnum(SaltSpecies.potassium_sulfate),
    );
    try std.testing.expectEqual(
        @as(usize, 33),
        @intFromEnum(SaltSpecies.phosphate),
    );
    try std.testing.expectEqual(
        @as(usize, 40),
        @intFromEnum(SaltSpecies.magnesium_hydrogen_phosphate),
    );

    const layer_count = 7;
    const capacities = [_]f64{2} ** layer_count;
    const face_fluxes = [_]f64{1} ** (layer_count * salt_species_count);
    var totals = [_]f64{0} ** (layer_count * salt_species_count);
    var scratch: [layer_count * salt_species_count]f64 = undefined;
    var state = State{ .net_mol_per_step_by_layer_species = &totals };
    try aggregate(.dynamic, .{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_mol_per_step_by_layer_species = &face_fluxes,
    }, &state, .{ .net_mol_per_step_by_layer_species = &scratch });
    for (totals) |value| try std.testing.expectEqual(@as(f64, 0), value);
}

test "inactive adjacent layers preserve source capacity gates" {
    const layer_count = 4;
    const capacities = [_]f64{ 2, 0, 2, 2 };
    var face_fluxes = [_]f64{0} ** (layer_count * salt_species_count);
    @memset(layerValues(&face_fluxes, 0), 10);
    @memset(layerValues(&face_fluxes, 1), 6);
    @memset(layerValues(&face_fluxes, 2), 4);
    @memset(layerValues(&face_fluxes, 3), 1);
    var totals = [_]f64{100} ** (layer_count * salt_species_count);
    var scratch: [layer_count * salt_species_count]f64 = undefined;
    var state = State{ .net_mol_per_step_by_layer_species = &totals };

    try aggregate(.dynamic, .{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_mol_per_step_by_layer_species = &face_fluxes,
    }, &state, .{ .net_mol_per_step_by_layer_species = &scratch });

    try expectLayerValue(&totals, 0, 100);
    try expectLayerValue(&totals, 1, 100);
    try expectLayerValue(&totals, 2, 103);
    try expectLayerValue(&totals, 3, 100);
}

test "static equilibrium bypasses dynamic dimensions and mutation" {
    var totals = [_]f64{11};
    var scratch = [_]f64{13};
    var state = State{ .net_mol_per_step_by_layer_species = &totals };
    try aggregate(.static, .{
        .heat_capacity_megajoules_per_k_by_layer = &.{},
        .minimum_heat_capacity_megajoules_per_k = std.math.nan(f64),
        .upper_face_mol_per_step_by_layer_species = &.{},
    }, &state, .{ .net_mol_per_step_by_layer_species = &scratch });
    try std.testing.expectEqual(@as(f64, 11), totals[0]);
    try std.testing.expectEqual(@as(f64, 13), scratch[0]);
}

test "source association and atomic failure behavior are retained" {
    const layer_count = 2;
    const capacities = [_]f64{2} ** layer_count;
    var face_fluxes = [_]f64{0} ** (layer_count * salt_species_count);
    @memset(layerValues(&face_fluxes, 0), -1.0e16);
    @memset(layerValues(&face_fluxes, 1), 1);
    var totals = [_]f64{0} ** (layer_count * salt_species_count);
    @memset(layerValues(&totals, 0), 1.0e16);
    var scratch: [layer_count * salt_species_count]f64 = undefined;
    var state = State{ .net_mol_per_step_by_layer_species = &totals };
    const workspace = Workspace{ .net_mol_per_step_by_layer_species = &scratch };

    try aggregate(.dynamic, .{
        .heat_capacity_megajoules_per_k_by_layer = &capacities,
        .minimum_heat_capacity_megajoules_per_k = 1,
        .upper_face_mol_per_step_by_layer_species = &face_fluxes,
    }, &state, workspace);
    try expectLayerValue(&totals, 0, -1);

    @memset(layerValues(&totals, 0), 3);
    face_fluxes[face_fluxes.len - 1] = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteSnowpackSaltInput,
        aggregate(.dynamic, .{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_mol_per_step_by_layer_species = &face_fluxes,
        }, &state, workspace),
    );
    try expectLayerValue(&totals, 0, 3);

    face_fluxes[face_fluxes.len - 1] = 0;
    @memset(layerValues(&face_fluxes, 0), std.math.floatMax(f64));
    @memset(layerValues(&totals, 0), std.math.floatMax(f64));
    try std.testing.expectError(
        error.NonFiniteSnowpackSaltResult,
        aggregate(.dynamic, .{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_mol_per_step_by_layer_species = &face_fluxes,
        }, &state, workspace),
    );
    try expectLayerValue(&totals, 0, std.math.floatMax(f64));
}

test "dimension and workspace alias errors precede mutation" {
    const capacities = [_]f64{ 2, 2 };
    const face_fluxes = [_]f64{1} ** (2 * salt_species_count);
    var totals = [_]f64{5} ** (2 * salt_species_count);
    var state = State{ .net_mol_per_step_by_layer_species = &totals };

    try std.testing.expectError(
        error.SnowpackSaltWorkspaceOverlap,
        aggregate(.dynamic, .{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_mol_per_step_by_layer_species = &face_fluxes,
        }, &state, .{ .net_mol_per_step_by_layer_species = &totals }),
    );
    try expectLayerValue(&totals, 0, 5);

    var short_scratch: [salt_species_count]f64 = undefined;
    try std.testing.expectError(
        error.SnowpackSaltDimensionMismatch,
        aggregate(.dynamic, .{
            .heat_capacity_megajoules_per_k_by_layer = &capacities,
            .minimum_heat_capacity_megajoules_per_k = 1,
            .upper_face_mol_per_step_by_layer_species = &face_fluxes,
        }, &state, .{ .net_mol_per_step_by_layer_species = &short_scratch }),
    );
    try expectLayerValue(&totals, 0, 5);
}

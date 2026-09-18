const std = @import("std");
const organic = @import("initialization.zig");

/// REDIST ponding for OMC/OMN/OMP, ORC/ORN/ORP, OQC/OQN/OQP/OQA,
/// OHC/OHN/OHP/OHA, and OSC/OSA/OSN/OSP. Every runtime substrate,
/// population and kinetic fraction validates before any pool changes.
pub fn transferLayerFraction(state: *organic.State, source: usize, destination: usize, fraction: f64) !void {
    try validateLayerFraction(state, source, destination, fraction);
    if (fraction == 0) return;
    inline for (.{ state.microbial, state.residue, state.dissolved, state.adsorbed, state.structural }) |pools|
        transferElementLayer(pools, state.layer_count, source, destination, fraction);
    inline for (.{ state.dissolved_acetate_carbon_g_c, state.adsorbed_acetate_carbon_g_c, state.colonized_structural_carbon_g_c }) |values|
        transferScalarLayer(values, state.layer_count, source, destination, fraction);
}

/// REDIST pond-water settling (`redist.f:529--611`). Only particulate OMC,
/// ORC, OHC/OHA, and OSC/OSA families settle. Dissolved OQC/OQA remain in the
/// water phase and must not hitchhike on this solid transfer.
pub fn transferPondParticulateLayerFraction(state: *organic.State, source: usize, destination: usize, fraction: f64) !void {
    try validatePondParticulateLayerFraction(state, source, destination, fraction);
    if (fraction == 0) return;
    inline for (.{ state.microbial, state.residue, state.adsorbed, state.structural }) |pools|
        transferElementLayer(pools, state.layer_count, source, destination, fraction);
    inline for (.{ state.adsorbed_acetate_carbon_g_c, state.colonized_structural_carbon_g_c }) |values|
        transferScalarLayer(values, state.layer_count, source, destination, fraction);
}

pub fn validatePondParticulateLayerFraction(state: *const organic.State, source: usize, destination: usize, fraction: f64) !void {
    if (source >= state.layer_count or destination >= state.layer_count or source == destination) return error.OrganicLayerRemapIndexOutOfBounds;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidOrganicLayerRemapFraction;
    inline for (.{ state.microbial, state.residue, state.adsorbed, state.structural }) |pools|
        try validateElementLayer(pools, state.layer_count, source, destination, fraction);
    inline for (.{ state.adsorbed_acetate_carbon_g_c, state.colonized_structural_carbon_g_c }) |values|
        try validateScalarLayer(values, state.layer_count, source, destination, fraction);
}

pub fn validateLayerFraction(state: *const organic.State, source: usize, destination: usize, fraction: f64) !void {
    if (source >= state.layer_count or destination >= state.layer_count or source == destination) return error.OrganicLayerRemapIndexOutOfBounds;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidOrganicLayerRemapFraction;
    inline for (.{ state.microbial, state.residue, state.dissolved, state.adsorbed, state.structural }) |pools|
        try validateElementLayer(pools, state.layer_count, source, destination, fraction);
    inline for (.{ state.dissolved_acetate_carbon_g_c, state.adsorbed_acetate_carbon_g_c, state.colonized_structural_carbon_g_c }) |values|
        try validateScalarLayer(values, state.layer_count, source, destination, fraction);
}

fn validateElementLayer(values: []const organic.ElementPool, layer_count: usize, source: usize, destination: usize, fraction: f64) !void {
    if (values.len % layer_count != 0) return error.OrganicLayerRemapDimensionMismatch;
    const per_layer = values.len / layer_count;
    for (0..per_layer) |offset| inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| {
        try validatePair(@field(values[source * per_layer + offset], field.name), @field(values[destination * per_layer + offset], field.name), fraction);
    };
}

fn validateScalarLayer(values: []const f64, layer_count: usize, source: usize, destination: usize, fraction: f64) !void {
    if (values.len % layer_count != 0) return error.OrganicLayerRemapDimensionMismatch;
    const per_layer = values.len / layer_count;
    for (0..per_layer) |offset| try validatePair(values[source * per_layer + offset], values[destination * per_layer + offset], fraction);
}

fn transferElementLayer(values: []organic.ElementPool, layer_count: usize, source: usize, destination: usize, fraction: f64) void {
    const per_layer = values.len / layer_count;
    for (0..per_layer) |offset| inline for (@typeInfo(organic.ElementPool).@"struct".fields) |field| {
        const moved = fraction * @field(values[source * per_layer + offset], field.name);
        @field(values[source * per_layer + offset], field.name) -= moved;
        @field(values[destination * per_layer + offset], field.name) += moved;
    };
}

fn transferScalarLayer(values: []f64, layer_count: usize, source: usize, destination: usize, fraction: f64) void {
    const per_layer = values.len / layer_count;
    for (0..per_layer) |offset| {
        const moved = fraction * values[source * per_layer + offset];
        values[source * per_layer + offset] -= moved;
        values[destination * per_layer + offset] += moved;
    }
}

fn validatePair(source: f64, destination: f64, fraction: f64) !void {
    const moved = fraction * source;
    inline for (.{ source, destination, moved, source - moved, destination + moved }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicLayerRemapState;
}

test "REDIST organic ponding conserves every runtime owner family" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.microbial[0].carbon_g_c = 8;
    state.residue[0].nitrogen_g_n = 4;
    state.dissolved[0].phosphorus_g_p = 2;
    state.adsorbed[0].carbon_g_c = 6;
    state.dissolved_acetate_carbon_g_c[0] = 10;
    state.adsorbed_acetate_carbon_g_c[0] = 12;
    state.structural[0].nitrogen_g_n = 14;
    state.colonized_structural_carbon_g_c[0] = 16;
    const before = try state.totalCarbon_g_c(0) + try state.totalCarbon_g_c(1);
    try transferLayerFraction(&state, 0, 1, 0.25);
    const after = try state.totalCarbon_g_c(0) + try state.totalCarbon_g_c(1);
    try std.testing.expectApproxEqAbs(before, after, 1e-14);
    const microbial_per_layer = state.microbial.len / state.layer_count;
    try std.testing.expectEqual(@as(f64, 2), state.microbial[microbial_per_layer].carbon_g_c);
    const structural_per_layer = state.structural.len / state.layer_count;
    try std.testing.expectEqual(@as(f64, 3.5), state.structural[structural_per_layer].nitrogen_g_n);
    const colonized_per_layer = state.colonized_structural_carbon_g_c.len / state.layer_count;
    try std.testing.expectEqual(@as(f64, 4), state.colonized_structural_carbon_g_c[colonized_per_layer]);
}

test "REDIST pond settling moves particulate organic but leaves dissolved owners" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    const microbial_stride = organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    state.microbial[0].carbon_g_c = 8;
    state.adsorbed[0].nitrogen_g_n = 4;
    state.dissolved[0].phosphorus_g_p = 6;
    state.dissolved_acetate_carbon_g_c[0] = 10;
    try transferPondParticulateLayerFraction(&state, 0, 1, 0.25);
    try std.testing.expectEqual(@as(f64, 6), state.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 2), state.microbial[microbial_stride].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 3), state.adsorbed[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1), state.adsorbed[organic.substrate_count].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 6), state.dissolved[0].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved[1].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 10), state.dissolved_acetate_carbon_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved_acetate_carbon_g_c[5]);
}

test "REDIST organic ponding validates late colonized carbon before mutation" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.microbial[0].carbon_g_c = 5;
    const per_layer = state.colonized_structural_carbon_g_c.len / state.layer_count;
    state.colonized_structural_carbon_g_c[per_layer - 1] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidOrganicLayerRemapState, transferLayerFraction(&state, 0, 1, 0.5));
    try std.testing.expectEqual(@as(f64, 5), state.microbial[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), state.microbial[state.microbial.len / state.layer_count].carbon_g_c);
}

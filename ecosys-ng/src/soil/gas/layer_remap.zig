const std = @import("std");
const gas = @import("transport.zig");

/// Matrix-only compatibility entry point. Production REDIST calls
/// `transferLayerFractions` so the macropore aqueous gases at
/// `redist.f:10319-10338` follow their macropore water carrier.
pub fn transferLayerFraction(
    state: *gas.State,
    source: usize,
    destination: usize,
    destination_band_fraction: f64,
    fraction: f64,
) !void {
    try transferLayerFractions(
        state,
        source,
        destination,
        destination_band_fraction,
        fraction,
        0,
    );
}

/// REDIST remap for gaseous, matrix-aqueous, band-water, and separately gated
/// macropore-aqueous gas inventories.
pub fn transferLayerFractions(
    state: *gas.State,
    source: usize,
    destination: usize,
    destination_band_fraction: f64,
    matrix_fraction: f64,
    macropore_fraction: f64,
) !void {
    try validateLayerFraction(
        state,
        source,
        destination,
        destination_band_fraction,
        matrix_fraction,
    );
    if (!std.math.isFinite(macropore_fraction) or macropore_fraction < 0 or macropore_fraction > 1)
        return error.InvalidGasLayerRemapFraction;
    const source_first = source * gas.species_count;
    const destination_first = destination * gas.species_count;
    if (macropore_fraction > 0) for (0..gas.species_count) |species|
        try validatePair(
            state.macropore_dissolved_mass_g[source_first + species],
            state.macropore_dissolved_mass_g[destination_first + species],
            macropore_fraction,
        );
    if (matrix_fraction == 0 and macropore_fraction == 0) return;
    transferPair(state.water_vapor_mol, source, destination, matrix_fraction);
    for (0..gas.species_count) |species| {
        transferPair(state.gaseous_mass_g, source_first + species, destination_first + species, matrix_fraction);
        transferPair(state.dissolved_mass_g, source_first + species, destination_first + species, matrix_fraction);
        if (destination_band_fraction > 0)
            transferPair(
                state.band_dissolved_mass_g,
                source_first + species,
                destination_first + species,
                matrix_fraction,
            );
        if (macropore_fraction > 0)
            transferPair(
                state.macropore_dissolved_mass_g,
                source_first + species,
                destination_first + species,
                macropore_fraction,
            );
    }
}

pub fn validateLayerFraction(
    state: *const gas.State,
    source: usize,
    destination: usize,
    destination_band_fraction: f64,
    fraction: f64,
) !void {
    if (source >= state.cell_count or destination >= state.cell_count or source == destination) return error.GasLayerRemapIndexOutOfBounds;
    if (!std.math.isFinite(destination_band_fraction) or
        destination_band_fraction < 0 or
        destination_band_fraction > 1)
        return error.InvalidGasLayerRemapBandFraction;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.InvalidGasLayerRemapFraction;
    try validatePair(state.water_vapor_mol[source], state.water_vapor_mol[destination], fraction);
    const source_first = source * gas.species_count;
    const destination_first = destination * gas.species_count;
    for (0..gas.species_count) |species| {
        try validatePair(state.gaseous_mass_g[source_first + species], state.gaseous_mass_g[destination_first + species], fraction);
        try validatePair(state.dissolved_mass_g[source_first + species], state.dissolved_mass_g[destination_first + species], fraction);
        if (destination_band_fraction > 0)
            try validatePair(
                state.band_dissolved_mass_g[source_first + species],
                state.band_dissolved_mass_g[destination_first + species],
                fraction,
            );
    }
}

fn validatePair(source: f64, destination: f64, fraction: f64) !void {
    const moved = fraction * source;
    const next_source = source - moved;
    const next_destination = destination + moved;
    inline for (.{ source, destination, moved, next_source, next_destination }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidGasLayerRemapState;
}

fn transferPair(values: []f64, source: usize, destination: usize, fraction: f64) void {
    const moved = fraction * values[source];
    values[source] -= moved;
    values[destination] += moved;
}

test "REDIST gas ponding conserves all seven gas phases and leaves macropore storage" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.water_vapor_mol[0] = 8;
    for (0..gas.species_count) |species| {
        state.gaseous_mass_g[species] = @floatFromInt(species + 1);
        state.dissolved_mass_g[species] = @floatFromInt(2 * (species + 1));
        state.macropore_dissolved_mass_g[species] = @floatFromInt(3 * (species + 1));
    }
    try transferLayerFraction(&state, 0, 1, 1, 0.25);
    try std.testing.expectEqual(@as(f64, 6), state.water_vapor_mol[0]);
    try std.testing.expectEqual(@as(f64, 2), state.water_vapor_mol[1]);
    for (0..gas.species_count) |species| {
        const source_value: f64 = @floatFromInt(species + 1);
        try std.testing.expectApproxEqAbs(source_value, state.gaseous_mass_g[species] + state.gaseous_mass_g[gas.species_count + species], 1e-14);
        try std.testing.expectApproxEqAbs(2 * source_value, state.dissolved_mass_g[species] + state.dissolved_mass_g[gas.species_count + species], 1e-14);
        try std.testing.expectApproxEqAbs(3 * source_value, state.macropore_dissolved_mass_g[species], 1e-14);
        try std.testing.expectEqual(@as(f64, 0), state.macropore_dissolved_mass_g[gas.species_count + species]);
        try std.testing.expectApproxEqAbs(
            0,
            state.band_dissolved_mass_g[species] +
                state.band_dissolved_mass_g[gas.species_count + species],
            1e-14,
        );
    }
}

test "REDIST gas ponding validates the final species before mutation" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.gaseous_mass_g[0] = 5;
    state.dissolved_mass_g[gas.species_count - 1] = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidGasLayerRemapState,
        transferLayerFraction(&state, 0, 1, 1, 0.5),
    );
    try std.testing.expectEqual(@as(f64, 5), state.gaseous_mass_g[0]);
    try std.testing.expectEqual(@as(f64, 0), state.gaseous_mass_g[gas.species_count]);
}

test "REDIST band gas follows recipient band geometry even when dry" {
    var state = try gas.State.init(std.testing.allocator, 3);
    defer state.deinit();
    for (0..gas.species_count) |species|
        state.band_dissolved_mass_g[species] = @floatFromInt(species + 1);

    try transferLayerFraction(&state, 0, 1, 0, 0.25);
    for (0..gas.species_count) |species| {
        const initial: f64 = @floatFromInt(species + 1);
        try std.testing.expectEqual(
            initial,
            state.band_dissolved_mass_g[species],
        );
        try std.testing.expectEqual(
            @as(f64, 0),
            state.band_dissolved_mass_g[gas.species_count + species],
        );
    }

    try transferLayerFraction(&state, 0, 2, 1, 0.25);
    for (0..gas.species_count) |species| {
        const initial: f64 = @floatFromInt(species + 1);
        try std.testing.expectApproxEqAbs(
            initial,
            state.band_dissolved_mass_g[species] +
                state.band_dissolved_mass_g[2 * gas.species_count + species],
            1e-14,
        );
        try std.testing.expectApproxEqAbs(
            0.25 * initial,
            state.band_dissolved_mass_g[2 * gas.species_count + species],
            1e-14,
        );
    }
}

test "REDIST macropore aqueous gases follow the FHOL-gated fraction" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    for (0..gas.species_count) |species|
        state.macropore_dissolved_mass_g[species] = @floatFromInt(species + 1);

    try transferLayerFractions(&state, 0, 1, 1, 0.25, 0.5);
    for (0..gas.species_count) |species| {
        const initial: f64 = @floatFromInt(species + 1);
        try std.testing.expectApproxEqAbs(0.5 * initial, state.macropore_dissolved_mass_g[species], 1e-14);
        try std.testing.expectApproxEqAbs(0.5 * initial, state.macropore_dissolved_mass_g[gas.species_count + species], 1e-14);
        try std.testing.expectApproxEqAbs(initial, state.macropore_dissolved_mass_g[species] + state.macropore_dissolved_mass_g[gas.species_count + species], 1e-14);
    }
}

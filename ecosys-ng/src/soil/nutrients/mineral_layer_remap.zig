const std = @import("std");
const properties_module = @import("../water/solver_properties.zig");

const sediment_fields = .{
    "sand_mass_megagrams",
    "silt_mass_megagrams",
    "clay_mass_megagrams",
};

const exchange_capacity_fields = .{
    "cation_exchange_capacity_mol",
    "anion_exchange_capacity_mol",
};

// REDIST carries ROCK as its own additive layer owner (redist.f 9605--9607),
// not as part of the dry-soil-mass-normalized SAND/SILT/CLAY tuple.
const additive_sediment_fields = .{"rock_fraction"};

/// REDIST soil branch (legacy REDIST.F 9616 onward): transfer the requested
/// fraction of sediment and exchange capacity, then rebuild their intensive
/// views on the accepted post-transfer dry-soil masses.
pub fn transferLayerFraction(
    properties: *properties_module.State,
    source: usize,
    destination: usize,
    sediment_fraction: f64,
    exchange_capacity_fraction: f64,
    source_soil_mass_after_megagrams: f64,
    destination_soil_mass_after_megagrams: f64,
) !void {
    try validateLayerFraction(properties, source, destination, sediment_fraction, exchange_capacity_fraction, source_soil_mass_after_megagrams, destination_soil_mass_after_megagrams);
    inline for (sediment_fields) |field_name| {
        const values = @field(properties, field_name);
        const moved = sediment_fraction * values[source];
        values[destination] += moved;
        values[source] -= moved;
    }
    inline for (additive_sediment_fields) |field_name| {
        const values = @field(properties, field_name);
        const moved = sediment_fraction * values[source];
        values[destination] += moved;
        values[source] -= moved;
    }
    inline for (exchange_capacity_fields) |field_name| {
        const values = @field(properties, field_name);
        const moved = exchange_capacity_fraction * values[source];
        values[destination] += moved;
        values[source] -= moved;
    }
    refresh(properties, source, source_soil_mass_after_megagrams);
    refresh(properties, destination, destination_soil_mass_after_megagrams);
}

pub fn validateLayerFraction(
    properties: *const properties_module.State,
    source: usize,
    destination: usize,
    sediment_fraction: f64,
    exchange_capacity_fraction: f64,
    source_soil_mass_after_megagrams: f64,
    destination_soil_mass_after_megagrams: f64,
) !void {
    if (source >= properties.layer_count or destination >= properties.layer_count or source == destination) return error.MineralLayerRemapIndexOutOfBounds;
    inline for (.{ sediment_fraction, exchange_capacity_fraction, source_soil_mass_after_megagrams, destination_soil_mass_after_megagrams }) |value| if (!std.math.isFinite(value)) return error.InvalidMineralLayerRemapInput;
    if (sediment_fraction < 0 or sediment_fraction > 1 or exchange_capacity_fraction < 0 or exchange_capacity_fraction > 1 or source_soil_mass_after_megagrams < 0 or destination_soil_mass_after_megagrams < 0) return error.InvalidMineralLayerRemapInput;
    inline for (sediment_fields ++ additive_sediment_fields ++ exchange_capacity_fields) |field_name| {
        const values = @field(properties, field_name);
        if (values.len != properties.layer_count) return error.MineralLayerRemapDimensionMismatch;
        try validatePair(values[source], values[destination]);
    }
}

/// REDIST pond-water settling (`redist.f:359--378`) moves only the extensive
/// SAND/SILT/CLAY and XCEC/XAEC owners. ROCK belongs to the later soil-profile
/// remap and is intentionally excluded here.
pub fn transferPondParticulateLayerFraction(
    properties: *properties_module.State,
    source: usize,
    destination: usize,
    fraction: f64,
    source_soil_mass_megagrams: f64,
    destination_soil_mass_megagrams: f64,
) !void {
    try validatePondParticulateLayerFraction(properties, source, destination, fraction, source_soil_mass_megagrams, destination_soil_mass_megagrams);
    inline for (sediment_fields ++ exchange_capacity_fields) |field_name| {
        const values = @field(properties, field_name);
        const moved = fraction * values[source];
        values[source] -= moved;
        values[destination] += moved;
    }
    refresh(properties, source, source_soil_mass_megagrams);
    refresh(properties, destination, destination_soil_mass_megagrams);
}

pub fn validatePondParticulateLayerFraction(
    properties: *const properties_module.State,
    source: usize,
    destination: usize,
    fraction: f64,
    source_soil_mass_megagrams: f64,
    destination_soil_mass_megagrams: f64,
) !void {
    if (source >= properties.layer_count or destination >= properties.layer_count or source == destination) return error.MineralLayerRemapIndexOutOfBounds;
    inline for (.{ fraction, source_soil_mass_megagrams, destination_soil_mass_megagrams }) |value|
        if (!std.math.isFinite(value)) return error.InvalidMineralLayerRemapInput;
    if (fraction < 0 or fraction > 1 or source_soil_mass_megagrams < 0 or destination_soil_mass_megagrams < 0) return error.InvalidMineralLayerRemapInput;
    inline for (sediment_fields ++ exchange_capacity_fields) |field_name| {
        const values = @field(properties, field_name);
        if (values.len != properties.layer_count) return error.MineralLayerRemapDimensionMismatch;
        try validatePair(values[source], values[destination]);
        const moved = fraction * values[source];
        if (!std.math.isFinite(moved) or !std.math.isFinite(values[source] - moved) or !std.math.isFinite(values[destination] + moved))
            return error.InvalidMineralLayerRemapState;
    }
}

fn validatePair(source: f64, destination: f64) !void {
    if (!std.math.isFinite(source) or source < 0 or !std.math.isFinite(destination) or destination < 0 or !std.math.isFinite(source + destination)) return error.InvalidMineralLayerRemapState;
}

fn refresh(properties: *properties_module.State, layer: usize, soil_mass_megagrams: f64) void {
    if (soil_mass_megagrams > 0) {
        properties.sand_mass_fraction[layer] = properties.sand_mass_megagrams[layer] / soil_mass_megagrams;
        properties.silt_mass_fraction[layer] = properties.silt_mass_megagrams[layer] / soil_mass_megagrams;
        properties.clay_mass_fraction[layer] = properties.clay_mass_megagrams[layer] / soil_mass_megagrams;
        properties.cation_exchange_capacity_mol_per_megagram[layer] = properties.cation_exchange_capacity_mol[layer] / soil_mass_megagrams;
        properties.anion_exchange_capacity_mol_per_megagram[layer] = properties.anion_exchange_capacity_mol[layer] / soil_mass_megagrams;
    } else {
        properties.sand_mass_fraction[layer] = 0;
        properties.silt_mass_fraction[layer] = 0;
        properties.clay_mass_fraction[layer] = 0;
        properties.cation_exchange_capacity_mol_per_megagram[layer] = 0;
        properties.anion_exchange_capacity_mol_per_megagram[layer] = 0;
    }
}

/// HOUR1 carrier rebuild for the intensive texture and exchange-capacity views.
/// The extensive SAND/SILT/CLAY/XCEC/XAEC owners remain authoritative.
pub fn rebaseLayerCarrier(properties: *properties_module.State, layer: usize, soil_mass_megagrams: f64) !void {
    if (layer >= properties.layer_count or !std.math.isFinite(soil_mass_megagrams) or soil_mass_megagrams < 0)
        return error.InvalidMineralLayerRemapInput;
    refresh(properties, layer, soil_mass_megagrams);
}

test "REDIST downward sediment moves while exchange capacities remain local" {
    var properties: properties_module.State = undefined;
    properties.layer_count = 2;
    var sand = [_]f64{ 6, 2 };
    var silt = [_]f64{ 3, 5 };
    var clay = [_]f64{ 1, 3 };
    var rock = [_]f64{ 0.2, 0.1 };
    var cec_mol = [_]f64{ 100, 200 };
    var aec_mol = [_]f64{ 10, 20 };
    var sand_fraction = [_]f64{ 0.6, 0.2 };
    var clay_fraction = [_]f64{ 0.1, 0.3 };
    var silt_fraction = [_]f64{ 0.3, 0.5 };
    var cec = [_]f64{ 10, 20 };
    var aec = [_]f64{ 1, 2 };
    properties.sand_mass_megagrams = &sand;
    properties.silt_mass_megagrams = &silt;
    properties.clay_mass_megagrams = &clay;
    properties.rock_fraction = &rock;
    properties.cation_exchange_capacity_mol = &cec_mol;
    properties.anion_exchange_capacity_mol = &aec_mol;
    properties.sand_mass_fraction = &sand_fraction;
    properties.silt_mass_fraction = &silt_fraction;
    properties.clay_mass_fraction = &clay_fraction;
    properties.cation_exchange_capacity_mol_per_megagram = &cec;
    properties.anion_exchange_capacity_mol_per_megagram = &aec;
    try transferLayerFraction(&properties, 0, 1, 0.5, 0, 5, 15);
    try std.testing.expectEqual(@as(f64, 3), sand[0]);
    try std.testing.expectEqual(@as(f64, 5), sand[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), sand_fraction[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6.5 / 15.0), silt_fraction[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), rock[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), rock[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), rock[0] + rock[1], 1e-15);
    try std.testing.expectEqual(@as(f64, 100), cec_mol[0]);
    try std.testing.expectEqual(@as(f64, 200), cec_mol[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 200.0 / 15.0), cec[1], 1e-14);
}

test "REDIST pond settling conserves texture and capacities without moving ROCK" {
    var properties: properties_module.State = undefined;
    properties.layer_count = 2;
    var sand = [_]f64{ 6, 2 };
    var silt = [_]f64{ 3, 5 };
    var clay = [_]f64{ 1, 3 };
    var rock = [_]f64{ 0.2, 0.1 };
    var cec_mol = [_]f64{ 100, 200 };
    var aec_mol = [_]f64{ 10, 20 };
    var sand_fraction = [_]f64{ 0, 0 };
    var silt_fraction = [_]f64{ 0, 0 };
    var clay_fraction = [_]f64{ 0, 0 };
    var cec = [_]f64{ 0, 0 };
    var aec = [_]f64{ 0, 0 };
    properties.sand_mass_megagrams = &sand;
    properties.silt_mass_megagrams = &silt;
    properties.clay_mass_megagrams = &clay;
    properties.rock_fraction = &rock;
    properties.cation_exchange_capacity_mol = &cec_mol;
    properties.anion_exchange_capacity_mol = &aec_mol;
    properties.sand_mass_fraction = &sand_fraction;
    properties.silt_mass_fraction = &silt_fraction;
    properties.clay_mass_fraction = &clay_fraction;
    properties.cation_exchange_capacity_mol_per_megagram = &cec;
    properties.anion_exchange_capacity_mol_per_megagram = &aec;
    try transferPondParticulateLayerFraction(&properties, 0, 1, 0.25, 0, 10);
    try std.testing.expectEqual(@as(f64, 4.5), sand[0]);
    try std.testing.expectEqual(@as(f64, 3.5), sand[1]);
    try std.testing.expectEqual(@as(f64, 75), cec_mol[0]);
    try std.testing.expectEqual(@as(f64, 225), cec_mol[1]);
    try std.testing.expectEqual(@as(f64, 7.5), aec_mol[0]);
    try std.testing.expectEqual(@as(f64, 22.5), aec_mol[1]);
    try std.testing.expectEqual(@as(f64, 0.2), rock[0]);
    try std.testing.expectEqual(@as(f64, 0.1), rock[1]);
    try std.testing.expectEqual(@as(f64, 8), sand[0] + sand[1]);
    try std.testing.expectEqual(@as(f64, 300), cec_mol[0] + cec_mol[1]);
}

test "REDIST ROCK is an additive owner and may exceed one after deposition" {
    var properties: properties_module.State = undefined;
    properties.layer_count = 2;
    var sand = [_]f64{ 6, 2 };
    var silt = [_]f64{ 3, 5 };
    var clay = [_]f64{ 1, 3 };
    var rock = [_]f64{ 0.8, 0.9 };
    var cec_mol = [_]f64{ 100, 200 };
    var aec_mol = [_]f64{ 10, 20 };
    var sand_fraction = [_]f64{ 0.6, 0.2 };
    var silt_fraction = [_]f64{ 0.3, 0.5 };
    var clay_fraction = [_]f64{ 0.1, 0.3 };
    var cec = [_]f64{ 10, 20 };
    var aec = [_]f64{ 1, 2 };
    properties.sand_mass_megagrams = &sand;
    properties.silt_mass_megagrams = &silt;
    properties.clay_mass_megagrams = &clay;
    properties.rock_fraction = &rock;
    properties.cation_exchange_capacity_mol = &cec_mol;
    properties.anion_exchange_capacity_mol = &aec_mol;
    properties.sand_mass_fraction = &sand_fraction;
    properties.silt_mass_fraction = &silt_fraction;
    properties.clay_mass_fraction = &clay_fraction;
    properties.cation_exchange_capacity_mol_per_megagram = &cec;
    properties.anion_exchange_capacity_mol_per_megagram = &aec;
    try transferLayerFraction(&properties, 0, 1, 0.5, 0, 5, 15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), rock[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.3), rock[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.7), rock[0] + rock[1], 1e-15);
}

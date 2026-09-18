const std = @import("std");
const Organic = @import("../organic/initialization.zig");

pub const Result = struct {
    residue_phosphorus_g_p: f64,
    humus_phosphorus_g_p: f64,
    microbial_phosphorus_g_p: f64,
};

/// REDIST/OUTSD projection of URSDP, UORGP, and TOPT.
/// This follows the translated organic-state substrate ownership used by the
/// corresponding carbon projection and has no fixed layer or species extent.
pub fn calculate(
    profile: *const Organic.State,
    surface: *const Organic.State,
    first_profile_layer: usize,
    active_layer_count: usize,
    surface_cell: usize,
) !Result {
    if (active_layer_count == 0 or first_profile_layer > profile.layer_count or active_layer_count > profile.layer_count - first_profile_layer or surface_cell >= surface.layer_count) return error.DailyPhosphorusPoolDimensionMismatch;
    var result: Result = .{
        .residue_phosphorus_g_p = try totalPhosphorus(surface, surface_cell),
        .humus_phosphorus_g_p = 0,
        .microbial_phosphorus_g_p = try microbialPhosphorus(surface, surface_cell),
    };
    for (0..active_layer_count) |local_layer| {
        const layer = first_profile_layer + local_layer;
        for (0..3) |substrate| result.residue_phosphorus_g_p += try substratePhosphorus(profile, layer, substrate);
        for (3..Organic.substrate_count) |substrate| result.humus_phosphorus_g_p += try substratePhosphorus(profile, layer, substrate);
        result.microbial_phosphorus_g_p += try microbialPhosphorus(profile, layer);
    }
    inline for (@typeInfo(Result).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidDailyPhosphorusPool;
    }
    return result;
}

fn microbialPhosphorus(state: *const Organic.State, layer: usize) !f64 {
    if (layer >= state.layer_count) return error.DailyPhosphorusPoolDimensionMismatch;
    const first = layer * Organic.microbial_substrate_count * Organic.microbial_population_count * Organic.kinetic_fraction_count;
    const count = Organic.microbial_substrate_count * Organic.microbial_population_count * Organic.kinetic_fraction_count;
    var total: f64 = 0;
    for (state.microbial[first..][0..count]) |pool| total += pool.phosphorus_g_p;
    if (!std.math.isFinite(total) or total < 0) return error.InvalidDailyPhosphorusPool;
    return total;
}

fn totalPhosphorus(state: *const Organic.State, layer: usize) !f64 {
    var total: f64 = 0;
    for (0..Organic.substrate_count) |substrate| total += try substratePhosphorus(state, layer, substrate);
    return total;
}

fn substratePhosphorus(state: *const Organic.State, layer: usize, substrate: usize) !f64 {
    if (layer >= state.layer_count or substrate >= Organic.substrate_count) return error.DailyPhosphorusPoolDimensionMismatch;
    var total: f64 = 0;
    if (substrate < Organic.microbial_substrate_count) {
        const first = (layer * Organic.microbial_substrate_count + substrate) * Organic.microbial_population_count * Organic.kinetic_fraction_count;
        for (state.microbial[first..][0 .. Organic.microbial_population_count * Organic.kinetic_fraction_count]) |pool| total += pool.phosphorus_g_p;
    }
    for (0..Organic.residue_fraction_count) |fraction| total += state.residue[(layer * Organic.substrate_count + substrate) * Organic.residue_fraction_count + fraction].phosphorus_g_p;
    total += state.dissolved[layer * Organic.substrate_count + substrate].phosphorus_g_p;
    total += state.adsorbed[layer * Organic.substrate_count + substrate].phosphorus_g_p;
    for (0..Organic.structural_fraction_count) |fraction| total += state.structural[(layer * Organic.substrate_count + substrate) * Organic.structural_fraction_count + fraction].phosphorus_g_p;
    if (!std.math.isFinite(total) or total < 0) return error.InvalidDailyPhosphorusPool;
    return total;
}

test "OUTSD phosphorus pools distinguish residue humus and microbial totals at runtime depth" {
    var profile = try Organic.State.init(std.testing.allocator, 3);
    defer profile.deinit();
    var surface = try Organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    profile.dissolved[0 * Organic.substrate_count + 0].phosphorus_g_p = 2;
    profile.dissolved[0 * Organic.substrate_count + 3].phosphorus_g_p = 5;
    profile.microbial[0].phosphorus_g_p = 3;
    profile.dissolved[1 * Organic.substrate_count + 4].phosphorus_g_p = 11;
    surface.dissolved[0].phosphorus_g_p = 13;
    surface.microbial[0].phosphorus_g_p = 7;
    const result = try calculate(&profile, &surface, 0, 2, 0);
    try std.testing.expectEqual(@as(f64, 25), result.residue_phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 16), result.humus_phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 10), result.microbial_phosphorus_g_p);
}

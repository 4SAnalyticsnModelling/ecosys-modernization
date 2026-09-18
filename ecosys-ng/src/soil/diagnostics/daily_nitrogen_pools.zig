const std = @import("std");
const Organic = @import("../organic/initialization.zig");

pub const Result = struct {
    residue_nitrogen_g_n: f64,
    humus_nitrogen_g_n: f64,
    microbial_nitrogen_g_n: f64,
};

/// REDIST/OUTSD projection of URSDN, UORGN, and TONT with runtime depth.
pub fn calculate(profile: *const Organic.State, surface: *const Organic.State, first_profile_layer: usize, active_layer_count: usize, surface_cell: usize) !Result {
    if (active_layer_count == 0 or first_profile_layer > profile.layer_count or active_layer_count > profile.layer_count - first_profile_layer or surface_cell >= surface.layer_count) return error.DailyNitrogenPoolDimensionMismatch;
    var result: Result = .{
        .residue_nitrogen_g_n = try totalNitrogen(surface, surface_cell),
        .humus_nitrogen_g_n = 0,
        .microbial_nitrogen_g_n = try microbialNitrogen(surface, surface_cell),
    };
    for (0..active_layer_count) |local_layer| {
        const layer = first_profile_layer + local_layer;
        for (0..3) |substrate| result.residue_nitrogen_g_n += try substrateNitrogen(profile, layer, substrate);
        for (3..Organic.substrate_count) |substrate| result.humus_nitrogen_g_n += try substrateNitrogen(profile, layer, substrate);
        result.microbial_nitrogen_g_n += try microbialNitrogen(profile, layer);
    }
    inline for (@typeInfo(Result).@"struct".fields) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidDailyNitrogenPool;
    }
    return result;
}

fn microbialNitrogen(state: *const Organic.State, layer: usize) !f64 {
    if (layer >= state.layer_count) return error.DailyNitrogenPoolDimensionMismatch;
    const first = layer * Organic.microbial_substrate_count * Organic.microbial_population_count * Organic.kinetic_fraction_count;
    const count = Organic.microbial_substrate_count * Organic.microbial_population_count * Organic.kinetic_fraction_count;
    var total: f64 = 0;
    for (state.microbial[first..][0..count]) |pool| total += pool.nitrogen_g_n;
    return total;
}

fn totalNitrogen(state: *const Organic.State, layer: usize) !f64 {
    var total: f64 = 0;
    for (0..Organic.substrate_count) |substrate| total += try substrateNitrogen(state, layer, substrate);
    return total;
}

fn substrateNitrogen(state: *const Organic.State, layer: usize, substrate: usize) !f64 {
    if (layer >= state.layer_count or substrate >= Organic.substrate_count) return error.DailyNitrogenPoolDimensionMismatch;
    var total: f64 = 0;
    if (substrate < Organic.microbial_substrate_count) {
        const first = (layer * Organic.microbial_substrate_count + substrate) * Organic.microbial_population_count * Organic.kinetic_fraction_count;
        for (state.microbial[first..][0 .. Organic.microbial_population_count * Organic.kinetic_fraction_count]) |pool| total += pool.nitrogen_g_n;
    }
    for (0..Organic.residue_fraction_count) |fraction| total += state.residue[(layer * Organic.substrate_count + substrate) * Organic.residue_fraction_count + fraction].nitrogen_g_n;
    total += state.dissolved[layer * Organic.substrate_count + substrate].nitrogen_g_n;
    total += state.adsorbed[layer * Organic.substrate_count + substrate].nitrogen_g_n;
    for (0..Organic.structural_fraction_count) |fraction| total += state.structural[(layer * Organic.substrate_count + substrate) * Organic.structural_fraction_count + fraction].nitrogen_g_n;
    if (!std.math.isFinite(total) or total < 0) return error.InvalidDailyNitrogenPool;
    return total;
}

test "OUTSD nitrogen pools distinguish residue humus and microbial totals" {
    var profile = try Organic.State.init(std.testing.allocator, 2);
    defer profile.deinit();
    var surface = try Organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    profile.dissolved[0].nitrogen_g_n = 2;
    profile.dissolved[3].nitrogen_g_n = 5;
    profile.microbial[0].nitrogen_g_n = 3;
    surface.dissolved[0].nitrogen_g_n = 7;
    const result = try calculate(&profile, &surface, 0, 2, 0);
    try std.testing.expectEqual(@as(f64, 12), result.residue_nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 5), result.humus_nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 3), result.microbial_nitrogen_g_n);
}

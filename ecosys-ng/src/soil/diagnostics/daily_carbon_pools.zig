const std = @import("std");
const Organic = @import("../organic/initialization.zig");

pub const Result = struct {
    residue_carbon_g_c: f64,
    humus_carbon_g_c: f64,
    microbial_carbon_g_c: f64,
    surface_noncharcoal_organic_carbon_g_c: f64,
};

/// REDIST/OUTSD projection of URSDC, UORGC, TOMT, ORGC(0), and ORGC(L).
/// Runtime substrates 0..2 are residue and 3..4 are humus/particulate
/// organic matter. ORGC layer choices exclude the separate charcoal fraction.
pub fn calculate(
    profile: *const Organic.State,
    surface: *const Organic.State,
    first_profile_layer: usize,
    active_layer_count: usize,
    surface_cell: usize,
    noncharcoal_organic_carbon_g_c_by_layer: []f64,
) !Result {
    if (active_layer_count == 0 or noncharcoal_organic_carbon_g_c_by_layer.len != active_layer_count or first_profile_layer > profile.layer_count or active_layer_count > profile.layer_count - first_profile_layer or surface_cell >= surface.layer_count) return error.DailyCarbonPoolDimensionMismatch;
    var result: Result = .{ .residue_carbon_g_c = 0, .humus_carbon_g_c = 0, .microbial_carbon_g_c = 0, .surface_noncharcoal_organic_carbon_g_c = 0 };
    result.residue_carbon_g_c = try surface.totalCarbon_g_c(surface_cell);
    result.surface_noncharcoal_organic_carbon_g_c = result.residue_carbon_g_c - try surface.charcoalCarbon_g_c(surface_cell);
    for (0..active_layer_count) |local_layer| {
        const layer = first_profile_layer + local_layer;
        var residue: f64 = 0;
        for (0..3) |substrate| residue += try profile.substrateCarbon_g_c(layer, substrate);
        var humus: f64 = 0;
        for (3..Organic.substrate_count) |substrate| humus += try profile.substrateCarbon_g_c(layer, substrate);
        result.residue_carbon_g_c += residue;
        result.humus_carbon_g_c += humus;
        const total = try profile.totalCarbon_g_c(layer);
        const charcoal = try profile.charcoalCarbon_g_c(layer);
        noncharcoal_organic_carbon_g_c_by_layer[local_layer] = total - charcoal;
        const microbial_first = layer * Organic.microbial_substrate_count * Organic.microbial_population_count * Organic.kinetic_fraction_count;
        const microbial_count = Organic.microbial_substrate_count * Organic.microbial_population_count * Organic.kinetic_fraction_count;
        for (profile.microbial[microbial_first..][0..microbial_count]) |pool| result.microbial_carbon_g_c += pool.carbon_g_c;
    }
    inline for (@typeInfo(Result).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.InvalidDailyCarbonPool;
    for (noncharcoal_organic_carbon_g_c_by_layer) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidDailyCarbonPool;
    return result;
}

test "OUTSD pools distinguish residue humus microbial and charcoal at runtime depth" {
    var profile = try Organic.State.init(std.testing.allocator, 3);
    defer profile.deinit();
    var surface = try Organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    profile.dissolved[0 * Organic.substrate_count + 0].carbon_g_c = 2;
    profile.dissolved[0 * Organic.substrate_count + 3].carbon_g_c = 5;
    profile.microbial[0].carbon_g_c = 3;
    profile.structural[Organic.structural_fraction_count - 1].carbon_g_c = 7;
    profile.dissolved[1 * Organic.substrate_count + 4].carbon_g_c = 11;
    surface.dissolved[0].carbon_g_c = 13;
    surface.structural[Organic.structural_fraction_count - 1].carbon_g_c = 17;
    var layers: [2]f64 = undefined;
    const result = try calculate(&profile, &surface, 0, 2, 0, &layers);
    try std.testing.expectEqual(@as(f64, 42), result.residue_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 16), result.humus_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 3), result.microbial_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 13), result.surface_noncharcoal_organic_carbon_g_c);
    try std.testing.expectEqualSlices(f64, &.{ 10, 11 }, &layers);
}

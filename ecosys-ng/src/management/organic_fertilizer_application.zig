const std = @import("std");
const organic = @import("../soil/organic/initialization.zig");
const parameters_module = @import("../soil/organic/parameters.zig");
const material_fractions = @import("organic_fertilizer_material_fractions.zig");

pub const Kind = enum { plant_residue, manure };

/// HOUR1 OFC/OFN/OFP application. The event is first partitioned into local
/// deltas, every destination is validated, and only then is live state changed.
pub fn apply(
    state: *organic.State,
    layer: usize,
    kind: Kind,
    material_type: u8,
    input: organic.ElementPool,
    parameters: *const parameters_module.OwnedParameters,
) !void {
    if (layer >= state.layer_count) return error.OrganicFertilizerLayerOutOfBounds;
    inline for (.{ input.carbon_g_c, input.nitrogen_g_n, input.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicFertilizerInput;
    if (input.carbon_g_c == 0 and input.nitrogen_g_n == 0 and input.phosphorus_g_p == 0) return;

    const target_substrate: usize = switch (kind) {
        .plant_residue => 1,
        .manure => 2,
    };
    if (kind == .plant_residue and material_type == 10) {
        const charcoal_index = (layer * organic.substrate_count + 3) * organic.structural_fraction_count + 4;
        try validateAddition(state.structural[charcoal_index], input);
        add(&state.structural[charcoal_index], input);
        return;
    }

    var microbial_delta = [_]organic.ElementPool{.{}} ** (organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count);
    var allocated: organic.ElementPool = .{};
    for (0..organic.microbial_population_count) |population| for (0..organic.kinetic_fraction_count) |fraction| {
        const parameter_index = (target_substrate * organic.microbial_population_count + population) * organic.kinetic_fraction_count + fraction;
        const carbon = @max(0, @min(
            input.carbon_g_c * parameters.microbial_kinetic_fraction[target_substrate * organic.kinetic_fraction_count + fraction] * parameters.heterotroph_population_fraction[population],
            input.carbon_g_c - allocated.carbon_g_c,
        ));
        const pool: organic.ElementPool = .{
            .carbon_g_c = carbon,
            .nitrogen_g_n = @max(0, @min(carbon * parameters.microbial_nitrogen_to_carbon[parameter_index], input.nitrogen_g_n - allocated.nitrogen_g_n)),
            .phosphorus_g_p = @max(0, @min(carbon * parameters.microbial_phosphorus_to_carbon[parameter_index], input.phosphorus_g_p - allocated.phosphorus_g_p)),
        };
        add(&microbial_delta[microbialIndex(target_substrate, population, fraction)], pool);
        add(&allocated, pool);
        for (0..organic.microbial_population_count) |autotroph_population| {
            const autotroph = scale(pool, parameters.autotroph_population_fraction[autotroph_population]);
            add(&microbial_delta[microbialIndex(organic.autotrophic_substrate_index, autotroph_population, fraction)], autotroph);
            add(&allocated, autotroph);
        }
    };

    const dissolved: organic.ElementPool = .{
        .carbon_g_c = @max(0, @min(0.1 * allocated.carbon_g_c, input.carbon_g_c - allocated.carbon_g_c)),
        .nitrogen_g_n = @max(0, @min(0.1 * allocated.nitrogen_g_n, input.nitrogen_g_n - allocated.nitrogen_g_n)),
        .phosphorus_g_p = @max(0, @min(0.1 * allocated.phosphorus_g_p, input.phosphorus_g_p - allocated.phosphorus_g_p)),
    };
    add(&allocated, dissolved);

    // HOUR1 fertilizer-event litter types are a *different* codebook from the
    // STARTS site-initialisation IXTYP types, even though both fill CFOSC and
    // both are read here from one runtime array. hour1.f 648--714 and starts.f
    // 847--916 disagree on three codes: 4 is old straw in HOUR1 but new straw in
    // STARTS, 5 is the reverse, and 8 is simple substrate {0, 1, 0, 0} in HOUR1
    // but new deciduous forest {0.07, 0.41, 0.36, 0.16} in STARTS. HOUR1 also has
    // no codes 9 or 10; they fall to its default row.
    //
    // Indexing the STARTS array by a HOUR1 code therefore silently applies the
    // wrong litter chemistry. Read the HOUR1 codebook from its own translated
    // owner instead. Manure agrees between the two, so it still uses the runtime
    // array.
    var fraction_storage = [_]f64{0} ** organic.structural_fraction_count;
    const fractions: []const f64 = switch (kind) {
        .plant_residue => blk: {
            const row = try material_fractions.plant(material_type, material_fractions.sourceParameters());
            fraction_storage[0] = row.protein;
            fraction_storage[1] = row.soluble_carbohydrate;
            fraction_storage[2] = row.cellulose;
            fraction_storage[3] = row.lignin;
            break :blk &fraction_storage;
        },
        .manure => blk: {
            const type_index: usize = if (material_type == 1 or material_type == 3) 0 else 1;
            break :blk parameters.surface_manure_structural_fraction[type_index * organic.structural_fraction_count ..][0..organic.structural_fraction_count];
        },
    };
    const nutrient_weight_row: usize = if (kind == .plant_residue) 1 else 2;
    const nitrogen_weights = parameters.surface_residue_nitrogen_weight[nutrient_weight_row * organic.structural_fraction_count ..][0..organic.structural_fraction_count];
    const phosphorus_weights = parameters.surface_residue_phosphorus_weight[nutrient_weight_row * organic.structural_fraction_count ..][0..organic.structural_fraction_count];
    var weighted_nitrogen: f64 = 0;
    var weighted_phosphorus: f64 = 0;
    for (0..organic.structural_fraction_count) |fraction| {
        weighted_nitrogen += fractions[fraction] * nitrogen_weights[fraction];
        weighted_phosphorus += fractions[fraction] * phosphorus_weights[fraction];
    }
    const remaining: organic.ElementPool = .{
        .carbon_g_c = input.carbon_g_c - allocated.carbon_g_c,
        .nitrogen_g_n = input.nitrogen_g_n - allocated.nitrogen_g_n,
        .phosphorus_g_p = input.phosphorus_g_p - allocated.phosphorus_g_p,
    };
    inline for (.{ remaining.carbon_g_c, remaining.nitrogen_g_n, remaining.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.OrganicFertilizerAllocationWouldOverdraw;
    var structural_delta = [_]organic.ElementPool{.{}} ** organic.structural_fraction_count;
    for (0..organic.structural_fraction_count) |fraction| structural_delta[fraction] = .{
        .carbon_g_c = fractions[fraction] * remaining.carbon_g_c,
        .nitrogen_g_n = if (weighted_nitrogen > 0) fractions[fraction] * nitrogen_weights[fraction] / weighted_nitrogen * remaining.nitrogen_g_n else 0,
        .phosphorus_g_p = if (weighted_phosphorus > 0) fractions[fraction] * phosphorus_weights[fraction] / weighted_phosphorus * remaining.phosphorus_g_p else 0,
    };

    const microbial_first = layer * organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    for (microbial_delta, 0..) |delta, index| try validateAddition(state.microbial[microbial_first + index], delta);
    const dissolved_index = layer * organic.substrate_count + target_substrate;
    try validateAddition(state.dissolved[dissolved_index], dissolved);
    for (structural_delta, 0..) |delta, fraction| {
        const index = (layer * organic.substrate_count + target_substrate) * organic.structural_fraction_count + fraction;
        try validateAddition(state.structural[index], delta);
        const colonized = state.colonized_structural_carbon_g_c[index] + delta.carbon_g_c * parameters.microbial_kinetic_fraction[target_substrate * organic.kinetic_fraction_count];
        if (!std.math.isFinite(colonized)) return error.OrganicFertilizerApplicationOverflow;
    }
    for (microbial_delta, 0..) |delta, index| add(&state.microbial[microbial_first + index], delta);
    add(&state.dissolved[dissolved_index], dissolved);
    for (structural_delta, 0..) |delta, fraction| {
        const index = (layer * organic.substrate_count + target_substrate) * organic.structural_fraction_count + fraction;
        add(&state.structural[index], delta);
        state.colonized_structural_carbon_g_c[index] += delta.carbon_g_c * parameters.microbial_kinetic_fraction[target_substrate * organic.kinetic_fraction_count];
    }
}

fn microbialIndex(substrate: usize, population: usize, fraction: usize) usize {
    return (substrate * organic.microbial_population_count + population) * organic.kinetic_fraction_count + fraction;
}
fn add(target: *organic.ElementPool, value: organic.ElementPool) void {
    target.carbon_g_c += value.carbon_g_c;
    target.nitrogen_g_n += value.nitrogen_g_n;
    target.phosphorus_g_p += value.phosphorus_g_p;
}
fn scale(pool: organic.ElementPool, fraction: f64) organic.ElementPool {
    return .{ .carbon_g_c = pool.carbon_g_c * fraction, .nitrogen_g_n = pool.nitrogen_g_n * fraction, .phosphorus_g_p = pool.phosphorus_g_p * fraction };
}
fn validateAddition(current: organic.ElementPool, delta: organic.ElementPool) !void {
    inline for (.{ current.carbon_g_c + delta.carbon_g_c, current.nitrogen_g_n + delta.nitrogen_g_n, current.phosphorus_g_p + delta.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.OrganicFertilizerApplicationOverflow;
}

test "HOUR1 organic application conserves arbitrary residue C N P" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    var parameters = try parameters_module.sourceParameters(std.testing.allocator);
    defer parameters.deinit();
    const input: organic.ElementPool = .{ .carbon_g_c = 100, .nitrogen_g_n = 5, .phosphorus_g_p = 1 };
    try apply(&state, 1, .plant_residue, 2, input, &parameters);
    var carbon: f64 = 0;
    var nitrogen: f64 = 0;
    var phosphorus: f64 = 0;
    const microbial_first = organic.microbial_substrate_count * organic.microbial_population_count * organic.kinetic_fraction_count;
    for (state.microbial[microbial_first .. microbial_first * 2]) |pool| {
        carbon += pool.carbon_g_c;
        nitrogen += pool.nitrogen_g_n;
        phosphorus += pool.phosphorus_g_p;
    }
    for (state.dissolved[organic.substrate_count .. organic.substrate_count * 2]) |pool| {
        carbon += pool.carbon_g_c;
        nitrogen += pool.nitrogen_g_n;
        phosphorus += pool.phosphorus_g_p;
    }
    for (state.structural[organic.substrate_count * organic.structural_fraction_count .. organic.substrate_count * organic.structural_fraction_count * 2]) |pool| {
        carbon += pool.carbon_g_c;
        nitrogen += pool.nitrogen_g_n;
        phosphorus += pool.phosphorus_g_p;
    }
    try std.testing.expectApproxEqAbs(input.carbon_g_c, carbon, 1e-10);
    try std.testing.expectApproxEqAbs(input.nitrogen_g_n, nitrogen, 1e-10);
    try std.testing.expectApproxEqAbs(input.phosphorus_g_p, phosphorus, 1e-10);
}

test "HOUR1 plant residue codes four five eight nine use the HOUR1 codebook not STARTS" {
    // This test previously asserted the opposite: that the STARTS runtime array
    // agreed with the HOUR1 codebook on codes 4, 5 and 8. It cannot, because the
    // two Fortran sources genuinely disagree there. That assertion was what kept
    // the wrong values in soil/organic/parameters.zig looking correct.
    var parameters = try parameters_module.sourceParameters(std.testing.allocator);
    defer parameters.deinit();
    @memset(parameters.microbial_kinetic_fraction, 0);

    // Codes 4 and 5 are transposed between the codebooks, 8 differs outright, and
    // 9 exists only in STARTS so HOUR1 must fall back to its default row.
    inline for (.{ 4, 5, 8, 9 }) |material_type| {
        var state = try organic.State.init(std.testing.allocator, 1);
        defer state.deinit();
        const expected = try material_fractions.plant(material_type, material_fractions.sourceParameters());
        try apply(&state, 0, .plant_residue, material_type, .{ .carbon_g_c = 1 }, &parameters);

        var applied = [_]f64{0} ** 4;
        var total: f64 = 0;
        for (0..4) |fraction| {
            const index = 1 * organic.structural_fraction_count + fraction; // layer 0, plant-residue substrate
            applied[fraction] = state.structural[index].carbon_g_c;
            total += applied[fraction];
        }
        try std.testing.expectApproxEqAbs(@as(f64, 1), total, 1e-12);
        try std.testing.expectApproxEqAbs(expected.protein, applied[0], 1e-12);
        try std.testing.expectApproxEqAbs(expected.soluble_carbohydrate, applied[1], 1e-12);
        try std.testing.expectApproxEqAbs(expected.cellulose, applied[2], 1e-12);
        try std.testing.expectApproxEqAbs(expected.lignin, applied[3], 1e-12);
    }
}

test "HOUR1 manure type three selects runtime ruminant fractions" {
    var state = try organic.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var parameters = try parameters_module.sourceParameters(std.testing.allocator);
    defer parameters.deinit();

    // Disable the preliminary microbial/dissolved allocation so structural
    // state_update exposes only the material-fraction selection.
    @memset(parameters.microbial_kinetic_fraction, 0);
    const input: organic.ElementPool = .{ .carbon_g_c = 1 };
    try apply(&state, 0, .manure, 3, input, &parameters);

    const source = try @import("organic_fertilizer_material_fractions.zig").manure(
        3,
        @import("organic_fertilizer_material_fractions.zig").sourceParameters(),
    );
    const first = (2 * organic.structural_fraction_count);
    try std.testing.expectEqual(source.protein, state.structural[first].carbon_g_c);
    try std.testing.expectEqual(source.soluble_carbohydrate, state.structural[first + 1].carbon_g_c);
    try std.testing.expectEqual(source.cellulose, state.structural[first + 2].carbon_g_c);
    try std.testing.expectEqual(source.lignin, state.structural[first + 3].carbon_g_c);
}

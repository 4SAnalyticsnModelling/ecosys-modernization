const std = @import("std");
const microbial = @import("state.zig");
const organic = @import("../organic/initialization.zig");

/// Requires the complete fixed-role microbial axes used by the authoritative
/// soil-organic inventory. Smaller axes are not a supported reduced model:
/// they leave initialized organic roles outside NITRO and can invalidate
/// source role indices. Production calls this immediately after parsing the
/// runscript so an invalid configuration cannot partially initialize science.
pub fn validateRepresentableDimensions(
    substrate_count: usize,
    population_count: usize,
) !void {
    if (substrate_count != organic.microbial_substrate_count or
        population_count != organic.microbial_population_count)
        return error.UnsupportedMicrobialDimensions;
}

/// Publishes runtime microbial biomass into the fixed soil-organic inventory
/// used by mass-balance reconstruction. Runtime dimensions larger than the
/// representable legacy role axes fail before any mirror pool is changed.
pub fn publishToOrganic(
    source: *const microbial.State,
    destination: *organic.State,
) !void {
    if (source.cell_count == 0 or source.layer_count == 0 or
        source.cell_count * source.layer_count != destination.layer_count)
        return error.SoilMicrobialInventoryBridgeDimensionMismatch;
    if (source.substrate_count > organic.microbial_substrate_count or
        source.population_count > organic.microbial_population_count)
        return error.SoilMicrobialInventoryExceedsOrganicMirror;

    const runtime_pool_count = try std.math.mul(
        usize,
        try std.math.mul(
            usize,
            destination.layer_count,
            source.substrate_count,
        ),
        source.population_count,
    );
    if (source.nonstructural.len != runtime_pool_count or
        source.structural.len != try std.math.mul(usize, runtime_pool_count, 2))
        return error.SoilMicrobialInventoryBridgeDimensionMismatch;

    for (source.nonstructural) |pool| try validatePool(pool);
    for (source.structural) |pool| try validatePool(pool);

    for (0..destination.layer_count) |layer| {
        for (0..source.substrate_count) |substrate| {
            for (0..source.population_count) |population| {
                const runtime_index = try source.populationIndex(
                    layer / source.layer_count,
                    layer % source.layer_count,
                    substrate,
                    population,
                );
                const mirror_index =
                    ((layer * organic.microbial_substrate_count + substrate) *
                        organic.microbial_population_count + population) *
                    organic.kinetic_fraction_count;
                destination.microbial[mirror_index] = toOrganic(
                    source.structural[runtime_index * 2],
                );
                destination.microbial[mirror_index + 1] = toOrganic(
                    source.structural[runtime_index * 2 + 1],
                );
                destination.microbial[mirror_index + 2] = toOrganic(
                    source.nonstructural[runtime_index],
                );
            }
        }
    }
}

/// Publishes the fixed soil-organic microbial mirror back into runtime
/// microbial biomass after processes such as pond transfer modify the mirror.
/// The complete mapped source is validated before runtime state is changed.
pub fn publishFromOrganic(
    source: *const organic.State,
    destination: *microbial.State,
) !void {
    try validateMappingDimensions(destination, source);

    for (0..source.layer_count) |layer| {
        for (0..destination.substrate_count) |substrate| {
            for (0..destination.population_count) |population| {
                const first =
                    ((layer * organic.microbial_substrate_count + substrate) *
                        organic.microbial_population_count + population) *
                    organic.kinetic_fraction_count;
                for (source.microbial[first .. first + organic.kinetic_fraction_count]) |pool|
                    try validateOrganicPool(pool);
            }
        }
    }

    for (0..source.layer_count) |layer| {
        for (0..destination.substrate_count) |substrate| {
            for (0..destination.population_count) |population| {
                const runtime_index = try destination.populationIndex(
                    layer / destination.layer_count,
                    layer % destination.layer_count,
                    substrate,
                    population,
                );
                const first =
                    ((layer * organic.microbial_substrate_count + substrate) *
                        organic.microbial_population_count + population) *
                    organic.kinetic_fraction_count;
                destination.structural[runtime_index * 2] = toRuntime(
                    source.microbial[first],
                );
                destination.structural[runtime_index * 2 + 1] = toRuntime(
                    source.microbial[first + 1],
                );
                destination.nonstructural[runtime_index] = toRuntime(
                    source.microbial[first + 2],
                );
            }
        }
    }
}

fn validateMappingDimensions(
    runtime: *const microbial.State,
    mirror: *const organic.State,
) !void {
    if (runtime.cell_count == 0 or runtime.layer_count == 0 or
        runtime.cell_count * runtime.layer_count != mirror.layer_count)
        return error.SoilMicrobialInventoryBridgeDimensionMismatch;
    if (runtime.substrate_count > organic.microbial_substrate_count or
        runtime.population_count > organic.microbial_population_count)
        return error.SoilMicrobialInventoryExceedsOrganicMirror;
    const runtime_pool_count = try std.math.mul(
        usize,
        try std.math.mul(usize, mirror.layer_count, runtime.substrate_count),
        runtime.population_count,
    );
    if (runtime.nonstructural.len != runtime_pool_count or
        runtime.structural.len != try std.math.mul(usize, runtime_pool_count, 2))
        return error.SoilMicrobialInventoryBridgeDimensionMismatch;
}

// MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001. These two mirror the microbial
// pools between `microbial.State` and `organic.State`, and both carried the
// invented domain. The oracle writes every microbial carbon pool unclamped
// (`nitro.f:3824`, `:3832`) and reads each through `AMAX1(0.0, ...)` (`:431`,
// `:454`, `:2094`, `:2532`), so a negative stored pool is a state it computes
// without complaint. A mirror must therefore carry the value through rather than
// reject it. Non-finite stays fatal, which is what the two tests here assert --
// both inject NaN, not a negative.
fn validatePool(pool: microbial.ElementalPool) !void {
    inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value))
            return error.InvalidSoilMicrobialInventoryBridgePool;
}

fn toOrganic(pool: microbial.ElementalPool) organic.ElementPool {
    return .{
        .carbon_g_c = pool.carbon_g_c,
        .nitrogen_g_n = pool.nitrogen_g_n,
        .phosphorus_g_p = pool.phosphorus_g_p,
    };
}

/// Same citation as `validatePool` above: this is the organic-side half of the
/// same microbial mirror, so it must accept exactly what the oracle stores.
fn validateOrganicPool(pool: organic.ElementPool) !void {
    inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value))
            return error.InvalidSoilMicrobialInventoryBridgePool;
}

fn toRuntime(pool: organic.ElementPool) microbial.ElementalPool {
    return .{
        .carbon_g_c = pool.carbon_g_c,
        .nitrogen_g_n = pool.nitrogen_g_n,
        .phosphorus_g_p = pool.phosphorus_g_p,
    };
}

const ElementTotals = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

fn runtimeTotals(state: *const microbial.State) ElementTotals {
    var totals: ElementTotals = .{};
    for (state.structural) |pool| addPool(&totals, pool);
    for (state.nonstructural) |pool| addPool(&totals, pool);
    return totals;
}

fn mappedOrganicTotals(
    state: *const organic.State,
    substrate_count: usize,
    population_count: usize,
) ElementTotals {
    var totals: ElementTotals = .{};
    for (0..state.layer_count) |layer| for (0..substrate_count) |substrate| for (0..population_count) |population| {
        const first = ((layer * organic.microbial_substrate_count + substrate) *
            organic.microbial_population_count + population) *
            organic.kinetic_fraction_count;
        for (state.microbial[first .. first + organic.kinetic_fraction_count]) |pool|
            addPool(&totals, pool);
    };
    return totals;
}

fn addPool(totals: *ElementTotals, pool: anytype) void {
    totals.carbon_g_c += pool.carbon_g_c;
    totals.nitrogen_g_n += pool.nitrogen_g_n;
    totals.phosphorus_g_p += pool.phosphorus_g_p;
}

test "microbial inventory state_update preserves mapped C N P and is idempotent" {
    var source = try microbial.State.init(std.testing.allocator, 1, 2, 2, 3);
    defer source.deinit();
    var destination = try organic.State.init(std.testing.allocator, 2);
    defer destination.deinit();

    for (source.nonstructural, 0..) |*pool, index| pool.* = .{
        .carbon_g_c = @floatFromInt(index + 1),
        .nitrogen_g_n = @as(f64, @floatFromInt(index + 1)) / 10,
        .phosphorus_g_p = @as(f64, @floatFromInt(index + 1)) / 100,
    };
    for (source.structural, 0..) |*pool, index| pool.* = .{
        .carbon_g_c = @floatFromInt(index + 21),
        .nitrogen_g_n = @as(f64, @floatFromInt(index + 21)) / 10,
        .phosphorus_g_p = @as(f64, @floatFromInt(index + 21)) / 100,
    };
    @memset(destination.microbial, .{
        .carbon_g_c = 999,
        .nitrogen_g_n = 99,
        .phosphorus_g_p = 9,
    });
    const unmapped_index =
        ((organic.microbial_substrate_count - 1) *
            organic.microbial_population_count) *
        organic.kinetic_fraction_count;

    try publishToOrganic(&source, &destination);
    const runtime_totals = runtimeTotals(&source);
    const mirror_totals = mappedOrganicTotals(&destination, 2, 3);
    try std.testing.expectApproxEqAbs(
        runtime_totals.carbon_g_c,
        mirror_totals.carbon_g_c,
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        runtime_totals.nitrogen_g_n,
        mirror_totals.nitrogen_g_n,
        1.0e-13,
    );
    try std.testing.expectApproxEqAbs(
        runtime_totals.phosphorus_g_p,
        mirror_totals.phosphorus_g_p,
        1.0e-14,
    );
    try std.testing.expectEqual(@as(f64, 999), destination.microbial[unmapped_index].carbon_g_c);
    const first_state_update = try std.testing.allocator.dupe(
        organic.ElementPool,
        destination.microbial,
    );
    defer std.testing.allocator.free(first_state_update);
    try publishToOrganic(&source, &destination);
    try std.testing.expectEqualSlices(
        organic.ElementPool,
        first_state_update,
        destination.microbial,
    );
}

test "oversized runtime microbial axes fail before mirror mutation" {
    var source = try microbial.State.init(
        std.testing.allocator,
        1,
        1,
        organic.microbial_substrate_count + 1,
        organic.microbial_population_count,
    );
    defer source.deinit();
    var destination = try organic.State.init(std.testing.allocator, 1);
    defer destination.deinit();
    destination.microbial[0].carbon_g_c = 17;

    try std.testing.expectError(
        error.SoilMicrobialInventoryExceedsOrganicMirror,
        publishToOrganic(&source, &destination),
    );
    try std.testing.expectEqual(@as(f64, 17), destination.microbial[0].carbon_g_c);
}

test "production microbial axes are preflighted against the fixed organic inventory" {
    try validateRepresentableDimensions(
        organic.microbial_substrate_count,
        organic.microbial_population_count,
    );
    try std.testing.expectError(
        error.UnsupportedMicrobialDimensions,
        validateRepresentableDimensions(
            organic.microbial_substrate_count + 1,
            organic.microbial_population_count,
        ),
    );
    try std.testing.expectError(
        error.UnsupportedMicrobialDimensions,
        validateRepresentableDimensions(
            organic.microbial_substrate_count,
            organic.microbial_population_count + 1,
        ),
    );
    try std.testing.expectError(
        error.UnsupportedMicrobialDimensions,
        validateRepresentableDimensions(
            organic.microbial_substrate_count - 1,
            organic.microbial_population_count,
        ),
    );
    try std.testing.expectError(
        error.UnsupportedMicrobialDimensions,
        validateRepresentableDimensions(
            organic.microbial_substrate_count,
            organic.microbial_population_count - 1,
        ),
    );
}

test "production preflight precedes input resolution and microbial allocation" {
    const production = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ecosys_ng.zig",
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
    defer std.testing.allocator.free(production);

    const parse = std.mem.indexOf(u8, production, "ecosys.runscript.parse(") orelse
        return error.MissingRunscriptParse;
    const preflight = std.mem.indexOfPos(
        u8,
        production,
        parse,
        "soil_microbial_inventory_bridge.validateRepresentableDimensions(",
    ) orelse return error.MissingMicrobialDimensionPreflight;
    const input_resolution = std.mem.indexOfPos(
        u8,
        production,
        parse,
        "resolveInputPath(",
    ) orelse return error.MissingProductionInputResolution;
    const microbial_allocation = std.mem.indexOfPos(
        u8,
        production,
        parse,
        "soil_microbial_state.State.init(",
    ) orelse return error.MissingSoilMicrobialAllocation;
    try std.testing.expect(parse < preflight);
    try std.testing.expect(preflight < input_resolution);
    try std.testing.expect(preflight < microbial_allocation);
}

test "invalid late runtime pool fails before mirror mutation" {
    var source = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer source.deinit();
    var destination = try organic.State.init(std.testing.allocator, 1);
    defer destination.deinit();
    destination.microbial[0].carbon_g_c = 23;
    source.structural[1].carbon_g_c = std.math.nan(f64);

    try std.testing.expectError(
        error.InvalidSoilMicrobialInventoryBridgePool,
        publishToOrganic(&source, &destination),
    );
    try std.testing.expectEqual(@as(f64, 23), destination.microbial[0].carbon_g_c);
}

test "reverse microbial state_update preserves mapped C N P and is idempotent" {
    var source = try organic.State.init(std.testing.allocator, 2);
    defer source.deinit();
    var destination = try microbial.State.init(std.testing.allocator, 1, 2, 2, 3);
    defer destination.deinit();

    for (0..source.layer_count) |layer| for (0..destination.substrate_count) |substrate| for (0..destination.population_count) |population| {
        const first = ((layer * organic.microbial_substrate_count + substrate) *
            organic.microbial_population_count + population) *
            organic.kinetic_fraction_count;
        for (source.microbial[first .. first + organic.kinetic_fraction_count], 0..) |*pool, fraction| {
            const ordinal = 1 + first + fraction;
            pool.* = .{
                .carbon_g_c = @floatFromInt(ordinal),
                .nitrogen_g_n = @as(f64, @floatFromInt(ordinal)) / 10,
                .phosphorus_g_p = @as(f64, @floatFromInt(ordinal)) / 100,
            };
        }
    };
    @memset(destination.nonstructural, .{
        .carbon_g_c = 999,
        .nitrogen_g_n = 99,
        .phosphorus_g_p = 9,
    });
    @memset(destination.structural, .{
        .carbon_g_c = 999,
        .nitrogen_g_n = 99,
        .phosphorus_g_p = 9,
    });

    try publishFromOrganic(&source, &destination);
    const mirror_totals = mappedOrganicTotals(&source, 2, 3);
    const runtime_totals = runtimeTotals(&destination);
    try std.testing.expectApproxEqAbs(mirror_totals.carbon_g_c, runtime_totals.carbon_g_c, 1.0e-12);
    try std.testing.expectApproxEqAbs(mirror_totals.nitrogen_g_n, runtime_totals.nitrogen_g_n, 1.0e-13);
    try std.testing.expectApproxEqAbs(mirror_totals.phosphorus_g_p, runtime_totals.phosphorus_g_p, 1.0e-14);
    const nonstructural = try std.testing.allocator.dupe(microbial.ElementalPool, destination.nonstructural);
    defer std.testing.allocator.free(nonstructural);
    const structural = try std.testing.allocator.dupe(microbial.ElementalPool, destination.structural);
    defer std.testing.allocator.free(structural);
    try publishFromOrganic(&source, &destination);
    try std.testing.expectEqualSlices(microbial.ElementalPool, nonstructural, destination.nonstructural);
    try std.testing.expectEqualSlices(microbial.ElementalPool, structural, destination.structural);
}

test "reverse state_update rejects oversized runtime axes atomically" {
    var source = try organic.State.init(std.testing.allocator, 1);
    defer source.deinit();
    var destination = try microbial.State.init(
        std.testing.allocator,
        1,
        1,
        organic.microbial_substrate_count,
        organic.microbial_population_count + 1,
    );
    defer destination.deinit();
    destination.nonstructural[0].carbon_g_c = 29;

    try std.testing.expectError(
        error.SoilMicrobialInventoryExceedsOrganicMirror,
        publishFromOrganic(&source, &destination),
    );
    try std.testing.expectEqual(@as(f64, 29), destination.nonstructural[0].carbon_g_c);
}

test "invalid late organic mirror pool leaves runtime inventory unchanged" {
    var source = try organic.State.init(std.testing.allocator, 1);
    defer source.deinit();
    var destination = try microbial.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer destination.deinit();
    destination.nonstructural[0].carbon_g_c = 31;
    source.microbial[2].phosphorus_g_p = std.math.nan(f64);

    try std.testing.expectError(
        error.InvalidSoilMicrobialInventoryBridgePool,
        publishFromOrganic(&source, &destination),
    );
    try std.testing.expectEqual(@as(f64, 31), destination.nonstructural[0].carbon_g_c);
}

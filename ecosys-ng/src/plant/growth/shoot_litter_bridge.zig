const std = @import("std");
const canopy = @import("../../canopy/photosynthesis/photosynthesis.zig");
const organic = @import("../../soil/organic/initialization.zig");

pub const woody_substrate_index: usize = 0;
pub const fine_residue_substrate_index: usize = 1;

fn structuralIndex(cell: usize, substrate: usize, fraction: usize) usize {
    return (cell * organic.substrate_count + substrate) * organic.structural_fraction_count + fraction;
}

pub fn validateCharcoalStateUpdate(
    surface: *const organic.State,
    cell: usize,
    charcoal: canopy.ElementalMass,
) !void {
    if (cell >= surface.layer_count) return error.ShootLitterCellOutOfBounds;
    const index = structuralIndex(cell, woody_substrate_index, 4);
    const next = organic.ElementPool{
        .carbon_g_c = surface.structural[index].carbon_g_c + charcoal.carbon_g,
        .nitrogen_g_n = surface.structural[index].nitrogen_g_n + charcoal.nitrogen_g,
        .phosphorus_g_p = surface.structural[index].phosphorus_g_p + charcoal.phosphorus_g,
    };
    inline for (.{ next.carbon_g_c, next.nitrogen_g_n, next.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidShootLitterFlux;
}

/// StateUpdates the fifth GROSUB standing-dead component to the dedicated surface
/// charcoal fraction after the caller has preflighted the complete transaction.
pub fn state_updateCharcoalCell(
    surface: *organic.State,
    cell: usize,
    charcoal: canopy.ElementalMass,
) !void {
    try validateCharcoalStateUpdate(surface, cell, charcoal);
    const index = structuralIndex(cell, woody_substrate_index, 4);
    surface.structural[index].carbon_g_c += charcoal.carbon_g;
    surface.structural[index].nitrogen_g_n += charcoal.nitrogen_g;
    surface.structural[index].phosphorus_g_p += charcoal.phosphorus_g;
}

/// StateUpdates GROSUB CSNC/ZSNC/PSNC shoot litter into the surface structural
/// pools. The four source kinetic components occupy fractions 0...3; the
/// separately tracked fire-derived charcoal fraction 4 is never modified.
pub fn state_updateCell(
    surface: *organic.State,
    cell: usize,
    products: canopy.SenescenceProducts,
) !void {
    if (cell >= surface.layer_count) return error.ShootLitterCellOutOfBounds;

    var next_woody: [4]organic.ElementPool = undefined;
    var next_fine: [4]organic.ElementPool = undefined;
    for (0..4) |fraction| {
        const woody_index = structuralIndex(cell, woody_substrate_index, fraction);
        const fine_index = structuralIndex(cell, fine_residue_substrate_index, fraction);
        next_woody[fraction] = .{
            .carbon_g_c = surface.structural[woody_index].carbon_g_c + products.woody_carbon_g[fraction],
            .nitrogen_g_n = surface.structural[woody_index].nitrogen_g_n + products.woody_nitrogen_g[fraction],
            .phosphorus_g_p = surface.structural[woody_index].phosphorus_g_p + products.woody_phosphorus_g[fraction],
        };
        next_fine[fraction] = .{
            .carbon_g_c = surface.structural[fine_index].carbon_g_c + products.nonwoody_carbon_g[fraction],
            .nitrogen_g_n = surface.structural[fine_index].nitrogen_g_n + products.nonwoody_nitrogen_g[fraction],
            .phosphorus_g_p = surface.structural[fine_index].phosphorus_g_p + products.nonwoody_phosphorus_g[fraction],
        };
        inline for (.{ next_woody[fraction], next_fine[fraction] }) |pool| {
            inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value|
                if (!std.math.isFinite(value) or value < 0) return error.InvalidShootLitterFlux;
        }
    }

    for (0..4) |fraction| {
        surface.structural[structuralIndex(cell, woody_substrate_index, fraction)] = next_woody[fraction];
        surface.structural[structuralIndex(cell, fine_residue_substrate_index, fraction)] = next_fine[fraction];
    }
}

test "GROSUB shoot litter bridge conserves four kinetic fractions and charcoal" {
    var surface = try organic.State.init(std.testing.allocator, 2);
    defer surface.deinit();
    const charcoal_index = structuralIndex(1, woody_substrate_index, 4);
    surface.structural[charcoal_index] = .{ .carbon_g_c = 7, .nitrogen_g_n = 0.7, .phosphorus_g_p = 0.07 };
    const products: canopy.SenescenceProducts = .{
        .woody_carbon_g = .{ 1, 2, 3, 4 },
        .woody_nitrogen_g = .{ 0.1, 0.2, 0.3, 0.4 },
        .woody_phosphorus_g = .{ 0.01, 0.02, 0.03, 0.04 },
        .nonwoody_carbon_g = .{ 5, 6, 7, 8 },
        .nonwoody_nitrogen_g = .{ 0.5, 0.6, 0.7, 0.8 },
        .nonwoody_phosphorus_g = .{ 0.05, 0.06, 0.07, 0.08 },
    };
    try state_updateCell(&surface, 1, products);
    var carbon_g_c: f64 = 0;
    var nitrogen_g_n: f64 = 0;
    var phosphorus_g_p: f64 = 0;
    for (0..4) |fraction| {
        for ([_]usize{ woody_substrate_index, fine_residue_substrate_index }) |substrate| {
            const pool = surface.structural[structuralIndex(1, substrate, fraction)];
            carbon_g_c += pool.carbon_g_c;
            nitrogen_g_n += pool.nitrogen_g_n;
            phosphorus_g_p += pool.phosphorus_g_p;
        }
    }
    try std.testing.expectApproxEqAbs(@as(f64, 36), carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.36), phosphorus_g_p, 1e-14);
    try std.testing.expectEqual(organic.ElementPool{ .carbon_g_c = 7, .nitrogen_g_n = 0.7, .phosphorus_g_p = 0.07 }, surface.structural[charcoal_index]);
}

test "shoot litter bridge rejects non-finite input atomically" {
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    var products: canopy.SenescenceProducts = .{};
    products.nonwoody_carbon_g[2] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidShootLitterFlux, state_updateCell(&surface, 0, products));
    for (surface.structural) |pool| try std.testing.expectEqual(organic.ElementPool{}, pool);
}

test "standing-dead charcoal state_updates to the fifth structural fraction" {
    var surface = try organic.State.init(std.testing.allocator, 1);
    defer surface.deinit();
    const charcoal = canopy.ElementalMass{
        .carbon_g = 3,
        .nitrogen_g = 0.3,
        .phosphorus_g = 0.03,
    };
    try validateCharcoalStateUpdate(&surface, 0, charcoal);
    try state_updateCharcoalCell(&surface, 0, charcoal);
    try std.testing.expectEqual(
        organic.ElementPool{
            .carbon_g_c = 3,
            .nitrogen_g_n = 0.3,
            .phosphorus_g_p = 0.03,
        },
        surface.structural[structuralIndex(0, woody_substrate_index, 4)],
    );
}

const std = @import("std");

pub const Products = struct {
    carbon_dioxide_g_c: f64,
    methane_g_c: f64,
    charcoal_g_c: f64,
    nitrogen_oxide_g_n: f64,
    ammonium_g_n: f64,
    phosphorus_oxide_g_p: f64,
    dihydrogen_phosphate_g_p: f64,
};

pub const Ledger = struct {
    cumulative_atmospheric_carbon_input_g_c: f64,
    cell_soil_charcoal_input_g_c: f64,
    cumulative_mineral_nitrogen_input_g_n: f64,
    cumulative_mineral_phosphorus_input_g_p: f64,
    signed_carbon_dioxide_fire_flux_g_c: f64,
    signed_methane_fire_flux_g_c: f64,
    signed_nitrogen_oxide_fire_flux_g_n: f64,
    signed_phosphorus_oxide_fire_flux_g_p: f64,
};

/// Direct translation of EXTRACT lines 575--582. Positive mineral and
/// charcoal products enter ecosystem inventories, while atmospheric fire
/// products are subtracted from the source's signed ecosystem flux ledgers.
pub fn publish(ledger: *Ledger, products: Products) !void {
    inline for (std.meta.fields(Ledger)) |field|
        if (!std.math.isFinite(@field(ledger.*, field.name)))
            return error.NonFiniteRootCombustionBoundaryLedger;
    inline for (std.meta.fields(Products)) |field| {
        const value = @field(products, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteRootCombustionBoundaryProduct;
        if (value < 0) return error.InvalidRootCombustionBoundaryProduct;
    }

    const next: Ledger = .{
        .cumulative_atmospheric_carbon_input_g_c = ledger.cumulative_atmospheric_carbon_input_g_c +
            products.carbon_dioxide_g_c + products.methane_g_c,
        .cell_soil_charcoal_input_g_c = ledger.cell_soil_charcoal_input_g_c + products.charcoal_g_c,
        .cumulative_mineral_nitrogen_input_g_n = ledger.cumulative_mineral_nitrogen_input_g_n + products.ammonium_g_n,
        .cumulative_mineral_phosphorus_input_g_p = ledger.cumulative_mineral_phosphorus_input_g_p +
            products.dihydrogen_phosphate_g_p,
        .signed_carbon_dioxide_fire_flux_g_c = ledger.signed_carbon_dioxide_fire_flux_g_c -
            products.carbon_dioxide_g_c,
        .signed_methane_fire_flux_g_c = ledger.signed_methane_fire_flux_g_c - products.methane_g_c,
        .signed_nitrogen_oxide_fire_flux_g_n = ledger.signed_nitrogen_oxide_fire_flux_g_n -
            products.nitrogen_oxide_g_n,
        .signed_phosphorus_oxide_fire_flux_g_p = ledger.signed_phosphorus_oxide_fire_flux_g_p -
            products.phosphorus_oxide_g_p,
    };
    inline for (std.meta.fields(Ledger)) |field|
        if (!std.math.isFinite(@field(next, field.name)))
            return error.NonFiniteRootCombustionBoundaryResult;
    ledger.* = next;
}

fn zeroLedger() Ledger {
    return std.mem.zeroes(Ledger);
}

const test_products: Products = .{
    .carbon_dioxide_g_c = 10,
    .methane_g_c = 2,
    .charcoal_g_c = 3,
    .nitrogen_oxide_g_n = 4,
    .ammonium_g_n = 5,
    .phosphorus_oxide_g_p = 6,
    .dihydrogen_phosphate_g_p = 7,
};

test "EXTRACT root combustion state_update preserves boundary signs" {
    var ledger = zeroLedger();
    try publish(&ledger, test_products);
    try std.testing.expectEqual(
        @as(f64, 12),
        ledger.cumulative_atmospheric_carbon_input_g_c,
    );
    try std.testing.expectEqual(@as(f64, 3), ledger.cell_soil_charcoal_input_g_c);
    try std.testing.expectEqual(
        @as(f64, 5),
        ledger.cumulative_mineral_nitrogen_input_g_n,
    );
    try std.testing.expectEqual(
        @as(f64, 7),
        ledger.cumulative_mineral_phosphorus_input_g_p,
    );
    try std.testing.expectEqual(
        @as(f64, -10),
        ledger.signed_carbon_dioxide_fire_flux_g_c,
    );
    try std.testing.expectEqual(
        @as(f64, -6),
        ledger.signed_phosphorus_oxide_fire_flux_g_p,
    );
}

test "EXTRACT root combustion state_update accumulates in source order" {
    var ledger = zeroLedger();
    try publish(&ledger, test_products);
    try publish(&ledger, test_products);
    try std.testing.expectEqual(
        @as(f64, 24),
        ledger.cumulative_atmospheric_carbon_input_g_c,
    );
    try std.testing.expectEqual(
        @as(f64, -8),
        ledger.signed_nitrogen_oxide_fire_flux_g_n,
    );
}

test "EXTRACT root combustion state_update is atomic on overflow" {
    var ledger = zeroLedger();
    ledger.cumulative_mineral_nitrogen_input_g_n = std.math.floatMax(f64);
    const before = ledger;
    var overflowing = test_products;
    overflowing.ammonium_g_n = std.math.floatMax(f64);
    try std.testing.expectError(
        error.NonFiniteRootCombustionBoundaryResult,
        publish(&ledger, overflowing),
    );
    try std.testing.expectEqual(before, ledger);
}

const std = @import("std");

pub const ExtensiveUnit = enum {
    moles,
    grams_nitrogen,
    grams_phosphorus,
};

pub const DeferredChanges = struct {
    /// Current non-band inventory used to calculate the source transfer.
    non_band_inventory: []const f64,
    non_band_change: []f64,
    band_change: []f64,
    change_unit: ExtensiveUnit,
    /// Converts inventory units to change-ledger units.
    inventory_units_per_change_unit: f64,
};

pub const ImmediateInventories = struct {
    non_band_inventory: []f64,
    band_inventory: []f64,
};

pub const Storage = union(enum) {
    /// Aqueous, exchange, and mineral state is changed later by REDIST.
    deferred: DeferredChanges,
    /// Undissolved fertilizer stores move during SOLUTE itself.
    immediate: ImmediateInventories,
};

pub const Pool = struct {
    name: []const u8,
    inventory_unit: ExtensiveUnit,
    storage: Storage,
};

pub const Inputs = struct {
    /// FVLNH4, FVLNO3, or FVLPO4 by runtime layer (step-1).
    relative_non_band_change: []const f64,
    /// IFNHB, IFNOB, or IFPOB for the current cell.
    band_active: bool,
    first_active_layer: usize,
    last_active_layer: usize,
};

pub const Result = struct {
    layers_repartitioned: usize,
    pools_repartitioned: usize,
};

/// Applies one nutrient family's band-growth inventory transaction.
///
/// Traceability: SOLUTE (`solute.f`) NH4 lines 3761--3804, NO3 lines
/// 3813--3833, and PO4 lines 3842--3914. Call separately for each nutrient,
/// supplying pools in their source statement order.
/// A negative FVL removes inventory from non-band and adds the same amount to
/// band. Every candidate is validated before any owner is mutated.
pub fn repartition(inputs: Inputs, pools: []const Pool) !Result {
    try validate(inputs, pools);
    if (!inputs.band_active) return .{
        .layers_repartitioned = 0,
        .pools_repartitioned = 0,
    };

    // Complete candidate validation first, retaining an atomic state_update below.
    var layer = inputs.first_active_layer;
    while (layer <= inputs.last_active_layer) : (layer += 1) {
        const relative_change = inputs.relative_non_band_change[layer];
        for (pools) |pool| switch (pool.storage) {
            .deferred => |storage| {
                const transfer = relative_change *
                    storage.non_band_inventory[layer] /
                    storage.inventory_units_per_change_unit;
                try validateDeferredCandidate(storage, layer, transfer);
            },
            .immediate => |storage| {
                const transfer =
                    relative_change * storage.non_band_inventory[layer];
                try validateImmediateCandidate(storage, layer, transfer);
            },
        };
    }

    var layers_repartitioned: usize = 0;
    var pools_repartitioned: usize = 0;
    layer = inputs.first_active_layer;
    while (layer <= inputs.last_active_layer) : (layer += 1) {
        const relative_change = inputs.relative_non_band_change[layer];
        if (relative_change == 0) continue;
        layers_repartitioned += 1;
        for (pools) |pool| {
            switch (pool.storage) {
                .deferred => |storage| {
                    const transfer = relative_change *
                        storage.non_band_inventory[layer] /
                        storage.inventory_units_per_change_unit;
                    storage.non_band_change[layer] += transfer;
                    storage.band_change[layer] -= transfer;
                },
                .immediate => |storage| {
                    const transfer =
                        relative_change * storage.non_band_inventory[layer];
                    storage.non_band_inventory[layer] += transfer;
                    storage.band_inventory[layer] -= transfer;
                },
            }
            pools_repartitioned += 1;
        }
    }
    return .{
        .layers_repartitioned = layers_repartitioned,
        .pools_repartitioned = pools_repartitioned,
    };
}

fn validate(inputs: Inputs, pools: []const Pool) !void {
    const count = inputs.relative_non_band_change.len;
    if (count == 0 or inputs.first_active_layer > inputs.last_active_layer or
        inputs.last_active_layer >= count)
        return error.InvalidBandRepartitionLayerRange;
    for (inputs.relative_non_band_change) |relative_change| {
        if (!std.math.isFinite(relative_change))
            return error.NonFiniteBandRelativeChange;
        if (relative_change < -1 or relative_change > 0)
            return error.InvalidBandRelativeChange;
    }
    for (pools) |pool| {
        if (pool.name.len == 0) return error.UnnamedBandInventoryPool;
        switch (pool.storage) {
            .deferred => |storage| {
                if (storage.non_band_inventory.len != count or
                    storage.non_band_change.len != count or
                    storage.band_change.len != count)
                    return error.BandRepartitionDimensionMismatch;
                if (!std.math.isFinite(
                    storage.inventory_units_per_change_unit,
                ) or storage.inventory_units_per_change_unit <= 0)
                    return error.InvalidBandInventoryConversion;
                if (pool.inventory_unit == storage.change_unit and
                    storage.inventory_units_per_change_unit != 1)
                    return error.InconsistentBandInventoryConversion;
                try validateDistinct(
                    storage.non_band_change,
                    storage.band_change,
                );
                for (
                    storage.non_band_inventory,
                    storage.non_band_change,
                    storage.band_change,
                ) |inventory, non_change, band_change| {
                    if (!std.math.isFinite(inventory) or inventory < 0 or
                        !std.math.isFinite(non_change) or
                        !std.math.isFinite(band_change))
                        return error.InvalidBandInventoryState;
                }
            },
            .immediate => |storage| {
                if (storage.non_band_inventory.len != count or
                    storage.band_inventory.len != count)
                    return error.BandRepartitionDimensionMismatch;
                try validateDistinct(
                    storage.non_band_inventory,
                    storage.band_inventory,
                );
                for (
                    storage.non_band_inventory,
                    storage.band_inventory,
                ) |non_band, band| {
                    if (!std.math.isFinite(non_band) or non_band < 0 or
                        !std.math.isFinite(band) or band < 0)
                        return error.InvalidBandInventoryState;
                }
            },
        }
    }
}

fn validateDistinct(first: []f64, second: []f64) !void {
    if (first.ptr == second.ptr) return error.AliasedBandInventoryOwners;
}

fn validateDeferredCandidate(
    storage: DeferredChanges,
    layer: usize,
    transfer: f64,
) !void {
    const non_band_change = storage.non_band_change[layer] + transfer;
    const band_change = storage.band_change[layer] - transfer;
    if (!std.math.isFinite(transfer) or
        !std.math.isFinite(non_band_change) or
        !std.math.isFinite(band_change))
        return error.BandRepartitionOverflow;
}

fn validateImmediateCandidate(
    storage: ImmediateInventories,
    layer: usize,
    transfer: f64,
) !void {
    const non_band = storage.non_band_inventory[layer] + transfer;
    const band = storage.band_inventory[layer] - transfer;
    if (!std.math.isFinite(transfer) or !std.math.isFinite(non_band) or
        !std.math.isFinite(band))
        return error.BandRepartitionOverflow;
    if (non_band < 0 or band < 0)
        return error.NegativeBandInventoryCandidate;
}

test "NH4 source units publish conservative molar changes and move fertilizer" {
    const fvl = [_]f64{-0.0234375};
    const ammonium_g_n = [_]f64{14};
    var non_band_change_mol = [_]f64{0};
    var band_change_mol = [_]f64{0};
    var broadcast_fertilizer_mol = [_]f64{10};
    var banded_fertilizer_mol = [_]f64{2};
    const pools = [_]Pool{
        .{
            .name = "dissolved ammonium",
            .inventory_unit = .grams_nitrogen,
            .storage = .{ .deferred = .{
                .non_band_inventory = &ammonium_g_n,
                .non_band_change = &non_band_change_mol,
                .band_change = &band_change_mol,
                .change_unit = .moles,
                .inventory_units_per_change_unit = 14,
            } },
        },
        .{
            .name = "undissolved ammonium fertilizer",
            .inventory_unit = .moles,
            .storage = .{ .immediate = .{
                .non_band_inventory = &broadcast_fertilizer_mol,
                .band_inventory = &banded_fertilizer_mol,
            } },
        },
    };

    const result = try repartition(.{
        .relative_non_band_change = &fvl,
        .band_active = true,
        .first_active_layer = 0,
        .last_active_layer = 0,
    }, &pools);
    try std.testing.expectEqual(@as(usize, 1), result.layers_repartitioned);
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.0234375),
        non_band_change_mol[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.0234375),
        band_change_mol[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 12),
        broadcast_fertilizer_mol[0] + banded_fertilizer_mol[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 9.765625),
        broadcast_fertilizer_mol[0],
        1e-15,
    );
}

test "SOLUTE 3761-3804 transfers all NH4 band-growth pools in source order" {
    const relative_change = [_]f64{-0.1};
    const dissolved_ammonium_g_n = [_]f64{14};
    const dissolved_ammonia_g_n = [_]f64{28};
    const exchangeable_ammonium_mol = [_]f64{3};
    var ammonium_non_band_change = [_]f64{0};
    var ammonium_band_change = [_]f64{0};
    var ammonia_non_band_change = [_]f64{0};
    var ammonia_band_change = [_]f64{0};
    var exchange_non_band_change = [_]f64{0};
    var exchange_band_change = [_]f64{0};
    var broadcast_ammonium = [_]f64{10};
    var banded_ammonium = [_]f64{2};
    var broadcast_ammonia = [_]f64{20};
    var banded_ammonia = [_]f64{3};
    var broadcast_urea = [_]f64{30};
    var banded_urea = [_]f64{4};
    const pools = [_]Pool{
        .{ .name = "dissolved ammonium", .inventory_unit = .grams_nitrogen, .storage = .{ .deferred = .{ .non_band_inventory = &dissolved_ammonium_g_n, .non_band_change = &ammonium_non_band_change, .band_change = &ammonium_band_change, .change_unit = .moles, .inventory_units_per_change_unit = 14 } } },
        .{ .name = "dissolved ammonia", .inventory_unit = .grams_nitrogen, .storage = .{ .deferred = .{ .non_band_inventory = &dissolved_ammonia_g_n, .non_band_change = &ammonia_non_band_change, .band_change = &ammonia_band_change, .change_unit = .moles, .inventory_units_per_change_unit = 14 } } },
        .{ .name = "exchangeable ammonium", .inventory_unit = .moles, .storage = .{ .deferred = .{ .non_band_inventory = &exchangeable_ammonium_mol, .non_band_change = &exchange_non_band_change, .band_change = &exchange_band_change, .change_unit = .moles, .inventory_units_per_change_unit = 1 } } },
        .{ .name = "broadcast ammonium fertilizer", .inventory_unit = .moles, .storage = .{ .immediate = .{ .non_band_inventory = &broadcast_ammonium, .band_inventory = &banded_ammonium } } },
        .{ .name = "broadcast ammonia fertilizer", .inventory_unit = .moles, .storage = .{ .immediate = .{ .non_band_inventory = &broadcast_ammonia, .band_inventory = &banded_ammonia } } },
        .{ .name = "broadcast urea fertilizer", .inventory_unit = .moles, .storage = .{ .immediate = .{ .non_band_inventory = &broadcast_urea, .band_inventory = &banded_urea } } },
    };
    _ = try repartition(.{ .relative_non_band_change = &relative_change, .band_active = true, .first_active_layer = 0, .last_active_layer = 0 }, &pools);
    try std.testing.expectEqual(@as(f64, -0.1), ammonium_non_band_change[0]);
    try std.testing.expectEqual(@as(f64, 0.1), ammonium_band_change[0]);
    try std.testing.expectEqual(@as(f64, -0.2), ammonia_non_band_change[0]);
    try std.testing.expectEqual(@as(f64, 0.2), ammonia_band_change[0]);
    try std.testing.expectApproxEqAbs(@as(f64, -0.3), exchange_non_band_change[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), exchange_band_change[0], 1e-15);
    try std.testing.expectEqual(@as(f64, 9), broadcast_ammonium[0]);
    try std.testing.expectEqual(@as(f64, 3), banded_ammonium[0]);
    try std.testing.expectEqual(@as(f64, 18), broadcast_ammonia[0]);
    try std.testing.expectEqual(@as(f64, 5), banded_ammonia[0]);
    try std.testing.expectEqual(@as(f64, 27), broadcast_urea[0]);
    try std.testing.expectEqual(@as(f64, 7), banded_urea[0]);
}

test "SOLUTE 3813-3833 transfers nitrate band-growth pools in source order" {
    const relative_change = [_]f64{-0.25};
    const dissolved_nitrate_g_n = [_]f64{28};
    const dissolved_nitrite_g_n = [_]f64{14};
    var nitrate_non_band_change = [_]f64{1};
    var nitrate_band_change = [_]f64{2};
    var nitrite_non_band_change = [_]f64{3};
    var nitrite_band_change = [_]f64{4};
    var broadcast_nitrate_fertilizer_mol = [_]f64{8};
    var banded_nitrate_fertilizer_mol = [_]f64{5};
    const pools = [_]Pool{
        .{ .name = "dissolved nitrate", .inventory_unit = .grams_nitrogen, .storage = .{ .deferred = .{ .non_band_inventory = &dissolved_nitrate_g_n, .non_band_change = &nitrate_non_band_change, .band_change = &nitrate_band_change, .change_unit = .moles, .inventory_units_per_change_unit = 14 } } },
        .{ .name = "dissolved nitrite", .inventory_unit = .grams_nitrogen, .storage = .{ .deferred = .{ .non_band_inventory = &dissolved_nitrite_g_n, .non_band_change = &nitrite_non_band_change, .band_change = &nitrite_band_change, .change_unit = .moles, .inventory_units_per_change_unit = 14 } } },
        .{ .name = "broadcast nitrate fertilizer", .inventory_unit = .moles, .storage = .{ .immediate = .{ .non_band_inventory = &broadcast_nitrate_fertilizer_mol, .band_inventory = &banded_nitrate_fertilizer_mol } } },
    };
    _ = try repartition(.{ .relative_non_band_change = &relative_change, .band_active = true, .first_active_layer = 0, .last_active_layer = 0 }, &pools);
    try std.testing.expectEqual(@as(f64, 0.5), nitrate_non_band_change[0]);
    try std.testing.expectEqual(@as(f64, 2.5), nitrate_band_change[0]);
    try std.testing.expectEqual(@as(f64, 2.75), nitrite_non_band_change[0]);
    try std.testing.expectEqual(@as(f64, 4.25), nitrite_band_change[0]);
    try std.testing.expectEqual(@as(f64, 6), broadcast_nitrate_fertilizer_mol[0]);
    try std.testing.expectEqual(@as(f64, 7), banded_nitrate_fertilizer_mol[0]);
}

test "PO4 dissolved exchange and precipitate ledgers conserve phosphorus" {
    const fvl = [_]f64{-0.1};
    const dissolved_g_p = [_]f64{31};
    const adsorbed_mol_p = [_]f64{2};
    const precipitated_mol_p = [_]f64{3};
    var dissolved_non = [_]f64{0};
    var dissolved_band = [_]f64{0};
    var adsorbed_non = [_]f64{0};
    var adsorbed_band = [_]f64{0};
    var precipitated_non = [_]f64{0};
    var precipitated_band = [_]f64{0};
    const pools = [_]Pool{
        .{ .name = "H2PO4", .inventory_unit = .grams_phosphorus, .storage = .{ .deferred = .{
            .non_band_inventory = &dissolved_g_p,
            .non_band_change = &dissolved_non,
            .band_change = &dissolved_band,
            .change_unit = .moles,
            .inventory_units_per_change_unit = 31,
        } } },
        .{ .name = "adsorbed H2PO4", .inventory_unit = .moles, .storage = .{ .deferred = .{
            .non_band_inventory = &adsorbed_mol_p,
            .non_band_change = &adsorbed_non,
            .band_change = &adsorbed_band,
            .change_unit = .moles,
            .inventory_units_per_change_unit = 1,
        } } },
        .{ .name = "AlPO4 precipitate", .inventory_unit = .moles, .storage = .{ .deferred = .{
            .non_band_inventory = &precipitated_mol_p,
            .non_band_change = &precipitated_non,
            .band_change = &precipitated_band,
            .change_unit = .moles,
            .inventory_units_per_change_unit = 1,
        } } },
    };
    _ = try repartition(.{
        .relative_non_band_change = &fvl,
        .band_active = true,
        .first_active_layer = 0,
        .last_active_layer = 0,
    }, &pools);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        dissolved_non[0] + dissolved_band[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        adsorbed_non[0] + adsorbed_band[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        precipitated_non[0] + precipitated_band[0],
        1e-15,
    );
    const phosphorus_change_mol =
        dissolved_non[0] + dissolved_band[0] +
        adsorbed_non[0] + adsorbed_band[0] +
        precipitated_non[0] + precipitated_band[0];
    try std.testing.expectApproxEqAbs(@as(f64, 0), phosphorus_change_mol, 1e-15);
}

test "SOLUTE 3888-3913 salt option transfers all eight phosphate species" {
    const relative_change = [_]f64{-0.1};
    const names = [_][]const u8{
        "phosphate",
        "phosphoric acid",
        "iron HPO4 pair",
        "iron H2PO4 pair",
        "calcium PO4 pair",
        "calcium HPO4 pair",
        "calcium H2PO4 pair",
        "magnesium HPO4 pair",
    };
    var inventories: [names.len][1]f64 = undefined;
    var non_band_changes: [names.len][1]f64 = @splat(.{0});
    var band_changes: [names.len][1]f64 = @splat(.{0});
    var pools: [names.len]Pool = undefined;
    for (&pools, 0..) |*pool, index| {
        inventories[index][0] = @floatFromInt(index + 1);
        pool.* = .{
            .name = names[index],
            .inventory_unit = .moles,
            .storage = .{ .deferred = .{
                .non_band_inventory = inventories[index][0..],
                .non_band_change = non_band_changes[index][0..],
                .band_change = band_changes[index][0..],
                .change_unit = .moles,
                .inventory_units_per_change_unit = 1,
            } },
        };
    }
    _ = try repartition(.{ .relative_non_band_change = &relative_change, .band_active = true, .first_active_layer = 0, .last_active_layer = 0 }, &pools);
    for (0..names.len) |index| {
        const expected = -0.1 * @as(f64, @floatFromInt(index + 1));
        try std.testing.expectApproxEqAbs(expected, non_band_changes[index][0], 1e-15);
        try std.testing.expectApproxEqAbs(-expected, band_changes[index][0], 1e-15);
    }
}

test "invalid late pool rejects transaction without earlier mutation" {
    const fvl = [_]f64{-0.5};
    var first_non = [_]f64{4};
    var first_band = [_]f64{1};
    const before_non = first_non;
    const before_band = first_band;
    var invalid_non = [_]f64{std.math.nan(f64)};
    var invalid_band = [_]f64{0};
    const pools = [_]Pool{
        .{ .name = "valid", .inventory_unit = .moles, .storage = .{ .immediate = .{
            .non_band_inventory = &first_non,
            .band_inventory = &first_band,
        } } },
        .{ .name = "invalid", .inventory_unit = .moles, .storage = .{ .immediate = .{
            .non_band_inventory = &invalid_non,
            .band_inventory = &invalid_band,
        } } },
    };
    try std.testing.expectError(error.InvalidBandInventoryState, repartition(.{
        .relative_non_band_change = &fvl,
        .band_active = true,
        .first_active_layer = 0,
        .last_active_layer = 0,
    }, &pools));
    try std.testing.expectEqualSlices(f64, &before_non, &first_non);
    try std.testing.expectEqualSlices(f64, &before_band, &first_band);
}

test "inactive band leaves every owner unchanged" {
    const invalid_for_inactive_fvl = [_]f64{0};
    var non_band = [_]f64{5};
    var band = [_]f64{2};
    const pools = [_]Pool{
        .{ .name = "fertilizer", .inventory_unit = .moles, .storage = .{ .immediate = .{
            .non_band_inventory = &non_band,
            .band_inventory = &band,
        } } },
    };
    const result = try repartition(.{
        .relative_non_band_change = &invalid_for_inactive_fvl,
        .band_active = false,
        .first_active_layer = 0,
        .last_active_layer = 0,
    }, &pools);
    try std.testing.expectEqual(@as(usize, 0), result.layers_repartitioned);
    try std.testing.expectEqual(@as(f64, 5), non_band[0]);
    try std.testing.expectEqual(@as(f64, 2), band[0]);
}

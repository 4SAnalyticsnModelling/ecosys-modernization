const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const phosphate = @import("phosphate_network.zig");

/// Preserves extensive water-carried chemistry amounts when matrix-water
/// volume changes. This includes persistent solids and the authoritative
/// HPO4/H2PO4 intermediates that have no generic transport-state owner.
pub fn rebase(
    state: *chemistry.State,
    old_water_volume_m3: []const f64,
    new_water_volume_m3: []const f64,
) !void {
    try validateDimensions(state, old_water_volume_m3, new_water_volume_m3);
    for (0..state.cell_count) |cell| {
        try validateCell(state, cell, old_water_volume_m3[cell], new_water_volume_m3[cell]);
    }
    for (0..state.cell_count) |cell| {
        applyCell(state, cell, old_water_volume_m3[cell], new_water_volume_m3[cell]);
    }
}

/// Allocation-free hot-loop form. The accepted signed change satisfies
/// `new_water_volume_m3 = old_water_volume_m3 + water_volume_change_m3`.
pub fn rebaseFromAcceptedChange(
    state: *chemistry.State,
    new_water_volume_m3: []const f64,
    water_volume_change_m3: []const f64,
) !void {
    try validateDimensions(state, new_water_volume_m3, water_volume_change_m3);
    for (0..state.cell_count) |cell| {
        const old = try oldCarrier(new_water_volume_m3[cell], water_volume_change_m3[cell]);
        try validateCell(state, cell, old, new_water_volume_m3[cell]);
    }
    for (0..state.cell_count) |cell| {
        const old = new_water_volume_m3[cell] - water_volume_change_m3[cell];
        applyCell(state, cell, old, new_water_volume_m3[cell]);
    }
}

fn validateDimensions(state: *const chemistry.State, first: []const f64, second: []const f64) !void {
    if (first.len != state.cell_count or second.len != state.cell_count)
        return error.SolidCarrierDimensionMismatch;
}

fn oldCarrier(new: f64, change: f64) !f64 {
    if (!std.math.isFinite(new) or !std.math.isFinite(change))
        return error.InvalidSolidCarrierVolume;
    const old = new - change;
    if (!std.math.isFinite(old)) return error.InvalidSolidCarrierVolume;
    return old;
}

fn validateCell(state: *const chemistry.State, cell: usize, old: f64, new: f64) !void {
    if (!std.math.isFinite(old) or !std.math.isFinite(new) or old < 0 or new < 0)
        return error.InvalidSolidCarrierVolume;
    inline for (@typeInfo(@TypeOf(state.geochemistry_solids[cell])).@"struct".fields) |field| {
        try validatePool(@field(state.geochemistry_solids[cell], field.name), old, new);
    }
    inline for (@typeInfo(phosphate.State).@"struct".fields) |field| {
        if (comptime isPersistentWaterCarriedPhosphate(field.name)) {
            try validatePool(@field(state.non_band_phosphate[cell], field.name), old, new);
            try validatePool(@field(state.band_phosphate[cell], field.name), old, new);
        }
    }
}

fn validatePool(concentration_mol_per_m3: f64, old: f64, new: f64) !void {
    if (!std.math.isFinite(concentration_mol_per_m3) or concentration_mol_per_m3 < 0)
        return error.InvalidPersistentSolidPool;
    if (concentration_mol_per_m3 > 0 and (old == 0 or new == 0))
        return error.SolidMassWithoutCarrier;
}

fn applyCell(state: *chemistry.State, cell: usize, old: f64, new: f64) void {
    const scale = if (old == 0) 0.0 else old / new;
    inline for (@typeInfo(@TypeOf(state.geochemistry_solids[cell])).@"struct".fields) |field| {
        @field(state.geochemistry_solids[cell], field.name) *= scale;
    }
    inline for (@typeInfo(phosphate.State).@"struct".fields) |field| {
        if (comptime isPersistentWaterCarriedPhosphate(field.name)) {
            @field(state.non_band_phosphate[cell], field.name) *= scale;
            @field(state.band_phosphate[cell], field.name) *= scale;
        }
    }
}

fn isMineralSolid(comptime name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_solid_mol_per_m3");
}

fn isPersistentWaterCarriedPhosphate(comptime name: []const u8) bool {
    return isMineralSolid(name) or
        std.mem.eql(u8, name, "dissolved_hpo4_mol_p_per_m3") or
        std.mem.eql(u8, name, "dissolved_h2po4_mol_p_per_m3");
}

test "carrier rebase conserves carbon phosphorus and mineral amounts" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 3;
    state.geochemistry_solids[0].gibbsite_solid_mol_per_m3 = 5;
    state.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 = 7;
    state.band_phosphate[0].hydroxyapatite_solid_mol_per_m3 = 11;

    try rebase(&state, &.{2}, &.{0.5});
    try std.testing.expectEqual(@as(f64, 12), state.geochemistry_solids[0].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 20), state.geochemistry_solids[0].gibbsite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 28), state.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 44), state.band_phosphate[0].hydroxyapatite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 6), state.geochemistry_solids[0].calcite_solid_mol_per_m3 * 0.5);
    try std.testing.expectEqual(@as(f64, 14), state.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3 * 0.5);
}

test "carrier rebase preserves authoritative dissolved phosphate and leaves transport-owned pairs untouched" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0].carbon_dioxide = 2;
    state.non_band_phosphate[0].dissolved_po4_mol_p_per_m3 = 3;
    state.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 7;
    state.band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 8;
    state.non_band_phosphate[0].deprotonated_site_mol_per_megagram = 4;
    state.non_band_phosphate[0].iron_hpo4_pair_mol_per_m3 = 5;
    state.cation_exchange_mol_per_megagram[0].calcium = 6;
    try rebaseFromAcceptedChange(&state, &.{2}, &.{1});
    try std.testing.expectEqual(@as(f64, 2), state.aqueous[0].carbon_dioxide);
    try std.testing.expectEqual(@as(f64, 3), state.non_band_phosphate[0].dissolved_po4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 3.5), state.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 4), state.band_phosphate[0].dissolved_h2po4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 4), state.non_band_phosphate[0].deprotonated_site_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 5), state.non_band_phosphate[0].iron_hpo4_pair_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 6), state.cation_exchange_mol_per_megagram[0].calcium);
}

test "carrier rebase failure is atomic and dry zero pools remain zero" {
    var state = try chemistry.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 2;
    state.geochemistry_solids[1].calcite_solid_mol_per_m3 = 3;
    try std.testing.expectError(error.SolidMassWithoutCarrier, rebase(&state, &.{ 1, 1 }, &.{ 2, 0 }));
    try std.testing.expectEqual(@as(f64, 2), state.geochemistry_solids[0].calcite_solid_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 3), state.geochemistry_solids[1].calcite_solid_mol_per_m3);
    state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 0;
    state.geochemistry_solids[1].calcite_solid_mol_per_m3 = 0;
    try rebase(&state, &.{ 0, 0 }, &.{ 0, 1 });
    try std.testing.expectEqual(@as(f64, 0), state.geochemistry_solids[0].calcite_solid_mol_per_m3);
}

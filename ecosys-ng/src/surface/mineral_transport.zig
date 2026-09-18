const std = @import("std");
const Chemistry = @import("litter_chemistry.zig").State;
const runoff_carrier = @import("runoff_carrier.zig");

pub const Directions = struct {
    east_m3: []const f64,
    west_m3: []const f64,
    south_m3: []const f64,
    north_m3: []const f64,
};

pub const Output = struct {
    inorganic_nitrogen_export_g_n_by_cell: []f64,
    inorganic_phosphorus_export_g_p_by_cell: []f64,
    /// REDIST `SSB` pseudo-ion boundary loss (mol-equivalent count). Optional
    /// for compatibility callers; the production transaction always binds it.
    ion_export_mol_by_cell: ?[]f64 = null,
    intercell: runoff_carrier.IntercellElementOutput,
};

const Species = enum(u8) { ammonium, ammonia, nitrate, nitrite, hpo4, h2po4 };
const species_count = @typeInfo(Species).@"enum".fields.len;

/// Translates the TRNSFR surface `VFLW * pool` donor transaction without
/// repeating a full sub-hour model cycle. All directional transfers use the
/// converged hourly runoff, update simultaneously, and state_update atomically.
pub fn advance(
    allocator: std.mem.Allocator,
    chemistry: *Chemistry,
    nitrite_g_n: []f64,
    columns: usize,
    rows: usize,
    post_runoff_water_m3: []const f64,
    runoff_water_change_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    nitrogen_molar_mass_g_per_mol: f64,
    phosphorus_molar_mass_g_per_mol: f64,
    output: Output,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (chemistry.cells.len != cells or nitrite_g_n.len != cells or post_runoff_water_m3.len != cells or runoff_water_change_m3.len != cells or output.inorganic_nitrogen_export_g_n_by_cell.len != cells or output.inorganic_phosphorus_export_g_p_by_cell.len != cells or output.intercell.debit_by_cell.len != cells or output.intercell.credit_by_cell.len != cells) return error.SurfaceMineralTransportDimensionMismatch;
    if (output.ion_export_mol_by_cell) |values|
        if (values.len != cells) return error.SurfaceMineralTransportDimensionMismatch;
    inline for (.{ directions.east_m3, directions.west_m3, directions.south_m3, directions.north_m3 }) |values| if (values.len != cells) return error.SurfaceMineralTransportDimensionMismatch;
    if (!std.math.isFinite(maximum_transport_fraction) or maximum_transport_fraction < 0 or maximum_transport_fraction > 1 or !std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0 or !std.math.isFinite(phosphorus_molar_mass_g_per_mol) or phosphorus_molar_mass_g_per_mol <= 0) return error.InvalidSurfaceMineralTransportParameter;

    const amount_count = try std.math.mul(usize, cells, species_count);
    const original = try allocator.alloc(f64, amount_count);
    defer allocator.free(original);
    const candidate = try allocator.alloc(f64, amount_count);
    defer allocator.free(candidate);
    const boundary_export_mol = try allocator.alloc(f64, amount_count);
    defer allocator.free(boundary_export_mol);
    const intercell_debit_mol = try allocator.alloc(f64, amount_count);
    defer allocator.free(intercell_debit_mol);
    const intercell_credit_mol = try allocator.alloc(f64, amount_count);
    defer allocator.free(intercell_credit_mol);
    const pre_runoff_water = try allocator.alloc(f64, cells);
    defer allocator.free(pre_runoff_water);
    const nitrogen_export_candidate = try allocator.alloc(f64, cells);
    defer allocator.free(nitrogen_export_candidate);
    const phosphorus_export_candidate = try allocator.alloc(f64, cells);
    defer allocator.free(phosphorus_export_candidate);
    const ion_export_candidate = try allocator.alloc(f64, cells);
    defer allocator.free(ion_export_candidate);
    const intercell_debit_candidate = try allocator.alloc(runoff_carrier.ElementMass, cells);
    defer allocator.free(intercell_debit_candidate);
    const intercell_credit_candidate = try allocator.alloc(runoff_carrier.ElementMass, cells);
    defer allocator.free(intercell_credit_candidate);
    const nitrite_candidate_g_n = try allocator.alloc(f64, cells);
    defer allocator.free(nitrite_candidate_g_n);
    @memset(nitrogen_export_candidate, 0);
    @memset(phosphorus_export_candidate, 0);
    @memset(ion_export_candidate, 0);
    @memset(intercell_debit_candidate, .{});
    @memset(intercell_credit_candidate, .{});

    for (0..cells) |cell| {
        const water_after = post_runoff_water_m3[cell];
        const water_before = water_after - runoff_water_change_m3[cell];
        if (!std.math.isFinite(water_after) or water_after < 0 or
            !std.math.isFinite(water_before) or water_before < 0)
            return error.InvalidSurfaceMineralWaterState;
        pre_runoff_water[cell] = water_before;
        const state = chemistry.cells[cell];
        const concentrations = [_]f64{ state.ammonium_mol_per_m3, state.ammonia_mol_per_m3, state.nitrate_mol_per_m3, 0, state.hpo4_mol_p_per_m3, state.h2po4_mol_p_per_m3 };
        for (concentrations, 0..) |concentration, species| {
            if (!std.math.isFinite(concentration) or concentration < 0) return error.InvalidSurfaceMineralChemistryState;
            original[cell * species_count + species] = if (species == @intFromEnum(Species.nitrite)) blk: {
                if (!std.math.isFinite(nitrite_g_n[cell]) or nitrite_g_n[cell] < 0) return error.InvalidSurfaceMineralChemistryState;
                break :blk nitrite_g_n[cell] / nitrogen_molar_mass_g_per_mol;
            } else concentration * pre_runoff_water[cell];
        }
    }
    try runoff_carrier.calculateChanges(
        columns,
        rows,
        species_count,
        original,
        pre_runoff_water,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        candidate,
        boundary_export_mol,
    );
    try runoff_carrier.calculateIntercellTransfers(
        columns,
        rows,
        species_count,
        original,
        pre_runoff_water,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        intercell_debit_mol,
        intercell_credit_mol,
    );
    for (candidate, original) |*change, amount| change.* += amount;
    for (0..cells) |cell| for (0..species_count) |species| {
        const exported_mol =
            boundary_export_mol[cell * species_count + species];
        const debit_mol = intercell_debit_mol[cell * species_count + species];
        const credit_mol = intercell_credit_mol[cell * species_count + species];
        switch (@as(Species, @enumFromInt(species))) {
            .ammonium, .ammonia, .nitrate, .nitrite => {
                nitrogen_export_candidate[cell] += exported_mol * nitrogen_molar_mass_g_per_mol;
                ion_export_candidate[cell] += exported_mol * switch (@as(Species, @enumFromInt(species))) {
                    .ammonium => @as(f64, 2),
                    .ammonia, .nitrate, .nitrite => @as(f64, 1),
                    else => unreachable,
                };
                intercell_debit_candidate[cell].nitrogen_g += debit_mol * nitrogen_molar_mass_g_per_mol;
                intercell_credit_candidate[cell].nitrogen_g += credit_mol * nitrogen_molar_mass_g_per_mol;
            },
            .hpo4, .h2po4 => {
                phosphorus_export_candidate[cell] += exported_mol * phosphorus_molar_mass_g_per_mol;
                ion_export_candidate[cell] += exported_mol * switch (@as(Species, @enumFromInt(species))) {
                    .hpo4 => @as(f64, 2),
                    .h2po4 => @as(f64, 3),
                    else => unreachable,
                };
                intercell_debit_candidate[cell].phosphorus_g += debit_mol * phosphorus_molar_mass_g_per_mol;
                intercell_credit_candidate[cell].phosphorus_g += credit_mol * phosphorus_molar_mass_g_per_mol;
            },
        }
    };
    for (nitrogen_export_candidate, phosphorus_export_candidate, ion_export_candidate, intercell_debit_candidate, intercell_credit_candidate) |n, p, ions, debit, credit| {
        if (!std.math.isFinite(n) or n < 0 or
            !std.math.isFinite(p) or p < 0 or
            !std.math.isFinite(ions) or ions < 0)
            return error.NonFiniteSurfaceMineralBoundaryExport;
        _ = try debit.add(.{});
        _ = try credit.add(.{});
    }

    for (0..cells) |cell| {
        const water = post_runoff_water_m3[cell];
        for (0..species_count) |species| {
            const amount = candidate[cell * species_count + species];
            // A dry cell holding dissolved mineral mass is a legitimate state once
            // surface evaporation is active, and it is handled below by holding the
            // stored concentrations rather than dividing by zero. Rejecting it here
            // was the fourth blocker on enabling evaporation. See EXEC-004.
            _ = water;
            if (!std.math.isFinite(amount) or amount < 0)
                return error.InvalidSurfaceMineralTransportCandidate;
        }
    }

    // Build the entire chemistry state privately. Mineral carrier rebasing can
    // fail for a later cell, so mutating the live owner one cell at a time
    // would leave a partial hourly transaction.
    const Cell = @typeInfo(@TypeOf(chemistry.cells)).pointer.child;
    const chemistry_cells_candidate = try allocator.dupe(Cell, chemistry.cells);
    defer allocator.free(chemistry_cells_candidate);
    const mineral_reference_candidate = try allocator.dupe(
        f64,
        chemistry.mineral_reference_water_m3,
    );
    defer allocator.free(mineral_reference_candidate);
    var chemistry_candidate: Chemistry = .{
        .allocator = chemistry.allocator,
        .cells = chemistry_cells_candidate,
        .ph = chemistry.ph,
        .mineral_reference_water_m3 = mineral_reference_candidate,
        .dry_reference_water_m3 = chemistry.dry_reference_water_m3,
        .water_equilibrium_balance_mol = chemistry.water_equilibrium_balance_mol,
    };
    for (0..cells) |cell|
        try chemistry_candidate.renormalizeMinerals(
            cell,
            post_runoff_water_m3[cell],
        );
    for (0..cells) |cell| {
        const water = post_runoff_water_m3[cell];
        nitrite_candidate_g_n[cell] =
            candidate[cell * species_count + @intFromEnum(Species.nitrite)] *
            nitrogen_molar_mass_g_per_mol;
        if (!std.math.isFinite(nitrite_candidate_g_n[cell]))
            return error.NonFiniteSurfaceMineralTransportCandidate;
        if (water <= 0) {
            // Dry cell: hold the stored concentrations. Writing zero here would
            // silently destroy the dissolved mineral mass, which is why this case
            // used to be rejected outright. The litter carrier rebase remembers the
            // carrier these concentrations refer to, so the extensive amount stays
            // recoverable on rewetting.
            continue;
        }
        const inverse_water = 1.0 / water;
        chemistry_candidate.cells[cell].ammonium_mol_per_m3 = candidate[cell * species_count + @intFromEnum(Species.ammonium)] * inverse_water;
        chemistry_candidate.cells[cell].ammonia_mol_per_m3 = candidate[cell * species_count + @intFromEnum(Species.ammonia)] * inverse_water;
        chemistry_candidate.cells[cell].nitrate_mol_per_m3 = candidate[cell * species_count + @intFromEnum(Species.nitrate)] * inverse_water;
        chemistry_candidate.cells[cell].hpo4_mol_p_per_m3 = candidate[cell * species_count + @intFromEnum(Species.hpo4)] * inverse_water;
        chemistry_candidate.cells[cell].h2po4_mol_p_per_m3 = candidate[cell * species_count + @intFromEnum(Species.h2po4)] * inverse_water;
        inline for (.{
            chemistry_candidate.cells[cell].ammonium_mol_per_m3,
            chemistry_candidate.cells[cell].ammonia_mol_per_m3,
            chemistry_candidate.cells[cell].nitrate_mol_per_m3,
            chemistry_candidate.cells[cell].hpo4_mol_p_per_m3,
            chemistry_candidate.cells[cell].h2po4_mol_p_per_m3,
        }) |concentration|
            if (!std.math.isFinite(concentration) or concentration < 0)
                return error.NonFiniteSurfaceMineralTransportCandidate;
    }
    @memcpy(chemistry.cells, chemistry_candidate.cells);
    @memcpy(
        chemistry.mineral_reference_water_m3,
        chemistry_candidate.mineral_reference_water_m3,
    );
    @memcpy(nitrite_g_n, nitrite_candidate_g_n);
    @memcpy(
        output.inorganic_nitrogen_export_g_n_by_cell,
        nitrogen_export_candidate,
    );
    @memcpy(
        output.inorganic_phosphorus_export_g_p_by_cell,
        phosphorus_export_candidate,
    );
    if (output.ion_export_mol_by_cell) |values|
        @memcpy(values, ion_export_candidate);
    @memcpy(output.intercell.debit_by_cell, intercell_debit_candidate);
    @memcpy(output.intercell.credit_by_cell, intercell_credit_candidate);
}

test "surface mineral runoff conserves internal transfer and reports external N P" {
    var chemistry = try Chemistry.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.cells[0].ammonium_mol_per_m3 = 2;
    chemistry.cells[0].ammonia_mol_per_m3 = 1;
    chemistry.cells[0].nitrate_mol_per_m3 = 3;
    chemistry.cells[0].hpo4_mol_p_per_m3 = 0.5;
    chemistry.cells[0].h2po4_mol_p_per_m3 = 1.5;
    chemistry.cells[1].ammonium_mol_per_m3 = 4;
    chemistry.cells[1].ammonia_mol_per_m3 = 2;
    chemistry.cells[1].nitrate_mol_per_m3 = 6;
    chemistry.cells[1].hpo4_mol_p_per_m3 = 1;
    chemistry.cells[1].h2po4_mol_p_per_m3 = 3;
    var nitrogen_export = [_]f64{ 0, 0 };
    var phosphorus_export = [_]f64{ 0, 0 };
    var ion_export = [_]f64{ 0, 0 };
    var intercell_debit = [_]runoff_carrier.ElementMass{.{}} ** 2;
    var intercell_credit = [_]runoff_carrier.ElementMass{.{}} ** 2;
    var nitrite = [_]f64{ 14, 0 };
    const zero = [_]f64{ 0, 0 };
    try advance(std.testing.allocator, &chemistry, &nitrite, 2, 1, &.{ 0.5, 1.25 }, &.{ -0.5, 0.25 }, .{
        .east_m3 = &.{ 0.5, 0.25 },
        .west_m3 = &zero,
        .south_m3 = &zero,
        .north_m3 = &zero,
    }, 1, 14, 31, .{ .inorganic_nitrogen_export_g_n_by_cell = &nitrogen_export, .inorganic_phosphorus_export_g_p_by_cell = &phosphorus_export, .ion_export_mol_by_cell = &ion_export, .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit } });
    try std.testing.expectApproxEqAbs(@as(f64, 2), chemistry.cells[0].ammonium_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3.2), chemistry.cells[1].ammonium_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 42), nitrogen_export[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 7), nitrite[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 31), phosphorus_export[1], 1e-14);
    // The open-edge quarter-volume export carries 1 mol NH4 (weight 2),
    // 0.5 mol NH3, 1.5 mol NO3, 0.25 mol HPO4 (weight 2), and 0.75 mol
    // H2PO4 (weight 3).
    try std.testing.expectApproxEqAbs(@as(f64, 6.75), ion_export[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 49), intercell_debit[0].nitrogen_g, 1e-14);
    try std.testing.expectApproxEqAbs(intercell_debit[0].nitrogen_g, intercell_credit[1].nitrogen_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 31), intercell_debit[0].phosphorus_g, 1e-14);
    try std.testing.expectApproxEqAbs(intercell_debit[0].phosphorus_g, intercell_credit[1].phosphorus_g, 1e-14);
}

test "a dry surface cell preserves its dissolved mineral concentrations" {
    // EXEC-004: this used to fail with InvalidSurfaceMineralTransportCandidate,
    // the fourth blocker on enabling surface evaporation. The guard existed for a
    // real reason: the writeback used `inverse_water = 0` for a dry cell, which
    // would have silently zeroed the concentrations and destroyed the mass. The fix
    // holds them instead, so both the error and the mass loss are gone.
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.cells[0].ammonium_mol_per_m3 = 2;
    chemistry.cells[0].nitrate_mol_per_m3 = 3;
    chemistry.cells[0].h2po4_mol_p_per_m3 = 1.5;
    var nitrogen_export = [_]f64{0};
    var phosphorus_export = [_]f64{0};
    var intercell_debit = [_]runoff_carrier.ElementMass{.{}};
    var intercell_credit = [_]runoff_carrier.ElementMass{.{}};
    var nitrite = [_]f64{0};
    const zero = [_]f64{0};
    // Evaporate the carrier to exactly dry with no runoff.
    try advance(std.testing.allocator, &chemistry, &nitrite, 1, 1, &.{1}, &.{0}, .{
        .east_m3 = &zero,
        .west_m3 = &zero,
        .south_m3 = &zero,
        .north_m3 = &zero,
    }, 1, 14, 31, .{
        .inorganic_nitrogen_export_g_n_by_cell = &nitrogen_export,
        .inorganic_phosphorus_export_g_p_by_cell = &phosphorus_export,
        .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
    });
    // A wet baseline first: with a unit carrier the concentrations are unchanged.
    try std.testing.expectApproxEqAbs(@as(f64, 2), chemistry.cells[0].ammonium_mol_per_m3, 1e-15);

    // Now dry it out. This must not error and must not zero the pools.
    try advance(std.testing.allocator, &chemistry, &nitrite, 1, 1, &.{0}, &.{0}, .{
        .east_m3 = &zero,
        .west_m3 = &zero,
        .south_m3 = &zero,
        .north_m3 = &zero,
    }, 1, 14, 31, .{
        .inorganic_nitrogen_export_g_n_by_cell = &nitrogen_export,
        .inorganic_phosphorus_export_g_p_by_cell = &phosphorus_export,
        .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
    });
    try std.testing.expect(chemistry.cells[0].ammonium_mol_per_m3 > 0);
    try std.testing.expect(chemistry.cells[0].nitrate_mol_per_m3 > 0);
    try std.testing.expect(chemistry.cells[0].h2po4_mol_p_per_m3 > 0);
    // Specifically, they are held at their previous values rather than scaled.
    try std.testing.expectApproxEqAbs(@as(f64, 2), chemistry.cells[0].ammonium_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), chemistry.cells[0].nitrate_mol_per_m3, 1e-15);
}

test "failed surface mineral transport leaves chemistry unchanged" {
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.cells[0].ammonium_mol_per_m3 = 2;
    var n = [_]f64{0};
    var p = [_]f64{0};
    var intercell_debit = [_]runoff_carrier.ElementMass{.{}};
    var intercell_credit = [_]runoff_carrier.ElementMass{.{}};
    var nitrite = [_]f64{0};
    try std.testing.expectError(error.InvalidSurfaceMineralWaterState, advance(std.testing.allocator, &chemistry, &nitrite, 1, 1, &.{0}, &.{1}, .{ .east_m3 = &.{0}, .west_m3 = &.{0}, .south_m3 = &.{0}, .north_m3 = &.{0} }, 1, 14, 31, .{ .inorganic_nitrogen_export_g_n_by_cell = &n, .inorganic_phosphorus_export_g_p_by_cell = &p, .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit } }));
    try std.testing.expectEqual(@as(f64, 2), chemistry.cells[0].ammonium_mol_per_m3);
}

test "late mineral carrier failure rolls back chemistry nitrite and exports" {
    var chemistry = try Chemistry.init(std.testing.allocator, 2);
    defer chemistry.deinit();
    chemistry.cells[0].ammonium_mol_per_m3 = 2;
    chemistry.cells[0].salt_minerals.calcite_mol_per_m3 = 3;
    chemistry.cells[1].ammonium_mol_per_m3 = 4;
    chemistry.mineral_reference_water_m3[0] = 1;
    chemistry.mineral_reference_water_m3[1] = std.math.nan(f64);
    const cells_before = chemistry.cells[0..2].*;
    const references_before = chemistry.mineral_reference_water_m3[0..2].*;
    var nitrogen_export = [_]f64{ 7, 8 };
    var phosphorus_export = [_]f64{ 9, 10 };
    var intercell_debit = [_]runoff_carrier.ElementMass{.{ .nitrogen_g = 21 }} ** 2;
    var intercell_credit = [_]runoff_carrier.ElementMass{.{ .phosphorus_g = 22 }} ** 2;
    var nitrite = [_]f64{ 11, 12 };
    const nitrite_before = nitrite;
    const zero = [_]f64{ 0, 0 };
    try std.testing.expectError(
        error.InvalidLitterMineralReferenceWater,
        advance(
            std.testing.allocator,
            &chemistry,
            &nitrite,
            2,
            1,
            &.{ 0.5, 0.5 },
            &zero,
            .{
                .east_m3 = &zero,
                .west_m3 = &zero,
                .south_m3 = &zero,
                .north_m3 = &zero,
            },
            1,
            14,
            31,
            .{
                .inorganic_nitrogen_export_g_n_by_cell = &nitrogen_export,
                .inorganic_phosphorus_export_g_p_by_cell = &phosphorus_export,
                .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
            },
        ),
    );
    try std.testing.expectEqualDeep(cells_before, chemistry.cells[0..2].*);
    try std.testing.expect(std.mem.eql(
        u8,
        std.mem.asBytes(&references_before),
        std.mem.sliceAsBytes(chemistry.mineral_reference_water_m3),
    ));
    try std.testing.expectEqualSlices(f64, &nitrite_before, &nitrite);
    try std.testing.expectEqualSlices(f64, &.{ 7, 8 }, &nitrogen_export);
    try std.testing.expectEqualSlices(f64, &.{ 9, 10 }, &phosphorus_export);
    try std.testing.expectEqual(@as(f64, 21), intercell_debit[0].nitrogen_g);
    try std.testing.expectEqual(@as(f64, 22), intercell_credit[1].phosphorus_g);
}

test "runoff water change preserves nonmobile solid mineral inventories" {
    var chemistry = try Chemistry.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.cells[0].salt_minerals.calcite_mol_per_m3 = 2;
    chemistry.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3 = 3;
    try chemistry.bindMineralReferenceWater(&.{1});
    var n = [_]f64{0};
    var p = [_]f64{0};
    var intercell_debit = [_]runoff_carrier.ElementMass{.{}};
    var intercell_credit = [_]runoff_carrier.ElementMass{.{}};
    var nitrite = [_]f64{0};
    const zero = [_]f64{0};
    try advance(
        std.testing.allocator,
        &chemistry,
        &nitrite,
        1,
        1,
        &.{0.5},
        &.{-0.5},
        .{
            .east_m3 = &zero,
            .west_m3 = &zero,
            .south_m3 = &zero,
            .north_m3 = &zero,
        },
        1,
        14,
        31,
        .{
            .inorganic_nitrogen_export_g_n_by_cell = &n,
            .inorganic_phosphorus_export_g_p_by_cell = &p,
            .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
        },
    );
    try std.testing.expectEqual(
        @as(f64, 2),
        chemistry.cells[0].salt_minerals.calcite_mol_per_m3 * 0.5,
    );
    try std.testing.expectEqual(
        @as(f64, 3),
        chemistry.cells[0].phosphate_minerals.hydroxyapatite_mol_per_m3 * 0.5,
    );
}

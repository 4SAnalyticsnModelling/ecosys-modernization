const std = @import("std");
const organic = @import("../soil/organic/initialization.zig");
const runoff_carrier = @import("runoff_carrier.zig");

pub const Directions = struct {
    east_m3: []const f64,
    west_m3: []const f64,
    south_m3: []const f64,
    north_m3: []const f64,
};

pub const Output = struct {
    dissolved_organic_carbon_export_g_c_by_cell: []f64,
    dissolved_organic_nitrogen_export_g_n_by_cell: []f64,
    dissolved_organic_phosphorus_export_g_p_by_cell: []f64,
    intercell: runoff_carrier.IntercellElementOutput,
};

const components_per_substrate: usize = 4;
const component_count: usize = organic.substrate_count * components_per_substrate;

/// TRNSFR surface transport of five DOC/DON/DOP/acetate complexes using the
/// converged hourly runoff. Every directional transfer is based on the same
/// pre-runoff donor inventory and the complete update state_updates atomically.
pub fn advance(
    allocator: std.mem.Allocator,
    state: *organic.State,
    columns: usize,
    rows: usize,
    post_runoff_water_m3: []const f64,
    runoff_water_change_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    output: Output,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    try validate(state, cells, post_runoff_water_m3, runoff_water_change_m3, directions, maximum_transport_fraction, output);
    const coordinate_count = try std.math.mul(usize, cells, component_count);
    const original = try allocator.alloc(f64, coordinate_count);
    defer allocator.free(original);
    const candidate = try allocator.alloc(f64, original.len);
    defer allocator.free(candidate);
    const boundary_export = try allocator.alloc(f64, original.len);
    defer allocator.free(boundary_export);
    const intercell_debit = try allocator.alloc(f64, original.len);
    defer allocator.free(intercell_debit);
    const intercell_credit = try allocator.alloc(f64, original.len);
    defer allocator.free(intercell_credit);
    const pre_runoff_water_m3 = try allocator.alloc(f64, cells);
    defer allocator.free(pre_runoff_water_m3);
    for (0..cells) |cell| {
        const before = post_runoff_water_m3[cell] - runoff_water_change_m3[cell];
        if (!std.math.isFinite(before) or !std.math.isFinite(post_runoff_water_m3[cell]) or post_runoff_water_m3[cell] < 0)
            return error.InvalidSurfaceOrganicWaterState;
        const reconstruction_scale = @max(1.0, @max(@abs(post_runoff_water_m3[cell]), @abs(runoff_water_change_m3[cell])));
        const reconstruction_roundoff = 64.0 * std.math.floatEps(f64) * reconstruction_scale;
        if (before < -reconstruction_roundoff) return error.InvalidSurfaceOrganicWaterState;
        // This is not a pool repair: an exact-zero pre-runoff carrier can
        // reconstruct a few ulps below zero after signed-flux subtraction.
        pre_runoff_water_m3[cell] = if (before < 0) 0 else before;
        for (0..organic.substrate_count) |substrate| {
            const pool = state.dissolved[cell * organic.substrate_count + substrate];
            const acetate = state.dissolved_acetate_carbon_g_c[cell * organic.substrate_count + substrate];
            inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p, acetate }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceOrganicPool;
            const base = cell * component_count + substrate * components_per_substrate;
            original[base] = pool.carbon_g_c;
            original[base + 1] = pool.nitrogen_g_n;
            original[base + 2] = pool.phosphorus_g_p;
            original[base + 3] = acetate;
        }
    }
    try runoff_carrier.calculateChanges(
        columns,
        rows,
        component_count,
        original,
        pre_runoff_water_m3,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        candidate,
        boundary_export,
    );
    try runoff_carrier.calculateIntercellTransfers(
        columns,
        rows,
        component_count,
        original,
        pre_runoff_water_m3,
        .{
            .east_m3 = directions.east_m3,
            .west_m3 = directions.west_m3,
            .south_m3 = directions.south_m3,
            .north_m3 = directions.north_m3,
        },
        maximum_transport_fraction,
        intercell_debit,
        intercell_credit,
    );
    for (candidate, original) |*change, amount| change.* += amount;
    for (candidate) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSurfaceOrganicTransportCandidate;

    const carbon_export_candidate = try allocator.alloc(f64, cells);
    defer allocator.free(carbon_export_candidate);
    const nitrogen_export_candidate = try allocator.alloc(f64, cells);
    defer allocator.free(nitrogen_export_candidate);
    const phosphorus_export_candidate = try allocator.alloc(f64, cells);
    defer allocator.free(phosphorus_export_candidate);
    const intercell_debit_candidate = try allocator.alloc(runoff_carrier.ElementMass, cells);
    defer allocator.free(intercell_debit_candidate);
    const intercell_credit_candidate = try allocator.alloc(runoff_carrier.ElementMass, cells);
    defer allocator.free(intercell_credit_candidate);
    @memset(carbon_export_candidate, 0);
    @memset(nitrogen_export_candidate, 0);
    @memset(phosphorus_export_candidate, 0);
    @memset(intercell_debit_candidate, .{});
    @memset(intercell_credit_candidate, .{});
    for (0..cells) |cell| for (0..component_count) |component| {
        const exported =
            boundary_export[cell * component_count + component];
        const debit = intercell_debit[cell * component_count + component];
        const credit = intercell_credit[cell * component_count + component];
        switch (component % components_per_substrate) {
            0, 3 => {
                carbon_export_candidate[cell] += exported;
                intercell_debit_candidate[cell].carbon_g += debit;
                intercell_credit_candidate[cell].carbon_g += credit;
            },
            1 => {
                nitrogen_export_candidate[cell] += exported;
                intercell_debit_candidate[cell].nitrogen_g += debit;
                intercell_credit_candidate[cell].nitrogen_g += credit;
            },
            2 => {
                phosphorus_export_candidate[cell] += exported;
                intercell_debit_candidate[cell].phosphorus_g += debit;
                intercell_credit_candidate[cell].phosphorus_g += credit;
            },
            else => unreachable,
        }
    };
    for (carbon_export_candidate, nitrogen_export_candidate, phosphorus_export_candidate, intercell_debit_candidate, intercell_credit_candidate) |c, n, p, debit, credit| {
        inline for (.{ c, n, p }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSurfaceOrganicTransportCandidate;
        _ = try debit.add(.{});
        _ = try credit.add(.{});
    }
    for (0..cells) |cell| for (0..organic.substrate_count) |substrate| {
        const base = cell * component_count + substrate * components_per_substrate;
        state.dissolved[cell * organic.substrate_count + substrate] = .{ .carbon_g_c = candidate[base], .nitrogen_g_n = candidate[base + 1], .phosphorus_g_p = candidate[base + 2] };
        state.dissolved_acetate_carbon_g_c[cell * organic.substrate_count + substrate] = candidate[base + 3];
    };
    @memcpy(output.dissolved_organic_carbon_export_g_c_by_cell, carbon_export_candidate);
    @memcpy(output.dissolved_organic_nitrogen_export_g_n_by_cell, nitrogen_export_candidate);
    @memcpy(output.dissolved_organic_phosphorus_export_g_p_by_cell, phosphorus_export_candidate);
    @memcpy(output.intercell.debit_by_cell, intercell_debit_candidate);
    @memcpy(output.intercell.credit_by_cell, intercell_credit_candidate);
}

fn validate(state: *const organic.State, cells: usize, water: []const f64, water_change: []const f64, directions: Directions, maximum_fraction: f64, output: Output) !void {
    if (state.layer_count != cells or water.len != cells or water_change.len != cells or output.dissolved_organic_carbon_export_g_c_by_cell.len != cells or output.dissolved_organic_nitrogen_export_g_n_by_cell.len != cells or output.dissolved_organic_phosphorus_export_g_p_by_cell.len != cells or output.intercell.debit_by_cell.len != cells or output.intercell.credit_by_cell.len != cells) return error.SurfaceOrganicTransportDimensionMismatch;
    inline for (.{ directions.east_m3, directions.west_m3, directions.south_m3, directions.north_m3 }) |values| if (values.len != cells) return error.SurfaceOrganicTransportDimensionMismatch;
    if (!std.math.isFinite(maximum_fraction) or maximum_fraction < 0 or maximum_fraction > 1) return error.InvalidSurfaceOrganicTransportParameter;
}

test "surface organic runoff conserves internal transfer and reports source-cell export" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.dissolved[0] = .{ .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 2 };
    state.dissolved_acetate_carbon_g_c[0] = 6;
    state.dissolved[organic.substrate_count] = .{ .carbon_g_c = 5, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    state.dissolved_acetate_carbon_g_c[organic.substrate_count] = 2;
    var carbon = [_]f64{ 0, 0 };
    var nitrogen = [_]f64{ 0, 0 };
    var phosphorus = [_]f64{ 0, 0 };
    var intercell_debit = [_]runoff_carrier.ElementMass{.{}} ** 2;
    var intercell_credit = [_]runoff_carrier.ElementMass{.{}} ** 2;
    const zero = [_]f64{ 0, 0 };
    try advance(std.testing.allocator, &state, 2, 1, &.{ 0.5, 1 }, &.{ -0.5, 0 }, .{ .east_m3 = &.{ 0.5, 1 }, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero }, 1, .{
        .dissolved_organic_carbon_export_g_c_by_cell = &carbon,
        .dissolved_organic_nitrogen_export_g_n_by_cell = &nitrogen,
        .dissolved_organic_phosphorus_export_g_p_by_cell = &phosphorus,
        .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0), carbon[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 7), carbon[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), nitrogen[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), phosphorus[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 7), intercell_debit[0].carbon_g, 1e-15);
    try std.testing.expectApproxEqAbs(intercell_debit[0].carbon_g, intercell_credit[1].carbon_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2), intercell_debit[0].nitrogen_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), intercell_debit[0].phosphorus_g, 1e-15);
}

test "surface organic failure preserves pools and previously accepted export diagnostics" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.dissolved[0].carbon_g_c = 8;
    state.dissolved[organic.substrate_count].phosphorus_g_p = std.math.nan(f64);
    var carbon = [_]f64{ 11, 12 };
    var nitrogen = [_]f64{ 13, 14 };
    var phosphorus = [_]f64{ 15, 16 };
    var intercell_debit = [_]runoff_carrier.ElementMass{.{ .carbon_g = 17 }} ** 2;
    var intercell_credit = [_]runoff_carrier.ElementMass{.{ .nitrogen_g = 18 }} ** 2;
    const zero = [_]f64{ 0, 0 };
    try std.testing.expectError(
        error.InvalidSurfaceOrganicPool,
        advance(
            std.testing.allocator,
            &state,
            2,
            1,
            &.{ 1, 1 },
            &zero,
            .{ .east_m3 = &zero, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero },
            1,
            .{
                .dissolved_organic_carbon_export_g_c_by_cell = &carbon,
                .dissolved_organic_nitrogen_export_g_n_by_cell = &nitrogen,
                .dissolved_organic_phosphorus_export_g_p_by_cell = &phosphorus,
                .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
            },
        ),
    );
    try std.testing.expectEqual(@as(f64, 8), state.dissolved[0].carbon_g_c);
    try std.testing.expect(std.math.isNan(state.dissolved[organic.substrate_count].phosphorus_g_p));
    try std.testing.expectEqualDeep([_]f64{ 11, 12 }, carbon);
    try std.testing.expectEqualDeep([_]f64{ 13, 14 }, nitrogen);
    try std.testing.expectEqualDeep([_]f64{ 15, 16 }, phosphorus);
    try std.testing.expectEqual(@as(f64, 17), intercell_debit[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 18), intercell_credit[1].nitrogen_g);
}

test "surface runoff DOC and acetate capacity changes close local heat at unequal temperatures" {
    const heat_rebase = @import("litter_organic_heat_rebase.zig");
    const hourly = @import("../validation/hourly_cell_conservation.zig");
    const layers = @import("../validation/layer_local_conservation.zig");
    const inventory = @import("../validation/landscape_mass_inventory.zig");
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();
    for (0..2) |cell| {
        state.dissolved[cell * organic.substrate_count].carbon_g_c = 12;
        state.dissolved_acetate_carbon_g_c[cell * organic.substrate_count] = 2;
    }
    const temperatures = [_]f64{ 280, 300 };
    const specific_capacity = 2.496e-6;
    const before_carbon = [_]f64{ try state.totalCarbon_g_c(0), try state.totalCarbon_g_c(1) };
    var carbon: [2]f64 = undefined;
    var nitrogen: [2]f64 = undefined;
    var phosphorus: [2]f64 = undefined;
    var debit: [2]runoff_carrier.ElementMass = undefined;
    var credit: [2]runoff_carrier.ElementMass = undefined;
    const zero = [_]f64{ 0, 0 };
    // Cell 0 transfers half its original donor to cell 1. Simultaneously,
    // cell 1 exports a quarter of its ORIGINAL donor, including acetate.
    try advance(std.testing.allocator, &state, 2, 1, &.{ 0.5, 1.25 }, &.{ -0.5, 0.25 }, .{ .east_m3 = &.{ 0.5, 0.25 }, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero }, 1, .{ .dissolved_organic_carbon_export_g_c_by_cell = &carbon, .dissolved_organic_nitrogen_export_g_n_by_cell = &nitrogen, .dissolved_organic_phosphorus_export_g_p_by_cell = &phosphorus, .intercell = .{ .debit_by_cell = &debit, .credit_by_cell = &credit } });
    try std.testing.expectEqual(@as(f64, 7), debit[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 3.5), carbon[1]);
    const after_carbon = [_]f64{ try state.totalCarbon_g_c(0), try state.totalCarbon_g_c(1) };
    try std.testing.expectEqualSlices(f64, &.{ 7, 17.5 }, &after_carbon);
    var rebase: [2]f64 = undefined;
    try heat_rebase.landscapeOrganicCarbonRebaseHeatMegajoulesByCell(&rebase, &before_carbon, &after_carbon, &temperatures, specific_capacity);
    try std.testing.expect(rebase[0] < 0 and rebase[1] > 0);

    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 2);
    defer cell_ledger.deinit();
    const layout = try layers.Layout.init(2, 1, 1);
    var layer_ledger = try layers.Ledger.init(std.testing.allocator, layout);
    defer layer_ledger.deinit();
    var before: [2]inventory.Storage = @splat(.{});
    var after: [2]inventory.Storage = @splat(.{});
    var layer_before: [8]inventory.Storage = @splat(.{});
    var layer_after: [8]inventory.Storage = @splat(.{});
    for (0..2) |cell| {
        // Water runoff has already completed. This is the following fixed-T
        // carbon transaction, with all nonorganic storage held unchanged.
        before[cell].heat_megajoules = (0.03 + specific_capacity * before_carbon[cell]) * temperatures[cell];
        after[cell].heat_megajoules = (0.03 + specific_capacity * after_carbon[cell]) * temperatures[cell];
        const scope = try layout.index(.{ .kind = .surface, .cell = cell });
        layer_before[scope] = before[cell];
        layer_after[scope] = after[cell];
    }
    const tolerance: hourly.Tolerances = .{ .absolute_per_area = .{}, .relative = 1e-9 };
    var unbooked = try hourly.evaluate(std.testing.allocator, &before, &after, cell_ledger.cells, &.{ 1, 1 }, tolerance);
    defer unbooked.deinit(std.testing.allocator);
    try std.testing.expect(!unbooked.accepted());
    try cell_ledger.accumulateSignedInternalHeat(&rebase);
    try layers.accumulateSurfaceOrganicHeatRebase(&layer_ledger, &rebase);
    var booked = try hourly.evaluate(std.testing.allocator, &before, &after, cell_ledger.cells, &.{ 1, 1 }, tolerance);
    defer booked.deinit(std.testing.allocator);
    try std.testing.expect(booked.accepted());
    var local = try layers.evaluate(std.testing.allocator, &layer_before, &layer_after, layer_ledger.activity, &@as([8]f64, @splat(1)), tolerance);
    defer local.deinit(std.testing.allocator);
    try std.testing.expect(local.accepted());
}

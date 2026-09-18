const std = @import("std");
const gas = @import("../soil/gas/transport.zig");
const runoff_carrier = @import("runoff_carrier.zig");

pub const Directions = struct {
    east_m3: []const f64,
    west_m3: []const f64,
    south_m3: []const f64,
    north_m3: []const f64,
};

pub const Output = struct {
    inorganic_carbon_export_g_c_by_cell: []f64,
    dissolved_oxygen_export_g_o_by_cell: []f64,
    dissolved_nitrogen_export_g_n_by_cell: []f64,
    dissolved_hydrogen_export_g_h_by_cell: []f64,
    intercell: runoff_carrier.IntercellElementOutput,
};

/// TRNSFR `RQRCOS/RQRCHS/...`: route gas-owned dissolved litter gases with the
/// converged surface runoff. Directional transfers share the pre-runoff
/// inventory, so routing is order independent and state_updates atomically.
/// Aqueous NH3 is excluded because `surface_mineral_transport` already routes
/// the authoritative `ZNH3S(0)` chemistry pool in mol N; the gas slot is only
/// a transient phase-exchange mirror.
pub fn advance(
    allocator: std.mem.Allocator,
    state: *gas.State,
    columns: usize,
    rows: usize,
    post_runoff_water_m3: []const f64,
    runoff_water_change_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    output: Output,
) !void {
    const cells = try std.math.mul(usize, columns, rows);
    if (state.cell_count != cells or post_runoff_water_m3.len != cells or runoff_water_change_m3.len != cells or output.inorganic_carbon_export_g_c_by_cell.len != cells or output.dissolved_oxygen_export_g_o_by_cell.len != cells or output.dissolved_nitrogen_export_g_n_by_cell.len != cells or output.dissolved_hydrogen_export_g_h_by_cell.len != cells or output.intercell.debit_by_cell.len != cells or output.intercell.credit_by_cell.len != cells) return error.SurfaceDissolvedGasDimensionMismatch;
    inline for (.{ directions.east_m3, directions.west_m3, directions.south_m3, directions.north_m3 }) |values| if (values.len != cells) return error.SurfaceDissolvedGasDimensionMismatch;
    if (!std.math.isFinite(maximum_transport_fraction) or maximum_transport_fraction < 0 or maximum_transport_fraction > 1) return error.InvalidSurfaceDissolvedGasTransportParameter;

    const original = try allocator.dupe(f64, state.dissolved_mass_g);
    defer allocator.free(original);
    const candidate = try allocator.dupe(f64, original);
    defer allocator.free(candidate);
    const ammonia = @intFromEnum(gas.Species.ammonia);
    const ammonia_mirror = try allocator.alloc(f64, cells);
    defer allocator.free(ammonia_mirror);
    for (0..cells) |cell|
        ammonia_mirror[cell] = original[cell * gas.species_count + ammonia];
    const boundary_export = try allocator.alloc(f64, original.len);
    defer allocator.free(boundary_export);
    const intercell_debit = try allocator.alloc(f64, original.len);
    defer allocator.free(intercell_debit);
    const intercell_credit = try allocator.alloc(f64, original.len);
    defer allocator.free(intercell_credit);
    const pre_runoff_water_m3 = try allocator.alloc(f64, cells);
    defer allocator.free(pre_runoff_water_m3);
    const candidate_carbon_export_g_c_by_cell = try allocator.alloc(f64, cells);
    defer allocator.free(candidate_carbon_export_g_c_by_cell);
    @memset(candidate_carbon_export_g_c_by_cell, 0);
    const candidate_oxygen_export_g_o_by_cell = try allocator.alloc(f64, cells);
    defer allocator.free(candidate_oxygen_export_g_o_by_cell);
    @memset(candidate_oxygen_export_g_o_by_cell, 0);
    const candidate_nitrogen_export_g_n_by_cell = try allocator.alloc(f64, cells);
    defer allocator.free(candidate_nitrogen_export_g_n_by_cell);
    @memset(candidate_nitrogen_export_g_n_by_cell, 0);
    const candidate_hydrogen_export_g_h_by_cell = try allocator.alloc(f64, cells);
    defer allocator.free(candidate_hydrogen_export_g_h_by_cell);
    @memset(candidate_hydrogen_export_g_h_by_cell, 0);
    const intercell_debit_candidate = try allocator.alloc(runoff_carrier.ElementMass, cells);
    defer allocator.free(intercell_debit_candidate);
    const intercell_credit_candidate = try allocator.alloc(runoff_carrier.ElementMass, cells);
    defer allocator.free(intercell_credit_candidate);
    @memset(intercell_debit_candidate, .{});
    @memset(intercell_credit_candidate, .{});

    for (0..cells) |cell| {
        const before = post_runoff_water_m3[cell] - runoff_water_change_m3[cell];
        if (!std.math.isFinite(before) or before < 0 or !std.math.isFinite(post_runoff_water_m3[cell]) or post_runoff_water_m3[cell] < 0) return error.InvalidSurfaceDissolvedGasWaterState;
        pre_runoff_water_m3[cell] = before;
        for (original[cell * gas.species_count ..][0..gas.species_count]) |mass| if (!std.math.isFinite(mass) or mass < 0) return error.InvalidSurfaceDissolvedGasPool;
    }

    try runoff_carrier.calculateChanges(
        columns,
        rows,
        gas.species_count,
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
        gas.species_count,
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
    for (0..cells) |cell|
        candidate[cell * gas.species_count + ammonia] = ammonia_mirror[cell];
    for (0..cells) |cell| for (0..gas.species_count) |species_index| {
        const species: gas.Species = @enumFromInt(species_index);
        if (species == .ammonia) continue;
        const index = cell * gas.species_count + species_index;
        const exported = boundary_export[index];
        const debit = intercell_debit[index];
        const credit = intercell_credit[index];
        switch (species) {
            .carbon_dioxide, .methane => {
                candidate_carbon_export_g_c_by_cell[cell] += exported;
                intercell_debit_candidate[cell].carbon_g += debit;
                intercell_credit_candidate[cell].carbon_g += credit;
            },
            .oxygen => {
                candidate_oxygen_export_g_o_by_cell[cell] += exported;
                intercell_debit_candidate[cell].oxygen_g += debit;
                intercell_credit_candidate[cell].oxygen_g += credit;
            },
            .nitrogen, .nitrous_oxide => {
                candidate_nitrogen_export_g_n_by_cell[cell] += exported;
                intercell_debit_candidate[cell].nitrogen_g += debit;
                intercell_credit_candidate[cell].nitrogen_g += credit;
            },
            .hydrogen => {
                candidate_hydrogen_export_g_h_by_cell[cell] += exported;
                intercell_debit_candidate[cell].hydrogen_g += debit;
                intercell_credit_candidate[cell].hydrogen_g += credit;
            },
            .ammonia => unreachable,
        }
    };
    for (candidate_carbon_export_g_c_by_cell, candidate_oxygen_export_g_o_by_cell, candidate_nitrogen_export_g_n_by_cell, candidate_hydrogen_export_g_h_by_cell, intercell_debit_candidate, intercell_credit_candidate) |c, o, n, h, debit, credit| {
        inline for (.{ c, o, n, h }) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSurfaceDissolvedGasCandidate;
        _ = try debit.add(.{});
        _ = try credit.add(.{});
    }
    for (candidate) |mass| if (!std.math.isFinite(mass) or mass < 0) return error.InvalidSurfaceDissolvedGasCandidate;
    @memcpy(state.dissolved_mass_g, candidate);
    @memcpy(output.inorganic_carbon_export_g_c_by_cell, candidate_carbon_export_g_c_by_cell);
    @memcpy(output.dissolved_oxygen_export_g_o_by_cell, candidate_oxygen_export_g_o_by_cell);
    @memcpy(output.dissolved_nitrogen_export_g_n_by_cell, candidate_nitrogen_export_g_n_by_cell);
    @memcpy(output.dissolved_hydrogen_export_g_h_by_cell, candidate_hydrogen_export_g_h_by_cell);
    @memcpy(output.intercell.debit_by_cell, intercell_debit_candidate);
    @memcpy(output.intercell.credit_by_cell, intercell_credit_candidate);
}

test "aqueous litter ammonia mirror never enters generic runoff transport" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    const ammonia = @intFromEnum(gas.Species.ammonia);
    state.dissolved_mass_g[ammonia] = 8;
    state.dissolved_mass_g[gas.species_count + ammonia] = 2;
    var carbon_export = [_]f64{ 7, 7 };
    var oxygen_export = [_]f64{ 11, 11 };
    var nitrogen_export = [_]f64{ 13, 13 };
    var hydrogen_export = [_]f64{ 17, 17 };
    var intercell_debit = [_]runoff_carrier.ElementMass{.{}} ** 2;
    var intercell_credit = [_]runoff_carrier.ElementMass{.{}} ** 2;
    const zero = [_]f64{ 0, 0 };
    try advance(std.testing.allocator, &state, 2, 1, &.{ 0.5, 1 }, &.{ -0.5, 0 }, .{
        .east_m3 = &.{ 0.5, 1 },
        .west_m3 = &zero,
        .south_m3 = &zero,
        .north_m3 = &zero,
    }, 1, .{
        .inorganic_carbon_export_g_c_by_cell = &carbon_export,
        .dissolved_oxygen_export_g_o_by_cell = &oxygen_export,
        .dissolved_nitrogen_export_g_n_by_cell = &nitrogen_export,
        .dissolved_hydrogen_export_g_h_by_cell = &hydrogen_export,
        .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
    });
    try std.testing.expectEqual(@as(f64, 8), state.dissolved_mass_g[ammonia]);
    try std.testing.expectEqual(@as(f64, 2), state.dissolved_mass_g[gas.species_count + ammonia]);
}

test "surface dissolved gas routing rejects sub-tolerance negative water without mutation" {
    var state = try gas.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.dissolved_mass_g[@intFromEnum(gas.Species.oxygen)] = 1;
    const before = state.dissolved_mass_g[@intFromEnum(gas.Species.oxygen)];
    var carbon_export = [_]f64{7};
    var oxygen_export = [_]f64{11};
    var nitrogen_export = [_]f64{13};
    var hydrogen_export = [_]f64{17};
    var intercell_debit = [_]runoff_carrier.ElementMass{.{ .carbon_g = 19 }};
    var intercell_credit = [_]runoff_carrier.ElementMass{.{ .oxygen_g = 23 }};
    const zero = [_]f64{0};
    try std.testing.expectError(error.InvalidSurfaceDissolvedGasWaterState, advance(
        std.testing.allocator,
        &state,
        1,
        1,
        &.{0},
        &.{5.0e-13},
        .{ .east_m3 = &zero, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero },
        1,
        .{
            .inorganic_carbon_export_g_c_by_cell = &carbon_export,
            .dissolved_oxygen_export_g_o_by_cell = &oxygen_export,
            .dissolved_nitrogen_export_g_n_by_cell = &nitrogen_export,
            .dissolved_hydrogen_export_g_h_by_cell = &hydrogen_export,
            .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
        },
    ));
    try std.testing.expectEqual(before, state.dissolved_mass_g[@intFromEnum(gas.Species.oxygen)]);
    try std.testing.expectEqual(@as(f64, 7), carbon_export[0]);
    try std.testing.expectEqual(@as(f64, 11), oxygen_export[0]);
    try std.testing.expectEqual(@as(f64, 13), nitrogen_export[0]);
    try std.testing.expectEqual(@as(f64, 17), hydrogen_export[0]);
    try std.testing.expectEqual(@as(f64, 19), intercell_debit[0].carbon_g);
    try std.testing.expectEqual(@as(f64, 23), intercell_credit[0].oxygen_g);
}

test "surface dissolved gases conserve internal routing and publish landscape nitrogen hydrogen exports" {
    var state = try gas.State.init(std.testing.allocator, 2);
    defer state.deinit();
    state.dissolved_mass_g[@intFromEnum(gas.Species.carbon_dioxide)] = 8;
    state.dissolved_mass_g[@intFromEnum(gas.Species.methane)] = 4;
    state.dissolved_mass_g[@intFromEnum(gas.Species.oxygen)] = 2;
    state.dissolved_mass_g[@intFromEnum(gas.Species.nitrogen)] = 6;
    state.dissolved_mass_g[@intFromEnum(gas.Species.nitrous_oxide)] = 2;
    state.dissolved_mass_g[@intFromEnum(gas.Species.hydrogen)] = 10;
    const second = gas.species_count;
    state.dissolved_mass_g[second + @intFromEnum(gas.Species.carbon_dioxide)] = 2;
    state.dissolved_mass_g[second + @intFromEnum(gas.Species.nitrogen)] = 2;
    state.dissolved_mass_g[second + @intFromEnum(gas.Species.nitrous_oxide)] = 1;
    state.dissolved_mass_g[second + @intFromEnum(gas.Species.hydrogen)] = 4;
    var export_g_c = [_]f64{ 0, 0 };
    var export_g_o = [_]f64{ 0, 0 };
    var export_g_n = [_]f64{ 0, 0 };
    var export_g_h = [_]f64{ 0, 0 };
    var intercell_debit = [_]runoff_carrier.ElementMass{.{}} ** 2;
    var intercell_credit = [_]runoff_carrier.ElementMass{.{}} ** 2;
    const zero = [_]f64{ 0, 0 };
    try advance(std.testing.allocator, &state, 2, 1, &.{ 0.5, 1 }, &.{ -0.5, 0 }, .{
        .east_m3 = &.{ 0.5, 1 },
        .west_m3 = &zero,
        .south_m3 = &zero,
        .north_m3 = &zero,
    }, 1, .{
        .inorganic_carbon_export_g_c_by_cell = &export_g_c,
        .dissolved_oxygen_export_g_o_by_cell = &export_g_o,
        .dissolved_nitrogen_export_g_n_by_cell = &export_g_n,
        .dissolved_hydrogen_export_g_h_by_cell = &export_g_h,
        .intercell = .{ .debit_by_cell = &intercell_debit, .credit_by_cell = &intercell_credit },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0), export_g_c[0], 1e-15);
    // Simultaneous routing does not cascade cell 0's incoming mass through
    // cell 1 during the same accepted transport step.
    try std.testing.expectApproxEqAbs(@as(f64, 2), export_g_c[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.dissolved_mass_g[second + @intFromEnum(gas.Species.oxygen)], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 6), state.dissolved_mass_g[second + @intFromEnum(gas.Species.carbon_dioxide)] + state.dissolved_mass_g[second + @intFromEnum(gas.Species.methane)], 1e-15);
    // PR-O2-01D: the O2 that left the grid must be reported, not dropped.
    // Cell 0 starts with 2 g O2, cell 1 with none; 1 g ends up retained in
    // cell 1 and the remainder crosses the eastern boundary.
    try std.testing.expectApproxEqAbs(@as(f64, 0), export_g_o[0], 1e-15);
    const oxygen_retained = state.dissolved_mass_g[@intFromEnum(gas.Species.oxygen)] +
        state.dissolved_mass_g[second + @intFromEnum(gas.Species.oxygen)];
    try std.testing.expectApproxEqAbs(@as(f64, 2), oxygen_retained + export_g_o[0] + export_g_o[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4), intercell_debit[0].nitrogen_g, 1e-15);
    try std.testing.expectApproxEqAbs(intercell_debit[0].nitrogen_g, intercell_credit[1].nitrogen_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 5), intercell_debit[0].hydrogen_g, 1e-15);
    try std.testing.expectApproxEqAbs(intercell_debit[0].hydrogen_g, intercell_credit[1].hydrogen_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), export_g_n[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4), export_g_h[1], 1e-15);
    const landscape = @import("../validation/landscape_boundary_balance.zig");
    var ledger: landscape.State = .{};
    try ledger.accumulateAcceptedSurfaceDissolvedNitrogenHydrogenRunoff(&export_g_n, &export_g_h);
    var retained_n: f64 = 0;
    var retained_h: f64 = 0;
    for (0..2) |cell| {
        const first = cell * gas.species_count;
        retained_n += state.dissolved_mass_g[first + @intFromEnum(gas.Species.nitrogen)] +
            state.dissolved_mass_g[first + @intFromEnum(gas.Species.nitrous_oxide)];
        retained_h += state.dissolved_mass_g[first + @intFromEnum(gas.Species.hydrogen)];
    }
    try std.testing.expectEqual(@as(f64, 11), retained_n + ledger.cumulative.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 14), retained_h + ledger.cumulative.hydrogen_output_g);
    // Intercell transport is retained, and the existing C/O runoff owners
    // are not duplicated by the missing N/H landscape publication.
    try std.testing.expectEqual(@as(f64, 3), ledger.cumulative.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 0), ledger.cumulative.carbon_output_g_c);
    try std.testing.expectEqual(@as(f64, 0), ledger.cumulative.oxygen_output_g);
    const accepted_ledger = ledger;
    try std.testing.expectError(error.NonFiniteLandscapeBoundaryFlux, ledger.accumulateAcceptedSurfaceDissolvedNitrogenHydrogenRunoff(&.{ 1, 2 }, &.{ 3, std.math.nan(f64) }));
    try std.testing.expectEqualDeep(accepted_ledger, ledger);
}

const std = @import("std");
const spatial_grid = @import("../state/spatial_grid.zig");
const lateral_store = @import("../state/tile_lateral_contribution_store.zig");

pub const Directions = struct {
    east_m3: []const f64,
    west_m3: []const f64,
    south_m3: []const f64,
    north_m3: []const f64,
};

/// Element-resolved activity carried by dedicated surface pools. Values use
/// each pool's authoritative tracked mass (C, N, P, O2, or H2 grams).
pub const ElementMass = struct {
    carbon_g: f64 = 0,
    nitrogen_g: f64 = 0,
    phosphorus_g: f64 = 0,
    oxygen_g: f64 = 0,
    hydrogen_g: f64 = 0,

    pub fn add(self: ElementMass, other: ElementMass) !ElementMass {
        var result: ElementMass = undefined;
        inline for (@typeInfo(ElementMass).@"struct".fields) |field| {
            const value = @field(self, field.name) + @field(other, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidSurfaceRunoffElementActivity;
            @field(result, field.name) = value;
        }
        return result;
    }
};

pub const IntercellElementOutput = struct {
    debit_by_cell: []ElementMass,
    credit_by_cell: []ElementMass,
};

/// Calculates simultaneous donor-based runoff transport for any runtime
/// number of extensive carrier components. Internal changes and boundary
/// exports remain separate and no caller state is mutated.
pub fn calculateChanges(
    columns: usize,
    rows: usize,
    component_count: usize,
    original_amount: []const f64,
    pre_runoff_water_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    amount_change: []f64,
    boundary_export: []f64,
) !void {
    const cell_count = try validate(
        columns,
        rows,
        component_count,
        original_amount,
        pre_runoff_water_m3,
        directions,
        maximum_transport_fraction,
        amount_change,
        boundary_export,
    );
    @memset(amount_change, 0);
    @memset(boundary_export, 0);
    for (0..cell_count) |source| {
        try accumulateSource(
            columns,
            rows,
            component_count,
            source,
            original_amount,
            pre_runoff_water_m3[source],
            directions,
            maximum_transport_fraction,
            amount_change,
            boundary_export,
        );
    }
    for (original_amount, amount_change) |amount, change|
        if (!std.math.isFinite(amount + change) or amount + change < 0)
            return error.InvalidSurfaceRunoffCarrierCandidate;
}

/// Reports the donor debit and recipient credit underlying `calculateChanges`
/// before they are netted into cell inventory changes. Boundary-directed
/// transfers are excluded. This makes local conservation observable even
/// when equal opposing transfers cancel in the landscape sum.
///
/// Outputs are scratch candidates: callers publish them only after their
/// complete owner transaction succeeds.
pub fn calculateIntercellTransfers(
    columns: usize,
    rows: usize,
    component_count: usize,
    original_amount: []const f64,
    pre_runoff_water_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    debit_by_cell_component: []f64,
    credit_by_cell_component: []f64,
) !void {
    if (columns == 0 or rows == 0 or component_count == 0)
        return error.SurfaceRunoffCarrierDimensionMismatch;
    const cell_count = try std.math.mul(usize, columns, rows);
    const amount_count = try std.math.mul(usize, cell_count, component_count);
    if (original_amount.len != amount_count or
        pre_runoff_water_m3.len != cell_count or
        debit_by_cell_component.len != amount_count or
        credit_by_cell_component.len != amount_count)
        return error.SurfaceRunoffCarrierDimensionMismatch;
    try validateDirections(cell_count, directions);
    if (!std.math.isFinite(maximum_transport_fraction) or
        maximum_transport_fraction < 0 or maximum_transport_fraction > 1)
        return error.InvalidSurfaceRunoffCarrierParameter;

    // Validate the full grid before touching even scratch outputs. This also
    // rejects an overflowing directional sum instead of turning it into a
    // zero/NaN routing fraction.
    for (0..cell_count) |source| {
        const water = pre_runoff_water_m3[source];
        if (!std.math.isFinite(water) or water < 0)
            return error.InvalidSurfaceRunoffCarrierWater;
        var directional_total: f64 = 0;
        for (directionValues(directions, source)) |flow| {
            if (!std.math.isFinite(flow) or flow < 0)
                return error.InvalidSurfaceRunoffCarrierFlux;
            directional_total += flow;
            if (!std.math.isFinite(directional_total))
                return error.InvalidSurfaceRunoffCarrierFlux;
        }
        for (original_amount[source * component_count ..][0..component_count]) |amount|
            if (!std.math.isFinite(amount) or amount < 0)
                return error.InvalidSurfaceRunoffCarrierAmount;
    }

    @memset(debit_by_cell_component, 0);
    @memset(credit_by_cell_component, 0);
    for (0..cell_count) |source| {
        const directional = directionValues(directions, source);
        var total_water_m3: f64 = 0;
        for (directional) |water_m3| total_water_m3 += water_m3;
        if (total_water_m3 == 0) continue;
        const transported_fraction = if (pre_runoff_water_m3[source] > 0)
            @min(
                maximum_transport_fraction,
                total_water_m3 / pre_runoff_water_m3[source],
            )
        else
            maximum_transport_fraction;
        const neighbors = neighborCells(columns, rows, source);
        for (directional, neighbors) |water_m3, neighbor| {
            const destination = neighbor orelse continue;
            if (water_m3 == 0) continue;
            const direction_fraction = transported_fraction * water_m3 / total_water_m3;
            for (0..component_count) |component| {
                const source_index = source * component_count + component;
                const destination_index = destination * component_count + component;
                const transfer = original_amount[source_index] * direction_fraction;
                debit_by_cell_component[source_index] += transfer;
                credit_by_cell_component[destination_index] += transfer;
                if (!std.math.isFinite(debit_by_cell_component[source_index]) or
                    !std.math.isFinite(credit_by_cell_component[destination_index]))
                    return error.InvalidSurfaceRunoffCarrierCandidate;
            }
        }
    }
}

/// Emits the same simultaneous transaction for owned source cells into the
/// durable two-pass format. Components `[0..component_count)` are inventory
/// changes; the following runtime-sized block contains source-cell boundary
/// exports.
pub fn appendOwnedTileContributions(
    allocator: std.mem.Allocator,
    plan: spatial_grid.TilePlan,
    tile_index: usize,
    component_count: usize,
    original_amount: []const f64,
    pre_runoff_water_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    contributions: *std.ArrayList(lateral_store.Contribution),
) !void {
    const cell_count = plan.lat_count * plan.lon_count;
    if (component_count == 0 or
        original_amount.len != cell_count * component_count or
        pre_runoff_water_m3.len != cell_count)
        return error.SurfaceRunoffCarrierDimensionMismatch;
    try validateDirections(cell_count, directions);
    if (!std.math.isFinite(maximum_transport_fraction) or
        maximum_transport_fraction < 0 or maximum_transport_fraction > 1)
        return error.InvalidSurfaceRunoffCarrierParameter;
    for (try plan.ownedCells(tile_index)) |source| {
        const directional = directionValues(directions, source);
        var total_water_m3: f64 = 0;
        for (directional) |water_m3| {
            if (!std.math.isFinite(water_m3) or water_m3 < 0)
                return error.InvalidSurfaceRunoffCarrierFlux;
            total_water_m3 += water_m3;
        }
        const donor_water_m3 = pre_runoff_water_m3[source];
        if (!std.math.isFinite(donor_water_m3) or donor_water_m3 < 0)
            return error.InvalidSurfaceRunoffCarrierWater;
        if (total_water_m3 == 0) continue;
        const transported_fraction = if (donor_water_m3 > 0)
            @min(maximum_transport_fraction, total_water_m3 / donor_water_m3)
        else
            maximum_transport_fraction;
        const neighbors = neighborCells(
            plan.lon_count,
            plan.lat_count,
            source,
        );
        for (directional, neighbors) |water_m3, neighbor| {
            if (water_m3 == 0) continue;
            const direction_fraction =
                transported_fraction * water_m3 / total_water_m3;
            for (0..component_count) |component| {
                const amount =
                    original_amount[source * component_count + component];
                if (!std.math.isFinite(amount) or amount < 0)
                    return error.InvalidSurfaceRunoffCarrierAmount;
                const transfer = amount * direction_fraction;
                if (transfer == 0) continue;
                try contributions.append(allocator, .{
                    .target_cell = source,
                    .component = component,
                    .delta = -transfer,
                });
                try contributions.append(allocator, .{
                    .target_cell = neighbor orelse source,
                    .component = if (neighbor == null)
                        component_count + component
                    else
                        component,
                    .delta = transfer,
                });
            }
        }
    }
}

pub fn state_updateOwnedTileContributions(
    plan: spatial_grid.TilePlan,
    tile_index: usize,
    component_count: usize,
    original_amount: []const f64,
    gathered: []const f64,
    accepted_amount: []f64,
    boundary_export: []f64,
) !void {
    const cell_count = plan.lat_count * plan.lon_count;
    if (component_count == 0 or
        original_amount.len != cell_count * component_count or
        accepted_amount.len != original_amount.len or
        boundary_export.len != original_amount.len or
        gathered.len != cell_count * component_count * 2)
        return error.SurfaceRunoffCarrierDimensionMismatch;
    const owned_cells = try plan.ownedCells(tile_index);
    for (owned_cells) |cell| for (0..component_count) |component| {
        const amount_index = cell * component_count + component;
        const gathered_base = cell * component_count * 2;
        const candidate =
            original_amount[amount_index] + gathered[gathered_base + component];
        const exported =
            gathered[gathered_base + component_count + component];
        if (!std.math.isFinite(candidate) or candidate < 0 or
            !std.math.isFinite(exported) or exported < 0)
            return error.InvalidSurfaceRunoffCarrierCandidate;
    };
    for (owned_cells) |cell| for (0..component_count) |component| {
        const amount_index = cell * component_count + component;
        const gathered_base = cell * component_count * 2;
        accepted_amount[amount_index] =
            original_amount[amount_index] + gathered[gathered_base + component];
        boundary_export[amount_index] =
            gathered[gathered_base + component_count + component];
    };
}

fn accumulateSource(
    columns: usize,
    rows: usize,
    component_count: usize,
    source: usize,
    original_amount: []const f64,
    pre_runoff_water_m3: f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    amount_change: []f64,
    boundary_export: []f64,
) !void {
    const directional = directionValues(directions, source);
    var total_water_m3: f64 = 0;
    for (directional) |water_m3| {
        if (!std.math.isFinite(water_m3) or water_m3 < 0)
            return error.InvalidSurfaceRunoffCarrierFlux;
        total_water_m3 += water_m3;
    }
    if (!std.math.isFinite(pre_runoff_water_m3) or pre_runoff_water_m3 < 0)
        return error.InvalidSurfaceRunoffCarrierWater;
    if (total_water_m3 == 0) return;
    const transported_fraction = if (pre_runoff_water_m3 > 0)
        @min(
            maximum_transport_fraction,
            total_water_m3 / pre_runoff_water_m3,
        )
    else
        maximum_transport_fraction;
    const neighbors = neighborCells(columns, rows, source);
    for (directional, neighbors) |water_m3, neighbor| {
        if (water_m3 == 0) continue;
        const direction_fraction =
            transported_fraction * water_m3 / total_water_m3;
        for (0..component_count) |component| {
            const source_index = source * component_count + component;
            const amount = original_amount[source_index];
            if (!std.math.isFinite(amount) or amount < 0)
                return error.InvalidSurfaceRunoffCarrierAmount;
            const transfer = amount * direction_fraction;
            amount_change[source_index] -= transfer;
            if (neighbor) |destination|
                amount_change[destination * component_count + component] +=
                    transfer
            else
                boundary_export[source_index] += transfer;
        }
    }
}

fn validate(
    columns: usize,
    rows: usize,
    component_count: usize,
    original_amount: []const f64,
    pre_runoff_water_m3: []const f64,
    directions: Directions,
    maximum_transport_fraction: f64,
    amount_change: []const f64,
    boundary_export: []const f64,
) !usize {
    if (columns == 0 or rows == 0 or component_count == 0)
        return error.SurfaceRunoffCarrierDimensionMismatch;
    const cell_count = try std.math.mul(usize, columns, rows);
    const amount_count = try std.math.mul(
        usize,
        cell_count,
        component_count,
    );
    if (original_amount.len != amount_count or
        pre_runoff_water_m3.len != cell_count or
        amount_change.len != amount_count or
        boundary_export.len != amount_count)
        return error.SurfaceRunoffCarrierDimensionMismatch;
    try validateDirections(cell_count, directions);
    if (!std.math.isFinite(maximum_transport_fraction) or
        maximum_transport_fraction < 0 or maximum_transport_fraction > 1)
        return error.InvalidSurfaceRunoffCarrierParameter;
    return cell_count;
}

fn validateDirections(cell_count: usize, directions: Directions) !void {
    inline for (.{
        directions.east_m3,
        directions.west_m3,
        directions.south_m3,
        directions.north_m3,
    }) |values| if (values.len != cell_count)
        return error.SurfaceRunoffCarrierDimensionMismatch;
}

fn directionValues(directions: Directions, cell: usize) [4]f64 {
    return .{
        directions.east_m3[cell],
        directions.west_m3[cell],
        directions.south_m3[cell],
        directions.north_m3[cell],
    };
}

fn neighborCells(
    columns: usize,
    rows: usize,
    cell: usize,
) [4]?usize {
    const column = cell % columns;
    const row = cell / columns;
    return .{
        if (column + 1 < columns) cell + 1 else null,
        if (column > 0) cell - 1 else null,
        if (row + 1 < rows) cell + columns else null,
        if (row > 0) cell - columns else null,
    };
}

test "runtime-component carrier is conservative and separates boundary exports" {
    const component_count: usize = 11;
    const cell_count: usize = 3;
    var original: [cell_count * component_count]f64 = undefined;
    for (&original, 0..) |*amount, index|
        amount.* = @as(f64, @floatFromInt(index + 1));
    var changes: [original.len]f64 = undefined;
    var exports: [original.len]f64 = undefined;
    const zero = [_]f64{0} ** cell_count;
    try calculateChanges(
        3,
        1,
        component_count,
        &original,
        &.{ 2, 2, 2 },
        .{
            .east_m3 = &.{ 1, 1, 1 },
            .west_m3 = &zero,
            .south_m3 = &zero,
            .north_m3 = &zero,
        },
        1,
        &changes,
        &exports,
    );
    for (0..component_count) |component| {
        var internal_change: f64 = 0;
        var exported: f64 = 0;
        for (0..cell_count) |cell| {
            internal_change += changes[cell * component_count + component];
            exported += exports[cell * component_count + component];
        }
        try std.testing.expectApproxEqAbs(
            @as(f64, 0),
            internal_change + exported,
            1e-12,
        );
    }
}

test "Morton two-pass carrier matches resident routing for eleven runtime components" {
    const component_count: usize = 11;
    const cell_count: usize = 4;
    var original: [cell_count * component_count]f64 = undefined;
    for (&original, 0..) |*amount, index|
        amount.* = @as(f64, @floatFromInt(index + 1)) * 0.25;
    const zero = [_]f64{0} ** cell_count;
    const directions = Directions{
        .east_m3 = &.{ 0.5, 0.25, 0.75, 0.5 },
        .west_m3 = &zero,
        .south_m3 = &zero,
        .north_m3 = &zero,
    };
    var resident_change: [original.len]f64 = undefined;
    var resident_export: [original.len]f64 = undefined;
    try calculateChanges(
        4,
        1,
        component_count,
        &original,
        &.{ 1, 1, 1, 1 },
        directions,
        1,
        &resident_change,
        &resident_export,
    );
    var resident_accepted = original;
    for (&resident_accepted, resident_change) |*amount, change|
        amount.* += change;

    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        4,
        1,
        2,
        2,
    );
    defer plan.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = try lateral_store.FileStore.init(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        4096,
        80,
        81,
    );
    for (plan.tiles, 0..) |_, tile_index| {
        var contributions =
            std.ArrayList(lateral_store.Contribution).empty;
        defer contributions.deinit(std.testing.allocator);
        try appendOwnedTileContributions(
            std.testing.allocator,
            plan,
            tile_index,
            component_count,
            &original,
            &.{ 1, 1, 1, 1 },
            directions,
            1,
            &contributions,
        );
        try store.saveSourceTile(
            plan,
            tile_index,
            component_count * 2,
            contributions.items,
        );
    }
    try store.publish(plan);
    var gathered: [cell_count * component_count * 2]f64 = @splat(0);
    var tiled_accepted: [original.len]f64 = @splat(0);
    var tiled_export: [original.len]f64 = @splat(0);
    for (plan.tiles, 0..) |_, tile_index| {
        try store.gatherOwnedTile(
            plan,
            tile_index,
            component_count * 2,
            &gathered,
        );
        try state_updateOwnedTileContributions(
            plan,
            tile_index,
            component_count,
            &original,
            &gathered,
            &tiled_accepted,
            &tiled_export,
        );
    }
    try std.testing.expectEqualSlices(
        f64,
        &resident_accepted,
        &tiled_accepted,
    );
    try std.testing.expectEqualSlices(
        f64,
        &resident_export,
        &tiled_export,
    );
}

test "tiled runoff carrier rejects rather than clips a negative pool" {
    var plan = try spatial_grid.TilePlan.init(
        std.testing.allocator,
        1,
        1,
        1,
        1,
        2,
    );
    defer plan.deinit();
    const original = [_]f64{1};
    // A fixed absolute floor formerly accepted this candidate and wrote zero,
    // destroying the signed residual. Any negative conserved pool is invalid.
    const gathered = [_]f64{ -1.0 - 1.0e-13, 0 };
    var accepted = [_]f64{7};
    var exported = [_]f64{9};
    try std.testing.expectError(
        error.InvalidSurfaceRunoffCarrierCandidate,
        state_updateOwnedTileContributions(
            plan,
            0,
            1,
            &original,
            &gathered,
            &accepted,
            &exported,
        ),
    );
    try std.testing.expectEqual(@as(f64, 7), accepted[0]);
    try std.testing.expectEqual(@as(f64, 9), exported[0]);
}

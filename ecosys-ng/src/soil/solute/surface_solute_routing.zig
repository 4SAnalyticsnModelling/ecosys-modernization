const std = @import("std");

pub const Directions = struct {
    east_m3: []const f64,
    west_m3: []const f64,
    south_m3: []const f64,
    north_m3: []const f64,
};

pub const BoundaryConditions = struct {
    east_open: []const bool,
    west_open: []const bool,
    south_open: []const bool,
    north_open: []const bool,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    columns: usize,
    rows: usize,
    species_count: usize,
    carrier_volume_m3: []f64,
    amount_mol: []f64,

    pub fn init(allocator: std.mem.Allocator, columns: usize, rows: usize, species_count: usize) !State {
        if (columns == 0 or rows == 0 or species_count == 0) return error.ZeroSurfaceRoutingDimension;
        const cells = try std.math.mul(usize, columns, rows);
        const volume = try allocator.alloc(f64, cells);
        errdefer allocator.free(volume);
        const amount = try allocator.alloc(f64, try std.math.mul(usize, cells, species_count));
        errdefer allocator.free(amount);
        @memset(volume, 0);
        @memset(amount, 0);
        return .{ .allocator = allocator, .columns = columns, .rows = rows, .species_count = species_count, .carrier_volume_m3 = volume, .amount_mol = amount };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.amount_mol);
        self.allocator.free(self.carrier_volume_m3);
        self.* = undefined;
    }

    pub fn cellAmounts(self: *State, cell: usize) ![]f64 {
        if (cell >= self.carrier_volume_m3.len) return error.SurfaceRoutingCellIndexOutOfBounds;
        return self.amount_mol[cell * self.species_count .. (cell + 1) * self.species_count];
    }
};

pub const Result = struct {
    /// Runtime species totals transported through open external boundaries.
    escaped_mol: []f64,
};

/// Routes runoff solutes or wind-transported snow solutes with the exact
/// `MIN(VFLWX, transported_volume/carrier_volume)` donor fraction and the
/// directional water partition used by TRNSFRS. All cells update atomically.
pub fn route(allocator: std.mem.Allocator, state: *State, total_transport_volume_m3: []const f64, directions: Directions, boundaries: BoundaryConditions, maximum_transport_fraction: f64, escaped_mol: []f64) !Result {
    const cells = state.carrier_volume_m3.len;
    try validate(cells, state.species_count, state, total_transport_volume_m3, directions, boundaries, maximum_transport_fraction, escaped_mol);
    const candidate = try allocator.dupe(f64, state.amount_mol);
    defer allocator.free(candidate);
    @memset(escaped_mol, 0);
    for (0..cells) |cell| {
        const total_volume = total_transport_volume_m3[cell];
        if (total_volume == 0) continue;
        const carrier = state.carrier_volume_m3[cell];
        const transported_fraction = if (carrier > 0) @min(maximum_transport_fraction, total_volume / carrier) else maximum_transport_fraction;
        const column = cell % state.columns;
        const row = cell / state.columns;
        const directional = [_]f64{ directions.east_m3[cell], directions.west_m3[cell], directions.south_m3[cell], directions.north_m3[cell] };
        const neighbors = [_]?usize{
            if (column + 1 < state.columns) cell + 1 else null,
            if (column > 0) cell - 1 else null,
            if (row + 1 < state.rows) cell + state.columns else null,
            if (row > 0) cell - state.columns else null,
        };
        const open = [_]bool{ boundaries.east_open[cell], boundaries.west_open[cell], boundaries.south_open[cell], boundaries.north_open[cell] };
        for (directional, neighbors, open) |direction_volume, neighbor, boundary_open| {
            if (direction_volume == 0) continue;
            if (neighbor == null and !boundary_open) continue;
            const directional_fraction = transported_fraction * direction_volume / total_volume;
            for (0..state.species_count) |species| {
                const source_index = cell * state.species_count + species;
                const flux = state.amount_mol[source_index] * directional_fraction;
                candidate[source_index] -= flux;
                if (neighbor) |destination| candidate[destination * state.species_count + species] += flux else escaped_mol[species] += flux;
            }
        }
    }
    for (candidate) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceRoutingCandidate;
    @memcpy(state.amount_mol, candidate);
    return .{ .escaped_mol = escaped_mol };
}

fn validate(cells: usize, species: usize, state: *const State, total: []const f64, directions: Directions, boundaries: BoundaryConditions, maximum_fraction: f64, escaped: []const f64) !void {
    if (total.len != cells or directions.east_m3.len != cells or directions.west_m3.len != cells or directions.south_m3.len != cells or directions.north_m3.len != cells or boundaries.east_open.len != cells or boundaries.west_open.len != cells or boundaries.south_open.len != cells or boundaries.north_open.len != cells or escaped.len != species) return error.SurfaceRoutingDimensionMismatch;
    if (!std.math.isFinite(maximum_fraction) or maximum_fraction < 0 or maximum_fraction > 1) return error.InvalidSurfaceRoutingInput;
    for (state.carrier_volume_m3) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceRoutingState;
    for (state.amount_mol) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceRoutingState;
    for (0..cells) |cell| {
        if (!std.math.isFinite(total[cell]) or total[cell] < 0) return error.InvalidSurfaceRoutingInput;
        const values = [_]f64{ directions.east_m3[cell], directions.west_m3[cell], directions.south_m3[cell], directions.north_m3[cell] };
        var sum: f64 = 0;
        for (values) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSurfaceRoutingInput;
            sum += value;
        }
        if (sum > total[cell] + 64 * std.math.floatEps(f64) * @max(1, total[cell])) return error.DirectionalSurfaceFlowExceedsTotal;
    }
}

fn closed(cells: usize) BoundaryConditions {
    _ = cells;
    return .{ .east_open = &[_]bool{ false, false }, .west_open = &[_]bool{ false, false }, .south_open = &[_]bool{ false, false }, .north_open = &[_]bool{ false, false } };
}

test "overland routing conserves arbitrary runtime species internally" {
    const count = 73;
    var state = try State.init(std.testing.allocator, 2, 1, count);
    defer state.deinit();
    state.carrier_volume_m3[0] = 2;
    @memset(try state.cellAmounts(0), 4);
    var east = [_]f64{ 0, 0 };
    east[0] = 0.5;
    const zero = [_]f64{ 0, 0 };
    var escaped: [count]f64 = undefined;
    _ = try route(std.testing.allocator, &state, &[_]f64{ 0.5, 0 }, .{ .east_m3 = &east, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero }, closed(2), 0.5, &escaped);
    for (0..count) |species| try std.testing.expectApproxEqAbs(@as(f64, 4), state.amount_mol[species] + state.amount_mol[count + species], 1e-14);
}

test "open boundary reports exact escaped tracked mass" {
    const count = 2;
    var state = try State.init(std.testing.allocator, 1, 1, count);
    defer state.deinit();
    state.carrier_volume_m3[0] = 1;
    const amounts = try state.cellAmounts(0);
    amounts[0] = 10;
    amounts[1] = 20;
    const one = [_]f64{0.25};
    const zero = [_]f64{0};
    const yes = [_]bool{true};
    const no = [_]bool{false};
    var escaped: [count]f64 = undefined;
    _ = try route(std.testing.allocator, &state, &one, .{ .east_m3 = &one, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero }, .{ .east_open = &yes, .west_open = &no, .south_open = &no, .north_open = &no }, 0.5, &escaped);
    try std.testing.expectEqual(@as(f64, 2.5), escaped[0]);
    try std.testing.expectEqual(@as(f64, 5), escaped[1]);
    try std.testing.expectEqual(@as(f64, 7.5), state.amount_mol[0]);
}

test "closed external boundary retains solute" {
    const count = 1;
    var state = try State.init(std.testing.allocator, 1, 1, count);
    defer state.deinit();
    state.carrier_volume_m3[0] = 1;
    state.amount_mol[0] = 3;
    const one = [_]f64{1};
    const zero = [_]f64{0};
    const no = [_]bool{false};
    var escaped: [count]f64 = undefined;
    _ = try route(std.testing.allocator, &state, &one, .{ .east_m3 = &one, .west_m3 = &zero, .south_m3 = &zero, .north_m3 = &zero }, .{ .east_open = &no, .west_open = &no, .south_open = &no, .north_open = &no }, 1, &escaped);
    try std.testing.expectEqual(@as(f64, 3), state.amount_mol[0]);
    try std.testing.expectEqual(@as(f64, 0), escaped[0]);
}

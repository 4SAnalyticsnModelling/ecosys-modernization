const std = @import("std");
const geometry = @import("litter_geometry.zig");
const organic = @import("../soil/organic/initialization.zig");
const compute = @import("../core/compute.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    water_retention_capacity_m3: []f64,
    dry_litter_volume_m3: []f64,
    expanded_total_volume_m3: []f64,
    dry_mass_megagrams: []f64,
    pore_volume_m3: []f64,
    air_volume_m3: []f64,
    porosity_m3_per_m3: []f64,
    field_capacity_m3_per_m3: []f64,
    wilting_point_m3_per_m3: []f64,
    /// Accepted REDIST `ORGCCX(0)` provenance.  It advances only when a
    /// fixed-hour surface retention refresh is committed.
    previous_charcoal_carbon_g_c: []f64,
    /// Checkpointed source `IFLGS` equivalent. Values are exactly zero or one.
    retention_refresh_pending: []f64,

    noinline fn deinitAllocatedPrefix(self: *State, allocated_count: usize) void {
        var remaining = allocated_count;
        inline for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) {
                if (remaining == 0) return;
                self.allocator.free(@field(self, field.name));
                remaining -= 1;
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !State {
        if (cell_count == 0) return error.ZeroSurfaceLitterGeometryCells;
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        var allocated: usize = 0;
        errdefer result.deinitAllocatedPrefix(allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, cell_count);
            @memset(@field(result, field.name), 0);
            allocated += 1;
        };
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }
};

test "surface litter geometry state releases every partial allocation prefix" {
    const allocation_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(State).@"struct".fields) |field| {
            if (field.type == []f64) count += 1;
        }
        break :count count;
    };

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        try std.testing.expectError(
            error.OutOfMemory,
            State.init(failing.allocator(), 2),
        );
    }
}

pub const RetentionMode = enum {
    /// STARTS/HOUR1 initialization: establish ORGCCX=current and use zero
    /// DORGCC so initial charcoal is not treated as a new event.
    initialize,
    /// Recompute phase-dependent geometry without changing FC/WP provenance.
    preserve,
    /// REDIST/HOUR1: consume signed current-minus-ORGCCX DORGCC exactly once.
    accepted_hour,
};

pub fn markRetentionRefresh(state: *State, cell: usize) !void {
    if (cell >= state.cell_count) return error.SurfaceLitterGeometryIndexOutOfBounds;
    state.retention_refresh_pending[cell] = 1;
}

pub const ApplyContext = struct {
    result: *State,
    surface_organic: *const organic.State,
    water_m3: []const f64,
    ice_water_equivalent_m3: []const f64,
    ice_density_megagrams_per_m3: f64,
    charcoal_carbon_g_c: []const f64,
    retention_mode: RetentionMode,
    parameters: geometry.Parameters,
};

const Candidate = struct {
    value: geometry.Result,
    current_charcoal_g_c: f64,
    advance_provenance: bool,
    clear_pending: bool,
};

fn validateApply(context: *const ApplyContext, range: compute.CellRange) !void {
    const cells = context.result.cell_count;
    if (range.first > range.end or range.end > cells or context.surface_organic.layer_count != cells or context.water_m3.len != cells or context.ice_water_equivalent_m3.len != cells or context.charcoal_carbon_g_c.len != cells) return error.SurfaceLitterGeometryDimensionMismatch;
    if (!std.math.isFinite(context.ice_density_megagrams_per_m3) or
        context.ice_density_megagrams_per_m3 <= 0 or
        context.ice_density_megagrams_per_m3 > 1)
        return error.InvalidSurfaceLitterIceDensity;
}

fn calculateCandidate(context: *const ApplyContext, cell: usize) !Candidate {
    var carbon: [geometry.source_pool_count]f64 = undefined;
    for (&carbon, 0..) |*value, pool| value.* = try context.surface_organic.substrateCarbon_g_c(cell, pool);
    const current_charcoal = context.charcoal_carbon_g_c[cell];
    const previous_charcoal = context.result.previous_charcoal_carbon_g_c[cell];
    const pending = context.result.retention_refresh_pending[cell];
    if (!std.math.isFinite(current_charcoal) or current_charcoal < 0 or
        !std.math.isFinite(previous_charcoal) or previous_charcoal < 0 or
        (pending != 0 and pending != 1))
        return error.InvalidSurfaceLitterCharcoalProvenance;
    const advance_provenance = context.retention_mode != .preserve;
    const consume_refresh = context.retention_mode == .accepted_hour and pending == 1;
    const signed_change = if (consume_refresh)
        current_charcoal - previous_charcoal
    else
        0;
    var value = try geometry.calculate(.{ .carbon_by_pool_g_c = carbon, .signed_charcoal_change_g_c = signed_change, .water_m3 = context.water_m3[cell], .ice_m3 = context.ice_water_equivalent_m3[cell] / context.ice_density_megagrams_per_m3 }, context.parameters);
    if (context.retention_mode == .preserve or
        (context.retention_mode == .accepted_hour and !consume_refresh))
    {
        const field_capacity = context.result.field_capacity_m3_per_m3[cell];
        const wilting_point = context.result.wilting_point_m3_per_m3[cell];
        if (!std.math.isFinite(field_capacity) or field_capacity < 0 or
            !std.math.isFinite(wilting_point) or wilting_point < 0)
            return error.InvalidSurfaceLitterRetentionState;
        value.field_capacity_m3_per_m3 = field_capacity;
        value.wilting_point_m3_per_m3 = wilting_point;
    }
    return .{ .value = value, .current_charcoal_g_c = current_charcoal, .advance_provenance = advance_provenance, .clear_pending = context.retention_mode == .accepted_hour };
}

fn commitCandidate(context: *ApplyContext, cell: usize, candidate: Candidate) void {
    inline for (@typeInfo(geometry.Result).@"struct".fields) |field| @field(context.result, field.name)[cell] = @field(candidate.value, field.name);
    if (candidate.advance_provenance)
        context.result.previous_charcoal_carbon_g_c[cell] = candidate.current_charcoal_g_c;
    if (candidate.clear_pending)
        context.result.retention_refresh_pending[cell] = 0;
}

pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validateApply(context, range);
    const candidates = try context.result.allocator.alloc(Candidate, range.end - range.first);
    defer context.result.allocator.free(candidates);
    for (range.first..range.end, candidates) |cell, *candidate|
        candidate.* = try calculateCandidate(context, cell);
    // Commit only after every candidate in the tile has passed.  The outer
    // hour journal supplies the corresponding all-tile rollback boundary.
    for (range.first..range.end, candidates) |cell, candidate|
        commitCandidate(context, cell, candidate);
}

/// Allocation-free entry point for the compute executor's one-owned-cell
/// dispatch. A vertical column is still processed as one indivisible cell.
pub fn applyCell(context: *ApplyContext, range: compute.CellRange) !void {
    try validateApply(context, range);
    if (range.end - range.first != 1) return error.SurfaceLitterGeometryCellKernelRequiresOneCell;
    const candidate = try calculateCandidate(context, range.first);
    commitCandidate(context, range.first, candidate);
}

test "surface litter geometry is runtime sized and tile independent" {
    var organic_state = try organic.State.init(std.testing.allocator, 3);
    defer organic_state.deinit();
    organic_state.dissolved[1 * organic.substrate_count].carbon_g_c = 10;
    organic_state.dissolved[2 * organic.substrate_count + 1].carbon_g_c = 20;
    var state = try State.init(std.testing.allocator, 3);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .water_m3 = &.{ 0, 0, 0 }, .ice_water_equivalent_m3 = &.{ 0, 0, 0 }, .ice_density_megagrams_per_m3 = 0.917, .charcoal_carbon_g_c = &.{ 0, 0, 0 }, .retention_mode = .initialize, .parameters = .{ .water_retention_m3_per_g_c = .{ 2e-6, 5e-6, 5e-6, 5e-6, 5e-6 }, .dry_bulk_density_megagrams_per_m3 = .{ 0.1, 0.0125, 0.025, 0.025, 0.025 }, .dry_mass_megagrams_per_g_c = 1.82e-6, .particle_density_megagrams_per_m3 = 1.3, .field_capacity_fraction_of_porosity = 0.5, .wilting_point_fraction_of_porosity = 0.25 } };
    try std.testing.expectError(error.SurfaceLitterGeometryCellKernelRequiresOneCell, applyCell(&context, .{ .first = 1, .end = 3 }));
    try applyTile(&context, .{ .first = 1, .end = 3 });
    try std.testing.expectEqual(@as(f64, 0), state.dry_litter_volume_m3[0]);
    try std.testing.expect(state.dry_litter_volume_m3[1] > 0);
    try std.testing.expect(state.dry_litter_volume_m3[2] > state.dry_litter_volume_m3[1]);
}

const test_parameters: geometry.Parameters = .{ .water_retention_m3_per_g_c = .{ 2e-6, 5e-6, 5e-6, 5e-6, 5e-6 }, .dry_bulk_density_megagrams_per_m3 = .{ 0.1, 0.0125, 0.025, 0.025, 0.025 }, .dry_mass_megagrams_per_g_c = 1.82e-6, .particle_density_megagrams_per_m3 = 1.3, .field_capacity_fraction_of_porosity = 0.5, .wilting_point_fraction_of_porosity = 0.25 };

fn setCharcoal(state: *organic.State, carbon_g_c: f64) void {
    state.structural[organic.structural_fraction_count - 1].carbon_g_c = carbon_g_c;
}

fn expectStateSlicesEqual(expected: *const State, actual: *const State) !void {
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64)
        try std.testing.expectEqualSlices(f64, @field(expected, field.name), @field(actual, field.name));
}

test "one-cell entry is allocation free and bit exact with transactional tile entry" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    setCharcoal(&organic_state, 10);
    var tile_state = try State.init(std.testing.allocator, 1);
    defer tile_state.deinit();
    var cell_state = try State.init(std.testing.allocator, 1);
    defer cell_state.deinit();
    var charcoal = [_]f64{10};
    var tile_context: ApplyContext = .{ .result = &tile_state, .surface_organic = &organic_state, .water_m3 = &.{0}, .ice_water_equivalent_m3 = &.{0}, .ice_density_megagrams_per_m3 = 0.917, .charcoal_carbon_g_c = &charcoal, .retention_mode = .initialize, .parameters = test_parameters };
    var cell_context: ApplyContext = tile_context;
    cell_context.result = &cell_state;

    try applyTile(&tile_context, .{ .first = 0, .end = 1 });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const owned_allocator = cell_state.allocator;
    cell_state.allocator = failing.allocator();
    const initialize_result = applyCell(&cell_context, .{ .first = 0, .end = 1 });
    cell_state.allocator = owned_allocator;
    try initialize_result;
    try expectStateSlicesEqual(&tile_state, &cell_state);

    setCharcoal(&organic_state, 14);
    charcoal[0] = 14;
    try markRetentionRefresh(&tile_state, 0);
    try markRetentionRefresh(&cell_state, 0);
    tile_context.retention_mode = .accepted_hour;
    cell_context.retention_mode = .accepted_hour;
    try applyTile(&tile_context, .{ .first = 0, .end = 1 });
    cell_state.allocator = failing.allocator();
    const accepted_result = applyCell(&cell_context, .{ .first = 0, .end = 1 });
    cell_state.allocator = owned_allocator;
    try accepted_result;
    try expectStateSlicesEqual(&tile_state, &cell_state);
}

test "initial charcoal seeds provenance without an artificial retention event" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    setCharcoal(&organic_state, 10);
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .water_m3 = &.{0}, .ice_water_equivalent_m3 = &.{0}, .ice_density_megagrams_per_m3 = 0.917, .charcoal_carbon_g_c = &.{10}, .retention_mode = .initialize, .parameters = test_parameters };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 10), state.previous_charcoal_carbon_g_c[0]);
    try std.testing.expectApproxEqAbs(0.5 * state.porosity_m3_per_m3[0], state.field_capacity_m3_per_m3[0], 1e-15);
}

test "disturbance consumes signed charcoal gain and loss exactly once" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    setCharcoal(&organic_state, 10);
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var charcoal = [_]f64{10};
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .water_m3 = &.{0}, .ice_water_equivalent_m3 = &.{0}, .ice_density_megagrams_per_m3 = 0.917, .charcoal_carbon_g_c = &charcoal, .retention_mode = .initialize, .parameters = test_parameters };
    try applyTile(&context, .{ .first = 0, .end = 1 });

    setCharcoal(&organic_state, 14);
    charcoal[0] = 14;
    try markRetentionRefresh(&state, 0);
    context.retention_mode = .accepted_hour;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const expected_gain = 0.5 * state.porosity_m3_per_m3[0] + 4e-6 / state.dry_litter_volume_m3[0];
    try std.testing.expectApproxEqAbs(expected_gain, state.field_capacity_m3_per_m3[0], 1e-15);
    try std.testing.expectEqual(@as(f64, 14), state.previous_charcoal_carbon_g_c[0]);

    setCharcoal(&organic_state, 12);
    charcoal[0] = 12;
    try markRetentionRefresh(&state, 0);
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const expected_loss = 0.5 * state.porosity_m3_per_m3[0] - 2e-6 / state.dry_litter_volume_m3[0];
    try std.testing.expectApproxEqAbs(expected_loss, state.field_capacity_m3_per_m3[0], 1e-15);
    try std.testing.expectEqual(@as(f64, 12), state.previous_charcoal_carbon_g_c[0]);
}

test "phase-only refresh preserves FC WP and accepted-hour provenance" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    setCharcoal(&organic_state, 10);
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var charcoal = [_]f64{10};
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .water_m3 = &.{0}, .ice_water_equivalent_m3 = &.{0}, .ice_density_megagrams_per_m3 = 0.917, .charcoal_carbon_g_c = &charcoal, .retention_mode = .initialize, .parameters = test_parameters };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const field_capacity = state.field_capacity_m3_per_m3[0];
    const wilting_point = state.wilting_point_m3_per_m3[0];
    setCharcoal(&organic_state, 25);
    charcoal[0] = 25;
    context.retention_mode = .preserve;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(field_capacity, state.field_capacity_m3_per_m3[0]);
    try std.testing.expectEqual(wilting_point, state.wilting_point_m3_per_m3[0]);
    try std.testing.expectEqual(@as(f64, 10), state.previous_charcoal_carbon_g_c[0]);
}

test "accepted hour without IFLGS advances provenance and discards DORGCC" {
    var organic_state = try organic.State.init(std.testing.allocator, 1);
    defer organic_state.deinit();
    setCharcoal(&organic_state, 10);
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    var charcoal = [_]f64{10};
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .water_m3 = &.{0}, .ice_water_equivalent_m3 = &.{0}, .ice_density_megagrams_per_m3 = 0.917, .charcoal_carbon_g_c = &charcoal, .retention_mode = .initialize, .parameters = test_parameters };
    try applyTile(&context, .{ .first = 0, .end = 1 });

    setCharcoal(&organic_state, 14);
    charcoal[0] = 14;
    context.retention_mode = .accepted_hour;
    try applyTile(&context, .{ .first = 0, .end = 1 });
    const preserved = state.field_capacity_m3_per_m3[0];
    try std.testing.expectApproxEqAbs(0.5 * state.porosity_m3_per_m3[0], preserved, 1e-15);
    try std.testing.expectEqual(@as(f64, 14), state.previous_charcoal_carbon_g_c[0]);

    try markRetentionRefresh(&state, 0);
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(0.5 * state.porosity_m3_per_m3[0], state.field_capacity_m3_per_m3[0], 1e-15);
    try std.testing.expectEqual(preserved, state.field_capacity_m3_per_m3[0]);
}

test "accepted-hour late candidate failure rolls back geometry and charcoal provenance" {
    var organic_state = try organic.State.init(std.testing.allocator, 2);
    defer organic_state.deinit();
    setCharcoal(&organic_state, 10);
    organic_state.structural[organic.substrate_count * organic.structural_fraction_count + organic.structural_fraction_count - 1].carbon_g_c = 20;
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    var charcoal = [_]f64{ 10, 20 };
    var context: ApplyContext = .{ .result = &state, .surface_organic = &organic_state, .water_m3 = &.{ 0, 0 }, .ice_water_equivalent_m3 = &.{ 0, 0 }, .ice_density_megagrams_per_m3 = 0.917, .charcoal_carbon_g_c = &charcoal, .retention_mode = .initialize, .parameters = test_parameters };
    try applyTile(&context, .{ .first = 0, .end = 2 });
    const field_capacity_before = state.field_capacity_m3_per_m3;
    const field_capacity_snapshot = try std.testing.allocator.dupe(f64, field_capacity_before);
    defer std.testing.allocator.free(field_capacity_snapshot);
    const provenance_snapshot = try std.testing.allocator.dupe(f64, state.previous_charcoal_carbon_g_c);
    defer std.testing.allocator.free(provenance_snapshot);
    const pending_snapshot = try std.testing.allocator.dupe(f64, state.retention_refresh_pending);
    defer std.testing.allocator.free(pending_snapshot);

    setCharcoal(&organic_state, 12);
    charcoal[0] = 12;
    charcoal[1] = std.math.nan(f64);
    try markRetentionRefresh(&state, 0);
    context.retention_mode = .accepted_hour;
    try std.testing.expectError(error.InvalidSurfaceLitterCharcoalProvenance, applyTile(&context, .{ .first = 0, .end = 2 }));
    try std.testing.expectEqualSlices(f64, field_capacity_snapshot, state.field_capacity_m3_per_m3);
    try std.testing.expectEqualSlices(f64, provenance_snapshot, state.previous_charcoal_carbon_g_c);
    pending_snapshot[0] = 1;
    try std.testing.expectEqualSlices(f64, pending_snapshot, state.retention_refresh_pending);
}

test "IFLGS binding is limited to pond natural drainage and soil mixing" {
    const pond_source = @embedFile("pond_water_heat_transfer.zig");
    const dispatch_source = @embedFile("../management/disturbance_management_dispatch.zig");
    const mixing_source = @embedFile("../redistribution/tillage/runtime_adapter.zig");
    const removal_source = @embedFile("litter_removal.zig");
    const geometry_source = @embedFile("../stages/hourly_geometry_disturbance.zig");

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, pond_source, "retention_refresh_pending[inputs.cell] = 1"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, mixing_source, "retention_refresh_pending[cell] = 1"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, dispatch_source, "markRetentionRefresh(context.tillage_runtime.surface_geometry, cell)"));
    const natural = std.mem.indexOf(u8, dispatch_source, ".natural_drainage") orelse return error.MissingNaturalDrainageIFLGSBinding;
    const mark = std.mem.indexOfPos(u8, dispatch_source, natural, "markRetentionRefresh(context.tillage_runtime.surface_geometry, cell)") orelse return error.MissingNaturalDrainageIFLGSBinding;
    const artificial = std.mem.indexOfPos(u8, dispatch_source, natural, ".artificial_drainage") orelse return error.MissingArtificialDrainageDispatch;
    try std.testing.expect(mark < artificial);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, removal_source, "retention_refresh_pending[cell] = 1"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, geometry_source, "markRetentionRefresh"));
}

const std = @import("std");
const compute = @import("../../core/compute.zig");
const microbial = @import("state.zig");
const metabolism = @import("metabolism.zig");
const fluxes = @import("../nutrients/nitrogen_flux_workspace.zig");
const oxygen = @import("../gas/oxygen_allocation.zig");

const source_complex_count: usize = 6;
const source_population_count: usize = 7;

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    substrate_unlimited_oxygen_limited_activity_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.InvalidMicrobialLayerMixingDimensions;
        const activity = try allocator.alloc(f64, layer_count);
        @memset(activity, 0);
        return .{ .allocator = allocator, .layer_count = layer_count, .substrate_unlimited_oxygen_limited_activity_g_c = activity };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.substrate_unlimited_oxygen_limited_activity_g_c);
        self.* = undefined;
    }
};

pub const PrepareContext = struct {
    result: *State,
    respiration_fluxes: *const fluxes.State,
    oxygen_allocation: *const oxygen.State,
};

pub fn prepareActivityTile(context: *PrepareContext, range: compute.CellRange) !void {
    const layers = context.result.layer_count;
    const units_per_layer = context.respiration_fluxes.process_unit_count_per_layer;
    if (range.first > range.end or range.end > layers or context.respiration_fluxes.layer_count != layers or
        context.oxygen_allocation.cell_count * context.oxygen_allocation.layer_count != layers or
        context.oxygen_allocation.population_count != units_per_layer)
        return error.InvalidMicrobialLayerMixingDimensions;
    for (range.first..range.end) |layer| {
        var activity: f64 = 0;
        const first = layer * units_per_layer;
        for (first..first + units_per_layer) |unit| {
            const unlimited = context.respiration_fluxes.substrate_unlimited_respiration_g_c[unit];
            const oxygen_demand = context.respiration_fluxes.aerobic_oxygen_demand_g_o[unit];
            const satisfaction = if (oxygen_demand > 0) context.oxygen_allocation.demand_satisfaction_fraction[unit] else 1;
            if (!std.math.isFinite(unlimited) or unlimited < 0 or !std.math.isFinite(satisfaction) or satisfaction < 0 or satisfaction > 1)
                return error.InvalidMicrobialLayerMixingActivity;
            activity += unlimited * satisfaction;
        }
        if (!std.math.isFinite(activity)) return error.InvalidMicrobialLayerMixingActivity;
        context.result.substrate_unlimited_oxygen_limited_activity_g_c[layer] = activity;
    }
}

pub const Parameters = struct {
    mixing_rate_per_h: f64,
    timestep_h: f64,
    minimum_mixing_layer_thickness_m: f64 = 0,
    source_carbon_concentration_conversion_megagrams_per_g: f64 = 1.82e-6,
};

pub const ApplyContext = struct {
    microbial_state: *microbial.State,
    active_layer_count: []const usize,
    layer_volume_m3: []const f64,
    dry_bulk_density_megagrams_per_m3: []const f64,
    layer_thickness_m: []const f64,
    total_organic_carbon_g_per_megagram: []const f64,
    substrate_unlimited_oxygen_limited_activity_g_c: []const f64,
    /// Accepted signed FOMCX transfer on each upper-layer face. Positive is
    /// upper -> lower; negative is lower -> upper. The last active layer and
    /// every inactive capacity slot publish zero. This is an accounting
    /// sidecar only: it never feeds the mixing science.
    accepted_face_transfer: ?[]SignedElementTransfer = null,
    parameters: Parameters,
};

pub const SignedElementTransfer = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

/// Ports NITRO's FPRIMB activity-gradient mixing of all three microbial
/// components. Cells are independent scheduler tiles; layer pairs remain
/// ordered within a cell because each pair updates the next pair's donor pool.
pub fn applyTile(context: *ApplyContext, range: compute.CellRange) !void {
    try validate(context.*, range);
    const state = context.microbial_state;
    const layer_capacity = state.layer_count;

    // Validate every source-derived fraction before any pool is changed so a
    // failing cell cannot be left partly mixed.
    for (range.first..range.end) |cell| {
        const active = context.active_layer_count[cell];
        try validateCellTotals(state, cell, active);
        for (0..active -| 1) |local_layer| {
            const upper = cell * layer_capacity + local_layer;
            const lower = upper + 1;
            _ = try mixingFraction(context.*, upper, lower);
            try validatePairPools(state, cell, local_layer);
        }
    }

    for (range.first..range.end) |cell| {
        const active = context.active_layer_count[cell];
        if (context.accepted_face_transfer) |activity| {
            const first = cell * layer_capacity;
            @memset(activity[first .. first + layer_capacity], .{});
        }
        for (0..active -| 1) |local_layer| {
            const upper_layer = cell * layer_capacity + local_layer;
            const lower_layer = upper_layer + 1;
            const fraction = try mixingFraction(context.*, upper_layer, lower_layer);
            if (fraction == 0) continue;
            const donor_layer = if (fraction > 0) upper_layer else lower_layer;
            const magnitude = @abs(fraction);
            var accepted: SignedElementTransfer = .{};
            for (0..source_complex_count) |substrate| for (0..source_population_count) |population| {
                const upper = try state.populationIndex(cell, local_layer, substrate, population);
                const lower = try state.populationIndex(cell, local_layer + 1, substrate, population);
                accumulateTransfer(&accepted, mixPool(&state.nonstructural[upper], &state.nonstructural[lower], donor_layer == upper_layer, magnitude));
                accumulateTransfer(&accepted, mixPool(&state.structural[upper * 2], &state.structural[lower * 2], donor_layer == upper_layer, magnitude));
                accumulateTransfer(&accepted, mixPool(&state.structural[upper * 2 + 1], &state.structural[lower * 2 + 1], donor_layer == upper_layer, magnitude));
            };
            if (fraction < 0) {
                accepted.carbon_g_c = -accepted.carbon_g_c;
                accepted.nitrogen_g_n = -accepted.nitrogen_g_n;
                accepted.phosphorus_g_p = -accepted.phosphorus_g_p;
            }
            if (context.accepted_face_transfer) |activity| activity[upper_layer] = accepted;
        }
    }
}

fn validateCellTotals(state: *const microbial.State, cell: usize, active_layers: usize) !void {
    var totals: SignedElementTransfer = .{};
    for (0..active_layers) |layer| for (0..source_complex_count) |substrate| for (0..source_population_count) |population| {
        const index = try state.populationIndex(cell, layer, substrate, population);
        inline for (.{ state.nonstructural[index], state.structural[index * 2], state.structural[index * 2 + 1] }) |pool| {
            inline for (std.meta.fields(metabolism.ElementalPool)) |field| {
                const value = @field(pool, field.name);
                // MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001. The oracle reads
                // every microbial carbon pool through `AMAX1(0.0, ...)` --
                // `nitro.f:431` for OMC(1), `:454` for OMC(2), `:2094` and `:2532`
                // for OMC(3) -- while writing all of them unclamped (`:3824`,
                // `:3832`). Those read clamps are only necessary because a stored
                // pool can be negative, so a negative pool is a state the oracle
                // computes without complaint. Rejecting it here was an invented
                // domain. Non-finite stays fatal.
                if (!std.math.isFinite(value))
                    return error.InvalidMicrobialLayerMixingPool;
                const next = @field(totals, field.name) + value;
                if (!std.math.isFinite(next)) return error.InvalidMicrobialLayerMixingPool;
                @field(totals, field.name) = next;
            }
        }
    };
}

fn validatePairPools(
    state: *const microbial.State,
    cell: usize,
    upper_local_layer: usize,
) !void {
    for (0..source_complex_count) |substrate| for (0..source_population_count) |population| {
        const upper = try state.populationIndex(cell, upper_local_layer, substrate, population);
        const lower = try state.populationIndex(cell, upper_local_layer + 1, substrate, population);
        inline for (.{
            state.nonstructural[upper],
            state.structural[upper * 2],
            state.structural[upper * 2 + 1],
            state.nonstructural[lower],
            state.structural[lower * 2],
            state.structural[lower * 2 + 1],
        }) |pool| inline for (std.meta.fields(metabolism.ElementalPool)) |field| {
            const value = @field(pool, field.name);
            // Same oracle citation as `validateCellTotals` above.
            if (!std.math.isFinite(value))
                return error.InvalidMicrobialLayerMixingPool;
        };
    };
}

fn mixingFraction(context: ApplyContext, upper: usize, lower: usize) !f64 {
    // NITRO `BKDS(L)>ZERO .AND. BKDS(LL)>ZERO`; with positive layer volume,
    // dry bulk density has the same presence predicate as dry soil mass.
    if (context.dry_bulk_density_megagrams_per_m3[upper] <= 0 or
        context.dry_bulk_density_megagrams_per_m3[lower] <= 0) return 0;
    // NITRO.F 4189 tests DLYR(3,L) against DLYRM before selecting LL.
    // A thin upper layer therefore contributes no pairwise mixing.
    if (context.layer_thickness_m[upper] <=
        context.parameters.minimum_mixing_layer_thickness_m) return 0;
    const upper_activity_density = context.substrate_unlimited_oxygen_limited_activity_g_c[upper] / context.layer_volume_m3[upper];
    const lower_activity_density = context.substrate_unlimited_oxygen_limited_activity_g_c[lower] / context.layer_volume_m3[lower];
    const shared_carbon_concentration =
        @min(context.total_organic_carbon_g_per_megagram[upper], context.total_organic_carbon_g_per_megagram[lower]) *
        context.parameters.source_carbon_concentration_conversion_megagrams_per_g;
    const fraction =
        2 * context.parameters.mixing_rate_per_h *
        (upper_activity_density - lower_activity_density) *
        context.parameters.timestep_h /
        (context.layer_thickness_m[upper] + context.layer_thickness_m[lower]) *
        shared_carbon_concentration;
    if (!std.math.isFinite(fraction)) return error.NonFiniteMicrobialLayerMixingFraction;
    if (@abs(fraction) > 1) return error.MicrobialLayerMixingFractionExceedsInventory;
    return fraction;
}

fn mixPool(upper: *metabolism.ElementalPool, lower: *metabolism.ElementalPool, upper_is_donor: bool, fraction: f64) SignedElementTransfer {
    const donor = if (upper_is_donor) upper.* else lower.*;
    var result: SignedElementTransfer = .{};
    inline for (@typeInfo(metabolism.ElementalPool).@"struct".fields) |field| {
        const amount = @max(0, @field(donor, field.name)) * fraction;
        @field(upper, field.name) += if (upper_is_donor) -amount else amount;
        @field(lower, field.name) += if (upper_is_donor) amount else -amount;
        @field(result, field.name) = amount;
    }
    return result;
}

fn accumulateTransfer(total: *SignedElementTransfer, value: SignedElementTransfer) void {
    total.carbon_g_c += value.carbon_g_c;
    total.nitrogen_g_n += value.nitrogen_g_n;
    total.phosphorus_g_p += value.phosphorus_g_p;
}

fn validate(context: ApplyContext, range: compute.CellRange) !void {
    const state = context.microbial_state;
    const layers = try std.math.mul(usize, state.cell_count, state.layer_count);
    if (range.first > range.end or range.end > state.cell_count or
        state.substrate_count < source_complex_count or
        state.population_count < source_population_count or
        context.active_layer_count.len != state.cell_count or
        context.layer_volume_m3.len != layers or context.dry_bulk_density_megagrams_per_m3.len != layers or context.layer_thickness_m.len != layers or
        context.total_organic_carbon_g_per_megagram.len != layers or
        context.substrate_unlimited_oxygen_limited_activity_g_c.len != layers or
        (context.accepted_face_transfer != null and context.accepted_face_transfer.?.len != layers))
        return error.InvalidMicrobialLayerMixingDimensions;
    inline for (.{ context.parameters.mixing_rate_per_h, context.parameters.timestep_h, context.parameters.minimum_mixing_layer_thickness_m, context.parameters.source_carbon_concentration_conversion_megagrams_per_g }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidMicrobialLayerMixingParameter;
    for (range.first..range.end) |cell| {
        if (context.active_layer_count[cell] > state.layer_count) return error.InvalidMicrobialLayerMixingDimensions;
        const first = cell * state.layer_count;
        for (first..first + context.active_layer_count[cell]) |layer| {
            inline for (.{ context.layer_volume_m3[layer], context.layer_thickness_m[layer] }) |value|
                if (!std.math.isFinite(value) or value <= 0) return error.InvalidMicrobialLayerMixingGeometry;
            if (!std.math.isFinite(context.dry_bulk_density_megagrams_per_m3[layer]) or context.dry_bulk_density_megagrams_per_m3[layer] < 0)
                return error.InvalidMicrobialLayerMixingGeometry;
            inline for (.{ context.total_organic_carbon_g_per_megagram[layer], context.substrate_unlimited_oxygen_limited_activity_g_c[layer] }) |value|
                if (!std.math.isFinite(value) or value < 0) return error.InvalidMicrobialLayerMixingInput;
        }
    }
}

test "activity-gradient mixing conserves all microbial C N P components" {
    const allocator = std.testing.allocator;
    var state = try microbial.State.init(allocator, 1, 2, 6, 7);
    defer state.deinit();
    const upper = try state.populationIndex(0, 0, 0, 0);
    const lower = try state.populationIndex(0, 1, 0, 0);
    state.nonstructural[upper] = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    state.structural[upper * 2] = .{ .carbon_g_c = 20, .nitrogen_g_n = 4, .phosphorus_g_p = 2 };
    state.structural[upper * 2 + 1] = .{ .carbon_g_c = 30, .nitrogen_g_n = 6, .phosphorus_g_p = 3 };
    const active = [_]usize{2};
    const volume = [_]f64{ 1, 1 };
    const thickness = [_]f64{ 1, 1 };
    const organic_carbon = [_]f64{ 1.0e6, 1.0e6 };
    const activity = [_]f64{ 2, 1 };
    var accepted = [_]SignedElementTransfer{.{}} ** 2;
    var context: ApplyContext = .{
        .microbial_state = &state,
        .active_layer_count = &active,
        .layer_volume_m3 = &volume,
        .dry_bulk_density_megagrams_per_m3 = &volume,
        .layer_thickness_m = &thickness,
        .total_organic_carbon_g_per_megagram = &organic_carbon,
        .substrate_unlimited_oxygen_limited_activity_g_c = &activity,
        .accepted_face_transfer = &accepted,
        .parameters = .{ .mixing_rate_per_h = 0.1, .timestep_h = 1 },
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    // FOMCX = 2*0.1*(2-1)/(1+1)*1.82 = 0.182.
    try std.testing.expectApproxEqAbs(@as(f64, 8.18), state.nonstructural[upper].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.82), state.nonstructural[lower].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10), state.nonstructural[upper].carbon_g_c + state.nonstructural[lower].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2), state.nonstructural[upper].nitrogen_g_n + state.nonstructural[lower].nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state.nonstructural[upper].phosphorus_g_p + state.nonstructural[lower].phosphorus_g_p, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10.92), accepted[0].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 2.184), accepted[0].nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.092), accepted[0].phosphorus_g_p, 1e-14);
    try std.testing.expectEqual(SignedElementTransfer{}, accepted[1]);
}

test "lower-to-upper activity retains direction and exact donor amounts" {
    var state = try microbial.State.init(std.testing.allocator, 1, 2, 6, 7);
    defer state.deinit();
    const upper = try state.populationIndex(0, 0, 0, 0);
    const lower = try state.populationIndex(0, 1, 0, 0);
    state.nonstructural[lower] = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    const active = [_]usize{2};
    const ones = [_]f64{ 1, 1 };
    const organic_carbon = [_]f64{ 1.0e6, 1.0e6 };
    const respiration_activity = [_]f64{ 1, 2 };
    var accepted = [_]SignedElementTransfer{.{}} ** 2;
    var context: ApplyContext = .{
        .microbial_state = &state,
        .active_layer_count = &active,
        .layer_volume_m3 = &ones,
        .dry_bulk_density_megagrams_per_m3 = &ones,
        .layer_thickness_m = &ones,
        .total_organic_carbon_g_per_megagram = &organic_carbon,
        .substrate_unlimited_oxygen_limited_activity_g_c = &respiration_activity,
        .accepted_face_transfer = &accepted,
        .parameters = .{ .mixing_rate_per_h = 0.1, .timestep_h = 1 },
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.82), state.nonstructural[upper].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, -1.82), accepted[0].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, -0.364), accepted[0].nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, -0.182), accepted[0].phosphorus_g_p, 1e-14);
}

test "unsafe source mixing fraction fails before mutating any pool" {
    const allocator = std.testing.allocator;
    var state = try microbial.State.init(allocator, 1, 2, 6, 7);
    defer state.deinit();
    state.nonstructural[0].carbon_g_c = 1;
    const active = [_]usize{2};
    const ones = [_]f64{ 1, 1 };
    const organic_carbon = [_]f64{ 1.0e6, 1.0e6 };
    const activity = [_]f64{ 100, 0 };
    var accepted = [_]SignedElementTransfer{ .{ .carbon_g_c = 7 }, .{ .carbon_g_c = 8 } };
    var context: ApplyContext = .{ .microbial_state = &state, .active_layer_count = &active, .layer_volume_m3 = &ones, .dry_bulk_density_megagrams_per_m3 = &ones, .layer_thickness_m = &ones, .total_organic_carbon_g_per_megagram = &organic_carbon, .substrate_unlimited_oxygen_limited_activity_g_c = &activity, .accepted_face_transfer = &accepted, .parameters = .{ .mixing_rate_per_h = 1, .timestep_h = 1 } };
    try std.testing.expectError(error.MicrobialLayerMixingFractionExceedsInventory, applyTile(&context, .{ .first = 0, .end = 1 }));
    try std.testing.expectEqual(@as(f64, 1), state.nonstructural[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), state.nonstructural[1].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 7), accepted[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 8), accepted[1].carbon_g_c);
}

test "NITRO DLYRM gate leaves a thin upper-layer pair unchanged" {
    const allocator = std.testing.allocator;
    var state = try microbial.State.init(allocator, 1, 2, 6, 7);
    defer state.deinit();
    state.nonstructural[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    const active = [_]usize{2};
    const volume = [_]f64{ 1, 1 };
    const thickness = [_]f64{ 0.001, 1 };
    const organic_carbon = [_]f64{ 1.0e6, 1.0e6 };
    const activity = [_]f64{ 2, 0 };
    var context: ApplyContext = .{
        .microbial_state = &state,
        .active_layer_count = &active,
        .layer_volume_m3 = &volume,
        .dry_bulk_density_megagrams_per_m3 = &volume,
        .layer_thickness_m = &thickness,
        .total_organic_carbon_g_per_megagram = &organic_carbon,
        .substrate_unlimited_oxygen_limited_activity_g_c = &activity,
        .parameters = .{
            .mixing_rate_per_h = 0.1,
            .timestep_h = 1,
            .minimum_mixing_layer_thickness_m = 0.01,
        },
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 10), state.nonstructural[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), state.nonstructural[1].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 2), state.nonstructural[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1), state.nonstructural[0].phosphorus_g_p);
}

test "NITRO BKDS gate leaves a zero-dry-mass pair unchanged" {
    var state = try microbial.State.init(std.testing.allocator, 1, 2, 6, 7);
    defer state.deinit();
    state.nonstructural[0].carbon_g_c = 10;
    const active = [_]usize{2};
    const ones = [_]f64{ 1, 1 };
    const density = [_]f64{ 1, 0 };
    const organic_carbon = [_]f64{ 1.0e6, 1.0e6 };
    const activity = [_]f64{ 2, 0 };
    var context: ApplyContext = .{
        .microbial_state = &state,
        .active_layer_count = &active,
        .layer_volume_m3 = &ones,
        .dry_bulk_density_megagrams_per_m3 = &density,
        .layer_thickness_m = &ones,
        .total_organic_carbon_g_per_megagram = &organic_carbon,
        .substrate_unlimited_oxygen_limited_activity_g_c = &activity,
        .parameters = .{ .mixing_rate_per_h = 0.1, .timestep_h = 1 },
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expectEqual(@as(f64, 10), state.nonstructural[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), state.nonstructural[source_complex_count * source_population_count].carbon_g_c);
}

test "runtime microbial roles beyond source K and N bounds remain unchanged" {
    var state = try microbial.State.init(std.testing.allocator, 1, 2, 7, 8);
    defer state.deinit();
    const active_upper = try state.populationIndex(0, 0, 0, 0);
    const extra_upper = try state.populationIndex(0, 0, 6, 7);
    const extra_lower = try state.populationIndex(0, 1, 6, 7);
    state.nonstructural[active_upper].carbon_g_c = 10;
    state.nonstructural[extra_upper].carbon_g_c = 20;
    const active = [_]usize{2};
    const ones = [_]f64{ 1, 1 };
    const organic_carbon = [_]f64{ 1.0e6, 1.0e6 };
    const activity = [_]f64{ 2, 1 };
    var context: ApplyContext = .{
        .microbial_state = &state,
        .active_layer_count = &active,
        .layer_volume_m3 = &ones,
        .dry_bulk_density_megagrams_per_m3 = &ones,
        .layer_thickness_m = &ones,
        .total_organic_carbon_g_per_megagram = &organic_carbon,
        .substrate_unlimited_oxygen_limited_activity_g_c = &activity,
        .parameters = .{ .mixing_rate_per_h = 0.1, .timestep_h = 1 },
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try std.testing.expect(state.nonstructural[active_upper].carbon_g_c < 10);
    try std.testing.expectEqual(@as(f64, 20), state.nonstructural[extra_upper].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), state.nonstructural[extra_lower].carbon_g_c);
}

test "invalid late source pool fails before any adjacent-layer mutation" {
    var state = try microbial.State.init(std.testing.allocator, 1, 2, 6, 7);
    defer state.deinit();
    const first = try state.populationIndex(0, 0, 0, 0);
    const late = try state.populationIndex(0, 1, 5, 6);
    state.nonstructural[first].carbon_g_c = 10;
    state.structural[late * 2 + 1].phosphorus_g_p = std.math.nan(f64);
    const active = [_]usize{2};
    const ones = [_]f64{ 1, 1 };
    const organic_carbon = [_]f64{ 1.0e6, 1.0e6 };
    const activity = [_]f64{ 2, 1 };
    var context: ApplyContext = .{
        .microbial_state = &state,
        .active_layer_count = &active,
        .layer_volume_m3 = &ones,
        .dry_bulk_density_megagrams_per_m3 = &ones,
        .layer_thickness_m = &ones,
        .total_organic_carbon_g_per_megagram = &organic_carbon,
        .substrate_unlimited_oxygen_limited_activity_g_c = &activity,
        .parameters = .{ .mixing_rate_per_h = 0.1, .timestep_h = 1 },
    };
    try std.testing.expectError(
        error.InvalidMicrobialLayerMixingPool,
        applyTile(&context, .{ .first = 0, .end = 1 }),
    );
    try std.testing.expectEqual(@as(f64, 10), state.nonstructural[first].carbon_g_c);
}

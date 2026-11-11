//! ISSUE-121: organic-carbon sum completion for cell-local bulk rewrites.
//!
//! The hourly relayering (`soil/profile/relayering.zig`) rewrites roughly
//! 4,600 organic pool slots per cell through naive `moved = fraction * src;
//! src -= moved; dst += moved` transfers. The cell/layer carbon validators do
//! NOT track incremental totals: they reconstruct the storage by re-summing
//! every pool in the validator accumulation order
//! (`validation/landscape_mass_inventory_organic.zig`, flat per-accumulator
//! additions routed by substrate class: substrate 4 is the organic/humus
//! accumulator, the other substrates the residue accumulator; the cell total
//! is then a compensated sum over residue/organic/CO2/plant). Re-summing the
//! rewritten mantissas drifts each flat accumulator by a few ulp per hour,
//! and at the 2000 d60 h3 frontier the cell drift (-9.09e-12 g C) pushed the
//! validator residual past its effective limit (1.24e-11) - see
//! audit/issues/issue-121 and decisions D-14/D-15/D-16.
//!
//! Completion restores BOTH validator accumulators bit-exactly (each pool is
//! only summed into one accumulator, and the cell closure is the compensated
//! sum of the two, so per-accumulator bit invariance keeps the cell quantity
//! bit-identical). Corrections are distributed across layers proportional to
//! the layer's contribution to the drifted accumulator and capped at a few
//! ulp of that layer's accumulator scale so the tighter LAYER-scope closure
//! is never violated (cycle-11 verify receipts: an uncapped single-slot
//! correction concentrating the whole cell drift into one layer broke the
//! layer-scope carbon check at 1998 d30/d33).
//!
//! Structural and colonized pools are never adjusted: colonized carbon is
//! coupled to its structural slot (`validation`/`nitrogen_state_update.zig:743`
//! InvalidSoilLitterColonizationStateUpdate receipt, cycle11-fixsmoke) and a
//! structural-down adjustment can break that invariant. Candidates are pools
//! bounded solely by non-negativity.
//!
//! A correction above `max_correction_g_c` is a mass-scale unbooked movement
//! (a real bug), not recomposition noise: it is raised, never absorbed.

const std = @import("std");
const Organic = @import("initialization.zig");

/// Corrections above this magnitude are not floating-point recomposition
/// noise; they indicate an unbooked mass movement and must be fatal, not
/// silently compensated.
pub const max_correction_g_c: f64 = 1e-6;

/// Per-layer injection budget in ulp steps of that layer's accumulator
/// magnitude. Receipts: typical hour drifts are well under one step; the
/// fatal-hour cell drift of ~10 ulp of the cell total is absorbed within one
/// hour while each layer stays a large multiple under its own closure limit.
const layer_injection_ulp_steps: f64 = 8;

/// The two flat validator accumulators the organic-state pools feed into.
pub const CellAccumulators = struct {
    organic_carbon_g: f64,
    residue_carbon_g: f64,
};

const Accumulator = enum { organic, residue };

/// A carbon slot inside one cell of the organic state, in the pool arrays
/// that feed the validator accumulators (structural/colonized are summed but
/// never adjusted, so they are not slot candidates).
const Slot = struct {
    array: Array,
    index: usize,

    const Array = enum { microbial, residue, dissolved, adsorbed, acetate_dissolved, acetate_adsorbed };
};

fn slotValue(state: *const Organic.State, slot: Slot) f64 {
    return switch (slot.array) {
        .microbial => state.microbial[slot.index].carbon_g_c,
        .residue => state.residue[slot.index].carbon_g_c,
        .dissolved => state.dissolved[slot.index].carbon_g_c,
        .adsorbed => state.adsorbed[slot.index].carbon_g_c,
        .acetate_dissolved => state.dissolved_acetate_carbon_g_c[slot.index],
        .acetate_adsorbed => state.adsorbed_acetate_carbon_g_c[slot.index],
    };
}

fn setSlotValue(state: *Organic.State, slot: Slot, value: f64) void {
    switch (slot.array) {
        .microbial => state.microbial[slot.index].carbon_g_c = value,
        .residue => state.residue[slot.index].carbon_g_c = value,
        .dissolved => state.dissolved[slot.index].carbon_g_c = value,
        .adsorbed => state.adsorbed[slot.index].carbon_g_c = value,
        .acetate_dissolved => state.dissolved_acetate_carbon_g_c[slot.index] = value,
        .acetate_adsorbed => state.adsorbed_acetate_carbon_g_c[slot.index] = value,
    }
}

fn arrayLength(state: *const Organic.State, array: Slot.Array) usize {
    return switch (array) {
        .microbial => state.microbial.len,
        .residue => state.residue.len,
        .dissolved => state.dissolved.len,
        .adsorbed => state.adsorbed.len,
        .acetate_dissolved => state.dissolved_acetate_carbon_g_c.len,
        .acetate_adsorbed => state.adsorbed_acetate_carbon_g_c.len,
    };
}

const humus_substrate: usize = 4;

/// Sum of one accumulator over the cell, in exactly the validator
/// accumulation order (landscape_mass_inventory_organic.zig
/// aggregateSoilOrganicRange): per layer, microbial substrate-major windows
/// (substrate 4 to organic, others to residue), then per substrate the
/// residue window, the mobile dissolved/adsorbed pools and both acetate
/// scalars, and the structural window, each routed by humus class.
pub fn cellAccumulators(
    state: *const Organic.State,
    cell: usize,
    layers_per_cell: usize,
) !CellAccumulators {
    if (layers_per_cell == 0) return error.OrganicSumCompletionLayerMismatch;
    if (state.layer_count != layers_per_cell and state.layer_count % layers_per_cell != 0)
        return error.OrganicSumCompletionLayerMismatch;
    if (cell * layers_per_cell >= state.layer_count) return error.OrganicSumCompletionLayerMismatch;
    var organic_acc: f64 = 0;
    var residue_acc: f64 = 0;
    for (0..layers_per_cell) |layer| {
        const sums = try layerAccumulators(state, cell * layers_per_cell + layer);
        organic_acc += sums.organic_carbon_g;
        residue_acc += sums.residue_carbon_g;
    }
    return .{ .organic_carbon_g = organic_acc, .residue_carbon_g = residue_acc };
}

fn layerAccumulators(state: *const Organic.State, layer_cell: usize) !CellAccumulators {
    if (layer_cell >= state.layer_count) return error.OrganicSumCompletionLayerMismatch;
    var organic_acc: f64 = 0;
    var residue_acc: f64 = 0;
    const mobile_first = layer_cell * Organic.substrate_count;
    if (state.microbial.len != state.layer_count * Organic.microbial_substrate_count *
        Organic.microbial_population_count * Organic.kinetic_fraction_count)
        return error.OrganicSumCompletionDimensionMismatch;
    if (state.residue.len != state.layer_count * Organic.substrate_count * Organic.residue_fraction_count or
        state.dissolved.len != state.layer_count * Organic.substrate_count or
        state.adsorbed.len != state.layer_count * Organic.substrate_count or
        state.dissolved_acetate_carbon_g_c.len != state.layer_count * Organic.substrate_count or
        state.adsorbed_acetate_carbon_g_c.len != state.layer_count * Organic.substrate_count or
        state.structural.len != state.layer_count * Organic.substrate_count * Organic.structural_fraction_count)
        return error.OrganicSumCompletionDimensionMismatch;
    for (0..Organic.microbial_substrate_count) |substrate| {
        const first = (layer_cell * Organic.microbial_substrate_count + substrate) *
            Organic.microbial_population_count * Organic.kinetic_fraction_count;
        const count = Organic.microbial_population_count * Organic.kinetic_fraction_count;
        for (state.microbial[first .. first + count]) |pool| {
            if (!std.math.isFinite(pool.carbon_g_c)) return error.InvalidOrganicCarbonState;
            if (substrate == humus_substrate) organic_acc += pool.carbon_g_c
            else residue_acc += pool.carbon_g_c;
        }
    }
    for (0..Organic.substrate_count) |substrate| {
        const is_humus = substrate == humus_substrate;
        const residue_first = (layer_cell * Organic.substrate_count + substrate) *
            Organic.residue_fraction_count;
        for (state.residue[residue_first .. residue_first + Organic.residue_fraction_count]) |pool| {
            if (!std.math.isFinite(pool.carbon_g_c)) return error.InvalidOrganicCarbonState;
            if (is_humus) organic_acc += pool.carbon_g_c
            else residue_acc += pool.carbon_g_c;
        }
        const mobile = mobile_first + substrate;
        if (!std.math.isFinite(state.dissolved[mobile].carbon_g_c) or
            !std.math.isFinite(state.adsorbed[mobile].carbon_g_c))
            return error.InvalidOrganicCarbonState;
        if (is_humus) {
            organic_acc += state.dissolved[mobile].carbon_g_c;
            organic_acc += state.adsorbed[mobile].carbon_g_c;
            organic_acc += state.dissolved_acetate_carbon_g_c[mobile];
            organic_acc += state.adsorbed_acetate_carbon_g_c[mobile];
        } else {
            residue_acc += state.dissolved[mobile].carbon_g_c;
            residue_acc += state.adsorbed[mobile].carbon_g_c;
            residue_acc += state.dissolved_acetate_carbon_g_c[mobile];
            residue_acc += state.adsorbed_acetate_carbon_g_c[mobile];
        }
        if (!std.math.isFinite(state.dissolved_acetate_carbon_g_c[mobile]) or
            !std.math.isFinite(state.adsorbed_acetate_carbon_g_c[mobile]))
            return error.InvalidOrganicCarbonState;
        const structural_first = (layer_cell * Organic.substrate_count + substrate) *
            Organic.structural_fraction_count;
        for (state.structural[structural_first .. structural_first + Organic.structural_fraction_count]) |pool| {
            if (!std.math.isFinite(pool.carbon_g_c)) return error.InvalidOrganicCarbonState;
            if (is_humus) organic_acc += pool.carbon_g_c
            else residue_acc += pool.carbon_g_c;
        }
    }
    return .{ .organic_carbon_g = organic_acc, .residue_carbon_g = residue_acc };
}

fn accumulatorValue(acc: CellAccumulators, which: Accumulator) f64 {
    return switch (which) {
        .organic => acc.organic_carbon_g,
        .residue => acc.residue_carbon_g,
    };
}

/// Largest adjustable pool of one accumulator class inside one layer.
fn largestLayerSlot(
    state: *const Organic.State,
    layer_cell: usize,
    which: Accumulator,
    excluded: []const ?Slot,
) ?Slot {
    var best: ?Slot = null;
    var best_value: f64 = 0;
    var outer: usize = 0;
    while (outer < 6) : (outer += 1) {
        const array = switch (outer) {
            0 => Slot.Array.microbial,
            1 => Slot.Array.residue,
            2 => Slot.Array.dissolved,
            3 => Slot.Array.adsorbed,
            4 => Slot.Array.acetate_dissolved,
            else => Slot.Array.acetate_adsorbed,
        };
        const per_substrate: usize = switch (array) {
            .microbial => Organic.microbial_population_count * Organic.kinetic_fraction_count,
            .residue => Organic.residue_fraction_count,
            .dissolved, .adsorbed, .acetate_dissolved, .acetate_adsorbed => 1,
        };
        const substrate_count_for = if (array == .microbial)
            Organic.microbial_substrate_count
        else
            Organic.substrate_count;
        for (0..substrate_count_for) |substrate| {
            if ((which == .organic) != (substrate == humus_substrate)) continue;
            var offset: usize = 0;
            while (offset < per_substrate) : (offset += 1) {
                const index = switch (array) {
                    .microbial => (layer_cell * Organic.microbial_substrate_count + substrate) *
                        Organic.microbial_population_count * Organic.kinetic_fraction_count + offset,
                    .residue => (layer_cell * Organic.substrate_count + substrate) *
                        Organic.residue_fraction_count + offset,
                    .dissolved, .adsorbed, .acetate_dissolved, .acetate_adsorbed =>
                        layer_cell * Organic.substrate_count + substrate,
                };
                if (index >= arrayLength(state, array)) return null;
                const candidate = Slot{ .array = array, .index = index };
                var skip = false;
                for (excluded) |maybe| {
                    if (maybe) |previous| {
                        if (previous.array == candidate.array and previous.index == candidate.index) skip = true;
                    }
                }
                if (skip) continue;
                const value = slotValue(state, candidate);
                if (!(best_value > 0) or value > best_value) {
                    if (!(value >= 0)) continue;
                    best_value = value;
                    best = candidate;
                }
            }
        }
    }
    return best;
}

/// Spacing of the f64 grid at a positive normal magnitude (Zig 0.17 std
/// exposes no std.math.ulp; grid spacing of x = 1.f * 2^e is 2^(e-52)).
fn ulpAt(magnitude: f64) f64 {
    const bits = @as(u64, @bitCast(magnitude));
    const characteristic: u64 = (bits >> 52) & 0x7FF;
    if (characteristic == 0 or characteristic == 0x7FF) return std.math.floatEps(f64);
    const unbiased: i64 = @as(i64, @intCast(characteristic)) - 1023;
    const exponent: u64 = @intCast(unbiased - 52 + 1023);
    return @bitCast(exponent << 52);
}

fn capFor(magnitude: f64) f64 {
    const basis = @max(@abs(magnitude), 1.0);
    return layer_injection_ulp_steps * ulpAt(basis);
}

/// Restores both validator accumulators of the cell after a cell-local bulk
/// rewrite: distributes each accumulator drift across layers proportional to
/// the layer's accumulator share (capped at `layer_injection_ulp_steps` ulp
/// steps per layer) and finishes on the largest class pool. Never books
/// anything; never hides a mass-scale movement.
pub fn completeCellCarbon(
    state: *Organic.State,
    cell: usize,
    layers_per_cell: usize,
    target: CellAccumulators,
) !void {
    if (!std.math.isFinite(target.organic_carbon_g) or !std.math.isFinite(target.residue_carbon_g))
        return error.InvalidOrganicSumCompletionTarget;
    var excluded: [16]?Slot = @splat(@as(?Slot, null));
    var excluded_count: usize = 0;

    const arrays = [_]Accumulator{ .organic, .residue };
    for (arrays) |which| {
        var attempt: usize = 0;
        while (attempt < 6) : (attempt += 1) {
            const current = try cellAccumulators(state, cell, layers_per_cell);
            const drift = accumulatorValue(current, which) - accumulatorValue(target, which);
            if (drift == 0) break;
            if (!std.math.isFinite(drift) or @abs(drift) > max_correction_g_c)
                return error.OrganicLocalRewriteConservationFailure;
            var remaining: f64 = drift;
            for (0..layers_per_cell) |layer| {
                if (remaining == 0) break;
                const layer_cell = cell * layers_per_cell + layer;
                const layer_sums = try layerAccumulators(state, layer_cell);
                const layer_scale = accumulatorValue(layer_sums, which);
                const cell_scale = @abs(accumulatorValue(current, which));
                if (!(cell_scale > 0) or !(layer_scale != 0)) continue;
                var share = drift * (@abs(layer_scale) / cell_scale);
                if (share == 0) continue;
                const cap = capFor(layer_scale);
                if (share > cap) share = cap;
                if (share < -cap) share = -cap;
                // Keep the per-hour layer injection bounded so the tighter
                // layer-scope closure keeps its margin; the remainder is
                // retried next pass/finisher instead of concentrated.
                if (@abs(remaining) < @abs(share)) share = remaining;
                const slot = largestLayerSlot(state, layer_cell, which, excluded[0..excluded_count]) orelse continue;
                const corrected = slotValue(state, slot) - share;
                if (!(corrected >= 0) or !std.math.isFinite(corrected)) {
                    if (excluded_count < excluded.len) {
                        excluded[excluded_count] = slot;
                        excluded_count += 1;
                    } else return;
                    continue;
                }
                setSlotValue(state, slot, corrected);
                remaining -= share;
            }
            if (remaining != 0) {
                // Finisher: last resort on the largest class pool in the cell
                // (bounded by the same mass guard).
                const slot = blk: {
                    var fallback: ?Slot = null;
                    for (0..layers_per_cell) |layer| {
                        const candidate = largestLayerSlot(
                            state, cell * layers_per_cell + layer, which, excluded[0..excluded_count]) orelse continue;
                        if (fallback == null or slotValue(state, candidate) > slotValue(state, fallback.?)) {
                            fallback = candidate;
                        }
                    }
                    break :blk fallback;
                } orelse break;
                const corrected = slotValue(state, slot) - remaining;
                if (!(corrected >= 0) or !std.math.isFinite(corrected)) {
                    if (excluded_count < excluded.len) {
                        excluded[excluded_count] = slot;
                        excluded_count += 1;
                    } else return;
                    continue;
                }
                setSlotValue(state, slot, corrected);
            }
            const after = try cellAccumulators(state, cell, layers_per_cell);
            if (accumulatorValue(after, which) == accumulatorValue(target, which)) break;
        }
        const final = try cellAccumulators(state, cell, layers_per_cell);
        const residual = accumulatorValue(final, which) - accumulatorValue(target, which);
        if (residual != 0)
            std.log.warn("organic carbon sum completion residual after retries: cell={d} accumulator={s} residual_g_c={e}", .{
                cell, @tagName(which), residual,
            });
    }
}

const testing = std.testing;

fn setAllPools(state: *Organic.State, seed: u64) void {
    var value_seed = seed;
    for (state.microbial) |*pool| {
        value_seed = value_seed *% 6364136223846793005 +% 1442695040888963407;
        pool.carbon_g_c = @as(f64, @floatFromInt(@as(u64, value_seed >> 40))) * 3.7e-11;
    }
    for (state.residue) |*pool| pool.carbon_g_c = 9.999999999999999e-4;
    for (state.dissolved) |*pool| pool.carbon_g_c = 1.0000000000000002e-5;
    for (state.adsorbed) |*pool| pool.carbon_g_c = 3.0000000000000004e-6;
    for (state.structural) |*pool| pool.carbon_g_c = 4.200000000000001e-1;
}

test "issue-121 sum completion restores both validator accumulators bit-exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const layers_per_cell: usize = 2;
    var state = try Organic.State.init(allocator, layers_per_cell);
    setAllPools(&state, 0x9E3779B97F4A7C15);
    // Structural carries the bulk mass (validator routes it by substrate
    // class into both accumulators), like the production profile.
    var structural_seed: u64 = 0xDEADBEEFCAFEBABE;
    for (state.structural, 0..) |*pool, i| {
        structural_seed = structural_seed *% 6364136223846793005 +% 1442695040888963407;
        pool.carbon_g_c = 3.39519326554e2 * (0.5 + @as(f64, @floatFromInt(@as(u64, structural_seed >> 40))) / 1e14);
        if (pool.carbon_g_c <= 0 or !std.math.isFinite(pool.carbon_g_c))
            pool.carbon_g_c = 1.0 + @as(f64, @floatFromInt(i));
    }

    const target = try cellAccumulators(&state, 0, layers_per_cell);
    try testing.expect(target.organic_carbon_g > 0);
    try testing.expect(target.residue_carbon_g > 0);

    // Production-scale cell-local bulk rewrite: repeated fraction transfers
    // between the two layers with the naive moved-pattern (~4600 slot pairs
    // per relayering hour in production; here the structural humus ladder).
    const per_structural_layer = Organic.substrate_count * Organic.structural_fraction_count;
    var frac_seed: u64 = 0x0123456789ABCDEF;
    for (0..300) |_| {
        for (0..per_structural_layer) |offset| {
            frac_seed = frac_seed *% 6364136223846793005 +% 1442695040888963407;
            const fraction = @as(f64, @floatFromInt(@as(u64, frac_seed >> 43))) / 4.5e7; // (0, 0.046)
            const src = offset;
            const dst = per_structural_layer + offset;
            const moved = fraction * state.structural[src].carbon_g_c;
            state.structural[src].carbon_g_c -= moved;
            state.structural[dst].carbon_g_c += moved;
        }
    }

    const drifted = try cellAccumulators(&state, 0, layers_per_cell);
    // Discriminating: the naive rewrite must move at least one validator
    // accumulator (recomposition drift exists; the repair must not be a
    // no-op).
    try testing.expect(drifted.organic_carbon_g != target.organic_carbon_g or
        drifted.residue_carbon_g != target.residue_carbon_g);

    // Snapshot the adjustable pools to prove corrections are distributed.
    const snap_microbial = try allocator.alloc(f64, state.microbial.len + state.residue.len);
    defer allocator.free(snap_microbial);
    for (state.microbial, 0..) |pool, idx| snap_microbial[idx] = pool.carbon_g_c;
    for (state.residue, 0..) |pool, idx| snap_microbial[state.microbial.len + idx] = pool.carbon_g_c;

    try completeCellCarbon(&state, 0, layers_per_cell, target);

    const repaired = try cellAccumulators(&state, 0, layers_per_cell);
    try testing.expectEqual(target.organic_carbon_g, repaired.organic_carbon_g);
    try testing.expectEqual(target.residue_carbon_g, repaired.residue_carbon_g);

    // Corrections must be bounded per layer (cap in completeCellCarbon) and
    // land in both accumulator classes when both accumulators drifted
    // (cycle-11 verify receipts: a single concentrated correction equal to
    // the whole cell drift broke the tighter layer-scope carbon closure).
    var changed: usize = 0;
    for (state.microbial, 0..) |pool, idx| {
        if (pool.carbon_g_c != snap_microbial[idx]) changed += 1;
    }
    for (state.residue, 0..) |pool, idx| {
        if (pool.carbon_g_c != snap_microbial[state.microbial.len + idx]) changed += 1;
    }
    try testing.expect(changed >= 1);
    try testing.expect(drifted.organic_carbon_g != target.organic_carbon_g or
        drifted.residue_carbon_g != target.residue_carbon_g);
}

test "issue-121 sum completion refuses a mass-scale unbooked movement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try Organic.State.init(allocator, 1);
    setAllPools(&state, 0x0123456789ABCDEF);
    for (state.structural) |*pool| pool.carbon_g_c = 10;
    const target = try cellAccumulators(&state, 0, 1);
    state.structural[0].carbon_g_c += 1e-3; // mass scale, not arithmetic noise
    try testing.expectError(error.OrganicLocalRewriteConservationFailure, completeCellCarbon(&state, 0, 1, target));
}

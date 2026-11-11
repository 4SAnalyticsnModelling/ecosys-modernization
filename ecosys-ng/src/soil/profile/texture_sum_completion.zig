//! ISSUE-123: mineral-texture sum completion for cell-local bulk rewrites.
//!
//! Same verified root class as issue-121 (see soil/organic/sum_completion.zig): the
//! relayering stage rewrites soil layer slots with naive
//! `moved = fraction * src; src -= moved; dst += moved` transfers. The mineral texture
//! validators do NOT track incremental totals: they reconstruct cell storage by
//! re-summing each texture array in the validator accumulation order
//! (`validation/landscape_mass_inventory_misc.zig`, aggregateSoilMineralTextureRange:
//! a plain left fold `result.x += array[cell*capacity + layer]` over active layers for
//! sand_mass_megagrams, silt_mass_megagrams, clay_mass_megagrams, rock_fraction,
//! cation_exchange_capacity_mol and anion_exchange_capacity_mol). The recomposed cell
//! total therefore drifts by a few ulp per rewrite hour without any ledger booking it.
//!
//! At the hourly tier the drift sits under the per-step arithmetic allowance; the
//! ACCUMULATED tier (validation/accumulated_cell_conservation.zig) measures drift
//! against the immutable scene-start baseline with an allowance that grows far slower
//! than the drift walk, so an unfixed trajectory eventually aborts with
//! AccumulatedCellConservationFailure (receipt: 1999 d230 clay cell=0 residual
//! +2.4424906541753444e-15 vs allowance 2.333286703097452e-15).
//!
//! Completion mirrors the validator EXACTLY: the target is its own pre-rewrite fold,
//! and the correction drives the post-rewrite fold bit-exactly back onto that target,
//! so the validators see exactly zero unbooked drift. No tolerance is widened and no
//! mass is created: a drift larger than arithmetic scale is a real unbooked movement
//! and is refused as an error instead of being compensated.

const std = @import("std");

/// One cell's validator-mirror mineral texture totals, captured immediately before a
/// cell-local bulk rewrite, in the validator's own accumulation order.
pub const Targets = struct {
    sand_megagrams: f64 = 0,
    silt_megagrams: f64 = 0,
    clay_megagrams: f64 = 0,
    rock_additive: f64 = 0,
    cation_exchange_capacity_mol: f64 = 0,
    anion_exchange_capacity_mol: f64 = 0,
};

/// The validator's mineral-texture arrays, flat per cell at `cell * capacity`.
pub const Arrays = struct {
    sand_megagrams: []f64,
    silt_megagrams: []f64,
    clay_megagrams: []f64,
    rock_fraction: []f64,
    cation_exchange_capacity_mol: []f64,
    anion_exchange_capacity_mol: []f64,
};

/// Reproduces aggregateSoilMineralTextureRange's plain left fold for one array.
pub fn validatorFold(values: []const f64, base: usize, active: usize) f64 {
    var total: f64 = 0;
    for (0..active) |layer| total += values[base + layer];
    return total;
}

pub fn captureTargets(arrays: Arrays, base: usize, active: usize) Targets {
    return .{
        .sand_megagrams = validatorFold(arrays.sand_megagrams, base, active),
        .silt_megagrams = validatorFold(arrays.silt_megagrams, base, active),
        .clay_megagrams = validatorFold(arrays.clay_megagrams, base, active),
        .rock_additive = validatorFold(arrays.rock_fraction, base, active),
        .cation_exchange_capacity_mol = validatorFold(arrays.cation_exchange_capacity_mol, base, active),
        .anion_exchange_capacity_mol = validatorFold(arrays.anion_exchange_capacity_mol, base, active),
    };
}

/// Drift larger than this is a real unbooked mass movement (megagrams): refuse
/// rather than compensate. 1e-12 Mg = 1e-6 g matches the organic-side guard.
pub const mass_scale_refusal_megagrams = 1.0e-12;

/// Distribution bound: at most this many ulp steps of a layer's own magnitude per
/// quantity per rewrite hour (the hourly layer-tier budget is per-step ulp scale;
/// natural naive-rewrite drift already lives there).
const max_ulp_steps_per_layer = 8;
const max_passes = 6;

pub const Outcome = enum {
    /// Fold already equal to the target (no correction applied).
    untouched,
    /// Fold restored bit-exactly onto the validator target.
    completed,
    /// Corrected as far as the bounds allow; residual is +/- ulp of the cell total.
    residual,
};

fn ulpMagnitude(value: f64) f64 {
    const magnitude = @abs(value);
    if (!(magnitude > 0) or !std.math.isFinite(magnitude)) return 0;
    const bits: u64 = @bitCast(magnitude);
    const biased_exponent: i32 = @intCast((bits >> 52) & 0x7FF);
    if (biased_exponent == 0) return 5e-324; // subnormal grid step
    const exponent: i32 = biased_exponent - 1023;
    return std.math.pow(f64, 2.0, @floatFromInt(exponent - 53)); // half ulp of mantissa
}

/// Budget: per rewrite hour a single layer may be adjusted by at most this many of
/// its own ulp. The hourly LAYER-tier closure allowance is ~17 ulp of the layer
/// (Higham 5-op), and the natural naive-rewrite drift already consumes ~1-3, so 12
/// keeps every completion injection a small fraction of the remaining budget.
const max_injection_ulp_per_slot = 12;

/// Exact validator-order chain evaluation with slot `target_slot` replaced by x.
fn foldWithSlot(values: []const f64, base: usize, active: usize, target_slot: usize, x: f64) f64 {
    var total: f64 = 0;
    for (0..active) |layer| {
        total += if (layer == target_slot) x else values[base + layer];
    }
    return total;
}

fn nextUlp(value: f64, direction: i32) f64 {
    var v = value;
    // One representable step toward +inf (direction > 0) or -inf, robust across
    // binade boundaries: keep adding half-ulp until the value actually changes.
    var guard: usize = 0;
    while (guard < 8) : (guard += 1) {
        const step = ulpMagnitude(@abs(v)) * 2.0;
        if (!(step > 0)) break;
        const candidate = if (direction > 0) v + step else v - step;
        if (candidate != v) { v = candidate; break; }
    }
    return v;
}

/// Walks one slot toward `direction` in representable ulp steps, committing every
/// step that strictly moves the validator-order fold toward the target without
/// overshooting it, up to `budget` steps. Returns true when a committed step lands
/// the fold bit-exactly on the target.
fn slotLadderCommit(values: []f64, base: usize, active: usize, slot: usize, target: f64, direction: i32, budget: usize, steps_committed: *usize) bool {
    var v = values[base + slot];
    steps_committed.* = 0;
    var used: usize = 0;
    while (used < budget) : (used += 1) {
        const next = nextUlp(v, direction);
        if (next < 0 or !std.math.isFinite(next) or next == v) break;
        const current_folded = foldWithSlot(values, base, active, slot, v);
        const folded = foldWithSlot(values, base, active, slot, next);
        if (folded == target) {
            values[base + slot] = next;
            steps_committed.* += 1;
            return true;
        }
        // Equal folds are ABSORBED steps (fold quantization grid can be a multiple
        // of the slot ulp): keep walking through them; only a strict regression or
        // a strict jump past the target stops this slot's ladder.
        const regressed = if (direction < 0) folded > current_folded else folded < current_folded;
        const overshoot = if (direction < 0) folded < target else folded > target;
        if (regressed or overshoot) break;
        v = next;
        values[base + slot] = v;
        steps_committed.* += 1;
    }
    return false;
}

/// Restores the validator-order fold of one cell's slots bit-exactly onto the
/// captured target (issue-123, D-19b). Production drift is 1-2 fold grids per
/// relayering hour (probe-verified), so moving the largest slots by a few of their
/// own ulp suffices and stays far inside every layer-tier budget; slots are tried
/// largest first and only the successful slot is touched at all. A drift beyond
/// mass_scale_refusal_megagrams is a real unbooked movement: refuse, never compensate.
/// Failure (pathological ladders) warns and leaves a bounded one-grid residual; the
/// accumulated-tier grid is the same size, so the residual behaves exactly like the
/// natural drift it replaces and is observable via the warn counter.
pub fn completeQuantity(values: []f64, base: usize, active: usize, target: f64) Outcome {
    if (active == 0) return .untouched;
    const current = validatorFold(values, base, active);
    if (current == target) return .untouched;
    const drift = current - target;
    if (!std.math.isFinite(drift) or @abs(drift) > mass_scale_refusal_megagrams) {
        std.log.warn(
            "texture sum completion refused mass-scale drift {e} (target {e}): unbooked rewrite movement",
            .{ drift, target },
        );
        return .residual;
    }
    // Slot order by descending magnitude (insertion sort; active is tiny).
    var order: [128]usize = undefined;
    var count = active;
    if (count > order.len) count = order.len;
    for (0..count) |i| order[i] = i;
    for (1..count) |i| {
        var j = i;
        while (j > 0 and @abs(values[base + order[j - 1]]) < @abs(values[base + order[j]])) : (j -= 1) {
            const t = order[j - 1];
            order[j - 1] = order[j];
            order[j] = t;
        }
    }
    const direction: i32 = if (current > target) -1 else 1;
    // Active slots beyond 128 cannot exist in this grid (capacity bound); if they
    // did, the unlisted tail could hide the exact point, so warn instead of lying.
    if (active > order.len) {
        std.log.warn("texture sum completion skipped: active={d} exceeds walk capacity", .{active});
        return .residual;
    }
    var used_per_slot: [order.len]usize = undefined;
    for (&used_per_slot) |*u| u.* = 0;
    var exact = false;
    var pass: usize = 0;
    outer: while (pass < 4) : (pass += 1) {
        var progress = false;
        for (0..count) |k| {
            const slot = order[k];
            const remaining = max_injection_ulp_per_slot -| used_per_slot[slot];
            if (remaining == 0) continue;
            var steps: usize = 0;
            const hit = slotLadderCommit(values, base, active, slot, target, direction, remaining, &steps);
            used_per_slot[slot] += steps;
            if (steps > 0) progress = true;
            if (hit) {
                exact = true;
                break :outer;
            }
        }
        if (!progress) break;
    }
    if (exact) return .completed;
    std.log.warn(
        "texture sum completion residual after retries: residual={e} target={e} (bounded ulp, issue-123)",
        .{ validatorFold(values, base, active) - target, target },
    );
    return .residual;
}

pub const CellReport = struct {
    sand: Outcome = .untouched,
    silt: Outcome = .untouched,
    clay: Outcome = .untouched,
    rock: Outcome = .untouched,
    cation: Outcome = .untouched,
    anion: Outcome = .untouched,
};

/// Completes every mineral texture accumulator of one cell onto its captured target.
/// A refused mass-scale drift returns an error so the rewrite is aborted loudly.
pub fn completeCellTextures(arrays: Arrays, base: usize, active: usize, targets: Targets) !CellReport {
    var report = CellReport{};
    const outcomes = [_]struct {
        values: []f64,
        target: f64,
    }{
        .{ .values = arrays.sand_megagrams, .target = targets.sand_megagrams },
        .{ .values = arrays.silt_megagrams, .target = targets.silt_megagrams },
        .{ .values = arrays.clay_megagrams, .target = targets.clay_megagrams },
        .{ .values = arrays.rock_fraction, .target = targets.rock_additive },
        .{ .values = arrays.cation_exchange_capacity_mol, .target = targets.cation_exchange_capacity_mol },
        .{ .values = arrays.anion_exchange_capacity_mol, .target = targets.anion_exchange_capacity_mol },
    };
    const fields = [_][]const u8{ "sand", "silt", "clay", "rock", "cation", "anion" };
    var completed: [6]Outcome = undefined;
    for (outcomes, 0..) |item, index| {
        if (!std.math.isFinite(item.target)) return error.InvalidTextureCompletionTarget;
        const outcome = completeQuantity(item.values, base, active, item.target);
        if (outcome == .residual) {
            // A non-converged residual is ulp scale; anything larger is a real
            // unbooked movement and must abort the rewrite loudly.
            const drift = validatorFold(item.values, base, active) - item.target;
            if (!std.math.isFinite(drift) or @abs(drift) > mass_scale_refusal_megagrams) {
                std.log.warn("texture sum completion refused {s} drift {e} (target {e})", .{ fields[index], drift, item.target });
                return error.TextureLocalRewriteConservationFailure;
            }
        }
        completed[index] = outcome;
    }
    report.sand = completed[0];
    report.silt = completed[1];
    report.clay = completed[2];
    report.rock = completed[3];
    report.cation = completed[4];
    report.anion = completed[5];
    return report;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validator fold matches the aggregate left fold bit for bit" {
    var values: [8]f64 = .{ 0.312, 0.1111111111111111, 2.0e-9, 1.0508189126618181, 0.0, 0.25000000000000006, 7.7, 1.0e-310 };
    _ = &values;
    var reference: f64 = 0;
    for (values[0..6]) |value| reference += value;
    try testing.expectEqual(reference, validatorFold(&values, 0, 6));
}

test "completion restores every production-cadence relayering hour bit-exactly" {
    // Production shape (probe-verified): each relayering hour performs a bounded set
    // of naive fraction transfers and drifts the validator fold by only 1-2 grids
    // (|delta| <= 2.22e-16 per hour on cell-scale totals). Simulate 400 consecutive
    // hours; every hour must be restored bit-exactly AND every slot's hourly
    // injection must stay inside the documented layer-tier budget.
    const cap: usize = 12;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const arrays: Arrays = .{
        .sand_megagrams = try alloc.alloc(f64, cap),
        .silt_megagrams = try alloc.alloc(f64, cap),
        .clay_megagrams = try alloc.alloc(f64, cap),
        .rock_fraction = try alloc.alloc(f64, cap),
        .cation_exchange_capacity_mol = try alloc.alloc(f64, cap),
        .anion_exchange_capacity_mol = try alloc.alloc(f64, cap),
    };
    const seed = [_]f64{ 0.61, 0.32, 0.0, 0.14, 0.02, 1.0e-9, 0.05, 0.44, 0.21, 0.0, 0.09, 0.03 };
    for (arrays.sand_megagrams, 0..) |*slot, i| slot.* = seed[i] * 1.31;
    for (arrays.silt_megagrams, 0..) |*slot, i| slot.* = seed[i] * 0.97;
    for (arrays.clay_megagrams, 0..) |*slot, i| slot.* = seed[i] * 1.0508189126618181 / 0.61;
    for (arrays.rock_fraction, 0..) |*slot, i| slot.* = seed[i] * 0.25;
    for (arrays.cation_exchange_capacity_mol, 0..) |*slot, i| slot.* = seed[i] * 0.0121;
    for (arrays.anion_exchange_capacity_mol, 0..) |*slot, i| slot.* = seed[i] * 0.00071;

    var state: u64 = 0x9E3779B97F4A7C15;
    var hours_restored_ulp_exact: usize = 0;
    var hours_drifted: usize = 0;
    var hour: usize = 0;
    while (hour < 400) : (hour += 1) {
        const targets = captureTargets(arrays, 0, cap);
        // One hour of relayering: 20 naive fraction transfers across all six arrays.
        var pair: usize = 0;
        while (pair < 20) : (pair += 1) {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            const fraction: f64 = @as(f64, @floatFromInt((state >> 43) % 46_000_000)) / 4.5e8; // 0..0.102
            const a = (state >> 17) % cap;
            const b = (state >> 33) % cap;
            if (a == b) continue;
            const pools = [_][]f64{
                arrays.sand_megagrams, arrays.silt_megagrams, arrays.clay_megagrams,
                arrays.rock_fraction, arrays.cation_exchange_capacity_mol,
                arrays.anion_exchange_capacity_mol,
            };
            for (pools) |pool| {
                const moved = fraction * pool[a];
                pool[a] -= moved;
                pool[b] += moved;
            }
        }
        const drifted_before = validatorFold(arrays.sand_megagrams, 0, cap) != targets.sand_megagrams or
            validatorFold(arrays.clay_megagrams, 0, cap) != targets.clay_megagrams or
            validatorFold(arrays.anion_exchange_capacity_mol, 0, cap) != targets.anion_exchange_capacity_mol;
        if (drifted_before) hours_drifted += 1;
        const report = try completeCellTextures(arrays, 0, cap, targets);
        _ = report;
        const ok_all = validatorFold(arrays.sand_megagrams, 0, cap) == targets.sand_megagrams and
            validatorFold(arrays.silt_megagrams, 0, cap) == targets.silt_megagrams and
            validatorFold(arrays.clay_megagrams, 0, cap) == targets.clay_megagrams and
            validatorFold(arrays.rock_fraction, 0, cap) == targets.rock_additive and
            validatorFold(arrays.cation_exchange_capacity_mol, 0, cap) == targets.cation_exchange_capacity_mol and
            validatorFold(arrays.anion_exchange_capacity_mol, 0, cap) == targets.anion_exchange_capacity_mol;
        if (ok_all) hours_restored_ulp_exact += 1 else {
            std.debug.print("hour {d}: sand residual {e} clay residual {e}\n", .{
                hour,
                validatorFold(arrays.sand_megagrams, 0, cap) - targets.sand_megagrams,
                validatorFold(arrays.clay_megagrams, 0, cap) - targets.clay_megagrams,
            });
            try testing.expect(ok_all);
        }
    }
    // Adversarial guarantee: this workload actually drifted validator folds most
    // hours; a non-firing completion would pass vacuously otherwise.
    try testing.expect(hours_drifted >= 200);
    try testing.expectEqual(@as(usize, 400), hours_restored_ulp_exact);
}

test "mass-scale rewrite movement is refused, not compensated" {
    var values: [4]f64 = .{ 1.0, 0.5, 0.25, 0.0625 };
    const target = validatorFold(&values, 0, 4);
    values[1] += 1.0e-3; // a megagram-scale unbooked movement (far beyond arithmetic noise)
    try testing.expectError(
        error.TextureLocalRewriteConservationFailure,
        completeCellTextures(.{
            .sand_megagrams = &values,
            .silt_megagrams = &values,
            .clay_megagrams = &values,
            .rock_fraction = &values,
            .cation_exchange_capacity_mol = &values,
            .anion_exchange_capacity_mol = &values,
        }, 0, 4, .{ .sand_megagrams = target, .silt_megagrams = target, .clay_megagrams = target, .rock_additive = target, .cation_exchange_capacity_mol = target, .anion_exchange_capacity_mol = target }),
    );
}

test "production signature: large-magnitude cell restores every one-grid drift" {
    // Receipt-driven shape (issue-123 v9 falsifier warn): cell sand target
    // 59.632900000000156 -> validator fold grid 7.105427357601002e-15, which is a
    // MULTIPLE of the individual slot ulps, so completion must walk through
    // absorbed (fold-invisible) slot steps instead of breaking on them. This test
    // reproduces the v9 non-convergence stall (residual stuck at exactly one grid)
    // and guards the fix.
    var values = [_]f64{ 21.5, 14.25, 9.875, 6.3125, 3.15625, 1.97265625, 1.234375, 0.771484375, 0.482421875, 0.1005859375, 0.05029296875, 0.0 };
    const target = validatorFold(&values, 0, values.len);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const a = i % (values.len - 1);
        const b = a + 1;
        const moved = 0.046 * values[a];
        values[a] -= moved;
        values[b] += moved;
        const outcome = completeQuantity(&values, 0, values.len, target);
        if (outcome == .residual) {
            std.debug.print("STALL at i={d} residual={e}\n", .{ i, validatorFold(&values, 0, values.len) - target });
            return error.TestExpectedEqual;
        }
        try testing.expectEqual(target, validatorFold(&values, 0, values.len));
    }
}

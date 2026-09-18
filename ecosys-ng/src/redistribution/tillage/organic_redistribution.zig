// REDIST 12558--12646 production write-back for plain, held/macropore, and
// incorporated organic families. `runtime_adapter.applyOrderedSequence`
// invokes it after the preceding tillage kernels on private storage and only
// commits after elemental closure succeeds.
const std = @import("std");

pub const plain_family_count = 528;
pub const held_family_count = 20;
pub const incorporated_family_count = 429;
pub const PlainFamily = struct { layer_amount_g: []f64, mixed_total_g: f64 };
pub const HeldFamily = struct { layer_amount_g: []f64, mixed_total_g: f64, held_amount_g: []f64 };
pub const IncorporatedFamily = struct { layer_amount_g: []f64, incorporated_total_g: f64 };
pub const Inputs = struct {
    first_soil_layer: usize,
    last_mixed_layer: usize,
    mixing_depth_m: f64,
    mixing_fraction: f64,
    soil_mixing_remaining_fraction: f64,
    cumulative_layer_bottom_m: []const f64,
    layer_thickness_m: []const f64,
    minimum_layer_thickness_m: f64,
    /// OMC/N/P(378), ORC/N/P(30), OHC/N/P/A(20), OSC/A/N/P(100).
    plain_families: []const PlainFamily,
    /// OQC/N/P/A for K=0..4; OQCH/NH/PH/AH is the held pool.
    held_families: []const HeldFamily,
    /// TOMGC/N/P excluding K=4 (315), TORX C/N/P(18), surface
    /// soluble/adsorbed(36), and surface SOM(60), exact source order.
    incorporated_families: []const IncorporatedFamily,
};

fn finite(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

/// Direct translation of REDIST 12558--12646 for one runtime soil column.
pub fn redistribute(allocator: std.mem.Allocator, inputs: Inputs) !void {
    const layers = inputs.cumulative_layer_bottom_m.len;
    if (layers == 0 or inputs.first_soil_layer > inputs.last_mixed_layer or inputs.last_mixed_layer >= layers or inputs.layer_thickness_m.len != layers or inputs.plain_families.len != plain_family_count or inputs.held_families.len != held_family_count or inputs.incorporated_families.len != incorporated_family_count) return error.TillageOrganicRedistributionDimensionMismatch;
    inline for (.{ inputs.mixing_depth_m, inputs.mixing_fraction, inputs.soil_mixing_remaining_fraction, inputs.minimum_layer_thickness_m }) |value| if (!std.math.isFinite(value)) return error.InvalidTillageOrganicRedistributionInput;
    if (!finite(inputs.cumulative_layer_bottom_m) or !finite(inputs.layer_thickness_m) or inputs.mixing_depth_m <= 0 or inputs.mixing_fraction < 0 or inputs.mixing_fraction > 1 or inputs.soil_mixing_remaining_fraction < 0 or inputs.soil_mixing_remaining_fraction > 1 or inputs.minimum_layer_thickness_m < 0) return error.InvalidTillageOrganicRedistributionInput;
    for (inputs.plain_families) |family| {
        if (family.layer_amount_g.len != layers) return error.TillageOrganicRedistributionDimensionMismatch;
        if (!finite(family.layer_amount_g) or !std.math.isFinite(family.mixed_total_g)) return error.InvalidTillageOrganicRedistributionInput;
    }
    for (inputs.held_families) |family| {
        if (family.layer_amount_g.len != layers or family.held_amount_g.len != layers) return error.TillageOrganicRedistributionDimensionMismatch;
        if (!finite(family.layer_amount_g) or !finite(family.held_amount_g) or !std.math.isFinite(family.mixed_total_g)) return error.InvalidTillageOrganicRedistributionInput;
    }
    for (inputs.incorporated_families) |family| {
        if (family.layer_amount_g.len != layers) return error.TillageOrganicRedistributionDimensionMismatch;
        if (!finite(family.layer_amount_g) or !std.math.isFinite(family.incorporated_total_g)) return error.InvalidTillageOrganicRedistributionInput;
    }

    const plain = try allocator.alloc(f64, plain_family_count * layers);
    defer allocator.free(plain);
    const held = try allocator.alloc(f64, held_family_count * layers);
    defer allocator.free(held);
    const held_pool = try allocator.alloc(f64, held_family_count * layers);
    defer allocator.free(held_pool);
    const incorporated = try allocator.alloc(f64, incorporated_family_count * layers);
    defer allocator.free(incorporated);
    for (inputs.plain_families, 0..) |family, i| @memcpy(plain[i * layers ..][0..layers], family.layer_amount_g);
    for (inputs.held_families, 0..) |family, i| {
        @memcpy(held[i * layers ..][0..layers], family.layer_amount_g);
        @memcpy(held_pool[i * layers ..][0..layers], family.held_amount_g);
    }
    for (inputs.incorporated_families, 0..) |family, i| @memcpy(incorporated[i * layers ..][0..layers], family.layer_amount_g);
    for (inputs.first_soil_layer..inputs.last_mixed_layer + 1) |layer| {
        const thickness = inputs.layer_thickness_m[layer];
        if (thickness <= inputs.minimum_layer_thickness_m) continue;
        const overlap = @min(thickness, inputs.mixing_depth_m - (inputs.cumulative_layer_bottom_m[layer] - thickness));
        const fi = overlap / inputs.mixing_depth_m;
        const ti = overlap / thickness;
        const tx = 1.0 - ti;
        for (inputs.plain_families, 0..) |family, i| {
            const old = family.layer_amount_g[layer];
            plain[i * layers + layer] = ti * old + inputs.mixing_fraction * (fi * family.mixed_total_g - ti * old) + tx * old;
            if (!std.math.isFinite(plain[i * layers + layer])) return error.NonFiniteTillageOrganicRedistributionResult;
        }
        for (inputs.held_families, 0..) |family, i| {
            const old = family.layer_amount_g[layer];
            held[i * layers + layer] = ti * old + inputs.mixing_fraction * (fi * family.mixed_total_g - ti * old) + tx * old + inputs.mixing_fraction * family.held_amount_g[layer];
            held_pool[i * layers + layer] = inputs.soil_mixing_remaining_fraction * family.held_amount_g[layer];
            if (!std.math.isFinite(held[i * layers + layer]) or !std.math.isFinite(held_pool[i * layers + layer])) return error.NonFiniteTillageOrganicRedistributionResult;
        }
        for (inputs.incorporated_families, 0..) |family, i| {
            // These are additions to the same OMC/ORC/OQC/... owners written
            // by the preceding plain/held block.  The runtime adapter passes
            // those aliases directly.  Stage from the already-redistributed
            // value, not the pre-tillage value, or the later incorporated
            // commit would silently overwrite soil mixing.
            var base = family.layer_amount_g[layer];
            for (inputs.plain_families, 0..) |plain_family, plain_index| {
                if (plain_family.layer_amount_g.ptr == family.layer_amount_g.ptr) {
                    base = plain[plain_index * layers + layer];
                    break;
                }
            }
            for (inputs.held_families, 0..) |held_family, held_index| {
                if (held_family.layer_amount_g.ptr == family.layer_amount_g.ptr) {
                    base = held[held_index * layers + layer];
                    break;
                }
                if (held_family.held_amount_g.ptr == family.layer_amount_g.ptr) {
                    base = held_pool[held_index * layers + layer];
                    break;
                }
            }
            incorporated[i * layers + layer] = base + fi * family.incorporated_total_g;
            if (!std.math.isFinite(incorporated[i * layers + layer])) return error.NonFiniteTillageOrganicRedistributionResult;
        }
    }
    for (inputs.plain_families, 0..) |family, i| @memcpy(family.layer_amount_g, plain[i * layers ..][0..layers]);
    for (inputs.held_families, 0..) |family, i| {
        @memcpy(family.layer_amount_g, held[i * layers ..][0..layers]);
        @memcpy(family.held_amount_g, held_pool[i * layers ..][0..layers]);
    }
    for (inputs.incorporated_families, 0..) |family, i| @memcpy(family.layer_amount_g, incorporated[i * layers ..][0..layers]);
}

test "REDIST organic redistribution preserves plain held scaling and incorporated addition" {
    const bottoms = [_]f64{0.1};
    const thickness = [_]f64{0.1};
    const held_source = [_]f64{0.5};
    var plain_values: [plain_family_count][1]f64 = @splat(@splat(2));
    var held_values: [held_family_count][1]f64 = @splat(@splat(2));
    var held_pools: [held_family_count][1]f64 = @splat(held_source);
    var incorporated_values: [incorporated_family_count][1]f64 = @splat(@splat(2));
    var plain: [plain_family_count]PlainFamily = undefined;
    var held: [held_family_count]HeldFamily = undefined;
    var incorporated: [incorporated_family_count]IncorporatedFamily = undefined;
    for (0..plain_family_count) |i| plain[i] = .{ .layer_amount_g = &plain_values[i], .mixed_total_g = 4 };
    for (0..held_family_count) |i| held[i] = .{ .layer_amount_g = &held_values[i], .mixed_total_g = 4, .held_amount_g = &held_pools[i] };
    for (0..incorporated_family_count) |i| incorporated[i] = .{ .layer_amount_g = &incorporated_values[i], .incorporated_total_g = 3 };
    try redistribute(std.testing.allocator, .{ .first_soil_layer = 0, .last_mixed_layer = 0, .mixing_depth_m = 0.1, .mixing_fraction = 0.5, .soil_mixing_remaining_fraction = 0.25, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0, .plain_families = &plain, .held_families = &held, .incorporated_families = &incorporated });
    try std.testing.expectEqual(@as(f64, 3), plain_values[527][0]);
    try std.testing.expectEqual(@as(f64, 3.25), held_values[19][0]);
    try std.testing.expectEqual(@as(f64, 0.125), held_pools[19][0]);
    try std.testing.expectEqual(@as(f64, 5), incorporated_values[428][0]);
}

test "REDIST organic incorporation composes with aliased plain owner" {
    const bottoms = [_]f64{0.1};
    const thickness = [_]f64{0.1};
    const zero = [_]f64{0};
    var plain_values: [plain_family_count][1]f64 = @splat(@splat(0));
    var held_values: [held_family_count][1]f64 = @splat(@splat(0));
    var held_pools: [held_family_count][1]f64 = @splat(zero);
    var incorporated_values: [incorporated_family_count][1]f64 = @splat(@splat(0));
    var plain: [plain_family_count]PlainFamily = undefined;
    var held: [held_family_count]HeldFamily = undefined;
    var incorporated: [incorporated_family_count]IncorporatedFamily = undefined;
    for (0..plain_family_count) |i| plain[i] = .{ .layer_amount_g = &plain_values[i], .mixed_total_g = 0 };
    for (0..held_family_count) |i| held[i] = .{ .layer_amount_g = &held_values[i], .mixed_total_g = 0, .held_amount_g = &held_pools[i] };
    for (0..incorporated_family_count) |i| incorporated[i] = .{ .layer_amount_g = &incorporated_values[i], .incorporated_total_g = 0 };
    plain_values[0][0] = 2;
    plain[0].mixed_total_g = 4;
    incorporated[0] = .{ .layer_amount_g = &plain_values[0], .incorporated_total_g = 3 };
    try redistribute(std.testing.allocator, .{ .first_soil_layer = 0, .last_mixed_layer = 0, .mixing_depth_m = 0.1, .mixing_fraction = 0.5, .soil_mixing_remaining_fraction = 0.5, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0, .plain_families = &plain, .held_families = &held, .incorporated_families = &incorporated });
    // Plain redistribution gives 3; surface incorporation adds another 3.
    try std.testing.expectEqual(@as(f64, 6), plain_values[0][0]);
}

test "REDIST organic incorporation composes with scaled held owner" {
    const bottoms = [_]f64{0.1};
    const thickness = [_]f64{0.1};
    var plain_values: [plain_family_count][1]f64 = @splat(@splat(0));
    var held_values: [held_family_count][1]f64 = @splat(@splat(0));
    var held_pools: [held_family_count][1]f64 = @splat(@splat(0));
    var incorporated_values: [incorporated_family_count][1]f64 = @splat(@splat(0));
    var plain: [plain_family_count]PlainFamily = undefined;
    var held: [held_family_count]HeldFamily = undefined;
    var incorporated: [incorporated_family_count]IncorporatedFamily = undefined;
    for (0..plain_family_count) |i| plain[i] = .{ .layer_amount_g = &plain_values[i], .mixed_total_g = 0 };
    for (0..held_family_count) |i| held[i] = .{ .layer_amount_g = &held_values[i], .mixed_total_g = 0, .held_amount_g = &held_pools[i] };
    for (0..incorporated_family_count) |i| incorporated[i] = .{ .layer_amount_g = &incorporated_values[i], .incorporated_total_g = 0 };
    held_pools[0][0] = 2;
    incorporated[0] = .{ .layer_amount_g = &held_pools[0], .incorporated_total_g = 3 };
    try redistribute(std.testing.allocator, .{ .first_soil_layer = 0, .last_mixed_layer = 0, .mixing_depth_m = 0.1, .mixing_fraction = 0.5, .soil_mixing_remaining_fraction = 0.5, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0, .plain_families = &plain, .held_families = &held, .incorporated_families = &incorporated });
    // Held scaling gives 1; surface incorporation then adds 3 to that owner.
    try std.testing.expectEqual(@as(f64, 4), held_pools[0][0]);
}

test "REDIST organic late incorporated overflow is atomic" {
    const bottoms = [_]f64{0.1};
    const thickness = [_]f64{0.1};
    var plain_values: [plain_family_count][1]f64 = @splat(@splat(2));
    var held_values: [held_family_count][1]f64 = @splat(@splat(2));
    var held_pools: [held_family_count][1]f64 = @splat(@splat(1));
    var incorporated_values: [incorporated_family_count][1]f64 = @splat(@splat(2));
    var plain: [plain_family_count]PlainFamily = undefined;
    var held: [held_family_count]HeldFamily = undefined;
    var incorporated: [incorporated_family_count]IncorporatedFamily = undefined;
    for (0..plain_family_count) |i| plain[i] = .{ .layer_amount_g = &plain_values[i], .mixed_total_g = 4 };
    for (0..held_family_count) |i| held[i] = .{ .layer_amount_g = &held_values[i], .mixed_total_g = 4, .held_amount_g = &held_pools[i] };
    for (0..incorporated_family_count) |i| incorporated[i] = .{ .layer_amount_g = &incorporated_values[i], .incorporated_total_g = 3 };
    incorporated[428].incorporated_total_g = std.math.floatMax(f64);
    incorporated_values[428][0] = std.math.floatMax(f64);
    try std.testing.expectError(error.NonFiniteTillageOrganicRedistributionResult, redistribute(std.testing.allocator, .{ .first_soil_layer = 0, .last_mixed_layer = 0, .mixing_depth_m = 0.1, .mixing_fraction = 0.5, .soil_mixing_remaining_fraction = 0.25, .cumulative_layer_bottom_m = &bottoms, .layer_thickness_m = &thickness, .minimum_layer_thickness_m = 0, .plain_families = &plain, .held_families = &held, .incorporated_families = &incorporated }));
    try std.testing.expectEqual(@as(f64, 2), plain_values[0][0]);
    try std.testing.expectEqual(@as(f64, 2), held_values[0][0]);
}

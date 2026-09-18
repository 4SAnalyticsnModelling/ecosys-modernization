const std = @import("std");

/// One GROSUB root-work coordinate. The caller owns plant traversal; this
/// iterator emits source `N` biological-domain outer, `L` soil-layer inner.
pub const Coordinate = struct {
    plant: usize,
    biological_domain: usize,
    soil_layer: usize,
};

pub const Inputs = struct {
    plant: usize,
    active_biological_domain_count: usize,
    /// Source cell-wide `NU`, mapped to a zero-based soil-layer index.
    first_active_soil_layer: usize,
    /// Source plant-wide inclusive `NI`, shared by every biological domain.
    deepest_rooted_soil_layer: usize,
    /// Source `DLYR(3,L)` in m, indexed by zero-based soil layer.
    layer_thickness_m: []const f64,
    /// Source `DLYRM` in m. Admission is strictly greater than this value.
    minimum_active_layer_thickness_m: f64,
};

/// Allocation-free GROSUB rooted-layer topology iterator. Process-specific
/// root area, activity, water-volume, and chemical gates deliberately remain
/// outside this contract.
pub const Iterator = struct {
    inputs: Inputs,
    biological_domain: usize = 0,
    soil_layer: usize,
    empty: bool,

    pub fn init(inputs: Inputs) !Iterator {
        if (inputs.active_biological_domain_count == 0)
            return error.ZeroActiveRootBiologicalDomains;
        if (inputs.layer_thickness_m.len == 0 or
            inputs.first_active_soil_layer >= inputs.layer_thickness_m.len or
            inputs.deepest_rooted_soil_layer >= inputs.layer_thickness_m.len)
            return error.InvalidRootedLayerEligibilityBounds;
        if (!std.math.isFinite(inputs.minimum_active_layer_thickness_m) or
            inputs.minimum_active_layer_thickness_m < 0)
            return error.InvalidMinimumActiveLayerThickness;
        if (inputs.first_active_soil_layer <= inputs.deepest_rooted_soil_layer) {
            for (inputs.layer_thickness_m[inputs.first_active_soil_layer .. inputs.deepest_rooted_soil_layer + 1]) |thickness_m|
                if (!std.math.isFinite(thickness_m) or thickness_m < 0)
                    return error.InvalidRootLayerThickness;
        }
        return .{
            .inputs = inputs,
            .soil_layer = inputs.first_active_soil_layer,
            .empty = inputs.first_active_soil_layer > inputs.deepest_rooted_soil_layer,
        };
    }

    pub fn next(self: *Iterator) ?Coordinate {
        if (self.empty) return null;
        while (self.biological_domain < self.inputs.active_biological_domain_count) {
            while (self.soil_layer <= self.inputs.deepest_rooted_soil_layer) {
                const layer = self.soil_layer;
                self.soil_layer += 1;
                if (self.inputs.layer_thickness_m[layer] > self.inputs.minimum_active_layer_thickness_m)
                    return .{
                        .plant = self.inputs.plant,
                        .biological_domain = self.biological_domain,
                        .soil_layer = layer,
                    };
            }
            self.biological_domain += 1;
            self.soil_layer = self.inputs.first_active_soil_layer;
        }
        return null;
    }
};

fn collect(iterator: *Iterator, output: []Coordinate) !usize {
    var count: usize = 0;
    while (iterator.next()) |coordinate| {
        if (count == output.len) return error.TestCoordinateCapacityExceeded;
        output[count] = coordinate;
        count += 1;
    }
    return count;
}

test "GROSUB rooted admission preserves exact domain-outer layer-inner order" {
    var iterator = try Iterator.init(.{
        .plant = 7,
        .active_biological_domain_count = 2,
        .first_active_soil_layer = 1,
        .deepest_rooted_soil_layer = 3,
        .layer_thickness_m = &.{ 0.1, 0.2, 0.3, 0.4 },
        .minimum_active_layer_thickness_m = 0.01,
    });
    var coordinates: [6]Coordinate = undefined;
    const count = try collect(&iterator, &coordinates);
    try std.testing.expectEqual(@as(usize, 6), count);
    try std.testing.expectEqualDeep([6]Coordinate{
        .{ .plant = 7, .biological_domain = 0, .soil_layer = 1 },
        .{ .plant = 7, .biological_domain = 0, .soil_layer = 2 },
        .{ .plant = 7, .biological_domain = 0, .soil_layer = 3 },
        .{ .plant = 7, .biological_domain = 1, .soil_layer = 1 },
        .{ .plant = 7, .biological_domain = 1, .soil_layer = 2 },
        .{ .plant = 7, .biological_domain = 1, .soil_layer = 3 },
    }, coordinates);
}

test "both biological domains consume one identical plant rooted bound" {
    var iterator = try Iterator.init(.{
        .plant = 1,
        .active_biological_domain_count = 2,
        .first_active_soil_layer = 2,
        .deepest_rooted_soil_layer = 4,
        .layer_thickness_m = &.{ 1, 1, 1, 1, 1 },
        .minimum_active_layer_thickness_m = 0,
    });
    var deepest = [_]?usize{ null, null };
    while (iterator.next()) |coordinate| deepest[coordinate.biological_domain] = coordinate.soil_layer;
    try std.testing.expectEqualDeep([_]?usize{ 4, 4 }, deepest);
}

test "different plants retain unequal rooted bounds under plant-outer caller order" {
    const thickness = [_]f64{ 1, 1, 1, 1, 1 };
    var output: [8]Coordinate = undefined;
    var count: usize = 0;
    for ([_]usize{ 2, 4 }, 0..) |deepest, plant| {
        var iterator = try Iterator.init(.{
            .plant = plant,
            .active_biological_domain_count = 1,
            .first_active_soil_layer = 1,
            .deepest_rooted_soil_layer = deepest,
            .layer_thickness_m = &thickness,
            .minimum_active_layer_thickness_m = 0,
        });
        count += try collect(&iterator, output[count..]);
    }
    try std.testing.expectEqual(@as(usize, 6), count);
    try std.testing.expectEqual(@as(usize, 2), output[1].soil_layer);
    try std.testing.expectEqual(@as(usize, 1), output[2].soil_layer);
    try std.testing.expectEqual(@as(usize, 4), output[5].soil_layer);
}

test "strict DLYR greater than DLYRM excludes equal and thinner layers" {
    var iterator = try Iterator.init(.{
        .plant = 0,
        .active_biological_domain_count = 1,
        .first_active_soil_layer = 0,
        .deepest_rooted_soil_layer = 3,
        .layer_thickness_m = &.{ 0.01, 0.0100001, 0.005, 0.02 },
        .minimum_active_layer_thickness_m = 0.01,
    });
    try std.testing.expectEqual(@as(usize, 1), iterator.next().?.soil_layer);
    try std.testing.expectEqual(@as(usize, 3), iterator.next().?.soil_layer);
    try std.testing.expect(iterator.next() == null);
}

test "empty rooted range emits nothing and malformed topology fails" {
    var empty = try Iterator.init(.{
        .plant = 0,
        .active_biological_domain_count = 1,
        .first_active_soil_layer = 2,
        .deepest_rooted_soil_layer = 1,
        .layer_thickness_m = &.{ 1, 1, 1 },
        .minimum_active_layer_thickness_m = 0,
    });
    try std.testing.expect(empty.next() == null);
    try std.testing.expectError(error.ZeroActiveRootBiologicalDomains, Iterator.init(.{
        .plant = 0,
        .active_biological_domain_count = 0,
        .first_active_soil_layer = 0,
        .deepest_rooted_soil_layer = 0,
        .layer_thickness_m = &.{1},
        .minimum_active_layer_thickness_m = 0,
    }));
    try std.testing.expectError(error.InvalidRootedLayerEligibilityBounds, Iterator.init(.{
        .plant = 0,
        .active_biological_domain_count = 1,
        .first_active_soil_layer = 0,
        .deepest_rooted_soil_layer = 2,
        .layer_thickness_m = &.{ 1, 1 },
        .minimum_active_layer_thickness_m = 0,
    }));
}

test "randomized plant decomposition preserves admitted coordinate stream" {
    const plant_count = 17;
    const thickness = [_]f64{ 0.02, 0.005, 0.03, 0.04, 0.01, 0.06 };
    var expected: [plant_count * 12]Coordinate = undefined;
    var decomposed: [plant_count * 12]Coordinate = undefined;
    var expected_count: usize = 0;
    var decomposed_count: usize = 0;
    var random_state: u32 = 0x8d31_62a7;
    for (0..plant_count) |plant| {
        random_state = random_state *% 1_664_525 +% 1_013_904_223;
        const deepest: usize = 2 + @as(usize, random_state % 4);
        var iterator = try Iterator.init(.{
            .plant = plant,
            .active_biological_domain_count = 1 + plant % 2,
            .first_active_soil_layer = 0,
            .deepest_rooted_soil_layer = deepest,
            .layer_thickness_m = &thickness,
            .minimum_active_layer_thickness_m = 0.01,
        });
        expected_count += try collect(&iterator, expected[expected_count..]);
    }
    const boundaries = [_]usize{ 0, 3, 4, 11, plant_count };
    random_state = 0x8d31_62a7;
    var deepest_by_plant: [plant_count]usize = undefined;
    for (&deepest_by_plant) |*deepest| {
        random_state = random_state *% 1_664_525 +% 1_013_904_223;
        deepest.* = 2 + @as(usize, random_state % 4);
    }
    for (0..boundaries.len - 1) |chunk| for (boundaries[chunk]..boundaries[chunk + 1]) |plant| {
        var iterator = try Iterator.init(.{
            .plant = plant,
            .active_biological_domain_count = 1 + plant % 2,
            .first_active_soil_layer = 0,
            .deepest_rooted_soil_layer = deepest_by_plant[plant],
            .layer_thickness_m = &thickness,
            .minimum_active_layer_thickness_m = 0.01,
        });
        decomposed_count += try collect(&iterator, decomposed[decomposed_count..]);
    };
    try std.testing.expectEqual(expected_count, decomposed_count);
    try std.testing.expectEqualDeep(expected[0..expected_count], decomposed[0..decomposed_count]);
}

test "late invalid thickness fails during preflight before yielding a tuple" {
    try std.testing.expectError(error.InvalidRootLayerThickness, Iterator.init(.{
        .plant = 9,
        .active_biological_domain_count = 2,
        .first_active_soil_layer = 0,
        .deepest_rooted_soil_layer = 3,
        .layer_thickness_m = &.{ 0.1, 0.2, 0.3, std.math.nan(f64) },
        .minimum_active_layer_thickness_m = 0.01,
    }));
}

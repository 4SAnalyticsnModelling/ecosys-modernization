const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const PlantState = @import("../../state/grid.zig").PlantState;
const Assignments = @import("../../state/plant_assignment.zig").Assignments;
const Catalog = @import("../../state/plant_catalog.zig").Catalog;

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    inclination_class_count: usize,
    species_is_active: []bool,
    initial_clumping_factor: []f64,
    effective_clumping_factor: []f64,
    leaf_inclination_fraction: []f64,
    leaf_area_index_by_inclination_m2_m2: []f64,

    pub fn initMapped(allocator: std.mem.Allocator, cell_count: usize, species_count: usize, inclination_class_count: usize, assignments: Assignments, unit_by_cell: []const usize, catalog: Catalog) !State {
        if (cell_count == 0 or species_count == 0 or inclination_class_count == 0 or unit_by_cell.len != cell_count) return error.InvalidCanopyStructureDimensions;
        const species_slots = try std.math.mul(usize, cell_count, species_count);
        const angle_slots = try std.math.mul(usize, species_slots, inclination_class_count);
        var result: State = .{
            .allocator = allocator,
            .cell_count = cell_count,
            .species_count = species_count,
            .inclination_class_count = inclination_class_count,
            .species_is_active = try allocator.alloc(bool, species_slots),
            .initial_clumping_factor = undefined,
            .effective_clumping_factor = undefined,
            .leaf_inclination_fraction = undefined,
            .leaf_area_index_by_inclination_m2_m2 = undefined,
        };
        errdefer allocator.free(result.species_is_active);
        result.initial_clumping_factor = try allocator.alloc(f64, species_slots);
        errdefer allocator.free(result.initial_clumping_factor);
        result.effective_clumping_factor = try allocator.alloc(f64, species_slots);
        errdefer allocator.free(result.effective_clumping_factor);
        result.leaf_inclination_fraction = try allocator.alloc(f64, angle_slots);
        errdefer allocator.free(result.leaf_inclination_fraction);
        result.leaf_area_index_by_inclination_m2_m2 = try allocator.alloc(f64, angle_slots);
        inline for (@typeInfo(State).@"struct".fields) |field| switch (field.type) {
            []f64 => @memset(@field(result, field.name), 0),
            []bool => @memset(@field(result, field.name), false),
            else => {},
        };

        for (unit_by_cell, 0..) |unit_index, cell| {
            if (unit_index >= assignments.units.len) return error.PlantAssignmentUnitOutOfBounds;
            const assigned = assignments.units[unit_index].species;
            if (assigned.len > species_count) return error.PlantSpeciesCapacityExceeded;
            for (assigned, 0..) |assignment, species| {
                const catalog_index = catalog.find(assignment.species_file) orelse return error.MissingPlantTraitProfile;
                const morphology = catalog.entries.items[catalog_index].traits.morphology;
                if (!std.math.isFinite(morphology.initial_clumping_factor) or morphology.initial_clumping_factor < 0) return error.InvalidInitialClumpingFactor;
                const source = [4]f64{
                    morphology.leaf_inclination_fraction_0_to_22_5_deg,
                    morphology.leaf_inclination_fraction_22_5_to_45_deg,
                    morphology.leaf_inclination_fraction_45_to_67_5_deg,
                    morphology.leaf_inclination_fraction_67_5_to_90_deg,
                };
                try validateDistribution(source);
                const species_index = cell * species_count + species;
                result.species_is_active[species_index] = true;
                result.initial_clumping_factor[species_index] = morphology.initial_clumping_factor;
                remapDistribution(source, result.leaf_inclination_fraction[species_index * inclination_class_count ..][0..inclination_class_count]);
            }
        }
        return result;
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.leaf_area_index_by_inclination_m2_m2);
        self.allocator.free(self.leaf_inclination_fraction);
        self.allocator.free(self.effective_clumping_factor);
        self.allocator.free(self.initial_clumping_factor);
        self.allocator.free(self.species_is_active);
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| {
            if (!std.math.isFinite(value)) {
                std.log.err("non-finite canopy structure: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteCanopyStructure;
            }
        };
    }
};

pub const ApplyContext = struct { structure: *State, plants: *const PlantState };

/// One HOUR1 ZL/ZL1 equal-area boundary update. Repeated hourly calls retain
/// the source's gradual 0.5 relaxation while the layer extent is runtime data.
pub fn redistributeLayerBoundariesEqualArea(allocator: std.mem.Allocator, canopy_height_m: f64, minimum_area_m2: f64, leaf_area_by_layer_m2: []const f64, stalk_area_by_layer_m2: []const f64, standing_dead_area_by_layer_m2: []const f64, layer_boundary_height_m: []f64) !void {
    const layer_count = leaf_area_by_layer_m2.len;
    if (layer_count == 0 or stalk_area_by_layer_m2.len != layer_count or standing_dead_area_by_layer_m2.len != layer_count or layer_boundary_height_m.len != layer_count + 1 or !std.math.isFinite(canopy_height_m) or canopy_height_m < 0 or !std.math.isFinite(minimum_area_m2) or minimum_area_m2 < 0) return error.InvalidCanopyLayerRedistributionInput;
    for (1..layer_boundary_height_m.len) |index| if (!std.math.isFinite(layer_boundary_height_m[index - 1]) or !std.math.isFinite(layer_boundary_height_m[index]) or layer_boundary_height_m[index] < layer_boundary_height_m[index - 1]) return error.InvalidCanopyLayerBoundary;
    var total_area_m2: f64 = 0;
    for (leaf_area_by_layer_m2, stalk_area_by_layer_m2, standing_dead_area_by_layer_m2) |leaf, stalk, dead| {
        inline for (.{ leaf, stalk, dead }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidCanopyLayerArea;
        total_area_m2 += leaf + stalk + dead;
    }
    const next = try allocator.dupe(f64, layer_boundary_height_m);
    defer allocator.free(next);
    next[0] = 0;
    next[layer_count] = canopy_height_m + 0.01;
    layer_boundary_height_m[layer_count] = canopy_height_m + 0.01;
    const target_area_m2 = total_area_m2 / @as(f64, @floatFromInt(layer_count));
    if (target_area_m2 > minimum_area_m2) {
        var upper = layer_count;
        while (upper > 1) {
            const layer = upper - 1;
            const area_m2 = leaf_area_by_layer_m2[layer] + stalk_area_by_layer_m2[layer] + standing_dead_area_by_layer_m2[layer];
            if (area_m2 > 1.01 * target_area_m2) {
                const thickness_m = layer_boundary_height_m[layer + 1] - layer_boundary_height_m[layer];
                next[layer] = layer_boundary_height_m[layer] + 0.5 * @min(1.0, (area_m2 - target_area_m2) / area_m2) * thickness_m;
            } else if (area_m2 < 0.99 * target_area_m2) {
                const lower_area_m2 = leaf_area_by_layer_m2[layer - 1] + stalk_area_by_layer_m2[layer - 1] + standing_dead_area_by_layer_m2[layer - 1];
                const lower_thickness_m = layer_boundary_height_m[layer] - layer_boundary_height_m[layer - 1];
                next[layer] = if (lower_area_m2 > minimum_area_m2) @min(canopy_height_m, layer_boundary_height_m[layer] - 0.5 * @min(1.0, (target_area_m2 - area_m2) / lower_area_m2) * lower_thickness_m) else next[layer + 1];
            } else next[layer] = layer_boundary_height_m[layer];
            upper -= 1;
        }
    } else {
        for (1..layer_count) |layer| next[layer] = 0;
    }
    @memcpy(layer_boundary_height_m, next);
}

/// Updates HOUR1 CFX and distributes LAI among runtime inclination classes.
pub fn applyLeafAreaTile(context: *ApplyContext, range: CellRange) !void {
    const structure = context.structure;
    if (range.end > structure.cell_count or context.plants.cell_count != structure.cell_count or context.plants.species_count != structure.species_count) return error.CanopyStructureTileOutOfBounds;
    for (range.first..range.end) |cell| for (0..structure.species_count) |species| {
        const species_index = cell * structure.species_count + species;
        if (!structure.species_is_active[species_index]) continue;
        const leaf_area_index = context.plants.leaf_area_index_m2_m2[species_index];
        if (!std.math.isFinite(leaf_area_index) or leaf_area_index < 0) return error.InvalidLeafAreaIndex;
        const density_correction = 1.0 - 0.025 * leaf_area_index;
        if (density_correction < 0) return error.ClumpingCorrectionBecameNegative;
        structure.effective_clumping_factor[species_index] = structure.initial_clumping_factor[species_index] * density_correction;
        for (0..structure.inclination_class_count) |inclination| {
            const angle_index = species_index * structure.inclination_class_count + inclination;
            structure.leaf_area_index_by_inclination_m2_m2[angle_index] = leaf_area_index * structure.leaf_inclination_fraction[angle_index];
        }
    };
}

fn validateDistribution(source: [4]f64) !void {
    var sum: f64 = 0;
    for (source) |fraction| {
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidLeafInclinationDistribution;
        sum += fraction;
    }
    if (@abs(sum - 1.0) > 1.0e-4) return error.LeafInclinationDistributionDoesNotSumToOne;
}

fn remapDistribution(source: [4]f64, target: []f64) void {
    @memset(target, 0);
    for (0..4) |source_index| {
        const source_lower = @as(f64, @floatFromInt(source_index)) / 4.0;
        const source_upper = @as(f64, @floatFromInt(source_index + 1)) / 4.0;
        for (target, 0..) |*fraction, target_index| {
            const target_lower = @as(f64, @floatFromInt(target_index)) / @as(f64, @floatFromInt(target.len));
            const target_upper = @as(f64, @floatFromInt(target_index + 1)) / @as(f64, @floatFromInt(target.len));
            const overlap = @max(0.0, @min(source_upper, target_upper) - @max(source_lower, target_lower));
            fraction.* += source[source_index] * 4.0 * overlap;
        }
    }
}

test "angle remapping conserves leaf area for arbitrary runtime classes" {
    var target: [7]f64 = undefined;
    remapDistribution(.{ 0.1, 0.2, 0.3, 0.4 }, &target);
    var sum: f64 = 0;
    for (target) |fraction| sum += fraction;
    try std.testing.expectApproxEqAbs(@as(f64, 1), sum, 1.0e-14);
}

test "HOUR1 equal-area canopy redistribution supports runtime layer counts" {
    const allocator = std.testing.allocator;
    const layer_count = 13;
    var boundaries: [layer_count + 1]f64 = undefined;
    for (&boundaries, 0..) |*height, index| height.* = @as(f64, @floatFromInt(index)) / layer_count;
    var leaf = [_]f64{1} ** layer_count;
    leaf[layer_count - 1] = 5;
    const zero = [_]f64{0} ** layer_count;
    const old_boundary = boundaries[layer_count - 1];
    try redistributeLayerBoundariesEqualArea(allocator, 1, 1.0e-12, &leaf, &zero, &zero, &boundaries);
    try std.testing.expect(boundaries[layer_count - 1] > old_boundary);
    try std.testing.expectEqual(@as(f64, 0), boundaries[0]);
    try std.testing.expectEqual(@as(f64, 1.01), boundaries[layer_count]);
}

test "negative density correction fails instead of silently propagating" {
    const allocator = std.testing.allocator;
    var plants = try PlantState.init(allocator, try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 }));
    defer plants.deinit();
    plants.leaf_area_index_m2_m2[0] = 41;
    var structure: State = .{ .allocator = allocator, .cell_count = 1, .species_count = 1, .inclination_class_count = 1, .species_is_active = try allocator.alloc(bool, 1), .initial_clumping_factor = try allocator.alloc(f64, 1), .effective_clumping_factor = try allocator.alloc(f64, 1), .leaf_inclination_fraction = try allocator.alloc(f64, 1), .leaf_area_index_by_inclination_m2_m2 = try allocator.alloc(f64, 1) };
    defer structure.deinit();
    structure.species_is_active[0] = true;
    structure.initial_clumping_factor[0] = 1;
    structure.leaf_inclination_fraction[0] = 1;
    var context: ApplyContext = .{ .structure = &structure, .plants = &plants };
    try std.testing.expectError(error.ClumpingCorrectionBecameNegative, applyLeafAreaTile(&context, .{ .first = 0, .end = 1 }));
}

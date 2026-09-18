const std = @import("std");
const cell_grid_file = @import("../io/input/cell_grid_file.zig");
const spatial_grid = @import("spatial_grid.zig");

pub const SpeciesAssignment = struct {
    species_file: []const u8,
    management_file: []const u8,
};

/// The plants growing at one grid cell.
///
/// A unit is one cell, named by coordinate, so units cannot overlap and there
/// is no rectangular range to reconcile.
pub const Unit = struct {
    species: []SpeciesAssignment,
};

pub const Assignments = struct {
    allocator: std.mem.Allocator,
    /// One unit per grid cell, in row-major order.
    units: []Unit,

    pub fn deinit(self: *Assignments) void {
        for (self.units) |unit| {
            // A cell with no species holds an empty literal, not an
            // allocation. Coverage is required at parse time, so this only
            // arises when tearing down after a partial parse.
            if (unit.species.len == 0) continue;
            for (unit.species) |species| {
                self.allocator.free(species.species_file);
                self.allocator.free(species.management_file);
            }
            self.allocator.free(unit.species);
        }
        self.allocator.free(self.units);
        self.* = undefined;
    }

    /// Identity map, since every cell owns its own unit. The species capacity
    /// is still checked here because exceeding it would silently drop a plant
    /// the user asked for.
    pub fn buildCellUnitMap(
        self: Assignments,
        allocator: std.mem.Allocator,
        species_capacity: usize,
    ) ![]usize {
        for (self.units, 0..) |unit, unit_index| {
            if (unit.species.len > species_capacity) {
                std.log.err(
                    "plant assignment exceeds runtime species capacity: assigned={d} capacity={d} cell={d}",
                    .{ unit.species.len, species_capacity, unit_index },
                );
                return error.PlantSpeciesCapacityExceeded;
            }
        }
        const map = try allocator.alloc(usize, self.units.len);
        for (map, 0..) |*unit_index, cell| unit_index.* = cell;
        return map;
    }
};

/// Parses the coordinate-keyed plant grid file.
///
/// Record order is `plant latitude longitude functional_type management`. The
/// functional-type name is written exactly as the file on disk is named, so no
/// ecosystem-type suffix is derived here: the name the user wrote is the name
/// that is opened.
///
/// One record carries one plant, and a cell growing several plants repeats its
/// coordinate once per plant. Repetition is therefore meaningful here rather
/// than a defect: intercropped and mixed-species stands are ordinary, and the
/// order the records appear in is the order the species are stored, because
/// competition for light and nutrients is resolved in species order.
pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    grid: spatial_grid.RegularGrid,
) !Assignments {
    const cell_count = try grid.cellCount();
    const units = try allocator.alloc(Unit, cell_count);
    errdefer allocator.free(units);
    for (units) |*unit| unit.* = .{ .species = &.{} };
    errdefer for (units) |unit| {
        if (unit.species.len == 0) continue;
        for (unit.species) |species| {
            allocator.free(species.species_file);
            allocator.free(species.management_file);
        }
        allocator.free(unit.species);
    };

    // A repeated coordinate adds a species to that cell rather than being a
    // duplicate, so the reader is told repeats are expected.
    var reader = try cell_grid_file.Reader.initWithRepeats(
        allocator,
        source,
        grid,
        "plant",
        2,
        true,
    );
    defer reader.deinit(allocator);
    while (try reader.next()) |record| {
        const species_file = try allocator.dupe(u8, record.names[0]);
        errdefer allocator.free(species_file);
        const management_file = try allocator.dupe(u8, record.names[1]);
        errdefer allocator.free(management_file);

        // Grown one entry at a time. A cell has a handful of species at most,
        // so reallocating per record costs nothing and avoids a second pass to
        // count them.
        const existing = units[record.cell].species;
        const grown = try allocator.realloc(existing, existing.len + 1);
        grown[grown.len - 1] = .{
            .species_file = species_file,
            .management_file = management_file,
        };
        units[record.cell] = .{ .species = grown };
    }
    try reader.requireCompleteCoverage();
    return .{ .allocator = allocator, .units = units };
}

/// Builds assignments directly from the species of each cell.
///
/// Production code reaches this shape through `parse`, which resolves each cell
/// from a coordinate and accumulates repeated coordinates into one cell's
/// species list. Tests of the dispatch layer need only the resulting lists.
pub fn fromUnits(
    allocator: std.mem.Allocator,
    specs: []const []const SpeciesAssignment,
) !Assignments {
    const units = try allocator.alloc(Unit, specs.len);
    errdefer allocator.free(units);
    for (units) |*unit| unit.* = .{ .species = &.{} };
    errdefer for (units) |unit| {
        if (unit.species.len == 0) continue;
        for (unit.species) |entry| {
            allocator.free(entry.species_file);
            allocator.free(entry.management_file);
        }
        allocator.free(unit.species);
    };
    for (specs, 0..) |cell_species, index| {
        const species = try allocator.alloc(SpeciesAssignment, cell_species.len);
        errdefer allocator.free(species);
        var initialized: usize = 0;
        errdefer for (species[0..initialized]) |entry| {
            allocator.free(entry.species_file);
            allocator.free(entry.management_file);
        };
        for (cell_species, 0..) |entry, species_index| {
            const species_file = try allocator.dupe(u8, entry.species_file);
            errdefer allocator.free(species_file);
            const management_file = try allocator.dupe(u8, entry.management_file);
            species[species_index] = .{
                .species_file = species_file,
                .management_file = management_file,
            };
            initialized += 1;
        }
        units[index] = .{ .species = species };
    }
    return .{ .allocator = allocator, .units = units };
}

test {
    _ = @import("plant_assignment_test.zig");
}

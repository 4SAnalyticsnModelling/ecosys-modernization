const std = @import("std");
const grid_input_files = @import("../io/input/grid_input_files.zig");
const runscript = @import("../driver/runscript.zig");
const site_catalog = @import("site_catalog.zig");
const spatial_grid = @import("spatial_grid.zig");
const topography_module = @import("topography.zig");

/// Which of a cell's four lateral faces has a neighbouring cell inside the
/// grid. A face without a neighbour is an exterior boundary, and only there
/// does the site file's own width value apply.
pub const Neighbors = struct {
    north: bool,
    east: bool,
    south: bool,
    west: bool,

    pub fn hasEastWestNeighbor(self: Neighbors) bool {
        return self.east or self.west;
    }

    pub fn hasNorthSouthNeighbor(self: Neighbors) bool {
        return self.north or self.south;
    }
};

/// Interior-face presence for one cell of a row-major grid.
pub fn neighborsOfCell(cell: usize, column_count: usize, row_count: usize) Neighbors {
    const column = cell % column_count;
    const row = cell / column_count;
    return .{
        .north = row > 0,
        .east = column + 1 < column_count,
        .south = row + 1 < row_count,
        .west = column > 0,
    };
}

pub const Assignments = struct {
    allocator: std.mem.Allocator,
    column_count: usize,
    row_count: usize,
    site_catalog_index_by_cell: []usize,
    horizontal_cell_width_m: []f64,
    vertical_cell_width_m: []f64,
    initial_water_table_depth_m: []f64,
    natural_water_table_surface_slope: []f64,

    /// Builds the per-cell environment from the grid-cell mapping and the site
    /// files it names.
    ///
    /// Cell dimensions come from the geospatial grid wherever a neighbouring
    /// cell exists on that axis, because two adjacent cells must agree on the
    /// width of the face they share, and deriving it from the shared latitude
    /// and longitude spacing is the only way that agreement is guaranteed. A
    /// cell with no neighbour on an axis has no shared face to reconcile, so
    /// there the site file's own width applies, which is what lets a
    /// single-cell run state its own footprint.
    pub fn init(
        allocator: std.mem.Allocator,
        files: grid_input_files.CellFiles,
        sites: site_catalog.Catalog,
        grid: spatial_grid.RegularGrid,
    ) !Assignments {
        const column_count = grid.column_count;
        const row_count = grid.row_count;
        const cell_count = try std.math.mul(usize, column_count, row_count);
        if (files.column_count != column_count or files.row_count != row_count or
            files.site_file_by_cell.len != cell_count or
            files.soil_file_by_cell.len != cell_count)
            return error.GridEnvironmentDimensionMismatch;

        var result: Assignments = undefined;
        result.allocator = allocator;
        result.column_count = column_count;
        result.row_count = row_count;
        var allocated: usize = 0;
        errdefer result.freeAllocated(allocated);
        result.site_catalog_index_by_cell = try allocator.alloc(usize, cell_count);
        allocated += 1;
        result.horizontal_cell_width_m = try allocator.alloc(f64, cell_count);
        allocated += 1;
        result.vertical_cell_width_m = try allocator.alloc(f64, cell_count);
        allocated += 1;
        result.initial_water_table_depth_m = try allocator.alloc(f64, cell_count);
        allocated += 1;
        result.natural_water_table_surface_slope = try allocator.alloc(f64, cell_count);
        allocated += 1;

        for (0..cell_count) |cell| {
            const site_index = sites.find(files.site_file_by_cell[cell]) orelse
                return error.SiteFileNotLoaded;
            const selected_site = sites.entries.items[site_index].site;
            if (selected_site.horizontal_cell_widths_m.len != 1 or
                selected_site.vertical_cell_widths_m.len != 1)
                return error.SiteDoesNotCoverGridCell;

            // Parsing resolved the cell from the coordinate, so this only
            // fails if the grid and the mapping disagree about the extent.
            try grid.validateSiteCoordinate(
                cell,
                files.latitude_degrees_north_by_cell[cell],
                files.longitude_degrees_east_by_cell[cell],
            );

            const neighbors = neighborsOfCell(cell, column_count, row_count);
            result.site_catalog_index_by_cell[cell] = site_index;
            result.horizontal_cell_width_m[cell] = if (neighbors.hasEastWestNeighbor())
                grid.east_west_cell_width_m[cell]
            else
                selected_site.horizontal_cell_widths_m[0];
            result.vertical_cell_width_m[cell] = if (neighbors.hasNorthSouthNeighbor())
                grid.north_south_cell_width_m[cell]
            else
                selected_site.vertical_cell_widths_m[0];
            for ([_]f64{
                result.horizontal_cell_width_m[cell],
                result.vertical_cell_width_m[cell],
            }) |width_m| if (!std.math.isFinite(width_m) or width_m <= 0)
                return error.InvalidGridCellDimension;
            result.initial_water_table_depth_m[cell] = selected_site.initial_water_table_depth_m;
            result.natural_water_table_surface_slope[cell] = selected_site.natural_water_table_surface_slope;
        }
        return result;
    }

    pub fn deinit(self: *Assignments) void {
        self.freeAllocated(5);
        self.* = undefined;
    }

    /// Materializes one landscape unit per runtime cell for consumers that
    /// operate on a domain-wide topography.
    ///
    /// Terrain attributes come from the cell's own site file rather than a
    /// separate topography file. A landscape unit is exactly one cell, so a
    /// file describing rectangular runs of cells could only repeat what the
    /// site file already states. The soil filename comes from the grid-cell
    /// mapping, which remains its only source.
    pub fn buildDomainTopography(
        self: Assignments,
        domain: runscript.Domain,
        files: grid_input_files.CellFiles,
        sites: site_catalog.Catalog,
    ) !topography_module.Topography {
        const cell_count = try std.math.mul(usize, self.column_count, self.row_count);
        if (files.soil_file_by_cell.len != cell_count) return error.GridEnvironmentDimensionMismatch;
        const units = try self.allocator.alloc(topography_module.LandscapeUnit, cell_count);
        errdefer self.allocator.free(units);
        var initialized: usize = 0;
        errdefer for (units[0..initialized]) |unit| self.allocator.free(unit.soil_profile_file);

        for (0..cell_count) |cell| {
            const local_column = cell % self.column_count;
            const local_row = cell / self.column_count;
            const global_column = try std.math.add(usize, domain.west_column, local_column);
            const global_row = try std.math.add(usize, domain.north_row, local_row);
            const site_index = self.site_catalog_index_by_cell[cell];
            if (site_index >= sites.entries.items.len)
                return error.SiteCatalogIndexOutOfRange;
            const selected_site = sites.entries.items[site_index].site;
            const soil_file = try self.allocator.dupe(u8, files.soil_file_by_cell[cell]);
            errdefer self.allocator.free(soil_file);
            units[cell] = .{
                .west_column = global_column,
                .north_row = global_row,
                .east_column = global_column,
                .south_row = global_row,
                .compass_aspect_degrees = selected_site.compass_aspect_degrees,
                .geometric_aspect_degrees = selected_site.geometricAspectDegrees(),
                .slope_degrees = selected_site.slope_degrees,
                .initial_snowpack_depth_m = selected_site.initial_snowpack_depth_m,
                .soil_profile_file = soil_file,
            };
            initialized += 1;
        }
        return .{ .allocator = self.allocator, .units = units };
    }

    fn freeAllocated(self: *Assignments, allocated: usize) void {
        if (allocated >= 5) self.allocator.free(self.natural_water_table_surface_slope);
        if (allocated >= 4) self.allocator.free(self.initial_water_table_depth_m);
        if (allocated >= 3) self.allocator.free(self.vertical_cell_width_m);
        if (allocated >= 2) self.allocator.free(self.horizontal_cell_width_m);
        if (allocated >= 1) self.allocator.free(self.site_catalog_index_by_cell);
    }
};

test {
    _ = @import("grid_environment_test.zig");
}

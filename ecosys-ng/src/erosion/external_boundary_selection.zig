// **A8a DISPOSITION: superseded, do not bind.** This module is index
// bookkeeping forced by legacy storing one erosion flux record per cell *per
// side*, so that the same physical interface appears twice and a backward
// `N4B/N5B` record must be reconciled against a forward `N4/N5` one.
// Production stores one directed face and derives the neighbor
// arithmetically: `erosion/sediment_routing.zig` decides interior versus
// boundary from the loop indices, consults the four `*_open` boundary flags,
// carries the site `NCNG` filter in `cellsExchange`, and in its reduction
// phase (`:93--103`) subtracts each face from its source and adds it to either
// the arithmetic neighbor or `sediment_export_megagrams`. Conservation is
// antisymmetric by construction, so there is no second record to map.
//
// Group D of docs/traceability/erosion_unbound_family_disposition.md

const std = @import("std");
const erosion_initialization = @import("substep_initialization.zig");

pub const Axis = enum { east_west, north_south }; // N=1,2
pub const Side = enum { forward, backward }; // NN=1,2

pub const GridExtent = struct {
    west_column: usize, // NHW
    east_column: usize, // NHE
    north_row: usize, // NVN
    south_row: usize, // NVS
};

pub const Cell = struct { column: usize, row: usize };

pub const BoundaryRunoff = struct {
    east: f64, // RCHQE
    west: f64, // RCHQW
    south: f64, // RCHQS
    north: f64, // RCHQN
};

pub const Inputs = struct {
    disturbance_effects: erosion_initialization.DisturbanceEffects,
    surface_soil_bulk_density_megagrams_per_m3: f64, // BKDS(NU,...)
    zero_threshold: f64, // ZERO
    extent: GridExtent,
    cell: Cell,
    axis: Axis,
    side: Side,
    boundary_runoff: BoundaryRunoff,
};

pub const Selection = struct {
    source: Cell, // M1,M2 and N1,N2
    positive_neighbor: Cell, // N4,N5
    external_face_storage: Cell, // M4,M5
    outward_sign: f64, // XN
    runoff_condition: f64, // RCHQF
};

fn includesErosion(effects: erosion_initialization.DisturbanceEffects) bool {
    return effects == .freeze_thaw_and_erosion or effects == .freeze_thaw_erosion_and_organic_change;
}

/// Direct translation of EROSION 1014--1072 for one runtime cell face.
pub fn select(inputs: Inputs) !?Selection {
    if (!includesErosion(inputs.disturbance_effects)) return null;
    if (!std.math.isFinite(inputs.surface_soil_bulk_density_megagrams_per_m3) or !std.math.isFinite(inputs.zero_threshold) or inputs.zero_threshold < 0) return error.InvalidErosionExternalBoundaryInput;
    if (inputs.surface_soil_bulk_density_megagrams_per_m3 <= inputs.zero_threshold) return null;
    const extent = inputs.extent;
    if (extent.west_column > extent.east_column or extent.north_row > extent.south_row or inputs.cell.column < extent.west_column or inputs.cell.column > extent.east_column or inputs.cell.row < extent.north_row or inputs.cell.row > extent.south_row) return error.InvalidErosionExternalBoundaryExtent;
    const source = inputs.cell;
    const selection: ?Selection = switch (inputs.axis) {
        .east_west => east_west: {
            if ((inputs.side == .forward and inputs.cell.column != extent.east_column) or (inputs.side == .backward and inputs.cell.column != extent.west_column)) break :east_west null;
            const east_neighbor_column = try std.math.add(usize, inputs.cell.column, 1);
            break :east_west switch (inputs.side) {
                .forward => .{ .source = source, .positive_neighbor = .{ .column = east_neighbor_column, .row = inputs.cell.row }, .external_face_storage = .{ .column = east_neighbor_column, .row = inputs.cell.row }, .outward_sign = -1, .runoff_condition = inputs.boundary_runoff.east },
                .backward => .{ .source = source, .positive_neighbor = .{ .column = east_neighbor_column, .row = inputs.cell.row }, .external_face_storage = source, .outward_sign = 1, .runoff_condition = inputs.boundary_runoff.west },
            };
        },
        .north_south => north_south: {
            if ((inputs.side == .forward and inputs.cell.row != extent.south_row) or (inputs.side == .backward and inputs.cell.row != extent.north_row)) break :north_south null;
            const south_neighbor_row = try std.math.add(usize, inputs.cell.row, 1);
            break :north_south switch (inputs.side) {
                .forward => .{ .source = source, .positive_neighbor = .{ .column = inputs.cell.column, .row = south_neighbor_row }, .external_face_storage = .{ .column = inputs.cell.column, .row = south_neighbor_row }, .outward_sign = -1, .runoff_condition = inputs.boundary_runoff.south },
                .backward => .{ .source = source, .positive_neighbor = .{ .column = inputs.cell.column, .row = south_neighbor_row }, .external_face_storage = source, .outward_sign = 1, .runoff_condition = inputs.boundary_runoff.north },
            };
        },
    };
    if (selection) |selected| if (!std.math.isFinite(selected.runoff_condition)) return error.InvalidErosionExternalBoundaryInput;
    return selection;
}

fn fixture() Inputs {
    return .{
        .disturbance_effects = .freeze_thaw_and_erosion,
        .surface_soil_bulk_density_megagrams_per_m3 = 1.2,
        .zero_threshold = 1.0e-15,
        .extent = .{ .west_column = 2, .east_column = 4, .north_row = 7, .south_row = 9 },
        .cell = .{ .column = 4, .row = 8 },
        .axis = .east_west,
        .side = .forward,
        .boundary_runoff = .{ .east = 10, .west = 20, .south = 30, .north = 40 },
    };
}

test "EROSION external selector preserves all four boundary coordinate conventions" {
    var inputs = fixture();
    const east = (try select(inputs)).?;
    try std.testing.expectEqual(Cell{ .column = 5, .row = 8 }, east.external_face_storage);
    try std.testing.expectEqual(@as(f64, -1), east.outward_sign);
    try std.testing.expectEqual(@as(f64, 10), east.runoff_condition);

    inputs.cell.column = 2;
    inputs.side = .backward;
    const west = (try select(inputs)).?;
    try std.testing.expectEqual(inputs.cell, west.external_face_storage);
    try std.testing.expectEqual(Cell{ .column = 3, .row = 8 }, west.positive_neighbor);
    try std.testing.expectEqual(@as(f64, 1), west.outward_sign);
    try std.testing.expectEqual(@as(f64, 20), west.runoff_condition);

    inputs.axis = .north_south;
    inputs.side = .forward;
    inputs.cell = .{ .column = 3, .row = 9 };
    const south = (try select(inputs)).?;
    try std.testing.expectEqual(Cell{ .column = 3, .row = 10 }, south.external_face_storage);
    try std.testing.expectEqual(@as(f64, 30), south.runoff_condition);

    inputs.side = .backward;
    inputs.cell.row = 7;
    const north = (try select(inputs)).?;
    try std.testing.expectEqual(inputs.cell, north.external_face_storage);
    try std.testing.expectEqual(Cell{ .column = 3, .row = 8 }, north.positive_neighbor);
    try std.testing.expectEqual(@as(f64, 40), north.runoff_condition);
}

test "EROSION external selector skips inactive and interior faces before dormant validation" {
    var inputs = fixture();
    inputs.disturbance_effects = .freeze_thaw;
    inputs.surface_soil_bulk_density_megagrams_per_m3 = std.math.nan(f64);
    try std.testing.expectEqual(@as(?Selection, null), try select(inputs));
    inputs = fixture();
    inputs.cell.column = 3;
    inputs.boundary_runoff.east = std.math.nan(f64);
    try std.testing.expectEqual(@as(?Selection, null), try select(inputs));
}

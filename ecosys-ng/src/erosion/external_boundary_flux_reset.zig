// **A8a DISPOSITION: superseded, do not bind.** This module zeroes the legacy
// per-face `X*ER`/`X*EB` constituent records field by field on the branch
// where no sediment moves. Production has no such storage to go stale:
// `erosion/sediment_routing.zig` `route` `@memset`s all six face and balance
// arrays on entry (`:62`) and skips a cell before writing when runoff is
// negligible or sediment is zero (`:76`), so an inactive face reads as zero
// rather than stale, and the bridges consume those same arrays. Binding this
// would re-zero zeros.
//
// Group C of docs/traceability/erosion_unbound_family_disposition.md

const std = @import("std");
const organic = @import("organic_matter_flux.zig");
const directional_reset = @import("directional_flux_reset.zig");

pub const TopographicConnection = enum { blocked, open }; // IRCHG == 0 / != 0

pub const Inputs = struct {
    topographic_connection: TopographicConnection,
    boundary_runoff_condition: f64, // RCHQF
    cumulative_sediment_megagrams: f64, // XSEDER
    negligible_sediment_megagrams: f64, // ZEROS
};

/// Direct translation of the no-erosion condition and reset in EROSION
/// 1076--1165. Returns true only when the source reset branch executes.
pub fn resetIfNoErosion(inputs: Inputs, dimensions: organic.Dimensions, state: directional_reset.State) !bool {
    if (inputs.topographic_connection == .blocked) {
        try directional_reset.reset(dimensions, state);
        return true;
    }
    if (!std.math.isFinite(inputs.boundary_runoff_condition)) return error.InvalidErosionExternalBoundaryResetInput;
    if (inputs.boundary_runoff_condition == 0) {
        try directional_reset.reset(dimensions, state);
        return true;
    }
    if (!std.math.isFinite(inputs.cumulative_sediment_megagrams) or !std.math.isFinite(inputs.negligible_sediment_megagrams) or inputs.negligible_sediment_megagrams < 0) return error.InvalidErosionExternalBoundaryResetInput;
    if (@abs(inputs.cumulative_sediment_megagrams) <= inputs.negligible_sediment_megagrams) {
        try directional_reset.reset(dimensions, state);
        return true;
    }
    return false;
}

const test_dimensions: organic.Dimensions = .{
    .microbial_substrate_class_count = 1,
    .microbial_functional_group_count = 1,
    .microbial_kinetic_pool_count = 1,
    .residue_class_count = 1,
    .residue_kinetic_pool_count = 1,
    .som_kinetic_pool_count = 1,
};

const Fixture = struct {
    sediment: [directional_reset.sediment_and_capacity_count]f64 = @splat(1),
    fertilizer: [directional_reset.fertilizer_count]f64 = @splat(1),
    exchange: [directional_reset.exchange_surface_count]f64 = @splat(1),
    precipitate: [directional_reset.precipitate_count]f64 = @splat(1),
    organic_fields: [14][1]f64 = @splat(.{1}),

    fn state(self: *Fixture) directional_reset.State {
        return .{
            .sediment_and_capacity = &self.sediment,
            .fertilizer = &self.fertilizer,
            .exchange_surface = &self.exchange,
            .precipitate = &self.precipitate,
            .organic = .{
                .microbial = .{ .carbon_g_per_step = &self.organic_fields[0], .nitrogen_g_per_step = &self.organic_fields[1], .phosphorus_g_per_step = &self.organic_fields[2] },
                .residue = .{ .carbon_g_per_step = &self.organic_fields[3], .nitrogen_g_per_step = &self.organic_fields[4], .phosphorus_g_per_step = &self.organic_fields[5] },
                .adsorbed = .{ .carbon_g_per_step = &self.organic_fields[6], .nitrogen_g_per_step = &self.organic_fields[7], .phosphorus_g_per_step = &self.organic_fields[8], .acetate_g_c_per_step = &self.organic_fields[9] },
                .som = .{ .carbon_g_per_step = &self.organic_fields[10], .colonized_carbon_g_per_step = &self.organic_fields[11], .nitrogen_g_per_step = &self.organic_fields[12], .phosphorus_g_per_step = &self.organic_fields[13] },
            },
        };
    }

    fn expectAll(self: Fixture, expected: f64) !void {
        for (self.sediment) |value| try std.testing.expectEqual(expected, value);
        for (self.fertilizer) |value| try std.testing.expectEqual(expected, value);
        for (self.exchange) |value| try std.testing.expectEqual(expected, value);
        for (self.precipitate) |value| try std.testing.expectEqual(expected, value);
        for (self.organic_fields) |value| try std.testing.expectEqual(expected, value[0]);
    }
};

test "EROSION blocked external boundary resets anomaly topology before dormant values" {
    var fixture: Fixture = .{};
    try std.testing.expect(try resetIfNoErosion(.{
        .topographic_connection = .blocked,
        .boundary_runoff_condition = std.math.nan(f64),
        .cumulative_sediment_megagrams = std.math.nan(f64),
        .negligible_sediment_megagrams = -1,
    }, test_dimensions, fixture.state()));
    try fixture.expectAll(0);
}

test "EROSION zero runoff and negligible signed sediment reset in source order" {
    var fixture: Fixture = .{};
    try std.testing.expect(try resetIfNoErosion(.{
        .topographic_connection = .open,
        .boundary_runoff_condition = 0,
        .cumulative_sediment_megagrams = std.math.nan(f64),
        .negligible_sediment_megagrams = -1,
    }, test_dimensions, fixture.state()));
    try fixture.expectAll(0);

    fixture = .{};
    try std.testing.expect(try resetIfNoErosion(.{
        .topographic_connection = .open,
        .boundary_runoff_condition = -1,
        .cumulative_sediment_megagrams = -1.0e-16,
        .negligible_sediment_megagrams = 1.0e-15,
    }, test_dimensions, fixture.state()));
    try fixture.expectAll(0);
}

test "EROSION active external sediment retains directional flux state" {
    var fixture: Fixture = .{};
    try std.testing.expect(!try resetIfNoErosion(.{
        .topographic_connection = .open,
        .boundary_runoff_condition = -1,
        .cumulative_sediment_megagrams = -2,
        .negligible_sediment_megagrams = 1.0e-15,
    }, test_dimensions, fixture.state()));
    try fixture.expectAll(1);
}

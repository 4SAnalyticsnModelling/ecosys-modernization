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

pub const sediment_and_capacity_count = 5;
pub const fertilizer_count = 8;
pub const exchange_surface_count = 22;
pub const precipitate_count = 14;

pub const State = struct {
    /// XSANER,XSILER,XCLAER,XCECER,XAECER.
    sediment_and_capacity: []f64,
    /// XNH4ER,XNH3ER,XNHUER,XNO3ER and corresponding band fields.
    fertilizer: []f64,
    /// Includes XAL2ER/XFE2ER at source lines 709--710, which have no
    /// corresponding assignment in the preceding active branch.
    exchange_surface: []f64,
    /// Literal source branch clears 14 precipitates but not the 12 Q* silicate
    /// fluxes assigned by lines 619--630.
    precipitate: []f64,
    organic: organic.Outputs,
};

fn finite(values: []const f64) bool {
    for (values) |value| if (!std.math.isFinite(value)) return false;
    return true;
}

fn validateElemental(fluxes: organic.ElementalFluxes, count: usize) bool {
    return fluxes.carbon_g_per_step.len == count and fluxes.nitrogen_g_per_step.len == count and fluxes.phosphorus_g_per_step.len == count and finite(fluxes.carbon_g_per_step) and finite(fluxes.nitrogen_g_per_step) and finite(fluxes.phosphorus_g_per_step);
}

/// Direct translation of EROSION 680--765 for one directional face.
pub fn reset(dimensions: organic.Dimensions, state: State) !void {
    if (state.sediment_and_capacity.len != sediment_and_capacity_count or state.fertilizer.len != fertilizer_count or state.exchange_surface.len != exchange_surface_count or state.precipitate.len != precipitate_count) return error.ErosionDirectionalFluxResetDimensionMismatch;
    inline for (.{ state.sediment_and_capacity, state.fertilizer, state.exchange_surface, state.precipitate }) |values| if (!finite(values)) return error.InvalidErosionDirectionalFluxResetState;
    if (dimensions.microbial_substrate_class_count == 0 or dimensions.microbial_functional_group_count == 0 or dimensions.microbial_kinetic_pool_count == 0 or dimensions.residue_class_count == 0 or dimensions.residue_kinetic_pool_count == 0 or dimensions.som_kinetic_pool_count == 0) return error.ErosionDirectionalFluxResetDimensionMismatch;
    const microbial_count = try std.math.mul(usize, try std.math.mul(usize, dimensions.microbial_substrate_class_count, dimensions.microbial_functional_group_count), dimensions.microbial_kinetic_pool_count);
    const residue_count = try std.math.mul(usize, dimensions.residue_class_count, dimensions.residue_kinetic_pool_count);
    const som_count = try std.math.mul(usize, dimensions.residue_class_count, dimensions.som_kinetic_pool_count);
    if (!validateElemental(state.organic.microbial, microbial_count) or !validateElemental(state.organic.residue, residue_count)) return error.ErosionDirectionalFluxResetDimensionMismatch;
    inline for (.{ state.organic.adsorbed.carbon_g_per_step, state.organic.adsorbed.nitrogen_g_per_step, state.organic.adsorbed.phosphorus_g_per_step, state.organic.adsorbed.acetate_g_c_per_step }) |values| {
        if (values.len != dimensions.residue_class_count) return error.ErosionDirectionalFluxResetDimensionMismatch;
        if (!finite(values)) return error.InvalidErosionDirectionalFluxResetState;
    }
    inline for (.{ state.organic.som.carbon_g_per_step, state.organic.som.colonized_carbon_g_per_step, state.organic.som.nitrogen_g_per_step, state.organic.som.phosphorus_g_per_step }) |values| {
        if (values.len != som_count) return error.ErosionDirectionalFluxResetDimensionMismatch;
        if (!finite(values)) return error.InvalidErosionDirectionalFluxResetState;
    }

    inline for (.{ state.sediment_and_capacity, state.fertilizer, state.exchange_surface, state.precipitate, state.organic.microbial.carbon_g_per_step, state.organic.microbial.nitrogen_g_per_step, state.organic.microbial.phosphorus_g_per_step, state.organic.residue.carbon_g_per_step, state.organic.residue.nitrogen_g_per_step, state.organic.residue.phosphorus_g_per_step, state.organic.adsorbed.carbon_g_per_step, state.organic.adsorbed.nitrogen_g_per_step, state.organic.adsorbed.phosphorus_g_per_step, state.organic.adsorbed.acetate_g_c_per_step, state.organic.som.carbon_g_per_step, state.organic.som.colonized_carbon_g_per_step, state.organic.som.nitrogen_g_per_step, state.organic.som.phosphorus_g_per_step }) |values| @memset(values, 0);
}

const Fixture = struct {
    sediment: [sediment_and_capacity_count]f64 = @splat(1),
    fertilizer: [fertilizer_count]f64 = @splat(1),
    exchange: [exchange_surface_count]f64 = @splat(1),
    precipitate: [precipitate_count]f64 = @splat(1),
    microbial: [3][4]f64 = @splat(@splat(1)),
    residue: [3][2]f64 = @splat(@splat(1)),
    adsorbed: [4][1]f64 = @splat(@splat(1)),
    som: [4][3]f64 = @splat(@splat(1)),

    fn state(self: *Fixture) State {
        return .{
            .sediment_and_capacity = &self.sediment,
            .fertilizer = &self.fertilizer,
            .exchange_surface = &self.exchange,
            .precipitate = &self.precipitate,
            .organic = .{
                .microbial = .{ .carbon_g_per_step = &self.microbial[0], .nitrogen_g_per_step = &self.microbial[1], .phosphorus_g_per_step = &self.microbial[2] },
                .residue = .{ .carbon_g_per_step = &self.residue[0], .nitrogen_g_per_step = &self.residue[1], .phosphorus_g_per_step = &self.residue[2] },
                .adsorbed = .{ .carbon_g_per_step = &self.adsorbed[0], .nitrogen_g_per_step = &self.adsorbed[1], .phosphorus_g_per_step = &self.adsorbed[2], .acetate_g_c_per_step = &self.adsorbed[3] },
                .som = .{ .carbon_g_per_step = &self.som[0], .colonized_carbon_g_per_step = &self.som[1], .nitrogen_g_per_step = &self.som[2], .phosphorus_g_per_step = &self.som[3] },
            },
        };
    }
};

const test_dimensions: organic.Dimensions = .{ .microbial_substrate_class_count = 2, .microbial_functional_group_count = 1, .microbial_kinetic_pool_count = 2, .residue_class_count = 1, .residue_kinetic_pool_count = 2, .som_kinetic_pool_count = 3 };

test "EROSION directional zero branch resets exact scalar and runtime organic topology" {
    var fixture: Fixture = .{};
    try reset(test_dimensions, fixture.state());
    inline for (@typeInfo(Fixture).@"struct".fields) |field| for (@field(fixture, field.name)) |value| {
        if (@TypeOf(value) == f64) try std.testing.expectEqual(@as(f64, 0), value) else for (value) |nested| try std.testing.expectEqual(@as(f64, 0), nested);
    };
}

test "EROSION directional zero branch validates atomically" {
    var fixture: Fixture = .{};
    fixture.som[3][2] = std.math.nan(f64);
    try std.testing.expectError(error.InvalidErosionDirectionalFluxResetState, reset(test_dimensions, fixture.state()));
    try std.testing.expectEqual(@as(f64, 1), fixture.sediment[0]);
    try std.testing.expectEqual(@as(f64, 1), fixture.microbial[0][0]);
}

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
const mineral = @import("mineral_fertilizer_flux.zig");
const exchange = @import("exchange_surface_flux.zig");
const precipitate = @import("precipitate_silicate_flux.zig");
const organic = @import("organic_matter_flux.zig");
const directional_reset = @import("directional_flux_reset.zig");

pub const DirectionalSide = enum { forward, backward };
pub const Neighbor = enum { absent, present };

pub const Inputs = struct {
    side: DirectionalSide, // NN
    neighbor: Neighbor, // N4B>0 and N5B>0
    cumulative_sediment_megagrams: f64, // XSEDER(N,1,...)
    surface_soil_mass_megagrams: f64, // BKVLNU
    mineral_and_fertilizer: mineral.SurfacePools,
    exchange_surface: exchange.SurfacePools,
    precipitate_and_silicate: precipitate.SurfacePools,
    organic_matter: organic.Inputs,
};

pub const Result = struct {
    transported_surface_mass_fraction: f64,
    mineral_and_fertilizer: mineral.Fluxes,
    exchange_surface: exchange.Fluxes,
    precipitate_and_silicate: precipitate.Fluxes,
};

/// Direct coordinator for EROSION 766--902. A null result preserves the two
/// nested source guards without evaluating dormant backward-neighbor inputs.
pub fn calculate(allocator: std.mem.Allocator, inputs: Inputs, organic_outputs: organic.Outputs) !?Result {
    if (inputs.side != .backward or inputs.neighbor != .present) return null;
    const fraction = try mineral.transportedFraction(inputs.cumulative_sediment_megagrams, inputs.surface_soil_mass_megagrams);
    const mineral_flux = try mineral.calculateFromFraction(fraction, inputs.mineral_and_fertilizer);
    const exchange_flux = try exchange.calculate(fraction, inputs.exchange_surface);
    const precipitate_flux = try precipitate.calculate(fraction, inputs.precipitate_and_silicate);
    var organic_inputs = inputs.organic_matter;
    organic_inputs.transported_surface_mass_fraction = fraction;
    try organic.calculate(allocator, organic_inputs, organic_outputs);
    return .{
        .transported_surface_mass_fraction = fraction,
        .mineral_and_fertilizer = mineral_flux,
        .exchange_surface = exchange_flux,
        .precipitate_and_silicate = precipitate_flux,
    };
}

/// Direct binding of EROSION 903--989. Only the backward side with an absent
/// neighbor enters the ELSE branch; all other faces retain their state here.
pub fn resetAbsentNeighbor(side: DirectionalSide, neighbor: Neighbor, dimensions: organic.Dimensions, state: directional_reset.State) !bool {
    if (side != .backward or neighbor != .absent) return false;
    try directional_reset.reset(dimensions, state);
    return true;
}

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}

const OrganicFixture = struct {
    one: [1]f64 = .{1},
    output: [14][1]f64 = @splat(.{9}),

    fn inputs(self: *OrganicFixture) organic.Inputs {
        return .{
            .transported_surface_mass_fraction = 0,
            .dimensions = .{ .microbial_substrate_class_count = 1, .microbial_functional_group_count = 1, .microbial_kinetic_pool_count = 1, .residue_class_count = 1, .residue_kinetic_pool_count = 1, .som_kinetic_pool_count = 1 },
            .microbial = .{ .carbon_g = &self.one, .nitrogen_g = &self.one, .phosphorus_g = &self.one },
            .residue = .{ .carbon_g = &self.one, .nitrogen_g = &self.one, .phosphorus_g = &self.one },
            .adsorbed = .{ .carbon_g = &self.one, .nitrogen_g = &self.one, .phosphorus_g = &self.one, .acetate_g_c = &self.one },
            .som = .{ .carbon_g = &self.one, .colonized_carbon_g = &self.one, .nitrogen_g = &self.one, .phosphorus_g = &self.one },
        };
    }

    fn outputs(self: *OrganicFixture) organic.Outputs {
        return .{
            .microbial = .{ .carbon_g_per_step = &self.output[0], .nitrogen_g_per_step = &self.output[1], .phosphorus_g_per_step = &self.output[2] },
            .residue = .{ .carbon_g_per_step = &self.output[3], .nitrogen_g_per_step = &self.output[4], .phosphorus_g_per_step = &self.output[5] },
            .adsorbed = .{ .carbon_g_per_step = &self.output[6], .nitrogen_g_per_step = &self.output[7], .phosphorus_g_per_step = &self.output[8], .acetate_g_c_per_step = &self.output[9] },
            .som = .{ .carbon_g_per_step = &self.output[10], .colonized_carbon_g_per_step = &self.output[11], .nitrogen_g_per_step = &self.output[12], .phosphorus_g_per_step = &self.output[13] },
        };
    }
};

fn fixture(organic_fixture: *OrganicFixture) Inputs {
    return .{
        .side = .backward,
        .neighbor = .present,
        .cumulative_sediment_megagrams = 2,
        .surface_soil_mass_megagrams = 8,
        .mineral_and_fertilizer = filled(mineral.SurfacePools, 1),
        .exchange_surface = filled(exchange.SurfacePools, 1),
        .precipitate_and_silicate = filled(precipitate.SurfacePools, 1),
        .organic_matter = organic_fixture.inputs(),
    };
}

test "EROSION backward mapping reuses exact domain kernels after source guards" {
    var organic_fixture: OrganicFixture = .{};
    const result = (try calculate(std.testing.allocator, fixture(&organic_fixture), organic_fixture.outputs())).?;
    try std.testing.expectEqual(@as(f64, 0.25), result.transported_surface_mass_fraction);
    try std.testing.expectEqual(@as(f64, 0.25), result.mineral_and_fertilizer.sand_megagrams);
    try std.testing.expectEqual(@as(f64, 0.25), result.exchange_surface.adsorbed_ammonium_non_band_mol);
    try std.testing.expectEqual(@as(f64, 0.25), result.precipitate_and_silicate.monocalcium_phosphate_band_mol);
    for (organic_fixture.output) |value| try std.testing.expectEqual(@as(f64, 0.25), value[0]);
}

test "EROSION backward mapping inactive guards skip dormant invalid inputs" {
    var organic_fixture: OrganicFixture = .{};
    var inputs = fixture(&organic_fixture);
    inputs.neighbor = .absent;
    inputs.surface_soil_mass_megagrams = 0;
    try std.testing.expectEqual(@as(?Result, null), try calculate(std.testing.allocator, inputs, organic_fixture.outputs()));
    for (organic_fixture.output) |value| try std.testing.expectEqual(@as(f64, 9), value[0]);
}

test "EROSION backward mapping validates scalar domains before organic state_update" {
    var organic_fixture: OrganicFixture = .{};
    var inputs = fixture(&organic_fixture);
    inputs.precipitate_and_silicate.monocalcium_phosphate_band_mol = std.math.nan(f64);
    try std.testing.expectError(error.InvalidErosionPrecipitateSilicatePool, calculate(std.testing.allocator, inputs, organic_fixture.outputs()));
    for (organic_fixture.output) |value| try std.testing.expectEqual(@as(f64, 9), value[0]);
}

test "EROSION absent backward neighbor reuses literal anomaly reset topology" {
    var organic_fixture: OrganicFixture = .{};
    var sediment: [directional_reset.sediment_and_capacity_count]f64 = @splat(1);
    var fertilizer: [directional_reset.fertilizer_count]f64 = @splat(1);
    var exchange_fields: [directional_reset.exchange_surface_count]f64 = @splat(1);
    var precipitate_fields: [directional_reset.precipitate_count]f64 = @splat(1);
    const did_reset = try resetAbsentNeighbor(.backward, .absent, organic_fixture.inputs().dimensions, .{
        .sediment_and_capacity = &sediment,
        .fertilizer = &fertilizer,
        .exchange_surface = &exchange_fields,
        .precipitate = &precipitate_fields,
        .organic = organic_fixture.outputs(),
    });
    try std.testing.expect(did_reset);
    for (sediment) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (fertilizer) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (exchange_fields) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (precipitate_fields) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (organic_fixture.output) |value| try std.testing.expectEqual(@as(f64, 0), value[0]);
}

test "EROSION non-backward face skips absent-neighbor reset before validation" {
    var organic_fixture: OrganicFixture = .{};
    var short = [_]f64{std.math.nan(f64)};
    const did_reset = try resetAbsentNeighbor(.forward, .absent, organic_fixture.inputs().dimensions, .{
        .sediment_and_capacity = &short,
        .fertilizer = &short,
        .exchange_surface = &short,
        .precipitate = &short,
        .organic = organic_fixture.outputs(),
    });
    try std.testing.expect(!did_reset);
    try std.testing.expect(std.math.isNan(short[0]));
    for (organic_fixture.output) |value| try std.testing.expectEqual(@as(f64, 9), value[0]);
}

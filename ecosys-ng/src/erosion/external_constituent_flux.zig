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

pub const Inputs = struct {
    cumulative_sediment_megagrams: f64, // XSEDER(N,NN,N5,N4)
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

/// Direct coordinator for active external-boundary EROSION 1178--1312.
pub fn calculate(allocator: std.mem.Allocator, inputs: Inputs, organic_outputs: organic.Outputs) !Result {
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

fn filled(comptime T: type, value: f64) T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| @field(result, field.name) = value;
    return result;
}

test "EROSION active external boundary maps all domains with one source fraction" {
    const one = [_]f64{1};
    var output: [14][1]f64 = @splat(.{9});
    const organic_inputs: organic.Inputs = .{
        .transported_surface_mass_fraction = 0,
        .dimensions = .{ .microbial_substrate_class_count = 1, .microbial_functional_group_count = 1, .microbial_kinetic_pool_count = 1, .residue_class_count = 1, .residue_kinetic_pool_count = 1, .som_kinetic_pool_count = 1 },
        .microbial = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one },
        .residue = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one },
        .adsorbed = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one, .acetate_g_c = &one },
        .som = .{ .carbon_g = &one, .colonized_carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one },
    };
    const organic_outputs: organic.Outputs = .{
        .microbial = .{ .carbon_g_per_step = &output[0], .nitrogen_g_per_step = &output[1], .phosphorus_g_per_step = &output[2] },
        .residue = .{ .carbon_g_per_step = &output[3], .nitrogen_g_per_step = &output[4], .phosphorus_g_per_step = &output[5] },
        .adsorbed = .{ .carbon_g_per_step = &output[6], .nitrogen_g_per_step = &output[7], .phosphorus_g_per_step = &output[8], .acetate_g_c_per_step = &output[9] },
        .som = .{ .carbon_g_per_step = &output[10], .colonized_carbon_g_per_step = &output[11], .nitrogen_g_per_step = &output[12], .phosphorus_g_per_step = &output[13] },
    };
    const result = try calculate(std.testing.allocator, .{
        .cumulative_sediment_megagrams = 3,
        .surface_soil_mass_megagrams = 12,
        .mineral_and_fertilizer = filled(mineral.SurfacePools, 1),
        .exchange_surface = filled(exchange.SurfacePools, 1),
        .precipitate_and_silicate = filled(precipitate.SurfacePools, 1),
        .organic_matter = organic_inputs,
    }, organic_outputs);
    try std.testing.expectEqual(@as(f64, 0.25), result.transported_surface_mass_fraction);
    try std.testing.expectEqual(@as(f64, 0.25), result.mineral_and_fertilizer.nitrate_band_mol);
    try std.testing.expectEqual(@as(f64, 0.25), result.exchange_surface.adsorbed_dihydrogen_phosphate_band_mol);
    try std.testing.expectEqual(@as(f64, 0.25), result.precipitate_and_silicate.potassium_silicate_secondary_mol);
    for (output) |field| try std.testing.expectEqual(@as(f64, 0.25), field[0]);
}

test "EROSION external chemistry failure precedes runtime organic state_update" {
    const one = [_]f64{1};
    var output: [14][1]f64 = @splat(.{9});
    var precipitate_pools = filled(precipitate.SurfacePools, 1);
    precipitate_pools.monocalcium_phosphate_band_mol = std.math.nan(f64);
    try std.testing.expectError(error.InvalidErosionPrecipitateSilicatePool, calculate(std.testing.allocator, .{
        .cumulative_sediment_megagrams = 1,
        .surface_soil_mass_megagrams = 2,
        .mineral_and_fertilizer = filled(mineral.SurfacePools, 1),
        .exchange_surface = filled(exchange.SurfacePools, 1),
        .precipitate_and_silicate = precipitate_pools,
        .organic_matter = .{
            .transported_surface_mass_fraction = 0,
            .dimensions = .{ .microbial_substrate_class_count = 1, .microbial_functional_group_count = 1, .microbial_kinetic_pool_count = 1, .residue_class_count = 1, .residue_kinetic_pool_count = 1, .som_kinetic_pool_count = 1 },
            .microbial = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one },
            .residue = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one },
            .adsorbed = .{ .carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one, .acetate_g_c = &one },
            .som = .{ .carbon_g = &one, .colonized_carbon_g = &one, .nitrogen_g = &one, .phosphorus_g = &one },
        },
    }, .{
        .microbial = .{ .carbon_g_per_step = &output[0], .nitrogen_g_per_step = &output[1], .phosphorus_g_per_step = &output[2] },
        .residue = .{ .carbon_g_per_step = &output[3], .nitrogen_g_per_step = &output[4], .phosphorus_g_per_step = &output[5] },
        .adsorbed = .{ .carbon_g_per_step = &output[6], .nitrogen_g_per_step = &output[7], .phosphorus_g_per_step = &output[8], .acetate_g_c_per_step = &output[9] },
        .som = .{ .carbon_g_per_step = &output[10], .colonized_carbon_g_per_step = &output[11], .nitrogen_g_per_step = &output[12], .phosphorus_g_per_step = &output[13] },
    }));
    for (output) |field| try std.testing.expectEqual(@as(f64, 9), field[0]);
}

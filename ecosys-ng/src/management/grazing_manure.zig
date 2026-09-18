const std = @import("std");
const canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const management = @import("plant_management.zig");
const organic = @import("../soil/organic/initialization.zig");

pub const biochemical_fraction_count: usize = 4;

pub const Products = struct {
    organic_by_biochemical_fraction: [biochemical_fraction_count]canopy.ElementalMass = [_]canopy.ElementalMass{.{}} ** biochemical_fraction_count,
    inorganic_nitrogen_g_n: f64 = 0,
    inorganic_phosphorus_g_p: f64 = 0,
};

pub fn biochemicalFractions(kind: management.HarvestKind) ![biochemical_fraction_count]f64 {
    return switch (kind) {
        .animal_grazing => .{ 0.036, 0.044, 0.630, 0.290 },
        .insect_grazing => .{ 0.138, 0.401, 0.316, 0.145 },
        else => error.NotGrazingEvent,
    };
}

pub fn add(target: *Products, source: Products) !void {
    var next_products = target.*;
    for (0..biochemical_fraction_count) |fraction| inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
        const next = @field(next_products.organic_by_biochemical_fraction[fraction], field.name) +
            @field(source.organic_by_biochemical_fraction[fraction], field.name);
        if (!std.math.isFinite(next) or next < 0) return error.GrazingManureOverflow;
        @field(next_products.organic_by_biochemical_fraction[fraction], field.name) = next;
    };
    const next_n = next_products.inorganic_nitrogen_g_n + source.inorganic_nitrogen_g_n;
    const next_p = next_products.inorganic_phosphorus_g_p + source.inorganic_phosphorus_g_p;
    if (!std.math.isFinite(next_n) or next_n < 0 or !std.math.isFinite(next_p) or next_p < 0)
        return error.GrazingManureOverflow;
    next_products.inorganic_nitrogen_g_n = next_n;
    next_products.inorganic_phosphorus_g_p = next_p;
    target.* = next_products;
}

fn previewOrganic(surface: *const organic.State, cell: usize, products: Products) ![biochemical_fraction_count]organic.ElementPool {
    if (cell >= surface.layer_count) return error.GrazingManureCellOutOfBounds;
    const manure_substrate: usize = 2;
    var next: [biochemical_fraction_count]organic.ElementPool = undefined;
    for (0..biochemical_fraction_count) |fraction| {
        const index = (cell * organic.substrate_count + manure_substrate) * organic.structural_fraction_count + fraction;
        const current = surface.structural[index];
        const input = products.organic_by_biochemical_fraction[fraction];
        next[fraction] = .{
            .carbon_g_c = current.carbon_g_c + input.carbon_g,
            .nitrogen_g_n = current.nitrogen_g_n + input.nitrogen_g,
            .phosphorus_g_p = current.phosphorus_g_p + input.phosphorus_g,
        };
        inline for (.{ next[fraction].carbon_g_c, next[fraction].nitrogen_g_n, next[fraction].phosphorus_g_p }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.GrazingManureOverflow;
    }
    return next;
}

pub fn validateOrganicStateUpdate(surface: *const organic.State, cell: usize, products: Products) !void {
    _ = try previewOrganic(surface, cell, products);
}

pub fn state_updateOrganic(surface: *organic.State, cell: usize, products: Products) !void {
    const next = try previewOrganic(surface, cell, products);
    const manure_substrate: usize = 2;
    for (next, 0..) |pool, fraction| {
        const index = (cell * organic.substrate_count + manure_substrate) * organic.structural_fraction_count + fraction;
        surface.structural[index] = pool;
    }
}

/// Exact GROSUB CMOSC/CSNM/ZSNM/PSNM/ZSNI/PSNI partition. Carbon remains
/// entirely organic; nitrogen and phosphorus split equally between organic
/// manure and inorganic surface inputs.
pub fn partition(kind: management.HarvestKind, returned: canopy.ElementalMass) !Products {
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(returned, field.name)) or @field(returned, field.name) < 0)
            return error.InvalidReturnedGrazingMass;
    const fractions = try biochemicalFractions(kind);
    var result: Products = .{
        .organic_by_biochemical_fraction = [_]canopy.ElementalMass{.{}} ** biochemical_fraction_count,
        .inorganic_nitrogen_g_n = 0.5 * returned.nitrogen_g,
        .inorganic_phosphorus_g_p = 0.5 * returned.phosphorus_g,
    };
    for (fractions, 0..) |fraction, index| result.organic_by_biochemical_fraction[index] = .{
        .carbon_g = fraction * returned.carbon_g,
        .nitrogen_g = fraction * 0.5 * returned.nitrogen_g,
        .phosphorus_g = fraction * 0.5 * returned.phosphorus_g,
    };
    return result;
}

/// Exact standing-dead grazing demand. Animal demand uses horizontal cell
/// area; insect demand uses current standing-dead surface area.
pub fn standingDeadDemandGPerH(
    kind: management.HarvestKind,
    grazer_biomass_g_living_mass_per_m2: f64,
    specific_consumption_g_dry_matter_per_g_living_mass_d: f64,
    horizontal_cell_area_m2: f64,
    standing_dead_area_m2: f64,
    harvested_standing_dead_fraction: f64,
) !f64 {
    inline for (.{
        grazer_biomass_g_living_mass_per_m2,
        specific_consumption_g_dry_matter_per_g_living_mass_d,
        horizontal_cell_area_m2,
        standing_dead_area_m2,
        harvested_standing_dead_fraction,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteStandingDeadGrazingInput;
    if (grazer_biomass_g_living_mass_per_m2 < 0 or specific_consumption_g_dry_matter_per_g_living_mass_d < 0 or
        horizontal_cell_area_m2 <= 0 or standing_dead_area_m2 < 0 or harvested_standing_dead_fraction < 0 or
        harvested_standing_dead_fraction > 1) return error.InvalidStandingDeadGrazingInput;
    const area_m2 = switch (kind) {
        .animal_grazing => horizontal_cell_area_m2,
        .insect_grazing => standing_dead_area_m2,
        else => return error.NotGrazingEvent,
    };
    return grazer_biomass_g_living_mass_per_m2 *
        specific_consumption_g_dry_matter_per_g_living_mass_d *
        0.5 / 24.0 * area_m2 * harvested_standing_dead_fraction;
}

test "GROSUB ruminant and insect returned biomass becomes exact manure fractions" {
    const returned: canopy.ElementalMass = .{ .carbon_g = 100, .nitrogen_g = 10, .phosphorus_g = 2 };
    const animal = try partition(.animal_grazing, returned);
    const insect = try partition(.insect_grazing, returned);
    try std.testing.expectApproxEqAbs(@as(f64, 3.6), animal.organic_by_biochemical_fraction[0].carbon_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 13.8), insect.organic_by_biochemical_fraction[0].carbon_g, 1e-14);
    var animal_organic: canopy.ElementalMass = .{};
    for (animal.organic_by_biochemical_fraction) |mass| {
        animal_organic.carbon_g += mass.carbon_g;
        animal_organic.nitrogen_g += mass.nitrogen_g;
        animal_organic.phosphorus_g += mass.phosphorus_g;
    }
    try std.testing.expectApproxEqAbs(returned.carbon_g, animal_organic.carbon_g, 1e-14);
    try std.testing.expectApproxEqAbs(returned.nitrogen_g, animal_organic.nitrogen_g + animal.inorganic_nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(returned.phosphorus_g, animal_organic.phosphorus_g + animal.inorganic_phosphorus_g_p, 1e-14);
}

test "GROSUB standing dead grazing selects cell or standing surface area" {
    try std.testing.expectApproxEqAbs(@as(f64, 2), try standingDeadDemandGPerH(.animal_grazing, 96, 1, 2, 5, 0.5), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 5), try standingDeadDemandGPerH(.insect_grazing, 96, 1, 2, 5, 0.5), 1e-14);
}

test "grazing manure state_updates four biochemical fractions to the runtime surface cell" {
    var surface = try organic.State.init(std.testing.allocator, 2);
    defer surface.deinit();
    const products = try partition(.animal_grazing, .{ .carbon_g = 100, .nitrogen_g = 10, .phosphorus_g = 2 });
    try state_updateOrganic(&surface, 1, products);
    var state_updateted: canopy.ElementalMass = .{};
    for (0..biochemical_fraction_count) |fraction| {
        const index = (organic.substrate_count + 2) * organic.structural_fraction_count + fraction;
        state_updateted.carbon_g += surface.structural[index].carbon_g_c;
        state_updateted.nitrogen_g += surface.structural[index].nitrogen_g_n;
        state_updateted.phosphorus_g += surface.structural[index].phosphorus_g_p;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 100), state_updateted.carbon_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 5), state_updateted.nitrogen_g, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1), state_updateted.phosphorus_g, 1e-14);
}

//! `landscape_mass_inventory` declarations: tests.
//!
//! Split out of `landscape_mass_inventory.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const grid_module = @import("../state/grid.zig");
const gas = @import("../soil/gas/transport.zig");
const organic = @import("../soil/organic/initialization.zig");
const organic_transport = @import("../soil/organic/transport.zig");
const litter_chemistry = @import("../surface/litter_chemistry.zig");
const litter_fertilizer = @import("../surface/litter_fertilizer.zig");
const audit = @import("mass_balance_audit.zig");
const surface_precipitation = @import("../surface/precipitation.zig");
const canopy_retention = @import("../canopy/energy/precipitation_retention.zig");
const mineral_nitrogen = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const nitrogen_fertilizer = @import("../management/fertilizer_nitrogen_inventory.zig");
const mineral_fertilizer = @import("../management/mineral_fertilizer_inventory.zig");
const soil_chemistry = @import("../soil/solute/chemistry_state.zig");
const solute_transport = @import("../soil/solute/transport.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const zone_classification = @import("../soil/solute/charge_classification.zig");
const plant_roots = @import("../plant/root/plant_root_system.zig");
const group_snow = @import("landscape_mass_inventory_snow.zig");
const group_organic = @import("landscape_mass_inventory_organic.zig");
const group_support = @import("landscape_mass_inventory_support.zig");

test "surface organic all-storage census includes every persistent C N P owner" {
    var state = try organic.State.init(std.testing.allocator, 2);
    defer state.deinit();

    const cell: usize = 1;
    const microbial =
        ((cell * organic.microbial_substrate_count + 4) *
            organic.microbial_population_count) *
        organic.kinetic_fraction_count;
    state.microbial[microbial] = .{
        .carbon_g_c = 1,
        .nitrogen_g_n = 2,
        .phosphorus_g_p = 3,
    };
    const particulate_mobile = cell * organic.substrate_count + 3;
    state.dissolved[particulate_mobile] = .{
        .carbon_g_c = 4,
        .nitrogen_g_n = 5,
        .phosphorus_g_p = 6,
    };
    state.dissolved_acetate_carbon_g_c[particulate_mobile] = 7;
    const humus_mobile = cell * organic.substrate_count + 4;
    state.adsorbed[humus_mobile] = .{
        .carbon_g_c = 8,
        .nitrogen_g_n = 9,
        .phosphorus_g_p = 10,
    };
    state.adsorbed_acetate_carbon_g_c[humus_mobile] = 11;
    const residue =
        (cell * organic.substrate_count + 4) *
        organic.residue_fraction_count;
    state.residue[residue] = .{
        .carbon_g_c = 12,
        .nitrogen_g_n = 13,
        .phosphorus_g_p = 14,
    };

    const selected = try group_organic.aggregateSurfaceOrganicCell(&state, cell);
    try std.testing.expectEqual(@as(f64, 43), selected.residue_carbon_g);
    try std.testing.expectEqual(@as(f64, 29), selected.residue_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 33), selected.residue_phosphorus_g);
    try std.testing.expectEqualDeep(selected, try group_organic.aggregateSurfaceOrganic(&state));
}

test "REDIST snow inventory sums every runtime cell and layer" {
    const ice_density: f64 = 0.92;
    const solid_capacity: f64 = 2.095;
    const liquid_capacity: f64 = 4.19;
    const physical_ice_capacity: f64 = 1.9274;
    const temperature_k: f64 = 250;
    var state = try snow.State.init(std.testing.allocator, 2, 3);
    defer state.deinit();
    for (0..6) |layer| {
        state.active[layer] = layer != 5;
        state.solid_snow_water_equivalent_m3[layer] = 1;
        state.liquid_water_volume_m3[layer] = 2;
        state.vapor_water_equivalent_m3[layer] = 3;
        state.ice_volume_m3[layer] = 4;
        state.temperature_k[layer] = temperature_k;
        state.heat_capacity_megajoules_per_k[layer] =
            solid_capacity * state.solid_snow_water_equivalent_m3[layer] +
            liquid_capacity *
                (state.liquid_water_volume_m3[layer] + state.vapor_water_equivalent_m3[layer]) +
            physical_ice_capacity * state.ice_volume_m3[layer];
        const values = try state.amounts(layer / 3, layer % 3);
        values[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 1;
        values[@intFromEnum(snow.Species.methane_carbon)] = 2;
        values[@intFromEnum(snow.Species.oxygen)] = 3;
        values[@intFromEnum(snow.Species.dinitrogen_nitrogen)] = 4;
        values[@intFromEnum(snow.Species.nitrous_oxide_nitrogen)] = 5;
        values[@intFromEnum(snow.Species.ammonium_nitrogen)] = 6;
        values[@intFromEnum(snow.Species.ammonia_nitrogen)] = 7;
        values[@intFromEnum(snow.Species.nitrate_nitrogen)] = 8;
        values[@intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)] = 9;
        values[@intFromEnum(snow.Species.dihydrogen_phosphate_phosphorus)] = 10;
        values[@intFromEnum(snow.Species.calcium)] = group_snow.test_molar_mass_g_per_mol.ions.calcium;
    }
    const inventory = try group_snow.aggregateSnow(&state, ice_density, group_support.default_latent_heat_of_fusion_megajoules_per_m3, solid_capacity, liquid_capacity, physical_ice_capacity, group_support.default_pure_water_melting_temperature_k, group_snow.test_molar_mass_g_per_mol);
    var partition: group_support.Storage = .{};
    try partition.add(try group_snow.aggregateSnowEnthalpyCell(&state, ice_density, group_support.default_latent_heat_of_fusion_megajoules_per_m3, solid_capacity, liquid_capacity, physical_ice_capacity, group_support.default_pure_water_melting_temperature_k, group_snow.test_molar_mass_g_per_mol, 0));
    try partition.add(try group_snow.aggregateSnowEnthalpyCell(&state, ice_density, group_support.default_latent_heat_of_fusion_megajoules_per_m3, solid_capacity, liquid_capacity, physical_ice_capacity, group_support.default_pure_water_melting_temperature_k, group_snow.test_molar_mass_g_per_mol, 1));
    inline for (std.meta.fields(group_support.Storage)) |field| {
        const expected = @field(inventory, field.name);
        try std.testing.expectApproxEqAbs(expected, @field(partition, field.name), 1e-10 * @max(1, @abs(expected)));
    }
    try std.testing.expectApproxEqAbs(6 * (1 + 2 + 3 + 4 * ice_density), inventory.water_m3, 1e-12);
    // Independent carrier form of the F77 census: solid SWE keeps the `Cs`
    // slope, while physical ice is converted to WE before applying
    // `Ci_phys/rho`. Liquid and vapor remain sensible-only on this reference.
    const melting_k = group_support.default_pure_water_melting_temperature_k;
    const latent = group_support.default_latent_heat_of_fusion_megajoules_per_m3;
    const solid_enthalpy_per_m3 =
        liquid_capacity * melting_k - latent + solid_capacity * (temperature_k - melting_k);
    const physical_ice_enthalpy_per_we_m3 =
        liquid_capacity * melting_k - latent +
        physical_ice_capacity / ice_density * (temperature_k - melting_k);
    const expected_heat_per_layer =
        solid_enthalpy_per_m3 +
        liquid_capacity * temperature_k * (2 + 3) +
        physical_ice_enthalpy_per_we_m3 * (4 * ice_density);
    try std.testing.expectApproxEqAbs(
        6 * expected_heat_per_layer,
        inventory.heat_megajoules,
        1e-9,
    );
    try std.testing.expectEqual(@as(f64, 18), inventory.carbon_dioxide_carbon_g);
    try std.testing.expectEqual(@as(f64, 18), inventory.oxygen_g);
    try std.testing.expectEqual(@as(f64, 54), inventory.dinitrogen_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 78), inventory.ammonium_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 48), inventory.nitrate_nitrogen_g);
    try std.testing.expectEqual(@as(f64, 114), inventory.phosphate_phosphorus_g);
    try std.testing.expectApproxEqAbs(6, inventory.ion_inventory_mol, 1e-12);
    try std.testing.expectApproxEqAbs(6, inventory.calcium_mol, 1e-12);
}

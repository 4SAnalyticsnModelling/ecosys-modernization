//! Atomic production binding for the REDIST tillage block.
//!
//! The legacy kernels use pool-major columns while production owners are
//! layer-major.  This adapter gathers one column, executes the translated
//! kernels in source order, validates elemental/phase closure, and only then
//! scatters to the live owners.  A failed event therefore has no soil-side
//! effects.

const std = @import("std");
const ice_units = @import("../../core/ice_units.zig");
const Grid = @import("../../state/grid.zig").GridState;
const SoilGeometry = @import("../../soil/profile/layer_geometry.zig");
const SoilProperties = @import("../../soil/water/solver_properties.zig");
const Retention = @import("../../soil/water/retention.zig");
const SoilThermal = @import("../../soil/heat/thermal.zig");
const Organic = @import("../../soil/organic/initialization.zig");
const OrganicTransport = @import("../../soil/organic/transport.zig");
const Gas = @import("../../soil/gas/transport.zig");
const Chemistry = @import("../../soil/solute/chemistry_state.zig");
const Aqueous = @import("../../soil/solute/aqueous_network.zig");
const Phosphate = @import("../../soil/solute/phosphate_network.zig");
const CationExchange = @import("../../soil/solute/cation_exchange.zig");
const Geochemistry = @import("../../soil/solute/geochemistry_network.zig");
const SurfaceChemistry = @import("../../surface/litter_chemistry.zig");
const SurfaceGeometry = @import("../../surface/litter_geometry_step.zig");
const FertilizerBand = @import("../../management/fertilizer_band_state.zig");
const FertilizerNitrogen = @import("../../management/fertilizer_nitrogen_inventory.zig");
const SurfaceFertilizer = @import("../../surface/litter_fertilizer.zig");
const MineralFertilizer = @import("../../management/mineral_fertilizer_inventory.zig");
const ReactiveNitrogen = @import("../../soil/nutrients/reactive_nitrogen_state.zig");
const FertilizerDissolution = @import("../../soil/nutrients/fertilizer_dissolution.zig");
const SoluteTransport = @import("../../soil/solute/transport.zig");
const SoluteSpecies = @import("../../soil/solute/transport_species.zig");
const MineralNitrogenTransport = @import("../../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const SurfaceDenitrification = @import("../../surface/denitrification_step.zig");
const SurfaceAqueousTillage = @import("../../surface/aqueous_runoff_transport.zig");
const SurfaceSoluteRouting = @import("../../soil/solute/surface_solute_routing.zig");
const PlantLitterSaltIngress = @import("../../plant/salt/litter_ingress.zig");
const TillageActivity = @import("activity.zig");
const InventorySupport = @import("../../validation/landscape_mass_inventory_support.zig");

const nitrogen_band_reset = @import("nitrogen_band_reset.zig");
const phosphate_band_reset = @import("phosphate_fertilizer_band_reset.zig");
const mixing_initialization = @import("mixing_initialization.zig");
const surface_biomass_transfer = @import("surface_biomass_transfer.zig");
const surface_organic_transfer = @import("surface_organic_transfer.zig");
const surface_chemical_transfer = @import("surface_chemical_transfer.zig");
const layer_accumulation = @import("layer_accumulation.zig");
const physical_redistribution = @import("physical_redistribution.zig");
const chemical_redistribution = @import("chemical_redistribution.zig");
const gas_redistribution = @import("gas_redistribution.zig");
const macropore_scaling = @import("macropore_scaling.zig");
const organic_redistribution = @import("organic_redistribution.zig");
const organic_ledger = @import("organic_ledger_recalculation.zig");
const mineral_incorporation = @import("mineral_incorporation.zig");
const salt_incorporation = @import("salt_incorporation.zig");
const soc_lability = @import("soc_lability.zig");
const fixation_normalization = @import("fixation_normalization.zig");
const soluble_removal = @import("../surface/litter_soluble_removal.zig");
const som_removal = @import("../surface/litter_som_removal.zig");

// REDIST 12487--12554 scales exactly these six macropore aqueous-gas
// coordinates after the 62 mineral-N/P/salt coordinates. Aqueous NH3 is
// carried by the mineral-N transport families, and the gas `band` arrays are
// not members of this source block.
const source_aqueous_gas_species = [_]usize{ 0, 1, 2, 3, 4, 6 };
const macropore_gas_scaling_offset = 62;

fn bindSourceMacroporeScaling(
    families: *[macropore_scaling.macropore_family_count][]f64,
    zero: []f64,
    transport_owners: PreparedTransport,
    macropore_species_major: []f64,
    layers: usize,
) !void {
    if (layers == 0 or zero.len != layers or
        macropore_species_major.len != Gas.species_count * layers or
        transport_owners.macropore_mol.len != SoluteSpecies.AqueousSpecies.count * layers or
        transport_owners.mineral_macropore_mol.len != MineralNitrogenTransport.species_count * layers or
        macropore_gas_scaling_offset + source_aqueous_gas_species.len !=
            macropore_scaling.macropore_family_count)
        return error.TillageMacroporeGasBindingDimensionMismatch;
    for (families) |*family| family.* = zero;
    const nonband_mineral = [_]usize{ 0, 2, 4, 6 };
    const band_mineral = [_]usize{ 1, 3, 5, 7 };
    for (nonband_mineral, 0..) |species, family|
        families[family] = transport_owners.mineral_macropore_mol[species * layers ..][0..layers];
    families[4] = transport_owners.macropore_mol[@intFromEnum(SoluteSpecies.AqueousSpecies.non_band_hpo4) * layers ..][0..layers];
    families[5] = transport_owners.macropore_mol[@intFromEnum(SoluteSpecies.AqueousSpecies.non_band_h2po4) * layers ..][0..layers];
    for (band_mineral, 0..) |species, family|
        families[6 + family] = transport_owners.mineral_macropore_mol[species * layers ..][0..layers];
    families[10] = transport_owners.macropore_mol[@intFromEnum(SoluteSpecies.AqueousSpecies.band_hpo4) * layers ..][0..layers];
    families[11] = transport_owners.macropore_mol[@intFromEnum(SoluteSpecies.AqueousSpecies.band_h2po4) * layers ..][0..layers];
    for (source_scaling_salt_species, 0..) |species, family|
        families[12 + family] = transport_owners.macropore_mol[@intFromEnum(species) * layers ..][0..layers];
    for (source_scaling_nonband_phosphate_species, 0..) |species, family|
        families[45 + family] = transport_owners.macropore_mol[@intFromEnum(species) * layers ..][0..layers];
    for (source_scaling_band_phosphate_species, 0..) |species, family|
        families[53 + family] = transport_owners.macropore_mol[@intFromEnum(species) * layers ..][0..layers];
    for (source_aqueous_gas_species, 0..) |species, family|
        families[macropore_gas_scaling_offset + family] =
            macropore_species_major[species * layers ..][0..layers];
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    grid: *Grid,
    geometry: *const SoilGeometry.State,
    properties: *SoilProperties.State,
    thermal: *SoilThermal.State,
    soil_organic: *Organic.State,
    soil_organic_transport: *OrganicTransport.State,
    surface_organic: *Organic.State,
    soil_gas: *Gas.State,
    surface_gas: *Gas.State,
    soil_chemistry: *Chemistry.State,
    surface_chemistry: *SurfaceChemistry.State,
    surface_geometry: *SurfaceGeometry.State,
    fertilizer_band: *FertilizerBand.State,
    fertilizer_nitrogen: *FertilizerNitrogen.State,
    surface_fertilizer: *SurfaceFertilizer.State,
    mineral_fertilizer: *MineralFertilizer.State,
    reactive_nitrogen: *ReactiveNitrogen.State,
    micropore_solutes: *SoluteTransport.State,
    macropore_solutes: *SoluteTransport.State,
    mineral_nitrogen_transport: *MineralNitrogenTransport.State,
    /// Per-layer accepted reaction parameters. REDIST mixes the five live
    /// Gapon coefficients in FI source order and the next chemistry solve
    /// must consume those mixed values.
    chemistry_layer_parameters: []Chemistry.ReactionParameters,
    surface_denitrification: *SurfaceDenitrification.State,
    surface_solute_transport: *SurfaceSoluteRouting.State,
    plant_litter_salt_ingress: *PlantLitterSaltIngress.State,
    local_activity: *TillageActivity.Sidecar,
    surface_water_m3: []f64,
    surface_ice_m3: []f64,
    surface_heat_capacity_megajoules_per_k: []f64,
    cell_area_m2: []const f64,
    salinity_enabled_by_cell: []const bool,
    minimum_layer_thickness_m: f64,
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    physical_ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
};

const OrganicPacked = struct {
    microbial: [3][]f64,
    residue: [3][]f64,
    soluble: [8][]f64,
    som: [4][]f64,
};

/// REDIST OQCH/OQNH/OQPH/OQAH: macropore dissolved organic pools, packed as
/// component -> substrate -> local layer to match the translated kernels.
const HeldOrganicPacked = [OrganicTransport.components_per_substrate][]f64;

const Inventory = struct { carbon: f64 = 0, nitrogen: f64 = 0, phosphorus: f64 = 0 };

const PreparedPhysicalGas = struct {
    matrix_water_m3: []f64,
    matrix_ice_m3: []f64,
    vapor_m3: []f64,
    temperature_k: []f64,
    reference_bulk_density: []f64,
    field_capacity_fraction: []f64,
    wilting_point_fraction: []f64,
    vertical_saturated_conductivity_m_per_h: []f64,
    lateral_saturated_conductivity_m_per_h: []f64,
    gapon_calcium_ammonium: []f64,
    gapon_calcium_aluminum_and_iron: []f64,
    gapon_calcium_magnesium: []f64,
    gapon_calcium_sodium: []f64,
    gapon_calcium_potassium: []f64,
    sand_mass: []f64,
    silt_mass: []f64,
    clay_mass: []f64,
    cec_inventory: []f64,
    aec_inventory: []f64,
    dry_solid_heat_capacity_megajoules_k: []f64,
    heat_capacity_megajoules_k: []f64,
    gaseous_mass_g: []f64,
    dissolved_mass_g: []f64,
    macropore_dissolved_mass_g: []f64,
    band_dissolved_mass_g: []f64,
    chemistry_inventory: []f64,
    surface_gaseous_mass_g: [Gas.species_count]f64,
    surface_dissolved_mass_g: [Gas.species_count]f64,
    surface_macropore_dissolved_mass_g: [Gas.species_count]f64,
    surface_band_dissolved_mass_g: [Gas.species_count]f64,
    surface_water_m3: f64,
    surface_ice_m3: f64,
    surface_vapor_m3: f64,
    surface_heat_capacity_megajoules_per_k: f64,
    surface_nitrite_g_n: f64,
    surface_dynamic_amount_mol: SurfaceAqueousTillage.TillageSurfaceAmounts,
    plant_litter_salt_pending_mol: []f64,
    surface_mineral_reference_water_m3: f64,
    surface_dry_reference_water_m3: f64,
    surface_chemistry: SurfaceChemistry.Cell,
    surface_fertilizer: SurfaceFertilizer.Inventory,
    mineral_soil: []MineralFertilizer.Inventory,
    mineral_surface: MineralFertilizer.Inventory,
    band_geometry: [3][4][]f64,
    urease_initial: []f64,
    urease_current: []f64,
    nitrification_initial: []f64,
    nitrification_current: []f64,
    surface_geometry_scale: f64,
    micropore_solute_amount_mol: []f64,
    macropore_solute_amount_mol: []f64,
    mineral_nitrogen_matrix_mol: []f64,
    mineral_nitrogen_macropore_mol: []f64,
};

const PreparedTransport = struct {
    micropore_mol: []f64,
    macropore_mol: []f64,
    mineral_matrix_mol: []f64,
    mineral_macropore_mol: []f64,
};

fn allocZero(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

fn allocOrganic(allocator: std.mem.Allocator, layers: usize) !OrganicPacked {
    var result: OrganicPacked = undefined;
    for (0..3) |element| {
        result.microbial[element] = try allocZero(allocator, 126 * layers);
        result.residue[element] = try allocZero(allocator, 10 * layers);
    }
    for (0..8) |pool| result.soluble[pool] = try allocZero(allocator, 5 * layers);
    for (0..4) |pool| result.som[pool] = try allocZero(allocator, 25 * layers);
    return result;
}

fn allocHeldOrganic(allocator: std.mem.Allocator, layers: usize) !HeldOrganicPacked {
    var result: HeldOrganicPacked = undefined;
    for (0..OrganicTransport.components_per_substrate) |component|
        result[component] = try allocZero(allocator, Organic.substrate_count * layers);
    return result;
}

fn elementValue(pool: Organic.ElementPool, element: usize) f64 {
    return switch (element) {
        0 => pool.carbon_g_c,
        1 => pool.nitrogen_g_n,
        2 => pool.phosphorus_g_p,
        else => unreachable,
    };
}

fn setElement(pool: *Organic.ElementPool, element: usize, value: f64) void {
    switch (element) {
        0 => pool.carbon_g_c = value,
        1 => pool.nitrogen_g_n = value,
        2 => pool.phosphorus_g_p = value,
        else => unreachable,
    }
}

fn gatherOrganic(source: *const Organic.State, first_layer: usize, layers: usize, result: OrganicPacked) !void {
    if (first_layer + layers > source.layer_count) return error.TillageOrganicOwnerDimensionMismatch;
    for (0..layers) |layer| {
        const source_layer = first_layer + layer;
        for (0..126) |pool| {
            for (0..3) |element|
                result.microbial[element][pool * layers + layer] = elementValue(source.microbial[source_layer * 126 + pool], element);
        }
        for (0..10) |pool| {
            for (0..3) |element|
                result.residue[element][pool * layers + layer] = elementValue(source.residue[source_layer * 10 + pool], element);
        }
        for (0..5) |pool| {
            for (0..3) |element| {
                result.soluble[element][pool * layers + layer] = elementValue(source.dissolved[source_layer * 5 + pool], element);
                result.soluble[4 + element][pool * layers + layer] = elementValue(source.adsorbed[source_layer * 5 + pool], element);
            }
            result.soluble[3][pool * layers + layer] = source.dissolved_acetate_carbon_g_c[source_layer * 5 + pool];
            result.soluble[7][pool * layers + layer] = source.adsorbed_acetate_carbon_g_c[source_layer * 5 + pool];
        }
        for (0..25) |pool| {
            const source_index = source_layer * 25 + pool;
            result.som[0][pool * layers + layer] = source.structural[source_index].carbon_g_c;
            result.som[1][pool * layers + layer] = source.colonized_structural_carbon_g_c[source_index];
            result.som[2][pool * layers + layer] = source.structural[source_index].nitrogen_g_n;
            result.som[3][pool * layers + layer] = source.structural[source_index].phosphorus_g_p;
        }
    }
}

fn gatherHeldOrganic(
    source: *const OrganicTransport.State,
    first_layer: usize,
    layers: usize,
    result: HeldOrganicPacked,
) !void {
    if (source.layer_count * OrganicTransport.component_count != source.macropore_amount_g.len or
        first_layer + layers > source.layer_count)
        return error.TillageOrganicOwnerDimensionMismatch;
    for (0..layers) |layer| for (0..Organic.substrate_count) |substrate| {
        const source_base = (first_layer + layer) * OrganicTransport.component_count +
            substrate * OrganicTransport.components_per_substrate;
        for (0..OrganicTransport.components_per_substrate) |component|
            result[component][substrate * layers + layer] = source.macropore_amount_g[source_base + component];
    };
}

// `validateOrganicTransportMirror` lived here and asserted that the transport
// state's micropore vector already equalled the profile's dissolved pools on
// entry to tillage. It is deleted rather than kept, because
// `soil/organic/transport.zig:42-63` gives that equality no owner outside the
// TRNSFR export/import window, so the assertion could only ever be true by
// luck. `TILLAGE-ORGANIC-MIRROR-OWNER-001` in the discrepancy register records
// the field-context capture that proved it -- profile `1.9681124921170343e-3` g
// C against mirrored `2.1895057100669314e-6` g C -- and the call site now
// derives the mirror from the profile instead. If this equality ever needs
// asserting again, the place for it is immediately after
// `importMicroporeIntoProfile`, inside the window that owns it.

fn scatterOrganic(destination: *Organic.State, first_layer: usize, layers: usize, values: OrganicPacked) void {
    for (0..layers) |layer| {
        const destination_layer = first_layer + layer;
        for (0..126) |pool| {
            for (0..3) |element|
                setElement(&destination.microbial[destination_layer * 126 + pool], element, values.microbial[element][pool * layers + layer]);
        }
        for (0..10) |pool| {
            for (0..3) |element|
                setElement(&destination.residue[destination_layer * 10 + pool], element, values.residue[element][pool * layers + layer]);
        }
        for (0..5) |pool| {
            for (0..3) |element| {
                setElement(&destination.dissolved[destination_layer * 5 + pool], element, values.soluble[element][pool * layers + layer]);
                setElement(&destination.adsorbed[destination_layer * 5 + pool], element, values.soluble[4 + element][pool * layers + layer]);
            }
            destination.dissolved_acetate_carbon_g_c[destination_layer * 5 + pool] = values.soluble[3][pool * layers + layer];
            destination.adsorbed_acetate_carbon_g_c[destination_layer * 5 + pool] = values.soluble[7][pool * layers + layer];
        }
        for (0..25) |pool| {
            const destination_index = destination_layer * 25 + pool;
            destination.structural[destination_index].carbon_g_c = values.som[0][pool * layers + layer];
            destination.colonized_structural_carbon_g_c[destination_index] = values.som[1][pool * layers + layer];
            destination.structural[destination_index].nitrogen_g_n = values.som[2][pool * layers + layer];
            destination.structural[destination_index].phosphorus_g_p = values.som[3][pool * layers + layer];
        }
    }
}

fn scatterOrganicTransport(
    destination: *OrganicTransport.State,
    first_layer: usize,
    layers: usize,
    matrix: OrganicPacked,
    held: HeldOrganicPacked,
) void {
    for (0..layers) |layer| for (0..Organic.substrate_count) |substrate| {
        const destination_base = (first_layer + layer) * OrganicTransport.component_count +
            substrate * OrganicTransport.components_per_substrate;
        for (0..OrganicTransport.components_per_substrate) |component| {
            destination.micropore_amount_g[destination_base + component] = matrix.soluble[component][substrate * layers + layer];
            destination.macropore_amount_g[destination_base + component] = held[component][substrate * layers + layer];
        }
    };
}

fn organicInventory(values: OrganicPacked) !Inventory {
    var result: Inventory = .{};
    for (0..3) |element| {
        for (values.microbial[element]) |value| try addInventory(&result, element, value);
        for (values.residue[element]) |value| try addInventory(&result, element, value);
    }
    for (values.soluble[0]) |value| try addInventory(&result, 0, value);
    for (values.soluble[1]) |value| try addInventory(&result, 1, value);
    for (values.soluble[2]) |value| try addInventory(&result, 2, value);
    for (values.soluble[3]) |value| try addInventory(&result, 0, value);
    for (values.soluble[4]) |value| try addInventory(&result, 0, value);
    for (values.soluble[5]) |value| try addInventory(&result, 1, value);
    for (values.soluble[6]) |value| try addInventory(&result, 2, value);
    for (values.soluble[7]) |value| try addInventory(&result, 0, value);
    for (values.som[0]) |value| try addInventory(&result, 0, value);
    for (values.som[2]) |value| try addInventory(&result, 1, value);
    for (values.som[3]) |value| try addInventory(&result, 2, value);
    return result;
}

fn heldOrganicInventory(values: HeldOrganicPacked) !Inventory {
    var result: Inventory = .{};
    for (values[0]) |value| try addInventory(&result, 0, value);
    for (values[1]) |value| try addInventory(&result, 1, value);
    for (values[2]) |value| try addInventory(&result, 2, value);
    for (values[3]) |value| try addInventory(&result, 0, value);
    return result;
}

fn addInventory(result: *Inventory, element: usize, value: f64) !void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidTillageOrganicOwner;
    const target = switch (element) {
        0 => &result.carbon,
        1 => &result.nitrogen,
        2 => &result.phosphorus,
        else => unreachable,
    };
    target.* += value;
    if (!std.math.isFinite(target.*)) return error.NonFiniteTillageOrganicInventory;
}

fn addStorageField(result: *InventorySupport.Storage, comptime name: []const u8, value: f64) !void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidTillageActivityInventory;
    const next = @field(result.*, name) + value;
    if (!std.math.isFinite(next)) return error.NonFiniteTillageActivityInventory;
    @field(result.*, name) = next;
}

fn addPhysicalActivity(
    result: *InventorySupport.Storage,
    context: *const Context,
    water_m3: f64,
    ice_m3: f64,
    vapor_m3: f64,
    temperature_k: f64,
) !void {
    inline for (.{ water_m3, ice_m3, vapor_m3, temperature_k }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidTillageActivityInventory;
    const ice_heat_capacity = try ice_units.heatCapacityPerWaterEquivalentM3K(
        context.physical_ice_heat_capacity_megajoules_per_m3_k,
        context.ice_density_megagrams_per_m3,
    );
    try addStorageField(result, "water_m3", water_m3 + ice_m3 + vapor_m3);
    result.heat_megajoules += context.liquid_water_heat_capacity_megajoules_per_m3_k *
        (water_m3 + vapor_m3) * temperature_k + ice_m3 *
        try InventorySupport.frozenWaterEnthalpyPerM3(
            temperature_k,
            context.liquid_water_heat_capacity_megajoules_per_m3_k,
            ice_heat_capacity,
            context.latent_heat_of_fusion_megajoules_per_m3,
            context.pure_water_melting_temperature_k,
        );
    if (!std.math.isFinite(result.heat_megajoules)) return error.NonFiniteTillageActivityInventory;
}

fn iceReferenceCorrection(context: *const Context) !f64 {
    const ice_heat_capacity = try ice_units.heatCapacityPerWaterEquivalentM3K(
        context.physical_ice_heat_capacity_megajoules_per_m3_k,
        context.ice_density_megagrams_per_m3,
    );
    const correction = context.liquid_water_heat_capacity_megajoules_per_m3_k * context.pure_water_melting_temperature_k -
        context.latent_heat_of_fusion_megajoules_per_m3 - ice_heat_capacity * context.pure_water_melting_temperature_k;
    if (!std.math.isFinite(correction)) return error.NonFiniteTillageActivityInventory;
    return correction;
}

fn addSoilPhysicalBeforeActivity(
    result: *InventorySupport.Storage,
    context: *const Context,
    matrix_water_m3: f64,
    matrix_ice_m3: f64,
    vapor_m3: f64,
    bound_water_m3: f64,
    bound_ice_m3: f64,
    temperature_k: f64,
) !void {
    const ice_heat_capacity = try ice_units.heatCapacityPerWaterEquivalentM3K(
        context.physical_ice_heat_capacity_megajoules_per_m3_k,
        context.ice_density_megagrams_per_m3,
    );
    try addStorageField(result, "water_m3", matrix_water_m3 + matrix_ice_m3 + vapor_m3);
    result.heat_megajoules +=
        (context.liquid_water_heat_capacity_megajoules_per_m3_k * (matrix_water_m3 + vapor_m3 + bound_water_m3) +
            ice_heat_capacity * (matrix_ice_m3 + bound_ice_m3)) * temperature_k +
        try iceReferenceCorrection(context) * matrix_ice_m3;
    if (!std.math.isFinite(result.heat_megajoules)) return error.NonFiniteTillageActivityInventory;
}

fn addSoilPhysicalAfterActivity(
    result: *InventorySupport.Storage,
    context: *const Context,
    matrix_water_m3: f64,
    matrix_ice_m3: f64,
    vapor_m3: f64,
    total_heat_capacity_megajoules_per_k: f64,
    temperature_k: f64,
    stationary_mineral_energy_megajoules: f64,
) !void {
    try addStorageField(result, "water_m3", matrix_water_m3 + matrix_ice_m3 + vapor_m3);
    result.heat_megajoules += total_heat_capacity_megajoules_per_k * temperature_k -
        stationary_mineral_energy_megajoules + try iceReferenceCorrection(context) * matrix_ice_m3;
    if (!std.math.isFinite(result.heat_megajoules)) return error.NonFiniteTillageActivityInventory;
}

fn addOrganicTriplet(result: *InventorySupport.Storage, humus: bool, carbon: f64, nitrogen: f64, phosphorus: f64) !void {
    if (humus) {
        try addStorageField(result, "organic_carbon_g", carbon);
        try addStorageField(result, "organic_nitrogen_g", nitrogen);
        try addStorageField(result, "organic_phosphorus_g", phosphorus);
    } else {
        try addStorageField(result, "residue_carbon_g", carbon);
        try addStorageField(result, "residue_nitrogen_g", nitrogen);
        try addStorageField(result, "residue_phosphorus_g", phosphorus);
    }
}

fn addOrganicActivity(result: *InventorySupport.Storage, values: OrganicPacked, layer: usize, layers: usize) !void {
    for (0..126) |pool| {
        const substrate = pool / (Organic.microbial_population_count * Organic.kinetic_fraction_count);
        try addOrganicTriplet(result, substrate == 4, values.microbial[0][pool * layers + layer], values.microbial[1][pool * layers + layer], values.microbial[2][pool * layers + layer]);
    }
    for (0..10) |pool| {
        const substrate = pool / Organic.residue_fraction_count;
        try addOrganicTriplet(result, substrate == 4, values.residue[0][pool * layers + layer], values.residue[1][pool * layers + layer], values.residue[2][pool * layers + layer]);
    }
    for (0..Organic.substrate_count) |substrate| {
        const index = substrate * layers + layer;
        try addOrganicTriplet(result, substrate == 4, values.soluble[0][index] + values.soluble[3][index] + values.soluble[4][index] + values.soluble[7][index], values.soluble[1][index] + values.soluble[5][index], values.soluble[2][index] + values.soluble[6][index]);
        for (0..Organic.structural_fraction_count) |fraction| {
            const structural = (substrate * Organic.structural_fraction_count + fraction) * layers + layer;
            try addOrganicTriplet(result, substrate == 4, values.som[0][structural], values.som[2][structural], values.som[3][structural]);
        }
    }
}

fn addSurfaceOrganicActivity(result: *InventorySupport.Storage, values: OrganicPacked) !void {
    const layers: usize = 1;
    for (0..126) |pool| {
        const substrate = pool / (Organic.microbial_population_count * Organic.kinetic_fraction_count);
        if (substrate == 4) continue;
        try addOrganicTriplet(result, false, values.microbial[0][pool * layers], values.microbial[1][pool * layers], values.microbial[2][pool * layers]);
    }
    for (0..6) |pool| try addOrganicTriplet(result, false, values.residue[0][pool], values.residue[1][pool], values.residue[2][pool]);
    for (0..3) |substrate| {
        try addOrganicTriplet(result, false, values.soluble[0][substrate] + values.soluble[3][substrate] + values.soluble[4][substrate] + values.soluble[7][substrate], values.soluble[1][substrate] + values.soluble[5][substrate], values.soluble[2][substrate] + values.soluble[6][substrate]);
    }
    for (0..25) |pool| try addOrganicTriplet(result, false, values.som[0][pool], values.som[2][pool], values.som[3][pool]);
}

fn addGasActivity(
    result: *InventorySupport.Storage,
    gaseous_species_major: []const f64,
    dissolved_species_major: []const f64,
    layer: usize,
    layers: usize,
) !void {
    if (gaseous_species_major.len != Gas.species_count * layers or dissolved_species_major.len != Gas.species_count * layers)
        return error.TillageActivityDimensionMismatch;
    const amount = struct {
        fn get(g: []const f64, d: []const f64, species: Gas.Species, local: usize, count: usize) f64 {
            const index = @intFromEnum(species) * count + local;
            return g[index] + if (species == .ammonia) 0 else d[index];
        }
    }.get;
    try addStorageField(result, "carbon_dioxide_carbon_g", amount(gaseous_species_major, dissolved_species_major, .carbon_dioxide, layer, layers) + amount(gaseous_species_major, dissolved_species_major, .methane, layer, layers));
    try addStorageField(result, "oxygen_g", amount(gaseous_species_major, dissolved_species_major, .oxygen, layer, layers));
    try addStorageField(result, "hydrogen_g", amount(gaseous_species_major, dissolved_species_major, .hydrogen, layer, layers));
    try addStorageField(result, "dinitrogen_nitrogen_g", amount(gaseous_species_major, dissolved_species_major, .nitrogen, layer, layers) + amount(gaseous_species_major, dissolved_species_major, .nitrous_oxide, layer, layers));
    try addStorageField(result, "ammonium_nitrogen_g", gaseous_species_major[@intFromEnum(Gas.Species.ammonia) * layers + layer]);
}

fn addAqueousActivity(result: *InventorySupport.Storage, species: SoluteSpecies.AqueousSpecies, amount_mol: f64, context: *const Context) !void {
    if (!std.math.isFinite(amount_mol) or amount_mol < 0) return error.InvalidTillageActivityInventory;
    try InventorySupport.addElementMoles(result, InventorySupport.aqueousSpeciesElements(species).scaled(amount_mol));
    const formula = SurfaceAqueousTillage.formula(species);
    try addStorageField(result, "phosphate_phosphorus_g", amount_mol * formula.phosphorus_mol * context.phosphorus_g_per_mol);
    try addStorageField(result, "carbon_dioxide_carbon_g", amount_mol * formula.carbon_mol * context.carbon_g_per_mol);
}

fn addMineralFertilizerActivity(result: *InventorySupport.Storage, value: MineralFertilizer.Inventory, context: *const Context) !void {
    inline for (std.meta.fields(MineralFertilizer.Inventory)) |field|
        if (!std.math.isFinite(@field(value, field.name)) or @field(value, field.name) < 0)
            return error.InvalidTillageActivityInventory;
    const monocalcium = value.broadcast_monocalcium_phosphate_mol + value.banded_monocalcium_phosphate_mol;
    try addStorageField(result, "phosphate_phosphorus_g", context.phosphorus_g_per_mol * (2 * monocalcium + 3 * value.hydroxyapatite_mol));
    try addStorageField(result, "carbon_dioxide_carbon_g", context.carbon_g_per_mol * value.calcite_mol);
    try InventorySupport.addElementMoles(result, .{
        .aluminum = value.aluminum_ground_silicate_mol,
        .iron = value.iron_ground_silicate_mol,
        .calcium = monocalcium + 5 * value.hydroxyapatite_mol + value.calcite_mol + value.gypsum_mol + value.calcium_ground_silicate_mol,
        .magnesium = value.magnesium_ground_silicate_mol,
        .sodium = value.sodium_ground_silicate_mol,
        .potassium = value.potassium_ground_silicate_mol,
        .sulfur = value.gypsum_mol,
        .silicon = 0.75 * (value.aluminum_ground_silicate_mol + value.iron_ground_silicate_mol) + 0.5 * (value.calcium_ground_silicate_mol + value.magnesium_ground_silicate_mol) + 0.25 * (value.sodium_ground_silicate_mol + value.potassium_ground_silicate_mol),
    });
}

fn mineralFertilizerDifference(after: MineralFertilizer.Inventory, before: MineralFertilizer.Inventory) !MineralFertilizer.Inventory {
    var result: MineralFertilizer.Inventory = .{};
    inline for (std.meta.fields(MineralFertilizer.Inventory)) |field| {
        @field(result, field.name) = @field(after, field.name) - @field(before, field.name);
        if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0)
            return error.InvalidTillageActivityInventory;
    }
    return result;
}

fn addGeochemistryActivity(result: *InventorySupport.Storage, storage: []const f64, layers: usize, layer: usize, context: *const Context) !void {
    const at = struct {
        fn get(values: []const f64, count: usize, local: usize, coordinate: usize) f64 {
            return values[(geochemistry_offset + coordinate) * count + local];
        }
    }.get;
    try InventorySupport.addElementMoles(result, .{
        .aluminum = at(storage, layers, layer, 0) + at(storage, layers, layer, 4) + at(storage, layers, layer, 5),
        .iron = at(storage, layers, layer, 1) + at(storage, layers, layer, 6) + at(storage, layers, layer, 7),
        .calcium = at(storage, layers, layer, 2) + at(storage, layers, layer, 3) + at(storage, layers, layer, 8) + at(storage, layers, layer, 9),
        .magnesium = at(storage, layers, layer, 10) + at(storage, layers, layer, 11),
        .sodium = at(storage, layers, layer, 12) + at(storage, layers, layer, 13),
        .potassium = at(storage, layers, layer, 14) + at(storage, layers, layer, 15),
        .sulfur = at(storage, layers, layer, 3),
        .silicon = 0.75 * (at(storage, layers, layer, 4) + at(storage, layers, layer, 5) + at(storage, layers, layer, 6) + at(storage, layers, layer, 7)) + 0.5 * (at(storage, layers, layer, 8) + at(storage, layers, layer, 9) + at(storage, layers, layer, 10) + at(storage, layers, layer, 11)) + 0.25 * (at(storage, layers, layer, 12) + at(storage, layers, layer, 13) + at(storage, layers, layer, 14) + at(storage, layers, layer, 15)),
    });
    try addStorageField(result, "carbon_dioxide_carbon_g", at(storage, layers, layer, 2) * context.carbon_g_per_mol);
}

fn addPhosphateSolidActivity(result: *InventorySupport.Storage, storage: []const f64, base: usize, layers: usize, layer: usize, context: *const Context) !void {
    var amount: [5]f64 = undefined;
    for (&amount, 0..) |*value, coordinate| value.* = storage[(base + coordinate) * layers + layer];
    try addStorageField(result, "phosphate_phosphorus_g", context.phosphorus_g_per_mol * (amount[0] + amount[1] + amount[2] + 3 * amount[3] + 2 * amount[4]));
    try InventorySupport.addElementMoles(result, .{ .aluminum = amount[0], .iron = amount[1], .calcium = amount[2] + 5 * amount[3] + amount[4] });
}

fn addChemistryActivity(result: *InventorySupport.Storage, storage: []const f64, layers: usize, layer: usize, context: *const Context) !void {
    if (storage.len != chemistry_family_count * layers or layer >= layers) return error.TillageActivityDimensionMismatch;
    try addStorageField(result, "ammonium_nitrogen_g", context.nitrogen_g_per_mol *
        (storage[(mineral_n_offset + 0) * layers + layer] + storage[(mineral_n_offset + 1) * layers + layer] + storage[(mineral_n_offset + 2) * layers + layer] + storage[(mineral_n_offset + 3) * layers + layer] + storage[(exchange_offset + 0) * layers + layer] + storage[(exchange_offset + 1) * layers + layer] + storage[(fertilizer_offset + 0) * layers + layer] + storage[(fertilizer_offset + 1) * layers + layer] + storage[(fertilizer_offset + 2) * layers + layer] + storage[(fertilizer_offset + 4) * layers + layer] + storage[(fertilizer_offset + 5) * layers + layer] + storage[(fertilizer_offset + 6) * layers + layer]));
    try addStorageField(result, "nitrate_nitrogen_g", context.nitrogen_g_per_mol *
        (storage[(mineral_n_offset + 4) * layers + layer] + storage[(mineral_n_offset + 5) * layers + layer] + storage[(fertilizer_offset + 3) * layers + layer] + storage[(fertilizer_offset + 7) * layers + layer]) + storage[(mineral_n_offset + 6) * layers + layer] + storage[(mineral_n_offset + 7) * layers + layer]);
    try InventorySupport.addElementMoles(result, .{
        .aluminum = storage[(exchange_offset + 3) * layers + layer],
        .iron = storage[(exchange_offset + 4) * layers + layer],
        .calcium = storage[(exchange_offset + 5) * layers + layer],
        .magnesium = storage[(exchange_offset + 6) * layers + layer],
        .sodium = storage[(exchange_offset + 7) * layers + layer],
        .potassium = storage[(exchange_offset + 8) * layers + layer],
    });
    try addGeochemistryActivity(result, storage, layers, layer, context);
    try addStorageField(result, "phosphate_phosphorus_g", context.phosphorus_g_per_mol *
        (storage[(phosphate_surface_nonband_offset + 3) * layers + layer] + storage[(phosphate_surface_nonband_offset + 4) * layers + layer] + storage[(phosphate_surface_band_offset + 3) * layers + layer] + storage[(phosphate_surface_band_offset + 4) * layers + layer]));
    try addPhosphateSolidActivity(result, storage, phosphate_solid_nonband_offset, layers, layer, context);
    try addPhosphateSolidActivity(result, storage, phosphate_solid_band_offset, layers, layer, context);
    try addAqueousActivity(result, .hydrogen_silicate, storage[hydrogen_silicate_coordinate * layers + layer], context);
    for (salt_transport_species, 0..) |species, coordinate|
        try addAqueousActivity(result, species, storage[(salt_offset + coordinate) * layers + layer], context);
    for (nonband_phosphate_transport_species, 0..) |species, coordinate|
        try addAqueousActivity(result, species, storage[(phosphate_aqueous_nonband_offset + coordinate) * layers + layer], context);
    for (band_phosphate_transport_species, 0..) |species, coordinate|
        try addAqueousActivity(result, species, storage[(phosphate_aqueous_band_offset + coordinate) * layers + layer], context);
}

fn addSurfaceChemicalActivity(
    result: *InventorySupport.Storage,
    core: *const [surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily,
    dynamic: *const [surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily,
    cell: usize,
    incorporated: bool,
    dynamic_salts: bool,
    context: *const Context,
) !void {
    const value = struct {
        fn get(family: surface_chemical_transfer.TransferFamily, index: usize, use_incorporated: bool) f64 {
            return if (use_incorporated) family.incorporated_amount[index] else family.surface_amount[index];
        }
    }.get;
    for (source_aqueous_gas_species, 0..) |species_index, family| {
        const amount = value(core[family], cell, incorporated);
        switch (@as(Gas.Species, @enumFromInt(species_index))) {
            .carbon_dioxide, .methane => try addStorageField(result, "carbon_dioxide_carbon_g", amount),
            .oxygen => try addStorageField(result, "oxygen_g", amount),
            .nitrogen, .nitrous_oxide => try addStorageField(result, "dinitrogen_nitrogen_g", amount),
            .hydrogen => try addStorageField(result, "hydrogen_g", amount),
            .ammonia => unreachable,
        }
    }
    try addStorageField(result, "ammonium_nitrogen_g", context.nitrogen_g_per_mol * (value(core[6], cell, incorporated) + value(core[7], cell, incorporated) + value(core[12], cell, incorporated) + value(core[26], cell, incorporated) + value(core[27], cell, incorporated) + value(core[28], cell, incorporated)));
    try addStorageField(result, "nitrate_nitrogen_g", context.nitrogen_g_per_mol * (value(core[8], cell, incorporated) + value(core[29], cell, incorporated)) + value(core[9], cell, incorporated));
    try addStorageField(result, "phosphate_phosphorus_g", context.phosphorus_g_per_mol * (value(core[10], cell, incorporated) + value(core[11], cell, incorporated) + value(core[24], cell, incorporated) + value(core[25], cell, incorporated)));
    try InventorySupport.addElementMoles(result, .{
        .aluminum = value(core[14], cell, incorporated),
        .iron = value(core[15], cell, incorporated),
        .calcium = value(core[16], cell, incorporated),
        .magnesium = value(core[17], cell, incorporated),
        .sodium = value(core[18], cell, incorporated),
        .potassium = value(core[19], cell, incorporated),
    });
    if (dynamic_salts) for (surface_dynamic_species, 0..) |species, family|
        try addAqueousActivity(result, species, value(dynamic[family], cell, incorporated), context);
}

fn storageDifference(before: InventorySupport.Storage, after: InventorySupport.Storage) !InventorySupport.Storage {
    var result: InventorySupport.Storage = .{};
    inline for (std.meta.fields(InventorySupport.Storage)) |field| {
        @field(result, field.name) = @field(before, field.name) - @field(after, field.name);
    }
    try result.validate();
    return result;
}

fn closeEnough(before: f64, after: f64) bool {
    const scale = @max(@max(@abs(before), @abs(after)), 1.0);
    return @abs(after - before) <= 512.0 * std.math.floatEps(f64) * scale;
}

pub fn incorporatedSurfaceDryHeatCapacity(
    carbon_before_g_c: f64,
    carbon_after_g_c: f64,
    dry_organic_heat_capacity_megajoules_per_g_c_k: f64,
) !f64 {
    if (!std.math.isFinite(carbon_before_g_c) or carbon_before_g_c < 0 or
        !std.math.isFinite(carbon_after_g_c) or carbon_after_g_c < 0 or
        !std.math.isFinite(dry_organic_heat_capacity_megajoules_per_g_c_k) or
        dry_organic_heat_capacity_megajoules_per_g_c_k < 0)
        return error.InvalidTillageSurfaceOrganicInventory;
    const incorporated_carbon_g_c = carbon_before_g_c - carbon_after_g_c;
    if (incorporated_carbon_g_c < 0)
        return error.TillageSurfaceOrganicConservationFailure;
    const heat_capacity = dry_organic_heat_capacity_megajoules_per_g_c_k * incorporated_carbon_g_c;
    if (!std.math.isFinite(heat_capacity))
        return error.NonFiniteTillageSurfaceOrganicHeatCapacity;
    return heat_capacity;
}

/// Rebinds REDIST's accepted extensive XCEC/XAEC inventory to the source
/// BKVL carrier used by STARTE and HOUR1: BKDS * VOLX (Mg). Texture minerals
/// are separate extensive inventories and are not the capacity denominator.
pub fn acceptedExchangeCapacityPerMegagram(
    capacity_mol: f64,
    bulk_density_megagrams_per_m3: f64,
    matrix_bulk_volume_m3: f64,
) !f64 {
    inline for (.{
        capacity_mol,
        bulk_density_megagrams_per_m3,
        matrix_bulk_volume_m3,
    }) |value| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidTillageExchangeCapacityCarrier;
    }
    const soil_mass_megagrams =
        bulk_density_megagrams_per_m3 * matrix_bulk_volume_m3;
    if (!std.math.isFinite(soil_mass_megagrams) or soil_mass_megagrams < 0)
        return error.InvalidTillageExchangeCapacityCarrier;
    if (soil_mass_megagrams == 0) {
        if (capacity_mol != 0)
            return error.UnboundTillageExchangeCapacity;
        return 0;
    }
    const capacity_mol_per_megagram = capacity_mol / soil_mass_megagrams;
    if (!std.math.isFinite(capacity_mol_per_megagram) or
        capacity_mol_per_megagram < 0)
        return error.InvalidTillageExchangeCapacityCarrier;
    return capacity_mol_per_megagram;
}

test "surface dry-organic heat rejects even a sub-ULP signed carbon increase" {
    const before: f64 = 1;
    const after = std.math.nextAfter(f64, before, std.math.inf(f64));
    try std.testing.expectError(
        error.TillageSurfaceOrganicConservationFailure,
        incorporatedSurfaceDryHeatCapacity(before, after, 2.5e-6),
    );
    try std.testing.expectEqual(
        @as(f64, 1.25e-6),
        try incorporatedSurfaceDryHeatCapacity(1, 0.5, 2.5e-6),
    );
}

/// REDIST changes FC/WP, not the retention curve's other controls. Stage the
/// exact mixed endpoints in its constitutive mirror before any live publish.
fn acceptedRetentionCurve(previous: Retention.ResolvedCurve, field_capacity: f64, wilting_point: f64) !Retention.ResolvedCurve {
    inline for (.{ previous.porosity_fraction, field_capacity, wilting_point }) |value|
        if (!std.math.isFinite(value)) return error.InvalidTillageRetentionCurve;
    if (previous.porosity_fraction <= 0 or previous.porosity_fraction > 1 or
        wilting_point <= 0 or field_capacity <= wilting_point or
        field_capacity >= previous.porosity_fraction)
        return error.InvalidTillageRetentionCurve;
    var result = previous;
    result.curve.field_capacity_fraction = field_capacity;
    result.curve.wilting_point_fraction = wilting_point;
    return result;
}

test "tillage retention endpoints remain exact and reject invalid mixed curves" {
    const previous = try Retention.resolve(Retention.compatibilityParameters(), .{
        .porosity_fraction = 0.5,
        .macropore_fraction = 0,
        .sand_fraction = 0.5,
        .clay_fraction = 0.25,
        .organic_carbon_g_per_megagram = 0,
        .bulk_density_megagrams_per_m3 = 1,
        .supplied_field_capacity_fraction = 0.28,
        .supplied_wilting_point_fraction = 0.15,
    }, -0.01, -1.5);
    const wilting = std.math.nextAfter(f64, 0.15, std.math.inf(f64));
    var expected = previous;
    expected.curve.wilting_point_fraction = wilting;
    try std.testing.expectEqualDeep(expected, try acceptedRetentionCurve(previous, 0.28, wilting));
    inline for (.{ @as(f64, 0), 0.15, 0.5, std.math.inf(f64), std.math.nan(f64) }) |field|
        try std.testing.expectError(error.InvalidTillageRetentionCurve, acceptedRetentionCurve(previous, field, 0.15));
    inline for (.{ @as(f64, 0), -0.1, 0.28, std.math.inf(f64), std.math.nan(f64) }) |point|
        try std.testing.expectError(error.InvalidTillageRetentionCurve, acceptedRetentionCurve(previous, 0.28, point));
}

/// Executes the complete translated REDIST tillage sequence for one cell.
/// Persistent owners are untouched unless the whole sequence and its local
/// conservation checks succeed.
pub fn apply(context: *Context, cell: usize, tillage_depth_m: f64, mixing_fraction: f64) !void {
    if (cell >= context.grid.cell_count or context.geometry.cell_count != context.grid.cell_count or
        context.properties.layer_count != context.grid.layer_count or context.thermal.layer_volume_m3.len != context.grid.layer_count or
        context.properties.matrix_bulk_volume_m3.len != context.grid.layer_count or context.properties.bulk_density_megagrams_per_m3.len != context.grid.layer_count or
        context.properties.retention_curve.len != context.grid.layer_count or context.properties.field_capacity_fraction.len != context.grid.layer_count or context.properties.wilting_point_fraction.len != context.grid.layer_count or
        context.soil_organic.layer_count != context.grid.layer_count or context.surface_organic.layer_count != context.grid.cell_count or
        context.soil_organic_transport.layer_count != context.grid.layer_count or
        context.soil_organic_transport.micropore_amount_g.len != context.grid.layer_count * OrganicTransport.component_count or
        context.soil_organic_transport.macropore_amount_g.len != context.grid.layer_count * OrganicTransport.component_count or
        context.soil_organic_transport.boundary_net_flux_g.len != context.grid.layer_count * OrganicTransport.component_count or
        context.soil_gas.cell_count != context.grid.layer_count or context.surface_gas.cell_count != context.grid.cell_count or
        context.soil_chemistry.cell_count != context.grid.layer_count or context.surface_chemistry.cells.len != context.grid.cell_count or context.surface_geometry.cell_count != context.grid.cell_count or
        context.fertilizer_band.cell_count != context.grid.cell_count or context.fertilizer_band.layer_capacity != context.grid.soil_layer_capacity or
        context.fertilizer_nitrogen.cell_count != context.grid.cell_count or context.fertilizer_nitrogen.layer_capacity != context.grid.soil_layer_capacity or
        context.surface_fertilizer.cells.len != context.grid.cell_count or context.mineral_fertilizer.cell_count != context.grid.cell_count or context.mineral_fertilizer.layer_capacity != context.grid.soil_layer_capacity or
        context.reactive_nitrogen.layer_count != context.grid.layer_count or
        context.micropore_solutes.cell_count != context.grid.layer_count or context.micropore_solutes.species_count != SoluteSpecies.AqueousSpecies.count or
        context.macropore_solutes.cell_count != context.grid.layer_count or context.macropore_solutes.species_count != SoluteSpecies.AqueousSpecies.count or
        context.mineral_nitrogen_transport.cell_count != context.grid.layer_count or
        context.chemistry_layer_parameters.len != context.grid.layer_count or
        context.surface_denitrification.cell_count != context.grid.cell_count or
        context.plant_litter_salt_ingress.cell_count != context.grid.cell_count or
        context.plant_litter_salt_ingress.soil_layer_capacity != context.grid.soil_layer_capacity or
        context.surface_water_m3.len != context.grid.cell_count or context.surface_ice_m3.len != context.grid.cell_count or
        context.surface_heat_capacity_megajoules_per_k.len != context.grid.cell_count or
        context.cell_area_m2.len != context.grid.cell_count or
        context.salinity_enabled_by_cell.len != context.grid.cell_count)
        return error.TillageRuntimeDimensionMismatch;
    try context.local_activity.validateLayout(context.grid.cell_count, context.grid.soil_layer_capacity);
    if (!context.local_activity.attempt_active) return error.TillageActivityAttemptNotActive;
    if (!std.math.isFinite(tillage_depth_m) or tillage_depth_m <= 0 or !std.math.isFinite(mixing_fraction) or mixing_fraction < 0 or mixing_fraction > 1 or
        !std.math.isFinite(context.minimum_layer_thickness_m) or context.minimum_layer_thickness_m < 0 or
        !std.math.isFinite(context.dry_organic_heat_capacity_megajoules_per_g_c_k) or context.dry_organic_heat_capacity_megajoules_per_g_c_k <= 0 or
        !std.math.isFinite(context.liquid_water_heat_capacity_megajoules_per_m3_k) or context.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or
        !std.math.isFinite(context.surface_heat_capacity_megajoules_per_k[cell]) or context.surface_heat_capacity_megajoules_per_k[cell] < 0 or
        !std.math.isFinite(context.cell_area_m2[cell]) or context.cell_area_m2[cell] <= 0 or
        !std.math.isFinite(context.latent_heat_of_fusion_megajoules_per_m3) or context.latent_heat_of_fusion_megajoules_per_m3 <= 0 or
        !std.math.isFinite(context.pure_water_melting_temperature_k) or context.pure_water_melting_temperature_k <= 0 or
        !std.math.isFinite(context.carbon_g_per_mol) or context.carbon_g_per_mol <= 0 or
        !std.math.isFinite(context.nitrogen_g_per_mol) or context.nitrogen_g_per_mol <= 0 or
        !std.math.isFinite(context.phosphorus_g_per_mol) or context.phosphorus_g_per_mol <= 0)
        return error.InvalidTillageRuntimeInput;
    _ = ice_units.heatCapacityPerWaterEquivalentM3K(
        context.physical_ice_heat_capacity_megajoules_per_m3_k,
        context.ice_density_megagrams_per_m3,
    ) catch return error.InvalidTillageRuntimeInput;
    try context.micropore_solutes.validateFinite();
    try context.macropore_solutes.validateFinite();
    try context.mineral_nitrogen_transport.validate();
    const first_soil_layer = context.geometry.first_active_layer[cell];
    const active_count = context.geometry.active_layer_count[cell];
    const layers = context.grid.soil_layer_capacity;
    if (active_count == 0 or first_soil_layer + active_count > layers) return error.TillageRuntimeDimensionMismatch;
    const last_soil_layer = first_soil_layer + active_count - 1;
    const global_first = cell * layers;
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const prepared_transport = try gatherTransportOwners(
        allocator,
        context,
        cell * layers,
        layers,
    );

    var soil_organic = try allocOrganic(allocator, layers);
    var surface_organic = try allocOrganic(allocator, 1);
    const held_organic = try allocHeldOrganic(allocator, layers);
    try gatherOrganic(context.soil_organic, global_first, layers, soil_organic);
    try gatherOrganic(context.surface_organic, cell, 1, surface_organic);
    // TILLAGE-ORGANIC-MIRROR-OWNER-001: derive the micropore mirror from the
    // profile rather than assert it already agrees.
    //
    // `soil/organic/transport.zig:42-63` states the ownership: the profile's
    // `dissolved` pools are authoritative and `exportMicroporeFromProfile`
    // copies them into the transport state "immediately before TRNSFR", with
    // `importMicroporeIntoProfile` returning the accepted result. Outside that
    // window the mirror is stale BY DESIGN, and roughly twenty production
    // modules write the profile pools against the three that write the mirror.
    // Asserting equality here asserted something the owner never promised.
    //
    // It held for 2,532 hours only because an upstream defect kept the quantity
    // near zero: with the litter layer read at residual saturation
    // (`LITTER-RETENTION-THETWR-001`) the litter/soil interface at
    // `hourly_heat_water_solute.zig:8140-8143` moved almost no dissolved
    // organic carbon into layer 0, so the drift stayed under a 512-eps
    // tolerance. Corrected, the interface moves real DOC and the measured
    // mirror was 899x low: profile `1.9681124921170343e-3` g C against mirrored
    // `2.1895057100669314e-6` g C at layer 0, substrate 1, against a
    // `1.1368683772161603e-13` tolerance.
    //
    // Only the macropore half of the transport state is read below
    // (`gatherHeldOrganic`), which the transport state solely owns; nothing
    // reads the micropore mirror between here and the write-back at `:382-383`.
    // So deriving it is the one-owner fix, and it is a no-op in every hour where
    // the two already agreed. `exportMicroporeFromProfile` validates each pool
    // finite and non-negative as it copies, which preserves the only safety the
    // assertion carried.
    try context.soil_organic_transport.exportMicroporeFromProfile(context.soil_organic);
    try gatherHeldOrganic(context.soil_organic_transport, global_first, layers, held_organic);
    const organic_before_soil = try organicInventory(soil_organic);
    const organic_before_surface = try organicInventory(surface_organic);
    const organic_before_held = try heldOrganicInventory(held_organic);

    const thickness = try allocator.dupe(f64, context.properties.layer_thickness_m[global_first .. global_first + layers]);
    const bottoms = try allocator.dupe(f64, context.properties.layer_bottom_depth_m[global_first .. global_first + layers]);
    const remaining = 1.0 - mixing_fraction;

    // 1-2. Gather every authoritative chemistry/fertilizer/band owner before
    // collapsing spatial bands. All writes remain arena-private until commit.
    const chemistry_storage = try allocZero(allocator, chemistry_family_count * layers);
    var band_geometry: [3][4][]f64 = undefined;
    inline for (std.enums.values(FertilizerBand.Family), 0..) |family, family_index| {
        const view = try context.fertilizer_band.geometry(cell, family);
        band_geometry[family_index][0] = try allocator.dupe(f64, view.band_depth_m);
        band_geometry[family_index][1] = try allocator.dupe(f64, view.band_width_m);
        band_geometry[family_index][2] = try allocator.dupe(f64, view.band_volume_fraction);
        band_geometry[family_index][3] = try allocator.dupe(f64, view.non_band_volume_fraction);
    }
    try gatherChemistry(context, cell, global_first, layers, band_geometry, prepared_transport, chemistry_storage);
    const band_resets = try applyBandResets(allocator, layers, first_soil_layer, tillage_depth_m, remaining, bottoms, &band_geometry, chemistry_storage);
    try collapseResetMacroporeBands(
        prepared_transport,
        layers,
        first_soil_layer,
        tillage_depth_m,
        bottoms,
        band_resets,
    );

    // 3. Exact workspace initialization.
    var cell_values: [7][]f64 = undefined;
    for (&cell_values) |*values| values.* = try allocZero(allocator, context.grid.cell_count);
    const disturbance_flags = try allocator.alloc(u8, context.grid.cell_count);
    @memset(disturbance_flags, 0);
    const scalar_totals = try allocZero(allocator, mixing_initialization.scalar_accumulator_count);
    var work_microbe: [3][]f64 = undefined;
    var work_residue: [3][]f64 = undefined;
    for (0..3) |e| {
        work_microbe[e] = try allocZero(allocator, 126);
        work_residue[e] = try allocZero(allocator, 10);
    }
    const work_soluble = try allocZero(allocator, 40);
    const work_som = try allocZero(allocator, 100);
    const applied_fraction = try mixing_initialization.initializeCell(cell, remaining, .{ .ammonium_band_depth_m = cell_values[0], .ammonium_band_extent_m = cell_values[1], .nitrate_band_depth_m = cell_values[2], .nitrate_band_extent_m = cell_values[3], .phosphate_band_depth_m = cell_values[4], .phosphate_band_extent_m = cell_values[5], .disturbance_flag = disturbance_flags, .soil_energy_megajoules = cell_values[6] }, .{ .scalar_accumulators = scalar_totals, .microbial_carbon_g_c = work_microbe[0], .microbial_nitrogen_g_n = work_microbe[1], .microbial_phosphorus_g_p = work_microbe[2], .residue_carbon_g_c = work_residue[0], .residue_nitrogen_g_n = work_residue[1], .residue_phosphorus_g_p = work_residue[2], .soluble_fraction_totals = work_soluble, .som_fraction_totals = work_som });
    if (applied_fraction != mixing_fraction) return error.TillageMixingFractionMismatch;

    const physical_gas = try applyOrderedSequence(allocator, context, cell, layers, global_first, first_soil_layer, last_soil_layer, tillage_depth_m, mixing_fraction, remaining, thickness, bottoms, &soil_organic, &surface_organic, held_organic, work_microbe, work_residue, work_soluble, work_som, chemistry_storage, band_geometry, prepared_transport);

    const retention_curves = try allocator.alloc(Retention.ResolvedCurve, layers);
    for (retention_curves, 0..) |*curve, layer| curve.* = try acceptedRetentionCurve(
        context.properties.retention_curve[global_first + layer],
        physical_gas.field_capacity_fraction[layer],
        physical_gas.wilting_point_fraction[layer],
    );

    // REDIST mixes XCEC/XAEC as extensive mol inventories. Derive every
    // mass-specific mirror before the non-failing commit so the next SOLUTE
    // call and the next HOUR1 material refresh consume the same accepted base.
    const cec_per_megagram = try allocator.alloc(f64, layers);
    const aec_per_megagram = try allocator.alloc(f64, layers);
    for (0..layers) |layer| {
        const index = global_first + layer;
        cec_per_megagram[layer] = try acceptedExchangeCapacityPerMegagram(
            physical_gas.cec_inventory[layer],
            context.properties.bulk_density_megagrams_per_m3[index],
            context.properties.matrix_bulk_volume_m3[index],
        );
        aec_per_megagram[layer] = try acceptedExchangeCapacityPerMegagram(
            physical_gas.aec_inventory[layer],
            context.properties.bulk_density_megagrams_per_m3[index],
            context.properties.matrix_bulk_volume_m3[index],
        );
    }

    const organic_after_soil = try organicInventory(soil_organic);
    const organic_after_surface = try organicInventory(surface_organic);
    const organic_after_held = try heldOrganicInventory(held_organic);
    if (!closeEnough(organic_before_soil.carbon + organic_before_surface.carbon + organic_before_held.carbon, organic_after_soil.carbon + organic_after_surface.carbon + organic_after_held.carbon) or
        !closeEnough(organic_before_soil.nitrogen + organic_before_surface.nitrogen + organic_before_held.nitrogen, organic_after_soil.nitrogen + organic_after_surface.nitrogen + organic_after_held.nitrogen) or
        !closeEnough(organic_before_soil.phosphorus + organic_before_surface.phosphorus + organic_before_held.phosphorus, organic_after_soil.phosphorus + organic_after_surface.phosphorus + organic_after_held.phosphorus))
    {
        return error.TillageOrganicConservationFailure;
    }

    // Commit is deliberately non-failing: every kernel and closure check has
    // completed on private storage.
    scatterOrganic(context.soil_organic, global_first, layers, soil_organic);
    scatterOrganic(context.surface_organic, cell, 1, surface_organic);
    scatterOrganicTransport(context.soil_organic_transport, global_first, layers, soil_organic, held_organic);
    @memcpy(context.grid.matrix_liquid_water_m3[global_first .. global_first + layers], physical_gas.matrix_water_m3);
    @memcpy(context.grid.matrix_ice_water_m3[global_first .. global_first + layers], physical_gas.matrix_ice_m3);
    @memcpy(context.grid.water_vapor_volume_m3[global_first .. global_first + layers], physical_gas.vapor_m3);
    @memcpy(context.grid.soil_temperature_k[global_first .. global_first + layers], physical_gas.temperature_k);
    for (0..layers) |layer| {
        const index = global_first + layer;
        context.grid.liquid_water_m3[index] = physical_gas.matrix_water_m3[layer] + context.grid.macropore_liquid_water_m3[index];
        context.grid.ice_water_m3[index] = physical_gas.matrix_ice_m3[layer] + context.grid.macropore_ice_water_m3[index];
    }
    scatterTransportOwnersAssumeValid(context, global_first, layers, physical_gas);
    @memcpy(context.properties.reference_bulk_density_megagrams_per_m3[global_first .. global_first + layers], physical_gas.reference_bulk_density);
    @memcpy(context.properties.field_capacity_fraction[global_first .. global_first + layers], physical_gas.field_capacity_fraction);
    @memcpy(context.properties.wilting_point_fraction[global_first .. global_first + layers], physical_gas.wilting_point_fraction);
    @memcpy(context.properties.retention_curve[global_first .. global_first + layers], retention_curves);
    @memcpy(context.properties.lateral_saturated_hydraulic_conductivity_m_per_h[global_first .. global_first + layers], physical_gas.lateral_saturated_conductivity_m_per_h);
    for (0..layers) |layer| {
        const global = global_first + layer;
        context.properties.mualem_van_genuchten_parameters[global].saturated_hydraulic_conductivity_m_per_h = physical_gas.vertical_saturated_conductivity_m_per_h[layer];
        const selectivity = &context.chemistry_layer_parameters[global].cation_exchange_parameters.selectivity;
        selectivity.calcium_ammonium = physical_gas.gapon_calcium_ammonium[layer];
        selectivity.calcium_aluminum_and_iron = physical_gas.gapon_calcium_aluminum_and_iron[layer];
        selectivity.calcium_magnesium = physical_gas.gapon_calcium_magnesium[layer];
        selectivity.calcium_sodium = physical_gas.gapon_calcium_sodium[layer];
        selectivity.calcium_potassium = physical_gas.gapon_calcium_potassium[layer];
    }
    @memcpy(context.properties.sand_mass_megagrams[global_first .. global_first + layers], physical_gas.sand_mass);
    @memcpy(context.properties.silt_mass_megagrams[global_first .. global_first + layers], physical_gas.silt_mass);
    @memcpy(context.properties.clay_mass_megagrams[global_first .. global_first + layers], physical_gas.clay_mass);
    @memcpy(context.properties.cation_exchange_capacity_mol[global_first .. global_first + layers], physical_gas.cec_inventory);
    @memcpy(context.properties.anion_exchange_capacity_mol[global_first .. global_first + layers], physical_gas.aec_inventory);
    @memcpy(context.properties.cation_exchange_capacity_mol_per_megagram[global_first .. global_first + layers], cec_per_megagram);
    @memcpy(context.properties.anion_exchange_capacity_mol_per_megagram[global_first .. global_first + layers], aec_per_megagram);
    for (0..layers) |layer| {
        context.chemistry_layer_parameters[global_first + layer]
            .cation_exchange_capacity_mol_charge_per_megagram =
            cec_per_megagram[layer];
    }
    for (0..layers) |layer| {
        const index = global_first + layer;
        context.thermal.dry_solid_heat_capacity_megajoules_per_m3_k[index] = physical_gas.dry_solid_heat_capacity_megajoules_k[layer] / context.thermal.layer_volume_m3[index];
        context.thermal.total_heat_capacity_megajoules_per_m3_k[index] = physical_gas.heat_capacity_megajoules_k[layer] / context.thermal.layer_volume_m3[index];
        const first_mass = index * Gas.species_count;
        @memcpy(context.soil_gas.gaseous_mass_g[first_mass .. first_mass + Gas.species_count], physical_gas.gaseous_mass_g[layer * Gas.species_count ..][0..Gas.species_count]);
        @memcpy(context.soil_gas.dissolved_mass_g[first_mass .. first_mass + Gas.species_count], physical_gas.dissolved_mass_g[layer * Gas.species_count ..][0..Gas.species_count]);
        @memcpy(context.soil_gas.macropore_dissolved_mass_g[first_mass .. first_mass + Gas.species_count], physical_gas.macropore_dissolved_mass_g[layer * Gas.species_count ..][0..Gas.species_count]);
        @memcpy(context.soil_gas.band_dissolved_mass_g[first_mass .. first_mass + Gas.species_count], physical_gas.band_dissolved_mass_g[layer * Gas.species_count ..][0..Gas.species_count]);
        context.soil_gas.temperature_k[index] = physical_gas.temperature_k[layer];
    }
    const surface_mass = cell * Gas.species_count;
    @memcpy(context.surface_gas.gaseous_mass_g[surface_mass .. surface_mass + Gas.species_count], &physical_gas.surface_gaseous_mass_g);
    @memcpy(context.surface_gas.dissolved_mass_g[surface_mass .. surface_mass + Gas.species_count], &physical_gas.surface_dissolved_mass_g);
    @memcpy(context.surface_gas.macropore_dissolved_mass_g[surface_mass .. surface_mass + Gas.species_count], &physical_gas.surface_macropore_dissolved_mass_g);
    @memcpy(context.surface_gas.band_dissolved_mass_g[surface_mass .. surface_mass + Gas.species_count], &physical_gas.surface_band_dissolved_mass_g);
    scatterChemistryAssumeValid(context, cell, global_first, layers, physical_gas.matrix_water_m3, context.properties.layer_volume_m3[global_first .. global_first + layers], physical_gas.band_geometry, physical_gas.chemistry_inventory);
    inline for (std.enums.values(FertilizerBand.Family), 0..) |family, family_index| {
        const view = context.fertilizer_band.geometry(cell, family) catch unreachable;
        @memcpy(view.band_depth_m, physical_gas.band_geometry[family_index][0]);
        @memcpy(view.band_width_m, physical_gas.band_geometry[family_index][1]);
        @memcpy(view.band_volume_fraction, physical_gas.band_geometry[family_index][2]);
        @memcpy(view.non_band_volume_fraction, physical_gas.band_geometry[family_index][3]);
    }
    context.surface_chemistry.cells[cell] = physical_gas.surface_chemistry;
    context.surface_denitrification.nitrite_g_n[cell] = physical_gas.surface_nitrite_g_n;
    context.surface_fertilizer.cells[cell] = physical_gas.surface_fertilizer;
    @memcpy(context.mineral_fertilizer.soil[cell * layers ..][0..layers], physical_gas.mineral_soil);
    context.mineral_fertilizer.surface[cell] = physical_gas.mineral_surface;
    @memcpy(context.fertilizer_nitrogen.initial_urease_inhibition_fraction[global_first .. global_first + layers], physical_gas.urease_initial);
    @memcpy(context.fertilizer_nitrogen.current_urease_inhibition_fraction[global_first .. global_first + layers], physical_gas.urease_current);
    @memcpy(context.reactive_nitrogen.initial_nitrification_inhibition_activity[global_first .. global_first + layers], physical_gas.nitrification_initial);
    @memcpy(context.reactive_nitrogen.current_nitrification_inhibition_activity[global_first .. global_first + layers], physical_gas.nitrification_current);
    inline for (.{ "water_retention_capacity_m3", "dry_litter_volume_m3", "expanded_total_volume_m3", "dry_mass_megagrams", "pore_volume_m3", "air_volume_m3" }) |name| @field(context.surface_geometry.*, name)[cell] *= physical_gas.surface_geometry_scale;
    // REDIST soil mixing raises IFLGS. The next accepted HOUR1 consumes only
    // that REDIST cycle's DORGCC against the checkpointed ORGCCX owner.
    context.surface_geometry.retention_refresh_pending[cell] = 1;
    context.surface_chemistry.mineral_reference_water_m3[cell] = physical_gas.surface_mineral_reference_water_m3;
    context.surface_chemistry.dry_reference_water_m3[cell] = physical_gas.surface_dry_reference_water_m3;
    context.surface_water_m3[cell] = physical_gas.surface_water_m3;
    context.surface_ice_m3[cell] = physical_gas.surface_ice_m3;
    context.surface_heat_capacity_megajoules_per_k[cell] = physical_gas.surface_heat_capacity_megajoules_per_k;
    context.surface_gas.water_vapor_mol[cell] = physical_gas.surface_vapor_m3 / 18.0e-6;
    SurfaceAqueousTillage.commitTillageSurfaceAmounts(
        context.surface_chemistry,
        context.surface_solute_transport,
        cell,
        physical_gas.surface_water_m3,
        if (physical_gas.surface_water_m3 > 0)
            physical_gas.surface_water_m3
        else
            physical_gas.surface_dry_reference_water_m3,
        physical_gas.surface_dynamic_amount_mol,
    ) catch unreachable;
    const pending_per_cell = (layers + 1) * PlantLitterSaltIngress.salt_count;
    @memcpy(
        context.plant_litter_salt_ingress.pending_mol[cell * pending_per_cell ..][0..pending_per_cell],
        physical_gas.plant_litter_salt_pending_mol,
    );
}

const OrderedSequenceContext = struct {
    allocator: std.mem.Allocator,
    context: *const Context,
    cell: usize,
    layers: usize,
    global_first: usize,
    first_soil_layer: usize,
    last_soil_layer: usize,
    tillage_depth_m: f64,
    mixing_fraction: f64,
    remaining: f64,
    thickness: []const f64,
    bottoms: []const f64,
    soil: *OrganicPacked,
    surface: *OrganicPacked,
    held_organic: HeldOrganicPacked,
    work_microbe: [3][]f64,
    work_residue: [3][]f64,
    work_soluble: []f64,
    work_som: []f64,
    chemistry_storage: []f64,
    band_geometry: [3][4][]f64,
    transport_owners: PreparedTransport,
};

const OrderedSurfacePhase = struct {
    dynamic_salts: bool,
    mixable_before: []InventorySupport.Storage,
    mixable_after: []InventorySupport.Storage,
    surface_mixable_before: InventorySupport.Storage,
    surface_mixable_after: InventorySupport.Storage,
    plant_litter_salt_pending: []f64,
    plant_litter_salt_pending_before: []f64,
    biomass: surface_biomass_transfer.Result,
    core: [surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily,
    dynamic: [surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily,
    phase: [23][]f64,
    surface_mass_offset: usize,
    incorporated_surface_dry_heat_capacity: f64,
    incorporated_surface_ice: f64,
    incorporated_surface_vapor: f64,
};

noinline fn prepareOrderedSurfacePhase(sequence: *const OrderedSequenceContext) !OrderedSurfacePhase {
    const allocator = sequence.allocator;
    const context = sequence.context;
    const cell = sequence.cell;
    const layers = sequence.layers;
    const surface = sequence.surface;
    const work_microbe = sequence.work_microbe;
    const work_residue = sequence.work_residue;
    const work_soluble = sequence.work_soluble;
    const work_som = sequence.work_som;
    const remaining = sequence.remaining;
    const dynamic_salts = context.salinity_enabled_by_cell[cell];
    const mixable_before = try allocator.alloc(InventorySupport.Storage, layers);
    const mixable_after = try allocator.alloc(InventorySupport.Storage, layers);
    @memset(mixable_before, .{});
    @memset(mixable_after, .{});
    var surface_mixable_before: InventorySupport.Storage = .{};
    const surface_mixable_after: InventorySupport.Storage = .{};
    const ice_heat_capacity_per_water_equivalent_m3_k = try ice_units.heatCapacityPerWaterEquivalentM3K(
        context.physical_ice_heat_capacity_megajoules_per_m3_k,
        context.ice_density_megagrams_per_m3,
    );
    const pending_per_cell = (layers + 1) * PlantLitterSaltIngress.salt_count;
    const pending_first = cell * pending_per_cell;
    const plant_litter_salt_pending = try allocator.dupe(
        f64,
        context.plant_litter_salt_ingress.pending_mol[pending_first .. pending_first + pending_per_cell],
    );
    const plant_litter_salt_pending_before = try allocator.dupe(f64, plant_litter_salt_pending);
    for (plant_litter_salt_pending) |amount|
        if (!std.math.isFinite(amount) or amount < 0) return error.InvalidPendingPlantLitterSaltInventory;

    const surface_organic_before = try organicInventory(surface.*);
    try addSurfaceOrganicActivity(&surface_mixable_before, surface.*);
    // REDIST 11625--11842 never places surface PALPO/PFEPO/PCAP* or
    // PALOH/PFEOH/PCAC/PCAS in an incorporation temporary. Those solid
    // precipitates retain their surface owner; only their soil-layer
    // counterparts enter the later 12063--12444 mixing accumulation.
    // Accordingly they are absent from this transfer-only sampler rather
    // than being aliased to any aqueous coordinate.
    try addPhysicalActivity(
        &surface_mixable_before,
        context,
        context.surface_water_m3[cell],
        context.surface_ice_m3[cell],
        context.surface_gas.water_vapor_mol[cell] * 18.0e-6,
        context.surface_gas.temperature_k[cell],
    );
    surface_mixable_before.heat_megajoules += context.dry_organic_heat_capacity_megajoules_per_g_c_k *
        surface_organic_before.carbon * context.surface_gas.temperature_k[cell];
    try addMineralFertilizerActivity(&surface_mixable_before, context.mineral_fertilizer.surface[cell], context);

    // 4. Surface microbial biomass transfer.
    // REDIST reads the accepted VHCP owner and compares it with the STARTS
    // residue threshold VHCPRX=8.380E-05*AREA. Recomputing a partial capacity
    // here used to omit vapor and passing zero disabled this source gate.
    const surface_heat_capacity = context.surface_heat_capacity_megajoules_per_k[cell];
    const residue_heat_capacity_threshold = 8.380e-05 * context.cell_area_m2[cell];
    const biomass = try surface_biomass_transfer.transfer(
        surface_heat_capacity,
        residue_heat_capacity_threshold,
        remaining,
        .{ .layer_count = 1, .carbon_g_c = surface.microbial[0], .nitrogen_g_n = surface.microbial[1], .phosphorus_g_p = surface.microbial[2] },
        .{ .carbon_g_c = work_microbe[0], .nitrogen_g_n = work_microbe[1], .phosphorus_g_p = work_microbe[2] },
    );

    // 5. Surface residue, soluble, adsorbed, and structural transfer. STARTS
    // initializes surface OQ*H to zero, TRNSFR only produces OQ*H in soil,
    // and restart reads it only for soil layers. Keep that proven invariant
    // explicit rather than inventing a surface owner or aliasing matrix OQ*.
    var humic: [4][3]f64 = @splat(@splat(0));
    var surface_residue_carbon: [3]f64 = @splat(0);
    const organic_totals = try surface_organic_transfer.transfer(
        biomass.surface_remaining_fraction,
        .{
            .layer_count = 1,
            .surface_residue_carbon_g_c = &surface_residue_carbon,
            .soluble = soluble_removal.Pools{
                .residue_carbon_g_c = surface.residue[0][0..6],
                .residue_nitrogen_g_n = surface.residue[1][0..6],
                .residue_phosphorus_g_p = surface.residue[2][0..6],
                .dissolved_carbon_g_c = surface.soluble[0][0..3],
                .dissolved_acetate_g_c = surface.soluble[3][0..3],
                .dissolved_nitrogen_g_n = surface.soluble[1][0..3],
                .dissolved_phosphorus_g_p = surface.soluble[2][0..3],
                .humic_dissolved_carbon_g_c = &humic[0],
                .humic_dissolved_acetate_g_c = &humic[1],
                .humic_dissolved_nitrogen_g_n = &humic[2],
                .humic_dissolved_phosphorus_g_p = &humic[3],
                .adsorbed_carbon_g_c = surface.soluble[4][0..3],
                .adsorbed_acetate_g_c = surface.soluble[7][0..3],
                .adsorbed_nitrogen_g_n = surface.soluble[5][0..3],
                .adsorbed_phosphorus_g_p = surface.soluble[6][0..3],
            },
            .som = som_removal.Pools{
                .layer_count = 1,
                .soil_organic_carbon_g_c = surface.som[0][0..15],
                .colonized_soil_organic_carbon_g_c = surface.som[1][0..15],
                .soil_organic_nitrogen_g_n = surface.som[2][0..15],
                .soil_organic_phosphorus_g_p = surface.som[3][0..15],
            },
        },
        .{ .residue_carbon_g_c = work_residue[0][0..6], .residue_nitrogen_g_n = work_residue[1][0..6], .residue_phosphorus_g_p = work_residue[2][0..6], .soluble_by_pool_and_fraction = work_soluble[0..36], .som_by_pool_m_and_fraction = work_som[0..60] },
        .{
            .remaining_carbon_g_c = biomass.remaining_carbon_g_c,
            .remaining_nitrogen_g_n = biomass.remaining_nitrogen_g_n,
            .remaining_phosphorus_g_p = biomass.remaining_phosphorus_g_p,
            .charcoal_remaining_carbon_g_c = biomass.charcoal_remaining_carbon_g_c,
            .charcoal_remaining_nitrogen_g_n = biomass.charcoal_remaining_nitrogen_g_n,
            .charcoal_remaining_phosphorus_g_p = biomass.charcoal_remaining_phosphorus_g_p,
        },
    );
    const surface_organic_after = try organicInventory(surface.*);
    const incorporated_surface_dry_heat_capacity = try incorporatedSurfaceDryHeatCapacity(
        surface_organic_before.carbon,
        surface_organic_after.carbon,
        context.dry_organic_heat_capacity_megajoules_per_g_c_k,
    );

    // 6. Surface chemical/phase transfer. Every transferable gas, mineral-N,
    // phosphate, exchange, fertilizer, and 42-coordinate aqueous salt family
    // is gathered from its authoritative owner before the destructive kernel.
    const cells = context.grid.cell_count;
    var core: [surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily = undefined;
    const core_surface = try allocZero(allocator, surface_chemical_transfer.core_family_count * cells);
    const core_incorporated = try allocZero(allocator, surface_chemical_transfer.core_family_count * cells);
    for (&core, 0..) |*family, index| family.* = .{ .surface_amount = core_surface[index * cells ..][0..cells], .incorporated_amount = core_incorporated[index * cells ..][0..cells] };
    var dynamic: [surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily = undefined;
    const dynamic_surface = try allocZero(allocator, surface_chemical_transfer.dynamic_salt_family_count * cells);
    const dynamic_incorporated = try allocZero(allocator, surface_chemical_transfer.dynamic_salt_family_count * cells);
    for (&dynamic, 0..) |*family, index| family.* = .{ .surface_amount = dynamic_surface[index * cells ..][0..cells], .incorporated_amount = dynamic_incorporated[index * cells ..][0..cells] };
    const surface_mass_offset = cell * Gas.species_count;
    for (source_aqueous_gas_species, 0..) |species, family| core[family].surface_amount[cell] = context.surface_gas.dissolved_mass_g[surface_mass_offset + species];
    try gatherSurfaceTransfers(context, cell, dynamic_salts, &core, &dynamic);
    for (plant_litter_salt_dynamic_coordinates, 0..) |coordinate, salt| {
        dynamic[coordinate].surface_amount[cell] += plant_litter_salt_pending[salt];
        if (!std.math.isFinite(dynamic[coordinate].surface_amount[cell]))
            return error.NonFiniteTillageSurfaceChemistryInventory;
        plant_litter_salt_pending[salt] = 0;
    }
    try addSurfaceChemicalActivity(
        &surface_mixable_before,
        &core,
        &dynamic,
        cell,
        false,
        dynamic_salts,
        context,
    );
    var core_before: [surface_chemical_transfer.core_family_count]f64 = undefined;
    var dynamic_before: [surface_chemical_transfer.dynamic_salt_family_count]f64 = undefined;
    for (&core_before, 0..) |*value, family| value.* = core[family].surface_amount[cell];
    for (&dynamic_before, 0..) |*value, family| value.* = dynamic[family].surface_amount[cell];
    var phase: [23][]f64 = undefined;
    for (&phase) |*values| values.* = try allocZero(allocator, cells);
    phase[0][cell] = context.surface_water_m3[cell];
    phase[1][cell] = context.surface_ice_m3[cell];
    phase[2][cell] = context.surface_gas.water_vapor_mol[cell] * 18.0e-6;
    phase[9][cell] = context.surface_gas.temperature_k[cell];
    phase[11][cell] = context.surface_heat_capacity_megajoules_per_k[cell];
    phase[20][cell] = context.surface_fertilizer.cells[cell].initial_urease_inhibition_fraction;
    phase[21][cell] = context.surface_fertilizer.cells[cell].current_urease_inhibition_fraction;
    const chemical_totals: surface_chemical_transfer.OrganicTotals = .{
        .remaining_carbon_g_c = organic_totals.remaining_carbon_g_c,
        .remaining_nitrogen_g_n = organic_totals.remaining_nitrogen_g_n,
        .charcoal_remaining_carbon_g_c = organic_totals.charcoal_remaining_carbon_g_c,
        .charcoal_remaining_nitrogen_g_n = organic_totals.charcoal_remaining_nitrogen_g_n,
    };
    try surface_chemical_transfer.transferCell(allocator, cell, biomass.surface_remaining_fraction, dynamic_salts, chemical_totals, .{
        .dry_organic_heat_capacity_megajoules_per_g_c_k = context.dry_organic_heat_capacity_megajoules_per_g_c_k,
        .liquid_water_heat_capacity_megajoules_per_m3_k = context.liquid_water_heat_capacity_megajoules_per_m3_k,
        .physical_ice_heat_capacity_megajoules_per_m3_k = context.physical_ice_heat_capacity_megajoules_per_m3_k,
        .ice_density_megagrams_per_m3 = context.ice_density_megagrams_per_m3,
    }, .{
        .core_families = &core,
        .dynamic_salt_families = if (dynamic_salts) &dynamic else &.{},
        .surface_water_m3 = phase[0],
        .surface_ice_m3 = phase[1],
        .surface_vapor_m3 = phase[2],
        .incorporated_water_m3 = phase[3],
        .incorporated_energy_megajoules = phase[4],
        .organic_carbon_g_c = phase[5],
        .organic_nitrogen_g_n = phase[6],
        .charcoal_organic_carbon_g_c = phase[7],
        .charcoal_organic_nitrogen_g_n = phase[8],
        .residue_organic_carbon_g_c = phase[10],
        .surface_temperature_k = phase[9],
        .surface_heat_capacity_megajoules_k = phase[11],
        .heat_input_megajoules = phase[12],
        .soil_heat_megajoules = phase[13],
        .residue_volume_m3 = phase[14],
        .total_volume_m3 = phase[15],
        .auxiliary_volume_m3 = phase[16],
        .urea_surface_maximum = phase[17],
        .urea_incorporated_maximum = phase[18],
        .fixation_maximum = phase[19],
        .urea_surface_candidate = phase[20],
        .urea_incorporated_candidate = phase[21],
        .fixation_candidate = phase[22],
    });
    for (core_before, 0..) |before, family| if (!closeEnough(before, core[family].surface_amount[cell] + core[family].incorporated_amount[cell])) return error.TillageSurfaceChemicalConservationFailure;
    if (dynamic_salts) for (dynamic_before, 0..) |before, family| if (!closeEnough(before, dynamic[family].surface_amount[cell] + dynamic[family].incorporated_amount[cell])) return error.TillageSurfaceChemicalConservationFailure;
    // REDIST scales surface ice and vapor but omits their recipients. Route
    // them to the same soil phases and transfer their sensible energy.
    const incorporated_surface_ice = context.surface_ice_m3[cell] - phase[1][cell];
    const incorporated_surface_vapor = context.surface_gas.water_vapor_mol[cell] * 18.0e-6 - phase[2][cell];
    phase[4][cell] += (incorporated_surface_dry_heat_capacity +
        ice_heat_capacity_per_water_equivalent_m3_k * incorporated_surface_ice +
        context.liquid_water_heat_capacity_megajoules_per_m3_k * incorporated_surface_vapor) * phase[9][cell];
    // The kernel's legacy HFLXD scratch reads aggregate ORGC, whereas the
    // modern authoritative owner is the actual accepted before/after carbon
    // inventory (including retained source-excluded pools). Reconstruct VHCP
    // and its internal surface-to-soil heat transfer from those live owners.
    phase[11][cell] = context.dry_organic_heat_capacity_megajoules_per_g_c_k * surface_organic_after.carbon +
        context.liquid_water_heat_capacity_megajoules_per_m3_k * (phase[0][cell] + phase[2][cell]) +
        ice_heat_capacity_per_water_equivalent_m3_k * phase[1][cell];
    phase[12][cell] = -incorporated_surface_dry_heat_capacity * phase[9][cell];
    phase[13][cell] = phase[12][cell];

    return .{
        .dynamic_salts = dynamic_salts,
        .mixable_before = mixable_before,
        .mixable_after = mixable_after,
        .surface_mixable_before = surface_mixable_before,
        .surface_mixable_after = surface_mixable_after,
        .plant_litter_salt_pending = plant_litter_salt_pending,
        .plant_litter_salt_pending_before = plant_litter_salt_pending_before,
        .biomass = biomass,
        .core = core,
        .dynamic = dynamic,
        .phase = phase,
        .surface_mass_offset = surface_mass_offset,
        .incorporated_surface_dry_heat_capacity = incorporated_surface_dry_heat_capacity,
        .incorporated_surface_ice = incorporated_surface_ice,
        .incorporated_surface_vapor = incorporated_surface_vapor,
    };
}

const OrderedRedistributionPhase = struct {
    intensive: [physical_redistribution.intensive_family_count]physical_redistribution.Family,
    inventory: [physical_redistribution.inventory_family_count]physical_redistribution.Family,
    matrix_water: []f64,
    matrix_ice: []f64,
    vapor: []f64,
    temperature: []f64,
    urease_initial: []f64,
    urease_current: []f64,
    nitrification_initial: []f64,
    nitrification_current: []f64,
    last_mixed: usize,
    mixing_depth: f64,
    heat_capacity: []f64,
    mineral_heat_capacity: []f64,
    temperature_before_physical: []f64,
    mineral_heat_capacity_before: []f64,
    chemistry_same_scope_gain: []f64,
    gaseous_values: []f64,
    dissolved_values: []f64,
    macropore_values: []f64,
    band_values: []f64,
    gas_same_scope_gain: []f64,
    organic_same_scope_gain: []InventorySupport.Storage,
    mineral_soil: []MineralFertilizer.Inventory,
    mineral_soil_before: []MineralFertilizer.Inventory,
    mineral_surface: MineralFertilizer.Inventory,
};

/// Concrete output of ordered phases 7-8. This is the complete private state
/// consumed by chemistry/gas/organic redistribution; no authoritative owner
/// is published until `finishOrderedSequence` accepts the returned phase.
const OrderedPhysicalPhase = struct {
    intensive: [physical_redistribution.intensive_family_count]physical_redistribution.Family,
    inventory: [physical_redistribution.inventory_family_count]physical_redistribution.Family,
    matrix_water: []f64,
    matrix_ice: []f64,
    vapor: []f64,
    temperature: []f64,
    urease_initial: []f64,
    urease_current: []f64,
    nitrification_initial: []f64,
    nitrification_current: []f64,
    last_mixed: usize,
    mixing_depth: f64,
    heat_capacity: []f64,
    mineral_heat_capacity: []f64,
    temperature_before_physical: []f64,
    mineral_heat_capacity_before: []f64,
    fixation_total: f64,
    maximum_a: f64,
    maximum_b: f64,
    maximum_c: f64,
    organic_totals_packed: OrganicPacked,
    ti_zero: []f64,
};

const ChemistryRedistributionPhase = struct {
    same_scope_gain: []f64,
    micropore_before_mol: []f64,
    macropore_before_mol: []f64,
    mineral_matrix_before_mol: []f64,
    mineral_macropore_before_mol: []f64,
};

const GasRedistributionPhase = struct {
    gaseous_values: []f64,
    dissolved_values: []f64,
    macropore_values: []f64,
    band_values: []f64,
    same_scope_gain: []f64,
};

const OrganicRedistributionPhase = struct {
    same_scope_gain: []InventorySupport.Storage,
};

const SurfaceIncorporationPhase = struct {
    cumulative_fixation: f64,
    mineral_soil: []MineralFertilizer.Inventory,
    mineral_soil_before: []MineralFertilizer.Inventory,
    mineral_surface: MineralFertilizer.Inventory,
};

noinline fn finishOrderedSequence(
    sequence: *const OrderedSequenceContext,
    surface_phase: *const OrderedSurfacePhase,
    redistribution: *const OrderedRedistributionPhase,
    core: *[surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily,
    dynamic: *[surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily,
) !PreparedPhysicalGas {
    const allocator = sequence.allocator;
    const context = sequence.context;
    const cell = sequence.cell;
    const layers = sequence.layers;
    const global_first = sequence.global_first;
    const first_soil_layer = sequence.first_soil_layer;
    const mixing_fraction = sequence.mixing_fraction;
    const bottoms = sequence.bottoms;
    const thickness = sequence.thickness;
    const soil = sequence.soil;
    const surface = sequence.surface;
    const chemistry_storage = sequence.chemistry_storage;
    const band_geometry = sequence.band_geometry;
    const transport_owners = sequence.transport_owners;
    const mixable_before = surface_phase.mixable_before;
    const mixable_after = surface_phase.mixable_after;
    const surface_mixable_before = surface_phase.surface_mixable_before;
    var surface_mixable_after = surface_phase.surface_mixable_after;
    const plant_litter_salt_pending = surface_phase.plant_litter_salt_pending;
    const biomass = surface_phase.biomass;
    const phase = surface_phase.phase;
    const dynamic_salts = surface_phase.dynamic_salts;
    const surface_mass_offset = surface_phase.surface_mass_offset;
    const last_mixed = redistribution.last_mixed;
    const mixing_depth = redistribution.mixing_depth;
    const matrix_water = redistribution.matrix_water;
    const matrix_ice = redistribution.matrix_ice;
    const vapor = redistribution.vapor;
    const temperature = redistribution.temperature;
    const heat_capacity = redistribution.heat_capacity;
    const mineral_heat_capacity = redistribution.mineral_heat_capacity;
    const mineral_heat_capacity_before = redistribution.mineral_heat_capacity_before;
    const temperature_before_physical = redistribution.temperature_before_physical;
    const inventory = redistribution.inventory;
    const intensive = redistribution.intensive;
    const chemistry_same_scope_gain = redistribution.chemistry_same_scope_gain;
    const gaseous_values = redistribution.gaseous_values;
    const dissolved_values = redistribution.dissolved_values;
    const macropore_values = redistribution.macropore_values;
    const band_values = redistribution.band_values;
    const gas_same_scope_gain = redistribution.gas_same_scope_gain;
    const organic_same_scope_gain = redistribution.organic_same_scope_gain;
    const mineral_soil = redistribution.mineral_soil;
    const mineral_soil_before = redistribution.mineral_soil_before;
    const mineral_surface = redistribution.mineral_surface;
    const urease_initial = redistribution.urease_initial;
    const urease_current = redistribution.urease_current;
    const nitrification_initial = redistribution.nitrification_initial;
    const nitrification_current = redistribution.nitrification_current;

    // Producer-derived local activity contains only cross-scope owners.
    const zero_gas = try allocZero(allocator, Gas.species_count * layers);
    for (0..layers) |layer| {
        try addSoilPhysicalAfterActivity(
            &mixable_after[layer],
            context,
            matrix_water[layer],
            matrix_ice[layer],
            vapor[layer],
            heat_capacity[layer],
            temperature[layer],
            mineral_heat_capacity_before[layer] * temperature_before_physical[layer],
        );
        try addStorageField(&mixable_after[layer], "sand_megagrams", inventory[0].layer_values[layer]);
        try addStorageField(&mixable_after[layer], "silt_megagrams", inventory[1].layer_values[layer]);
        try addStorageField(&mixable_after[layer], "clay_megagrams", inventory[2].layer_values[layer]);
        try addStorageField(&mixable_after[layer], "cation_exchange_capacity_mol", inventory[3].layer_values[layer]);
        try addStorageField(&mixable_after[layer], "anion_exchange_capacity_mol", inventory[4].layer_values[layer]);
        try addOrganicActivity(&mixable_after[layer], soil.*, layer, layers);
        try addChemistryActivity(&mixable_after[layer], chemistry_storage, layers, layer, context);
        try addGasActivity(&mixable_after[layer], gaseous_values, dissolved_values, layer, layers);
        for (plant_litter_salt_transport_species, 0..) |species, salt|
            try addAqueousActivity(
                &mixable_after[layer],
                species,
                plant_litter_salt_pending[(layer + 1) * PlantLitterSaltIngress.salt_count + salt],
                context,
            );
        try addMineralFertilizerActivity(
            &mixable_after[layer],
            try mineralFertilizerDifference(mineral_soil[layer], mineral_soil_before[layer]),
            context,
        );
        var correction: InventorySupport.Storage = .{};
        try addChemistryActivity(&correction, chemistry_same_scope_gain, layers, layer, context);
        try addGasActivity(&correction, zero_gas, gas_same_scope_gain, layer, layers);
        try correction.add(organic_same_scope_gain[layer]);
        mixable_after[layer] = try storageDifference(mixable_after[layer], correction);
        try mixable_before[layer].validate();
        try mixable_after[layer].validate();
    }

    const surface_organic_after_activity = try organicInventory(surface.*);
    try addSurfaceOrganicActivity(&surface_mixable_after, surface.*);
    try addPhysicalActivity(
        &surface_mixable_after,
        context,
        phase[0][cell],
        phase[1][cell],
        phase[2][cell],
        phase[9][cell],
    );
    surface_mixable_after.heat_megajoules += context.dry_organic_heat_capacity_megajoules_per_g_c_k *
        surface_organic_after_activity.carbon * phase[9][cell];
    try addSurfaceChemicalActivity(&surface_mixable_after, core, dynamic, cell, false, dynamic_salts, context);
    try addMineralFertilizerActivity(&surface_mixable_after, mineral_surface, context);
    const surface_incorporated_activity = try storageDifference(surface_mixable_before, surface_mixable_after);
    try context.local_activity.stageCell(
        cell,
        first_soil_layer,
        last_mixed,
        mixing_depth,
        mixing_fraction,
        bottoms,
        thickness,
        context.minimum_layer_thickness_m,
        mixable_before,
        surface_mixable_before,
        surface_incorporated_activity,
        mixable_after,
        surface_mixable_after,
    );

    const remaining_surface_aqueous_carrier = if (phase[0][cell] > 0)
        phase[0][cell]
    else
        context.surface_chemistry.dry_reference_water_m3[cell] * biomass.surface_remaining_fraction;
    if (remaining_surface_aqueous_carrier == 0) {
        for (plant_litter_salt_dynamic_coordinates, 0..) |coordinate, salt| {
            plant_litter_salt_pending[salt] = dynamic[coordinate].surface_amount[cell];
            dynamic[coordinate].surface_amount[cell] = 0;
        }
    }
    const surface_owners = try surfaceOwnersAfter(context, cell, dynamic_salts, biomass.surface_remaining_fraction, phase[0][cell], core, dynamic);
    inline for (.{ urease_initial, urease_current, nitrification_initial, nitrification_current }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidTillageInhibitorResult;
    inline for (.{ surface_owners.fertilizer.initial_urease_inhibition_fraction, surface_owners.fertilizer.current_urease_inhibition_fraction }) |value| if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidTillageInhibitorResult;

    var result: PreparedPhysicalGas = .{
        .matrix_water_m3 = matrix_water,
        .matrix_ice_m3 = matrix_ice,
        .vapor_m3 = vapor,
        .temperature_k = temperature,
        .reference_bulk_density = intensive[0].layer_values,
        .field_capacity_fraction = intensive[1].layer_values,
        .wilting_point_fraction = intensive[2].layer_values,
        .vertical_saturated_conductivity_m_per_h = intensive[3].layer_values,
        .lateral_saturated_conductivity_m_per_h = intensive[4].layer_values,
        .gapon_calcium_ammonium = intensive[5].layer_values,
        .gapon_calcium_aluminum_and_iron = intensive[6].layer_values,
        .gapon_calcium_magnesium = intensive[7].layer_values,
        .gapon_calcium_sodium = intensive[8].layer_values,
        .gapon_calcium_potassium = intensive[9].layer_values,
        .sand_mass = inventory[0].layer_values,
        .silt_mass = inventory[1].layer_values,
        .clay_mass = inventory[2].layer_values,
        .cec_inventory = inventory[3].layer_values,
        .aec_inventory = inventory[4].layer_values,
        .dry_solid_heat_capacity_megajoules_k = mineral_heat_capacity,
        .heat_capacity_megajoules_k = heat_capacity,
        .chemistry_inventory = chemistry_storage,
        .gaseous_mass_g = try allocZero(allocator, Gas.species_count * layers),
        .dissolved_mass_g = try allocZero(allocator, Gas.species_count * layers),
        .macropore_dissolved_mass_g = try allocZero(allocator, Gas.species_count * layers),
        .band_dissolved_mass_g = try allocZero(allocator, Gas.species_count * layers),
        .surface_gaseous_mass_g = @splat(0),
        .surface_dissolved_mass_g = @splat(0),
        .surface_macropore_dissolved_mass_g = @splat(0),
        .surface_band_dissolved_mass_g = @splat(0),
        .surface_water_m3 = phase[0][cell],
        .surface_ice_m3 = phase[1][cell],
        .surface_vapor_m3 = phase[2][cell],
        .surface_heat_capacity_megajoules_per_k = phase[11][cell],
        .surface_nitrite_g_n = surface_owners.nitrite_g_n,
        .surface_dynamic_amount_mol = @splat(0),
        .plant_litter_salt_pending_mol = plant_litter_salt_pending,
        .surface_mineral_reference_water_m3 = context.surface_chemistry.mineral_reference_water_m3[cell],
        .surface_dry_reference_water_m3 = if (phase[0][cell] > 0) 0 else context.surface_chemistry.dry_reference_water_m3[cell] * biomass.surface_remaining_fraction,
        .surface_chemistry = surface_owners.chemistry,
        .surface_fertilizer = surface_owners.fertilizer,
        .mineral_soil = mineral_soil,
        .mineral_surface = mineral_surface,
        .band_geometry = band_geometry,
        .urease_initial = urease_initial,
        .urease_current = urease_current,
        .nitrification_initial = nitrification_initial,
        .nitrification_current = nitrification_current,
        .surface_geometry_scale = biomass.surface_remaining_fraction,
        .micropore_solute_amount_mol = transport_owners.micropore_mol,
        .macropore_solute_amount_mol = transport_owners.macropore_mol,
        .mineral_nitrogen_matrix_mol = transport_owners.mineral_matrix_mol,
        .mineral_nitrogen_macropore_mol = transport_owners.mineral_macropore_mol,
    };
    for (0..layers) |layer| for (0..Gas.species_count) |species| {
        const destination = layer * Gas.species_count + species;
        result.gaseous_mass_g[destination] = gaseous_values[species * layers + layer];
        result.dissolved_mass_g[destination] = dissolved_values[species * layers + layer];
        result.macropore_dissolved_mass_g[destination] = macropore_values[species * layers + layer];
        result.band_dissolved_mass_g[destination] = band_values[species * layers + layer];
    };
    for (0..Gas.species_count) |species| {
        result.surface_gaseous_mass_g[species] = context.surface_gas.gaseous_mass_g[surface_mass_offset + species];
        result.surface_dissolved_mass_g[species] = context.surface_gas.dissolved_mass_g[surface_mass_offset + species];
        result.surface_macropore_dissolved_mass_g[species] = context.surface_gas.macropore_dissolved_mass_g[surface_mass_offset + species];
        result.surface_band_dissolved_mass_g[species] = context.surface_gas.band_dissolved_mass_g[surface_mass_offset + species];
    }
    for (source_aqueous_gas_species, 0..) |species, family| result.surface_dissolved_mass_g[species] = core[family].surface_amount[cell];
    for (&result.surface_dynamic_amount_mol, 0..) |*amount, family|
        amount.* = dynamic[family].surface_amount[cell];
    try validatePhysicalGasClosure(context, cell, global_first, layers, result);
    return result;
}

noinline fn redistributeOrderedSequence(
    sequence: *const OrderedSequenceContext,
    surface_phase: *const OrderedSurfacePhase,
    core: *[surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily,
    dynamic: *[surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily,
) !OrderedRedistributionPhase {
    const allocator = sequence.allocator;
    const context = sequence.context;
    const cell = sequence.cell;
    const layers = sequence.layers;
    const global_first = sequence.global_first;
    const first_soil_layer = sequence.first_soil_layer;
    const last_soil_layer = sequence.last_soil_layer;
    const tillage_depth_m = sequence.tillage_depth_m;
    const mixing_fraction = sequence.mixing_fraction;
    const thickness = sequence.thickness;
    const bottoms = sequence.bottoms;
    const soil = sequence.soil;
    const mixable_before = surface_phase.mixable_before;
    const phase = surface_phase.phase;
    const incorporated_surface_dry_heat_capacity = surface_phase.incorporated_surface_dry_heat_capacity;
    const incorporated_surface_ice = surface_phase.incorporated_surface_ice;
    const incorporated_surface_vapor = surface_phase.incorporated_surface_vapor;

    // 7. Accumulate exact FI/TI and organic totals over the mixing depth.
    var intensive_storage = try allocZero(allocator, physical_redistribution.intensive_family_count * layers);
    var inventory_storage = try allocZero(allocator, physical_redistribution.inventory_family_count * layers);
    var intensive: [physical_redistribution.intensive_family_count]physical_redistribution.Family = undefined;
    var inventory: [physical_redistribution.inventory_family_count]physical_redistribution.Family = undefined;
    for (&intensive, 0..) |*family, index| family.* = .{ .layer_values = intensive_storage[index * layers ..][0..layers], .mixed_total = 0 };
    for (&inventory, 0..) |*family, index| family.* = .{ .layer_values = inventory_storage[index * layers ..][0..layers], .mixed_total = 0 };
    // REDIST FI source order (11917--11931): BKDSI, FC, WP, SCNV, SCNH,
    // GKC4, GKCA, GKCM, GKCN, GKCK. These are all intensive controls; the
    // texture/CEC inventories are the separate TI families below.
    @memcpy(intensive[0].layer_values, context.properties.reference_bulk_density_megagrams_per_m3[global_first .. global_first + layers]);
    @memcpy(intensive[1].layer_values, context.properties.field_capacity_fraction[global_first .. global_first + layers]);
    @memcpy(intensive[2].layer_values, context.properties.wilting_point_fraction[global_first .. global_first + layers]);
    @memcpy(intensive[4].layer_values, context.properties.lateral_saturated_hydraulic_conductivity_m_per_h[global_first .. global_first + layers]);
    for (0..layers) |layer| {
        const global = global_first + layer;
        intensive[3].layer_values[layer] = context.properties.mualem_van_genuchten_parameters[global].saturated_hydraulic_conductivity_m_per_h;
        const selectivity = context.chemistry_layer_parameters[global].cation_exchange_parameters.selectivity;
        intensive[5].layer_values[layer] = selectivity.calcium_ammonium;
        intensive[6].layer_values[layer] = selectivity.calcium_aluminum_and_iron;
        intensive[7].layer_values[layer] = selectivity.calcium_magnesium;
        intensive[8].layer_values[layer] = selectivity.calcium_sodium;
        intensive[9].layer_values[layer] = selectivity.calcium_potassium;
    }
    const inventory_sources = .{ context.properties.sand_mass_megagrams, context.properties.silt_mass_megagrams, context.properties.clay_mass_megagrams, context.properties.cation_exchange_capacity_mol, context.properties.anion_exchange_capacity_mol };
    inline for (inventory_sources, 0..) |source_values, family| @memcpy(inventory[family].layer_values, source_values[global_first .. global_first + layers]);
    var fi_sources: [layer_accumulation.fi_family_count]layer_accumulation.Family = undefined;
    for (&fi_sources, 0..) |*family, index| family.* = .{ .layer_values = intensive[index].layer_values };
    var ti_sources: [layer_accumulation.ti_family_count]layer_accumulation.Family = undefined;
    const ti_zero = try allocZero(allocator, layers);
    for (&ti_sources) |*family| family.* = .{ .layer_values = ti_zero };
    for (0..physical_redistribution.inventory_family_count) |index| ti_sources[index] = .{ .layer_values = inventory[index].layer_values };
    var fi_totals: [layer_accumulation.fi_family_count]f64 = @splat(0);
    var ti_totals: [layer_accumulation.ti_family_count]f64 = @splat(0);
    const organic_totals_packed = try allocOrganic(allocator, 1);
    // TOM* is soil-only.  The surface-incorporation workspaces are the
    // distinct TOMG*/TORX*/TO?G* families added later at REDIST 12610.
    const matrix_water = try allocator.dupe(f64, context.grid.matrix_liquid_water_m3[global_first .. global_first + layers]);
    const matrix_ice = try allocator.dupe(f64, context.grid.matrix_ice_water_m3[global_first .. global_first + layers]);
    const vapor = try allocator.dupe(f64, context.grid.water_vapor_volume_m3[global_first .. global_first + layers]);
    const temperature = try allocator.dupe(f64, context.grid.soil_temperature_k[global_first .. global_first + layers]);
    // VOLWH/VOLIH are held in their layers but participate in TENGY, ENGYV,
    // and VHCP. Bind the authoritative macropore phase owners; the physical
    // kernel intentionally does not redistribute either quantity.
    const bound_water = try allocator.dupe(f64, context.grid.macropore_liquid_water_m3[global_first .. global_first + layers]);
    const bound_ice = try allocator.dupe(f64, context.grid.macropore_ice_water_m3[global_first .. global_first + layers]);
    const urease_initial = try allocator.dupe(f64, context.fertilizer_nitrogen.initial_urease_inhibition_fraction[global_first .. global_first + layers]);
    const urease_current = try allocator.dupe(f64, context.fertilizer_nitrogen.current_urease_inhibition_fraction[global_first .. global_first + layers]);
    const nitrification_initial = try allocator.dupe(f64, context.reactive_nitrogen.initial_nitrification_inhibition_activity[global_first .. global_first + layers]);
    const nitrification_current = try allocator.dupe(f64, context.reactive_nitrogen.current_nitrification_inhibition_activity[global_first .. global_first + layers]);
    var thermal_energy: f64 = 0;
    var maximum_a: f64 = 0;
    var maximum_b: f64 = 0;
    var maximum_c: f64 = 0;
    var fixation_total: f64 = 0;
    var last_mixed = first_soil_layer;
    const mixing_depth = try layer_accumulation.accumulate(allocator, .{
        .first_soil_layer = first_soil_layer,
        .last_soil_layer = last_soil_layer,
        .tillage_depth_m = tillage_depth_m,
        .cumulative_layer_bottom_m = bottoms,
        .layer_thickness_m = thickness,
        .minimum_layer_thickness_m = context.minimum_layer_thickness_m,
        .liquid_water_heat_capacity_megajoules_per_m3_k = context.liquid_water_heat_capacity_megajoules_per_m3_k,
        .physical_ice_heat_capacity_megajoules_per_m3_k = context.physical_ice_heat_capacity_megajoules_per_m3_k,
        .ice_density_megagrams_per_m3 = context.ice_density_megagrams_per_m3,
        .fi_families = &fi_sources,
        .ti_families = &ti_sources,
        .water_m3 = matrix_water,
        .bound_water_m3 = bound_water,
        .ice_m3 = matrix_ice,
        .bound_ice_m3 = bound_ice,
        .temperature_k = temperature,
        .organic = .{ .microbial_c_n_p = soil.microbial, .residue_c_n_p = soil.residue, .soluble_c_n_p_a_h = soil.soluble, .som_c_a_n_p = soil.som },
        .urea_surface_candidate = urease_initial,
        .urea_incorporated_candidate = urease_current,
        .fixation_candidate = nitrification_initial,
        .fixation_amount_g_n = nitrification_current,
    }, .{
        .fi_totals = &fi_totals,
        .ti_totals = &ti_totals,
        .thermal_energy_megajoules = &thermal_energy,
        .microbial_c_n_p = organic_totals_packed.microbial,
        .residue_c_n_p = organic_totals_packed.residue,
        .soluble_c_n_p_a_h = organic_totals_packed.soluble,
        .som_c_a_n_p = organic_totals_packed.som,
        .urea_surface_maximum = &maximum_a,
        .urea_incorporated_maximum = &maximum_b,
        .fixation_maximum = &maximum_c,
        .fixation_total_g_n = &fixation_total,
        .last_eligible_layer = &last_mixed,
    });
    for (first_soil_layer..last_mixed + 1) |layer| {
        const overlap = layerOverlap(thickness, bottoms, layer, mixing_depth);
        if (overlap > 0) thermal_energy += overlap / thickness[layer] * context.liquid_water_heat_capacity_megajoules_per_m3_k * vapor[layer] * temperature[layer];
    }
    for (&intensive, 0..) |*family, index| family.mixed_total = fi_totals[index];
    for (&inventory, 0..) |*family, index| family.mixed_total = ti_totals[index];

    // 8. Physical water/ice/heat and soil-property redistribution.
    var heat_capacity = try allocZero(allocator, layers);
    const temperature_c = try allocZero(allocator, layers);
    const water_snapshot = try allocZero(allocator, layers);
    var mineral_heat_capacity = try allocZero(allocator, layers);
    for (0..layers) |layer| {
        const global = global_first + layer;
        heat_capacity[layer] = context.thermal.total_heat_capacity_megajoules_per_m3_k[global] * context.thermal.layer_volume_m3[global];
        mineral_heat_capacity[layer] = context.thermal.dry_solid_heat_capacity_megajoules_per_m3_k[global] * context.thermal.layer_volume_m3[global];
    }
    const temperature_before_physical = try allocator.dupe(f64, temperature);
    const mineral_heat_capacity_before = try allocator.dupe(f64, mineral_heat_capacity);
    for (0..layers) |layer| {
        try addSoilPhysicalBeforeActivity(
            &mixable_before[layer],
            context,
            matrix_water[layer],
            matrix_ice[layer],
            vapor[layer],
            bound_water[layer],
            bound_ice[layer],
            temperature[layer],
        );
        try addStorageField(&mixable_before[layer], "sand_megagrams", inventory[0].layer_values[layer]);
        try addStorageField(&mixable_before[layer], "silt_megagrams", inventory[1].layer_values[layer]);
        try addStorageField(&mixable_before[layer], "clay_megagrams", inventory[2].layer_values[layer]);
        try addStorageField(&mixable_before[layer], "cation_exchange_capacity_mol", inventory[3].layer_values[layer]);
        try addStorageField(&mixable_before[layer], "anion_exchange_capacity_mol", inventory[4].layer_values[layer]);
        try addOrganicActivity(&mixable_before[layer], soil.*, layer, layers);
    }
    try physical_redistribution.redistribute(allocator, .{
        .first_soil_layer = first_soil_layer,
        .last_mixed_layer = last_mixed,
        .mixing_depth_m = mixing_depth,
        .mixing_fraction = mixing_fraction,
        .cumulative_layer_bottom_m = bottoms,
        .layer_thickness_m = thickness,
        .minimum_layer_thickness_m = context.minimum_layer_thickness_m,
        .liquid_water_heat_capacity_megajoules_per_m3_k = context.liquid_water_heat_capacity_megajoules_per_m3_k,
        .physical_ice_heat_capacity_megajoules_per_m3_k = context.physical_ice_heat_capacity_megajoules_per_m3_k,
        .ice_density_megagrams_per_m3 = context.ice_density_megagrams_per_m3,
        .intensive_families = &intensive,
        .inventory_families = &inventory,
        .mixed_water_m3 = mixedExtensive(matrix_water, thickness, bottoms, first_soil_layer, last_mixed, mixing_depth),
        .mixed_vapor_m3 = mixedExtensive(vapor, thickness, bottoms, first_soil_layer, last_mixed, mixing_depth),
        .mixed_ice_m3 = mixedExtensive(matrix_ice, thickness, bottoms, first_soil_layer, last_mixed, mixing_depth),
        .incorporated_surface_water_m3 = phase[3][cell],
        .incorporated_surface_vapor_m3 = incorporated_surface_vapor,
        .incorporated_surface_ice_m3 = incorporated_surface_ice,
        .incorporated_surface_dry_heat_capacity_megajoules_k = incorporated_surface_dry_heat_capacity,
        .mixed_thermal_energy_megajoules = thermal_energy,
        .incorporated_surface_energy_megajoules = phase[4][cell],
    }, .{ .water_m3 = matrix_water, .vapor_m3 = vapor, .ice_m3 = matrix_ice, .water_snapshot_m3 = water_snapshot, .bound_water_m3 = bound_water, .bound_ice_m3 = bound_ice, .mineral_heat_capacity_megajoules_k = mineral_heat_capacity, .heat_capacity_megajoules_k = heat_capacity, .temperature_k = temperature, .temperature_c = temperature_c });

    const physical_phase: OrderedPhysicalPhase = .{
        .intensive = intensive,
        .inventory = inventory,
        .matrix_water = matrix_water,
        .matrix_ice = matrix_ice,
        .vapor = vapor,
        .temperature = temperature,
        .urease_initial = urease_initial,
        .urease_current = urease_current,
        .nitrification_initial = nitrification_initial,
        .nitrification_current = nitrification_current,
        .last_mixed = last_mixed,
        .mixing_depth = mixing_depth,
        .heat_capacity = heat_capacity,
        .mineral_heat_capacity = mineral_heat_capacity,
        .temperature_before_physical = temperature_before_physical,
        .mineral_heat_capacity_before = mineral_heat_capacity_before,
        .fixation_total = fixation_total,
        .maximum_a = maximum_a,
        .maximum_b = maximum_b,
        .maximum_c = maximum_c,
        .organic_totals_packed = organic_totals_packed,
        .ti_zero = ti_zero,
    };
    return redistributeChemistryGasAndFinalize(
        sequence,
        surface_phase,
        &physical_phase,
        core,
        dynamic,
    );
}

fn applyOrderedSequence(
    allocator: std.mem.Allocator,
    context: *const Context,
    cell: usize,
    layers: usize,
    global_first: usize,
    first_soil_layer: usize,
    last_soil_layer: usize,
    tillage_depth_m: f64,
    mixing_fraction: f64,
    remaining: f64,
    thickness: []const f64,
    bottoms: []const f64,
    soil: *OrganicPacked,
    surface: *OrganicPacked,
    held_organic: HeldOrganicPacked,
    work_microbe: [3][]f64,
    work_residue: [3][]f64,
    work_soluble: []f64,
    work_som: []f64,
    chemistry_storage: []f64,
    band_geometry: [3][4][]f64,
    transport_owners: PreparedTransport,
) !PreparedPhysicalGas {
    const sequence: OrderedSequenceContext = .{
        .allocator = allocator,
        .context = context,
        .cell = cell,
        .layers = layers,
        .global_first = global_first,
        .first_soil_layer = first_soil_layer,
        .last_soil_layer = last_soil_layer,
        .tillage_depth_m = tillage_depth_m,
        .mixing_fraction = mixing_fraction,
        .remaining = remaining,
        .thickness = thickness,
        .bottoms = bottoms,
        .soil = soil,
        .surface = surface,
        .held_organic = held_organic,
        .work_microbe = work_microbe,
        .work_residue = work_residue,
        .work_soluble = work_soluble,
        .work_som = work_som,
        .chemistry_storage = chemistry_storage,
        .band_geometry = band_geometry,
        .transport_owners = transport_owners,
    };
    const surface_phase = try prepareOrderedSurfacePhase(&sequence);
    var core = surface_phase.core;
    var dynamic = surface_phase.dynamic;
    const redistribution = try redistributeOrderedSequence(&sequence, &surface_phase, &core, &dynamic);
    return finishOrderedSequence(&sequence, &surface_phase, &redistribution, &core, &dynamic);
}

fn scatterTransportOwnersAssumeValid(
    context: *Context,
    global_first: usize,
    layers: usize,
    values: PreparedPhysicalGas,
) void {
    for (0..layers) |layer| {
        const global = global_first + layer;
        context.micropore_solutes.water_volume_m3[global] = values.matrix_water_m3[layer];
        context.macropore_solutes.water_volume_m3[global] = context.grid.macropore_liquid_water_m3[global];
        context.mineral_nitrogen_transport.matrix.water_volume_m3[global] = values.matrix_water_m3[layer];
        context.mineral_nitrogen_transport.macropore.water_volume_m3[global] = context.grid.macropore_liquid_water_m3[global];
        for (0..SoluteSpecies.AqueousSpecies.count) |species| {
            context.micropore_solutes.amount_mol[global * SoluteSpecies.AqueousSpecies.count + species] =
                values.micropore_solute_amount_mol[species * layers + layer];
            context.macropore_solutes.amount_mol[global * SoluteSpecies.AqueousSpecies.count + species] =
                values.macropore_solute_amount_mol[species * layers + layer];
        }
        for (0..MineralNitrogenTransport.species_count) |species| {
            context.mineral_nitrogen_transport.matrix.amount_mol[global * MineralNitrogenTransport.species_count + species] =
                values.mineral_nitrogen_matrix_mol[species * layers + layer];
            context.mineral_nitrogen_transport.macropore.amount_mol[global * MineralNitrogenTransport.species_count + species] =
                values.mineral_nitrogen_macropore_mol[species * layers + layer];
        }
    }
}

fn layerOverlap(thickness: []const f64, bottoms: []const f64, layer: usize, mixing_depth: f64) f64 {
    const top = bottoms[layer] - thickness[layer];
    if (top >= mixing_depth) return 0;
    return @max(0, @min(thickness[layer], mixing_depth - top));
}

fn mixedExtensive(values: []const f64, thickness: []const f64, bottoms: []const f64, first: usize, last: usize, mixing_depth: f64) f64 {
    var total: f64 = 0;
    for (first..last + 1) |layer| total += layerOverlap(thickness, bottoms, layer, mixing_depth) / thickness[layer] * values[layer];
    return total;
}

const chemistry_family_count = chemical_redistribution.plain_family_count + chemical_redistribution.held_family_count;
const fertilizer_offset = 0;
const hydrogen_silicate_coordinate = 8;
const exchange_offset = 9;
const phosphate_surface_nonband_offset = 19;
const phosphate_surface_band_offset = 24;
const geochemistry_offset = 29;
const phosphate_solid_nonband_offset = 45;
const phosphate_solid_band_offset = 50;
const mineral_n_offset = chemical_redistribution.plain_family_count;
const salt_offset = mineral_n_offset + 8;
const phosphate_aqueous_nonband_offset = salt_offset + 33;
const phosphate_aqueous_band_offset = phosphate_aqueous_nonband_offset + 10;

const salt_fields = .{
    "aluminum",             "iron",                 "hydrogen",             "calcium",              "magnesium",             "sodium",            "potassium",        "hydroxide",        "sulfate",           "chloride",     "carbonate",         "bicarbonate",
    "aluminum_hydroxide_1", "aluminum_hydroxide_2", "aluminum_hydroxide_3", "aluminum_hydroxide_4", "aluminum_sulfate",      "iron_hydroxide_1",  "iron_hydroxide_2", "iron_hydroxide_3", "iron_hydroxide_4",  "iron_sulfate", "calcium_hydroxide", "calcium_carbonate",
    "calcium_bicarbonate",  "calcium_sulfate",      "magnesium_hydroxide",  "magnesium_carbonate",  "magnesium_bicarbonate", "magnesium_sulfate", "sodium_carbonate", "sodium_sulfate",   "potassium_sulfate",
};
const phosphate_aqueous_fields = .{
    "dissolved_po4_mol_p_per_m3",    "dissolved_hpo4_mol_p_per_m3",    "dissolved_h2po4_mol_p_per_m3", "dissolved_h3po4_mol_p_per_m3",
    "iron_hpo4_pair_mol_per_m3",     "iron_h2po4_pair_mol_per_m3",     "calcium_po4_pair_mol_per_m3",  "calcium_hpo4_pair_mol_per_m3",
    "calcium_h2po4_pair_mol_per_m3", "magnesium_hpo4_pair_mol_per_m3",
};
const salt_transport_species = [_]SoluteSpecies.AqueousSpecies{
    .aluminum,             .iron,                 .hydrogen,             .calcium,              .magnesium,             .sodium,            .potassium,        .hydroxide,        .sulfate,           .chloride,     .carbonate,         .bicarbonate,
    .aluminum_hydroxide_1, .aluminum_hydroxide_2, .aluminum_hydroxide_3, .aluminum_hydroxide_4, .aluminum_sulfate,      .iron_hydroxide_1,  .iron_hydroxide_2, .iron_hydroxide_3, .iron_hydroxide_4,  .iron_sulfate, .calcium_hydroxide, .calcium_carbonate,
    .calcium_bicarbonate,  .calcium_sulfate,      .magnesium_hydroxide,  .magnesium_carbonate,  .magnesium_bicarbonate, .magnesium_sulfate, .sodium_carbonate, .sodium_sulfate,   .potassium_sulfate,
};
const plant_litter_salt_dynamic_coordinates = [_]usize{ 0, 1, 3, 4, 5, 6, 8, 9 };
const plant_litter_salt_transport_species = [_]SoluteSpecies.AqueousSpecies{
    .aluminum, .iron, .calcium, .magnesium, .sodium, .potassium, .sulfate, .chloride,
};
const surface_dynamic_species = [_]SoluteSpecies.AqueousSpecies{
    .aluminum,               .iron,                    .hydrogen,            .calcium,                  .magnesium,             .sodium,               .potassium,                  .hydroxide,
    .sulfate,                .chloride,                .carbonate,           .bicarbonate,              .aluminum_hydroxide_1,  .aluminum_hydroxide_2, .aluminum_hydroxide_3,       .aluminum_hydroxide_4,
    .aluminum_sulfate,       .iron_hydroxide_1,        .iron_hydroxide_2,    .iron_hydroxide_3,         .iron_hydroxide_4,      .iron_sulfate,         .calcium_hydroxide,          .calcium_carbonate,
    .calcium_bicarbonate,    .calcium_sulfate,         .magnesium_hydroxide, .magnesium_carbonate,      .magnesium_bicarbonate, .magnesium_sulfate,    .sodium_carbonate,           .sodium_sulfate,
    .potassium_sulfate,      .hydrogen_silicate,       .non_band_phosphate,  .non_band_phosphoric_acid, .non_band_iron_hpo4,    .non_band_iron_h2po4,  .non_band_calcium_phosphate, .non_band_calcium_hpo4,
    .non_band_calcium_h2po4, .non_band_magnesium_hpo4,
};

fn isPlantLitterSaltCoordinate(coordinate: usize) bool {
    for (plant_litter_salt_dynamic_coordinates) |dynamic_coordinate|
        if (coordinate == salt_offset + dynamic_coordinate) return true;
    return false;
}
const nonband_phosphate_transport_species = [_]SoluteSpecies.AqueousSpecies{
    .non_band_phosphate,
    .non_band_hpo4,
    .non_band_h2po4,
    .non_band_phosphoric_acid,
    .non_band_iron_hpo4,
    .non_band_iron_h2po4,
    .non_band_calcium_phosphate,
    .non_band_calcium_hpo4,
    .non_band_calcium_h2po4,
    .non_band_magnesium_hpo4,
};
const band_phosphate_transport_species = [_]SoluteSpecies.AqueousSpecies{
    .band_phosphate,
    .band_hpo4,
    .band_h2po4,
    .band_phosphoric_acid,
    .band_iron_hpo4,
    .band_iron_h2po4,
    .band_calcium_phosphate,
    .band_calcium_hpo4,
    .band_calcium_h2po4,
    .band_magnesium_hpo4,
};
const source_scaling_salt_species = [_]SoluteSpecies.AqueousSpecies{
    .aluminum,             .iron,                 .hydrogen,             .calcium,              .magnesium,             .sodium,            .potassium,        .hydroxide,        .sulfate,           .chloride,     .carbonate,         .bicarbonate,
    .aluminum_hydroxide_1, .aluminum_hydroxide_2, .aluminum_hydroxide_3, .aluminum_hydroxide_4, .aluminum_sulfate,      .iron_hydroxide_1,  .iron_hydroxide_2, .iron_hydroxide_3, .iron_hydroxide_4,  .iron_sulfate, .calcium_hydroxide, .calcium_carbonate,
    .calcium_bicarbonate,  .calcium_sulfate,      .magnesium_hydroxide,  .magnesium_carbonate,  .magnesium_bicarbonate, .magnesium_sulfate, .sodium_carbonate, .sodium_sulfate,   .potassium_sulfate,
};
const source_scaling_nonband_phosphate_species = [_]SoluteSpecies.AqueousSpecies{
    .non_band_phosphate,
    .non_band_phosphoric_acid,
    .non_band_iron_hpo4,
    .non_band_iron_h2po4,
    .non_band_calcium_phosphate,
    .non_band_calcium_hpo4,
    .non_band_calcium_h2po4,
    .non_band_magnesium_hpo4,
};
// H1POBH is source-repeated after slot 10; binding the same authoritative
// slice twice preserves source order without applying the remaining fraction
// twice because `macropore_scaling.scale` stages every slot before commit.
const source_scaling_band_phosphate_species = [_]SoluteSpecies.AqueousSpecies{
    .band_phosphate,
    .band_hpo4,
    .band_phosphoric_acid,
    .band_iron_hpo4,
    .band_iron_h2po4,
    .band_calcium_phosphate,
    .band_calcium_hpo4,
    .band_calcium_h2po4,
    .band_magnesium_hpo4,
};
const phosphate_surface_fields = .{ "deprotonated_site_mol_per_megagram", "hydroxyl_site_mol_per_megagram", "protonated_site_mol_per_megagram", "adsorbed_hpo4_mol_p_per_megagram", "adsorbed_h2po4_mol_p_per_megagram" };
const phosphate_solid_fields = .{ "aluminum_phosphate_solid_mol_per_m3", "iron_phosphate_solid_mol_per_m3", "dicalcium_phosphate_solid_mol_per_m3", "hydroxyapatite_solid_mol_per_m3", "monocalcium_phosphate_solid_mol_per_m3" };
const fertilizer_fields = .{ "broadcast_ammonium_mol_n", "broadcast_ammonia_mol_n", "broadcast_urea_mol_n", "broadcast_nitrate_mol_n", "banded_ammonium_mol_n", "banded_ammonia_mol_n", "banded_urea_mol_n", "banded_nitrate_mol_n" };

fn fieldIndex(comptime T: type, comptime name: []const u8) usize {
    return comptime blk: {
        for (@typeInfo(T).@"struct".fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, name)) break :blk index;
        }
        @compileError("missing tillage chemistry field " ++ name);
    };
}

/// SOLUTE and the authoritative census express immobile chemistry per Mg of
/// BKVL (matrix bulk volume times current bulk density). REDIST separately
/// redistributes mineral texture inventories; their sum is not this carrier.
fn chemistryMassCarrier(bulk_density: f64, matrix_bulk_volume: f64) !f64 {
    if (!std.math.isFinite(bulk_density) or bulk_density < 0 or
        !std.math.isFinite(matrix_bulk_volume) or matrix_bulk_volume < 0)
        return error.InvalidTillageChemistryMassCarrier;
    const mass = bulk_density * matrix_bulk_volume;
    if (!std.math.isFinite(mass)) return error.InvalidTillageChemistryMassCarrier;
    return mass;
}

test "tillage chemistry carrier is canonical BKVL with finite nonnegative geometry" {
    try std.testing.expectEqual(@as(f64, 3), try chemistryMassCarrier(1.5, 2));
    try std.testing.expectEqual(@as(f64, 0), try chemistryMassCarrier(0, 2));
    try std.testing.expectEqual(@as(f64, 0), try chemistryMassCarrier(1.5, 0));
    try std.testing.expectError(error.InvalidTillageChemistryMassCarrier, chemistryMassCarrier(-1, 2));
    try std.testing.expectError(error.InvalidTillageChemistryMassCarrier, chemistryMassCarrier(1, -2));
    try std.testing.expectError(error.InvalidTillageChemistryMassCarrier, chemistryMassCarrier(std.math.nan(f64), 2));
    try std.testing.expectError(error.InvalidTillageChemistryMassCarrier, chemistryMassCarrier(1, std.math.inf(f64)));
    try std.testing.expectError(error.InvalidTillageChemistryMassCarrier, chemistryMassCarrier(std.math.floatMax(f64), 2));
}

fn storeInventory(storage: []f64, coordinate: usize, layers: usize, layer: usize, concentration: f64, carrier: f64) !void {
    if (!std.math.isFinite(concentration) or concentration < 0 or !std.math.isFinite(carrier) or carrier < 0) return error.InvalidTillageChemistryOwner;
    const inventory = concentration * carrier;
    if (!std.math.isFinite(inventory)) return error.NonFiniteTillageChemistryInventory;
    storage[coordinate * layers + layer] = inventory;
}

const BandResetResult = struct {
    nitrogen: bool,
    phosphate: bool,
};

fn applyBandResets(allocator: std.mem.Allocator, layers: usize, first: usize, tillage_depth_m: f64, remaining: f64, bottoms: []const f64, geometry: *[3][4][]f64, storage: []f64) !BandResetResult {
    var nitrogen_storage = try allocZero(allocator, 10 * layers);
    var nitrogen: [10][]f64 = undefined;
    for (&nitrogen, 0..) |*values, index| values.* = nitrogen_storage[index * layers ..][0..layers];
    for (0..layers) |layer| {
        nitrogen[0][layer] = 14 * storage[(mineral_n_offset + 0) * layers + layer];
        nitrogen[1][layer] = 14 * storage[(mineral_n_offset + 1) * layers + layer];
        nitrogen[2][layer] = 14 * storage[(mineral_n_offset + 2) * layers + layer];
        nitrogen[3][layer] = 14 * storage[(mineral_n_offset + 3) * layers + layer];
        nitrogen[4][layer] = storage[(exchange_offset + 0) * layers + layer];
        nitrogen[5][layer] = storage[(exchange_offset + 1) * layers + layer];
        nitrogen[6][layer] = 14 * storage[(mineral_n_offset + 4) * layers + layer];
        nitrogen[7][layer] = 14 * storage[(mineral_n_offset + 5) * layers + layer];
        nitrogen[8][layer] = storage[(mineral_n_offset + 6) * layers + layer];
        nitrogen[9][layer] = storage[(mineral_n_offset + 7) * layers + layer];
    }
    const nitrogen_reset = try nitrogen_band_reset.reset(allocator, .{ .disturbance_type = 10, .soil_mixing_remaining_fraction = remaining, .mixing_gate_tolerance = 64 * std.math.floatEps(f64), .tillage_depth_m = tillage_depth_m, .layer_bottom_depth_m = bottoms, .first_soil_layer = first }, .{
        .ammonium_band_depth_m = geometry[0][0],
        .ammonium_band_width_m = geometry[0][1],
        .ammonium_band_volume_fraction = geometry[0][2],
        .ammonium_nonband_volume_fraction = geometry[0][3],
        .nitrate_band_depth_m = geometry[1][0],
        .nitrate_band_width_m = geometry[1][1],
        .nitrate_band_volume_fraction = geometry[1][2],
        .nitrate_nonband_volume_fraction = geometry[1][3],
    }, .{ .ammonium_nonband_g_n = nitrogen[0], .ammonium_band_g_n = nitrogen[1], .ammonia_nonband_g_n = nitrogen[2], .ammonia_band_g_n = nitrogen[3], .exchangeable_ammonium_nonband_mol = nitrogen[4], .exchangeable_ammonium_band_mol = nitrogen[5], .nitrate_nonband_g_n = nitrogen[6], .nitrate_band_g_n = nitrogen[7], .nitrite_nonband_g_n = nitrogen[8], .nitrite_band_g_n = nitrogen[9] });
    for (0..layers) |layer| {
        storage[(mineral_n_offset + 0) * layers + layer] = nitrogen[0][layer] / 14;
        storage[(mineral_n_offset + 1) * layers + layer] = nitrogen[1][layer] / 14;
        storage[(mineral_n_offset + 2) * layers + layer] = nitrogen[2][layer] / 14;
        storage[(mineral_n_offset + 3) * layers + layer] = nitrogen[3][layer] / 14;
        storage[(exchange_offset + 0) * layers + layer] = nitrogen[4][layer];
        storage[(exchange_offset + 1) * layers + layer] = nitrogen[5][layer];
        storage[(mineral_n_offset + 4) * layers + layer] = nitrogen[6][layer] / 14;
        storage[(mineral_n_offset + 5) * layers + layer] = nitrogen[7][layer] / 14;
        storage[(mineral_n_offset + 6) * layers + layer] = nitrogen[8][layer];
        storage[(mineral_n_offset + 7) * layers + layer] = nitrogen[9][layer];
    }

    const phosphate_nonband = [_]usize{ phosphate_aqueous_nonband_offset + 0, phosphate_aqueous_nonband_offset + 1, phosphate_aqueous_nonband_offset + 2, phosphate_aqueous_nonband_offset + 3, phosphate_aqueous_nonband_offset + 4, phosphate_aqueous_nonband_offset + 5, phosphate_aqueous_nonband_offset + 6, phosphate_aqueous_nonband_offset + 7, phosphate_aqueous_nonband_offset + 8, phosphate_aqueous_nonband_offset + 9, phosphate_surface_nonband_offset + 0, phosphate_surface_nonband_offset + 1, phosphate_surface_nonband_offset + 2, phosphate_surface_nonband_offset + 3, phosphate_surface_nonband_offset + 4, phosphate_solid_nonband_offset + 0, phosphate_solid_nonband_offset + 1, phosphate_solid_nonband_offset + 2, phosphate_solid_nonband_offset + 3, phosphate_solid_nonband_offset + 4 };
    const phosphate_band = [_]usize{ phosphate_aqueous_band_offset + 0, phosphate_aqueous_band_offset + 1, phosphate_aqueous_band_offset + 2, phosphate_aqueous_band_offset + 3, phosphate_aqueous_band_offset + 4, phosphate_aqueous_band_offset + 5, phosphate_aqueous_band_offset + 6, phosphate_aqueous_band_offset + 7, phosphate_aqueous_band_offset + 8, phosphate_aqueous_band_offset + 9, phosphate_surface_band_offset + 0, phosphate_surface_band_offset + 1, phosphate_surface_band_offset + 2, phosphate_surface_band_offset + 3, phosphate_surface_band_offset + 4, phosphate_solid_band_offset + 0, phosphate_solid_band_offset + 1, phosphate_solid_band_offset + 2, phosphate_solid_band_offset + 3, phosphate_solid_band_offset + 4 };
    var pairs: [phosphate_band_reset.phosphate_family_count]phosphate_band_reset.BandPair = undefined;
    for (&pairs, phosphate_nonband, phosphate_band) |*pair, nonband, band| pair.* = .{ .nonband = storage[nonband * layers ..][0..layers], .band = storage[band * layers ..][0..layers] };
    const phosphate_reset = try phosphate_band_reset.reset(allocator, .{ .disturbance_type = 10, .soil_mixing_remaining_fraction = remaining, .mixing_gate_tolerance = 64 * std.math.floatEps(f64), .tillage_depth_m = tillage_depth_m, .layer_bottom_depth_m = bottoms, .first_soil_layer = first, .phosphate_band_depth_m = geometry[2][0], .phosphate_band_width_m = geometry[2][1], .phosphate_nonband_volume_fraction = geometry[2][3], .phosphate_band_volume_fraction = geometry[2][2], .ammonium_nonband_volume_fraction = geometry[0][3], .ammonium_band_volume_fraction = geometry[0][2], .nitrate_nonband_volume_fraction = geometry[1][3], .nitrate_band_volume_fraction = geometry[1][2] }, .{ .families = &pairs }, .{
        .ammonium = .{ .nonband = storage[(fertilizer_offset + 0) * layers ..][0..layers], .band = storage[(fertilizer_offset + 4) * layers ..][0..layers] },
        .ammonia = .{ .nonband = storage[(fertilizer_offset + 1) * layers ..][0..layers], .band = storage[(fertilizer_offset + 5) * layers ..][0..layers] },
        .urea = .{ .nonband = storage[(fertilizer_offset + 2) * layers ..][0..layers], .band = storage[(fertilizer_offset + 6) * layers ..][0..layers] },
        .nitrate = .{ .nonband = storage[(fertilizer_offset + 3) * layers ..][0..layers], .band = storage[(fertilizer_offset + 7) * layers ..][0..layers] },
    });
    return .{ .nitrogen = nitrogen_reset, .phosphate = phosphate_reset };
}

fn collapsePairForReset(nonband: []f64, band: []f64, first: usize, tillage_depth_m: f64, bottoms: []const f64) !void {
    for (first..bottoms.len) |layer| {
        if (bottoms[layer] > tillage_depth_m) continue;
        const combined = nonband[layer] + band[layer];
        if (!std.math.isFinite(combined) or combined < 0) return error.NonFiniteTillageMacroporeBandReset;
        nonband[layer] = combined;
        band[layer] = 0;
    }
}

/// Band reset changes the zone identity, not merely the matrix concentration.
/// Move the private macropore owner through the same donor/recipient pair so
/// no inventory remains attached to a zero-volume band before REDIST consumes
/// the held amount into the matrix coordinate.
fn collapseResetMacroporeBands(
    transport: PreparedTransport,
    layers: usize,
    first: usize,
    tillage_depth_m: f64,
    bottoms: []const f64,
    resets: BandResetResult,
) !void {
    if (bottoms.len != layers or first >= layers) return error.TillageRuntimeDimensionMismatch;
    if (resets.nitrogen) {
        for (0..MineralNitrogenTransport.species_count / 2) |coordinate| {
            const nonband = 2 * coordinate;
            const band = nonband + 1;
            try collapsePairForReset(
                transport.mineral_macropore_mol[nonband * layers ..][0..layers],
                transport.mineral_macropore_mol[band * layers ..][0..layers],
                first,
                tillage_depth_m,
                bottoms,
            );
        }
    }
    if (resets.phosphate) {
        for (nonband_phosphate_transport_species, band_phosphate_transport_species) |nonband_species, band_species| {
            try collapsePairForReset(
                transport.macropore_mol[@intFromEnum(nonband_species) * layers ..][0..layers],
                transport.macropore_mol[@intFromEnum(band_species) * layers ..][0..layers],
                first,
                tillage_depth_m,
                bottoms,
            );
        }
    }
}

fn gatherTransportOwners(
    allocator: std.mem.Allocator,
    context: *const Context,
    global_first: usize,
    layers: usize,
) !PreparedTransport {
    var result: PreparedTransport = .{
        .micropore_mol = try allocZero(allocator, SoluteSpecies.AqueousSpecies.count * layers),
        .macropore_mol = try allocZero(allocator, SoluteSpecies.AqueousSpecies.count * layers),
        .mineral_matrix_mol = try allocZero(allocator, MineralNitrogenTransport.species_count * layers),
        .mineral_macropore_mol = try allocZero(allocator, MineralNitrogenTransport.species_count * layers),
    };
    for (0..layers) |layer| {
        const global = global_first + layer;
        const micropore = try context.micropore_solutes.cellAmountsConst(global);
        const macropore = try context.macropore_solutes.cellAmountsConst(global);
        const mineral_matrix = try context.mineral_nitrogen_transport.matrix.cellAmountsConst(global);
        const mineral_macropore = try context.mineral_nitrogen_transport.macropore.cellAmountsConst(global);
        for (0..SoluteSpecies.AqueousSpecies.count) |species| {
            result.micropore_mol[species * layers + layer] = micropore[species];
            result.macropore_mol[species * layers + layer] = macropore[species];
        }
        for (0..MineralNitrogenTransport.species_count) |species| {
            result.mineral_matrix_mol[species * layers + layer] = mineral_matrix[species];
            result.mineral_macropore_mol[species * layers + layer] = mineral_macropore[species];
        }
    }
    return result;
}

fn gatherChemistry(context: *const Context, cell: usize, global_first: usize, layers: usize, band_geometry: [3][4][]f64, transport_owners: PreparedTransport, storage: []f64) !void {
    if (storage.len != chemistry_family_count * layers) return error.TillageChemistryDimensionMismatch;
    for (0..layers) |layer| {
        const global = global_first + layer;
        const water = context.grid.matrix_liquid_water_m3[global];
        const mass = try chemistryMassCarrier(context.properties.bulk_density_megagrams_per_m3[global], context.properties.matrix_bulk_volume_m3[global]);
        const fractions = .{
            .ammonium_non_band = band_geometry[0][3][layer],
            .ammonium_band = band_geometry[0][2][layer],
            .phosphate_non_band = band_geometry[2][3][layer],
            .phosphate_band = band_geometry[2][2][layer],
        };
        const fertilizer = context.fertilizer_nitrogen.soil[cell * layers + layer];
        inline for (fertilizer_fields, 0..) |name, coordinate| try storeInventory(storage, fertilizer_offset + coordinate, layers, layer, @field(fertilizer, name), 1);
        storage[hydrogen_silicate_coordinate * layers + layer] = transport_owners.micropore_mol[@intFromEnum(SoluteSpecies.AqueousSpecies.hydrogen_silicate) * layers + layer];
        inline for (@typeInfo(CationExchange.Cations).@"struct".fields, 0..) |field, coordinate| {
            const carrier = if (coordinate == 0)
                mass * fractions.ammonium_non_band
            else if (coordinate == 1)
                mass * fractions.ammonium_band
            else
                mass;
            try storeInventory(storage, exchange_offset + coordinate, layers, layer, @field(context.soil_chemistry.cation_exchange_mol_per_megagram[global], field.name), carrier);
        }
        try storeInventory(storage, exchange_offset + 9, layers, layer, context.soil_chemistry.carboxyl_bound_hydrogen_mol_per_megagram[global], mass);
        inline for (phosphate_surface_fields, 0..) |name, coordinate| {
            try storeInventory(storage, phosphate_surface_nonband_offset + coordinate, layers, layer, @field(context.soil_chemistry.non_band_phosphate[global], name), mass * fractions.phosphate_non_band);
            try storeInventory(storage, phosphate_surface_band_offset + coordinate, layers, layer, @field(context.soil_chemistry.band_phosphate[global], name), mass * fractions.phosphate_band);
        }
        inline for (@typeInfo(Geochemistry.SolidState).@"struct".fields, 0..) |field, coordinate|
            try storeInventory(storage, geochemistry_offset + coordinate, layers, layer, @field(context.soil_chemistry.geochemistry_solids[global], field.name), water);
        inline for (phosphate_solid_fields, 0..) |name, coordinate| {
            try storeInventory(storage, phosphate_solid_nonband_offset + coordinate, layers, layer, @field(context.soil_chemistry.non_band_phosphate[global], name), water * fractions.phosphate_non_band);
            try storeInventory(storage, phosphate_solid_band_offset + coordinate, layers, layer, @field(context.soil_chemistry.band_phosphate[global], name), water * fractions.phosphate_band);
        }
        for (0..MineralNitrogenTransport.species_count) |coordinate| {
            const amount_mol = transport_owners.mineral_matrix_mol[coordinate * layers + layer];
            storage[(mineral_n_offset + coordinate) * layers + layer] =
                if (coordinate < 6) amount_mol else 14 * amount_mol;
        }
        for (salt_transport_species, 0..) |species, coordinate|
            storage[(salt_offset + coordinate) * layers + layer] = transport_owners.micropore_mol[@intFromEnum(species) * layers + layer];
        for (nonband_phosphate_transport_species, 0..) |species, coordinate|
            storage[(phosphate_aqueous_nonband_offset + coordinate) * layers + layer] = transport_owners.micropore_mol[@intFromEnum(species) * layers + layer];
        for (band_phosphate_transport_species, 0..) |species, coordinate|
            storage[(phosphate_aqueous_band_offset + coordinate) * layers + layer] = transport_owners.micropore_mol[@intFromEnum(species) * layers + layer];
    }
}

fn syncPreparedTransportFromChemistry(
    transport_owners: PreparedTransport,
    chemistry_storage: []const f64,
    layers: usize,
) void {
    for (0..layers) |layer| {
        for (0..MineralNitrogenTransport.species_count) |species| {
            const value = chemistry_storage[(mineral_n_offset + species) * layers + layer];
            transport_owners.mineral_matrix_mol[species * layers + layer] =
                if (species < 6) value else value / 14;
        }
        transport_owners.micropore_mol[@intFromEnum(SoluteSpecies.AqueousSpecies.hydrogen_silicate) * layers + layer] =
            chemistry_storage[hydrogen_silicate_coordinate * layers + layer];
        for (salt_transport_species, 0..) |species, coordinate|
            transport_owners.micropore_mol[@intFromEnum(species) * layers + layer] =
                chemistry_storage[(salt_offset + coordinate) * layers + layer];
        for (nonband_phosphate_transport_species, 0..) |species, coordinate|
            transport_owners.micropore_mol[@intFromEnum(species) * layers + layer] =
                chemistry_storage[(phosphate_aqueous_nonband_offset + coordinate) * layers + layer];
        for (band_phosphate_transport_species, 0..) |species, coordinate|
            transport_owners.micropore_mol[@intFromEnum(species) * layers + layer] =
                chemistry_storage[(phosphate_aqueous_band_offset + coordinate) * layers + layer];
    }
}

fn validateTransportOwnerClosure(
    layers: usize,
    micropore_before: []const f64,
    macropore_before: []const f64,
    mineral_matrix_before: []const f64,
    mineral_macropore_before: []const f64,
    after: PreparedTransport,
    aqueous_surface_addition: []const f64,
    mineral_surface_addition: []const f64,
    aqueous_pending_before: []const f64,
    aqueous_pending_after: []const f64,
) !void {
    if (aqueous_pending_before.len != SoluteSpecies.AqueousSpecies.count or
        aqueous_pending_after.len != SoluteSpecies.AqueousSpecies.count)
        return error.TillageTransportOwnerDimensionMismatch;
    for (0..SoluteSpecies.AqueousSpecies.count) |species| {
        var is_phosphate_zone_coordinate = false;
        for (nonband_phosphate_transport_species) |phosphate_species|
            is_phosphate_zone_coordinate = is_phosphate_zone_coordinate or species == @intFromEnum(phosphate_species);
        for (band_phosphate_transport_species) |phosphate_species|
            is_phosphate_zone_coordinate = is_phosphate_zone_coordinate or species == @intFromEnum(phosphate_species);
        // Nitrogen/phosphate band reset is an internal transfer between the
        // two authoritative zone coordinates.  Test those pairs below so a
        // legitimate band -> non-band move is not mistaken for production.
        if (is_phosphate_zone_coordinate) continue;
        var before = aqueous_surface_addition[species] + aqueous_pending_before[species];
        var result: f64 = aqueous_pending_after[species];
        for (0..layers) |layer| {
            before += micropore_before[species * layers + layer] + macropore_before[species * layers + layer];
            result += after.micropore_mol[species * layers + layer] + after.macropore_mol[species * layers + layer];
        }
        if (!closeEnough(before, result)) {
            std.log.err("tillage aqueous closure species={s} before={e} after={e} residual={e}", .{
                @tagName(@as(SoluteSpecies.AqueousSpecies, @enumFromInt(species))),
                before,
                result,
                result - before,
            });
            return error.TillageAqueousTransportConservationFailure;
        }
    }
    for (0..nonband_phosphate_transport_species.len) |coordinate| {
        const nonband = @intFromEnum(nonband_phosphate_transport_species[coordinate]);
        const band = @intFromEnum(band_phosphate_transport_species[coordinate]);
        var before = aqueous_surface_addition[nonband] + aqueous_surface_addition[band];
        var result: f64 = 0;
        for (0..layers) |layer| {
            before += micropore_before[nonband * layers + layer] + macropore_before[nonband * layers + layer] +
                micropore_before[band * layers + layer] + macropore_before[band * layers + layer];
            result += after.micropore_mol[nonband * layers + layer] + after.macropore_mol[nonband * layers + layer] +
                after.micropore_mol[band * layers + layer] + after.macropore_mol[band * layers + layer];
        }
        if (!closeEnough(before, result)) {
            std.log.err("tillage aqueous phosphate closure coordinate={d} before={e} after={e} residual={e}", .{
                coordinate,
                before,
                result,
                result - before,
            });
            return error.TillageAqueousTransportConservationFailure;
        }
    }
    for (0..MineralNitrogenTransport.species_count / 2) |coordinate| {
        const nonband = 2 * coordinate;
        const band = nonband + 1;
        var before = mineral_surface_addition[nonband] + mineral_surface_addition[band];
        var result: f64 = 0;
        for (0..layers) |layer| {
            before += mineral_matrix_before[nonband * layers + layer] + mineral_macropore_before[nonband * layers + layer] +
                mineral_matrix_before[band * layers + layer] + mineral_macropore_before[band * layers + layer];
            result += after.mineral_matrix_mol[nonband * layers + layer] + after.mineral_macropore_mol[nonband * layers + layer] +
                after.mineral_matrix_mol[band * layers + layer] + after.mineral_macropore_mol[band * layers + layer];
        }
        if (!closeEnough(before, result)) {
            std.log.err("tillage mineral-N closure coordinate={d} before={e} after={e} residual={e}", .{
                coordinate,
                before,
                result,
                result - before,
            });
            return error.TillageMineralNitrogenTransportConservationFailure;
        }
    }
}

fn inventoryConcentration(inventory: f64, carrier: f64) f64 {
    return if (carrier > 0) inventory / carrier else 0;
}

fn validateChemistryCarriers(water: []const f64, volume: []const f64, bulk_density: []const f64, matrix_bulk_volume: []const f64, band_geometry: [3][4][]f64, storage: []const f64, allow_dry_plant_litter_salts: bool) !void {
    const layers = water.len;
    if (volume.len != layers or bulk_density.len != layers or matrix_bulk_volume.len != layers or storage.len != chemistry_family_count * layers) return error.TillageChemistryDimensionMismatch;
    for (0..layers) |layer| {
        const mass = try chemistryMassCarrier(bulk_density[layer], matrix_bulk_volume[layer]);
        for (0..chemistry_family_count) |coordinate| {
            const carrier = chemistryCarrier(coordinate, layer, water[layer], volume[layer], mass, band_geometry);
            const inventory = storage[coordinate * layers + layer];
            const dry_pending_coordinate = allow_dry_plant_litter_salts and carrier == 0 and inventory != 0 and isPlantLitterSaltCoordinate(coordinate);
            if (!std.math.isFinite(inventory) or inventory < 0 or !std.math.isFinite(carrier) or carrier < 0 or (carrier == 0 and inventory != 0 and !dry_pending_coordinate)) return error.UnboundTillageChemistryInventory;
            if (dry_pending_coordinate) continue;
            const concentration = inventoryConcentration(inventory, carrier);
            if (!std.math.isFinite(concentration) or concentration < 0) return error.NonFiniteTillageChemistryConcentration;
        }
    }
}

fn chemistryCarrier(coordinate: usize, layer: usize, water: f64, volume: f64, mass: f64, band_geometry: [3][4][]f64) f64 {
    _ = volume;
    if (coordinate < 8) return 1;
    if (coordinate == hydrogen_silicate_coordinate) return water;
    if (coordinate == exchange_offset) return mass * band_geometry[0][3][layer];
    if (coordinate == exchange_offset + 1) return mass * band_geometry[0][2][layer];
    if (coordinate < phosphate_surface_nonband_offset) return mass;
    if (coordinate < phosphate_surface_band_offset) return mass * band_geometry[2][3][layer];
    if (coordinate < geochemistry_offset) return mass * band_geometry[2][2][layer];
    if (coordinate < phosphate_solid_nonband_offset) return water;
    if (coordinate < phosphate_solid_band_offset) return water * band_geometry[2][3][layer];
    if (coordinate < mineral_n_offset) return water * band_geometry[2][2][layer];
    if (coordinate >= mineral_n_offset and coordinate < mineral_n_offset + 6) {
        const family: usize = if (coordinate < mineral_n_offset + 4) 0 else 1;
        const band = (coordinate - mineral_n_offset) % 2 == 1;
        return water * band_geometry[family][if (band) 2 else 3][layer];
    }
    if (coordinate == mineral_n_offset + 6 or coordinate == mineral_n_offset + 7) return 1;
    if (coordinate >= phosphate_aqueous_nonband_offset and coordinate < phosphate_aqueous_band_offset)
        return water * band_geometry[2][3][layer];
    if (coordinate >= phosphate_aqueous_band_offset)
        return water * band_geometry[2][2][layer];
    return water;
}

fn scatterChemistryAssumeValid(context: *Context, cell: usize, global_first: usize, layers: usize, water: []const f64, volume: []const f64, band_geometry: [3][4][]f64, storage: []const f64) void {
    const state = context.soil_chemistry;
    for (0..layers) |layer| {
        const global = global_first + layer;
        // Validated before commit; neither current bulk density nor matrix
        // bulk volume changes in this transaction (reference density does).
        const mass = context.properties.bulk_density_megagrams_per_m3[global] * context.properties.matrix_bulk_volume_m3[global];
        const fertilizer = &context.fertilizer_nitrogen.soil[cell * layers + layer];
        inline for (fertilizer_fields, 0..) |name, coordinate| @field(fertilizer.*, name) = storage[(fertilizer_offset + coordinate) * layers + layer];
        state.aqueous[global].hydrogen_silicate = inventoryConcentration(storage[hydrogen_silicate_coordinate * layers + layer], water[layer]);
        inline for (@typeInfo(CationExchange.Cations).@"struct".fields, 0..) |field, coordinate| @field(state.cation_exchange_mol_per_megagram[global], field.name) = inventoryConcentration(storage[(exchange_offset + coordinate) * layers + layer], chemistryCarrier(exchange_offset + coordinate, layer, water[layer], volume[layer], mass, band_geometry));
        state.carboxyl_bound_hydrogen_mol_per_megagram[global] = inventoryConcentration(storage[(exchange_offset + 9) * layers + layer], mass);
        inline for (phosphate_surface_fields, 0..) |name, coordinate| {
            @field(state.non_band_phosphate[global], name) = inventoryConcentration(storage[(phosphate_surface_nonband_offset + coordinate) * layers + layer], chemistryCarrier(phosphate_surface_nonband_offset + coordinate, layer, water[layer], volume[layer], mass, band_geometry));
            @field(state.band_phosphate[global], name) = inventoryConcentration(storage[(phosphate_surface_band_offset + coordinate) * layers + layer], chemistryCarrier(phosphate_surface_band_offset + coordinate, layer, water[layer], volume[layer], mass, band_geometry));
        }
        inline for (@typeInfo(Geochemistry.SolidState).@"struct".fields, 0..) |field, coordinate| @field(state.geochemistry_solids[global], field.name) = inventoryConcentration(storage[(geochemistry_offset + coordinate) * layers + layer], water[layer]);
        inline for (phosphate_solid_fields, 0..) |name, coordinate| {
            @field(state.non_band_phosphate[global], name) = inventoryConcentration(storage[(phosphate_solid_nonband_offset + coordinate) * layers + layer], chemistryCarrier(phosphate_solid_nonband_offset + coordinate, layer, water[layer], volume[layer], mass, band_geometry));
            @field(state.band_phosphate[global], name) = inventoryConcentration(storage[(phosphate_solid_band_offset + coordinate) * layers + layer], chemistryCarrier(phosphate_solid_band_offset + coordinate, layer, water[layer], volume[layer], mass, band_geometry));
        }
        inline for (.{ "ammonium_non_band", "ammonium_band", "ammonia_non_band", "ammonia_band", "nitrate_non_band", "nitrate_band" }, 0..) |name, coordinate| @field(state.aqueous[global], name) = inventoryConcentration(storage[(mineral_n_offset + coordinate) * layers + layer], chemistryCarrier(mineral_n_offset + coordinate, layer, water[layer], volume[layer], mass, band_geometry));
        context.reactive_nitrogen.non_band_nitrite_g_n[global] = storage[(mineral_n_offset + 6) * layers + layer];
        context.reactive_nitrogen.band_nitrite_g_n[global] = storage[(mineral_n_offset + 7) * layers + layer];
        inline for (salt_fields, 0..) |name, coordinate| @field(state.aqueous[global], name) = inventoryConcentration(storage[(salt_offset + coordinate) * layers + layer], water[layer]);
        inline for (phosphate_aqueous_fields, 0..) |name, coordinate| {
            @field(state.non_band_phosphate[global], name) = inventoryConcentration(storage[(phosphate_aqueous_nonband_offset + coordinate) * layers + layer], water[layer] * band_geometry[2][3][layer]);
            @field(state.band_phosphate[global], name) = inventoryConcentration(storage[(phosphate_aqueous_band_offset + coordinate) * layers + layer], water[layer] * band_geometry[2][2][layer]);
        }
    }
}

fn setSurfaceInventory(family: *surface_chemical_transfer.TransferFamily, cell: usize, concentration: f64, carrier: f64) !void {
    if (!std.math.isFinite(concentration) or concentration < 0 or !std.math.isFinite(carrier) or carrier < 0) return error.InvalidTillageSurfaceChemistryOwner;
    family.surface_amount[cell] = concentration * carrier;
    if (!std.math.isFinite(family.surface_amount[cell])) return error.NonFiniteTillageSurfaceChemistryInventory;
}

fn surfaceAqueousCarrier(context: *const Context, cell: usize) f64 {
    return if (context.surface_water_m3[cell] > 0) context.surface_water_m3[cell] else context.surface_chemistry.dry_reference_water_m3[cell];
}

fn gatherSurfaceTransfers(context: *const Context, cell: usize, dynamic_salts: bool, core: *[surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily, dynamic: *[surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily) !void {
    const state = context.surface_chemistry.cells[cell];
    const water = surfaceAqueousCarrier(context, cell);
    const mass = context.surface_geometry.dry_mass_megagrams[cell];
    inline for (.{ state.ammonium_mol_per_m3, state.ammonia_mol_per_m3, state.nitrate_mol_per_m3 }, 0..) |value, index| try setSurfaceInventory(&core[6 + index], cell, value, water);
    const nitrite = context.surface_denitrification.nitrite_g_n[cell];
    if (!std.math.isFinite(nitrite) or nitrite < 0) return error.InvalidTillageSurfaceChemistryOwner;
    core[9].surface_amount[cell] = nitrite;
    try setSurfaceInventory(&core[10], cell, state.hpo4_mol_p_per_m3, water);
    try setSurfaceInventory(&core[11], cell, state.h2po4_mol_p_per_m3, water);
    inline for (@typeInfo(@TypeOf(state.exchange)).@"struct".fields, 0..) |field, index| try setSurfaceInventory(&core[12 + index], cell, @field(state.exchange, field.name), mass);
    try setSurfaceInventory(&core[20], cell, state.carboxyl_hydrogen_mol_per_megagram, mass);
    inline for (@typeInfo(@TypeOf(state.phosphate_surface)).@"struct".fields, 0..) |field, index| try setSurfaceInventory(&core[21 + index], cell, @field(state.phosphate_surface, field.name), mass);
    const fertilizer = context.surface_fertilizer.cells[cell];
    inline for (.{ fertilizer.ammonium_mol_n, fertilizer.ammonia_mol_n, fertilizer.urea_mol_n, fertilizer.nitrate_mol_n }, 0..) |value, index| try setSurfaceInventory(&core[26 + index], cell, value, 1);
    core[30].surface_amount[cell] = 0; // surface nitrification-inhibitor owner is scientifically absent

    _ = dynamic_salts;
    const dynamic_amounts = try SurfaceAqueousTillage.gatherTillageSurfaceAmounts(
        context.surface_chemistry,
        context.surface_solute_transport,
        cell,
        context.surface_water_m3[cell],
    );
    for (dynamic_amounts, 0..) |amount, index|
        dynamic[index].surface_amount[cell] = amount;
}

const SurfaceOwners = struct {
    chemistry: SurfaceChemistry.Cell,
    fertilizer: SurfaceFertilizer.Inventory,
    nitrite_g_n: f64,
};

fn surfaceOwnersAfter(context: *const Context, cell: usize, dynamic_salts: bool, remaining: f64, new_water_m3: f64, core: *const [surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily, dynamic: *const [surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily) !SurfaceOwners {
    var result: SurfaceOwners = .{
        .chemistry = context.surface_chemistry.cells[cell],
        .fertilizer = context.surface_fertilizer.cells[cell],
        .nitrite_g_n = core[9].surface_amount[cell],
    };
    const old_dry = context.surface_chemistry.dry_reference_water_m3[cell];
    const water = if (new_water_m3 > 0) new_water_m3 else old_dry * remaining;
    const mass = context.surface_geometry.dry_mass_megagrams[cell] * remaining;
    const concentration = struct {
        fn value(inventory: f64, carrier: f64) !f64 {
            if (carrier == 0) {
                if (inventory != 0) return error.UnboundTillageSurfaceChemistryInventory;
                return 0;
            }
            const next = inventory / carrier;
            if (!std.math.isFinite(next) or next < 0) return error.InvalidTillageSurfaceChemistryOwner;
            return next;
        }
    }.value;
    result.chemistry.ammonium_mol_per_m3 = try concentration(core[6].surface_amount[cell], water);
    result.chemistry.ammonia_mol_per_m3 = try concentration(core[7].surface_amount[cell], water);
    result.chemistry.nitrate_mol_per_m3 = try concentration(core[8].surface_amount[cell], water);
    result.chemistry.hpo4_mol_p_per_m3 = try concentration(core[10].surface_amount[cell], water);
    result.chemistry.h2po4_mol_p_per_m3 = try concentration(core[11].surface_amount[cell], water);
    inline for (@typeInfo(@TypeOf(result.chemistry.exchange)).@"struct".fields, 0..) |field, index| @field(result.chemistry.exchange, field.name) = try concentration(core[12 + index].surface_amount[cell], mass);
    result.chemistry.carboxyl_hydrogen_mol_per_megagram = try concentration(core[20].surface_amount[cell], mass);
    inline for (@typeInfo(@TypeOf(result.chemistry.phosphate_surface)).@"struct".fields, 0..) |field, index| @field(result.chemistry.phosphate_surface, field.name) = try concentration(core[21 + index].surface_amount[cell], mass);
    _ = dynamic_salts;
    _ = dynamic;
    result.fertilizer.ammonium_mol_n = core[26].surface_amount[cell];
    result.fertilizer.ammonia_mol_n = core[27].surface_amount[cell];
    result.fertilizer.urea_mol_n = core[28].surface_amount[cell];
    result.fertilizer.nitrate_mol_n = core[29].surface_amount[cell];
    return result;
}

fn sumCoordinate(storage: []const f64, layers: usize, coordinate: usize) f64 {
    var total: f64 = 0;
    for (storage[coordinate * layers ..][0..layers]) |value| total += value;
    return total;
}

fn validateCoordinateClosure(before: []const f64, after: []const f64, layers: usize, failure: anyerror) !void {
    if (before.len != after.len or before.len % layers != 0) return error.TillageChemistryDimensionMismatch;
    for (0..before.len / layers) |coordinate| if (!closeEnough(sumCoordinate(before, layers, coordinate), sumCoordinate(after, layers, coordinate))) return failure;
}

fn validateMappedSurfaceIncorporation(before: []const f64, after: []const f64, layers: usize, core_coordinates: []const usize, core_totals: []const f64, salt_coordinates: []const usize, salt_totals: []const f64) !void {
    if (core_coordinates.len != core_totals.len or salt_coordinates.len != salt_totals.len or salt_totals.len != surface_chemical_transfer.dynamic_salt_family_count) return error.TillageChemistryDimensionMismatch;
    for (core_coordinates, core_totals) |coordinate, incorporated| {
        const delta = sumCoordinate(after, layers, coordinate) - sumCoordinate(before, layers, coordinate);
        if (!closeEnough(incorporated, delta)) return error.TillageChemistrySurfaceIncorporationConservationFailure;
    }
    for (salt_totals, salt_coordinates) |incorporated, coordinate| {
        const delta = sumCoordinate(after, layers, coordinate) - sumCoordinate(before, layers, coordinate);
        if (!closeEnough(incorporated, delta)) return error.TillageChemistrySurfaceIncorporationConservationFailure;
    }
}

fn redistributeMineralFertilizer(soil: []MineralFertilizer.Inventory, surface: *MineralFertilizer.Inventory, first: usize, last: usize, mixing_depth: f64, thickness: []const f64, bottoms: []const f64, remaining: f64) !void {
    if (soil.len != thickness.len or bottoms.len != soil.len or !std.math.isFinite(remaining) or remaining < 0 or remaining > 1) return error.TillageMineralFertilizerDimensionMismatch;
    inline for (@typeInfo(MineralFertilizer.Inventory).@"struct".fields) |field| {
        const original_surface = @field(surface.*, field.name);
        if (!std.math.isFinite(original_surface) or original_surface < 0) return error.InvalidTillageMineralFertilizerOwner;
        var before = original_surface;
        for (soil) |layer| {
            const value = @field(layer, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidTillageMineralFertilizerOwner;
            before += value;
        }
        const incorporated = original_surface * (1 - remaining);
        @field(surface.*, field.name) = original_surface * remaining;
        for (first..last + 1) |layer| @field(soil[layer], field.name) += layerOverlap(thickness, bottoms, layer, mixing_depth) / mixing_depth * incorporated;
        var after = @field(surface.*, field.name);
        for (soil) |layer| {
            const value = @field(layer, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.NonFiniteTillageMineralFertilizerResult;
            after += value;
        }
        if (!closeEnough(before, after)) return error.TillageMineralFertilizerConservationFailure;
    }
}

fn redistributeOrganic(
    allocator: std.mem.Allocator,
    layers: usize,
    first: usize,
    last: usize,
    mixing_depth: f64,
    mixing_fraction: f64,
    remaining: f64,
    thickness: []const f64,
    bottoms: []const f64,
    soil: OrganicPacked,
    held_organic: HeldOrganicPacked,
    totals: OrganicPacked,
    work_microbe: [3][]f64,
    work_residue: [3][]f64,
    work_soluble: []const f64,
    work_som: []const f64,
) !void {
    var plain: [organic_redistribution.plain_family_count]organic_redistribution.PlainFamily = undefined;
    var held: [organic_redistribution.held_family_count]organic_redistribution.HeldFamily = undefined;
    var incorporated: [organic_redistribution.incorporated_family_count]organic_redistribution.IncorporatedFamily = undefined;
    var p: usize = 0;
    for (0..3) |element| for (0..126) |pool| {
        plain[p] = .{ .layer_amount_g = soil.microbial[element][pool * layers ..][0..layers], .mixed_total_g = totals.microbial[element][pool] };
        p += 1;
    };
    for (0..3) |element| for (0..10) |pool| {
        plain[p] = .{ .layer_amount_g = soil.residue[element][pool * layers ..][0..layers], .mixed_total_g = totals.residue[element][pool] };
        p += 1;
    };
    for (4..8) |soluble| for (0..5) |pool| {
        plain[p] = .{ .layer_amount_g = soil.soluble[soluble][pool * layers ..][0..layers], .mixed_total_g = totals.soluble[soluble][pool] };
        p += 1;
    };
    for (0..4) |component| for (0..25) |pool| {
        plain[p] = .{ .layer_amount_g = soil.som[component][pool * layers ..][0..layers], .mixed_total_g = totals.som[component][pool] };
        p += 1;
    };
    if (p != organic_redistribution.plain_family_count) unreachable;
    var h: usize = 0;
    for (0..4) |soluble| for (0..5) |pool| {
        held[h] = .{ .layer_amount_g = soil.soluble[soluble][pool * layers ..][0..layers], .mixed_total_g = totals.soluble[soluble][pool], .held_amount_g = held_organic[soluble][pool * layers ..][0..layers] };
        h += 1;
    };
    if (h != organic_redistribution.held_family_count) unreachable;

    var incorporated_index: usize = 0;
    for (0..3) |element| for (0..6) |substrate| {
        if (substrate == 4) continue;
        for (0..21) |within| {
            const pool = substrate * 21 + within;
            incorporated[incorporated_index] = .{ .layer_amount_g = soil.microbial[element][pool * layers ..][0..layers], .incorporated_total_g = work_microbe[element][pool] };
            incorporated_index += 1;
        }
    };
    for (0..3) |element| for (0..6) |pool| {
        incorporated[incorporated_index] = .{ .layer_amount_g = soil.residue[element][pool * layers ..][0..layers], .incorporated_total_g = work_residue[element][pool] };
        incorporated_index += 1;
    };
    // Surface order: matrix dissolved C/N/P/A, macropore dissolved
    // C/N/P/A, adsorbed C/N/P/A. The surface OQ*H source is the proven-zero
    // reference coordinate; its destination remains the authoritative soil
    // macropore transport owner so no downstream alias is introduced.
    for (0..12) |source_pool| for (0..3) |substrate| {
        const target = if (source_pool < 4)
            soil.soluble[source_pool][substrate * layers ..][0..layers]
        else if (source_pool < 8)
            held_organic[source_pool - 4][substrate * layers ..][0..layers]
        else
            soil.soluble[source_pool - 4][substrate * layers ..][0..layers];
        incorporated[incorporated_index] = .{ .layer_amount_g = target, .incorporated_total_g = work_soluble[source_pool * 3 + substrate] };
        incorporated_index += 1;
    };
    for (0..4) |component| for (0..15) |pool| {
        incorporated[incorporated_index] = .{ .layer_amount_g = soil.som[component][pool * layers ..][0..layers], .incorporated_total_g = work_som[component * 15 + pool] };
        incorporated_index += 1;
    };
    if (incorporated_index != organic_redistribution.incorporated_family_count) unreachable;
    try organic_redistribution.redistribute(allocator, .{
        .first_soil_layer = first,
        .last_mixed_layer = last,
        .mixing_depth_m = mixing_depth,
        .mixing_fraction = mixing_fraction,
        .soil_mixing_remaining_fraction = remaining,
        .cumulative_layer_bottom_m = bottoms,
        .layer_thickness_m = thickness,
        .minimum_layer_thickness_m = 0,
        .plain_families = &plain,
        .held_families = &held,
        .incorporated_families = &incorporated,
    });
}

fn solubleLedgerArrays(soil: OrganicPacked, held: HeldOrganicPacked) [12][]const f64 {
    return .{
        soil.soluble[0], held[0], soil.soluble[4],
        soil.soluble[3], held[3], soil.soluble[7],
        soil.soluble[1], held[1], soil.soluble[5],
        soil.soluble[2], held[2], soil.soluble[6],
    };
}

fn validatePhysicalGasClosure(context: *const Context, cell: usize, global_first: usize, layers: usize, result: PreparedPhysicalGas) !void {
    var water_before = context.surface_water_m3[cell];
    var water_after = result.surface_water_m3;
    var ice_before = context.surface_ice_m3[cell];
    var ice_after = result.surface_ice_m3;
    var vapor_before = context.surface_gas.water_vapor_mol[cell] * 18.0e-6;
    var vapor_after = result.surface_vapor_m3;
    for (0..layers) |layer| {
        water_before += context.grid.matrix_liquid_water_m3[global_first + layer];
        water_after += result.matrix_water_m3[layer];
        ice_before += context.grid.matrix_ice_water_m3[global_first + layer];
        ice_after += result.matrix_ice_m3[layer];
        vapor_before += context.grid.water_vapor_volume_m3[global_first + layer];
        vapor_after += result.vapor_m3[layer];
    }
    if (!closeEnough(water_before, water_after) or !closeEnough(ice_before, ice_after) or !closeEnough(vapor_before, vapor_after)) return error.TillagePhaseConservationFailure;
    for (0..Gas.species_count) |species| {
        const surface_index = cell * Gas.species_count + species;
        var before = context.surface_gas.gaseous_mass_g[surface_index] + context.surface_gas.dissolved_mass_g[surface_index] + context.surface_gas.macropore_dissolved_mass_g[surface_index] + context.surface_gas.band_dissolved_mass_g[surface_index];
        var after = result.surface_gaseous_mass_g[species] + result.surface_dissolved_mass_g[species] + result.surface_macropore_dissolved_mass_g[species] + result.surface_band_dissolved_mass_g[species];
        for (0..layers) |layer| {
            const source = (global_first + layer) * Gas.species_count + species;
            before += context.soil_gas.gaseous_mass_g[source] + context.soil_gas.dissolved_mass_g[source] + context.soil_gas.macropore_dissolved_mass_g[source] + context.soil_gas.band_dissolved_mass_g[source];
            const destination = layer * Gas.species_count + species;
            after += result.gaseous_mass_g[destination] + result.dissolved_mass_g[destination] + result.macropore_dissolved_mass_g[destination] + result.band_dissolved_mass_g[destination];
        }
        if (!closeEnough(before, after)) return error.TillageGasConservationFailure;
    }
}

test "REDIST tillage binds exact source-ordered chemical and gas macropore families" {
    try std.testing.expectEqual(
        macropore_scaling.macropore_family_count,
        macropore_gas_scaling_offset + source_aqueous_gas_species.len,
    );
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1, 2, 3, 4, 6 },
        &source_aqueous_gas_species,
    );

    var macropore = [_]f64{ 1, 2, 3, 4, 5, 6, 7 };
    var micropore_solute: [SoluteSpecies.AqueousSpecies.count]f64 = @splat(0);
    var macropore_solute: [SoluteSpecies.AqueousSpecies.count]f64 = undefined;
    for (&macropore_solute, 0..) |*value, species| value.* = @floatFromInt(100 + species);
    var mineral_matrix: [MineralNitrogenTransport.species_count]f64 = @splat(0);
    var mineral_macropore: [MineralNitrogenTransport.species_count]f64 = undefined;
    for (&mineral_macropore, 0..) |*value, species| value.* = @floatFromInt(200 + species);
    var zero = [_]f64{0};
    var families: [macropore_scaling.macropore_family_count][]f64 = undefined;
    try bindSourceMacroporeScaling(&families, &zero, .{
        .micropore_mol = &micropore_solute,
        .macropore_mol = &macropore_solute,
        .mineral_matrix_mol = &mineral_matrix,
        .mineral_macropore_mol = &mineral_macropore,
    }, &macropore, 1);
    try std.testing.expect(families[0].ptr == mineral_macropore[0..].ptr);
    try std.testing.expect(families[1].ptr == mineral_macropore[2..].ptr);
    try std.testing.expect(families[4].ptr == macropore_solute[@intFromEnum(SoluteSpecies.AqueousSpecies.non_band_hpo4)..].ptr);
    try std.testing.expect(families[10].ptr == families[54].ptr);
    try std.testing.expect(families[12].ptr == macropore_solute[@intFromEnum(SoluteSpecies.AqueousSpecies.aluminum)..].ptr);
    try std.testing.expect(families[44].ptr == macropore_solute[@intFromEnum(SoluteSpecies.AqueousSpecies.potassium_sulfate)..].ptr);
    try std.testing.expect(families[45].ptr == macropore_solute[@intFromEnum(SoluteSpecies.AqueousSpecies.non_band_phosphate)..].ptr);
    try std.testing.expect(families[61].ptr == macropore_solute[@intFromEnum(SoluteSpecies.AqueousSpecies.band_magnesium_hpo4)..].ptr);
    try std.testing.expect(families[62].ptr == macropore[0..].ptr);
    try std.testing.expect(families[67].ptr == macropore[6..].ptr);
    try macropore_scaling.scale(std.testing.allocator, .{
        .first_soil_layer = 0,
        .last_mixed_layer = 0,
        .soil_mixing_remaining_fraction = 0.25,
        .layer_thickness_m = &.{0.1},
        .minimum_layer_thickness_m = 0,
        .macropore_families = &families,
    });

    try std.testing.expectEqualSlices(
        f64,
        &.{ 0.25, 0.5, 0.75, 1.0, 1.25, 6.0, 1.75 },
        &macropore,
    );
    try std.testing.expectEqual(@as(f64, 50), mineral_macropore[0]);
    try std.testing.expectEqual(@as(f64, 51.75), mineral_macropore[7]);
    try std.testing.expectEqual(@as(f64, 25), macropore_solute[@intFromEnum(SoluteSpecies.AqueousSpecies.aluminum)]);
    try std.testing.expectEqual(@as(f64, 37.25), macropore_solute[@intFromEnum(SoluteSpecies.AqueousSpecies.band_magnesium_hpo4)]);
    try std.testing.expectEqual(@as(f64, 133), macropore_solute[@intFromEnum(SoluteSpecies.AqueousSpecies.hydrogen_silicate)]);
}

noinline fn redistributeChemistryPhase(
    sequence: *const OrderedSequenceContext,
    surface_phase: *const OrderedSurfacePhase,
    physical: *const OrderedPhysicalPhase,
) !ChemistryRedistributionPhase {
    const allocator = sequence.allocator;
    const context = sequence.context;
    const layers = sequence.layers;
    const global_first = sequence.global_first;
    const first_soil_layer = sequence.first_soil_layer;
    const thickness = sequence.thickness;
    const bottoms = sequence.bottoms;
    const mixing_fraction = sequence.mixing_fraction;
    const chemistry_storage = sequence.chemistry_storage;
    const band_geometry = sequence.band_geometry;
    const transport_owners = sequence.transport_owners;
    const mixable_before = surface_phase.mixable_before;
    const plant_litter_salt_pending = surface_phase.plant_litter_salt_pending;
    const matrix_water = physical.matrix_water;
    const last_mixed = physical.last_mixed;
    const mixing_depth = physical.mixing_depth;

    // 9. Carrier-safe chemistry redistribution. Concentrations are gathered
    // as extensive mol inventories before mixing and divided by each new
    // water/mineral carrier only after the full transaction succeeds.
    // Carrierless plant-litter salts remain extensive in the ingress pending
    // owner. Admit them here, after physical mixing has established the
    // recipient carriers, so they follow the same exact REDIST matrix.
    for (0..layers) |layer| {
        for (plant_litter_salt_dynamic_coordinates, 0..) |coordinate, salt| {
            const pending_index = (layer + 1) * PlantLitterSaltIngress.salt_count + salt;
            const chemistry_index = (salt_offset + coordinate) * layers + layer;
            chemistry_storage[chemistry_index] += plant_litter_salt_pending[pending_index];
            if (!std.math.isFinite(chemistry_storage[chemistry_index]))
                return error.NonFiniteTillageChemistryInventory;
            plant_litter_salt_pending[pending_index] = 0;
        }
    }
    for (0..layers) |layer| try addChemistryActivity(&mixable_before[layer], chemistry_storage, layers, layer, context);
    const chemistry_before_mixing = try allocator.dupe(f64, chemistry_storage);
    const micropore_before_mol = try allocator.dupe(f64, transport_owners.micropore_mol);
    const macropore_before_mol = try allocator.dupe(f64, transport_owners.macropore_mol);
    const mineral_matrix_before_mol = try allocator.dupe(f64, transport_owners.mineral_matrix_mol);
    const mineral_macropore_before_mol = try allocator.dupe(f64, transport_owners.mineral_macropore_mol);
    var chemical_plain: [chemical_redistribution.plain_family_count]chemical_redistribution.PlainFamily = undefined;
    var chemical_held: [chemical_redistribution.held_family_count]chemical_redistribution.HeldFamily = undefined;
    for (&chemical_plain, 0..) |*family, index| {
        const values = chemistry_storage[index * layers ..][0..layers];
        family.* = .{ .layer_amount = values, .mixed_total = mixedExtensive(values, thickness, bottoms, first_soil_layer, last_mixed, mixing_depth) };
    }
    var mineral_nitrite_macropore_g = try allocZero(allocator, 2 * layers);
    for (0..2) |nitrite| {
        for (0..layers) |layer|
            mineral_nitrite_macropore_g[nitrite * layers + layer] =
                14 * transport_owners.mineral_macropore_mol[(6 + nitrite) * layers + layer];
    }
    for (&chemical_held, 0..) |*family, index| {
        const coordinate = chemical_redistribution.plain_family_count + index;
        const values = chemistry_storage[coordinate * layers ..][0..layers];
        const held_amount = if (index < 6)
            transport_owners.mineral_macropore_mol[index * layers ..][0..layers]
        else if (index < 8)
            mineral_nitrite_macropore_g[(index - 6) * layers ..][0..layers]
        else if (index < 8 + salt_transport_species.len)
            transport_owners.macropore_mol[@intFromEnum(salt_transport_species[index - 8]) * layers ..][0..layers]
        else if (index < 8 + salt_transport_species.len + nonband_phosphate_transport_species.len)
            transport_owners.macropore_mol[@intFromEnum(nonband_phosphate_transport_species[index - 8 - salt_transport_species.len]) * layers ..][0..layers]
        else
            transport_owners.macropore_mol[@intFromEnum(band_phosphate_transport_species[index - 8 - salt_transport_species.len - nonband_phosphate_transport_species.len]) * layers ..][0..layers];
        family.* = .{ .layer_amount = values, .mixed_total = mixedExtensive(values, thickness, bottoms, first_soil_layer, last_mixed, mixing_depth), .held_amount = held_amount };
    }
    const chemistry_same_scope_gain = try allocZero(allocator, chemistry_family_count * layers);
    for (chemical_held, 0..) |family, index| for (first_soil_layer..last_mixed + 1) |layer| {
        if (thickness[layer] <= context.minimum_layer_thickness_m) continue;
        chemistry_same_scope_gain[(chemical_redistribution.plain_family_count + index) * layers + layer] = mixing_fraction * family.held_amount[layer];
    };
    try chemical_redistribution.redistribute(allocator, .{ .first_soil_layer = first_soil_layer, .last_mixed_layer = last_mixed, .mixing_depth_m = mixing_depth, .mixing_fraction = mixing_fraction, .cumulative_layer_bottom_m = bottoms, .layer_thickness_m = thickness, .minimum_layer_thickness_m = context.minimum_layer_thickness_m, .plain_families = &chemical_plain, .held_families = &chemical_held });
    try validateCoordinateClosure(
        chemistry_before_mixing[0 .. chemical_redistribution.plain_family_count * layers],
        chemistry_storage[0 .. chemical_redistribution.plain_family_count * layers],
        layers,
        error.TillageChemistryRedistributionConservationFailure,
    );
    try validateChemistryCarriers(matrix_water, context.properties.layer_volume_m3[global_first .. global_first + layers], context.properties.bulk_density_megagrams_per_m3[global_first .. global_first + layers], context.properties.matrix_bulk_volume_m3[global_first .. global_first + layers], band_geometry, chemistry_storage, true);
    return .{
        .same_scope_gain = chemistry_same_scope_gain,
        .micropore_before_mol = micropore_before_mol,
        .macropore_before_mol = macropore_before_mol,
        .mineral_matrix_before_mol = mineral_matrix_before_mol,
        .mineral_macropore_before_mol = mineral_macropore_before_mol,
    };
}

noinline fn redistributeGasPhase(
    sequence: *const OrderedSequenceContext,
    surface_phase: *const OrderedSurfacePhase,
    physical: *const OrderedPhysicalPhase,
) !GasRedistributionPhase {
    const allocator = sequence.allocator;
    const bottoms = sequence.bottoms;
    const context = sequence.context;
    const first_soil_layer = sequence.first_soil_layer;
    const global_first = sequence.global_first;
    const layers = sequence.layers;
    const mixing_fraction = sequence.mixing_fraction;
    const remaining = sequence.remaining;
    const thickness = sequence.thickness;
    const transport_owners = sequence.transport_owners;
    const mixable_before = surface_phase.mixable_before;
    const last_mixed = physical.last_mixed;
    const mixing_depth = physical.mixing_depth;
    const ti_zero = physical.ti_zero;

    // 10-11. Gas redistribution plus destruction of held macropore/band
    // gradients.  The held loss is added to the matrix aqueous recipient.
    var gas_values = try allocZero(allocator, 4 * Gas.species_count * layers);
    const gaseous_values = gas_values[0 * Gas.species_count * layers ..][0 .. Gas.species_count * layers];
    const dissolved_values = gas_values[1 * Gas.species_count * layers ..][0 .. Gas.species_count * layers];
    const macropore_values = gas_values[2 * Gas.species_count * layers ..][0 .. Gas.species_count * layers];
    const band_values = gas_values[3 * Gas.species_count * layers ..][0 .. Gas.species_count * layers];
    for (0..layers) |layer| {
        const global = global_first + layer;
        const source = global * Gas.species_count;
        for (0..Gas.species_count) |species| {
            const destination = species * layers + layer;
            gaseous_values[destination] = context.soil_gas.gaseous_mass_g[source + species];
            dissolved_values[destination] = context.soil_gas.dissolved_mass_g[source + species];
            macropore_values[destination] = context.soil_gas.macropore_dissolved_mass_g[source + species];
            band_values[destination] = context.soil_gas.band_dissolved_mass_g[source + species];
        }
        try addGasActivity(&mixable_before[layer], gaseous_values, dissolved_values, layer, layers);
    }
    var gas_families: [gas_redistribution.gaseous_family_count]gas_redistribution.GaseousFamily = undefined;
    var aqueous_families: [gas_redistribution.aqueous_family_count]gas_redistribution.AqueousFamily = undefined;
    var held_gas = try allocZero(allocator, gas_redistribution.aqueous_family_count * layers);
    for (&gas_families, 0..) |*family, species| family.* = .{ .layer_amount_g = gaseous_values[species * layers ..][0..layers], .mixed_total_g = mixedExtensive(gaseous_values[species * layers ..][0..layers], thickness, bottoms, first_soil_layer, last_mixed, mixing_depth) };
    for (&aqueous_families, source_aqueous_gas_species, 0..) |*family, species, family_index| {
        const held = held_gas[family_index * layers ..][0..layers];
        for (0..layers) |layer| held[layer] = macropore_values[species * layers + layer];
        family.* = .{ .layer_amount_g = dissolved_values[species * layers ..][0..layers], .mixed_total_g = mixedExtensive(dissolved_values[species * layers ..][0..layers], thickness, bottoms, first_soil_layer, last_mixed, mixing_depth), .held_amount_g = held };
    }
    const gas_same_scope_gain = try allocZero(allocator, Gas.species_count * layers);
    for (source_aqueous_gas_species, 0..) |species, family| for (first_soil_layer..last_mixed + 1) |layer| {
        if (thickness[layer] <= context.minimum_layer_thickness_m) continue;
        gas_same_scope_gain[species * layers + layer] = mixing_fraction * held_gas[family * layers + layer];
    };
    try gas_redistribution.redistribute(allocator, .{ .first_soil_layer = first_soil_layer, .last_mixed_layer = last_mixed, .mixing_depth_m = mixing_depth, .mixing_fraction = mixing_fraction, .cumulative_layer_bottom_m = bottoms, .layer_thickness_m = thickness, .minimum_layer_thickness_m = context.minimum_layer_thickness_m, .gaseous_families = &gas_families, .aqueous_families = &aqueous_families });
    var macro_families: [macropore_scaling.macropore_family_count][]f64 = undefined;
    try bindSourceMacroporeScaling(&macro_families, ti_zero, transport_owners, macropore_values, layers);
    try macropore_scaling.scale(allocator, .{ .first_soil_layer = first_soil_layer, .last_mixed_layer = last_mixed, .soil_mixing_remaining_fraction = remaining, .layer_thickness_m = thickness, .minimum_layer_thickness_m = context.minimum_layer_thickness_m, .macropore_families = &macro_families });
    return .{
        .gaseous_values = gaseous_values,
        .dissolved_values = dissolved_values,
        .macropore_values = macropore_values,
        .band_values = band_values,
        .same_scope_gain = gas_same_scope_gain,
    };
}

noinline fn redistributeOrganicPhase(
    sequence: *const OrderedSequenceContext,
    physical: *const OrderedPhysicalPhase,
) !OrganicRedistributionPhase {
    const allocator = sequence.allocator;
    const bottoms = sequence.bottoms;
    const context = sequence.context;
    const first_soil_layer = sequence.first_soil_layer;
    const held_organic = sequence.held_organic;
    const layers = sequence.layers;
    const mixing_fraction = sequence.mixing_fraction;
    const remaining = sequence.remaining;
    const soil = sequence.soil;
    const thickness = sequence.thickness;
    const work_microbe = sequence.work_microbe;
    const work_residue = sequence.work_residue;
    const work_soluble = sequence.work_soluble;
    const work_som = sequence.work_som;
    const last_mixed = physical.last_mixed;
    const mixing_depth = physical.mixing_depth;
    const organic_totals_packed = physical.organic_totals_packed;

    // 12. Soil organic redistribution and incorporation of the surface
    // workspace into the same authoritative arrays.
    const organic_same_scope_gain = try allocator.alloc(InventorySupport.Storage, layers);
    @memset(organic_same_scope_gain, .{});
    for (first_soil_layer..last_mixed + 1) |layer| {
        if (thickness[layer] <= context.minimum_layer_thickness_m) continue;
        for (0..Organic.substrate_count) |substrate| {
            const index = substrate * layers + layer;
            try addOrganicTriplet(
                &organic_same_scope_gain[layer],
                substrate == 4,
                mixing_fraction * (held_organic[0][index] + held_organic[3][index]),
                mixing_fraction * held_organic[1][index],
                mixing_fraction * held_organic[2][index],
            );
        }
    }
    try redistributeOrganic(allocator, layers, first_soil_layer, last_mixed, mixing_depth, mixing_fraction, remaining, thickness, bottoms, soil.*, held_organic, organic_totals_packed, work_microbe, work_residue, work_soluble, work_som);

    // 13. Recalculate every mixed-layer organic ledger.  The result is a
    // validation/closure oracle; production derives its diagnostics directly
    // from the same authoritative pools.
    const ledger_soluble = solubleLedgerArrays(soil.*, held_organic);
    for (first_soil_layer..last_mixed + 1) |layer| _ = try organic_ledger.recalculate(layer, .{ .layer_count = layers, .microbial_c_n_p = soil.microbial, .residue_c_n_p = soil.residue, .soluble_and_adsorbed = ledger_soluble, .som_c_a_n_p = soil.som });
    return .{ .same_scope_gain = organic_same_scope_gain };
}

noinline fn incorporateSurfacePhase(
    sequence: *const OrderedSequenceContext,
    surface_phase: *const OrderedSurfacePhase,
    physical: *const OrderedPhysicalPhase,
    chemistry_phase: *const ChemistryRedistributionPhase,
    gas_phase: *const GasRedistributionPhase,
    core: *[surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily,
    dynamic: *[surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily,
) !SurfaceIncorporationPhase {
    const allocator = sequence.allocator;
    const band_geometry = sequence.band_geometry;
    const bottoms = sequence.bottoms;
    const cell = sequence.cell;
    const chemistry_storage = sequence.chemistry_storage;
    const context = sequence.context;
    const first_soil_layer = sequence.first_soil_layer;
    const global_first = sequence.global_first;
    const layers = sequence.layers;
    const mixing_fraction = sequence.mixing_fraction;
    const thickness = sequence.thickness;
    const transport_owners = sequence.transport_owners;
    const biomass = surface_phase.biomass;
    const dynamic_salts = surface_phase.dynamic_salts;
    const plant_litter_salt_pending = surface_phase.plant_litter_salt_pending;
    const plant_litter_salt_pending_before = surface_phase.plant_litter_salt_pending_before;
    const fixation_total = physical.fixation_total;
    const last_mixed = physical.last_mixed;
    const matrix_water = physical.matrix_water;
    const maximum_a = physical.maximum_a;
    const maximum_b = physical.maximum_b;
    const maximum_c = physical.maximum_c;
    const mixing_depth = physical.mixing_depth;
    const nitrification_current = physical.nitrification_current;
    const nitrification_initial = physical.nitrification_initial;
    const urease_current = physical.urease_current;
    const urease_initial = physical.urease_initial;
    const micropore_before_mol = chemistry_phase.micropore_before_mol;
    const macropore_before_mol = chemistry_phase.macropore_before_mol;
    const mineral_matrix_before_mol = chemistry_phase.mineral_matrix_before_mol;
    const mineral_macropore_before_mol = chemistry_phase.mineral_macropore_before_mol;
    const dissolved_values = gas_phase.dissolved_values;

    // 14-15. Incorporate surface gas, mineral N/P, exchange, fertilizer, and
    // salts into their exact REDIST-ordered authoritative coordinates.
    var mineral_slices: [mineral_incorporation.incorporated_family_count][]f64 = undefined;
    for (source_aqueous_gas_species, 0..) |species, index| mineral_slices[index] = dissolved_values[species * layers ..][0..layers];
    const mineral_chemistry_coordinates = [_]usize{
        mineral_n_offset + 0,                 mineral_n_offset + 2,                 mineral_n_offset + 4,                 mineral_n_offset + 6,
        phosphate_aqueous_nonband_offset + 1, phosphate_aqueous_nonband_offset + 2, exchange_offset + 0,                  exchange_offset + 2,
        exchange_offset + 3,                  exchange_offset + 4,                  exchange_offset + 5,                  exchange_offset + 6,
        exchange_offset + 7,                  exchange_offset + 8,                  exchange_offset + 9,                  phosphate_surface_nonband_offset + 0,
        phosphate_surface_nonband_offset + 1, phosphate_surface_nonband_offset + 2, phosphate_surface_nonband_offset + 3, phosphate_surface_nonband_offset + 4,
        fertilizer_offset + 0,                fertilizer_offset + 1,                fertilizer_offset + 2,                fertilizer_offset + 3,
    };
    for (mineral_chemistry_coordinates, 6..) |coordinate, family| mineral_slices[family] = chemistry_storage[coordinate * layers ..][0..layers];
    var mineral_totals: [mineral_incorporation.incorporated_family_count]f64 = undefined;
    for (&mineral_totals, 0..) |*total, family| total.* = core[family].incorporated_amount[cell];
    var cumulative_fixation: f64 = 0;
    const chemistry_before_surface = try allocator.dupe(f64, chemistry_storage);
    const gas_before_surface = try allocator.dupe(f64, dissolved_values);
    var salt_slices: [salt_incorporation.salt_family_count][]f64 = undefined;
    var salt_coordinates: [salt_incorporation.salt_family_count]usize = undefined;
    for (0..33) |family| salt_coordinates[family] = salt_offset + family;
    salt_coordinates[33] = hydrogen_silicate_coordinate;
    salt_coordinates[34] = phosphate_aqueous_nonband_offset + 0;
    salt_coordinates[35] = phosphate_aqueous_nonband_offset + 3;
    for (36..salt_incorporation.salt_family_count) |family|
        salt_coordinates[family] = phosphate_aqueous_nonband_offset + 4 + (family - 36);
    for (&salt_slices, salt_coordinates) |*slice, coordinate|
        slice.* = chemistry_storage[coordinate * layers ..][0..layers];
    var salt_totals: [salt_incorporation.salt_family_count]f64 = undefined;
    for (&salt_totals, 0..) |*total, family| total.* = dynamic[family].incorporated_amount[cell];
    for (first_soil_layer..last_mixed + 1) |layer| {
        const overlap = layerOverlap(thickness, bottoms, layer, mixing_depth);
        if (overlap <= 0 or thickness[layer] <= context.minimum_layer_thickness_m) continue;
        const fi = overlap / mixing_depth;
        const ti = overlap / thickness[layer];
        try mineral_incorporation.incorporate(allocator, .{ .layer = layer, .layer_count = layers, .incorporation_fraction = fi, .mixed_layer_fraction = ti, .unmixed_layer_fraction = 1 - ti, .tillage_incorporation_fraction = mixing_fraction, .layer_amounts = mineral_slices, .mixed_totals = mineral_totals, .urea_hydrolysis_initial = urease_initial, .urea_hydrolysis_current = urease_current, .fertilizer_fixation_initial = nitrification_initial, .fertilizer_fixation_current = nitrification_current, .mixed_urea_hydrolysis_initial = maximum_a, .mixed_urea_hydrolysis_current = maximum_b, .mixed_fertilizer_fixation_initial = maximum_c, .mixed_fertilizer_fixation_current = fixation_total, .incorporated_fertilizer_fixation = core[30].incorporated_amount[cell], .cumulative_fertilizer_fixation = &cumulative_fixation });
        try salt_incorporation.incorporate(allocator, .{ .simulation = if (dynamic_salts) .enabled else .disabled, .layer = layer, .layer_count = layers, .incorporation_fraction = fi, .layer_amounts = salt_slices, .mixed_totals = salt_totals });
    }
    try validateMappedSurfaceIncorporation(chemistry_before_surface, chemistry_storage, layers, &mineral_chemistry_coordinates, mineral_totals[6..], &salt_coordinates, &salt_totals);
    for (0..layers) |layer| {
        if (matrix_water[layer] > 0) continue;
        for (plant_litter_salt_dynamic_coordinates, 0..) |coordinate, salt| {
            const chemistry_index = (salt_offset + coordinate) * layers + layer;
            const pending_index = (layer + 1) * PlantLitterSaltIngress.salt_count + salt;
            plant_litter_salt_pending[pending_index] = chemistry_storage[chemistry_index];
            chemistry_storage[chemistry_index] = 0;
        }
    }
    try validateChemistryCarriers(matrix_water, context.properties.layer_volume_m3[global_first .. global_first + layers], context.properties.bulk_density_megagrams_per_m3[global_first .. global_first + layers], context.properties.matrix_bulk_volume_m3[global_first .. global_first + layers], band_geometry, chemistry_storage, false);
    syncPreparedTransportFromChemistry(transport_owners, chemistry_storage, layers);
    var mineral_surface_addition_mol: [MineralNitrogenTransport.species_count]f64 = @splat(0);
    mineral_surface_addition_mol[0] = mineral_totals[6];
    mineral_surface_addition_mol[2] = mineral_totals[7];
    mineral_surface_addition_mol[4] = mineral_totals[8];
    mineral_surface_addition_mol[6] = mineral_totals[9] / 14;
    var aqueous_surface_addition_mol: [SoluteSpecies.AqueousSpecies.count]f64 = @splat(0);
    aqueous_surface_addition_mol[@intFromEnum(SoluteSpecies.AqueousSpecies.non_band_hpo4)] = mineral_totals[10];
    aqueous_surface_addition_mol[@intFromEnum(SoluteSpecies.AqueousSpecies.non_band_h2po4)] = mineral_totals[11];
    for (salt_totals, 0..) |amount, family|
        aqueous_surface_addition_mol[family] += amount;
    var aqueous_pending_before_mol: [SoluteSpecies.AqueousSpecies.count]f64 = @splat(0);
    var aqueous_pending_after_mol: [SoluteSpecies.AqueousSpecies.count]f64 = @splat(0);
    for (0..layers) |layer| {
        for (plant_litter_salt_transport_species, 0..) |species, salt| {
            const pending_index = (layer + 1) * PlantLitterSaltIngress.salt_count + salt;
            const species_index = @intFromEnum(species);
            aqueous_pending_before_mol[species_index] += plant_litter_salt_pending_before[pending_index];
            aqueous_pending_after_mol[species_index] += plant_litter_salt_pending[pending_index];
        }
    }
    try validateTransportOwnerClosure(
        layers,
        micropore_before_mol,
        macropore_before_mol,
        mineral_matrix_before_mol,
        mineral_macropore_before_mol,
        transport_owners,
        &aqueous_surface_addition_mol,
        &mineral_surface_addition_mol,
        &aqueous_pending_before_mol,
        &aqueous_pending_after_mol,
    );
    for (source_aqueous_gas_species, 0..) |species, family| {
        const before = sumCoordinate(gas_before_surface, layers, species);
        const after = sumCoordinate(dissolved_values, layers, species);
        if (!closeEnough(before + mineral_totals[family], after)) return error.TillageGasSurfaceIncorporationConservationFailure;
    }
    const mineral_soil = try allocator.dupe(MineralFertilizer.Inventory, context.mineral_fertilizer.soil[cell * layers ..][0..layers]);
    const mineral_soil_before = try allocator.dupe(MineralFertilizer.Inventory, mineral_soil);
    var mineral_surface = context.mineral_fertilizer.surface[cell];
    try redistributeMineralFertilizer(mineral_soil, &mineral_surface, first_soil_layer, last_mixed, mixing_depth, thickness, bottoms, biomass.surface_remaining_fraction);
    return .{
        .cumulative_fixation = cumulative_fixation,
        .mineral_soil = mineral_soil,
        .mineral_soil_before = mineral_soil_before,
        .mineral_surface = mineral_surface,
    };
}

noinline fn redistributeChemistryGasAndFinalize(
    sequence: *const OrderedSequenceContext,
    surface_phase: *const OrderedSurfacePhase,
    physical: *const OrderedPhysicalPhase,
    core: *[surface_chemical_transfer.core_family_count]surface_chemical_transfer.TransferFamily,
    dynamic: *[surface_chemical_transfer.dynamic_salt_family_count]surface_chemical_transfer.TransferFamily,
) !OrderedRedistributionPhase {
    const allocator = sequence.allocator;
    const bottoms = sequence.bottoms;
    const cell = sequence.cell;
    const context = sequence.context;
    const first_soil_layer = sequence.first_soil_layer;
    const layers = sequence.layers;
    const mixing_fraction = sequence.mixing_fraction;
    const soil = sequence.soil;
    const thickness = sequence.thickness;
    const biomass = surface_phase.biomass;
    const fixation_total = physical.fixation_total;
    const heat_capacity = physical.heat_capacity;
    const intensive = physical.intensive;
    const inventory = physical.inventory;
    const last_mixed = physical.last_mixed;
    const matrix_ice = physical.matrix_ice;
    const matrix_water = physical.matrix_water;
    const maximum_c = physical.maximum_c;
    const mineral_heat_capacity = physical.mineral_heat_capacity;
    const mineral_heat_capacity_before = physical.mineral_heat_capacity_before;
    const mixing_depth = physical.mixing_depth;
    const nitrification_current = physical.nitrification_current;
    const nitrification_initial = physical.nitrification_initial;
    const temperature = physical.temperature;
    const temperature_before_physical = physical.temperature_before_physical;
    const urease_current = physical.urease_current;
    const urease_initial = physical.urease_initial;
    const vapor = physical.vapor;

    const chemistry_phase = try redistributeChemistryPhase(sequence, surface_phase, physical);
    const chemistry_same_scope_gain = chemistry_phase.same_scope_gain;

    const gas_phase = try redistributeGasPhase(sequence, surface_phase, physical);
    const organic_phase = try redistributeOrganicPhase(sequence, physical);

    const surface_incorporation = try incorporateSurfacePhase(
        sequence,
        surface_phase,
        physical,
        &chemistry_phase,
        &gas_phase,
        core,
        dynamic,
    );
    // 16. Tillage-induced SOC lability transfer (humus substrate K=4,
    // structural fractions M=1/2).  Apparent carbon is the colonized owner.
    const labile = 20 * layers;
    const resistant = 21 * layers;
    for (first_soil_layer..last_mixed + 1) |layer| {
        const overlap = layerOverlap(thickness, bottoms, layer, mixing_depth);
        if (overlap <= 0 or thickness[layer] <= context.minimum_layer_thickness_m) continue;
        try soc_lability.increaseLability(layer, layers, overlap / thickness[layer], mixing_fraction, .{
            .carbon_g_c = .{ .labile = soil.som[0][labile .. labile + layers], .resistant = soil.som[0][resistant .. resistant + layers] },
            .apparent_carbon_g_c = .{ .labile = soil.som[1][labile .. labile + layers], .resistant = soil.som[1][resistant .. resistant + layers] },
            .nitrogen_g_n = .{ .labile = soil.som[2][labile .. labile + layers], .resistant = soil.som[2][resistant .. resistant + layers] },
            .phosphorus_g_p = .{ .labile = soil.som[3][labile .. labile + layers], .resistant = soil.som[3][resistant .. resistant + layers] },
        });
    }

    // 17. Fixation normalization, including the surface coordinate.
    const fixation_initial = try allocZero(allocator, layers + 1);
    const fixation_current = try allocZero(allocator, layers + 1);
    for (0..layers) |layer| {
        fixation_initial[layer + 1] = nitrification_initial[layer];
        fixation_current[layer + 1] = nitrification_current[layer];
    }
    _ = try fixation_normalization.normalize(allocator, .{ .first_soil_layer = first_soil_layer + 1, .last_soil_layer = last_mixed + 1, .zero_threshold = 64 * std.math.floatEps(f64), .initial_fixation_fraction = fixation_initial, .current_fixation_fraction = fixation_current, .mixed_initial_surface_fraction = maximum_c, .surface_incorporation_factor = biomass.surface_remaining_fraction, .previous_fixation_total = surface_incorporation.cumulative_fixation, .target_fixation_total = fixation_total, .incorporated_fixation_total = core[30].incorporated_amount[cell] });
    for (0..layers) |layer| {
        nitrification_initial[layer] = fixation_initial[layer + 1];
        nitrification_current[layer] = fixation_current[layer + 1];
    }

    return .{
        .intensive = intensive,
        .inventory = inventory,
        .matrix_water = matrix_water,
        .matrix_ice = matrix_ice,
        .vapor = vapor,
        .temperature = temperature,
        .urease_initial = urease_initial,
        .urease_current = urease_current,
        .nitrification_initial = nitrification_initial,
        .nitrification_current = nitrification_current,
        .last_mixed = last_mixed,
        .mixing_depth = mixing_depth,
        .heat_capacity = heat_capacity,
        .mineral_heat_capacity = mineral_heat_capacity,
        .temperature_before_physical = temperature_before_physical,
        .mineral_heat_capacity_before = mineral_heat_capacity_before,
        .chemistry_same_scope_gain = chemistry_same_scope_gain,
        .gaseous_values = gas_phase.gaseous_values,
        .dissolved_values = gas_phase.dissolved_values,
        .macropore_values = gas_phase.macropore_values,
        .band_values = gas_phase.band_values,
        .gas_same_scope_gain = gas_phase.same_scope_gain,
        .organic_same_scope_gain = organic_phase.same_scope_gain,
        .mineral_soil = surface_incorporation.mineral_soil,
        .mineral_soil_before = surface_incorporation.mineral_soil_before,
        .mineral_surface = surface_incorporation.mineral_surface,
    };
}

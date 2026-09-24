const std = @import("std");
const builtin = @import("builtin");
const inventory = @import("landscape_mass_inventory.zig");
const scoped = @import("scoped_conservation.zig");
const tolerance_config = @import("../core/conservation_tolerance.zig");
const solute_species = @import("../soil/solute/transport_species.zig");
const soil_solute_transport = @import("../soil/solute/transport.zig");
const snow_solutes = @import("../soil/solute/snow_solute_transport.zig");
const snow_discharge = @import("../soil/water/snow_surface_discharge.zig");
const surface_aqueous = @import("../surface/aqueous_runoff_transport.zig");
const transport_hydrology = @import("../transport/hydrology.zig");
const gas_transport = @import("../soil/gas/transport.zig");
const gas_transport_step = @import("../soil/gas/transport_step.zig");
const dissolved_gas_transport = @import("../soil/gas/dissolved_gas_transport.zig");
const organic_transport = @import("../soil/organic/transport.zig");
const mineral_nitrogen_transport = @import("../soil/biogeochemistry/mineral_nitrogen_transport.zig");
const eroded_constituents = @import("../erosion/eroded_constituents.zig");
const erosion_organic_bridge = @import("../soil/profile/erosion_organic_bridge.zig");
const erosion_fertilizer_bridge = @import("../soil/profile/erosion_fertilizer_bridge.zig");
const erosion_mineral_fertilizer_bridge = @import("../soil/profile/erosion_mineral_fertilizer_bridge.zig");
const mineral_fertilizer_inventory = @import("../management/mineral_fertilizer_inventory.zig");
const erosion_chemistry_bridge = @import("../soil/profile/erosion_chemistry_bridge.zig");
const erosion_mineral_bridge = @import("../soil/profile/erosion_mineral_bridge.zig");
const organic_state = @import("../soil/organic/initialization.zig");
const cation_exchange = @import("../soil/solute/cation_exchange.zig");
const phosphate_network = @import("../soil/solute/phosphate_network.zig");
const geochemistry_network = @import("../soil/solute/geochemistry_network.zig");
const canopy_photosynthesis = @import("../canopy/photosynthesis/photosynthesis.zig");
const canopy_carbon_state_update = @import("../canopy/photosynthesis/carbon_state_update.zig");
const canopy_fire_state_update = @import("../canopy/gas/fire_state_update.zig");
const plant_combustion_state_update = @import("../plant/state_update/combustion.zig");
const root_internal_gas_state_update = @import("../plant/root/internal_gas_state_update.zig");
const root_soil_gas_state_update = @import("../plant/root/soil_gas_state_update.zig");
const plant_root_system = @import("../plant/root/plant_root_system.zig");

fn readRepositorySource(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        std.testing.allocator,
        .limited(4 * 1024 * 1024),
    );
}

pub const Quantity = enum(u8) {
    water,
    heat,
    oxygen,
    hydrogen,
    carbon,
    nitrogen,
    phosphorus,
    sand,
    silt,
    clay,
    rock_additive,
    cation_exchange_capacity,
    anion_exchange_capacity,
    aluminum,
    iron,
    calcium,
    magnesium,
    sodium,
    potassium,
    sulfur,
    chloride,
    silicon,
};

pub const quantity_count = @typeInfo(Quantity).@"enum".fields.len;

/// Static production-readiness contract for the per-cell acceptance gate.
/// This is deliberately independent of numerical closure: a zero residual is
/// not evidence of conservation when a storage owner or activity producer was
/// omitted. `productionCoverageComplete` must be true before the runtime gate
/// may be bound into the accepted-hour path.
pub const StorageOwner = enum(u8) {
    water_phases,
    thermal_energy,
    soil_litter_gases,
    aqueous_and_mineral_species,
    residue_som_and_microbes,
    surface_litter_organic,
    living_plant_carbon,
    living_plant_nitrogen,
    living_plant_phosphorus,
    soil_mineral_texture,
};

pub const ExternalProducer = enum(u8) {
    atmospheric_water_and_heat,
    subsurface_irrigation,
    surface_runoff,
    soil_water_boundary,
    atmospheric_solutes,
    soil_aqueous_boundary,
    dissolved_gas_boundary,
    organic_transport_boundary,
    mineral_nitrogen_boundary,
    soil_litter_gas_atmosphere,
    plant_atmosphere,
    fertilizer,
    erosion,
    fire_and_harvest,
    symbiotic_inoculum,
};

pub const IntercellProducer = enum(u8) {
    soil_water_and_heat_faces,
    soil_aqueous_faces,
    soil_gas_faces,
    surface_runoff_water_and_aqueous,
    surface_runoff_dedicated_species,
    dissolved_gas_faces,
    organic_transport_faces,
    mineral_nitrogen_faces,
    erosion_faces,
};

pub const ProductionCoverage = struct {
    storage: u64,
    external: u64,
    intercell: u64,
    internal: u64 = 0,
};

pub const InternalProducer = enum(u8) {
    heat_adjustments,
    oxygen_reactions,
    hydrogen_reactions,
    charcoal_exchange_capacity,
};

fn enumMask(comptime values: anytype) u64 {
    var result: u64 = 0;
    inline for (values) |value| result |= @as(u64, 1) << @intFromEnum(value);
    return result;
}

fn externalMask(comptime values: []const ExternalProducer) u64 {
    return enumMask(values);
}

fn intercellMask(comptime values: []const IntercellProducer) u64 {
    return enumMask(values);
}

fn internalMask(comptime values: []const InternalProducer) u64 {
    return enumMask(values);
}

const storage_water = enumMask(.{StorageOwner.water_phases});
const storage_heat = enumMask(.{StorageOwner.thermal_energy});
const storage_gases = enumMask(.{StorageOwner.soil_litter_gases});
const storage_elements = enumMask(.{StorageOwner.aqueous_and_mineral_species});
const storage_organic = enumMask(.{ StorageOwner.residue_som_and_microbes, StorageOwner.surface_litter_organic });
const storage_plant_c = enumMask(.{StorageOwner.living_plant_carbon});
const storage_plant_n = enumMask(.{StorageOwner.living_plant_nitrogen});
const storage_plant_p = enumMask(.{StorageOwner.living_plant_phosphorus});
const storage_mineral_texture = enumMask(.{StorageOwner.soil_mineral_texture});

/// Required sources are intentionally conservative and producer-resolved.
/// A category may be zero in a particular run, but its production wiring must
/// still exist so later activation cannot silently bypass the ledger.
pub const production_requirements: [quantity_count]ProductionCoverage = blk: {
    var result: [quantity_count]ProductionCoverage = undefined;
    result[@intFromEnum(Quantity.water)] = .{
        .storage = storage_water,
        .external = externalMask(&.{ .atmospheric_water_and_heat, .subsurface_irrigation, .surface_runoff, .soil_water_boundary }),
        .intercell = intercellMask(&.{ .soil_water_and_heat_faces, .surface_runoff_water_and_aqueous }),
    };
    result[@intFromEnum(Quantity.heat)] = .{
        .storage = storage_heat,
        .external = externalMask(&.{ .atmospheric_water_and_heat, .subsurface_irrigation, .surface_runoff, .soil_water_boundary }),
        .intercell = intercellMask(&.{ .soil_water_and_heat_faces, .surface_runoff_water_and_aqueous }),
        .internal = internalMask(&.{.heat_adjustments}),
    };
    result[@intFromEnum(Quantity.oxygen)] = .{
        .storage = storage_gases,
        .external = externalMask(&.{ .atmospheric_solutes, .dissolved_gas_boundary, .soil_litter_gas_atmosphere, .plant_atmosphere, .fire_and_harvest }),
        .intercell = intercellMask(&.{ .soil_gas_faces, .surface_runoff_dedicated_species, .dissolved_gas_faces }),
        .internal = internalMask(&.{.oxygen_reactions}),
    };
    result[@intFromEnum(Quantity.hydrogen)] = .{
        .storage = storage_gases,
        .external = externalMask(&.{ .dissolved_gas_boundary, .soil_litter_gas_atmosphere, .plant_atmosphere }),
        .intercell = intercellMask(&.{ .soil_gas_faces, .dissolved_gas_faces }),
        .internal = internalMask(&.{.hydrogen_reactions}),
    };
    result[@intFromEnum(Quantity.carbon)] = .{
        .storage = storage_gases | storage_elements | storage_organic | storage_plant_c,
        .external = externalMask(&.{ .atmospheric_solutes, .surface_runoff, .soil_aqueous_boundary, .dissolved_gas_boundary, .organic_transport_boundary, .soil_litter_gas_atmosphere, .plant_atmosphere, .fertilizer, .erosion, .fire_and_harvest, .symbiotic_inoculum }),
        .intercell = intercellMask(&.{ .soil_aqueous_faces, .soil_gas_faces, .surface_runoff_water_and_aqueous, .surface_runoff_dedicated_species, .dissolved_gas_faces, .organic_transport_faces, .erosion_faces }),
    };
    result[@intFromEnum(Quantity.nitrogen)] = .{
        .storage = storage_gases | storage_elements | storage_organic | storage_plant_n,
        .external = externalMask(&.{ .atmospheric_solutes, .subsurface_irrigation, .surface_runoff, .soil_aqueous_boundary, .organic_transport_boundary, .mineral_nitrogen_boundary, .soil_litter_gas_atmosphere, .plant_atmosphere, .fertilizer, .erosion, .fire_and_harvest, .symbiotic_inoculum }),
        .intercell = intercellMask(&.{ .soil_aqueous_faces, .soil_gas_faces, .surface_runoff_dedicated_species, .organic_transport_faces, .mineral_nitrogen_faces, .erosion_faces }),
    };
    result[@intFromEnum(Quantity.phosphorus)] = .{
        .storage = storage_elements | storage_organic | storage_plant_p,
        .external = externalMask(&.{ .atmospheric_solutes, .subsurface_irrigation, .surface_runoff, .soil_aqueous_boundary, .organic_transport_boundary, .fertilizer, .erosion, .fire_and_harvest, .symbiotic_inoculum }),
        .intercell = intercellMask(&.{ .soil_aqueous_faces, .surface_runoff_water_and_aqueous, .surface_runoff_dedicated_species, .organic_transport_faces, .erosion_faces }),
    };
    for (.{ Quantity.sand, Quantity.silt, Quantity.clay }) |quantity| {
        result[@intFromEnum(quantity)] = .{
            .storage = storage_mineral_texture,
            .external = externalMask(&.{.erosion}),
            .intercell = intercellMask(&.{.erosion_faces}),
        };
    }
    result[@intFromEnum(Quantity.rock_additive)] = .{
        .storage = storage_mineral_texture,
        .external = 0,
        .intercell = 0,
    };
    for (.{ Quantity.cation_exchange_capacity, Quantity.anion_exchange_capacity }) |quantity| {
        result[@intFromEnum(quantity)] = .{
            .storage = storage_mineral_texture,
            .external = externalMask(&.{.erosion}),
            .intercell = intercellMask(&.{.erosion_faces}),
            .internal = internalMask(&.{.charcoal_exchange_capacity}),
        };
    }
    for (.{
        Quantity.aluminum,
        Quantity.iron,
        Quantity.calcium,
        Quantity.magnesium,
        Quantity.sodium,
        Quantity.potassium,
        Quantity.sulfur,
        Quantity.chloride,
        Quantity.silicon,
    }) |quantity| {
        result[@intFromEnum(quantity)] = .{
            .storage = storage_elements,
            .external = externalMask(&.{ .atmospheric_solutes, .subsurface_irrigation, .surface_runoff, .soil_aqueous_boundary, .fertilizer, .erosion }),
            .intercell = intercellMask(&.{ .soil_aqueous_faces, .surface_runoff_water_and_aqueous, .erosion_faces }),
        };
    }
    break :blk result;
};

/// Producers currently wired with exact, current-hour, per-cell activity.
/// Deliberately excludes every domain scalar, diagnostic whose time ownership
/// is ambiguous, and all partially represented multi-species transports.
pub const production_bound: ProductionCoverage = .{
    .storage = storage_water | storage_heat | storage_gases | storage_elements | storage_organic | storage_plant_c | storage_plant_n | storage_plant_p | storage_mineral_texture,
    .external = externalMask(&.{ .atmospheric_water_and_heat, .subsurface_irrigation, .surface_runoff, .soil_water_boundary, .atmospheric_solutes, .soil_aqueous_boundary, .dissolved_gas_boundary, .organic_transport_boundary, .mineral_nitrogen_boundary, .soil_litter_gas_atmosphere, .plant_atmosphere, .fertilizer, .erosion, .fire_and_harvest, .symbiotic_inoculum }),
    .intercell = intercellMask(&.{ .soil_water_and_heat_faces, .soil_aqueous_faces, .soil_gas_faces, .surface_runoff_water_and_aqueous, .surface_runoff_dedicated_species, .dissolved_gas_faces, .organic_transport_faces, .mineral_nitrogen_faces, .erosion_faces }),
    .internal = internalMask(&.{ .heat_adjustments, .oxygen_reactions, .hydrogen_reactions, .charcoal_exchange_capacity }),
};

pub fn productionCoverageComplete() bool {
    for (production_requirements) |required| {
        if (required.storage & ~production_bound.storage != 0 or
            required.external & ~production_bound.external != 0 or
            required.intercell & ~production_bound.intercell != 0 or
            required.internal & ~production_bound.internal != 0)
            return false;
    }
    return true;
}

pub fn requireProductionCoverage() !void {
    if (!productionCoverageComplete())
        return error.HourlyCellConservationCoverageIncomplete;
}

/// Direction-separated activity for one horizontal cell and one accepted
/// external hour. Intercell transfers belong here only at the modeled-domain
/// edge; transfers between cells are internal to the domain but must be
/// included with opposite directions in the two cell scopes by their owning
/// transport producer.
pub const BoundaryActivity = struct {
    water_input_m3: f64 = 0,
    water_output_m3: f64 = 0,
    /// Sum of rigorous binary64 forward-error bounds for accepted upstream
    /// water-storage update schedules. Diagnostic arithmetic provenance only:
    /// this is neither a physical flux nor a configurable tolerance.
    water_storage_update_roundoff_allowance_m3: f64 = 0,
    /// Certified binary64 forward error created when accepted water-carrier
    /// rebases preserve concentration-owned extensive chemistry.  These lanes
    /// are arithmetic provenance only; they are never physical sources/sinks.
    carbon_storage_update_roundoff_allowance_g: f64 = 0,
    nitrogen_storage_update_roundoff_allowance_g: f64 = 0,
    phosphorus_storage_update_roundoff_allowance_g: f64 = 0,
    aluminum_storage_update_roundoff_allowance_mol: f64 = 0,
    iron_storage_update_roundoff_allowance_mol: f64 = 0,
    calcium_storage_update_roundoff_allowance_mol: f64 = 0,
    magnesium_storage_update_roundoff_allowance_mol: f64 = 0,
    sodium_storage_update_roundoff_allowance_mol: f64 = 0,
    potassium_storage_update_roundoff_allowance_mol: f64 = 0,
    sulfur_storage_update_roundoff_allowance_mol: f64 = 0,
    chloride_storage_update_roundoff_allowance_mol: f64 = 0,
    silicon_storage_update_roundoff_allowance_mol: f64 = 0,
    /// Producer-certified binary64 forward error from accepted heat-storage
    /// updates. Arithmetic provenance only; never a heat source or sink.
    heat_storage_update_roundoff_allowance_megajoules: f64 = 0,
    heat_input_megajoules: f64 = 0,
    heat_output_megajoules: f64 = 0,
    heat_internal_production_megajoules: f64 = 0,
    heat_internal_consumption_megajoules: f64 = 0,
    oxygen_input_g: f64 = 0,
    oxygen_output_g: f64 = 0,
    oxygen_internal_production_g: f64 = 0,
    oxygen_internal_consumption_g: f64 = 0,
    hydrogen_input_g: f64 = 0,
    hydrogen_output_g: f64 = 0,
    hydrogen_internal_production_g: f64 = 0,
    hydrogen_internal_consumption_g: f64 = 0,
    carbon_input_g: f64 = 0,
    carbon_output_g: f64 = 0,
    nitrogen_input_g: f64 = 0,
    nitrogen_output_g: f64 = 0,
    phosphorus_input_g: f64 = 0,
    phosphorus_output_g: f64 = 0,
    aluminum_input_mol: f64 = 0,
    aluminum_output_mol: f64 = 0,
    iron_input_mol: f64 = 0,
    iron_output_mol: f64 = 0,
    calcium_input_mol: f64 = 0,
    calcium_output_mol: f64 = 0,
    magnesium_input_mol: f64 = 0,
    magnesium_output_mol: f64 = 0,
    sodium_input_mol: f64 = 0,
    sodium_output_mol: f64 = 0,
    potassium_input_mol: f64 = 0,
    potassium_output_mol: f64 = 0,
    sulfur_input_mol: f64 = 0,
    sulfur_output_mol: f64 = 0,
    chloride_input_mol: f64 = 0,
    chloride_output_mol: f64 = 0,
    silicon_input_mol: f64 = 0,
    silicon_output_mol: f64 = 0,
    sand_input_megagrams: f64 = 0,
    sand_output_megagrams: f64 = 0,
    silt_input_megagrams: f64 = 0,
    silt_output_megagrams: f64 = 0,
    clay_input_megagrams: f64 = 0,
    clay_output_megagrams: f64 = 0,
    rock_additive_input: f64 = 0,
    rock_additive_output: f64 = 0,
    cation_exchange_capacity_input_mol: f64 = 0,
    cation_exchange_capacity_output_mol: f64 = 0,
    cation_exchange_capacity_internal_production_mol: f64 = 0,
    cation_exchange_capacity_internal_consumption_mol: f64 = 0,
    anion_exchange_capacity_input_mol: f64 = 0,
    anion_exchange_capacity_output_mol: f64 = 0,
    anion_exchange_capacity_internal_production_mol: f64 = 0,
    anion_exchange_capacity_internal_consumption_mol: f64 = 0,
};

/// Exact runoff water/heat activity for one horizontal cell. Incoming heat is
/// the sum of immutable donor-temperature `HQR` transfers; outgoing heat is
/// evaluated from this cell's immutable pre-route temperature. Keeping the
/// directions separate makes both local closure and domain cancellation
/// observable.
pub fn surfaceRunoffWaterHeatActivity(
    incoming_water_m3: f64,
    outgoing_water_m3: f64,
    incoming_heat_megajoules: f64,
    outgoing_heat_megajoules: f64,
) !BoundaryActivity {
    const result: BoundaryActivity = .{
        .water_input_m3 = incoming_water_m3,
        .water_output_m3 = outgoing_water_m3,
        .heat_input_megajoules = incoming_heat_megajoules,
        .heat_output_megajoules = outgoing_heat_megajoules,
    };
    try validateBoundary(result);
    return result;
}

/// Atomically combines two producer fragments before a ledger publication.
pub fn addActivities(left: BoundaryActivity, right: BoundaryActivity) !BoundaryActivity {
    return addBoundary(left, right);
}

pub const SignedElementActivity = struct {
    oxygen_g: f64 = 0,
    hydrogen_g: f64 = 0,
    carbon_g: f64 = 0,
    nitrogen_g: f64 = 0,
    phosphorus_g: f64 = 0,
};

/// Converts a producer's source-signed current-hour element changes into the
/// direction-separated cell ledger. Positive means external -> ecosystem;
/// negative means ecosystem -> external. No cancellation between directions
/// is introduced after this producer boundary.
pub fn signedElementActivity(values: SignedElementActivity) !BoundaryActivity {
    var result: BoundaryActivity = .{};
    inline for (std.meta.fields(SignedElementActivity)) |field| {
        const value = @field(values, field.name);
        if (!std.math.isFinite(value)) return error.InvalidHourlyCellBoundaryActivity;
        const stem = field.name[0 .. field.name.len - 2];
        if (value >= 0)
            @field(result, stem ++ "_input_g") = value
        else
            @field(result, stem ++ "_output_g") = -value;
    }
    return result;
}

/// Converts the authoritative dynamic plant-salt order (Al, Fe, Ca, Mg, Na,
/// K, SO4, Cl) into an element-resolved cell boundary. Living plant salt is
/// inventoried, so only true harvest removal uses `.output`; litterfall,
/// uptake, shoot/root exchange, and fire return are internal transfers.
pub fn plantSaltElementActivity(
    salt_mol: []const f64,
    direction: enum { input, output },
) !BoundaryActivity {
    if (salt_mol.len != 8)
        return error.HourlyCellBoundarySpeciesDimensionMismatch;
    for (salt_mol) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidHourlyCellBoundaryActivity;
    const values: [8]f64 = salt_mol[0..8].*;
    const result: BoundaryActivity = switch (direction) {
        .input => .{
            .aluminum_input_mol = values[0],
            .iron_input_mol = values[1],
            .calcium_input_mol = values[2],
            .magnesium_input_mol = values[3],
            .sodium_input_mol = values[4],
            .potassium_input_mol = values[5],
            .sulfur_input_mol = values[6],
            .chloride_input_mol = values[7],
        },
        .output => .{
            .aluminum_output_mol = values[0],
            .iron_output_mol = values[1],
            .calcium_output_mol = values[2],
            .magnesium_output_mol = values[3],
            .sodium_output_mol = values[4],
            .potassium_output_mol = values[5],
            .sulfur_output_mol = values[6],
            .chloride_output_mol = values[7],
        },
    };
    try validateBoundary(result);
    return result;
}

test "plant salt activity preserves eight species and boundary direction" {
    const output = try plantSaltElementActivity(
        &.{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .output,
    );
    try std.testing.expectEqual(@as(f64, 1), output.aluminum_output_mol);
    try std.testing.expectEqual(@as(f64, 7), output.sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 8), output.chloride_output_mol);
    try std.testing.expectEqual(@as(f64, 0), output.aluminum_input_mol);
    try std.testing.expectError(
        error.InvalidHourlyCellBoundaryActivity,
        plantSaltElementActivity(&.{ 1, 2, 3, 4, 5, 6, 7, -8 }, .input),
    );
}

/// Exact canopy-air activity for one accepted hour. Net fixation already
/// includes shoot/symbiont respiration and C4 leakage. Fire C gases are
/// external outputs, fire O2 is an input, and source-signed fire N/P values
/// contain only the gaseous remainder after internal mineral/charcoal return.
pub fn plantAtmosphereActivity(
    canopy_net_fixation_g_c: f64,
    fire_carbon_dioxide_emission_g_c: f64,
    fire_methane_emission_g_c: f64,
    fire_oxygen_consumption_g_o: f64,
    photosynthetic_oxygen_g_o_per_g_c: f64,
    canopy_ammonia_net_input_g_n: f64,
    symbiotic_fixation_input_g_n: f64,
    fire_nitrogen_net_input_g_n: f64,
    fire_phosphorus_net_input_g_p: f64,
) !BoundaryActivity {
    inline for (.{ fire_carbon_dioxide_emission_g_c, fire_methane_emission_g_c, fire_oxygen_consumption_g_o }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidHourlyCellBoundaryActivity;
    if (!std.math.isFinite(canopy_net_fixation_g_c) or
        !std.math.isFinite(photosynthetic_oxygen_g_o_per_g_c) or photosynthetic_oxygen_g_o_per_g_c <= 0 or
        !std.math.isFinite(canopy_ammonia_net_input_g_n) or
        !std.math.isFinite(symbiotic_fixation_input_g_n) or symbiotic_fixation_input_g_n < 0 or
        !std.math.isFinite(fire_nitrogen_net_input_g_n) or fire_nitrogen_net_input_g_n > 0 or
        !std.math.isFinite(fire_phosphorus_net_input_g_p) or fire_phosphorus_net_input_g_p > 0)
        return error.InvalidHourlyCellBoundaryActivity;
    const fixation_oxygen_g_o = canopy_net_fixation_g_c * photosynthetic_oxygen_g_o_per_g_c;
    if (!std.math.isFinite(fixation_oxygen_g_o))
        return error.InvalidHourlyCellBoundaryActivity;
    var result = try signedElementActivity(.{
        .carbon_g = canopy_net_fixation_g_c,
        .oxygen_g = -fixation_oxygen_g_o,
        .nitrogen_g = canopy_ammonia_net_input_g_n,
    });
    result = try addActivities(result, .{
        .carbon_output_g = try addNonnegative(&.{ fire_carbon_dioxide_emission_g_c, fire_methane_emission_g_c }),
        .oxygen_input_g = fire_oxygen_consumption_g_o,
        .oxygen_internal_production_g = @max(0, fixation_oxygen_g_o),
        .oxygen_internal_consumption_g = try addNonnegative(&.{ @max(0, -fixation_oxygen_g_o), fire_oxygen_consumption_g_o }),
        .nitrogen_input_g = symbiotic_fixation_input_g_n,
        .nitrogen_output_g = -fire_nitrogen_net_input_g_n,
        .phosphorus_output_g = -fire_phosphorus_net_input_g_p,
    });
    return result;
}

pub fn canopyAmmoniaNetInputForCell(
    canopy: *const canopy_photosynthesis.State,
    cell: usize,
) !f64 {
    if (cell >= canopy.cell_count) return error.HourlyCellBoundaryIndexOutOfBounds;
    var total: f64 = 0;
    for (0..canopy.species_count) |species| {
        const plant = try canopy.plantIndex(cell, species);
        const branches = try canopy.branchRange(plant);
        for (canopy.branch_canopy_ammonia_exchange_g_n_per_h[branches.first..branches.end]) |value| {
            if (!std.math.isFinite(value)) return error.InvalidHourlyCellBoundaryActivity;
            total += value;
            if (!std.math.isFinite(total)) return error.HourlyCellBoundaryOverflow;
        }
    }
    return total;
}

pub const PlantFireNutrientOutput = struct {
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

pub const PlantAtmosphereCellActivity = struct {
    boundary: BoundaryActivity,
    fire_nutrient_output: PlantFireNutrientOutput,
};

/// Returns the accepted cell boundary plus the exact shoot-fire N/P subset.
/// The sidecar is needed by the domain reducer because the boundary's N output
/// also contains outward canopy NH3, which has its own daily domain owner.
pub fn plantAtmosphereCellActivityForCell(
    canopy: ?*const canopy_photosynthesis.State,
    roots: ?*const plant_root_system.State,
    carbon: *const canopy_carbon_state_update.State,
    fire: *const canopy_fire_state_update.State,
    combustion: *const plant_combustion_state_update.State,
    cell: usize,
    photosynthetic_oxygen_g_o_per_g_c: f64,
) !PlantAtmosphereCellActivity {
    if (cell >= carbon.cell_count or fire.cell_count != carbon.cell_count or
        fire.plant_species_per_cell != carbon.species_count or
        combustion.plant_count != try std.math.mul(usize, carbon.cell_count, carbon.species_count))
        return error.HourlyCellBoundaryDimensionMismatch;
    if (canopy) |value| if (value.cell_count != carbon.cell_count or value.species_count != carbon.species_count)
        return error.HourlyCellBoundaryDimensionMismatch;
    if (roots) |value| if (value.plant_count != try std.math.mul(usize, carbon.cell_count, carbon.species_count))
        return error.HourlyCellBoundaryDimensionMismatch;
    var fire_nitrogen_net_input: f64 = 0;
    var fire_phosphorus_net_input: f64 = 0;
    var symbiotic_fixation_input: f64 = 0;
    if (canopy != null or roots != null) {
        const first_plant = cell * carbon.species_count;
        for (first_plant..first_plant + carbon.species_count) |plant| {
            fire_nitrogen_net_input += combustion.signed_nitrogen_loss_g_n_per_h_by_plant[plant];
            fire_phosphorus_net_input += combustion.signed_phosphorus_loss_g_p_per_h_by_plant[plant];
            if (!std.math.isFinite(fire_nitrogen_net_input) or !std.math.isFinite(fire_phosphorus_net_input))
                return error.HourlyCellBoundaryOverflow;
            if (canopy) |value| {
                const branches = try value.branchRange(plant);
                for (value.branch_symbiotic_fixed_nitrogen_g_n_per_h[branches.first..branches.end]) |fixed| {
                    if (!std.math.isFinite(fixed) or fixed < 0) return error.InvalidHourlyCellBoundaryActivity;
                    symbiotic_fixation_input += fixed;
                }
            }
            if (roots) |value| {
                const fixed = value.fixation_uptake_g_n_per_h[plant];
                if (!std.math.isFinite(fixed) or fixed < 0) return error.InvalidHourlyCellBoundaryActivity;
                symbiotic_fixation_input += fixed;
            }
            if (!std.math.isFinite(symbiotic_fixation_input)) return error.HourlyCellBoundaryOverflow;
        }
    }
    return .{
        .boundary = try plantAtmosphereActivity(
            carbon.hourly_net_fixation_g_c_per_h_by_cell[cell],
            fire.carbon_dioxide_emission_g_c_per_h_by_cell[cell],
            fire.methane_emission_g_c_per_h_by_cell[cell],
            fire.oxygen_consumption_g_o_per_h_by_cell[cell],
            photosynthetic_oxygen_g_o_per_g_c,
            if (canopy) |value| try canopyAmmoniaNetInputForCell(value, cell) else 0,
            symbiotic_fixation_input,
            fire_nitrogen_net_input,
            fire_phosphorus_net_input,
        ),
        .fire_nutrient_output = .{
            .nitrogen_g_n = -fire_nitrogen_net_input,
            .phosphorus_g_p = -fire_phosphorus_net_input,
        },
    };
}

pub fn plantAtmosphereActivityForCell(
    canopy: ?*const canopy_photosynthesis.State,
    roots: ?*const plant_root_system.State,
    carbon: *const canopy_carbon_state_update.State,
    fire: *const canopy_fire_state_update.State,
    combustion: *const plant_combustion_state_update.State,
    cell: usize,
    photosynthetic_oxygen_g_o_per_g_c: f64,
) !BoundaryActivity {
    return (try plantAtmosphereCellActivityForCell(
        canopy,
        roots,
        carbon,
        fire,
        combustion,
        cell,
        photosynthetic_oxygen_g_o_per_g_c,
    )).boundary;
}

/// One conservative transfer between two horizontal cell control volumes.
/// Every field is an extensive, nonnegative amount in the same native unit as
/// `BoundaryActivity`. The ledger publishes it as an output from the donor and
/// the exactly equal input to the recipient; it never performs a unit or
/// stoichiometric conversion on behalf of a producer.
pub const IntercellTransfer = struct {
    water_m3: f64 = 0,
    heat_megajoules: f64 = 0,
    oxygen_g: f64 = 0,
    hydrogen_g: f64 = 0,
    carbon_g: f64 = 0,
    nitrogen_g: f64 = 0,
    phosphorus_g: f64 = 0,
    aluminum_mol: f64 = 0,
    iron_mol: f64 = 0,
    calcium_mol: f64 = 0,
    magnesium_mol: f64 = 0,
    sodium_mol: f64 = 0,
    potassium_mol: f64 = 0,
    sulfur_mol: f64 = 0,
    chloride_mol: f64 = 0,
    silicon_mol: f64 = 0,
    sand_megagrams: f64 = 0,
    silt_megagrams: f64 = 0,
    clay_megagrams: f64 = 0,
    rock_additive: f64 = 0,
    cation_exchange_capacity_mol: f64 = 0,
    anion_exchange_capacity_mol: f64 = 0,
};

/// Converts the full named-species transport vector into element-resolved
/// external activity. No aggregate-ion allocation is possible: each species
/// contributes by its chemical formula.
pub fn aqueousElementActivity(
    amounts_mol_by_species: []const f64,
    direction: enum { input, output },
) !BoundaryActivity {
    if (amounts_mol_by_species.len != solute_species.AqueousSpecies.count)
        return error.HourlyCellBoundarySpeciesDimensionMismatch;
    var totals: inventory.ElementMoles = .{};
    inline for (@typeInfo(solute_species.AqueousSpecies).@"enum".fields) |field| {
        const amount = amounts_mol_by_species[field.value];
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidHourlyCellBoundaryActivity;
        const contribution = inventory.aqueousSpeciesElements(@enumFromInt(field.value)).scaled(amount);
        inline for (std.meta.fields(inventory.ElementMoles)) |element| {
            const next = @field(totals, element.name) + @field(contribution, element.name);
            if (!std.math.isFinite(next)) return error.HourlyCellBoundaryOverflow;
            @field(totals, element.name) = next;
        }
    }
    var result: BoundaryActivity = .{};
    switch (direction) {
        .input => {
            inline for (std.meta.fields(inventory.ElementMoles)) |element|
                @field(result, element.name ++ "_input_mol") = @field(totals, element.name);
        },
        .output => {
            inline for (std.meta.fields(inventory.ElementMoles)) |element|
                @field(result, element.name ++ "_output_mol") = @field(totals, element.name);
        },
    }
    return result;
}

/// Converts one cell's accepted current-hour precipitation/irrigation
/// chemistry into its exact tracked-element inputs. The mutually exclusive
/// snow and direct branches are recombined here from producer outputs, never
/// inferred from a daily or landscape scalar.
pub fn atmosphericSoluteActivity(
    cell: usize,
    cell_count: usize,
    snow_input_g: []const f64,
    snow_input_salt_mol: []const f64,
    direct_input: []const snow_solutes.SurfaceDischarge,
    ion_molar_mass_g_per_mol: snow_discharge.IonMolarMassesGPerMol,
) !BoundaryActivity {
    if (cell >= cell_count or direct_input.len != cell_count or
        snow_input_g.len != try std.math.mul(usize, cell_count, snow_solutes.species_count) or
        snow_input_salt_mol.len != try std.math.mul(usize, cell_count, snow_solutes.salt_species_count))
        return error.HourlyCellBoundaryDimensionMismatch;
    inline for (std.meta.fields(snow_discharge.IonMolarMassesGPerMol)) |field| {
        const value = @field(ion_molar_mass_g_per_mol, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidHourlyCellBoundaryMolarMass;
    }
    const first = cell * snow_solutes.species_count;
    var amounts: [snow_solutes.species_count]f64 = undefined;
    for (&amounts, 0..) |*amount, species| {
        amount.* = try addNonnegative(&.{
            snow_input_g[first + species],
            direct_input[cell].litter_g[species],
            direct_input[cell].soil_nonband_g[species],
            direct_input[cell].soil_band_g[species],
        });
    }
    var result: BoundaryActivity = .{
        .carbon_input_g = try addNonnegative(&.{
            amounts[@intFromEnum(snow_solutes.Species.carbon_dioxide_carbon)],
            amounts[@intFromEnum(snow_solutes.Species.methane_carbon)],
        }),
        .oxygen_input_g = amounts[@intFromEnum(snow_solutes.Species.oxygen)],
        .nitrogen_input_g = try addNonnegative(&.{
            amounts[@intFromEnum(snow_solutes.Species.dinitrogen_nitrogen)],
            amounts[@intFromEnum(snow_solutes.Species.nitrous_oxide_nitrogen)],
            amounts[@intFromEnum(snow_solutes.Species.ammonium_nitrogen)],
            amounts[@intFromEnum(snow_solutes.Species.ammonia_nitrogen)],
            amounts[@intFromEnum(snow_solutes.Species.nitrate_nitrogen)],
        }),
        .phosphorus_input_g = try addNonnegative(&.{
            amounts[@intFromEnum(snow_solutes.Species.hydrogen_phosphate_phosphorus)],
            amounts[@intFromEnum(snow_solutes.Species.dihydrogen_phosphate_phosphorus)],
        }),
        .aluminum_input_mol = amounts[@intFromEnum(snow_solutes.Species.aluminum)] / ion_molar_mass_g_per_mol.aluminum,
        .iron_input_mol = amounts[@intFromEnum(snow_solutes.Species.iron)] / ion_molar_mass_g_per_mol.iron,
        .calcium_input_mol = amounts[@intFromEnum(snow_solutes.Species.calcium)] / ion_molar_mass_g_per_mol.calcium,
        .magnesium_input_mol = amounts[@intFromEnum(snow_solutes.Species.magnesium)] / ion_molar_mass_g_per_mol.magnesium,
        .sodium_input_mol = amounts[@intFromEnum(snow_solutes.Species.sodium)] / ion_molar_mass_g_per_mol.sodium,
        .potassium_input_mol = amounts[@intFromEnum(snow_solutes.Species.potassium)] / ion_molar_mass_g_per_mol.potassium,
        .sulfur_input_mol = amounts[@intFromEnum(snow_solutes.Species.sulfate_sulfur)] / ion_molar_mass_g_per_mol.sulfur,
        .chloride_input_mol = amounts[@intFromEnum(snow_solutes.Species.chloride)] / ion_molar_mass_g_per_mol.chloride,
    };
    const salt_first = cell * snow_solutes.salt_species_count;
    for (0..snow_solutes.salt_species_count) |species| {
        const salt_amount = try addNonnegative(&.{
            snow_input_salt_mol[salt_first + species],
            direct_input[cell].litter_salt_mol[species],
            direct_input[cell].soil_nonband_salt_mol[species],
            direct_input[cell].soil_band_salt_mol[species],
        });
        const surface_species = if (species < 33) species else species + 1;
        const formula = surface_aqueous.formula(@enumFromInt(surface_species));
        result.carbon_input_g = try addNonnegative(&.{ result.carbon_input_g, salt_amount * formula.carbon_mol * 12 });
        result.phosphorus_input_g = try addNonnegative(&.{ result.phosphorus_input_g, salt_amount * formula.phosphorus_mol * snow_solutes.phosphorus_g_per_mol });
        inline for (.{
            .{ "aluminum_input_mol", "aluminum_mol" },
            .{ "iron_input_mol", "iron_mol" },
            .{ "calcium_input_mol", "calcium_mol" },
            .{ "magnesium_input_mol", "magnesium_mol" },
            .{ "sodium_input_mol", "sodium_mol" },
            .{ "potassium_input_mol", "potassium_mol" },
            .{ "sulfur_input_mol", "sulfur_mol" },
            .{ "chloride_input_mol", "chloride_mol" },
            .{ "silicon_input_mol", "silicon_mol" },
        }) |names| @field(result, names[0]) = try addNonnegative(&.{
            @field(result, names[0]),
            salt_amount * @field(formula, names[1]),
        });
    }
    try validateBoundary(result);
    return result;
}

fn addNonnegative(values: []const f64) !f64 {
    var result: f64 = 0;
    for (values) |value| {
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidHourlyCellBoundaryActivity;
        result += value;
        if (!std.math.isFinite(result)) return error.HourlyCellBoundaryOverflow;
    }
    return result;
}

/// One-hour, horizontal-cell boundary ledger. It is reset at the pre-hour
/// snapshot and mutated only by accepted producer outputs. Directional fields
/// stay nonnegative; signed producer terms are split at this boundary.
/// Exact internal reference-state term paired with WATSUB's endpoint heat
/// capacity. Positive ice change releases the fixed liquid/ice reference
/// difference; positive represented-vapor change is evaporation and consumes
/// latent heat. Atmospheric vapor is a boundary carrier and is excluded.
pub fn surfaceEndpointReferenceHeatMegajoules(
    ice_water_equivalent_change_m3: f64,
    internal_vapor_water_change_m3: f64,
    liquid_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_per_water_equivalent_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
) !f64 {
    inline for (.{
        ice_water_equivalent_change_m3,
        internal_vapor_water_change_m3,
        liquid_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_per_water_equivalent_m3_k,
        pure_water_melting_temperature_k,
        latent_heat_of_vaporization_megajoules_per_m3,
    }) |value| if (!std.math.isFinite(value))
        return error.InvalidSurfaceEndpointReferenceHeat;
    inline for (.{
        liquid_heat_capacity_megajoules_per_m3_k,
        ice_heat_capacity_per_water_equivalent_m3_k,
        pure_water_melting_temperature_k,
        latent_heat_of_vaporization_megajoules_per_m3,
    }) |value| if (value <= 0)
        return error.InvalidSurfaceEndpointReferenceHeat;
    const signed_heat_megajoules =
        (liquid_heat_capacity_megajoules_per_m3_k -
            ice_heat_capacity_per_water_equivalent_m3_k) *
        pure_water_melting_temperature_k *
        ice_water_equivalent_change_m3 -
        latent_heat_of_vaporization_megajoules_per_m3 *
            internal_vapor_water_change_m3;
    if (!std.math.isFinite(signed_heat_megajoules))
        return error.InvalidSurfaceEndpointReferenceHeat;
    return signed_heat_megajoules;
}

/// TEMP_DIAGNOSTIC (`issue-100`): the hour the nitrogen trace below is allowed
/// to speak on. The ledger has no access to the clock, and the booking helpers
/// run many times per hour, so an ungated trace would flush tens of thousands
/// of lines (`run_support.zig:448` flushes every line -- an unconditional
/// census trace previously cost about 140x throughput). Set once per hour by
/// the driver next to `reset()`; zero means silent.
pub var diagnostic_nitrogen_trace_hour: usize = 0;
/// TEMP_DIAGNOSTIC (`issue-100`): the failing `acceptHourAndPublish` is
/// attempted hour 3,276 (`executed_weather_hours + 1`); earlier probes gated on
/// 3,275 described the last ACCEPTED hour instead.
pub const diagnostic_nitrogen_trace_target_hour: usize = 3276;
/// TEMP_DIAGNOSTIC (`issue-100`): counts `at_evaluate` invocations in the
/// target hour, so a retried hour is distinguishable from a single call.
pub var diagnostic_at_evaluate_invocations: usize = 0;

pub const BoundaryLedger = struct {
    allocator: std.mem.Allocator,
    cells: []BoundaryActivity,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize) !BoundaryLedger {
        if (cell_count == 0) return error.ZeroHourlyCellBoundaryExtent;
        const cells = try allocator.alloc(BoundaryActivity, cell_count);
        @memset(cells, .{});
        // TEMP_DIAGNOSTIC (`issue-100`): a presence marker, so that "the probe
        // below fired zero times" is distinguishable from "the probe was not
        // in the binary I ran". Also reports the ledger extent, which decides
        // whether the failing row's `cell=2` can be an index into this slice
        // at all.
        if (!@import("builtin").is_test) std.log.err(
            "TEMP_DIAGNOSTIC n_ledger[init]: cells.len={d}",
            .{cell_count},
        );
        return .{ .allocator = allocator, .cells = cells };
    }

    pub fn deinit(self: *BoundaryLedger) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn reset(self: *BoundaryLedger) void {
        @memset(self.cells, .{});
    }

    // TEMP_DIAGNOSTIC (`issue-100`): hour 3,275 cell 2 reports
    // `external_inputs=1.7186002174175976`, `external_outputs=6.85290171591924e-2`
    // and `residual=-6.766553859959434e-2` -- 0.0677 g N that never reaches
    // storage. Logging every nitrogen contribution as the ledger books it
    // splits the two possibilities outright: if these sum to the reported
    // external terms then the LEDGER is right and the STORAGE census is short,
    // which is a state problem rather than an accounting one.
    //
    // The first attempt instrumented `accumulate` alone and fired ZERO times
    // while cell 2 still reached 1.7186, which proved the booking arrives by
    // one of the other two mutation paths. This helper is called from all
    // three so the measurement cannot be incomplete the same way twice.
    // Scoped to cell 2 and nonzero nitrogen so the volume stays small.
    fn traceNitrogen(
        site: []const u8,
        cells_ptr: usize,
        cell: usize,
        activity: BoundaryActivity,
        next: BoundaryActivity,
    ) void {
        if (@import("builtin").is_test) return;
        if (diagnostic_nitrogen_trace_hour != diagnostic_nitrogen_trace_target_hour) return;
        // Every cell, not just cell 2. The run that motivated this probe logged
        // TWO failing nitrogen rows -- cell 0 and cell 2 -- losing the same
        // 0.0676655386 g N to eleven digits despite storage differing 12.7x
        // (641.81 vs 50.41) and cell 0's external_outputs being 4.03e-16
        // against cell 2's 6.85e-2. Cell 0 is the cleaner experiment because
        // its outputs are effectively zero, and the first probe filtered it
        // out. The hour gate keeps the volume trivial either way.
        if (activity.nitrogen_input_g == 0 and activity.nitrogen_output_g == 0) return;
        std.log.err(
            "TEMP_DIAGNOSTIC n_ledger[{s}]: cells_ptr=0x{x} cell={d} in={e} out={e} running_in={e} running_out={e}",
            .{
                site,
                cells_ptr,
                cell,
                activity.nitrogen_input_g,
                activity.nitrogen_output_g,
                next.nitrogen_input_g,
                next.nitrogen_output_g,
            },
        );
    }

    pub fn accumulate(self: *BoundaryLedger, cell: usize, activity: BoundaryActivity) !void {
        try self.preflight(cell, activity);
        const next = try addBoundary(self.cells[cell], activity);
        traceNitrogen("accumulate", @intFromPtr(self.cells.ptr), cell, activity, next);
        self.cells[cell] = next;
    }

    /// Atomically publishes one activity per cell. Every addition is checked
    /// against the current ledger before any cell changes, so an invalid late
    /// producer value cannot leave earlier cells booked on a failed attempt.
    pub fn accumulateCells(self: *BoundaryLedger, activities: []const BoundaryActivity) !void {
        if (activities.len != self.cells.len)
            return error.HourlyCellBoundaryDimensionMismatch;
        for (activities, 0..) |activity, cell| try self.preflight(cell, activity);
        for (activities, 0..) |activity, cell| {
            const next = addBoundary(self.cells[cell], activity) catch unreachable;
            traceNitrogen("accumulateCells", @intFromPtr(self.cells.ptr), cell, activity, next);
            self.cells[cell] = next;
        }
    }

    pub fn preflight(self: *const BoundaryLedger, cell: usize, activity: BoundaryActivity) !void {
        if (cell >= self.cells.len) return error.HourlyCellBoundaryIndexOutOfBounds;
        _ = try addBoundary(self.cells[cell], activity);
    }

    /// Atomically books one producer-resolved intercell transfer. Both sides
    /// are preflighted before either cell is changed, so a late overflow or an
    /// invalid amount cannot leave a one-sided debit/credit.
    pub fn accumulateIntercell(
        self: *BoundaryLedger,
        donor_cell: usize,
        recipient_cell: usize,
        transfer: IntercellTransfer,
    ) !void {
        if (donor_cell >= self.cells.len or recipient_cell >= self.cells.len)
            return error.HourlyCellBoundaryIndexOutOfBounds;
        if (donor_cell == recipient_cell)
            return error.InvalidHourlyCellIntercellTransfer;
        try validateIntercellTransfer(transfer);
        const donor_activity = transferBoundary(transfer, .output);
        const recipient_activity = transferBoundary(transfer, .input);
        const donor_next = try addBoundary(self.cells[donor_cell], donor_activity);
        const recipient_next = try addBoundary(self.cells[recipient_cell], recipient_activity);
        traceNitrogen("intercell_donor", @intFromPtr(self.cells.ptr), donor_cell, donor_activity, donor_next);
        traceNitrogen("intercell_recipient", @intFromPtr(self.cells.ptr), recipient_cell, recipient_activity, recipient_next);
        self.cells[donor_cell] = donor_next;
        self.cells[recipient_cell] = recipient_next;
    }

    pub fn preflightIntercell(
        self: *const BoundaryLedger,
        donor_cell: usize,
        recipient_cell: usize,
        transfer: IntercellTransfer,
    ) !void {
        if (donor_cell >= self.cells.len or recipient_cell >= self.cells.len)
            return error.HourlyCellBoundaryIndexOutOfBounds;
        if (donor_cell == recipient_cell)
            return error.InvalidHourlyCellIntercellTransfer;
        try validateIntercellTransfer(transfer);
        _ = try addBoundary(self.cells[donor_cell], transferBoundary(transfer, .output));
        _ = try addBoundary(self.cells[recipient_cell], transferBoundary(transfer, .input));
    }

    pub fn accumulateSignedHeat(self: *BoundaryLedger, signed_heat_megajoules_by_cell: []const f64) !void {
        try self.preflightSignedHeat(signed_heat_megajoules_by_cell);
        for (self.cells, signed_heat_megajoules_by_cell) |*current, signed|
            current.* = try addBoundary(current.*, if (signed >= 0)
                .{ .heat_input_megajoules = signed }
            else
                .{ .heat_output_megajoules = -signed });
    }

    /// Direction-separated internal thermal production/consumption. These
    /// terms alter inventoried enthalpy without crossing the modeled boundary
    /// (combustion, phase/reference rebasing, and soil/plant heat transfer).
    pub fn accumulateSignedInternalHeat(self: *BoundaryLedger, signed_heat_megajoules_by_cell: []const f64) !void {
        try self.preflightSignedInternalHeat(signed_heat_megajoules_by_cell);
        for (self.cells, signed_heat_megajoules_by_cell) |*current, signed|
            current.* = try addBoundary(current.*, if (signed >= 0)
                .{ .heat_internal_production_megajoules = signed }
            else
                .{ .heat_internal_consumption_megajoules = -signed });
    }

    /// Cell-resolved counterpart of the accepted landscape HEATH + THFLXC
    /// booking. Ground fluxes are positive into the ecosystem and per area;
    /// canopy water-energy changes are already extensive signed MJ by cell.
    /// Keeping this producer cell-indexed prevents opposite surface/canopy
    /// defects from disappearing in the domain sum.
    pub fn accumulateSurfaceAndCanopyHeat(
        self: *BoundaryLedger,
        ground_net_radiation_megajoules_per_m2: []const f64,
        ground_sensible_heat_megajoules_per_m2: []const f64,
        ground_latent_heat_megajoules_per_m2: []const f64,
        ground_vapor_sensible_heat_megajoules_per_m2: []const f64,
        cell_area_m2: []const f64,
        canopy_water_energy_change_megajoules: []const f64,
    ) !void {
        const cells = self.cells.len;
        inline for (.{
            ground_net_radiation_megajoules_per_m2,
            ground_sensible_heat_megajoules_per_m2,
            ground_latent_heat_megajoules_per_m2,
            ground_vapor_sensible_heat_megajoules_per_m2,
            cell_area_m2,
            canopy_water_energy_change_megajoules,
        }) |values| if (values.len != cells)
            return error.HourlyCellBoundaryDimensionMismatch;
        const signed = try self.allocator.alloc(f64, cells);
        defer self.allocator.free(signed);
        for (signed, 0..) |*value, cell| {
            const area_m2 = cell_area_m2[cell];
            inline for (.{
                ground_net_radiation_megajoules_per_m2[cell],
                ground_sensible_heat_megajoules_per_m2[cell],
                ground_latent_heat_megajoules_per_m2[cell],
                ground_vapor_sensible_heat_megajoules_per_m2[cell],
                area_m2,
                canopy_water_energy_change_megajoules[cell],
            }) |part| if (!std.math.isFinite(part))
                return error.InvalidHourlyCellBoundaryActivity;
            if (area_m2 <= 0) return error.InvalidHourlyCellBoundaryActivity;
            value.* = (ground_net_radiation_megajoules_per_m2[cell] +
                ground_sensible_heat_megajoules_per_m2[cell] +
                ground_latent_heat_megajoules_per_m2[cell] +
                ground_vapor_sensible_heat_megajoules_per_m2[cell]) * area_m2 +
                canopy_water_energy_change_megajoules[cell];
            if (!std.math.isFinite(value.*))
                return error.InvalidHourlyCellBoundaryActivity;
        }
        try self.accumulateSignedHeat(signed);
    }

    /// Cell-resolved internal heat needed to reconcile the endpoint-capacity
    /// WATSUB surface solve with the conserved surface enthalpy census. Fusion
    /// latent heat is already in the solved surface flux; represented internal
    /// liquid/vapor exchange contributes its opposite latent term.
    pub fn accumulateSurfaceEndpointReferenceHeat(
        self: *BoundaryLedger,
        ice_water_equivalent_change_m3: []const f64,
        internal_vapor_water_change_m3: []const f64,
        liquid_heat_capacity_megajoules_per_m3_k: f64,
        ice_heat_capacity_per_water_equivalent_m3_k: f64,
        pure_water_melting_temperature_k: f64,
        latent_heat_of_vaporization_megajoules_per_m3: f64,
    ) !void {
        const cells = self.cells.len;
        inline for (.{
            ice_water_equivalent_change_m3,
            internal_vapor_water_change_m3,
        }) |values| if (values.len != cells)
            return error.HourlyCellBoundaryDimensionMismatch;
        const signed = try self.allocator.alloc(f64, cells);
        defer self.allocator.free(signed);
        for (signed, 0..) |*value, cell| {
            value.* = surfaceEndpointReferenceHeatMegajoules(
                ice_water_equivalent_change_m3[cell],
                internal_vapor_water_change_m3[cell],
                liquid_heat_capacity_megajoules_per_m3_k,
                ice_heat_capacity_per_water_equivalent_m3_k,
                pure_water_melting_temperature_k,
                latent_heat_of_vaporization_megajoules_per_m3,
            ) catch return error.InvalidHourlyCellBoundaryActivity;
        }
        try self.accumulateSignedInternalHeat(signed);
    }

    pub fn preflightSignedHeat(self: *const BoundaryLedger, signed_heat_megajoules_by_cell: []const f64) !void {
        if (signed_heat_megajoules_by_cell.len != self.cells.len)
            return error.HourlyCellBoundaryDimensionMismatch;
        for (self.cells, signed_heat_megajoules_by_cell) |current, signed| {
            if (!std.math.isFinite(signed)) return error.InvalidHourlyCellBoundaryActivity;
            _ = try addBoundary(current, if (signed >= 0)
                .{ .heat_input_megajoules = signed }
            else
                .{ .heat_output_megajoules = -signed });
        }
    }

    pub fn preflightSignedInternalHeat(self: *const BoundaryLedger, signed_heat_megajoules_by_cell: []const f64) !void {
        if (signed_heat_megajoules_by_cell.len != self.cells.len)
            return error.HourlyCellBoundaryDimensionMismatch;
        for (self.cells, signed_heat_megajoules_by_cell) |current, signed| {
            if (!std.math.isFinite(signed)) return error.InvalidHourlyCellBoundaryActivity;
            _ = try addBoundary(current, if (signed >= 0)
                .{ .heat_internal_production_megajoules = signed }
            else
                .{ .heat_internal_consumption_megajoules = -signed });
        }
    }

    pub fn accumulateHeat(
        self: *BoundaryLedger,
        input_megajoules_by_cell: []const f64,
        output_megajoules_by_cell: []const f64,
    ) !void {
        if (input_megajoules_by_cell.len != self.cells.len or output_megajoules_by_cell.len != self.cells.len)
            return error.HourlyCellBoundaryDimensionMismatch;
        for (self.cells, input_megajoules_by_cell, output_megajoules_by_cell) |current, input, output|
            _ = try addBoundary(current, .{ .heat_input_megajoules = input, .heat_output_megajoules = output });
        for (self.cells, input_megajoules_by_cell, output_megajoules_by_cell) |*current, input, output|
            current.* = try addBoundary(current.*, .{ .heat_input_megajoules = input, .heat_output_megajoules = output });
    }
};

/// Books exact accepted active-layer heat producers. Combustion is consumed
/// by the soil solver; current root-water convective heat is published with
/// TUPWTR after UPTAKE (and restored legacy checkpoint heat can still be
/// consumed by WATSUB). Root heat retains its REDIST sign. Inactive capacity
/// is excluded and every cell is preflighted before any ledger entry changes.
pub fn accumulateSubsurfaceCombustionAndRootHeat(
    ledger: *BoundaryLedger,
    active_soil_layer_count: []const usize,
    soil_layer_capacity: usize,
    combustion_heat_megajoules_by_layer: []const f64,
    root_uptake_heat_megajoules_by_layer: []const f64,
) !void {
    if (active_soil_layer_count.len != ledger.cells.len or soil_layer_capacity == 0)
        return error.HourlyCellBoundaryDimensionMismatch;
    const layer_count = try std.math.mul(usize, ledger.cells.len, soil_layer_capacity);
    if (combustion_heat_megajoules_by_layer.len != layer_count or
        root_uptake_heat_megajoules_by_layer.len != layer_count)
        return error.HourlyCellBoundaryDimensionMismatch;

    const activities = try ledger.allocator.alloc(BoundaryActivity, ledger.cells.len);
    defer ledger.allocator.free(activities);
    @memset(activities, .{});
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        if (active_layers > soil_layer_capacity)
            return error.HourlyCellBoundaryDimensionMismatch;
        const first = cell * soil_layer_capacity;
        for (0..active_layers) |local_layer| {
            const layer = first + local_layer;
            const combustion = combustion_heat_megajoules_by_layer[layer];
            const root = root_uptake_heat_megajoules_by_layer[layer];
            if (!std.math.isFinite(combustion) or combustion < 0 or
                !std.math.isFinite(root))
                return error.InvalidHourlyCellBoundaryActivity;
            activities[cell].heat_internal_production_megajoules = try addNonnegative(&.{
                activities[cell].heat_internal_production_megajoules,
                combustion,
                @max(0, root),
            });
            activities[cell].heat_internal_consumption_megajoules = try addNonnegative(&.{
                activities[cell].heat_internal_consumption_megajoules,
                @max(0, -root),
            });
        }
    }
    try ledger.accumulateCells(activities);
}

/// Books the accepted subsurface microbial O2 sink in the same horizontal
/// cell partition used by the inventory. The producer is process-unit indexed;
/// inactive capacity is deliberately excluded from the accepted-hour sum.
pub fn accumulateSoilMicrobialOxygenUptake(
    ledger: *BoundaryLedger,
    active_soil_layer_count: []const usize,
    soil_layer_capacity: usize,
    process_units_per_layer: usize,
    oxygen_uptake_g_o: []const f64,
) !void {
    if (active_soil_layer_count.len != ledger.cells.len or
        soil_layer_capacity == 0 or process_units_per_layer == 0)
        return error.HourlyCellBoundaryDimensionMismatch;
    const layer_count = try std.math.mul(usize, ledger.cells.len, soil_layer_capacity);
    const expected = try std.math.mul(usize, layer_count, process_units_per_layer);
    if (oxygen_uptake_g_o.len != expected)
        return error.HourlyCellBoundaryDimensionMismatch;

    const activities = try ledger.allocator.alloc(BoundaryActivity, ledger.cells.len);
    defer ledger.allocator.free(activities);
    @memset(activities, .{});
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        if (active_layers > soil_layer_capacity)
            return error.HourlyCellBoundaryDimensionMismatch;
        var total: f64 = 0;
        for (0..active_layers) |local_layer| {
            const layer = cell * soil_layer_capacity + local_layer;
            const first = layer * process_units_per_layer;
            total = try addNonnegative(&.{
                total,
                try addNonnegative(oxygen_uptake_g_o[first..][0..process_units_per_layer]),
            });
        }
        activities[cell].oxygen_internal_consumption_g = total;
    }
    try ledger.accumulateCells(activities);
}

/// Books accepted root respiration in the same cell/layer partition as the
/// soil and root O2 storage census. UPTAKE consumes soil dissolved O2
/// (`TUPOXS`) and root aqueous O2 (`TUPOXP`); REDIST publishes their sum to
/// `OXYGOU`. Inactive capacity is excluded and every cell is preflighted
/// before any ledger entry changes.
pub fn accumulateRootOxygenUptake(
    ledger: *BoundaryLedger,
    active_soil_layer_count: []const usize,
    soil_layer_capacity: usize,
    soil_oxygen_uptake_g_o: []const f64,
    root_pool_oxygen_uptake_g_o: []const f64,
) !void {
    if (active_soil_layer_count.len != ledger.cells.len or
        soil_layer_capacity == 0)
        return error.HourlyCellBoundaryDimensionMismatch;
    const layer_count = try std.math.mul(usize, ledger.cells.len, soil_layer_capacity);
    if (soil_oxygen_uptake_g_o.len != layer_count or
        root_pool_oxygen_uptake_g_o.len != layer_count)
        return error.HourlyCellBoundaryDimensionMismatch;

    const activities = try ledger.allocator.alloc(BoundaryActivity, ledger.cells.len);
    defer ledger.allocator.free(activities);
    @memset(activities, .{});
    for (active_soil_layer_count, 0..) |active_layers, cell| {
        if (active_layers > soil_layer_capacity)
            return error.HourlyCellBoundaryDimensionMismatch;
        var total: f64 = 0;
        for (0..active_layers) |local_layer| {
            const layer = cell * soil_layer_capacity + local_layer;
            total = try addNonnegative(&.{
                total,
                soil_oxygen_uptake_g_o[layer],
                root_pool_oxygen_uptake_g_o[layer],
            });
        }
        activities[cell].oxygen_internal_consumption_g = total;
    }
    try ledger.accumulateCells(activities);
}

/// Surface respiration and surface combustion both debit the authoritative
/// litter-gas O2 pools. Their producer-resolved sinks are combined per cell and
/// published atomically after every surface fire cell has been finalized.
pub fn accumulateSurfaceMicrobialAndFireOxygenUptake(
    ledger: *BoundaryLedger,
    microbial_units_per_cell: usize,
    microbial_oxygen_uptake_g_o: []const f64,
    fire_oxygen_consumption_g_o: []const f64,
) !void {
    if (microbial_units_per_cell == 0 or
        fire_oxygen_consumption_g_o.len != ledger.cells.len or
        microbial_oxygen_uptake_g_o.len != try std.math.mul(usize, ledger.cells.len, microbial_units_per_cell))
        return error.HourlyCellBoundaryDimensionMismatch;

    const activities = try ledger.allocator.alloc(BoundaryActivity, ledger.cells.len);
    defer ledger.allocator.free(activities);
    @memset(activities, .{});
    for (0..ledger.cells.len) |cell| {
        const first = cell * microbial_units_per_cell;
        activities[cell].oxygen_internal_consumption_g = try addNonnegative(&.{
            try addNonnegative(microbial_oxygen_uptake_g_o[first..][0..microbial_units_per_cell]),
            fire_oxygen_consumption_g_o[cell],
        });
    }
    try ledger.accumulateCells(activities);
}

/// Exact active-layer subsurface/root fire O2 sink for one horizontal cell.
/// `finalizeLayer` has already debited these amounts from counted soil-gas
/// storage; inactive capacity must not leak into accepted-hour activity.
pub fn soilFireOxygenConsumptionForCell(
    oxygen_consumption_g_o_by_layer: []const f64,
    cell: usize,
    active_soil_layers: usize,
    soil_layer_capacity: usize,
) !f64 {
    if (soil_layer_capacity == 0 or active_soil_layers > soil_layer_capacity)
        return error.HourlyCellBoundaryDimensionMismatch;
    const first = try std.math.mul(usize, cell, soil_layer_capacity);
    const end = try std.math.add(usize, first, soil_layer_capacity);
    if (end > oxygen_consumption_g_o_by_layer.len)
        return error.HourlyCellBoundaryDimensionMismatch;
    return addNonnegative(oxygen_consumption_g_o_by_layer[first..][0..active_soil_layers]);
}

/// Books accepted horizontal soil water/vapor and heat face transfers at
/// their producing face resolution. Vertical faces remain internal to one
/// horizontal control volume. Positive flux is first layer -> second layer,
/// matching the transport face contract; water and heat are oriented
/// independently because conduction can oppose advective water motion.
pub fn accumulateSoilFaceTransfers(
    ledger: *BoundaryLedger,
    faces: *const transport_hydrology.SoilFaces,
    soil_layer_capacity: usize,
) !void {
    if (soil_layer_capacity == 0) return error.HourlyCellBoundaryDimensionMismatch;
    const count = faces.direction_axis.len;
    if (faces.micropore_faces.len != count or faces.macropore_faces.len != count or
        faces.active_by_face.len != count or
        faces.micropore_water_flux_m3_per_step.len != count or
        faces.macropore_water_flux_m3_per_step.len != count or
        faces.vapor_flux_m3_per_step.len != count or
        faces.heat_flux_megajoules_per_step.len != count)
        return error.HourlyCellBoundaryDimensionMismatch;
    const layer_count = try std.math.mul(usize, ledger.cells.len, soil_layer_capacity);
    for (0..count) |face| try applySoilFaceTransfer(ledger, faces, soil_layer_capacity, layer_count, face, true);
    for (0..count) |face| try applySoilFaceTransfer(ledger, faces, soil_layer_capacity, layer_count, face, false);
}

/// Books the accepted implicit micropore+macropore aqueous face fluxes by
/// chemical formula. Each conserved element is oriented independently after
/// the two pore-domain fluxes are combined, so opposing species movements
/// cannot be assigned the sign of an unrelated aggregate ion scalar.
pub fn accumulateAqueousFaceTransfers(
    ledger: *BoundaryLedger,
    faces: *const transport_hydrology.SoilFaces,
    micropore_face_flux_mol: []const f64,
    macropore_face_flux_mol: []const f64,
    soil_layer_capacity: usize,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !void {
    if (soil_layer_capacity == 0 or !std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_g_per_mol) or phosphorus_g_per_mol <= 0)
        return error.HourlyCellBoundaryDimensionMismatch;
    const face_components = try std.math.mul(usize, faces.direction_axis.len, solute_species.AqueousSpecies.count);
    if (faces.micropore_faces.len != faces.direction_axis.len or faces.macropore_faces.len != faces.direction_axis.len or
        faces.active_by_face.len != faces.direction_axis.len or
        micropore_face_flux_mol.len != face_components or macropore_face_flux_mol.len != face_components)
        return error.HourlyCellBoundaryDimensionMismatch;
    const layer_count = try std.math.mul(usize, ledger.cells.len, soil_layer_capacity);
    for (0..faces.direction_axis.len) |face| try applyAqueousFaceTransfer(
        ledger,
        faces,
        micropore_face_flux_mol,
        macropore_face_flux_mol,
        soil_layer_capacity,
        layer_count,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
        face,
        true,
    );
    for (0..faces.direction_axis.len) |face| try applyAqueousFaceTransfer(
        ledger,
        faces,
        micropore_face_flux_mol,
        macropore_face_flux_mol,
        soil_layer_capacity,
        layer_count,
        carbon_g_per_mol,
        phosphorus_g_per_mol,
        face,
        false,
    );
}

/// Books accepted signed aqueous exchange through all external soil faces.
/// The producer layout is layer-capacity × the named species registry; each horizontal cell
/// retains independent input/output directions so opposing faces or species
/// cannot cancel before cell-scale closure is evaluated.
pub fn accumulateAqueousExternalBoundaries(
    ledger: *BoundaryLedger,
    boundary_net_flux_mol_by_layer_species: []const f64,
    active_by_layer: []const bool,
    soil_layer_capacity: usize,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
) !void {
    // Formula-resolved expansion intentionally instantiates every named
    // carrier; the default comptime quota became insufficient when the four
    // source-required bare phosphate coordinates were added.
    @setEvalBranchQuota(10_000);
    if (soil_layer_capacity == 0 or
        !std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_g_per_mol) or phosphorus_g_per_mol <= 0)
        return error.HourlyCellBoundaryDimensionMismatch;
    const layer_count = try std.math.mul(usize, ledger.cells.len, soil_layer_capacity);
    const expected = try std.math.mul(usize, layer_count, solute_species.AqueousSpecies.count);
    if (boundary_net_flux_mol_by_layer_species.len != expected or active_by_layer.len != layer_count)
        return error.HourlyCellBoundaryDimensionMismatch;
    for (0..ledger.cells.len) |cell|
        try ledger.preflight(cell, try aqueousExternalActivityForCell(
            boundary_net_flux_mol_by_layer_species,
            active_by_layer,
            soil_layer_capacity,
            carbon_g_per_mol,
            phosphorus_g_per_mol,
            cell,
        ));
    for (0..ledger.cells.len) |cell|
        try ledger.accumulate(cell, aqueousExternalActivityForCell(
            boundary_net_flux_mol_by_layer_species,
            active_by_layer,
            soil_layer_capacity,
            carbon_g_per_mol,
            phosphorus_g_per_mol,
            cell,
        ) catch unreachable);
}

fn aqueousExternalActivityForCell(
    fluxes: []const f64,
    active_by_layer: []const bool,
    soil_layer_capacity: usize,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    cell: usize,
) !BoundaryActivity {
    var activity: BoundaryActivity = .{};
    const accumulator: AqueousExternalAccumulator = .{
        .activity = &activity,
        .carbon_g_per_mol = carbon_g_per_mol,
        .phosphorus_g_per_mol = phosphorus_g_per_mol,
    };
    for (0..soil_layer_capacity) |local_layer| {
        const layer = cell * soil_layer_capacity + local_layer;
        if (!active_by_layer[layer]) continue;
        const first = layer * solute_species.AqueousSpecies.count;
        // This must remain an ordinary ascending runtime loop. The previous
        // reflected `inline for` instantiated the complete formula switch and
        // all element updates once per species inside every caller.
        for (0..solute_species.AqueousSpecies.count) |species_index| {
            const species: solute_species.AqueousSpecies = @enumFromInt(species_index);
            try accumulator.accumulateSpecies(species, fluxes[first + species_index]);
        }
    }
    try validateAqueousExternalActivity(&activity);
    return activity;
}

const AqueousExternalAccumulator = struct {
    activity: *BoundaryActivity,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,

    /// Keeping the formula switch and element updates in one separately
    /// optimized function prevents LLVM from cloning them for all 54 species.
    noinline fn accumulateSpecies(
        self: AqueousExternalAccumulator,
        species: solute_species.AqueousSpecies,
        signed_mol: f64,
    ) !void {
        if (!std.math.isFinite(signed_mol)) return error.InvalidHourlyCellBoundaryActivity;
        const amount_mol = @abs(signed_mol);
        const formula = surface_aqueous.formula(species);
        if (signed_mol >= 0) {
            self.activity.carbon_input_g += amount_mol * formula.carbon_mol * self.carbon_g_per_mol;
            self.activity.phosphorus_input_g += amount_mol * formula.phosphorus_mol * self.phosphorus_g_per_mol;
            self.activity.aluminum_input_mol += amount_mol * formula.aluminum_mol;
            self.activity.iron_input_mol += amount_mol * formula.iron_mol;
            self.activity.calcium_input_mol += amount_mol * formula.calcium_mol;
            self.activity.magnesium_input_mol += amount_mol * formula.magnesium_mol;
            self.activity.sodium_input_mol += amount_mol * formula.sodium_mol;
            self.activity.potassium_input_mol += amount_mol * formula.potassium_mol;
            self.activity.sulfur_input_mol += amount_mol * formula.sulfur_mol;
            self.activity.chloride_input_mol += amount_mol * formula.chloride_mol;
            self.activity.silicon_input_mol += amount_mol * formula.silicon_mol;
        } else {
            self.activity.carbon_output_g += amount_mol * formula.carbon_mol * self.carbon_g_per_mol;
            self.activity.phosphorus_output_g += amount_mol * formula.phosphorus_mol * self.phosphorus_g_per_mol;
            self.activity.aluminum_output_mol += amount_mol * formula.aluminum_mol;
            self.activity.iron_output_mol += amount_mol * formula.iron_mol;
            self.activity.calcium_output_mol += amount_mol * formula.calcium_mol;
            self.activity.magnesium_output_mol += amount_mol * formula.magnesium_mol;
            self.activity.sodium_output_mol += amount_mol * formula.sodium_mol;
            self.activity.potassium_output_mol += amount_mol * formula.potassium_mol;
            self.activity.sulfur_output_mol += amount_mol * formula.sulfur_mol;
            self.activity.chloride_output_mol += amount_mol * formula.chloride_mol;
            self.activity.silicon_output_mol += amount_mol * formula.silicon_mol;
        }
    }
};

noinline fn validateAqueousExternalActivity(activity: *const BoundaryActivity) !void {
    inline for (std.meta.fields(BoundaryActivity)) |field|
        if (!std.math.isFinite(@field(activity.*, field.name)) or @field(activity.*, field.name) < 0)
            return error.HourlyCellBoundaryOverflow;
}

comptime {
    const fields = @typeInfo(solute_species.AqueousSpecies).@"enum".fields;
    if (fields.len != solute_species.AqueousSpecies.count)
        @compileError("aqueous species count no longer matches its enum registry");
    for (fields, 0..) |field, expected_index|
        if (field.value != expected_index)
            @compileError("aqueous species values must remain contiguous and declaration-ordered");
}

/// Books exact accepted dry-gas face fluxes between horizontal cell scopes.
/// Gas species are already stored as grams of their tracked element, so only
/// the scientifically required species-to-element reduction is performed.
pub fn accumulateGasFaceTransfers(
    ledger: *BoundaryLedger,
    state: *const gas_transport_step.State,
    soil_layer_capacity: usize,
) !void {
    if (soil_layer_capacity == 0) return error.HourlyCellBoundaryDimensionMismatch;
    const components = try std.math.mul(usize, state.accepted_faces.len, gas_transport.species_count);
    if (state.accepted_face_flux_g_per_h.len != components)
        return error.HourlyCellBoundaryDimensionMismatch;
    const layer_count = try std.math.mul(usize, ledger.cells.len, soil_layer_capacity);
    for (state.accepted_faces, 0..) |face, face_index| try applyGasFaceTransfer(
        ledger,
        face,
        state.accepted_face_flux_g_per_h,
        soil_layer_capacity,
        layer_count,
        face_index,
        true,
    );
    for (state.accepted_faces, 0..) |face, face_index| try applyGasFaceTransfer(
        ledger,
        face,
        state.accepted_face_flux_g_per_h,
        soil_layer_capacity,
        layer_count,
        face_index,
        false,
    );
}

/// Books accepted dissolved-gas aqueous boundary and horizontal face
/// activity from the producer's signed, extensive outputs. The NH3 mirror is
/// excluded because mineral-N transport owns that mass.
pub fn accumulateDissolvedGasTransport(
    ledger: *BoundaryLedger,
    faces: *const transport_hydrology.SoilFaces,
    boundary_net_flux_g: []const f64,
    micropore_face_flux_g: []const f64,
    macropore_face_flux_g: []const f64,
    soil_layer_capacity: usize,
) !void {
    const layer_count = try validateDedicatedTransportLayout(
        ledger,
        faces,
        boundary_net_flux_g,
        micropore_face_flux_g,
        macropore_face_flux_g,
        soil_layer_capacity,
        gas_transport.species_count,
    );
    if (boundary_net_flux_g.len != try std.math.mul(usize, layer_count, gas_transport.species_count))
        return error.HourlyCellBoundaryDimensionMismatch;
    const activities = try ledger.allocator.alloc(BoundaryActivity, ledger.cells.len);
    defer ledger.allocator.free(activities);
    @memset(activities, .{});
    for (0..layer_count) |layer| {
        if (!faces.active_by_layer[layer]) continue;
        for (0..gas_transport.species_count) |species_index| {
            const species: gas_transport.Species = @enumFromInt(species_index);
            if (species == .ammonia) continue;
            const signed = boundary_net_flux_g[layer * gas_transport.species_count + species_index];
            switch (species) {
                .carbon_dioxide, .methane => try addSignedBoundary(&activities[layer / soil_layer_capacity], signed, "carbon_input_g", "carbon_output_g"),
                .oxygen => try addSignedBoundary(&activities[layer / soil_layer_capacity], signed, "oxygen_input_g", "oxygen_output_g"),
                .nitrogen, .nitrous_oxide => try addSignedBoundary(&activities[layer / soil_layer_capacity], signed, "nitrogen_input_g", "nitrogen_output_g"),
                .hydrogen => try addSignedBoundary(&activities[layer / soil_layer_capacity], signed, "hydrogen_input_g", "hydrogen_output_g"),
                .ammonia => unreachable,
            }
        }
    }
    for (faces.micropore_faces, 0..) |face, face_index| {
        if (!faces.active_by_face[face_index] or faces.direction_axis[face_index] == 2) continue;
        const first_cell = face.first_cell / soil_layer_capacity;
        const second_cell = face.second_cell / soil_layer_capacity;
        const start = face_index * gas_transport.species_count;
        for (0..gas_transport.species_count) |species_index| {
            const species: gas_transport.Species = @enumFromInt(species_index);
            if (species == .ammonia) continue;
            const signed = try checkedSignedSum(micropore_face_flux_g[start + species_index], macropore_face_flux_g[start + species_index]);
            switch (species) {
                .carbon_dioxide, .methane => try addSignedFace(activities, first_cell, second_cell, signed, "carbon_input_g", "carbon_output_g"),
                .oxygen => try addSignedFace(activities, first_cell, second_cell, signed, "oxygen_input_g", "oxygen_output_g"),
                .nitrogen, .nitrous_oxide => try addSignedFace(activities, first_cell, second_cell, signed, "nitrogen_input_g", "nitrogen_output_g"),
                .hydrogen => try addSignedFace(activities, first_cell, second_cell, signed, "hydrogen_input_g", "hydrogen_output_g"),
                .ammonia => unreachable,
            }
        }
    }
    try ledger.accumulateCells(activities);
}

pub fn accumulateOrganicTransport(
    ledger: *BoundaryLedger,
    faces: *const transport_hydrology.SoilFaces,
    boundary_net_flux_g: []const f64,
    micropore_face_flux_g: []const f64,
    macropore_face_flux_g: []const f64,
    soil_layer_capacity: usize,
) !void {
    const layer_count = try validateDedicatedTransportLayout(
        ledger,
        faces,
        boundary_net_flux_g,
        micropore_face_flux_g,
        macropore_face_flux_g,
        soil_layer_capacity,
        organic_transport.component_count,
    );
    if (boundary_net_flux_g.len != try std.math.mul(usize, layer_count, organic_transport.component_count))
        return error.HourlyCellBoundaryDimensionMismatch;
    const activities = try ledger.allocator.alloc(BoundaryActivity, ledger.cells.len);
    defer ledger.allocator.free(activities);
    @memset(activities, .{});
    for (0..layer_count) |layer| {
        if (!faces.active_by_layer[layer]) continue;
        for (0..organic_transport.component_count) |component| {
            const signed = boundary_net_flux_g[layer * organic_transport.component_count + component];
            switch (component % organic_transport.components_per_substrate) {
                0, 3 => try addSignedBoundary(&activities[layer / soil_layer_capacity], signed, "carbon_input_g", "carbon_output_g"),
                1 => try addSignedBoundary(&activities[layer / soil_layer_capacity], signed, "nitrogen_input_g", "nitrogen_output_g"),
                2 => try addSignedBoundary(&activities[layer / soil_layer_capacity], signed, "phosphorus_input_g", "phosphorus_output_g"),
                else => unreachable,
            }
        }
    }
    for (faces.micropore_faces, 0..) |face, face_index| {
        if (!faces.active_by_face[face_index] or faces.direction_axis[face_index] == 2) continue;
        const first_cell = face.first_cell / soil_layer_capacity;
        const second_cell = face.second_cell / soil_layer_capacity;
        const start = face_index * organic_transport.component_count;
        for (0..organic_transport.component_count) |component| {
            const signed = try checkedSignedSum(micropore_face_flux_g[start + component], macropore_face_flux_g[start + component]);
            switch (component % organic_transport.components_per_substrate) {
                0, 3 => try addSignedFace(activities, first_cell, second_cell, signed, "carbon_input_g", "carbon_output_g"),
                1 => try addSignedFace(activities, first_cell, second_cell, signed, "nitrogen_input_g", "nitrogen_output_g"),
                2 => try addSignedFace(activities, first_cell, second_cell, signed, "phosphorus_input_g", "phosphorus_output_g"),
                else => unreachable,
            }
        }
    }
    try ledger.accumulateCells(activities);
}

pub fn accumulateMineralNitrogenTransport(
    ledger: *BoundaryLedger,
    faces: *const transport_hydrology.SoilFaces,
    boundary_export_g_n: []const f64,
    micropore_face_flux_mol: []const f64,
    macropore_face_flux_mol: []const f64,
    soil_layer_capacity: usize,
    nitrogen_g_per_mol: f64,
) !void {
    if (!std.math.isFinite(nitrogen_g_per_mol) or nitrogen_g_per_mol <= 0)
        return error.InvalidHourlyCellBoundaryMolarMass;
    const layer_count = try validateDedicatedTransportLayout(
        ledger,
        faces,
        boundary_export_g_n,
        micropore_face_flux_mol,
        macropore_face_flux_mol,
        soil_layer_capacity,
        mineral_nitrogen_transport.species_count,
    );
    // Mineral-N publishes one already-reduced boundary export per layer.
    if (boundary_export_g_n.len != layer_count)
        return error.HourlyCellBoundaryDimensionMismatch;
    const activities = try ledger.allocator.alloc(BoundaryActivity, ledger.cells.len);
    defer ledger.allocator.free(activities);
    @memset(activities, .{});
    for (boundary_export_g_n, 0..) |export_g, layer| {
        if (!faces.active_by_layer[layer]) continue;
        try addNonnegativeField(&activities[layer / soil_layer_capacity].nitrogen_output_g, export_g);
    }
    for (faces.micropore_faces, 0..) |face, face_index| {
        if (!faces.active_by_face[face_index] or faces.direction_axis[face_index] == 2) continue;
        const first_cell = face.first_cell / soil_layer_capacity;
        const second_cell = face.second_cell / soil_layer_capacity;
        const start = face_index * mineral_nitrogen_transport.species_count;
        for (0..mineral_nitrogen_transport.species_count) |species| {
            const signed_mol = try checkedSignedSum(micropore_face_flux_mol[start + species], macropore_face_flux_mol[start + species]);
            try addSignedFace(activities, first_cell, second_cell, signed_mol * nitrogen_g_per_mol, "nitrogen_input_g", "nitrogen_output_g");
        }
    }
    try ledger.accumulateCells(activities);
}

pub const ErosionAccountingTolerances = struct {
    absolute_g: f64,
    absolute_mol: f64,
    absolute_megagrams: f64,
    relative: f64,
};

/// Reduces the erosion producers' accepted, source-indexed directional fluxes
/// directly into per-cell activity. Sand/silt/clay are audited from the same
/// authoritative packed workspace that mutates their storage owners.
pub fn accumulateErosionTransport(
    ledger: *BoundaryLedger,
    columns: usize,
    rows: usize,
    organic: *const organic_state.State,
    organic_workspace: *const eroded_constituents.PackedWorkspace,
    fertilizer_workspace: *const eroded_constituents.PackedWorkspace,
    mineral_fertilizer_workspace: *const eroded_constituents.PackedWorkspace,
    chemistry_workspace: *const eroded_constituents.PackedWorkspace,
    mineral_workspace: *const eroded_constituents.PackedWorkspace,
    carbon_g_per_mol: f64,
    nitrogen_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    tolerances: ErosionAccountingTolerances,
) !void {
    const cells = std.math.mul(usize, columns, rows) catch
        return error.HourlyCellBoundaryDimensionMismatch;
    if (cells == 0 or ledger.cells.len != cells or organic.layer_count == 0 or
        !std.math.isFinite(carbon_g_per_mol) or carbon_g_per_mol <= 0 or
        !std.math.isFinite(nitrogen_g_per_mol) or nitrogen_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_g_per_mol) or phosphorus_g_per_mol <= 0 or
        !std.math.isFinite(tolerances.absolute_g) or tolerances.absolute_g < 0 or
        !std.math.isFinite(tolerances.absolute_mol) or tolerances.absolute_mol < 0 or
        !std.math.isFinite(tolerances.absolute_megagrams) or tolerances.absolute_megagrams < 0 or
        !std.math.isFinite(tolerances.relative) or tolerances.relative < 0)
        return error.InvalidHourlyCellErosionAccounting;
    const organic_components = try erosion_organic_bridge.componentCount(organic);
    try validateErosionWorkspace(organic_workspace, cells, organic_components);
    try validateErosionWorkspace(fertilizer_workspace, cells, erosion_fertilizer_bridge.component_count);
    try validateErosionWorkspace(mineral_fertilizer_workspace, cells, erosion_mineral_fertilizer_bridge.component_count);
    try validateErosionWorkspace(chemistry_workspace, cells, erosion_chemistry_bridge.component_count);
    try validateErosionWorkspace(mineral_workspace, cells, erosion_mineral_bridge.component_count);

    const activities = try ledger.allocator.alloc(BoundaryActivity, cells);
    defer ledger.allocator.free(activities);
    @memset(activities, .{});

    for (0..cells) |cell| for (0..organic_components) |component| {
        try bookErodedComponent(
            activities,
            columns,
            rows,
            organic_workspace,
            cell,
            component,
            try organicErosionComposition(organic, component),
            tolerances.absolute_g,
            tolerances.relative,
        );
    };
    for (0..cells) |cell| for (0..erosion_fertilizer_bridge.component_count) |component| {
        try bookErodedComponent(
            activities,
            columns,
            rows,
            fertilizer_workspace,
            cell,
            component,
            .{ .nitrogen_g = nitrogen_g_per_mol },
            tolerances.absolute_mol,
            tolerances.relative,
        );
    };
    for (0..cells) |cell| for (0..erosion_mineral_fertilizer_bridge.component_count) |component| {
        try bookErodedComponent(
            activities,
            columns,
            rows,
            mineral_fertilizer_workspace,
            cell,
            component,
            mineralFertilizerErosionComposition(component, carbon_g_per_mol, phosphorus_g_per_mol),
            tolerances.absolute_mol,
            tolerances.relative,
        );
    };
    for (0..cells) |cell| for (0..erosion_chemistry_bridge.component_count) |component| {
        try bookErodedComponent(
            activities,
            columns,
            rows,
            chemistry_workspace,
            cell,
            component,
            try chemistryErosionComposition(component, carbon_g_per_mol, nitrogen_g_per_mol, phosphorus_g_per_mol),
            tolerances.absolute_mol,
            tolerances.relative,
        );
    };
    for (0..cells) |cell| for (0..erosion_mineral_bridge.component_count) |component| {
        const composition: IntercellTransfer = switch (component) {
            0 => .{ .sand_megagrams = 1 },
            1 => .{ .silt_megagrams = 1 },
            2 => .{ .clay_megagrams = 1 },
            3 => .{ .cation_exchange_capacity_mol = 1 },
            4 => .{ .anion_exchange_capacity_mol = 1 },
            else => unreachable,
        };
        const absolute = if (component < 3) tolerances.absolute_megagrams else tolerances.absolute_mol;
        try bookErodedComponent(activities, columns, rows, mineral_workspace, cell, component, composition, absolute, tolerances.relative);
    };
    // `accumulateCells` preflights the complete candidate before publishing,
    // so a late chemistry overflow cannot leave organic or fertilizer entries.
    try ledger.accumulateCells(activities);
}

fn validateErosionWorkspace(workspace: *const eroded_constituents.PackedWorkspace, cells: usize, components: usize) !void {
    const length = std.math.mul(usize, cells, components) catch
        return error.HourlyCellBoundaryDimensionMismatch;
    if (workspace.cell_count != cells or workspace.component_count != components or
        workspace.exported.len != length or workspace.flux.cell_count != cells or
        workspace.flux.component_count != components or workspace.flux.east.len != length or
        workspace.flux.west.len != length or workspace.flux.south.len != length or
        workspace.flux.north.len != length)
        return error.HourlyCellBoundaryDimensionMismatch;
}

fn bookErodedComponent(
    activities: []BoundaryActivity,
    columns: usize,
    rows: usize,
    workspace: *const eroded_constituents.PackedWorkspace,
    cell: usize,
    component: usize,
    composition: IntercellTransfer,
    absolute_native: f64,
    relative: f64,
) !void {
    try validateIntercellTransfer(composition);
    const index = cell * workspace.component_count + component;
    const row = cell / columns;
    const column = cell % columns;
    const fluxes = [_]f64{
        workspace.flux.east[index],
        workspace.flux.west[index],
        workspace.flux.south[index],
        workspace.flux.north[index],
    };
    const destinations = [_]?usize{
        if (column + 1 < columns) cell + 1 else null,
        if (column > 0) cell - 1 else null,
        if (row + 1 < rows) cell + columns else null,
        if (row > 0) cell - columns else null,
    };
    var external_native: f64 = 0;
    for (fluxes, destinations) |amount, destination| {
        if (!std.math.isFinite(amount) or amount < 0)
            return error.InvalidHourlyCellErosionAccounting;
        if (destination) |recipient| {
            const transfer = try scaleIntercellTransfer(composition, amount);
            activities[cell] = try addBoundary(activities[cell], transferBoundary(transfer, .output));
            activities[recipient] = try addBoundary(activities[recipient], transferBoundary(transfer, .input));
        } else {
            external_native = checkedSignedSum(external_native, amount) catch
                return error.HourlyCellBoundaryOverflow;
        }
    }
    const exported_native = workspace.exported[index];
    if (!std.math.isFinite(exported_native) or exported_native < 0)
        return error.InvalidHourlyCellErosionAccounting;
    const scale = @max(1, @max(@abs(external_native), @abs(exported_native)));
    if (@abs(exported_native - external_native) > absolute_native + relative * scale)
        return error.HourlyCellErosionExportMismatch;
    activities[cell] = try addBoundary(
        activities[cell],
        transferBoundary(try scaleIntercellTransfer(composition, exported_native), .output),
    );
}

fn scaleIntercellTransfer(composition: IntercellTransfer, amount: f64) !IntercellTransfer {
    if (!std.math.isFinite(amount) or amount < 0)
        return error.InvalidHourlyCellErosionAccounting;
    var result: IntercellTransfer = .{};
    inline for (std.meta.fields(IntercellTransfer)) |field| {
        const value = @field(composition, field.name) * amount;
        if (!std.math.isFinite(value) or value < 0)
            return error.HourlyCellBoundaryOverflow;
        @field(result, field.name) = value;
    }
    return result;
}

fn organicErosionComposition(state: *const organic_state.State, component: usize) !IntercellTransfer {
    if (state.layer_count == 0) return error.HourlyCellBoundaryDimensionMismatch;
    var cursor: usize = 0;
    inline for (.{ state.microbial, state.residue, state.adsorbed }) |pools| {
        const components = 3 * (pools.len / state.layer_count);
        if (component < cursor + components)
            return organicElementComposition((component - cursor) % 3);
        cursor += components;
    }
    const acetate_components = state.adsorbed_acetate_carbon_g_c.len / state.layer_count;
    if (component < cursor + acetate_components) return .{ .carbon_g = 1 };
    cursor += acetate_components;
    const structural_components = 3 * (state.structural.len / state.layer_count);
    if (component < cursor + structural_components)
        return organicElementComposition((component - cursor) % 3);
    cursor += structural_components;
    const annotation_components = state.colonized_structural_carbon_g_c.len / state.layer_count;
    if (component < cursor + annotation_components) return .{};
    return error.HourlyCellBoundaryDimensionMismatch;
}

fn organicElementComposition(element: usize) IntercellTransfer {
    return switch (element) {
        0 => .{ .carbon_g = 1 },
        1 => .{ .nitrogen_g = 1 },
        2 => .{ .phosphorus_g = 1 },
        else => unreachable,
    };
}

fn chemistryErosionComposition(component: usize, carbon_g_per_mol: f64, nitrogen_g_per_mol: f64, phosphorus_g_per_mol: f64) !IntercellTransfer {
    @setEvalBranchQuota(10_000);
    var cursor: usize = 0;
    inline for (@typeInfo(cation_exchange.Cations).@"struct".fields) |field| {
        if (component == cursor) return chemistryCationComposition(field.name, nitrogen_g_per_mol);
        cursor += 1;
    }
    // Carboxyl-bound H is charge state, not molecular-hydrogen storage.
    if (component == cursor) return .{};
    cursor += 1;
    inline for (0..2) |_| inline for (@typeInfo(phosphate_network.State).@"struct".fields) |field| {
        if (comptime isErodiblePhosphateField(field.name)) {
            if (component == cursor)
                return phosphateErosionComposition(field.name, phosphorus_g_per_mol);
            cursor += 1;
        }
    };
    inline for (@typeInfo(geochemistry_network.SolidState).@"struct".fields) |field| {
        if (component == cursor)
            return geochemistryErosionComposition(field.name, carbon_g_per_mol);
        cursor += 1;
    }
    return error.HourlyCellBoundaryDimensionMismatch;
}

fn mineralFertilizerErosionComposition(component: usize, carbon_g_per_mol: f64, phosphorus_g_per_mol: f64) IntercellTransfer {
    inline for (@typeInfo(mineral_fertilizer_inventory.Inventory).@"struct".fields, 0..) |field, index| if (component == index) {
        if (comptime std.mem.indexOf(u8, field.name, "monocalcium_phosphate") != null)
            return .{ .phosphorus_g = 2 * phosphorus_g_per_mol, .calcium_mol = 1 };
        if (comptime std.mem.eql(u8, field.name, "hydroxyapatite_mol"))
            return .{ .phosphorus_g = 3 * phosphorus_g_per_mol, .calcium_mol = 5 };
        if (comptime std.mem.eql(u8, field.name, "calcite_mol"))
            return .{ .carbon_g = carbon_g_per_mol, .calcium_mol = 1 };
        if (comptime std.mem.eql(u8, field.name, "gypsum_mol"))
            return .{ .calcium_mol = 1, .sulfur_mol = 1 };
        if (comptime std.mem.startsWith(u8, field.name, "aluminum_")) return .{ .aluminum_mol = 1, .silicon_mol = 0.75 };
        if (comptime std.mem.startsWith(u8, field.name, "iron_")) return .{ .iron_mol = 1, .silicon_mol = 0.75 };
        if (comptime std.mem.startsWith(u8, field.name, "calcium_")) return .{ .calcium_mol = 1, .silicon_mol = 0.5 };
        if (comptime std.mem.startsWith(u8, field.name, "magnesium_")) return .{ .magnesium_mol = 1, .silicon_mol = 0.5 };
        if (comptime std.mem.startsWith(u8, field.name, "sodium_")) return .{ .sodium_mol = 1, .silicon_mol = 0.25 };
        if (comptime std.mem.startsWith(u8, field.name, "potassium_")) return .{ .potassium_mol = 1, .silicon_mol = 0.25 };
        unreachable;
    };
    unreachable;
}

fn chemistryCationComposition(comptime name: []const u8, nitrogen_g_per_mol: f64) IntercellTransfer {
    if (std.mem.startsWith(u8, name, "ammonium")) return .{ .nitrogen_g = nitrogen_g_per_mol };
    if (std.mem.eql(u8, name, "aluminum")) return .{ .aluminum_mol = 1 };
    if (std.mem.eql(u8, name, "iron")) return .{ .iron_mol = 1 };
    if (std.mem.eql(u8, name, "calcium")) return .{ .calcium_mol = 1 };
    if (std.mem.eql(u8, name, "magnesium")) return .{ .magnesium_mol = 1 };
    if (std.mem.eql(u8, name, "sodium")) return .{ .sodium_mol = 1 };
    if (std.mem.eql(u8, name, "potassium")) return .{ .potassium_mol = 1 };
    return .{};
}

fn phosphateErosionComposition(comptime name: []const u8, phosphorus_g_per_mol: f64) IntercellTransfer {
    var result: IntercellTransfer = .{ .phosphorus_g = phosphateAtoms(name) * phosphorus_g_per_mol };
    if (std.mem.indexOf(u8, name, "aluminum_phosphate") != null) result.aluminum_mol = 1;
    if (std.mem.indexOf(u8, name, "iron_phosphate") != null) result.iron_mol = 1;
    if (std.mem.indexOf(u8, name, "dicalcium_phosphate") != null) result.calcium_mol = 1;
    if (std.mem.indexOf(u8, name, "hydroxyapatite") != null) result.calcium_mol = 5;
    if (std.mem.indexOf(u8, name, "monocalcium_phosphate") != null) result.calcium_mol = 1;
    return result;
}

fn geochemistryErosionComposition(comptime name: []const u8, carbon_g_per_mol: f64) IntercellTransfer {
    if (std.mem.eql(u8, name, "gibbsite_solid_mol_per_m3")) return .{ .aluminum_mol = 1 };
    if (std.mem.eql(u8, name, "iron_hydroxide_solid_mol_per_m3")) return .{ .iron_mol = 1 };
    if (std.mem.eql(u8, name, "calcite_solid_mol_per_m3")) return .{ .carbon_g = carbon_g_per_mol, .calcium_mol = 1 };
    if (std.mem.eql(u8, name, "gypsum_solid_mol_per_m3")) return .{ .calcium_mol = 1, .sulfur_mol = 1 };
    const silicon: f64 = if (comptime (std.mem.startsWith(u8, name, "aluminum_") or std.mem.startsWith(u8, name, "iron_")))
        0.75
    else if (comptime (std.mem.startsWith(u8, name, "calcium_") or std.mem.startsWith(u8, name, "magnesium_")))
        0.5
    else
        0.25;
    if (std.mem.startsWith(u8, name, "aluminum_")) return .{ .aluminum_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "iron_")) return .{ .iron_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "calcium_")) return .{ .calcium_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "magnesium_")) return .{ .magnesium_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "sodium_")) return .{ .sodium_mol = 1, .silicon_mol = silicon };
    if (std.mem.startsWith(u8, name, "potassium_")) return .{ .potassium_mol = 1, .silicon_mol = silicon };
    unreachable;
}

fn isErodiblePhosphateField(comptime name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_per_megagram") or
        std.mem.indexOf(u8, name, "_solid_mol_per_m3") != null;
}

fn phosphateAtoms(comptime name: []const u8) f64 {
    if (std.mem.indexOf(u8, name, "adsorbed_") != null) return 1;
    if (std.mem.indexOf(u8, name, "aluminum_phosphate") != null or
        std.mem.indexOf(u8, name, "iron_phosphate") != null or
        std.mem.indexOf(u8, name, "dicalcium_phosphate") != null)
        return 1;
    if (std.mem.indexOf(u8, name, "hydroxyapatite") != null) return 3;
    if (std.mem.indexOf(u8, name, "monocalcium_phosphate") != null) return 2;
    return 0;
}

fn validateDedicatedTransportLayout(
    ledger: *const BoundaryLedger,
    faces: *const transport_hydrology.SoilFaces,
    boundary: []const f64,
    micropore_face_flux: []const f64,
    macropore_face_flux: []const f64,
    soil_layer_capacity: usize,
    component_count: usize,
) !usize {
    if (soil_layer_capacity == 0 or component_count == 0 or
        faces.micropore_faces.len != faces.macropore_faces.len or
        faces.direction_axis.len != faces.micropore_faces.len or
        faces.active_by_face.len != faces.micropore_faces.len)
        return error.HourlyCellBoundaryDimensionMismatch;
    const layer_count = try std.math.mul(usize, ledger.cells.len, soil_layer_capacity);
    if (faces.active_by_layer.len != layer_count)
        return error.HourlyCellBoundaryDimensionMismatch;
    const face_component_count = try std.math.mul(usize, faces.micropore_faces.len, component_count);
    if (micropore_face_flux.len != face_component_count or macropore_face_flux.len != face_component_count)
        return error.HourlyCellBoundaryDimensionMismatch;
    if (boundary.len != layer_count and boundary.len != try std.math.mul(usize, layer_count, component_count))
        return error.HourlyCellBoundaryDimensionMismatch;
    for (faces.micropore_faces, faces.macropore_faces, faces.direction_axis) |micro, macro, axis| {
        if (axis > 2 or micro.first_cell >= layer_count or micro.second_cell >= layer_count or
            micro.first_cell != macro.first_cell or micro.second_cell != macro.second_cell)
            return error.InvalidHourlyCellSoilFaceTopology;
        if (axis != 2 and micro.first_cell / soil_layer_capacity == micro.second_cell / soil_layer_capacity)
            return error.InvalidHourlyCellSoilFaceTopology;
    }
    return layer_count;
}

fn addSignedBoundary(activity: *BoundaryActivity, signed: f64, comptime input_field: []const u8, comptime output_field: []const u8) !void {
    if (!std.math.isFinite(signed)) return error.InvalidHourlyCellBoundaryActivity;
    if (signed >= 0)
        try addNonnegativeField(&@field(activity, input_field), signed)
    else
        try addNonnegativeField(&@field(activity, output_field), -signed);
}

fn addSignedFace(activities: []BoundaryActivity, first_cell: usize, second_cell: usize, signed: f64, comptime input_field: []const u8, comptime output_field: []const u8) !void {
    if (!std.math.isFinite(signed) or first_cell >= activities.len or second_cell >= activities.len or first_cell == second_cell)
        return error.InvalidHourlyCellBoundaryActivity;
    const donor = if (signed >= 0) first_cell else second_cell;
    const recipient = if (signed >= 0) second_cell else first_cell;
    try addNonnegativeField(&@field(activities[donor], output_field), @abs(signed));
    try addNonnegativeField(&@field(activities[recipient], input_field), @abs(signed));
}

fn checkedSignedSum(left: f64, right: f64) !f64 {
    const sum = left + right;
    if (!std.math.isFinite(left) or !std.math.isFinite(right) or !std.math.isFinite(sum))
        return error.HourlyCellBoundaryOverflow;
    return sum;
}

fn addNonnegativeField(field: *f64, amount: f64) !void {
    if (!std.math.isFinite(amount) or amount < 0)
        return error.InvalidHourlyCellBoundaryActivity;
    const next = field.* + amount;
    if (!std.math.isFinite(next)) return error.HourlyCellBoundaryOverflow;
    field.* = next;
}

fn applyGasFaceTransfer(
    ledger: *BoundaryLedger,
    face: gas_transport.Face,
    fluxes: []const f64,
    soil_layer_capacity: usize,
    layer_count: usize,
    face_index: usize,
    preflight_only: bool,
) !void {
    if (face.first_cell >= layer_count or face.second_cell >= layer_count or face.first_cell == face.second_cell)
        return error.InvalidHourlyCellSoilFaceTopology;
    const first_cell = face.first_cell / soil_layer_capacity;
    const second_cell = face.second_cell / soil_layer_capacity;
    if (first_cell == second_cell) return;
    var signed: IntercellTransfer = .{};
    const first = face_index * gas_transport.species_count;
    inline for (@typeInfo(gas_transport.Species).@"enum".fields) |field| {
        const flux = fluxes[first + field.value];
        if (!std.math.isFinite(flux)) return error.InvalidHourlyCellBoundaryActivity;
        switch (@as(gas_transport.Species, @enumFromInt(field.value))) {
            .carbon_dioxide, .methane => signed.carbon_g += flux,
            .oxygen => signed.oxygen_g += flux,
            .nitrogen, .nitrous_oxide, .ammonia => signed.nitrogen_g += flux,
            .hydrogen => signed.hydrogen_g += flux,
        }
    }
    inline for (std.meta.fields(IntercellTransfer)) |field| {
        const amount = @field(signed, field.name);
        if (!std.math.isFinite(amount)) return error.HourlyCellBoundaryOverflow;
        if (amount != 0) {
            var transfer: IntercellTransfer = .{};
            @field(transfer, field.name) = @abs(amount);
            const donor = if (amount > 0) first_cell else second_cell;
            const recipient = if (amount > 0) second_cell else first_cell;
            if (preflight_only)
                try ledger.preflightIntercell(donor, recipient, transfer)
            else
                try ledger.accumulateIntercell(donor, recipient, transfer);
        }
    }
}

fn applyAqueousFaceTransfer(
    ledger: *BoundaryLedger,
    faces: *const transport_hydrology.SoilFaces,
    micropore_face_flux_mol: []const f64,
    macropore_face_flux_mol: []const f64,
    soil_layer_capacity: usize,
    layer_count: usize,
    carbon_g_per_mol: f64,
    phosphorus_g_per_mol: f64,
    face: usize,
    preflight_only: bool,
) !void {
    if (!faces.active_by_face[face]) return;
    const topology = faces.micropore_faces[face];
    const macro_topology = faces.macropore_faces[face];
    if (faces.direction_axis[face] > 2 or topology.first_cell >= layer_count or topology.second_cell >= layer_count)
        return error.InvalidHourlyCellSoilFaceTopology;
    if (topology.first_cell != macro_topology.first_cell or topology.second_cell != macro_topology.second_cell)
        return error.InvalidHourlyCellSoilFaceTopology;
    if (faces.direction_axis[face] == 2) return;
    const first_cell = topology.first_cell / soil_layer_capacity;
    const second_cell = topology.second_cell / soil_layer_capacity;
    if (first_cell == second_cell) return error.InvalidHourlyCellSoilFaceTopology;
    var signed: IntercellTransfer = .{};
    const start = face * solute_species.AqueousSpecies.count;
    inline for (@typeInfo(solute_species.AqueousSpecies).@"enum".fields) |field| {
        const flux = micropore_face_flux_mol[start + field.value] + macropore_face_flux_mol[start + field.value];
        if (!std.math.isFinite(flux)) return error.InvalidHourlyCellBoundaryActivity;
        const formula = surface_aqueous.formula(@enumFromInt(field.value));
        signed.carbon_g += flux * formula.carbon_mol * carbon_g_per_mol;
        signed.phosphorus_g += flux * formula.phosphorus_mol * phosphorus_g_per_mol;
        signed.aluminum_mol += flux * formula.aluminum_mol;
        signed.iron_mol += flux * formula.iron_mol;
        signed.calcium_mol += flux * formula.calcium_mol;
        signed.magnesium_mol += flux * formula.magnesium_mol;
        signed.sodium_mol += flux * formula.sodium_mol;
        signed.potassium_mol += flux * formula.potassium_mol;
        signed.sulfur_mol += flux * formula.sulfur_mol;
        signed.chloride_mol += flux * formula.chloride_mol;
        signed.silicon_mol += flux * formula.silicon_mol;
    }
    inline for (std.meta.fields(IntercellTransfer)) |field| {
        const amount = @field(signed, field.name);
        if (!std.math.isFinite(amount)) return error.HourlyCellBoundaryOverflow;
        if (amount != 0) {
            var transfer: IntercellTransfer = .{};
            @field(transfer, field.name) = @abs(amount);
            const donor = if (amount > 0) first_cell else second_cell;
            const recipient = if (amount > 0) second_cell else first_cell;
            if (preflight_only)
                try ledger.preflightIntercell(donor, recipient, transfer)
            else
                try ledger.accumulateIntercell(donor, recipient, transfer);
        }
    }
}

fn applySoilFaceTransfer(
    ledger: *BoundaryLedger,
    faces: *const transport_hydrology.SoilFaces,
    soil_layer_capacity: usize,
    layer_count: usize,
    face: usize,
    preflight_only: bool,
) !void {
    if (!faces.active_by_face[face]) return;
    const micro_face = faces.micropore_faces[face];
    const macro_face = faces.macropore_faces[face];
    const axis = faces.direction_axis[face];
    if (axis > 2 or micro_face.first_cell >= layer_count or micro_face.second_cell >= layer_count or
        micro_face.first_cell != macro_face.first_cell or micro_face.second_cell != macro_face.second_cell)
        return error.InvalidHourlyCellSoilFaceTopology;
    const water_flux = faces.micropore_water_flux_m3_per_step[face] +
        faces.macropore_water_flux_m3_per_step[face] +
        faces.vapor_flux_m3_per_step[face];
    const heat_flux = faces.heat_flux_megajoules_per_step[face];
    if (!std.math.isFinite(water_flux) or !std.math.isFinite(heat_flux))
        return error.InvalidHourlyCellBoundaryActivity;
    if (axis == 2) return;
    const first_cell = micro_face.first_cell / soil_layer_capacity;
    const second_cell = micro_face.second_cell / soil_layer_capacity;
    if (first_cell == second_cell) return error.InvalidHourlyCellSoilFaceTopology;
    if (water_flux != 0) {
        const donor = if (water_flux > 0) first_cell else second_cell;
        const recipient = if (water_flux > 0) second_cell else first_cell;
        const transfer: IntercellTransfer = .{ .water_m3 = @abs(water_flux) };
        if (preflight_only)
            try ledger.preflightIntercell(donor, recipient, transfer)
        else
            try ledger.accumulateIntercell(donor, recipient, transfer);
    }
    if (heat_flux != 0) {
        const donor = if (heat_flux > 0) first_cell else second_cell;
        const recipient = if (heat_flux > 0) second_cell else first_cell;
        const transfer: IntercellTransfer = .{ .heat_megajoules = @abs(heat_flux) };
        if (preflight_only)
            try ledger.preflightIntercell(donor, recipient, transfer)
        else
            try ledger.accumulateIntercell(donor, recipient, transfer);
    }
}

fn addBoundary(left: BoundaryActivity, right: BoundaryActivity) !BoundaryActivity {
    try validateBoundary(left);
    try validateBoundary(right);
    var result = left;
    inline for (std.meta.fields(BoundaryActivity)) |field| {
        const left_value = @field(left, field.name);
        const right_value = @field(right, field.name);
        var value = left_value + right_value;
        if (!std.math.isFinite(value)) return error.HourlyCellBoundaryOverflow;
        // Arithmetic-provenance lanes are upper bounds, so a reduction may
        // never round downward. Physical flux/state lanes retain their exact
        // pre-existing binary64 addition order.
        if (comptime isArithmeticProvenanceField(field.name)) {
            if (left_value != 0 and right_value != 0)
                value = roundUpArithmeticProvenance(value);
        }
        if (!std.math.isFinite(value)) return error.HourlyCellBoundaryOverflow;
        @field(result, field.name) = value;
    }
    return result;
}

noinline fn roundUpArithmeticProvenance(value: f64) f64 {
    return if (value > 0)
        std.math.nextAfter(f64, value, std.math.inf(f64))
    else
        value;
}

fn isArithmeticProvenanceField(comptime name: []const u8) bool {
    @setEvalBranchQuota(10_000);
    return std.mem.indexOf(u8, name, "_roundoff_allowance_") != null;
}

fn validateIntercellTransfer(transfer: IntercellTransfer) !void {
    inline for (std.meta.fields(IntercellTransfer)) |field| {
        const value = @field(transfer, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidHourlyCellIntercellTransfer;
    }
}

fn transferBoundary(transfer: IntercellTransfer, direction: enum { input, output }) BoundaryActivity {
    return switch (direction) {
        .input => .{
            .water_input_m3 = transfer.water_m3,
            .heat_input_megajoules = transfer.heat_megajoules,
            .oxygen_input_g = transfer.oxygen_g,
            .hydrogen_input_g = transfer.hydrogen_g,
            .carbon_input_g = transfer.carbon_g,
            .nitrogen_input_g = transfer.nitrogen_g,
            .phosphorus_input_g = transfer.phosphorus_g,
            .aluminum_input_mol = transfer.aluminum_mol,
            .iron_input_mol = transfer.iron_mol,
            .calcium_input_mol = transfer.calcium_mol,
            .magnesium_input_mol = transfer.magnesium_mol,
            .sodium_input_mol = transfer.sodium_mol,
            .potassium_input_mol = transfer.potassium_mol,
            .sulfur_input_mol = transfer.sulfur_mol,
            .chloride_input_mol = transfer.chloride_mol,
            .silicon_input_mol = transfer.silicon_mol,
            .sand_input_megagrams = transfer.sand_megagrams,
            .silt_input_megagrams = transfer.silt_megagrams,
            .clay_input_megagrams = transfer.clay_megagrams,
            .rock_additive_input = transfer.rock_additive,
            .cation_exchange_capacity_input_mol = transfer.cation_exchange_capacity_mol,
            .anion_exchange_capacity_input_mol = transfer.anion_exchange_capacity_mol,
        },
        .output => .{
            .water_output_m3 = transfer.water_m3,
            .heat_output_megajoules = transfer.heat_megajoules,
            .oxygen_output_g = transfer.oxygen_g,
            .hydrogen_output_g = transfer.hydrogen_g,
            .carbon_output_g = transfer.carbon_g,
            .nitrogen_output_g = transfer.nitrogen_g,
            .phosphorus_output_g = transfer.phosphorus_g,
            .aluminum_output_mol = transfer.aluminum_mol,
            .iron_output_mol = transfer.iron_mol,
            .calcium_output_mol = transfer.calcium_mol,
            .magnesium_output_mol = transfer.magnesium_mol,
            .sodium_output_mol = transfer.sodium_mol,
            .potassium_output_mol = transfer.potassium_mol,
            .sulfur_output_mol = transfer.sulfur_mol,
            .chloride_output_mol = transfer.chloride_mol,
            .silicon_output_mol = transfer.silicon_mol,
            .sand_output_megagrams = transfer.sand_megagrams,
            .silt_output_megagrams = transfer.silt_megagrams,
            .clay_output_megagrams = transfer.clay_megagrams,
            .rock_additive_output = transfer.rock_additive,
            .cation_exchange_capacity_output_mol = transfer.cation_exchange_capacity_mol,
            .anion_exchange_capacity_output_mol = transfer.anion_exchange_capacity_mol,
        },
    };
}

pub const Tolerances = struct {
    absolute_per_area: tolerance_config.AbsolutePerArea,
    relative: f64,

    pub fn validate(self: Tolerances) !void {
        try self.absolute_per_area.validate();
        if (!std.math.isFinite(self.relative) or self.relative <= 0)
            return error.InvalidHourlyCellConservationTolerance;
    }
};

pub const CellReport = struct {
    closure: [quantity_count]scoped.Closure,
};

pub const Report = struct {
    cells: []CellReport,
    maximum_absolute: [quantity_count]f64,
    maximum_normalized_relative: [quantity_count]f64,
    failing_cell_count: [quantity_count]usize,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn accepted(self: Report) bool {
        for (self.failing_cell_count) |count| if (count != 0) return false;
        return true;
    }
};

/// Identifies BOTH the accumulation window and the DOMAIN whose index space
/// the report is indexed by, because this evaluator is shared by two callers
/// over two different index spaces: `hourly_cell_conservation` indexes grid
/// cells, and `layer_local_conservation.evaluate` (`:4325`) delegates here
/// with layer/scope arrays.
///
/// `issue-101`: the layer variants exist because all six (domain, window)
/// combinations previously collapsed onto the three window tags, and the
/// failure message additionally hard-coded the word "cell". A layer-scope
/// failure therefore printed as `hourly cell conservation failure: cell=2`
/// with `2` being a layer index. That cost two build-and-run cycles and three
/// wrong committed conclusions on `issue-100`. The tag must name the index
/// space, because the number beside it is meaningless without it.
pub const EvaluationScope = enum {
    hourly,
    accumulated_continuity,
    accumulated,
    hourly_layer,
    accumulated_layer_continuity,
    accumulated_layer,

    /// The domain word used in diagnostics, so a reader can tell what the
    /// printed index counts without knowing which module called.
    pub fn domain(self: EvaluationScope) []const u8 {
        return switch (self) {
            .hourly, .accumulated_continuity, .accumulated => "cell",
            .hourly_layer, .accumulated_layer_continuity, .accumulated_layer => "layer_scope",
        };
    }
};

/// Evaluates every cell before any domain reduction. The report owns its cell
/// closures so callers can publish absolute and normalized diagnostics at the
/// hourly scale. No scientific or ledger owner is mutated.
pub fn evaluate(
    allocator: std.mem.Allocator,
    storage_before: []const inventory.Storage,
    storage_after: []const inventory.Storage,
    boundary: []const BoundaryActivity,
    cell_area_m2: []const f64,
    tolerances: Tolerances,
) !Report {
    return evaluateForScope(
        allocator,
        storage_before,
        storage_after,
        boundary,
        cell_area_m2,
        tolerances,
        .hourly,
    );
}

pub fn evaluateForScope(
    allocator: std.mem.Allocator,
    storage_before: []const inventory.Storage,
    storage_after: []const inventory.Storage,
    boundary: []const BoundaryActivity,
    cell_area_m2: []const f64,
    tolerances: Tolerances,
    scope: EvaluationScope,
) !Report {
    try tolerances.validate();
    const cell_count = storage_before.len;
    if (cell_count == 0 or storage_after.len != cell_count or boundary.len != cell_count or cell_area_m2.len != cell_count)
        return error.HourlyCellConservationDimensionMismatch;
    const cells = try allocator.alloc(CellReport, cell_count);
    errdefer allocator.free(cells);
    var result: Report = .{
        .cells = cells,
        .maximum_absolute = @splat(0),
        .maximum_normalized_relative = @splat(0),
        .failing_cell_count = @splat(0),
    };
    // `issue-101`: resolved once, not inside the loops. The diagnostics below
    // sit in an `inline for` over every `Quantity`, so anything evaluated in
    // their argument lists is duplicated per quantity per message.
    const domain_word = scope.domain();
    for (0..cell_count) |cell| {
        try storage_before[cell].validate();
        try storage_after[cell].validate();
        try validateBoundary(boundary[cell]);
        const area_m2 = cell_area_m2[cell];
        if (!std.math.isFinite(area_m2) or area_m2 <= 0)
            return error.InvalidHourlyCellConservationArea;
        inline for (@typeInfo(Quantity).@"enum".fields) |field| {
            const quantity: Quantity = @enumFromInt(field.value);
            const index: usize = @intCast(field.value);
            const terms = transaction(
                quantity,
                storage_before[cell],
                storage_after[cell],
                boundary[cell],
            );
            const closure = try scoped.evaluate(
                terms,
                .{
                    .absolute = absolutePerArea(quantity, tolerances.absolute_per_area) * area_m2,
                    .relative = tolerances.relative,
                    .upstream_arithmetic_roundoff_allowance = storageUpdateRoundoffAllowance(quantity, boundary[cell]),
                },
            );
            result.cells[cell].closure[index] = closure;
            result.maximum_absolute[index] = @max(result.maximum_absolute[index], closure.absolute);
            result.maximum_normalized_relative[index] = @max(result.maximum_normalized_relative[index], closure.normalized_relative);
            result.failing_cell_count[index] += @intFromBool(!closure.accepted);
            if (!closure.accepted and !builtin.is_test) std.log.err(
                "{s} {s} conservation failure: {s}={d} quantity={s} before={e} after={e} external_inputs={e} external_outputs={e} internal_production={e} internal_consumption={e} residual={e} absolute={e} normalized_relative={e} physical_limit={e} arithmetic_roundoff_allowance={e} effective_limit={e}",
                .{ @tagName(scope), domain_word, domain_word, cell, field.name, terms.storage_before, terms.storage_after, terms.external_inputs, terms.external_outputs, terms.internal_production, terms.internal_consumption, closure.residual, closure.absolute, closure.normalized_relative, closure.acceptance_limit, closure.arithmetic_roundoff_allowance, closure.effective_acceptance_limit },
            );
            if (!closure.accepted and !builtin.is_test and quantity == .carbon) std.log.err(
                "{s} {s} carbon storage components: {s}={d} residue_before={e} residue_after={e} organic_before={e} organic_after={e} inorganic_and_gas_before={e} inorganic_and_gas_after={e} soil_gas_before={e} soil_gas_after={e} surface_gas_before={e} surface_gas_after={e} other_inorganic_before={e} other_inorganic_after={e} plant_before={e} plant_after={e}",
                .{
                    @tagName(scope),
                    domain_word,
                    domain_word,
                    cell,
                    storage_before[cell].residue_carbon_g,
                    storage_after[cell].residue_carbon_g,
                    storage_before[cell].organic_carbon_g,
                    storage_after[cell].organic_carbon_g,
                    storage_before[cell].carbon_dioxide_carbon_g,
                    storage_after[cell].carbon_dioxide_carbon_g,
                    storage_before[cell].diagnostic_soil_gas_carbon_g,
                    storage_after[cell].diagnostic_soil_gas_carbon_g,
                    storage_before[cell].diagnostic_surface_gas_carbon_g,
                    storage_after[cell].diagnostic_surface_gas_carbon_g,
                    storage_before[cell].carbon_dioxide_carbon_g - storage_before[cell].diagnostic_soil_gas_carbon_g - storage_before[cell].diagnostic_surface_gas_carbon_g,
                    storage_after[cell].carbon_dioxide_carbon_g - storage_after[cell].diagnostic_soil_gas_carbon_g - storage_after[cell].diagnostic_surface_gas_carbon_g,
                    storage_before[cell].plant_carbon_g,
                    storage_after[cell].plant_carbon_g,
                },
            );
            if (!closure.accepted and !builtin.is_test and quantity == .heat) std.log.err(
                "{s} {s} heat storage components: {s}={d} snow_before={e} snow_after={e} soil_before={e} soil_after={e} surface_before={e} surface_after={e} canopy_before={e} canopy_after={e} surface_organic_carbon_before={e} surface_organic_carbon_after={e}",
                .{
                    @tagName(scope),
                    domain_word,
                    domain_word,
                    cell,
                    storage_before[cell].diagnostic_snow_heat_megajoules,
                    storage_after[cell].diagnostic_snow_heat_megajoules,
                    storage_before[cell].diagnostic_soil_heat_megajoules,
                    storage_after[cell].diagnostic_soil_heat_megajoules,
                    storage_before[cell].diagnostic_surface_heat_megajoules,
                    storage_after[cell].diagnostic_surface_heat_megajoules,
                    storage_before[cell].diagnostic_canopy_heat_megajoules,
                    storage_after[cell].diagnostic_canopy_heat_megajoules,
                    storage_before[cell].diagnostic_surface_organic_carbon_g,
                    storage_after[cell].diagnostic_surface_organic_carbon_g,
                },
            );
        }
    }
    return result;
}

pub fn requireAccepted(report: Report) !void {
    if (!report.accepted()) return error.HourlyCellConservationFailure;
}

fn transaction(quantity: Quantity, before: inventory.Storage, after: inventory.Storage, activity: BoundaryActivity) scoped.Transaction {
    return switch (quantity) {
        .water => .{ .storage_before = before.water_m3, .storage_after = after.water_m3, .external_inputs = activity.water_input_m3, .external_outputs = activity.water_output_m3 },
        .heat => .{ .storage_before = before.heat_megajoules, .storage_after = after.heat_megajoules, .external_inputs = activity.heat_input_megajoules, .external_outputs = activity.heat_output_megajoules, .internal_production = activity.heat_internal_production_megajoules, .internal_consumption = activity.heat_internal_consumption_megajoules },
        .oxygen => .{ .storage_before = before.oxygen_g, .storage_after = after.oxygen_g, .external_inputs = activity.oxygen_input_g, .external_outputs = activity.oxygen_output_g, .internal_production = activity.oxygen_internal_production_g, .internal_consumption = activity.oxygen_internal_consumption_g },
        .hydrogen => .{ .storage_before = before.hydrogen_g, .storage_after = after.hydrogen_g, .external_inputs = activity.hydrogen_input_g, .external_outputs = activity.hydrogen_output_g, .internal_production = activity.hydrogen_internal_production_g, .internal_consumption = activity.hydrogen_internal_consumption_g },
        .carbon => .{ .storage_before = totalCarbon(before), .storage_after = totalCarbon(after), .external_inputs = activity.carbon_input_g, .external_outputs = activity.carbon_output_g },
        .nitrogen => .{ .storage_before = totalNitrogen(before), .storage_after = totalNitrogen(after), .external_inputs = activity.nitrogen_input_g, .external_outputs = activity.nitrogen_output_g },
        .phosphorus => .{ .storage_before = totalPhosphorus(before), .storage_after = totalPhosphorus(after), .external_inputs = activity.phosphorus_input_g, .external_outputs = activity.phosphorus_output_g },
        .sand => .{ .storage_before = before.sand_megagrams, .storage_after = after.sand_megagrams, .external_inputs = activity.sand_input_megagrams, .external_outputs = activity.sand_output_megagrams },
        .silt => .{ .storage_before = before.silt_megagrams, .storage_after = after.silt_megagrams, .external_inputs = activity.silt_input_megagrams, .external_outputs = activity.silt_output_megagrams },
        .clay => .{ .storage_before = before.clay_megagrams, .storage_after = after.clay_megagrams, .external_inputs = activity.clay_input_megagrams, .external_outputs = activity.clay_output_megagrams },
        .rock_additive => .{ .storage_before = before.rock_additive, .storage_after = after.rock_additive, .external_inputs = activity.rock_additive_input, .external_outputs = activity.rock_additive_output },
        .cation_exchange_capacity => .{ .storage_before = before.cation_exchange_capacity_mol, .storage_after = after.cation_exchange_capacity_mol, .external_inputs = activity.cation_exchange_capacity_input_mol, .external_outputs = activity.cation_exchange_capacity_output_mol, .internal_production = activity.cation_exchange_capacity_internal_production_mol, .internal_consumption = activity.cation_exchange_capacity_internal_consumption_mol },
        .anion_exchange_capacity => .{ .storage_before = before.anion_exchange_capacity_mol, .storage_after = after.anion_exchange_capacity_mol, .external_inputs = activity.anion_exchange_capacity_input_mol, .external_outputs = activity.anion_exchange_capacity_output_mol, .internal_production = activity.anion_exchange_capacity_internal_production_mol, .internal_consumption = activity.anion_exchange_capacity_internal_consumption_mol },
        .aluminum => .{ .storage_before = before.aluminum_mol, .storage_after = after.aluminum_mol, .external_inputs = activity.aluminum_input_mol, .external_outputs = activity.aluminum_output_mol },
        .iron => .{ .storage_before = before.iron_mol, .storage_after = after.iron_mol, .external_inputs = activity.iron_input_mol, .external_outputs = activity.iron_output_mol },
        .calcium => .{ .storage_before = before.calcium_mol, .storage_after = after.calcium_mol, .external_inputs = activity.calcium_input_mol, .external_outputs = activity.calcium_output_mol },
        .magnesium => .{ .storage_before = before.magnesium_mol, .storage_after = after.magnesium_mol, .external_inputs = activity.magnesium_input_mol, .external_outputs = activity.magnesium_output_mol },
        .sodium => .{ .storage_before = before.sodium_mol, .storage_after = after.sodium_mol, .external_inputs = activity.sodium_input_mol, .external_outputs = activity.sodium_output_mol },
        .potassium => .{ .storage_before = before.potassium_mol, .storage_after = after.potassium_mol, .external_inputs = activity.potassium_input_mol, .external_outputs = activity.potassium_output_mol },
        .sulfur => .{ .storage_before = before.sulfur_mol, .storage_after = after.sulfur_mol, .external_inputs = activity.sulfur_input_mol, .external_outputs = activity.sulfur_output_mol },
        .chloride => .{ .storage_before = before.chloride_mol, .storage_after = after.chloride_mol, .external_inputs = activity.chloride_input_mol, .external_outputs = activity.chloride_output_mol },
        .silicon => .{ .storage_before = before.silicon_mol, .storage_after = after.silicon_mol, .external_inputs = activity.silicon_input_mol, .external_outputs = activity.silicon_output_mol },
    };
}

fn storageUpdateRoundoffAllowance(
    quantity: Quantity,
    activity: BoundaryActivity,
) f64 {
    return switch (quantity) {
        .water => activity.water_storage_update_roundoff_allowance_m3,
        .heat => activity.heat_storage_update_roundoff_allowance_megajoules,
        .carbon => activity.carbon_storage_update_roundoff_allowance_g,
        .nitrogen => activity.nitrogen_storage_update_roundoff_allowance_g,
        .phosphorus => activity.phosphorus_storage_update_roundoff_allowance_g,
        .aluminum => activity.aluminum_storage_update_roundoff_allowance_mol,
        .iron => activity.iron_storage_update_roundoff_allowance_mol,
        .calcium => activity.calcium_storage_update_roundoff_allowance_mol,
        .magnesium => activity.magnesium_storage_update_roundoff_allowance_mol,
        .sodium => activity.sodium_storage_update_roundoff_allowance_mol,
        .potassium => activity.potassium_storage_update_roundoff_allowance_mol,
        .sulfur => activity.sulfur_storage_update_roundoff_allowance_mol,
        .chloride => activity.chloride_storage_update_roundoff_allowance_mol,
        .silicon => activity.silicon_storage_update_roundoff_allowance_mol,
        else => 0,
    };
}

fn validateBoundary(activity: BoundaryActivity) !void {
    inline for (std.meta.fields(BoundaryActivity)) |field| {
        const value = @field(activity, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidHourlyCellBoundaryActivity;
    }
}

fn absolutePerArea(quantity: Quantity, values: tolerance_config.AbsolutePerArea) f64 {
    return switch (quantity) {
        .water => values.water_m,
        .heat => values.heat_megajoules_m2,
        .oxygen => values.oxygen_g_m2,
        .hydrogen => values.hydrogen_g_m2,
        .carbon => values.carbon_g_m2,
        .nitrogen => values.nitrogen_g_m2,
        .phosphorus => values.phosphorus_g_m2,
        .sand => values.sand_megagrams_m2,
        .silt => values.silt_megagrams_m2,
        .clay => values.clay_megagrams_m2,
        .rock_additive => values.rock_additive_m2,
        .cation_exchange_capacity,
        .anion_exchange_capacity,
        => values.exchange_capacity_mol_m2,
        .aluminum,
        .iron,
        .calcium,
        .magnesium,
        .sodium,
        .potassium,
        .sulfur,
        .chloride,
        .silicon,
        => values.ions_mol_m2,
    };
}

fn totalCarbon(value: inventory.Storage) f64 {
    return compensatedSum(&.{ value.residue_carbon_g, value.organic_carbon_g, value.carbon_dioxide_carbon_g, value.plant_carbon_g });
}

fn totalNitrogen(value: inventory.Storage) f64 {
    return compensatedSum(&.{ value.residue_nitrogen_g, value.organic_nitrogen_g, value.dinitrogen_nitrogen_g, value.ammonium_nitrogen_g, value.nitrate_nitrogen_g, value.plant_nitrogen_g });
}

fn totalPhosphorus(value: inventory.Storage) f64 {
    return compensatedSum(&.{ value.residue_phosphorus_g, value.organic_phosphorus_g, value.phosphate_phosphorus_g, value.plant_phosphorus_g });
}

fn compensatedSum(values: []const f64) f64 {
    var sum: f64 = 0;
    var correction: f64 = 0;
    for (values) |value| {
        const corrected = value - correction;
        const next = sum + corrected;
        correction = (next - sum) - corrected;
        sum = next;
    }
    return sum;
}

test "production coverage is complete and runtime acceptance is transaction ordered" {
    for (production_requirements, 0..) |required, index| {
        try std.testing.expect(required.storage != 0);
        if (index != @intFromEnum(Quantity.rock_additive)) {
            try std.testing.expect(required.external != 0);
            try std.testing.expect(required.intercell != 0);
        }
    }
    try std.testing.expect(productionCoverageComplete());
    try requireProductionCoverage();
    const living_plant_storage = storage_plant_c | storage_plant_n | storage_plant_p;
    try std.testing.expectEqual(@as(u64, 0), living_plant_storage & ~production_bound.storage);
    try std.testing.expectEqual(@as(u64, 0), enumMask(.{
        ExternalProducer.soil_litter_gas_atmosphere,
        ExternalProducer.plant_atmosphere,
        ExternalProducer.fertilizer,
        ExternalProducer.fire_and_harvest,
        ExternalProducer.symbiotic_inoculum,
        ExternalProducer.soil_aqueous_boundary,
    }) & ~production_bound.external);
    try std.testing.expectEqual(@as(u64, 0), enumMask(.{
        ExternalProducer.erosion,
    }) & ~production_bound.external);
    try std.testing.expectEqual(@as(u64, 0), enumMask(.{
        IntercellProducer.erosion_faces,
    }) & ~production_bound.intercell);
    try std.testing.expectEqual(@as(u64, 0), enumMask(.{
        IntercellProducer.surface_runoff_dedicated_species,
        IntercellProducer.dissolved_gas_faces,
        IntercellProducer.organic_transport_faces,
        IntercellProducer.mineral_nitrogen_faces,
    }) & ~production_bound.intercell);
    try std.testing.expectEqual(@as(u64, 0), enumMask(.{
        ExternalProducer.dissolved_gas_boundary,
        ExternalProducer.organic_transport_boundary,
        ExternalProducer.mineral_nitrogen_boundary,
    }) & ~production_bound.external);
    const production_source = try readRepositorySource("src/ecosys_ng.zig");
    defer std.testing.allocator.free(production_source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production_source, "hourly_cell_conservation.evaluate("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production_source, "hourly_cell_conservation.requireProductionCoverage("));
    // The layer-local wrapper reconstructs the canonical cell output in the
    // same call and proves the exact scope partition before either acceptance
    // path can consume it. Both hour endpoints must use that stronger census.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, production_source, "reconstructLayerMassBalanceScopes("));
    const accept_start = std.mem.indexOf(u8, production_source, "noinline fn acceptHourAndPublish(") orelse return error.MissingAcceptHourPhase;
    const prepare_start = std.mem.indexOfPos(u8, production_source, accept_start, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(u8, production_source, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(u8, production_source, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const accept_phase = production_source[accept_start..prepare_start];
    const prepare_phase = production_source[prepare_start..advance_start];
    const advance_phase = production_source[advance_start..timeline_start];
    const transaction_begin = std.mem.indexOf(u8, advance_phase, "driver_context.outer_hour_transaction_workspace.*.begin(") orelse return error.MissingOuterHourTransaction;
    const material_refresh = std.mem.indexOf(u8, prepare_phase, "soil_runtime_material_refresh.refreshAcceptedHour") orelse return error.MissingHourlyMaterialRefresh;
    const storage_before = std.mem.indexOfPos(u8, prepare_phase, material_refresh, "hourly_cell_storage_before") orelse return error.MissingHourlyCellStorageBefore;
    const activity_reset = std.mem.indexOfPos(u8, prepare_phase, storage_before, "driver_context.hourly_cell_boundary_ledger.*.reset()") orelse return error.MissingHourlyCellLedgerReset;
    const prepare_call = std.mem.indexOfPos(u8, advance_phase, transaction_begin, "try prepareHourlyScience(driver_context,") orelse return error.MissingHourlyPreparationCall;
    const science_call = std.mem.indexOfPos(u8, advance_phase, prepare_call, "executeHourlyScience(") orelse return error.MissingHourlyScienceCall;
    const post_call = std.mem.indexOfPos(u8, advance_phase, science_call, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceCall;
    const accept_call = std.mem.indexOfPos(u8, advance_phase, post_call, "try acceptHourAndPublish(driver_context,") orelse return error.MissingAcceptHourCall;
    const acceptance = std.mem.indexOf(u8, accept_phase, "hourly_cell_conservation.requireAccepted(") orelse return error.MissingHourlyCellAcceptance;
    const counter = std.mem.indexOfPos(u8, accept_phase, acceptance, "advance_context.previous_weather_timestamp.* = accept_context.timestamp.*") orelse return error.MissingAcceptedHourCounter;
    const commit = std.mem.indexOfPos(u8, accept_phase, counter, "outer_hour_transaction.*.commit()") orelse return error.MissingOuterHourCommit;
    try std.testing.expect(material_refresh < storage_before);
    try std.testing.expect(storage_before < activity_reset);
    try std.testing.expect(transaction_begin < prepare_call);
    try std.testing.expect(prepare_call < science_call);
    try std.testing.expect(science_call < post_call);
    try std.testing.expect(post_call < accept_call);
    try std.testing.expect(acceptance < counter);
    try std.testing.expect(counter < commit);
}

test "production source binds every dedicated transport face and boundary output" {
    const source = try readRepositorySource("src/stages/hourly_heat_water_solute.zig");
    defer std.testing.allocator.free(source);
    const publisher_start = std.mem.lastIndexOf(u8, source, "noinline fn publishHourlyCellTransportLedgers(") orelse return error.MissingDedicatedTransportLedgerPublisher;
    const publisher_end = std.mem.indexOfPos(u8, source, publisher_start, "noinline fn publishHourlyLayerSurfaceHeatAndWater(") orelse return error.MissingDedicatedTransportLedgerPublisherEnd;
    const publisher = source[publisher_start..publisher_end];
    inline for (.{
        "accumulateOrganicTransport(",
        "accumulateMineralNitrogenTransport(",
        "accumulateDissolvedGasTransport(",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, publisher, needle));
    inline for (.{
        ".micropore_face_flux_g_by_component = self.organic_micropore_face_step_g",
        ".matrix_face_flux_mol_by_component = self.mineral_micropore_face_step_mol",
        ".micropore_face_flux_by_component = self.dissolved_gas_micropore_face_step_g",
    }) |needle| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, needle));
    const candidate = std.mem.indexOf(u8, publisher, "var dedicated_candidate:") orelse return error.MissingDedicatedTransportLedgerCandidate;
    const publish = std.mem.indexOfPos(u8, publisher, candidate, "@memcpy(context.hourly_cell_boundary_ledger.cells, dedicated_candidate.cells)") orelse return error.MissingDedicatedTransportLedgerPublish;
    try std.testing.expect(candidate < publish);
}

test "erosion books exact external and intercell elements and rejects a late export atomically" {
    var organic = try organic_state.State.init(std.testing.allocator, 2);
    defer organic.deinit();
    const organic_components = try erosion_organic_bridge.componentCount(&organic);
    var organic_workspace = try eroded_constituents.PackedWorkspace.init(std.testing.allocator, 2, organic_components);
    defer organic_workspace.deinit();
    var fertilizer_workspace = try eroded_constituents.PackedWorkspace.init(std.testing.allocator, 2, erosion_fertilizer_bridge.component_count);
    defer fertilizer_workspace.deinit();
    var mineral_fertilizer_workspace = try eroded_constituents.PackedWorkspace.init(std.testing.allocator, 2, erosion_mineral_fertilizer_bridge.component_count);
    defer mineral_fertilizer_workspace.deinit();
    var chemistry_workspace = try eroded_constituents.PackedWorkspace.init(std.testing.allocator, 2, erosion_chemistry_bridge.component_count);
    defer chemistry_workspace.deinit();
    var mineral_workspace = try eroded_constituents.PackedWorkspace.init(std.testing.allocator, 2, erosion_mineral_bridge.component_count);
    defer mineral_workspace.deinit();

    // Cell 0 -> cell 1, followed by cell 1 -> open east boundary.
    organic_workspace.flux.east[0] = 2;
    organic_workspace.flux.east[organic_components + 1] = 3;
    organic_workspace.exported[organic_components + 1] = 3;
    fertilizer_workspace.flux.east[0] = 1;
    fertilizer_workspace.flux.east[erosion_fertilizer_bridge.component_count] = 2;
    fertilizer_workspace.exported[erosion_fertilizer_bridge.component_count] = 2;
    // Cations are NH4-N, NH4-N, H, Al, Fe, Ca, Mg, Na, K.
    chemistry_workspace.flux.east[3] = 4;
    var calcite_component: ?usize = null;
    for (0..erosion_chemistry_bridge.component_count) |component| {
        const composition = try chemistryErosionComposition(component, 12, 14, 31);
        if (composition.carbon_g == 12 and composition.calcium_mol == 1) {
            calcite_component = component;
            break;
        }
    }
    const calcite = calcite_component orelse return error.MissingCalciteErosionComponent;
    const calcite_index = erosion_chemistry_bridge.component_count + calcite;
    chemistry_workspace.flux.east[calcite_index] = 5;
    chemistry_workspace.exported[calcite_index] = 5;

    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    const tolerances: ErosionAccountingTolerances = .{
        .absolute_g = 64 * std.math.floatEps(f64),
        .absolute_mol = 64 * std.math.floatEps(f64),
        .absolute_megagrams = 64 * std.math.floatEps(f64),
        .relative = 64 * std.math.floatEps(f64),
    };
    try accumulateErosionTransport(&ledger, 2, 1, &organic, &organic_workspace, &fertilizer_workspace, &mineral_fertilizer_workspace, &chemistry_workspace, &mineral_workspace, 12, 14, 31, tolerances);
    try std.testing.expectEqual(@as(f64, 2), ledger.cells[0].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 2), ledger.cells[1].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 60), ledger.cells[1].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 14), ledger.cells[0].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 14), ledger.cells[1].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 31), ledger.cells[1].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 4), ledger.cells[0].aluminum_output_mol);
    try std.testing.expectEqual(@as(f64, 4), ledger.cells[1].aluminum_input_mol);
    try std.testing.expectEqual(@as(f64, 5), ledger.cells[1].calcium_output_mol);

    const before = [_]BoundaryActivity{ ledger.cells[0], ledger.cells[1] };
    chemistry_workspace.exported[calcite_index] = 5 + 1024 * tolerances.absolute_mol;
    try std.testing.expectError(
        error.HourlyCellErosionExportMismatch,
        accumulateErosionTransport(&ledger, 2, 1, &organic, &organic_workspace, &fertilizer_workspace, &mineral_fertilizer_workspace, &chemistry_workspace, &mineral_workspace, 12, 14, 31, tolerances),
    );
    try std.testing.expectEqualSlices(BoundaryActivity, &before, ledger.cells);
}

test "production source binds exact erosion workspaces before aggregate landscape export" {
    const source = try readRepositorySource("src/stages/hourly_sediment.zig");
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "accumulateErosionTransport("));
    const per_cell = std.mem.indexOf(u8, source, "accumulateErosionTransport(") orelse return error.MissingPerCellErosionBinding;
    const aggregate = std.mem.indexOfPos(u8, source, per_cell, "const eroded_organic_export") orelse return error.MissingLandscapeErosionExport;
    try std.testing.expect(per_cell < aggregate);
    inline for (.{
        "context.eroded_organic_workspace",
        "context.eroded_fertilizer_workspace",
        "context.eroded_chemistry_workspace",
        "context.eroded_mineral_state.workspace",
    }) |needle| try std.testing.expect(std.mem.indexOfPos(u8, source, per_cell, needle) != null);
}

test "hourly mineral texture gate resolves intercell transfer and rejects ROCK loss" {
    const before = [_]inventory.Storage{
        .{ .sand_megagrams = 4, .silt_megagrams = 2, .clay_megagrams = 1, .rock_additive = 0.25 },
        .{ .sand_megagrams = 1, .silt_megagrams = 3, .clay_megagrams = 2, .rock_additive = 0.5 },
    };
    const after = [_]inventory.Storage{
        .{ .sand_megagrams = 3, .silt_megagrams = 1.5, .clay_megagrams = 0.75, .rock_additive = 0.25 },
        .{ .sand_megagrams = 2, .silt_megagrams = 3.5, .clay_megagrams = 2.25, .rock_additive = 0.5 },
    };
    const activity = [_]BoundaryActivity{
        .{ .sand_output_megagrams = 1, .silt_output_megagrams = 0.5, .clay_output_megagrams = 0.25 },
        .{ .sand_input_megagrams = 1, .silt_input_megagrams = 0.5, .clay_input_megagrams = 0.25 },
    };
    var report = try evaluate(std.testing.allocator, &before, &after, &activity, &.{ 1, 1 }, .{ .absolute_per_area = .{}, .relative = 1e-9 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.accepted());

    var leaked = after;
    leaked[0].rock_additive -= 0.01;
    var rejected = try evaluate(std.testing.allocator, &before, &leaked, &activity, &.{ 1, 1 }, .{ .absolute_per_area = .{}, .relative = 1e-9 });
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rejected.failing_cell_count[@intFromEnum(Quantity.rock_additive)]);
}

test "hourly texture gate separates representation roundoff from physical leakage" {
    const standing: f64 = 1;
    const adjacent: f64 = @bitCast(@as(u64, @bitCast(standing)) + 2);
    const before = [_]inventory.Storage{.{ .sand_megagrams = standing }};
    const rounded = [_]inventory.Storage{.{ .sand_megagrams = adjacent }};
    var accepted_report = try evaluate(
        std.testing.allocator,
        &before,
        &rounded,
        &.{.{}},
        &.{1},
        .{ .absolute_per_area = .{}, .relative = 1e-9 },
    );
    defer accepted_report.deinit(std.testing.allocator);
    const rounded_closure = accepted_report.cells[0].closure[@intFromEnum(Quantity.sand)];
    try std.testing.expect(rounded_closure.absolute > rounded_closure.acceptance_limit);
    try std.testing.expect(rounded_closure.absolute <= rounded_closure.arithmetic_roundoff_allowance);
    try std.testing.expect(!rounded_closure.physical_accepted);
    try std.testing.expect(rounded_closure.accepted);
    try std.testing.expectEqual(@as(usize, 0), accepted_report.failing_cell_count[@intFromEnum(Quantity.sand)]);

    const leaked = [_]inventory.Storage{.{ .sand_megagrams = standing + 1e-12 }};
    var rejected_report = try evaluate(
        std.testing.allocator,
        &before,
        &leaked,
        &.{.{}},
        &.{1},
        .{ .absolute_per_area = .{}, .relative = 1e-9 },
    );
    defer rejected_report.deinit(std.testing.allocator);
    const leaked_closure = rejected_report.cells[0].closure[@intFromEnum(Quantity.sand)];
    try std.testing.expect(leaked_closure.absolute > leaked_closure.effective_acceptance_limit);
    try std.testing.expectEqual(@as(usize, 1), rejected_report.failing_cell_count[@intFromEnum(Quantity.sand)]);
}

test "chemistry carrier provenance is quantity-local and cannot mask material leakage" {
    const standing: f64 = 1;
    const adjacent: f64 = @bitCast(@as(u64, @bitCast(standing)) + 2);
    const before = [_]inventory.Storage{.{
        .calcium_mol = standing,
        .phosphate_phosphorus_g = standing,
    }};
    const rounded = [_]inventory.Storage{.{
        .calcium_mol = adjacent,
        .phosphate_phosphorus_g = standing,
    }};
    const provenance: BoundaryActivity = .{
        .calcium_storage_update_roundoff_allowance_mol = 1.0e-14,
        .phosphorus_storage_update_roundoff_allowance_g = 2.0e-14,
    };
    var accepted_report = try evaluate(
        std.testing.allocator,
        &before,
        &rounded,
        &.{provenance},
        &.{1},
        .{ .absolute_per_area = .{}, .relative = std.math.floatEps(f64) },
    );
    defer accepted_report.deinit(std.testing.allocator);
    const calcium = accepted_report.cells[0].closure[@intFromEnum(Quantity.calcium)];
    const phosphorus = accepted_report.cells[0].closure[@intFromEnum(Quantity.phosphorus)];
    try std.testing.expect(!calcium.physical_accepted);
    try std.testing.expect(calcium.accepted);
    try std.testing.expect(calcium.arithmetic_roundoff_allowance >= 1.0e-14);
    try std.testing.expect(phosphorus.arithmetic_roundoff_allowance >= 2.0e-14);
    try std.testing.expectEqual(@as(f64, 1.0e-14), storageUpdateRoundoffAllowance(.calcium, provenance));
    try std.testing.expectEqual(@as(f64, 2.0e-14), storageUpdateRoundoffAllowance(.phosphorus, provenance));
    try std.testing.expectEqual(@as(f64, 0), storageUpdateRoundoffAllowance(.magnesium, provenance));

    const leaked = [_]inventory.Storage{.{
        .calcium_mol = standing + 1.0e-10,
        .phosphate_phosphorus_g = standing,
    }};
    var rejected_report = try evaluate(
        std.testing.allocator,
        &before,
        &leaked,
        &.{provenance},
        &.{1},
        .{ .absolute_per_area = .{}, .relative = std.math.floatEps(f64) },
    );
    defer rejected_report.deinit(std.testing.allocator);
    try std.testing.expect(!rejected_report.cells[0].closure[@intFromEnum(Quantity.calcium)].accepted);
}

test "plant atmosphere activity preserves fixation respiration fire and ammonia signs" {
    const activity = try plantAtmosphereActivity(10, 2, 3, 4, 2.5, -0.25, 1.25, -0.5, -0.75);
    try std.testing.expectEqual(@as(f64, 10), activity.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 5), activity.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 4), activity.oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 25), activity.oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 25), activity.oxygen_internal_production_g);
    try std.testing.expectEqual(@as(f64, 4), activity.oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 1.25), activity.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 0.75), activity.nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 0.75), activity.phosphorus_output_g);

    const respiration = try plantAtmosphereActivity(-2, 0, 0, 0, 2.5, 1, 0, 0, 0);
    try std.testing.expectEqual(@as(f64, 2), respiration.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 5), respiration.oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 5), respiration.oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 1), respiration.nitrogen_input_g);
}

test "canopy ammonia source remains cell local" {
    var canopy = try canopy_photosynthesis.State.init(std.testing.allocator, 2, 2, &.{ 1, 2, 1, 1 }, &.{ 1, 1, 1, 1, 1 }, &.{ 1, 1, 1, 1, 1 });
    defer canopy.deinit();
    canopy.branch_canopy_ammonia_exchange_g_n_per_h[0..5].* = .{ 1, 2, -0.5, 100, 200 };
    try std.testing.expectEqual(@as(f64, 2.5), try canopyAmmoniaNetInputForCell(&canopy, 0));
    try std.testing.expectEqual(@as(f64, 300), try canopyAmmoniaNetInputForCell(&canopy, 1));
}

test "plant atmosphere producer preserves per-cell canopy and combustion ownership" {
    var canopy = try canopy_photosynthesis.State.init(std.testing.allocator, 2, 2, &.{ 1, 2, 1, 1 }, &.{ 1, 1, 1, 1, 1 }, &.{ 1, 1, 1, 1, 1 });
    defer canopy.deinit();
    canopy.branch_canopy_ammonia_exchange_g_n_per_h[0..5].* = .{ 1, 2, -0.5, 100, 200 };
    canopy.branch_symbiotic_fixed_nitrogen_g_n_per_h[3] = 1;
    canopy.branch_symbiotic_fixed_nitrogen_g_n_per_h[4] = 2;
    var roots = try plant_root_system.State.init(std.testing.allocator, 4, 1, 1);
    defer roots.deinit();
    roots.fixation_uptake_g_n_per_h[2] = 0.5;
    roots.fixation_uptake_g_n_per_h[3] = 0.25;
    var carbon = try canopy_carbon_state_update.State.init(std.testing.allocator, 2, 2);
    defer carbon.deinit();
    var fire = try canopy_fire_state_update.State.init(std.testing.allocator, 2, 2);
    defer fire.deinit();
    var combustion = try plant_combustion_state_update.State.init(std.testing.allocator, 4);
    defer combustion.deinit();
    carbon.hourly_net_fixation_g_c_per_h_by_cell[1] = 20;
    fire.carbon_dioxide_emission_g_c_per_h_by_cell[1] = 2;
    fire.methane_emission_g_c_per_h_by_cell[1] = 3;
    fire.oxygen_consumption_g_o_per_h_by_cell[1] = 4;
    combustion.signed_nitrogen_loss_g_n_per_h_by_plant[2] = -0.5;
    combustion.signed_nitrogen_loss_g_n_per_h_by_plant[3] = -0.25;
    combustion.signed_phosphorus_loss_g_p_per_h_by_plant[2] = -0.4;
    combustion.signed_phosphorus_loss_g_p_per_h_by_plant[3] = -0.6;

    const accepted = try plantAtmosphereCellActivityForCell(&canopy, &roots, &carbon, &fire, &combustion, 1, 2);
    const activity = accepted.boundary;
    try std.testing.expectEqual(@as(f64, 20), activity.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 5), activity.carbon_output_g);
    try std.testing.expectEqual(@as(f64, 4), activity.oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 40), activity.oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 40), activity.oxygen_internal_production_g);
    try std.testing.expectEqual(@as(f64, 4), activity.oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 303.75), activity.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 0.75), accepted.fire_nutrient_output.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1), activity.phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 1), accepted.fire_nutrient_output.phosphorus_g_p);
}

test "shoot fire products precede SOLUTE while late accounting remains single-owner and rollback ordered" {
    const source = try readRepositorySource("src/ecosys_ng.zig");
    defer std.testing.allocator.free(source);
    const stage_source = try readRepositorySource("src/stages/hourly_heat_water_solute.zig");
    defer std.testing.allocator.free(stage_source);
    const vegetation_source = try readRepositorySource("src/stages/hourly_vegetation.zig");
    defer std.testing.allocator.free(vegetation_source);
    const post_start = std.mem.indexOf(u8, source, "noinline fn postScienceAccounting(") orelse return error.MissingPostSciencePhase;
    const management_start = std.mem.indexOfPos(u8, source, post_start, "noinline fn postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingPhase;
    const canopy_wrapper_start = std.mem.indexOfPos(u8, source, management_start, "noinline fn postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapper;
    const canopy_start = std.mem.indexOfPos(u8, source, canopy_wrapper_start, "noinline fn postScienceCanopyAndEnergy(") orelse return error.MissingCanopyEnergyPhase;
    const fire_start = std.mem.indexOfPos(u8, source, canopy_start, "noinline fn postScienceFireAndCloseout(") orelse return error.MissingFireCloseoutPhase;
    const accept_start = std.mem.indexOfPos(u8, source, fire_start, "noinline fn acceptHourAndPublish(") orelse return error.MissingAcceptHourPhase;
    const prepare_start = std.mem.indexOfPos(u8, source, accept_start, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(u8, source, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(u8, source, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const post_phase = source[post_start..management_start];
    const canopy_wrapper = source[canopy_wrapper_start..canopy_start];
    const fire_phase = source[fire_start..accept_start];
    const accept_phase = source[accept_start..prepare_start];
    const advance_phase = source[advance_start..timeline_start];
    const management_call = std.mem.indexOf(u8, post_phase, "try postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingCall;
    const canopy_wrapper_call = std.mem.indexOfPos(u8, post_phase, management_call, "try postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapperCall;
    const canopy_call = std.mem.indexOf(u8, canopy_wrapper, "try postScienceCanopyAndEnergy(") orelse return error.MissingCanopyEnergyCall;
    const fire_call = std.mem.indexOfPos(u8, canopy_wrapper, canopy_call, "try postScienceFireAndCloseout(") orelse return error.MissingFireCloseoutCall;
    const transaction_begin = std.mem.indexOf(
        u8,
        advance_phase,
        "driver_context.outer_hour_transaction_workspace.*.begin(",
    ) orelse return error.MissingOuterHourTransaction;
    const stable_capture = std.mem.indexOfPos(
        u8,
        advance_phase,
        transaction_begin,
        "captureStable(&driver_context.hourly_science_context.*",
    ) orelse return error.MissingHourlyScienceRollbackCapture;
    const post_call = std.mem.indexOfPos(u8, advance_phase, stable_capture, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceCall;
    const accept_call = std.mem.indexOfPos(u8, advance_phase, post_call, "try acceptHourAndPublish(driver_context,") orelse return error.MissingAcceptHourCall;
    const attempt_start = std.mem.indexOf(
        u8,
        stage_source,
        "fn solveSoilHeatWaterAndSoluteTransportAttempt(",
    ) orelse return error.MissingSoilHeatWaterSoluteAttempt;
    const attempt = stage_source[attempt_start..];
    const grosub_extract = std.mem.indexOf(u8, attempt, "advanceUptakeGrowthAndExtract(") orelse return error.MissingGrosubExtractPhase;
    const pre_solute_fire = std.mem.indexOfPos(u8, attempt, grosub_extract, "produceCanopyStandingDeadFireBeforeSolute(") orelse return error.MissingPreSoluteShootFirePhase;
    const solute = std.mem.indexOfPos(u8, attempt, pre_solute_fire, ".solute,") orelse return error.MissingSolutePhase;
    const shoot_fire_owner = std.mem.indexOf(u8, vegetation_source, "pub noinline fn produceCanopyStandingDeadFireBeforeSolute(") orelse return error.MissingShootFireOwner;
    const shoot_fire = std.mem.indexOfPos(u8, vegetation_source, shoot_fire_owner, "plant_shoot_fire.apply(") orelse return error.MissingShootFireScience;
    const solute_publication = std.mem.indexOfPos(u8, vegetation_source, shoot_fire, ".publishCanopyFireSurfaceSolutes(") orelse return error.MissingShootFireSolutePublication;
    const salt_publication = std.mem.indexOfPos(u8, vegetation_source, solute_publication, ".accumulateAcceptedLegacyPlantSaltInput(") orelse return error.MissingShootFireSaltPublication;
    const combustion_state = std.mem.indexOf(
        u8,
        fire_phase,
        "plant_combustion_state_update.refresh(",
    ) orelse return error.MissingShootFireAcceptedState;
    const cell_source = std.mem.indexOfPos(
        u8,
        fire_phase,
        combustion_state,
        "plantAtmosphereCellActivityForCell(",
    ) orelse return error.MissingShootFireCellBoundarySource;
    const domain_reduce = std.mem.indexOfPos(
        u8,
        fire_phase,
        cell_source,
        ".accumulateAcceptedPlantFireNutrientEmissionTotals(",
    ) orelse return error.MissingShootFireDomainBoundaryReduction;
    const candidate_publish = std.mem.indexOfPos(
        u8,
        fire_phase,
        domain_reduce,
        "driver_context.landscape_mass_balance_state.*.boundary_ledger = plant_atmosphere_domain_candidate;",
    ) orelse return error.MissingShootFireDomainCandidatePublish;
    const acceptance = std.mem.indexOfPos(
        u8,
        accept_phase,
        0,
        "hourly_cell_conservation.requireAccepted(",
    ) orelse return error.MissingHourlyCellAcceptance;
    const transaction_commit = std.mem.indexOfPos(
        u8,
        accept_phase,
        acceptance,
        "outer_hour_transaction.*.commit();",
    ) orelse return error.MissingOuterHourCommit;

    try std.testing.expect(transaction_begin < stable_capture);
    try std.testing.expect(stable_capture < post_call);
    try std.testing.expect(post_call < accept_call);
    try std.testing.expect(management_call < canopy_wrapper_call);
    try std.testing.expect(canopy_call < fire_call);
    try std.testing.expect(grosub_extract < pre_solute_fire and pre_solute_fire < solute);
    try std.testing.expect(shoot_fire_owner < shoot_fire and shoot_fire < solute_publication and solute_publication < salt_publication);
    try std.testing.expect(std.mem.indexOf(u8, fire_phase, "plant_shoot_fire.apply(") == null);
    try std.testing.expect(std.mem.indexOf(u8, fire_phase, "convergeSurfaceLitterChemistry(") == null);
    try std.testing.expect(combustion_state < cell_source);
    try std.testing.expect(cell_source < domain_reduce);
    try std.testing.expect(domain_reduce < candidate_publish);
    try std.testing.expect(acceptance < transaction_commit);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, ".accumulateAcceptedPlantFireNutrientEmissionTotals("),
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, vegetation_source, "plant_shoot_fire.apply("));
    try std.testing.expect(std.mem.indexOf(u8, source, "plant_shoot_fire.apply(") == null);
}

test "soil aqueous external activity preserves cell directions formulas and atomic preflight" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    var fluxes = [_]f64{0} ** (2 * 2 * solute_species.AqueousSpecies.count);
    const carbonate = @intFromEnum(solute_species.AqueousSpecies.carbonate);
    const calcium_sulfate = @intFromEnum(solute_species.AqueousSpecies.calcium_sulfate);
    const silicate = @intFromEnum(solute_species.AqueousSpecies.hydrogen_silicate);
    fluxes[carbonate] = 2;
    fluxes[solute_species.AqueousSpecies.count + carbonate] = -1;
    fluxes[solute_species.AqueousSpecies.count + calcium_sulfate] = -3;
    fluxes[2 * solute_species.AqueousSpecies.count + silicate] = 4;
    try accumulateAqueousExternalBoundaries(&ledger, &fluxes, &.{ true, true, true, true }, 2, 12, 31);
    try std.testing.expectEqual(@as(f64, 24), ledger.cells[0].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 12), ledger.cells[0].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[0].calcium_output_mol);
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[0].sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 4), ledger.cells[1].silicon_input_mol);

    ledger.reset();
    ledger.cells[1].silicon_input_mol = std.math.floatMax(f64);
    fluxes[2 * solute_species.AqueousSpecies.count + silicate] = std.math.floatMax(f64);
    try std.testing.expectError(
        error.HourlyCellBoundaryOverflow,
        accumulateAqueousExternalBoundaries(&ledger, &fluxes, &.{ true, true, true, true }, 2, 12, 31),
    );
    try std.testing.expectEqual(@as(f64, 0), ledger.cells[0].carbon_input_g);
    try std.testing.expectEqual(std.math.floatMax(f64), ledger.cells[1].silicon_input_mol);
}

test "soil aqueous external runtime traversal is formula and order equivalent" {
    const species_count = solute_species.AqueousSpecies.count;
    var fluxes: [3 * species_count]f64 = @splat(0);
    for (0..species_count) |species_index| {
        const magnitude = @as(f64, @floatFromInt(species_index + 1)) / 8.0;
        fluxes[species_index] = if (species_index % 2 == 0) magnitude else -magnitude;
        // Inactive-layer values must have no effect, including non-finite ones.
        fluxes[species_count + species_index] = std.math.nan(f64);
        const later_magnitude = @as(f64, @floatFromInt(species_count - species_index)) / 16.0;
        fluxes[2 * species_count + species_index] = if (species_index % 3 == 0)
            -later_magnitude
        else
            later_magnitude;
    }

    const actual = try aqueousExternalActivityForCell(
        &fluxes,
        &.{ true, false, true },
        3,
        12,
        31,
        0,
    );

    var carbon_input_g: f64 = 0;
    var carbon_output_g: f64 = 0;
    var phosphorus_input_g: f64 = 0;
    var phosphorus_output_g: f64 = 0;
    var element_input_mol: [9]f64 = @splat(0);
    var element_output_mol: [9]f64 = @splat(0);
    for (0..3) |local_layer| {
        if (local_layer == 1) continue;
        const first = local_layer * species_count;
        for (0..species_count) |species_index| {
            const signed_mol = fluxes[first + species_index];
            const amount_mol = @abs(signed_mol);
            const formula = surface_aqueous.formula(@enumFromInt(species_index));
            const elements = [9]f64{
                formula.aluminum_mol,
                formula.iron_mol,
                formula.calcium_mol,
                formula.magnesium_mol,
                formula.sodium_mol,
                formula.potassium_mol,
                formula.sulfur_mol,
                formula.chloride_mol,
                formula.silicon_mol,
            };
            if (signed_mol >= 0) {
                carbon_input_g += amount_mol * formula.carbon_mol * 12;
                phosphorus_input_g += amount_mol * formula.phosphorus_mol * 31;
                for (&element_input_mol, elements) |*total, contribution|
                    total.* += amount_mol * contribution;
            } else {
                carbon_output_g += amount_mol * formula.carbon_mol * 12;
                phosphorus_output_g += amount_mol * formula.phosphorus_mol * 31;
                for (&element_output_mol, elements) |*total, contribution|
                    total.* += amount_mol * contribution;
            }
        }
    }
    const expected: BoundaryActivity = .{
        .carbon_input_g = carbon_input_g,
        .carbon_output_g = carbon_output_g,
        .phosphorus_input_g = phosphorus_input_g,
        .phosphorus_output_g = phosphorus_output_g,
        .aluminum_input_mol = element_input_mol[0],
        .aluminum_output_mol = element_output_mol[0],
        .iron_input_mol = element_input_mol[1],
        .iron_output_mol = element_output_mol[1],
        .calcium_input_mol = element_input_mol[2],
        .calcium_output_mol = element_output_mol[2],
        .magnesium_input_mol = element_input_mol[3],
        .magnesium_output_mol = element_output_mol[3],
        .sodium_input_mol = element_input_mol[4],
        .sodium_output_mol = element_output_mol[4],
        .potassium_input_mol = element_input_mol[5],
        .potassium_output_mol = element_output_mol[5],
        .sulfur_input_mol = element_input_mol[6],
        .sulfur_output_mol = element_output_mol[6],
        .chloride_input_mol = element_input_mol[7],
        .chloride_output_mol = element_output_mol[7],
        .silicon_input_mol = element_input_mol[8],
        .silicon_output_mol = element_output_mol[8],
    };
    try std.testing.expectEqualDeep(expected, actual);
}

test "dedicated soil transports preserve boundary signs intercell direction and late atomicity" {
    var axes = [_]u2{0};
    var micro_faces = [_]soil_solute_transport.Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }};
    var macro_faces = micro_faces;
    var zero_face = [_]f64{0};
    var slot_sources = [_]usize{0};
    var slot_destinations = [_]usize{1};
    var active_faces = [_]bool{true};
    var active_layers = [_]bool{ true, true };
    var faces: transport_hydrology.SoilFaces = .{
        .allocator = std.testing.allocator,
        .direction_axis = &axes,
        .slot_source_cell = &slot_sources,
        .slot_default_destination_cell = &slot_destinations,
        .active_by_face = &active_faces,
        .active_by_layer = &active_layers,
        .micropore_faces = &micro_faces,
        .macropore_faces = &macro_faces,
        .micropore_water_flux_m3_per_step = &zero_face,
        .macropore_water_flux_m3_per_step = &zero_face,
        .vapor_flux_m3_per_step = &zero_face,
        .heat_flux_megajoules_per_step = &zero_face,
    };

    var gas_boundary = [_]f64{0} ** (2 * gas_transport.species_count);
    var gas_micro = [_]f64{0} ** gas_transport.species_count;
    var gas_macro = [_]f64{0} ** gas_transport.species_count;
    gas_boundary[@intFromEnum(gas_transport.Species.carbon_dioxide)] = 2;
    gas_boundary[gas_transport.species_count + @intFromEnum(gas_transport.Species.oxygen)] = -3;
    gas_micro[@intFromEnum(gas_transport.Species.carbon_dioxide)] = 5;
    gas_macro[@intFromEnum(gas_transport.Species.carbon_dioxide)] = -1;
    gas_micro[@intFromEnum(gas_transport.Species.nitrogen)] = -2;
    gas_micro[@intFromEnum(gas_transport.Species.ammonia)] = 99;
    var gas_ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer gas_ledger.deinit();
    try accumulateDissolvedGasTransport(&gas_ledger, &faces, &gas_boundary, &gas_micro, &gas_macro, 1);
    try std.testing.expectEqual(@as(f64, 2), gas_ledger.cells[0].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 4), gas_ledger.cells[0].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 4), gas_ledger.cells[1].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 3), gas_ledger.cells[1].oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 2), gas_ledger.cells[1].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 2), gas_ledger.cells[0].nitrogen_input_g);

    var organic_boundary = [_]f64{0} ** (2 * organic_transport.component_count);
    var organic_micro = [_]f64{0} ** organic_transport.component_count;
    var organic_macro = [_]f64{0} ** organic_transport.component_count;
    organic_boundary[@intFromEnum(organic_transport.Component.dissolved_organic_carbon)] = 3;
    organic_boundary[organic_transport.component_count + @intFromEnum(organic_transport.Component.dissolved_organic_nitrogen)] = -4;
    organic_micro[@intFromEnum(organic_transport.Component.dissolved_organic_carbon)] = 5;
    organic_macro[@intFromEnum(organic_transport.Component.dissolved_organic_carbon)] = 1;
    organic_micro[@intFromEnum(organic_transport.Component.dissolved_organic_phosphorus)] = -2;
    var organic_ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer organic_ledger.deinit();
    try accumulateOrganicTransport(&organic_ledger, &faces, &organic_boundary, &organic_micro, &organic_macro, 1);
    try std.testing.expectEqual(@as(f64, 3), organic_ledger.cells[0].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 6), organic_ledger.cells[0].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 6), organic_ledger.cells[1].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 4), organic_ledger.cells[1].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 2), organic_ledger.cells[1].phosphorus_output_g);
    try std.testing.expectEqual(@as(f64, 2), organic_ledger.cells[0].phosphorus_input_g);

    var mineral_micro = [_]f64{0} ** mineral_nitrogen_transport.species_count;
    var mineral_macro = [_]f64{0} ** mineral_nitrogen_transport.species_count;
    mineral_micro[@intFromEnum(mineral_nitrogen_transport.Species.nitrate_non_band)] = 0.5;
    mineral_macro[@intFromEnum(mineral_nitrogen_transport.Species.ammonium_non_band)] = -0.25;
    var mineral_ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer mineral_ledger.deinit();
    try accumulateMineralNitrogenTransport(&mineral_ledger, &faces, &.{ 7, 11 }, &mineral_micro, &mineral_macro, 1, 14);
    try std.testing.expectEqual(@as(f64, 14), mineral_ledger.cells[0].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 14.5), mineral_ledger.cells[1].nitrogen_output_g);
    try std.testing.expectEqual(@as(f64, 3.5), mineral_ledger.cells[0].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 7), mineral_ledger.cells[1].nitrogen_input_g);

    gas_ledger.reset();
    gas_ledger.cells[1].carbon_input_g = 0.75 * std.math.floatMax(f64);
    gas_micro[@intFromEnum(gas_transport.Species.carbon_dioxide)] = 0.75 * std.math.floatMax(f64);
    gas_macro[@intFromEnum(gas_transport.Species.carbon_dioxide)] = 0;
    const before = gas_ledger.cells[0..2].*;
    try std.testing.expectError(
        error.HourlyCellBoundaryOverflow,
        accumulateDissolvedGasTransport(&gas_ledger, &faces, &gas_boundary, &gas_micro, &gas_macro, 1),
    );
    try std.testing.expectEqualDeep(before, gas_ledger.cells[0..2].*);
}

test "equal opposite cell leaks fail despite exact domain cancellation" {
    const before = [_]inventory.Storage{ .{}, .{ .water_m3 = 1 } };
    const after = [_]inventory.Storage{ .{ .water_m3 = 1 }, .{} };
    var report = try evaluate(std.testing.allocator, &before, &after, &.{ .{}, .{} }, &.{ 1, 1 }, .{ .absolute_per_area = .{ .water_m = 1e-12 }, .relative = 1e-9 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), report.failing_cell_count[@intFromEnum(Quantity.water)]);
    try std.testing.expectError(error.HourlyCellConservationFailure, requireAccepted(report));
}

test "surface runoff donor and recipient close water and immutable-temperature heat locally and by domain" {
    const runoff_water_m3: f64 = 0.001;
    const runoff_heat_megajoules = 4.19 * 300.0 * runoff_water_m3;
    const before = [_]inventory.Storage{
        .{ .water_m3 = 0.02, .heat_megajoules = 325 },
        .{ .water_m3 = 0.01, .heat_megajoules = 294 },
    };
    const after = [_]inventory.Storage{
        .{ .water_m3 = before[0].water_m3 - runoff_water_m3, .heat_megajoules = before[0].heat_megajoules - runoff_heat_megajoules },
        .{ .water_m3 = before[1].water_m3 + runoff_water_m3, .heat_megajoules = before[1].heat_megajoules + runoff_heat_megajoules },
    };
    const activity = [_]BoundaryActivity{
        try surfaceRunoffWaterHeatActivity(0, runoff_water_m3, 0, runoff_heat_megajoules),
        try surfaceRunoffWaterHeatActivity(runoff_water_m3, 0, runoff_heat_megajoules, 0),
    };
    var report = try evaluate(std.testing.allocator, &before, &after, &activity, &.{ 1, 1 }, .{
        .absolute_per_area = .{ .water_m = 1e-12, .heat_megajoules_m2 = 1e-12 },
        .relative = 1e-10,
    });
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
    inline for (.{ Quantity.water, Quantity.heat }) |quantity| {
        const index = @intFromEnum(quantity);
        try std.testing.expectEqual(@as(usize, 0), report.failing_cell_count[index]);
        for (report.cells) |cell_report|
            try std.testing.expectApproxEqAbs(@as(f64, 0), cell_report.closure[index].residual, 1e-13);
    }
    try std.testing.expectEqual(activity[0].water_output_m3, activity[1].water_input_m3);
    try std.testing.expectEqual(activity[0].heat_output_megajoules, activity[1].heat_input_megajoules);
    try std.testing.expectApproxEqAbs(
        before[0].water_m3 + before[1].water_m3,
        after[0].water_m3 + after[1].water_m3,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        before[0].heat_megajoules + before[1].heat_megajoules,
        after[0].heat_megajoules + after[1].heat_megajoules,
        1e-13,
    );
}

test "surface runoff boundary export closes local and domain water and heat" {
    const runoff_water_m3: f64 = 0.001;
    const runoff_heat_megajoules = 4.19 * 290.0 * runoff_water_m3;
    const before = [_]inventory.Storage{.{ .water_m3 = 0.02, .heat_megajoules = 400 }};
    const after = [_]inventory.Storage{.{
        .water_m3 = before[0].water_m3 - runoff_water_m3,
        .heat_megajoules = before[0].heat_megajoules - runoff_heat_megajoules,
    }};
    const activity = [_]BoundaryActivity{try surfaceRunoffWaterHeatActivity(
        0,
        runoff_water_m3,
        0,
        runoff_heat_megajoules,
    )};
    var report = try evaluate(std.testing.allocator, &before, &after, &activity, &.{1}, .{
        .absolute_per_area = .{ .water_m = 1e-12, .heat_megajoules_m2 = 1e-12 },
        .relative = 1e-10,
    });
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
    inline for (.{ Quantity.water, Quantity.heat }) |quantity| {
        const closure = report.cells[0].closure[@intFromEnum(quantity)];
        try std.testing.expect(closure.accepted);
        try std.testing.expectApproxEqAbs(@as(f64, 0), closure.residual, 1e-13);
    }
}

test "surface and canopy heat booking preserves each cell instead of only its domain sum" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    try ledger.accumulateSurfaceAndCanopyHeat(
        &.{ 2, -1 },
        &.{ 0.5, -0.5 },
        &.{ -0.25, 0.25 },
        &.{ -0.05, 0.05 },
        &.{ 10, 20 },
        &.{ -2, 1 },
    );
    // Cell 0: (2 + .5 - .25 - .05)*10 - 2 = +20 MJ.
    try std.testing.expectApproxEqAbs(@as(f64, 20), ledger.cells[0].heat_input_megajoules, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), ledger.cells[0].heat_output_megajoules);
    // Cell 1: (-1 - .5 + .25 + .05)*20 + 1 = -23 MJ.
    try std.testing.expectEqual(@as(f64, 0), ledger.cells[1].heat_input_megajoules);
    try std.testing.expectApproxEqAbs(@as(f64, 23), ledger.cells[1].heat_output_megajoules, 1e-12);
}

test "surface endpoint reference heat is cell resolved and atomic" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    try ledger.accumulate(0, .{ .heat_input_megajoules = 4 });
    const before: [2]BoundaryActivity = ledger.cells[0..2].*;
    try std.testing.expectError(
        error.InvalidHourlyCellBoundaryActivity,
        ledger.accumulateSurfaceEndpointReferenceHeat(
            &.{ 0.1, 0.2 },
            &.{ 0, std.math.nan(f64) },
            4.19,
            1.9274 / 0.917,
            273.15,
            2465,
        ),
    );
    try std.testing.expectEqualSlices(BoundaryActivity, &before, ledger.cells);
    try ledger.accumulateSurfaceEndpointReferenceHeat(
        &.{ 0.1, -0.2 },
        &.{ 0.01, -0.02 },
        4.19,
        1.9274 / 0.917,
        273.15,
        2465,
    );
    const cell0 = (4.19 - 1.9274 / 0.917) * 273.15 * 0.1 - 2465 * 0.01;
    const cell1 = (4.19 - 1.9274 / 0.917) * 273.15 * -0.2 + 2465 * 0.02;
    try std.testing.expectEqual(@as(f64, 4), ledger.cells[0].heat_input_megajoules);
    try std.testing.expectApproxEqAbs(cell0, ledger.cells[0].heat_internal_production_megajoules, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), ledger.cells[1].heat_internal_production_megajoules);
    try std.testing.expectApproxEqAbs(-cell1, ledger.cells[1].heat_internal_consumption_megajoules, 1e-12);
}

test "element-resolved hourly quantities use independent units and internal hydrogen terms" {
    const before = [_]inventory.Storage{.{}};
    const after = [_]inventory.Storage{.{
        .water_m3 = 1,
        .heat_megajoules = 2,
        .oxygen_g = 3,
        .hydrogen_g = 1,
        .residue_carbon_g = 4,
        .ammonium_nitrogen_g = 5,
        .phosphate_phosphorus_g = 6,
        .aluminum_mol = 7,
        .iron_mol = 8,
        .calcium_mol = 9,
        .magnesium_mol = 10,
        .sodium_mol = 11,
        .potassium_mol = 12,
        .sulfur_mol = 13,
        .chloride_mol = 14,
        .silicon_mol = 15,
    }};
    const activity = [_]BoundaryActivity{.{
        .water_input_m3 = 1,
        .heat_input_megajoules = 2,
        .oxygen_input_g = 3,
        .hydrogen_internal_production_g = 2,
        .hydrogen_internal_consumption_g = 1,
        .carbon_input_g = 4,
        .nitrogen_input_g = 5,
        .phosphorus_input_g = 6,
        .aluminum_input_mol = 7,
        .iron_input_mol = 8,
        .calcium_input_mol = 9,
        .magnesium_input_mol = 10,
        .sodium_input_mol = 11,
        .potassium_input_mol = 12,
        .sulfur_input_mol = 13,
        .chloride_input_mol = 14,
        .silicon_input_mol = 15,
    }};
    var report = try evaluate(std.testing.allocator, &before, &after, &activity, &.{10}, .{ .absolute_per_area = .{}, .relative = 1e-9 });
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
    for (report.cells[0].closure) |closure| {
        try std.testing.expectEqual(@as(f64, 0), closure.residual);
        try std.testing.expect(closure.accepted);
    }
}

test "aggregate ions cannot hide cross-element cancellation" {
    const before = [_]inventory.Storage{.{
        .aluminum_mol = 1,
        .ion_inventory_mol = 1,
    }};
    const after = [_]inventory.Storage{.{
        .sodium_mol = 1,
        .ion_inventory_mol = 1,
    }};
    var report = try evaluate(std.testing.allocator, &before, &after, &.{.{}}, &.{1}, .{
        .absolute_per_area = .{ .ions_mol_m2 = 1e-12 },
        .relative = 1e-9,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), report.failing_cell_count[@intFromEnum(Quantity.aluminum)]);
    try std.testing.expectEqual(@as(usize, 1), report.failing_cell_count[@intFromEnum(Quantity.sodium)]);
    try std.testing.expectError(error.HourlyCellConservationFailure, requireAccepted(report));
}

test "full aqueous formula maps complexes to their conserved elements" {
    var amounts = [_]f64{0} ** solute_species.AqueousSpecies.count;
    amounts[@intFromEnum(solute_species.AqueousSpecies.aluminum_sulfate)] = 2;
    amounts[@intFromEnum(solute_species.AqueousSpecies.band_calcium_h2po4)] = 3;
    amounts[@intFromEnum(solute_species.AqueousSpecies.hydrogen_silicate)] = 4;
    const activity = try aqueousElementActivity(&amounts, .output);
    try std.testing.expectEqual(@as(f64, 2), activity.aluminum_output_mol);
    try std.testing.expectEqual(@as(f64, 2), activity.sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 3), activity.calcium_output_mol);
    try std.testing.expectEqual(@as(f64, 4), activity.silicon_output_mol);
}

test "accepted atmospheric snow and direct branches book every tracked element by source cell" {
    var primary = [_]f64{0} ** snow_solutes.species_count;
    var salts = [_]f64{0} ** snow_solutes.salt_species_count;
    var direct = [_]snow_solutes.SurfaceDischarge{.{}};
    primary[@intFromEnum(snow_solutes.Species.carbon_dioxide_carbon)] = 1;
    direct[0].litter_g[@intFromEnum(snow_solutes.Species.methane_carbon)] = 2;
    primary[@intFromEnum(snow_solutes.Species.oxygen)] = 4;
    primary[@intFromEnum(snow_solutes.Species.dinitrogen_nitrogen)] = 5;
    direct[0].soil_nonband_g[@intFromEnum(snow_solutes.Species.ammonium_nitrogen)] = 6;
    primary[@intFromEnum(snow_solutes.Species.hydrogen_phosphate_phosphorus)] = 7;
    primary[@intFromEnum(snow_solutes.Species.aluminum)] = 27;
    primary[@intFromEnum(snow_solutes.Species.sulfate_sulfur)] = 32;
    salts[@intFromEnum(snow_solutes.SaltSpecies.calcium_sulfate)] = 2;
    direct[0].litter_salt_mol[@intFromEnum(snow_solutes.SaltSpecies.carbonate)] = 3;
    const activity = try atmosphericSoluteActivity(0, 1, &primary, &salts, &direct, .{
        .aluminum = 27,
        .iron = 56,
        .calcium = 40,
        .magnesium = 24,
        .sodium = 23,
        .potassium = 39,
        .sulfur = 32,
        .chloride = 35.5,
    });
    try std.testing.expectEqual(@as(f64, 39), activity.carbon_input_g);
    try std.testing.expectEqual(@as(f64, 4), activity.oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 11), activity.nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 7), activity.phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 1), activity.aluminum_input_mol);
    try std.testing.expectEqual(@as(f64, 2), activity.calcium_input_mol);
    try std.testing.expectEqual(@as(f64, 3), activity.sulfur_input_mol);
}

test "invalid late cell activity leaves inputs untouched" {
    const before = [_]inventory.Storage{ .{}, .{} };
    const after = before;
    const activity = [_]BoundaryActivity{ .{}, .{ .nitrogen_output_g = std.math.nan(f64) } };
    const before_copy = before;
    const after_copy = after;
    try std.testing.expectError(error.InvalidHourlyCellBoundaryActivity, evaluate(std.testing.allocator, &before, &after, &activity, &.{ 1, 1 }, .{ .absolute_per_area = .{}, .relative = 1e-9 }));
    try std.testing.expectEqualDeep(before_copy, before);
    try std.testing.expectEqualDeep(after_copy, after);
}

test "hourly cell boundary ledger splits signed heat and rejects late overflow atomically" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    try ledger.accumulateSignedHeat(&.{ 3, -4 });
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[0].heat_input_megajoules);
    try std.testing.expectEqual(@as(f64, 4), ledger.cells[1].heat_output_megajoules);
    ledger.cells[1].heat_input_megajoules = std.math.floatMax(f64);
    const staged = [_]BoundaryActivity{ ledger.cells[0], ledger.cells[1] };
    try std.testing.expectError(error.HourlyCellBoundaryOverflow, ledger.accumulateSignedHeat(&.{ 1, std.math.floatMax(f64) }));
    try std.testing.expectEqualSlices(BoundaryActivity, &staged, ledger.cells);
}

test "hourly cell ledger separates signed internal heat and rejects late overflow atomically" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    try ledger.accumulateSignedInternalHeat(&.{ 3, -4 });
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[0].heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 4), ledger.cells[1].heat_internal_consumption_megajoules);
    ledger.cells[1].heat_internal_production_megajoules = std.math.floatMax(f64);
    const staged = [_]BoundaryActivity{ ledger.cells[0], ledger.cells[1] };
    try std.testing.expectError(error.HourlyCellBoundaryOverflow, ledger.accumulateSignedInternalHeat(&.{ 1, std.math.floatMax(f64) }));
    try std.testing.expectEqualSlices(BoundaryActivity, &staged, ledger.cells);
}

test "hourly cell heat closure includes gross internal production and consumption" {
    const before = [_]inventory.Storage{.{ .heat_megajoules = 100 }};
    const after = [_]inventory.Storage{.{ .heat_megajoules = 107 }};
    const activity = [_]BoundaryActivity{.{
        .heat_internal_production_megajoules = 10,
        .heat_internal_consumption_megajoules = 3,
    }};
    var report = try evaluate(std.testing.allocator, &before, &after, &activity, &.{1}, .{ .absolute_per_area = .{}, .relative = 1e-9 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.failing_cell_count[@intFromEnum(Quantity.heat)]);
}

test "the cell heat scale excludes inter-layer transfers, so per-layer criteria at the same tolerance permit 42x what this gate allows" {
    // Regression pin for
    // HOUR-346-ROOT-CAUSE-TWO-RELATIVE-CRITERIA-AT-THE-SAME-1e-9-WITH-INCOMMENSURATE-SCALES-007.
    // The deck stops at hour 346 on this gate, and the cause is not a
    // tolerance VALUE: `stages/hourly_heat_water_solute.zig` hands the soil
    // heat solver this very same `mass_balance_relative_tolerance`. The two
    // criteria disagree because they normalize by different quantities, and
    // this test pins both sides of that so neither can drift silently.
    //
    // Every literal below is measured, from evidence roots
    // 20260912T123210524Z and 20260912T145032039Z, which agreed on every
    // printed digit.
    const before = [_]inventory.Storage{.{ .heat_megajoules = 1.9158856345604552e3 }};
    const after = [_]inventory.Storage{.{ .heat_megajoules = 1.9158732113903588e3 }};
    const activity = [_]BoundaryActivity{.{
        .heat_input_megajoules = 1.6295372293859771e-3,
        .heat_output_megajoules = 1.3384866225918932e-2,
        .heat_internal_production_megajoules = 1.8913404033305086e-11,
        .heat_internal_consumption_megajoules = 6.678411775627429e-4,
    }};
    var report = try evaluate(
        std.testing.allocator,
        &before,
        &after,
        &activity,
        &.{1},
        .{ .absolute_per_area = .{}, .relative = 1.0e-9 },
    );
    defer report.deinit(std.testing.allocator);
    const heat = report.cells[0].closure[@intFromEnum(Quantity.heat)];

    // The hour really is rejected, at the measured residual.
    try std.testing.expect(!heat.accepted);
    try std.testing.expectApproxEqRel(@as(f64, 5.885586289167133e-11), heat.residual, 1e-12);

    // This gate's scale is the cell's OWN booked activity: the four terms
    // above and nothing else. Heat moving between two soil layers of this
    // cell is internal to it and never reaches this ledger, so it cannot
    // enlarge the scale no matter how large it is.
    const cell_activity_scale = activity[0].heat_input_megajoules +
        activity[0].heat_output_megajoules +
        activity[0].heat_internal_production_megajoules +
        activity[0].heat_internal_consumption_megajoules;
    try std.testing.expectApproxEqRel(cell_activity_scale, heat.normalization_scale, 1e-15);
    try std.testing.expectApproxEqRel(
        @as(f64, 1.0e-9) * cell_activity_scale,
        heat.acceptance_limit,
        1e-15,
    );

    // The solver's side. Gross hourly enthalpy traffic per soil layer, as
    // printed by `ecosys_ng.zig`'s per-scope term line. Layers 9-11 are the
    // three 0.500 m layers; two of them are extrapolated rather than
    // described, and they dominate this sum because 2.84173e-1 MJ crosses the
    // layer 10 | 11 face alone.
    const layer_gross_activity_megajoules = [_]f64{
        5.321273599232512e-4,  6.668163147871553e-4,
        1.9944518022967372e-3, 2.0500501981643993e-3,
        2.1341000504762064e-3, 2.1768545639702097e-3,
        3.215566934429148e-3,  9.648113010570114e-3,
        2.6142936730849442e-2, 7.238634548394884e-2,
        2.652632621069415e-1,  2.850795894060525e-1,
    };
    var summed_layer_activity_megajoules: f64 = 0;
    for (layer_gross_activity_megajoules) |value|
        summed_layer_activity_megajoules += @abs(value);
    const collective_layer_allowance = 1.0e-9 * summed_layer_activity_megajoules;

    // Same tolerance constant, 42.8x the allowance. If this ratio ever drops
    // to ~1 the incommensurability is gone and this test should be rewritten,
    // not deleted.
    const ratio = collective_layer_allowance / heat.acceptance_limit;
    try std.testing.expect(ratio > 40);
    try std.testing.expect(ratio < 46);

    // And the consequence that actually stops the deck: the accumulated
    // per-layer defect clears every layer's own gate while failing this one.
    // Summed from the same per-scope line; 0.5% off `heat.residual` by float
    // reassociation across terms spanning 1e-16 to 2.7e-10.
    const summed_layer_defect_megajoules = 5.916829955148170e-11;
    try std.testing.expect(summed_layer_defect_megajoules < collective_layer_allowance);
    try std.testing.expect(summed_layer_defect_megajoules > heat.effective_acceptance_limit);
    try std.testing.expectApproxEqRel(heat.residual, summed_layer_defect_megajoules, 1e-2);

    // The excess is NOT representation error, which is why no arithmetic
    // allowance covers it and why loosening this criterion would mask it.
    try std.testing.expect(heat.residual > heat.arithmetic_roundoff_allowance);
}

test "multi-cell producer publication rejects a late cell atomically" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    ledger.cells[1].carbon_output_g = std.math.floatMax(f64);
    const before = ledger.cells[0..2].*;
    try std.testing.expectError(
        error.HourlyCellBoundaryOverflow,
        ledger.accumulateCells(&.{
            .{ .carbon_input_g = 3 },
            .{ .carbon_output_g = std.math.floatMax(f64) },
        }),
    );
    try std.testing.expectEqualDeep(before, ledger.cells[0..2].*);
}

test "intercell transfer books exact donor debit and recipient credit for every quantity" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    const transfer: IntercellTransfer = .{
        .water_m3 = 1,
        .heat_megajoules = 2,
        .oxygen_g = 3,
        .hydrogen_g = 4,
        .carbon_g = 5,
        .nitrogen_g = 6,
        .phosphorus_g = 7,
        .aluminum_mol = 8,
        .iron_mol = 9,
        .calcium_mol = 10,
        .magnesium_mol = 11,
        .sodium_mol = 12,
        .potassium_mol = 13,
        .sulfur_mol = 14,
        .chloride_mol = 15,
        .silicon_mol = 16,
    };
    try ledger.accumulateIntercell(0, 1, transfer);
    try std.testing.expectEqualDeep(transferBoundary(transfer, .output), ledger.cells[0]);
    try std.testing.expectEqualDeep(transferBoundary(transfer, .input), ledger.cells[1]);
}

test "intercell transfer rejects a late recipient overflow atomically" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    ledger.cells[1].water_input_m3 = std.math.floatMax(f64);
    const staged = [_]BoundaryActivity{ ledger.cells[0], ledger.cells[1] };
    try std.testing.expectError(
        error.HourlyCellBoundaryOverflow,
        ledger.accumulateIntercell(0, 1, .{ .water_m3 = std.math.floatMax(f64) }),
    );
    try std.testing.expectEqualSlices(BoundaryActivity, &staged, ledger.cells);
}

test "horizontal soil faces book opposing water and heat while vertical faces remain internal" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    var direction = [_]u2{ 0, 2 };
    var micro_faces = [_]soil_solute_transport.Face{
        .{ .first_cell = 0, .second_cell = 2, .water_flux_m3_per_step = 0.1 },
        .{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 99 },
    };
    var macro_faces = micro_faces;
    var micro = [_]f64{ 0.1, 99 };
    var macro = [_]f64{ 0.2, 99 };
    var vapor = [_]f64{ -0.05, 99 };
    var heat = [_]f64{ -3, 99 };
    var slot_sources = [_]usize{ 0, 0 };
    var slot_destinations = [_]usize{ 2, 1 };
    var active_faces = [_]bool{ true, true };
    var active_layers = [_]bool{ true, true, true, true };
    const faces: transport_hydrology.SoilFaces = .{
        .allocator = std.testing.allocator,
        .direction_axis = &direction,
        .slot_source_cell = &slot_sources,
        .slot_default_destination_cell = &slot_destinations,
        .active_by_face = &active_faces,
        .active_by_layer = &active_layers,
        .micropore_faces = &micro_faces,
        .macropore_faces = &macro_faces,
        .micropore_water_flux_m3_per_step = &micro,
        .macropore_water_flux_m3_per_step = &macro,
        .vapor_flux_m3_per_step = &vapor,
        .heat_flux_megajoules_per_step = &heat,
    };
    try accumulateSoilFaceTransfers(&ledger, &faces, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), ledger.cells[0].water_output_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), ledger.cells[1].water_input_m3, 1e-15);
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[1].heat_output_megajoules);
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[0].heat_input_megajoules);
    @memset(ledger.cells, .{});
    active_faces[0] = false;
    try accumulateSoilFaceTransfers(&ledger, &faces, 2);
    try std.testing.expectEqual(BoundaryActivity{}, ledger.cells[0]);
    try std.testing.expectEqual(BoundaryActivity{}, ledger.cells[1]);
}

test "aqueous face transfers preserve formula stoichiometry and independent directions" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    var direction = [_]u2{0};
    var micro_faces = [_]soil_solute_transport.Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = 0 }};
    var macro_faces = micro_faces;
    var zero = [_]f64{0};
    var slot_sources = [_]usize{0};
    var slot_destinations = [_]usize{1};
    var active_faces = [_]bool{true};
    var active_layers = [_]bool{ true, true };
    const faces: transport_hydrology.SoilFaces = .{
        .allocator = std.testing.allocator,
        .direction_axis = &direction,
        .slot_source_cell = &slot_sources,
        .slot_default_destination_cell = &slot_destinations,
        .active_by_face = &active_faces,
        .active_by_layer = &active_layers,
        .micropore_faces = &micro_faces,
        .macropore_faces = &macro_faces,
        .micropore_water_flux_m3_per_step = &zero,
        .macropore_water_flux_m3_per_step = &zero,
        .vapor_flux_m3_per_step = &zero,
        .heat_flux_megajoules_per_step = &zero,
    };
    var micro = [_]f64{0} ** solute_species.AqueousSpecies.count;
    var macro = [_]f64{0} ** solute_species.AqueousSpecies.count;
    micro[@intFromEnum(solute_species.AqueousSpecies.calcium_carbonate)] = 2;
    macro[@intFromEnum(solute_species.AqueousSpecies.sulfate)] = -3;
    try accumulateAqueousFaceTransfers(&ledger, &faces, &micro, &macro, 1, 12, 31);
    try std.testing.expectEqual(@as(f64, 24), ledger.cells[0].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 24), ledger.cells[1].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 2), ledger.cells[0].calcium_output_mol);
    try std.testing.expectEqual(@as(f64, 2), ledger.cells[1].calcium_input_mol);
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[1].sulfur_output_mol);
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[0].sulfur_input_mol);
}

test "gas face transfers preserve tracked-element species and skip vertical faces" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    var state = try gas_transport_step.State.init(std.testing.allocator, 4);
    defer state.deinit();
    state.accepted_faces = try std.testing.allocator.realloc(state.accepted_faces, 2);
    state.accepted_face_flux_g_per_h = try std.testing.allocator.realloc(
        state.accepted_face_flux_g_per_h,
        2 * gas_transport.species_count,
    );
    state.accepted_faces[0] = .{ .first_cell = 0, .second_cell = 2 };
    state.accepted_faces[1] = .{ .first_cell = 0, .second_cell = 1 };
    @memset(state.accepted_face_flux_g_per_h, 0);
    state.accepted_face_flux_g_per_h[@intFromEnum(gas_transport.Species.carbon_dioxide)] = 5;
    state.accepted_face_flux_g_per_h[@intFromEnum(gas_transport.Species.methane)] = -2;
    state.accepted_face_flux_g_per_h[@intFromEnum(gas_transport.Species.oxygen)] = -7;
    state.accepted_face_flux_g_per_h[gas_transport.species_count + @intFromEnum(gas_transport.Species.hydrogen)] = 99;
    try accumulateGasFaceTransfers(&ledger, &state, 2);
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[0].carbon_output_g);
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[1].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 7), ledger.cells[1].oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 7), ledger.cells[0].oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 0), ledger.cells[0].hydrogen_output_g);
}

test "nonzero microbial and fire oxygen sinks remain cell local and publish atomically" {
    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();

    // Two layers of capacity and two process units per layer. Cell 0 has only
    // one active layer, so its inactive-capacity values must not be booked.
    const soil_uptake = [_]f64{ 1, 2, 90, 900, 10, 20, 30, 40 };
    try accumulateSoilMicrobialOxygenUptake(
        &ledger,
        &.{ 1, 2 },
        2,
        2,
        &soil_uptake,
    );
    try std.testing.expectEqual(@as(f64, 3), ledger.cells[0].oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 100), ledger.cells[1].oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 0), ledger.cells[0].oxygen_output_g);

    try accumulateSurfaceMicrobialAndFireOxygenUptake(
        &ledger,
        2,
        &.{ 0.5, 1.5, 5, 15 },
        &.{ 2, 20 },
    );
    try std.testing.expectEqual(@as(f64, 7), ledger.cells[0].oxygen_internal_consumption_g);
    try std.testing.expectEqual(@as(f64, 140), ledger.cells[1].oxygen_internal_consumption_g);

    const soil_fire = [_]f64{ 7, 700, 70, 80 };
    try std.testing.expectEqual(
        @as(f64, 7),
        try soilFireOxygenConsumptionForCell(&soil_fire, 0, 1, 2),
    );
    try std.testing.expectEqual(
        @as(f64, 150),
        try soilFireOxygenConsumptionForCell(&soil_fire, 1, 2, 2),
    );

    const before = [_]BoundaryActivity{ ledger.cells[0], ledger.cells[1] };
    try std.testing.expectError(
        error.InvalidHourlyCellBoundaryActivity,
        accumulateSurfaceMicrobialAndFireOxygenUptake(
            &ledger,
            1,
            &.{ 1, 2 },
            &.{ 3, std.math.nan(f64) },
        ),
    );
    try std.testing.expectEqualSlices(BoundaryActivity, &before, ledger.cells);
}

test "root soil and aqueous oxygen uptake closes per cell across root domains" {
    var soil = try root_soil_gas_state_update.State.init(
        std.testing.allocator,
        2,
        1,
        2,
        2,
    );
    defer soil.deinit();
    var root = try root_internal_gas_state_update.State.init(
        std.testing.allocator,
        2,
        1,
        2,
        2,
    );
    defer root.deinit();
    const passive_exchange = [_]f64{0} ** (8 * 6);
    try root_soil_gas_state_update.refresh(&soil, .{
        .active_soil_layer_count_by_cell = &.{ 2, 1 },
        .active_by_plant = &.{ true, true },
        .root_domain_count_by_plant = &.{ 2, 2 },
        .soil_to_root_exchange_g_per_h_by_root_and_transport_gas = &passive_exchange,
        // Root order is plant, domain, layer. Inactive cell-1 layer values
        // are deliberately nonzero and must not enter either cell ledger.
        .oxygen_uptake_from_soil_g_o_per_h_by_root = &.{ 1, 2, 3, 4, 10, 20, 30, 40 },
    });
    const carbon_dioxide_reaction = [_]f64{0} ** 8;
    try root_internal_gas_state_update.refresh(&root, .{
        .active_soil_layer_count_by_cell = &.{ 2, 1 },
        .active_by_plant = &.{ true, true },
        .root_domain_count_by_plant = &.{ 2, 2 },
        .aqueous_carbon_dioxide_reaction_g_c_per_h_by_root = &carbon_dioxide_reaction,
        .oxygen_uptake_from_root_pool_g_o_per_h_by_root = &.{ 0.1, 0.2, 0.3, 0.4, 1, 2, 3, 4 },
    });

    var ledger = try BoundaryLedger.init(std.testing.allocator, 2);
    defer ledger.deinit();
    try accumulateRootOxygenUptake(
        &ledger,
        &.{ 2, 1 },
        2,
        soil.exchange_g_per_h_by_gas_and_layer[1],
        root.oxygen_uptake_g_o_per_h_by_layer,
    );
    // Cell 0: (1+3)+(2+4) soil + (0.1+0.3)+(0.2+0.4) root = 11.
    // Cell 1: (10+30) soil + (1+3) root = 44.
    try std.testing.expectApproxEqAbs(@as(f64, 11), ledger.cells[0].oxygen_internal_consumption_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 44), ledger.cells[1].oxygen_internal_consumption_g, 1e-15);

    const zero = [_]f64{0} ** 4;
    try accumulateRootOxygenUptake(&ledger, &.{ 2, 1 }, 2, &zero, &zero);
    try std.testing.expectApproxEqAbs(@as(f64, 11), ledger.cells[0].oxygen_internal_consumption_g, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 44), ledger.cells[1].oxygen_internal_consumption_g, 1e-15);

    const before = [_]BoundaryActivity{ ledger.cells[0], ledger.cells[1] };
    try std.testing.expectError(
        error.InvalidHourlyCellBoundaryActivity,
        accumulateRootOxygenUptake(
            &ledger,
            &.{ 2, 1 },
            2,
            &.{ 1, 2, std.math.nan(f64), 4 },
            &.{ 1, 2, 3, 4 },
        ),
    );
    try std.testing.expectEqualSlices(BoundaryActivity, &before, ledger.cells);
    try std.testing.expectError(
        error.HourlyCellBoundaryDimensionMismatch,
        accumulateRootOxygenUptake(&ledger, &.{ 2, 1 }, 2, &.{ 1, 2 }, &.{ 1, 2 }),
    );
    try std.testing.expectEqualSlices(BoundaryActivity, &before, ledger.cells);
}

test "production books microbial root and fire oxygen sinks before hourly acceptance" {
    const source = try readRepositorySource("src/ecosys_ng.zig");
    defer std.testing.allocator.free(source);
    const post_start = std.mem.indexOf(u8, source, "noinline fn postScienceAccounting(") orelse return error.MissingPostSciencePhase;
    const management_start = std.mem.indexOfPos(u8, source, post_start, "noinline fn postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingPhase;
    const canopy_wrapper_start = std.mem.indexOfPos(u8, source, management_start, "noinline fn postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapper;
    const canopy_start = std.mem.indexOfPos(u8, source, canopy_wrapper_start, "noinline fn postScienceCanopyAndEnergy(") orelse return error.MissingCanopyEnergyPhase;
    const fire_start = std.mem.indexOfPos(u8, source, canopy_start, "noinline fn postScienceFireAndCloseout(") orelse return error.MissingFireCloseoutPhase;
    const accept_start = std.mem.indexOfPos(u8, source, fire_start, "noinline fn acceptHourAndPublish(") orelse return error.MissingAcceptHourPhase;
    const prepare_start = std.mem.indexOfPos(u8, source, accept_start, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(u8, source, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(u8, source, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const post_phase = source[post_start..management_start];
    const management_phase = source[management_start..canopy_wrapper_start];
    const canopy_wrapper = source[canopy_wrapper_start..canopy_start];
    const canopy_phase = source[canopy_start..fire_start];
    const fire_phase = source[fire_start..accept_start];
    const accept_phase = source[accept_start..prepare_start];
    const advance_phase = source[advance_start..timeline_start];
    const management_call = std.mem.indexOf(u8, post_phase, "try postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingCall;
    const canopy_wrapper_call = std.mem.indexOfPos(u8, post_phase, management_call, "try postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapperCall;
    const canopy_call = std.mem.indexOf(u8, canopy_wrapper, "try postScienceCanopyAndEnergy(") orelse return error.MissingCanopyEnergyCall;
    const fire_call = std.mem.indexOfPos(u8, canopy_wrapper, canopy_call, "try postScienceFireAndCloseout(") orelse return error.MissingFireCloseoutCall;
    const transaction_begin = std.mem.indexOf(
        u8,
        advance_phase,
        "driver_context.outer_hour_transaction_workspace.*.begin(",
    ) orelse return error.MissingOuterHourTransaction;
    const stable_capture = std.mem.indexOfPos(
        u8,
        advance_phase,
        transaction_begin,
        "captureStable(&driver_context.hourly_science_context.*",
    ) orelse return error.MissingHourlyScienceRollbackCapture;
    const post_call = std.mem.indexOfPos(u8, advance_phase, stable_capture, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceCall;
    const accept_call = std.mem.indexOfPos(u8, advance_phase, post_call, "try acceptHourAndPublish(driver_context,") orelse return error.MissingAcceptHourCall;
    const landscape_soil = std.mem.indexOf(
        u8,
        management_phase,
        ".accumulateAcceptedSoilMicrobialOxygenUptake(",
    ) orelse return error.MissingLandscapeSoilMicrobialOxygenBooking;
    const cell_soil = std.mem.indexOfPos(
        u8,
        management_phase,
        landscape_soil,
        "hourly_cell_conservation.accumulateSoilMicrobialOxygenUptake(",
    ) orelse return error.MissingCellSoilMicrobialOxygenBooking;
    const root_aggregate = std.mem.indexOf(
        u8,
        canopy_phase,
        "driver_context.root_uptake_ledger_state.*.soil_oxygen_uptake_g_o_per_h,",
    ) orelse return error.MissingRootOxygenAggregate;
    const landscape_root = std.mem.indexOfPos(
        u8,
        canopy_phase,
        root_aggregate,
        ".accumulateAcceptedRootOxygenUptake(",
    ) orelse return error.MissingLandscapeRootOxygenBooking;
    const cell_root = std.mem.indexOfPos(
        u8,
        canopy_phase,
        landscape_root,
        "hourly_cell_conservation.accumulateRootOxygenUptake(",
    ) orelse return error.MissingCellRootOxygenBooking;
    const surface_finalize = std.mem.indexOf(
        u8,
        fire_phase,
        "driver_context.surface_fire_exchange_state.*.finalizeSurfaceCell(",
    ) orelse return error.MissingSurfaceFireFinalize;
    const cell_surface = std.mem.indexOfPos(
        u8,
        fire_phase,
        surface_finalize,
        "hourly_cell_conservation.accumulateSurfaceMicrobialAndFireOxygenUptake(",
    ) orelse return error.MissingCellSurfaceOxygenBooking;
    const surface_redist = std.mem.indexOfPos(
        u8,
        fire_phase,
        cell_surface,
        "redist_surface_gas_flux_accounting.computeOxygenHydrogen(",
    ) orelse return error.MissingSurfaceOxygenRedist;
    const soil_fire_finalize = std.mem.indexOf(
        u8,
        fire_phase,
        "driver_context.organic_matter_fire_exchange_state.*.finalizeLayer(",
    ) orelse return error.MissingSoilFireFinalize;
    const cell_soil_fire = std.mem.indexOfPos(
        u8,
        fire_phase,
        soil_fire_finalize,
        "hourly_cell_conservation.soilFireOxygenConsumptionForCell(",
    ) orelse return error.MissingCellSoilFireOxygenBooking;
    const landscape_surface_and_fire = std.mem.indexOfPos(
        u8,
        fire_phase,
        cell_soil_fire,
        ".accumulateAcceptedSurfaceMicrobialAndFireOxygenUptake(",
    ) orelse return error.MissingLandscapeSurfaceAndFireOxygenBooking;
    const acceptance = std.mem.indexOfPos(
        u8,
        accept_phase,
        0,
        "hourly_cell_conservation.requireAccepted(",
    ) orelse return error.MissingHourlyCellAcceptance;
    const transaction_commit = std.mem.indexOfPos(
        u8,
        accept_phase,
        acceptance,
        "outer_hour_transaction.*.commit();",
    ) orelse return error.MissingOuterHourCommit;
    try std.testing.expect(landscape_soil < cell_soil);
    try std.testing.expect(root_aggregate < landscape_root);
    try std.testing.expect(landscape_root < cell_root);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, ".accumulateAcceptedRootOxygenUptake("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "hourly_cell_conservation.accumulateRootOxygenUptake("),
    );
    try std.testing.expect(surface_finalize < cell_surface);
    try std.testing.expect(cell_surface < surface_redist);
    try std.testing.expect(soil_fire_finalize < cell_soil_fire);
    try std.testing.expect(cell_soil_fire < landscape_surface_and_fire);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            source,
            ".accumulateAcceptedSurfaceMicrobialAndFireOxygenUptake(",
        ),
    );
    try std.testing.expect(transaction_begin < stable_capture);
    try std.testing.expect(stable_capture < post_call);
    try std.testing.expect(post_call < accept_call);
    try std.testing.expect(management_call < canopy_wrapper_call);
    try std.testing.expect(canopy_call < fire_call);
    try std.testing.expect(acceptance < transaction_commit);
}

test "production does not reinstate mid-hour ad hoc C N P closure verdicts" {
    const source = try readRepositorySource("src/ecosys_ng.zig");
    defer std.testing.allocator.free(source);

    // Current storage and the landscape ledger are deliberately published at
    // different phases. The accepted per-cell report is the sole hourly
    // conservation verdict; these old resummations mixed those phases and, for
    // N and P, omitted plant storage.
    const forbidden = [_][]const u8{
        "hourly carbon closure",
        "hourly nitrogen closure",
        "hourly phosphorus closure",
        "diagnostic_storage_g_n",
        "diagnostic_storage_g_p",
        "carbon_balance_g - driver_context.landscape_mass_balance_state",
    };
    for (forbidden) |token| {
        try std.testing.expect(std.mem.indexOf(u8, source, token) == null);
    }
}

test "production root ledgers use serial runtime loops instead of forced unrolling" {
    const source = try readRepositorySource("src/ecosys_ng.zig");
    defer std.testing.allocator.free(source);

    const start = std.mem.indexOf(u8, source, "noinline fn postScienceRootLedgers(") orelse
        return error.MissingPostScienceRootLedgers;
    const end = std.mem.indexOfPos(u8, source, start, "noinline fn postScienceFireAndCloseout(") orelse
        return error.MissingPostScienceFireAndCloseout;
    const body = source[start..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "inline for") == null);
}

test "failed closure acceptance is diagnostic-only and leaves storage and ledger unchanged" {
    const before = [_]inventory.Storage{.{ .water_m3 = 1 }};
    const after = [_]inventory.Storage{.{ .water_m3 = 2 }};
    const activity = [_]BoundaryActivity{.{}};
    const before_copy = before;
    const after_copy = after;
    const activity_copy = activity;
    var report = try evaluate(std.testing.allocator, &before, &after, &activity, &.{1}, .{
        .absolute_per_area = .{ .water_m = 1e-12 },
        .relative = 1e-9,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectError(error.HourlyCellConservationFailure, requireAccepted(report));
    try std.testing.expectEqualDeep(before_copy, before);
    try std.testing.expectEqualDeep(after_copy, after);
    try std.testing.expectEqualDeep(activity_copy, activity);
}

test "signed charcoal exchange-site changes close as internal production and consumption" {
    const before = [_]inventory.Storage{.{
        .cation_exchange_capacity_mol = 10,
        .anion_exchange_capacity_mol = 5,
    }};
    const after = [_]inventory.Storage{.{
        .cation_exchange_capacity_mol = 12,
        .anion_exchange_capacity_mol = 4,
    }};
    const activity = [_]BoundaryActivity{.{
        .cation_exchange_capacity_internal_production_mol = 2,
        .anion_exchange_capacity_internal_consumption_mol = 1,
    }};
    var report = try evaluate(std.testing.allocator, &before, &after, &activity, &.{1}, .{
        .absolute_per_area = .{ .exchange_capacity_mol_m2 = 1e-12 },
        .relative = 1e-9,
    });
    defer report.deinit(std.testing.allocator);
    try requireAccepted(report);
    try std.testing.expectEqual(
        @as(f64, 0),
        report.cells[0].closure[@intFromEnum(Quantity.cation_exchange_capacity)].residual,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        report.cells[0].closure[@intFromEnum(Quantity.anion_exchange_capacity)].residual,
    );
}

test "the conservation criterion's VALUE is pinned, not just gross-leak rejection" {
    // Measured 2026-09-12: loosening `default_mass_balance_relative_tolerance`
    // from 1.0e-9 to 1.0e-4 -- five orders -- broke ZERO of 4,214 tests. The
    // suite had rejection tests, but every one used a unit-magnitude leak
    // (water 1 m3, aluminum 1 mol) against a 1e-12 floor, and a leak of 1.0
    // fails at 1e-4 exactly as it fails at 1e-9. Two of the three also
    // hardcoded `.relative = 1e-9` as a literal rather than reading the
    // default, so they were blind to a default change by construction.
    //
    // So "a gross leak is rejected" was pinned and the CRITERION'S VALUE was
    // not. That made any change to it unmeasurable, which is the same defect
    // class as a tolerance widened to pass -- there was nothing to widen
    // against. This test closes that: it fails if the default moves in either
    // direction.
    const core_config = @import("../core/config.zig");

    // 1. The constant itself. One part per billion of accepted boundary
    //    activity, per its own doc comment.
    try std.testing.expectEqual(
        @as(f64, 1.0e-9),
        core_config.default_mass_balance_relative_tolerance,
    );

    // 2. Storage is deliberately 1000x the activity so the normalization scale
    //    is observable. Residual is `(after - before) - (inputs - outputs)`,
    //    so with before=1000, inputs=1, outputs=0 and after=1001+leak the
    //    residual is exactly `leak`.
    const activity_m3: f64 = 1;
    const storage_m3: f64 = 1000;
    const tolerances: Tolerances = .{
        // Zero absolute floor isolates the relative term, and is what P3
        // describes production as using: "gated at 1e-9 x interval_activity
        // with ZERO absolute floor".
        .absolute_per_area = .{},
        .relative = core_config.default_mass_balance_relative_tolerance,
    };

    // 3. A leak ten times the criterion must be REJECTED. At a 1e-4 default
    //    this leak is 1e-8 against a 1e-4 limit and would be accepted, so this
    //    assertion is what makes a loosening visible.
    {
        const leak_m3: f64 = 10 * core_config.default_mass_balance_relative_tolerance * activity_m3;
        const before = [_]inventory.Storage{.{ .water_m3 = storage_m3 }};
        const after = [_]inventory.Storage{.{ .water_m3 = storage_m3 + activity_m3 + leak_m3 }};
        var report = try evaluate(
            std.testing.allocator,
            &before,
            &after,
            &.{.{ .water_input_m3 = activity_m3 }},
            &.{1},
            tolerances,
        );
        defer report.deinit(std.testing.allocator);
        try std.testing.expectError(error.HourlyCellConservationFailure, requireAccepted(report));

        // 4. THE SCALE. normalized_relative must divide by ACTIVITY, not by
        //    storage. This is not a stylistic preference: at 1e-4 against the
        //    1915.9 MJ storage of the real failing cell the per-hour allowance
        //    is 0.19 MJ, which over the deck's 262,920 hours accumulates to
        //    50,372 MJ -- 26x that cell's entire storage. Against hourly
        //    activity the same 1e-4 accumulates to 0.41 MJ, 0.022%. If this
        //    assertion ever flips to the storage scale, the criterion silently
        //    becomes four orders more permissive than it reads.
        const index = @intFromEnum(Quantity.water);
        const observed = report.maximum_normalized_relative[index];
        // Bound derived, not tuned. The leak is recovered as a difference of
        // numbers of magnitude `storage + activity`, so its relative accuracy
        // is limited to about `eps * (storage + activity) / leak` =
        // 2.22e-16 * 1001 / 1e-8 = 2.2e-5. Demanding 1e-9 here failed at
        // 7.8e-7, which is inside that bound and is representation, not a
        // defect. Making storage 1000x the activity is what exposes the scale,
        // and this is the price of that.
        const representation_bound =
            std.math.floatEps(f64) * (storage_m3 + activity_m3) / leak_m3;
        try std.testing.expect(representation_bound < 1e-4);
        try std.testing.expectApproxEqRel(leak_m3 / activity_m3, observed, 1e-4);
        // Explicitly NOT the storage normalization, which would be 1000x smaller.
        try std.testing.expect(observed > 100 * (leak_m3 / storage_m3));
    }

    // 5. A leak a tenth of the criterion must be ACCEPTED, so the test pins the
    //    criterion from BELOW too and cannot be satisfied by a check that
    //    rejects everything.
    {
        const leak_m3: f64 = 0.1 * core_config.default_mass_balance_relative_tolerance * activity_m3;
        const before = [_]inventory.Storage{.{ .water_m3 = storage_m3 }};
        const after = [_]inventory.Storage{.{ .water_m3 = storage_m3 + activity_m3 + leak_m3 }};
        var report = try evaluate(
            std.testing.allocator,
            &before,
            &after,
            &.{.{ .water_input_m3 = activity_m3 }},
            &.{1},
            tolerances,
        );
        defer report.deinit(std.testing.allocator);
        try requireAccepted(report);
    }
}

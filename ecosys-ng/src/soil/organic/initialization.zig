const std = @import("std");
const GridState = @import("../../state/grid.zig").GridState;
const SoilCatalogEntry = @import("../profile/catalog.zig").Entry;
const SoilProperties = @import("../water/solver_properties.zig").State;

pub const substrate_count: usize = 5;
pub const kinetic_fraction_count: usize = 3;
// Legacy OSC/OSA index M=1..5. The fifth fraction is fire-derived charcoal;
// ordinary litter inputs initialize it to zero, but it must remain represented.
pub const structural_fraction_count: usize = 5;
pub const residue_fraction_count: usize = 2;
pub const microbial_population_count: usize = 7;
pub const autotrophic_substrate_index: usize = 5;
pub const microbial_substrate_count: usize = 6;

pub const ElementPool = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

pub const ProfileOrganicComplexMasses = struct {
    particulate_carbon_g_c: f64,
    humus_carbon_g_c: f64,
    particulate_nitrogen_g_n: f64,
    humus_nitrogen_g_n: f64,
    particulate_phosphorus_g_p: f64,
    humus_phosphorus_g_p: f64,
};

/// `starts.f` lines 1297--1304 and 1328--1340: the carrier that organic concentrations are
/// multiplied by is chosen per layer, not fixed.
///
/// ```fortran
///       IF(BKVL(L,NY,NX).GT.ZEROS(NY,NX))THEN
///       OSCI(K)=CORGCX(K)*BKVL(L,NY,NX)
///       ...
///       ELSE
///       OSCI(K)=CORGCX(K)*VOLT(L,NY,NX)
/// ```
///
/// `BKVL` is mineral mass in Mg (`starts.f:579`, `BKDS*VOLX`) and `VOLT` is
/// total layer volume in m3 (`:575`). The `ELSE` branch is the source's explicit
/// statement about a layer with **no mineral matrix**: a ponded layer of open
/// water still carries organic matter, so its concentrations are carried on
/// volume instead of on a mineral mass that does not exist. The same two-branch
/// selection is repeated for the microbial seed `OSCM` at 1328--1340, so both
/// uses of the carrier in this module must move together.
///
/// This is a *carrier substitution*, not a fallback constant and not a floor.
/// The numerical value is a real physical quantity in both branches, which is
/// why the ponded case does not need, and must not be given, a fabricated bulk
/// density. `examples-ng/Meditteranean Pond CA` declares `bulk_density` `0.00`
/// for its upper seven layers, which is the correct physical statement that
/// those layers are open water.
///
/// Units differ between the two branches (Mg against m3), which is deliberate in
/// the source: `CORGCX` is a concentration per carrier unit, and the legacy
/// comment at `starts.f:1281` writes it as `g unit-1` precisely because the unit
/// is carrier-dependent. Callers must therefore treat the result as an extensive
/// mass in g and never re-divide it by a mineral mass.
pub const OrganicCarrier = struct {
    /// The multiplier applied to organic concentrations for this layer.
    amount: f64,
    /// True when `amount` is a mineral mass in Mg, false when it is a layer
    /// volume in m3 because the layer holds no mineral matrix.
    mineral_matrix_present: bool,
};

/// Selects the STARTS organic carrier for one layer. `negligible_mineral_mass_megagrams`
/// is the runtime `ZEROS` analogue: the source compares against `ZEROS(NY,NX)`,
/// an area-scaled floor, not against exact zero.
pub fn selectOrganicCarrier(mineral_mass_megagrams: f64, total_layer_volume_m3: f64, negligible_mineral_mass_megagrams: f64) !OrganicCarrier {
    inline for (.{ mineral_mass_megagrams, total_layer_volume_m3, negligible_mineral_mass_megagrams }) |value| {
        if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitializationParameter;
    }
    if (mineral_mass_megagrams > negligible_mineral_mass_megagrams)
        return .{ .amount = mineral_mass_megagrams, .mineral_matrix_present = true };
    // A layer with no mineral matrix must still have a volume to carry its
    // organic matter. A zero-volume, zero-mass layer carries nothing and cannot
    // be given a meaningful concentration, so it stays an explicit error rather
    // than silently becoming a zero-mass soil layer.
    if (total_layer_volume_m3 <= 0) return error.InvalidOrganicInitializationParameter;
    return .{ .amount = total_layer_volume_m3, .mineral_matrix_present = false };
}

/// `starts.f` lines 807--812: split mineral-soil organic matter into particulate
/// substrate 3 and humus substrate 4. Carbon inputs are kg C Mg-1; N and P
/// inputs are g element Mg-1.
pub fn profileOrganicComplexMasses(total_organic_carbon_kg_per_megagram: f64, particulate_organic_carbon_kg_per_megagram: f64, organic_nitrogen_g_per_megagram: f64, organic_phosphorus_g_per_megagram: f64, soil_mass_megagrams: f64, particulate_nitrogen_to_carbon_g_n_per_g_c: f64, particulate_phosphorus_to_carbon_g_p_per_g_c: f64) !ProfileOrganicComplexMasses {
    inline for (.{ total_organic_carbon_kg_per_megagram, particulate_organic_carbon_kg_per_megagram, organic_nitrogen_g_per_megagram, organic_phosphorus_g_per_megagram, soil_mass_megagrams, particulate_nitrogen_to_carbon_g_n_per_g_c, particulate_phosphorus_to_carbon_g_p_per_g_c }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidProfileOrganicMatter;
    const total_carbon_g_c = total_organic_carbon_kg_per_megagram * 1000.0 * soil_mass_megagrams;
    const particulate_carbon_g_c = particulate_organic_carbon_kg_per_megagram * 1000.0 * soil_mass_megagrams;
    const total_nitrogen_g_n = organic_nitrogen_g_per_megagram * soil_mass_megagrams;
    const total_phosphorus_g_p = organic_phosphorus_g_per_megagram * soil_mass_megagrams;
    const particulate_nitrogen_g_n = @min(particulate_nitrogen_to_carbon_g_n_per_g_c * particulate_carbon_g_c, total_nitrogen_g_n);
    const particulate_phosphorus_g_p = @min(particulate_phosphorus_to_carbon_g_p_per_g_c * particulate_carbon_g_c, total_phosphorus_g_p);
    const result: ProfileOrganicComplexMasses = .{
        .particulate_carbon_g_c = particulate_carbon_g_c,
        .humus_carbon_g_c = @max(0.0, total_carbon_g_c - particulate_carbon_g_c),
        .particulate_nitrogen_g_n = particulate_nitrogen_g_n,
        .humus_nitrogen_g_n = @max(0.0, total_nitrogen_g_n - particulate_nitrogen_g_n),
        .particulate_phosphorus_g_p = particulate_phosphorus_g_p,
        .humus_phosphorus_g_p = @max(0.0, total_phosphorus_g_p - particulate_phosphorus_g_p),
    };
    inline for (@typeInfo(ProfileOrganicComplexMasses).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteProfileOrganicMatter;
    return result;
}

/// All STARTS DATA coefficients are supplied as runtime slices. Array order is
/// substrate-major unless the field name states otherwise.
pub const RuntimeParameters = struct {
    microbial_kinetic_fraction: []const f64, // substrate x 3
    residue_fraction: []const f64, // substrate x 2
    dissolved_fraction: []const f64, // substrate
    adsorbed_fraction: []const f64, // substrate
    heterotroph_population_fraction: []const f64, // 7
    autotroph_population_fraction: []const f64, // 7
    microbial_nitrogen_to_carbon: []const f64, // substrate x population x 3
    microbial_phosphorus_to_carbon: []const f64, // substrate x population x 3
};

pub const LayerInputs = struct {
    initial_complex: []const ElementPool, // 5
    microbial_carbon_g_c: []const f64, // OSCM, 5
    carbon_allocation_fraction: []const f64, // FOSCI, 5
    nitrogen_allocation_fraction: []const f64, // FOSNI, 5
    phosphorus_allocation_fraction: []const f64, // FOSPI, 5
    complex_nitrogen_to_carbon: []const f64, // CNOSCT, 5
    complex_phosphorus_to_carbon: []const f64, // CPOSCT, 5
    structural_fraction: []const f64, // substrate x 4
    structural_nitrogen_to_carbon: []const f64, // substrate x 4
    structural_phosphorus_to_carbon: []const f64, // substrate x 4
};

pub const MineralAllocationDerivationParameters = struct {
    residue_microbial_fraction: f64,
    humus_microbial_half_saturation_g_c_per_megagram: f64,
    depth_partition_factor: f64,
    microbial_budget_fraction: []const f64, // OMCK, 5
    residue_budget_fraction: []const f64, // ORCK, 5
    dissolved_budget_fraction: []const f64, // OQCK, 5
    adsorbed_budget_fraction: []const f64, // OHCK, 5
    microbial_kinetic_fraction: []const f64, // OMCI, substrate x 3
    microbial_nitrogen_to_carbon: []const f64, // substrate x population x 3
    microbial_phosphorus_to_carbon: []const f64, // substrate x population x 3
    residue_nitrogen_to_carbon: []const f64, // CNRH, 5
    residue_phosphorus_to_carbon: []const f64, // CPRH, 5
};

pub const MineralAllocationDerivation = struct {
    microbial_carbon_g_c: [substrate_count]f64,
    carbon_allocation_fraction: [substrate_count]f64,
    nitrogen_allocation_fraction: [substrate_count]f64,
    phosphorus_allocation_fraction: [substrate_count]f64,
};

pub const MappedRuntimeParameters = struct {
    pool_allocation: RuntimeParameters,
    microbial_derivation: MineralAllocationDerivationParameters,
    depth_partition_factor_by_layer: []const f64,
    /// `starts.f` 1032--1046: true where the layer took the wetland arm (FCX
    /// collapses to 1 and FC0's nutrient-protection exponential is disabled).
    /// Empty is treated as "no wetland layers" (every layer took the dryland or
    /// reconstructed arm), which keeps `surface()`'s empty-slice call valid.
    wetland_layer_by_layer: []const bool = &.{},
    default_complex_nitrogen_to_carbon: []const f64, // 5
    default_complex_phosphorus_to_carbon: []const f64, // 5
    residue_structural_fraction: []const f64, // first 3 substrates x 5
    manure_structural_fraction_by_type: []const f64, // ruminant, other: 2 x 5
    particulate_structural_fraction: []const f64, // 5
    less_resistant_humus_fraction_at_surface: f64,
    nutrient_protection_exponent: f64,
    phosphorus_nutrient_weight: f64,
    /// Runtime `ZEROS` analogue for the `starts.f:1297` mineral-mass test
    /// `IF(BKVL(L,NY,NX).GT.ZEROS(NY,NX))`. Mineral mass at or below this is
    /// treated as "no mineral matrix" and the organic carrier becomes the total
    /// layer volume, which is the source's ponded/wetland branch.
    ///
    /// Defaults to `0`, which reproduces the strict `> 0` reading and keeps every
    /// existing caller and every mineral profile bit-identical. It is a separate
    /// runtime control rather than a reuse of the legacy universal solver scalar because
    /// this floor is a *mass* in Mg, and `INIT-006` (A0) is still deciding
    /// whether such floors carry the source's cell-area scaling.
    negligible_mineral_mass_megagrams: f64 = 0,
};

pub const SurfaceRuntimeParameters = struct {
    pool_allocation: RuntimeParameters,
    residue_microbial_fraction: f64,
    default_complex_nitrogen_to_carbon: []const f64, // 5
    default_complex_phosphorus_to_carbon: []const f64, // 5
    woody_structural_fraction: []const f64, // 5
    plant_structural_fraction_by_type: []const f64, // 12 x 5; final row is default
    manure_structural_fraction_by_type: []const f64, // ruminant, other: 2 x 5
    residue_nitrogen_weight: []const f64, // woody/fine/manure x 5
    residue_phosphorus_weight: []const f64, // woody/fine/manure x 5
};

pub const HumusDepthPartitionParameters = struct {
    reference_accumulation_fraction: f64,
    maximum_reference_humus_g_c_per_m2: f64,
    fraction_at_reference_accumulation: f64,
};

fn lessResistantHumusFraction(
    surface_fraction: f64,
    nutrient_protection_exponent: f64,
    nutrient_ratio: f64,
    depth_partition_factor: f64,
    wetland_arm: bool,
) f64 {
    const nutrient_protection = if (wetland_arm)
        1.0
    else
        @exp(-nutrient_protection_exponent * nutrient_ratio);
    return surface_fraction * nutrient_protection * depth_partition_factor;
}

fn manureStructuralFraction(manure_type: i32, by_type: []const f64) []const f64 {
    const type_index: usize = if (manure_type == 1) 0 else 1;
    return by_type[type_index * structural_fraction_count ..][0..structural_fraction_count];
}

/// `starts.f` lines 754--766 and 1023--1028: midpoint cumulative humus and its
/// exponential reduction of the less-resistant and initial microbial pools.
pub fn deriveNaturalDrylandDepthPartition(humus_carbon_g_c: []const f64, horizontal_area_m2: f64, reference_layer: usize, parameters: HumusDepthPartitionParameters, result: []f64) !void {
    if (humus_carbon_g_c.len == 0 or result.len != humus_carbon_g_c.len or reference_layer >= humus_carbon_g_c.len) return error.OrganicInitializationDimensionMismatch;
    inline for (.{ horizontal_area_m2, parameters.reference_accumulation_fraction, parameters.maximum_reference_humus_g_c_per_m2, parameters.fraction_at_reference_accumulation }) |value| if (!std.math.isFinite(value)) return error.InvalidOrganicInitializationParameter;
    if (horizontal_area_m2 <= 0 or parameters.reference_accumulation_fraction < 0 or parameters.maximum_reference_humus_g_c_per_m2 < 0 or parameters.fraction_at_reference_accumulation <= 0 or parameters.fraction_at_reference_accumulation > 1) return error.InvalidOrganicInitializationParameter;
    var cumulative_humus_g_c_per_m2: f64 = 0;
    var reference_midpoint_humus_g_c_per_m2: f64 = 0;
    for (humus_carbon_g_c, 0..) |carbon, layer| {
        if (!std.math.isFinite(carbon) or carbon < 0) return error.InvalidOrganicInitializationParameter;
        const layer_humus_g_c_per_m2 = carbon / horizontal_area_m2;
        const midpoint = cumulative_humus_g_c_per_m2 + 0.5 * layer_humus_g_c_per_m2;
        result[layer] = midpoint;
        if (layer == reference_layer) reference_midpoint_humus_g_c_per_m2 = midpoint;
        cumulative_humus_g_c_per_m2 += layer_humus_g_c_per_m2;
    }
    const reference = @min(parameters.maximum_reference_humus_g_c_per_m2, parameters.reference_accumulation_fraction * reference_midpoint_humus_g_c_per_m2);
    const exponent_per_g_c_per_m2 = if (reference > 0) @log(parameters.fraction_at_reference_accumulation) / reference else 0;
    for (result) |*midpoint| {
        midpoint.* = @exp(exponent_per_g_c_per_m2 * midpoint.*);
        if (!std.math.isFinite(midpoint.*) or midpoint.* < 0 or midpoint.* > 1) return error.NonFiniteOrganicInitialization;
    }
}

/// Maps STARTS natural/reconstructed and dryland/wetland depth branches onto
/// the runtime grid. DTBLZ is reconstructed from landscape-relative elevation.
pub fn deriveMappedDepthPartition(
    allocator: std.mem.Allocator,
    grid: *const GridState,
    properties: *const SoilProperties,
    catalog_entries: []const SoilCatalogEntry,
    catalog_index_by_cell: []const usize,
    horizontal_cell_width_m: []const f64,
    vertical_cell_width_m: []const f64,
    relative_surface_elevation_m: []const f64,
    minimum_surface_elevation_m: f64,
    initial_water_table_depth_m: []const f64,
    natural_water_table_surface_slope: []const f64,
    parameters: HumusDepthPartitionParameters,
    result: []f64,
    wetland_arm: []bool,
) !void {
    if (properties.layer_count != grid.layer_count or result.len != grid.layer_count or
        wetland_arm.len != grid.layer_count or
        catalog_index_by_cell.len != grid.cell_count or
        relative_surface_elevation_m.len != grid.cell_count or
        horizontal_cell_width_m.len != grid.cell_count or
        vertical_cell_width_m.len != grid.cell_count or
        initial_water_table_depth_m.len != grid.cell_count or
        natural_water_table_surface_slope.len != grid.cell_count)
        return error.OrganicInitializationDimensionMismatch;
    if (!std.math.isFinite(minimum_surface_elevation_m)) return error.InvalidOrganicInitializationParameter;
    var maximum_surface_layer_bottom_m: f64 = 0;
    for (catalog_index_by_cell) |catalog_index| {
        if (catalog_index >= catalog_entries.len) return error.SoilCatalogMapOutOfBounds;
        const profile = catalog_entries[catalog_index].profile;
        if (profile.total_layer_count == 0) return error.SoilLayerCountMismatch;
        maximum_surface_layer_bottom_m = @max(maximum_surface_layer_bottom_m, profile.depth_to_layer_bottom_m[0]);
    }
    for (0..grid.cell_count) |cell| {
        const entry = catalog_entries[catalog_index_by_cell[cell]];
        const profile = entry.profile;
        if (profile.total_layer_count != grid.active_soil_layer_count[cell]) return error.SoilLayerCountMismatch;
        const area_m2 = horizontal_cell_width_m[cell] * vertical_cell_width_m[cell];
        const water_table_depth_m = initial_water_table_depth_m[cell];
        const water_table_slope = natural_water_table_surface_slope[cell];
        if (!std.math.isFinite(water_table_depth_m) or !std.math.isFinite(water_table_slope) or
            water_table_slope < 0 or water_table_slope > 1)
            return error.InvalidOrganicInitializationParameter;
        const cell_start = cell * grid.soil_layer_capacity;
        const cell_result = result[cell_start..][0..profile.total_layer_count];
        const cell_wetland_arm = wetland_arm[cell_start..][0..profile.total_layer_count];
        if (profile.reconstructed_profile) {
            // `starts.f` 1050--1058: the reconstructed arm sets FCX=1 but still
            // applies the nutrient-protection exponential to FC0 (its FC0
            // computation is identical to the dryland arm's), unlike the
            // wetland arm below, whose FC0 exponential is source-commented out.
            @memset(cell_result, 1);
            @memset(cell_wetland_arm, false);
            continue;
        }
        const humus = try allocator.alloc(f64, profile.total_layer_count);
        defer allocator.free(humus);
        for (0..profile.total_layer_count) |layer| {
            const layer_cell = try grid.layerIndex(cell, layer);
            // Same STARTS carrier selection as `initializeMappedInPlace`. This
            // is the humus inventory the depth partition is weighted by, so a
            // ponded layer must contribute its volume-carried humus rather than
            // a spurious zero that would shift the partition of every layer
            // below it. `starts.f` 1297--1304.
            const carrier = try selectOrganicCarrier(
                properties.matrix_bulk_volume_m3[layer_cell] * properties.bulk_density_megagrams_per_m3[layer_cell],
                properties.layer_volume_m3[layer_cell],
                0,
            );
            humus[layer] = @max(0.0, entry.material.total_organic_carbon_g_per_megagram[layer] - entry.material.particulate_organic_carbon_g_per_megagram[layer]) * carrier.amount;
        }
        const reference_layer = profile.maximum_rooting_layer_index - profile.surface_layer_index;
        try deriveNaturalDrylandDepthPartition(humus, area_m2, reference_layer, parameters, cell_result);
        @memset(cell_wetland_arm, false);
        const adjusted_water_table_depth_m = water_table_depth_m - (minimum_surface_elevation_m - relative_surface_elevation_m[cell]) * (1 - water_table_slope);
        const dryland_depth_limit_m = adjusted_water_table_depth_m + profile.depth_to_layer_bottom_m[0] - maximum_surface_layer_bottom_m;
        var previous_bottom_m: f64 = 0;
        for (profile.depth_to_layer_bottom_m, 0..) |bottom_m, layer| {
            const midpoint_m = 0.5 * (previous_bottom_m + bottom_m);
            // `starts.f` 1032--1046 (`ELSE`, wetland): FCX collapses to 1 *and*
            // FC0's nutrient-protection exponential is source-commented out, so
            // this arm must be distinguishable from the reconstructed arm's
            // FCX=1, which keeps the exponential (`SOIL-HUMPART-001`).
            if (midpoint_m > dryland_depth_limit_m) {
                cell_result[layer] = 1;
                cell_wetland_arm[layer] = true;
            }
            previous_bottom_m = bottom_m;
        }
    }
}

/// `starts.f` lines 1290--1356 derives OSCM and the FOSCI/FOSNI/FOSPI limitation
/// fractions. Mineral-layer allocations from every K are limited by the
/// available humus (K=4) inventory.
pub fn deriveMineralAllocations(initial_complex: []const ElementPool, soil_mass_megagrams: f64, complex_nitrogen_to_carbon: []const f64, complex_phosphorus_to_carbon: []const f64, parameters: MineralAllocationDerivationParameters) !MineralAllocationDerivation {
    if (initial_complex.len != substrate_count or complex_nitrogen_to_carbon.len != substrate_count or complex_phosphorus_to_carbon.len != substrate_count or parameters.microbial_budget_fraction.len != substrate_count or parameters.residue_budget_fraction.len != substrate_count or parameters.dissolved_budget_fraction.len != substrate_count or parameters.adsorbed_budget_fraction.len != substrate_count or parameters.microbial_kinetic_fraction.len != substrate_count * kinetic_fraction_count or parameters.microbial_nitrogen_to_carbon.len != substrate_count * microbial_population_count * kinetic_fraction_count or parameters.microbial_phosphorus_to_carbon.len != substrate_count * microbial_population_count * kinetic_fraction_count or parameters.residue_nitrogen_to_carbon.len != substrate_count or parameters.residue_phosphorus_to_carbon.len != substrate_count) return error.OrganicInitializationDimensionMismatch;
    inline for (.{ soil_mass_megagrams, parameters.residue_microbial_fraction, parameters.humus_microbial_half_saturation_g_c_per_megagram, parameters.depth_partition_factor }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitializationParameter;
    if (parameters.humus_microbial_half_saturation_g_c_per_megagram <= 0 or parameters.depth_partition_factor > 1) return error.InvalidOrganicInitializationParameter;
    // `soil_mass_megagrams` is the STARTS organic *carrier*, chosen per layer by
    // `selectOrganicCarrier`: mineral mass `BKVL` where a mineral matrix exists,
    // total layer volume `VOLT` where it does not (`starts.f` 1297--1304,
    // 1328--1340). A ponded layer of open water legitimately arrives on the
    // volume branch, so rejecting a non-positive value here would reject the
    // source's own wetland case. Only a carrier that is absent in *both* senses
    // is invalid, and `selectOrganicCarrier` has already rejected that.
    if (soil_mass_megagrams <= 0) return error.InvalidOrganicInitializationParameter;
    for (initial_complex) |pool| try validatePool(pool);
    inline for (.{ complex_nitrogen_to_carbon, complex_phosphorus_to_carbon, parameters.microbial_budget_fraction, parameters.residue_budget_fraction, parameters.dissolved_budget_fraction, parameters.adsorbed_budget_fraction, parameters.microbial_kinetic_fraction, parameters.microbial_nitrogen_to_carbon, parameters.microbial_phosphorus_to_carbon, parameters.residue_nitrogen_to_carbon, parameters.residue_phosphorus_to_carbon }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitializationParameter;

    const humus_concentration_g_c_per_megagram = initial_complex[substrate_count - 1].carbon_g_c / soil_mass_megagrams;
    var result: MineralAllocationDerivation = .{
        .microbial_carbon_g_c = @splat(0),
        .carbon_allocation_fraction = @splat(0),
        .nitrogen_allocation_fraction = @splat(0),
        .phosphorus_allocation_fraction = @splat(0),
    };
    var total_initialization_carbon_g_c: f64 = 0;
    var total_initialization_nitrogen_g_n: f64 = 0;
    var total_initialization_phosphorus_g_p: f64 = 0;
    for (0..substrate_count) |substrate| {
        const concentration_g_c_per_megagram = initial_complex[substrate].carbon_g_c / soil_mass_megagrams;
        result.microbial_carbon_g_c[substrate] = if (substrate <= 2)
            parameters.residue_microbial_fraction * initial_complex[substrate].carbon_g_c
        else
            parameters.depth_partition_factor * soil_mass_megagrams * parameters.humus_microbial_half_saturation_g_c_per_megagram * concentration_g_c_per_megagram / (humus_concentration_g_c_per_megagram + parameters.humus_microbial_half_saturation_g_c_per_megagram);

        const carbon_budget = parameters.microbial_budget_fraction[substrate] + parameters.residue_budget_fraction[substrate] + parameters.dissolved_budget_fraction[substrate] + parameters.adsorbed_budget_fraction[substrate];
        const first_ratio_index = microbialParameterIndex(substrate, 0, 0);
        const second_ratio_index = microbialParameterIndex(substrate, 0, 1);
        const nitrogen_budget = parameters.microbial_kinetic_fraction[substrate * kinetic_fraction_count] * parameters.microbial_nitrogen_to_carbon[first_ratio_index] + parameters.microbial_kinetic_fraction[substrate * kinetic_fraction_count + 1] * parameters.microbial_nitrogen_to_carbon[second_ratio_index] + parameters.residue_budget_fraction[substrate] * parameters.residue_nitrogen_to_carbon[substrate] + (parameters.dissolved_budget_fraction[substrate] + parameters.adsorbed_budget_fraction[substrate]) * complex_nitrogen_to_carbon[substrate];
        const phosphorus_budget = parameters.microbial_kinetic_fraction[substrate * kinetic_fraction_count] * parameters.microbial_phosphorus_to_carbon[first_ratio_index] + parameters.microbial_kinetic_fraction[substrate * kinetic_fraction_count + 1] * parameters.microbial_phosphorus_to_carbon[second_ratio_index] + parameters.residue_budget_fraction[substrate] * parameters.residue_phosphorus_to_carbon[substrate] + (parameters.dissolved_budget_fraction[substrate] + parameters.adsorbed_budget_fraction[substrate]) * complex_phosphorus_to_carbon[substrate];
        total_initialization_carbon_g_c += initial_complex[substrate].carbon_g_c * carbon_budget;
        total_initialization_nitrogen_g_n += initial_complex[substrate].carbon_g_c * nitrogen_budget;
        total_initialization_phosphorus_g_p += initial_complex[substrate].carbon_g_c * phosphorus_budget;
    }
    if (!std.math.isFinite(total_initialization_carbon_g_c) or !std.math.isFinite(total_initialization_nitrogen_g_n) or !std.math.isFinite(total_initialization_phosphorus_g_p)) return error.NonFiniteOrganicInitialization;
    if (total_initialization_carbon_g_c > 1.0e-15) {
        const humus = initial_complex[substrate_count - 1];
        const carbon_fraction = @min(1.0, humus.carbon_g_c / total_initialization_carbon_g_c);
        const nitrogen_fraction = if (total_initialization_nitrogen_g_n > 0) @min(1.0, humus.carbon_g_c * complex_nitrogen_to_carbon[substrate_count - 1] / total_initialization_nitrogen_g_n) else 0;
        const phosphorus_fraction = if (total_initialization_phosphorus_g_p > 0) @min(1.0, humus.carbon_g_c * complex_phosphorus_to_carbon[substrate_count - 1] / total_initialization_phosphorus_g_p) else 0;
        @memset(&result.carbon_allocation_fraction, carbon_fraction);
        @memset(&result.nitrogen_allocation_fraction, nitrogen_fraction);
        @memset(&result.phosphorus_allocation_fraction, phosphorus_fraction);
    }
    inline for (.{ result.microbial_carbon_g_c, result.carbon_allocation_fraction, result.nitrogen_allocation_fraction, result.phosphorus_allocation_fraction }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.NonFiniteOrganicInitialization;
    return result;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    microbial: []ElementPool, // layer x 6 substrates x 7 populations x 3 fractions
    residue: []ElementPool, // layer x 5 substrates x 2 fractions
    dissolved: []ElementPool, // layer x 5 substrates
    adsorbed: []ElementPool, // layer x 5 substrates
    dissolved_acetate_carbon_g_c: []f64, // layer x 5 substrates, OQA
    adsorbed_acetate_carbon_g_c: []f64, // layer x 5 substrates, OHA
    structural: []ElementPool, // layer x 5 substrates x 5 fractions
    colonized_structural_carbon_g_c: []f64, // same shape as structural

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroOrganicInitializationLayers;
        const microbial_count = try product(&.{ layer_count, microbial_substrate_count, microbial_population_count, kinetic_fraction_count });
        const residue_count = try product(&.{ layer_count, substrate_count, residue_fraction_count });
        const mobile_count = try product(&.{ layer_count, substrate_count });
        const structural_count = try product(&.{ layer_count, substrate_count, structural_fraction_count });
        const microbial = try allocator.alloc(ElementPool, microbial_count);
        errdefer allocator.free(microbial);
        const residue = try allocator.alloc(ElementPool, residue_count);
        errdefer allocator.free(residue);
        const dissolved = try allocator.alloc(ElementPool, mobile_count);
        errdefer allocator.free(dissolved);
        const adsorbed = try allocator.alloc(ElementPool, mobile_count);
        errdefer allocator.free(adsorbed);
        const dissolved_acetate = try allocator.alloc(f64, mobile_count);
        errdefer allocator.free(dissolved_acetate);
        const adsorbed_acetate = try allocator.alloc(f64, mobile_count);
        errdefer allocator.free(adsorbed_acetate);
        const structural = try allocator.alloc(ElementPool, structural_count);
        errdefer allocator.free(structural);
        const colonized = try allocator.alloc(f64, structural_count);
        @memset(microbial, .{});
        @memset(residue, .{});
        @memset(dissolved, .{});
        @memset(adsorbed, .{});
        @memset(dissolved_acetate, 0);
        @memset(adsorbed_acetate, 0);
        @memset(structural, .{});
        @memset(colonized, 0);
        return .{ .allocator = allocator, .layer_count = layer_count, .microbial = microbial, .residue = residue, .dissolved = dissolved, .adsorbed = adsorbed, .dissolved_acetate_carbon_g_c = dissolved_acetate, .adsorbed_acetate_carbon_g_c = adsorbed_acetate, .structural = structural, .colonized_structural_carbon_g_c = colonized };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.colonized_structural_carbon_g_c);
        self.allocator.free(self.structural);
        self.allocator.free(self.adsorbed_acetate_carbon_g_c);
        self.allocator.free(self.dissolved_acetate_carbon_g_c);
        self.allocator.free(self.adsorbed);
        self.allocator.free(self.dissolved);
        self.allocator.free(self.residue);
        self.allocator.free(self.microbial);
        self.* = undefined;
    }

    pub fn totalCarbon_g_c(self: *const State, layer: usize) !f64 {
        if (layer >= self.layer_count) return error.OrganicInitializationLayerOutOfBounds;
        var total: f64 = 0;
        try addPoolCarbon(self.microbial, layer, microbial_substrate_count * microbial_population_count * kinetic_fraction_count, &total);
        try addPoolCarbon(self.residue, layer, substrate_count * residue_fraction_count, &total);
        try addPoolCarbon(self.dissolved, layer, substrate_count, &total);
        try addPoolCarbon(self.adsorbed, layer, substrate_count, &total);
        for (self.dissolved_acetate_carbon_g_c[layer * substrate_count ..][0..substrate_count]) |value| total += value;
        for (self.adsorbed_acetate_carbon_g_c[layer * substrate_count ..][0..substrate_count]) |value| total += value;
        try addPoolCarbon(self.structural, layer, substrate_count * structural_fraction_count, &total);
        if (!std.math.isFinite(total)) return error.NonFiniteOrganicCarbonState;
        return total;
    }

    /// Persistent fire charcoal is OSC(5,K,L): the most resistant structural
    /// fraction, summed across every runtime surface substrate.
    pub fn charcoalCarbon_g_c(self: *const State, layer: usize) !f64 {
        if (layer >= self.layer_count) return error.OrganicInitializationLayerOutOfBounds;
        var total: f64 = 0;
        for (0..substrate_count) |substrate| {
            const index = (layer * substrate_count + substrate) * structural_fraction_count +
                (structural_fraction_count - 1);
            const value = self.structural[index].carbon_g_c;
            if (!std.math.isFinite(value) or value < 0) return error.NonFiniteOrganicCarbonState;
            total += value;
        }
        if (!std.math.isFinite(total)) return error.NonFiniteOrganicCarbonState;
        return total;
    }

    pub fn substrateCarbon_g_c(self: *const State, layer: usize, substrate: usize) !f64 {
        if (layer >= self.layer_count or substrate >= substrate_count) return error.OrganicInitializationLayerOutOfBounds;
        var total: f64 = 0;
        for (0..microbial_population_count * kinetic_fraction_count) |index| total += self.microbial[((layer * microbial_substrate_count + substrate) * microbial_population_count * kinetic_fraction_count) + index].carbon_g_c;
        for (0..residue_fraction_count) |fraction| total += self.residue[(layer * substrate_count + substrate) * residue_fraction_count + fraction].carbon_g_c;
        total += self.dissolved[layer * substrate_count + substrate].carbon_g_c;
        total += self.adsorbed[layer * substrate_count + substrate].carbon_g_c;
        total += self.dissolved_acetate_carbon_g_c[layer * substrate_count + substrate];
        total += self.adsorbed_acetate_carbon_g_c[layer * substrate_count + substrate];
        for (0..structural_fraction_count) |fraction| total += self.structural[(layer * substrate_count + substrate) * structural_fraction_count + fraction].carbon_g_c;
        if (!std.math.isFinite(total) or total < 0) return error.NonFiniteOrganicCarbonState;
        return total;
    }

    /// Builds the mineral-layer STARTS organic state from the soil profile
    /// selected independently for each runtime grid cell.
    pub fn initializeMapped(self: *State, grid: *const GridState, properties: *const SoilProperties, catalog_entries: []const SoilCatalogEntry, catalog_index_by_cell: []const usize, horizontal_cell_width_m: []const f64, vertical_cell_width_m: []const f64, parameters: MappedRuntimeParameters) !void {
        var staged = try State.init(self.allocator, self.layer_count);
        errdefer staged.deinit();
        try staged.initializeMappedInPlace(grid, properties, catalog_entries, catalog_index_by_cell, horizontal_cell_width_m, vertical_cell_width_m, parameters);
        const previous = self.*;
        self.* = staged;
        staged = previous;
        staged.deinit();
    }

    fn initializeMappedInPlace(self: *State, grid: *const GridState, properties: *const SoilProperties, catalog_entries: []const SoilCatalogEntry, catalog_index_by_cell: []const usize, horizontal_cell_width_m: []const f64, vertical_cell_width_m: []const f64, parameters: MappedRuntimeParameters) !void {
        if (self.layer_count != grid.layer_count or properties.layer_count != grid.layer_count or catalog_index_by_cell.len != grid.cell_count or horizontal_cell_width_m.len != grid.cell_count or vertical_cell_width_m.len != grid.cell_count or parameters.depth_partition_factor_by_layer.len != grid.layer_count or parameters.wetland_layer_by_layer.len != grid.layer_count or parameters.default_complex_nitrogen_to_carbon.len != substrate_count or parameters.default_complex_phosphorus_to_carbon.len != substrate_count or parameters.residue_structural_fraction.len != 3 * structural_fraction_count or parameters.manure_structural_fraction_by_type.len != 2 * structural_fraction_count or parameters.particulate_structural_fraction.len != structural_fraction_count) return error.OrganicInitializationDimensionMismatch;
        inline for (.{ parameters.less_resistant_humus_fraction_at_surface, parameters.nutrient_protection_exponent, parameters.phosphorus_nutrient_weight }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitializationParameter;
        if (parameters.less_resistant_humus_fraction_at_surface > 1) return error.InvalidOrganicInitializationParameter;

        for (0..grid.cell_count) |cell| {
            const catalog_index = catalog_index_by_cell[cell];
            if (catalog_index >= catalog_entries.len) return error.SoilCatalogMapOutOfBounds;
            const profile = catalog_entries[catalog_index].profile;
            const material = catalog_entries[catalog_index].material;
            if (profile.total_layer_count != grid.active_soil_layer_count[cell]) return error.SoilLayerCountMismatch;
            // `starts.f` lines 776--796: buried litter/manure C, N and P (RSC/RSN/RSP)
            // are read on an area basis (g m-2) and converted to an extensive mass by
            // the layer's horizontal area -- the intermediate BKVL/VOLT carrier used
            // for the concentration cancels back out, so this is independent of
            // `selectOrganicCarrier`'s choice of carrier for this layer.
            const area_m2 = horizontal_cell_width_m[cell] * vertical_cell_width_m[cell];
            if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidCellGeometry;
            for (0..profile.total_layer_count) |layer| {
                const layer_cell = try grid.layerIndex(cell, layer);
                // `starts.f` lines 1297--1304: mineral mass where a matrix exists, total
                // layer volume where it does not. A ponded layer is the latter.
                const carrier = try selectOrganicCarrier(
                    properties.matrix_bulk_volume_m3[layer_cell] * properties.bulk_density_megagrams_per_m3[layer_cell],
                    properties.layer_volume_m3[layer_cell],
                    parameters.negligible_mineral_mass_megagrams,
                );
                const soil_mass_megagrams = carrier.amount;
                const masses = try profileOrganicComplexMasses(1.0e-3 * material.total_organic_carbon_g_per_megagram[layer], 1.0e-3 * material.particulate_organic_carbon_g_per_megagram[layer], material.organic_nitrogen_g_per_megagram[layer], material.organic_phosphorus_g_per_megagram[layer], soil_mass_megagrams, parameters.microbial_derivation.residue_nitrogen_to_carbon[3], parameters.microbial_derivation.residue_phosphorus_to_carbon[3]);
                var initial_complex = [_]ElementPool{.{}} ** substrate_count;
                // `starts.f` lines 776--786/1298: previous coarse woody (K=0), fine
                // (K=1) litter, and manure (K=2) buried in this mineral layer, parsed
                // by `soil_profile.zig` but previously never consumed
                // (SOIL-STARTS-BURIED-LITTER-001).
                initial_complex[0] = .{
                    .carbon_g_c = profile.property(.woody_litter_carbon_g_m2)[layer] * area_m2,
                    .nitrogen_g_n = profile.property(.woody_litter_nitrogen_g_m2)[layer] * area_m2,
                    .phosphorus_g_p = profile.property(.woody_litter_phosphorus_g_m2)[layer] * area_m2,
                };
                initial_complex[1] = .{
                    .carbon_g_c = profile.property(.fine_litter_carbon_g_m2)[layer] * area_m2,
                    .nitrogen_g_n = profile.property(.fine_litter_nitrogen_g_m2)[layer] * area_m2,
                    .phosphorus_g_p = profile.property(.fine_litter_phosphorus_g_m2)[layer] * area_m2,
                };
                initial_complex[2] = .{
                    .carbon_g_c = profile.property(.manure_carbon_g_m2)[layer] * area_m2,
                    .nitrogen_g_n = profile.property(.manure_nitrogen_g_m2)[layer] * area_m2,
                    .phosphorus_g_p = profile.property(.manure_phosphorus_g_m2)[layer] * area_m2,
                };
                initial_complex[3] = .{ .carbon_g_c = masses.particulate_carbon_g_c, .nitrogen_g_n = masses.particulate_nitrogen_g_n, .phosphorus_g_p = masses.particulate_phosphorus_g_p };
                initial_complex[4] = .{ .carbon_g_c = masses.humus_carbon_g_c, .nitrogen_g_n = masses.humus_nitrogen_g_n, .phosphorus_g_p = masses.humus_phosphorus_g_p };
                var nitrogen_to_carbon: [substrate_count]f64 = undefined;
                var phosphorus_to_carbon: [substrate_count]f64 = undefined;
                for (0..substrate_count) |substrate| {
                    nitrogen_to_carbon[substrate] = if (initial_complex[substrate].carbon_g_c > 0) initial_complex[substrate].nitrogen_g_n / initial_complex[substrate].carbon_g_c else parameters.default_complex_nitrogen_to_carbon[substrate];
                    phosphorus_to_carbon[substrate] = if (initial_complex[substrate].carbon_g_c > 0) initial_complex[substrate].phosphorus_g_p / initial_complex[substrate].carbon_g_c else parameters.default_complex_phosphorus_to_carbon[substrate];
                }
                var derivation_parameters = parameters.microbial_derivation;
                derivation_parameters.depth_partition_factor = parameters.depth_partition_factor_by_layer[layer_cell];
                const derived = try deriveMineralAllocations(&initial_complex, soil_mass_megagrams, &nitrogen_to_carbon, &phosphorus_to_carbon, derivation_parameters);

                var structural_fraction = [_]f64{0} ** (substrate_count * structural_fraction_count);
                @memcpy(structural_fraction[0 .. 3 * structural_fraction_count], parameters.residue_structural_fraction);
                @memcpy(
                    structural_fraction[2 * structural_fraction_count ..][0..structural_fraction_count],
                    manureStructuralFraction(profile.surface_manure_type, parameters.manure_structural_fraction_by_type),
                );
                @memcpy(structural_fraction[3 * structural_fraction_count ..][0..structural_fraction_count], parameters.particulate_structural_fraction);
                const humus = initial_complex[4];
                const nutrient_ratio = if (humus.carbon_g_c > 0) @min(humus.nitrogen_g_n, parameters.phosphorus_nutrient_weight * humus.phosphorus_g_p) / humus.carbon_g_c else 0;
                // `starts.f` 1032--1037: the wetland arm's FC0 nutrient-protection
                // exponential is source-commented out (flat FCY), unlike the
                // dryland and reconstructed arms (`SOIL-HUMPART-001`).
                const less_resistant_fraction = lessResistantHumusFraction(
                    parameters.less_resistant_humus_fraction_at_surface,
                    parameters.nutrient_protection_exponent,
                    nutrient_ratio,
                    parameters.depth_partition_factor_by_layer[layer_cell],
                    parameters.wetland_layer_by_layer[layer_cell],
                );
                if (!std.math.isFinite(less_resistant_fraction) or less_resistant_fraction < 0 or less_resistant_fraction > 1) return error.InvalidOrganicInitializationParameter;
                structural_fraction[4 * structural_fraction_count] = less_resistant_fraction;
                structural_fraction[4 * structural_fraction_count + 1] = 1 - less_resistant_fraction;
                var structural_nitrogen_to_carbon: [substrate_count * structural_fraction_count]f64 = undefined;
                var structural_phosphorus_to_carbon: [substrate_count * structural_fraction_count]f64 = undefined;
                for (0..substrate_count) |substrate| for (0..structural_fraction_count) |fraction| {
                    structural_nitrogen_to_carbon[substrate * structural_fraction_count + fraction] = nitrogen_to_carbon[substrate];
                    structural_phosphorus_to_carbon[substrate * structural_fraction_count + fraction] = phosphorus_to_carbon[substrate];
                };
                try self.initializeMineralLayer(layer_cell, .{
                    .initial_complex = &initial_complex,
                    .microbial_carbon_g_c = &derived.microbial_carbon_g_c,
                    .carbon_allocation_fraction = &derived.carbon_allocation_fraction,
                    .nitrogen_allocation_fraction = &derived.nitrogen_allocation_fraction,
                    .phosphorus_allocation_fraction = &derived.phosphorus_allocation_fraction,
                    .complex_nitrogen_to_carbon = &nitrogen_to_carbon,
                    .complex_phosphorus_to_carbon = &phosphorus_to_carbon,
                    .structural_fraction = &structural_fraction,
                    .structural_nitrogen_to_carbon = &structural_nitrogen_to_carbon,
                    .structural_phosphorus_to_carbon = &structural_phosphorus_to_carbon,
                }, parameters.pool_allocation);
            }
        }
    }

    pub fn initializeMappedSurface(self: *State, catalog_entries: []const SoilCatalogEntry, catalog_index_by_cell: []const usize, horizontal_cell_width_m: []const f64, vertical_cell_width_m: []const f64, parameters: SurfaceRuntimeParameters) !void {
        var staged = try State.init(self.allocator, self.layer_count);
        errdefer staged.deinit();
        try staged.initializeMappedSurfaceInPlace(catalog_entries, catalog_index_by_cell, horizontal_cell_width_m, vertical_cell_width_m, parameters);
        const previous = self.*;
        self.* = staged;
        staged = previous;
        staged.deinit();
    }

    fn initializeMappedSurfaceInPlace(self: *State, catalog_entries: []const SoilCatalogEntry, catalog_index_by_cell: []const usize, horizontal_cell_width_m: []const f64, vertical_cell_width_m: []const f64, parameters: SurfaceRuntimeParameters) !void {
        if (catalog_index_by_cell.len != self.layer_count or
            horizontal_cell_width_m.len != self.layer_count or
            vertical_cell_width_m.len != self.layer_count or
            parameters.default_complex_nitrogen_to_carbon.len != substrate_count or parameters.default_complex_phosphorus_to_carbon.len != substrate_count or parameters.woody_structural_fraction.len != structural_fraction_count or parameters.plant_structural_fraction_by_type.len != 12 * structural_fraction_count or parameters.manure_structural_fraction_by_type.len != 2 * structural_fraction_count or parameters.residue_nitrogen_weight.len != 3 * structural_fraction_count or parameters.residue_phosphorus_weight.len != 3 * structural_fraction_count) return error.OrganicInitializationDimensionMismatch;
        if (!std.math.isFinite(parameters.residue_microbial_fraction) or parameters.residue_microbial_fraction < 0 or parameters.residue_microbial_fraction > 1) return error.InvalidOrganicInitializationParameter;
        const unit_allocation = [_]f64{1} ** substrate_count;
        for (catalog_index_by_cell, 0..) |catalog_index, cell| {
            if (catalog_index >= catalog_entries.len) return error.SoilCatalogMapOutOfBounds;
            const area_m2 = horizontal_cell_width_m[cell] * vertical_cell_width_m[cell];
            if (!std.math.isFinite(area_m2) or area_m2 <= 0) return error.InvalidCellGeometry;
            const profile = catalog_entries[catalog_index].profile;
            var initial = [_]ElementPool{.{}} ** substrate_count;
            initial[0] = .{ .carbon_g_c = profile.surface_woody_litter_carbon_g_c_per_m2 * area_m2, .nitrogen_g_n = profile.surface_woody_litter_nitrogen_g_n_per_m2 * area_m2, .phosphorus_g_p = profile.surface_woody_litter_phosphorus_g_p_per_m2 * area_m2 };
            initial[1] = .{ .carbon_g_c = profile.surface_fine_litter_carbon_g_c_per_m2 * area_m2, .nitrogen_g_n = profile.surface_fine_litter_nitrogen_g_n_per_m2 * area_m2, .phosphorus_g_p = profile.surface_fine_litter_phosphorus_g_p_per_m2 * area_m2 };
            initial[2] = .{ .carbon_g_c = profile.surface_manure_carbon_g_c_per_m2 * area_m2, .nitrogen_g_n = profile.surface_manure_nitrogen_g_n_per_m2 * area_m2, .phosphorus_g_p = profile.surface_manure_phosphorus_g_p_per_m2 * area_m2 };
            var structural_fraction = [_]f64{0} ** (substrate_count * structural_fraction_count);
            @memcpy(structural_fraction[0..structural_fraction_count], parameters.woody_structural_fraction);
            const plant_type_index: usize = if (profile.surface_plant_litter_type >= 1 and profile.surface_plant_litter_type <= 11) @intCast(profile.surface_plant_litter_type - 1) else 11;
            @memcpy(structural_fraction[structural_fraction_count..][0..structural_fraction_count], parameters.plant_structural_fraction_by_type[plant_type_index * structural_fraction_count ..][0..structural_fraction_count]);
            @memcpy(structural_fraction[2 * structural_fraction_count ..][0..structural_fraction_count], manureStructuralFraction(profile.surface_manure_type, parameters.manure_structural_fraction_by_type));
            structural_fraction[3 * structural_fraction_count] = 1;
            structural_fraction[4 * structural_fraction_count] = 1;
            var complex_nitrogen_to_carbon: [substrate_count]f64 = undefined;
            var complex_phosphorus_to_carbon: [substrate_count]f64 = undefined;
            var structural_nitrogen_to_carbon: [substrate_count * structural_fraction_count]f64 = undefined;
            var structural_phosphorus_to_carbon: [substrate_count * structural_fraction_count]f64 = undefined;
            for (0..substrate_count) |substrate| {
                complex_nitrogen_to_carbon[substrate] = parameters.default_complex_nitrogen_to_carbon[substrate];
                complex_phosphorus_to_carbon[substrate] = parameters.default_complex_phosphorus_to_carbon[substrate];
                for (0..structural_fraction_count) |fraction| {
                    structural_nitrogen_to_carbon[substrate * structural_fraction_count + fraction] = parameters.default_complex_nitrogen_to_carbon[substrate];
                    structural_phosphorus_to_carbon[substrate * structural_fraction_count + fraction] = parameters.default_complex_phosphorus_to_carbon[substrate];
                }
                if (substrate >= 3 or initial[substrate].carbon_g_c <= 0) continue;
                var weighted_nitrogen: f64 = 0;
                var weighted_phosphorus: f64 = 0;
                for (0..structural_fraction_count) |fraction| {
                    const index = substrate * structural_fraction_count + fraction;
                    weighted_nitrogen += structural_fraction[index] * parameters.residue_nitrogen_weight[index];
                    weighted_phosphorus += structural_fraction[index] * parameters.residue_phosphorus_weight[index];
                }
                if (weighted_nitrogen <= 0 or weighted_phosphorus <= 0) return error.InvalidOrganicInitializationParameter;
                const nitrogen_scale = initial[substrate].nitrogen_g_n / (initial[substrate].carbon_g_c * weighted_nitrogen);
                const phosphorus_scale = initial[substrate].phosphorus_g_p / (initial[substrate].carbon_g_c * weighted_phosphorus);
                complex_nitrogen_to_carbon[substrate] = initial[substrate].nitrogen_g_n / initial[substrate].carbon_g_c;
                complex_phosphorus_to_carbon[substrate] = initial[substrate].phosphorus_g_p / initial[substrate].carbon_g_c;
                for (0..structural_fraction_count) |fraction| {
                    const index = substrate * structural_fraction_count + fraction;
                    structural_nitrogen_to_carbon[index] = parameters.residue_nitrogen_weight[index] * nitrogen_scale;
                    structural_phosphorus_to_carbon[index] = parameters.residue_phosphorus_weight[index] * phosphorus_scale;
                }
            }
            var microbial_carbon: [substrate_count]f64 = undefined;
            for (initial, 0..) |pool, substrate| microbial_carbon[substrate] = parameters.residue_microbial_fraction * pool.carbon_g_c;
            try self.initializeSurfaceLayer(cell, .{
                .initial_complex = &initial,
                .microbial_carbon_g_c = &microbial_carbon,
                .carbon_allocation_fraction = &unit_allocation,
                .nitrogen_allocation_fraction = &unit_allocation,
                .phosphorus_allocation_fraction = &unit_allocation,
                .complex_nitrogen_to_carbon = &complex_nitrogen_to_carbon,
                .complex_phosphorus_to_carbon = &complex_phosphorus_to_carbon,
                .structural_fraction = &structural_fraction,
                .structural_nitrogen_to_carbon = &structural_nitrogen_to_carbon,
                .structural_phosphorus_to_carbon = &structural_phosphorus_to_carbon,
            }, parameters.pool_allocation);
        }
    }

    /// Translates `starts.f` lines 1293--1467 for one mineral-soil layer. Results are
    /// prepared in temporary heap storage and published atomically.
    pub fn initializeMineralLayer(self: *State, layer: usize, inputs: LayerInputs, parameters: RuntimeParameters) !void {
        return self.initializeLayer(layer, inputs, parameters, .mineral);
    }

    /// Translates the same STARTS transaction for L=0 surface litter. The
    /// caller supplies surface-specific kinetic fractions and unit allocation
    /// factors; STARTS sets X=0 for residue, dissolved, and adsorbed pools.
    pub fn initializeSurfaceLayer(self: *State, cell: usize, inputs: LayerInputs, parameters: RuntimeParameters) !void {
        return self.initializeLayer(cell, inputs, parameters, .surface);
    }

    const LayerKind = enum { mineral, surface };

    fn initializeLayer(self: *State, layer: usize, inputs: LayerInputs, parameters: RuntimeParameters, layer_kind: LayerKind) !void {
        if (layer >= self.layer_count) return error.OrganicInitializationLayerOutOfBounds;
        try validateDimensions(inputs, parameters);
        try validateValues(inputs, parameters);

        const microbial_count = microbial_substrate_count * microbial_population_count * kinetic_fraction_count;
        var microbial = try self.allocator.alloc(ElementPool, microbial_count);
        defer self.allocator.free(microbial);
        const residue_count = substrate_count * residue_fraction_count;
        var residue = try self.allocator.alloc(ElementPool, residue_count);
        defer self.allocator.free(residue);
        var dissolved = try self.allocator.alloc(ElementPool, substrate_count);
        defer self.allocator.free(dissolved);
        var adsorbed = try self.allocator.alloc(ElementPool, substrate_count);
        defer self.allocator.free(adsorbed);
        const structural_count = substrate_count * structural_fraction_count;
        var structural = try self.allocator.alloc(ElementPool, structural_count);
        defer self.allocator.free(structural);
        var colonized = try self.allocator.alloc(f64, structural_count);
        defer self.allocator.free(colonized);
        @memset(microbial, .{});
        @memset(residue, .{});
        @memset(dissolved, .{});
        @memset(adsorbed, .{});
        @memset(structural, .{});
        @memset(colonized, 0);

        var allocated = [_]ElementPool{.{}} ** substrate_count;
        for (0..substrate_count) |substrate| {
            // Mineral STARTS sets KK=4; surface STARTS retains KK=K.
            const allocation_target = if (layer_kind == .mineral) substrate_count - 1 else substrate;
            const nonmicrobial_initialization_multiplier: f64 = if (layer_kind == .mineral) 1 else 0;
            const microbial_carbon = inputs.microbial_carbon_g_c[substrate];
            const carbon_allocation = inputs.carbon_allocation_fraction[substrate];
            const nitrogen_allocation = inputs.nitrogen_allocation_fraction[substrate];
            const phosphorus_allocation = inputs.phosphorus_allocation_fraction[substrate];

            for (0..microbial_population_count) |population| for (0..kinetic_fraction_count) |fraction| {
                const parameter_index = microbialParameterIndex(substrate, population, fraction);
                const carbon = @max(0.0, microbial_carbon * parameters.microbial_kinetic_fraction[substrate * kinetic_fraction_count + fraction] * parameters.heterotroph_population_fraction[population] * carbon_allocation);
                const pool: ElementPool = .{
                    .carbon_g_c = carbon,
                    .nitrogen_g_n = @max(0.0, carbon * parameters.microbial_nitrogen_to_carbon[parameter_index] * nitrogen_allocation),
                    .phosphorus_g_p = @max(0.0, carbon * parameters.microbial_phosphorus_to_carbon[parameter_index] * phosphorus_allocation),
                };
                microbial[microbialIndex(substrate, population, fraction)] = pool;
                add(&allocated[allocation_target], pool);
                for (0..microbial_population_count) |autotroph_population| {
                    const autotroph_pool = scale(pool, parameters.autotroph_population_fraction[autotroph_population]);
                    add(&microbial[microbialIndex(autotrophic_substrate_index, autotroph_population, fraction)], autotroph_pool);
                    add(&allocated[allocation_target], autotroph_pool);
                }
            };

            for (0..residue_fraction_count) |fraction| {
                const carbon = nonmicrobial_initialization_multiplier * @max(0.0, microbial_carbon * parameters.residue_fraction[substrate * residue_fraction_count + fraction] * carbon_allocation);
                const ratio_index = microbialParameterIndex(substrate, 0, fraction);
                const pool: ElementPool = .{
                    .carbon_g_c = carbon,
                    .nitrogen_g_n = @max(0.0, carbon * parameters.microbial_nitrogen_to_carbon[ratio_index] * nitrogen_allocation),
                    .phosphorus_g_p = @max(0.0, carbon * parameters.microbial_phosphorus_to_carbon[ratio_index] * phosphorus_allocation),
                };
                residue[substrate * residue_fraction_count + fraction] = pool;
                add(&allocated[allocation_target], pool);
            }

            const dissolved_carbon = nonmicrobial_initialization_multiplier * @max(0.0, microbial_carbon * parameters.dissolved_fraction[substrate] * carbon_allocation);
            dissolved[substrate] = .{
                .carbon_g_c = dissolved_carbon,
                .nitrogen_g_n = @max(0.0, dissolved_carbon * inputs.complex_nitrogen_to_carbon[substrate] * nitrogen_allocation),
                .phosphorus_g_p = @max(0.0, dissolved_carbon * inputs.complex_phosphorus_to_carbon[substrate] * phosphorus_allocation),
            };
            add(&allocated[allocation_target], dissolved[substrate]);

            const adsorbed_carbon = nonmicrobial_initialization_multiplier * @max(0.0, microbial_carbon * parameters.adsorbed_fraction[substrate] * carbon_allocation);
            adsorbed[substrate] = .{
                .carbon_g_c = adsorbed_carbon,
                .nitrogen_g_n = @max(0.0, adsorbed_carbon * inputs.complex_nitrogen_to_carbon[substrate] * nitrogen_allocation),
                .phosphorus_g_p = @max(0.0, adsorbed_carbon * inputs.complex_phosphorus_to_carbon[substrate] * phosphorus_allocation),
            };
            add(&allocated[allocation_target], adsorbed[substrate]);

            for (0..structural_fraction_count) |fraction| {
                const index = substrate * structural_fraction_count + fraction;
                const carbon = @max(0.0, inputs.structural_fraction[index] * (inputs.initial_complex[substrate].carbon_g_c - allocated[substrate].carbon_g_c));
                const nitrogen = if (inputs.complex_nitrogen_to_carbon[substrate] > 0)
                    @max(0.0, inputs.structural_fraction[index] * inputs.structural_nitrogen_to_carbon[index] / inputs.complex_nitrogen_to_carbon[substrate] * (inputs.initial_complex[substrate].nitrogen_g_n - allocated[substrate].nitrogen_g_n))
                else
                    0;
                const phosphorus = if (inputs.complex_phosphorus_to_carbon[substrate] > 0)
                    @max(0.0, inputs.structural_fraction[index] * inputs.structural_phosphorus_to_carbon[index] / inputs.complex_phosphorus_to_carbon[substrate] * (inputs.initial_complex[substrate].phosphorus_g_p - allocated[substrate].phosphorus_g_p))
                else
                    0;
                structural[index] = .{ .carbon_g_c = carbon, .nitrogen_g_n = nitrogen, .phosphorus_g_p = phosphorus };
                // `starts.f` 1464--1468: `IF(K.EQ.0)THEN OSA=OSC*OMCI(1,K) ELSE
                // OSA=OSC ENDIF` -- the initial-colonization discount for woody
                // structural carbon (substrate 0) applies whenever substrate==0,
                // regardless of whether this is a surface or mineral layer. It was
                // previously restricted to the surface layer only; that restriction
                // was inert while mineral-layer substrate-0 carbon was always zero
                // (SOIL-STARTS-BURIED-LITTER-001) and would otherwise have
                // double-counted buried woody litter as fully colonized from day one.
                colonized[index] = if (substrate == 0)
                    carbon * parameters.microbial_kinetic_fraction[0]
                else
                    carbon;
            }
        }
        inline for (.{ microbial, residue, dissolved, adsorbed, structural }) |pools| for (pools) |pool| try validatePool(pool);
        for (colonized) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitializationResult;

        @memcpy(self.microbial[layer * microbial_count ..][0..microbial_count], microbial);
        @memcpy(self.residue[layer * residue_count ..][0..residue_count], residue);
        @memcpy(self.dissolved[layer * substrate_count ..][0..substrate_count], dissolved);
        @memcpy(self.adsorbed[layer * substrate_count ..][0..substrate_count], adsorbed);
        @memcpy(self.structural[layer * structural_count ..][0..structural_count], structural);
        @memcpy(self.colonized_structural_carbon_g_c[layer * structural_count ..][0..structural_count], colonized);
    }
};

fn validateDimensions(inputs: LayerInputs, parameters: RuntimeParameters) !void {
    inline for (.{ inputs.initial_complex, inputs.microbial_carbon_g_c, inputs.carbon_allocation_fraction, inputs.nitrogen_allocation_fraction, inputs.phosphorus_allocation_fraction, inputs.complex_nitrogen_to_carbon, inputs.complex_phosphorus_to_carbon }) |values| if (values.len != substrate_count) return error.OrganicInitializationDimensionMismatch;
    inline for (.{ inputs.structural_fraction, inputs.structural_nitrogen_to_carbon, inputs.structural_phosphorus_to_carbon }) |values| if (values.len != substrate_count * structural_fraction_count) return error.OrganicInitializationDimensionMismatch;
    inline for (.{parameters.microbial_kinetic_fraction}) |values| if (values.len != substrate_count * kinetic_fraction_count) return error.OrganicInitializationDimensionMismatch;
    if (parameters.residue_fraction.len != substrate_count * residue_fraction_count or parameters.dissolved_fraction.len != substrate_count or parameters.adsorbed_fraction.len != substrate_count or parameters.heterotroph_population_fraction.len != microbial_population_count or parameters.autotroph_population_fraction.len != microbial_population_count or parameters.microbial_nitrogen_to_carbon.len != substrate_count * microbial_population_count * kinetic_fraction_count or parameters.microbial_phosphorus_to_carbon.len != substrate_count * microbial_population_count * kinetic_fraction_count) return error.OrganicInitializationDimensionMismatch;
}

fn validateValues(inputs: LayerInputs, parameters: RuntimeParameters) !void {
    for (inputs.initial_complex) |pool| try validatePool(pool);
    inline for (.{ inputs.microbial_carbon_g_c, inputs.carbon_allocation_fraction, inputs.nitrogen_allocation_fraction, inputs.phosphorus_allocation_fraction, inputs.complex_nitrogen_to_carbon, inputs.complex_phosphorus_to_carbon, inputs.structural_fraction, inputs.structural_nitrogen_to_carbon, inputs.structural_phosphorus_to_carbon, parameters.microbial_kinetic_fraction, parameters.residue_fraction, parameters.dissolved_fraction, parameters.adsorbed_fraction, parameters.heterotroph_population_fraction, parameters.autotroph_population_fraction, parameters.microbial_nitrogen_to_carbon, parameters.microbial_phosphorus_to_carbon }) |values| for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitializationParameter;
    inline for (.{ inputs.carbon_allocation_fraction, inputs.nitrogen_allocation_fraction, inputs.phosphorus_allocation_fraction, inputs.structural_fraction, parameters.microbial_kinetic_fraction, parameters.residue_fraction, parameters.dissolved_fraction, parameters.adsorbed_fraction, parameters.heterotroph_population_fraction, parameters.autotroph_population_fraction }) |values| for (values) |value| if (value > 1) return error.InvalidOrganicInitializationParameter;
}

fn validatePool(pool: ElementPool) !void {
    inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidOrganicInitializationResult;
}

fn add(target: *ElementPool, value: ElementPool) void {
    target.carbon_g_c += value.carbon_g_c;
    target.nitrogen_g_n += value.nitrogen_g_n;
    target.phosphorus_g_p += value.phosphorus_g_p;
}

fn scale(pool: ElementPool, fraction: f64) ElementPool {
    return .{ .carbon_g_c = pool.carbon_g_c * fraction, .nitrogen_g_n = pool.nitrogen_g_n * fraction, .phosphorus_g_p = pool.phosphorus_g_p * fraction };
}

fn microbialIndex(substrate: usize, population: usize, fraction: usize) usize {
    return (substrate * microbial_population_count + population) * kinetic_fraction_count + fraction;
}

fn addPoolCarbon(pools: []const ElementPool, layer: usize, stride: usize, total: *f64) !void {
    for (pools[layer * stride ..][0..stride]) |pool| {
        // MICROBIAL-POOL-CARBON-OVERDRAW-HOUR-2678-001. The `-1e-14` floor was an
        // invented domain: `nitro.f` writes microbial carbon pools unclamped
        // (`:3824`, `:3832`) and reads each through `AMAX1(0.0, ...)` (`:431`,
        // `:454`, `:2094`, `:2532`), so a negative pool is oracle-legal and the
        // observed value is `-1.2936078130910764e-7` -- seven orders past the
        // floor, once in 2,677 hours. Non-finite stays fatal, which is what the
        // two tests asserting this error inject.
        if (!std.math.isFinite(pool.carbon_g_c)) return error.InvalidOrganicCarbonState;
        total.* += @max(0, pool.carbon_g_c);
    }
}

fn microbialParameterIndex(substrate: usize, population: usize, fraction: usize) usize {
    return microbialIndex(substrate, population, fraction);
}

fn product(values: []const usize) !usize {
    var result: usize = 1;
    for (values) |value| result = try std.math.mul(usize, result, value);
    return result;
}

test "mineral STARTS organic transaction initializes all runtime pools atomically" {
    const allocator = std.testing.allocator;
    var state = try State.init(allocator, 2);
    defer state.deinit();
    const initial = [_]ElementPool{.{ .carbon_g_c = 100, .nitrogen_g_n = 10, .phosphorus_g_p = 1 }} ** substrate_count;
    const fives = [_]f64{1} ** substrate_count;
    const ratios_n = [_]f64{0.1} ** substrate_count;
    const ratios_p = [_]f64{0.01} ** substrate_count;
    const structural_fraction = [_]f64{0.2} ** (substrate_count * structural_fraction_count);
    const microbial_fraction = [_]f64{0.01} ** (substrate_count * kinetic_fraction_count);
    const residue_fraction = [_]f64{0.01} ** (substrate_count * residue_fraction_count);
    const dissolved_fraction = [_]f64{0.005} ** substrate_count;
    const adsorbed_fraction = [_]f64{0.05} ** substrate_count;
    const heterotroph_fraction = [_]f64{1.0 / 7.0} ** microbial_population_count;
    const autotroph_fraction = [_]f64{0} ** microbial_population_count;
    const microbial_n = [_]f64{0.1} ** (substrate_count * microbial_population_count * kinetic_fraction_count);
    const microbial_p = [_]f64{0.01} ** (substrate_count * microbial_population_count * kinetic_fraction_count);
    try state.initializeMineralLayer(1, .{
        .initial_complex = &initial,
        .microbial_carbon_g_c = &([_]f64{10} ** substrate_count),
        .carbon_allocation_fraction = &fives,
        .nitrogen_allocation_fraction = &fives,
        .phosphorus_allocation_fraction = &fives,
        .complex_nitrogen_to_carbon = &ratios_n,
        .complex_phosphorus_to_carbon = &ratios_p,
        .structural_fraction = &structural_fraction,
        .structural_nitrogen_to_carbon = &([_]f64{0.1} ** (substrate_count * structural_fraction_count)),
        .structural_phosphorus_to_carbon = &([_]f64{0.01} ** (substrate_count * structural_fraction_count)),
    }, .{
        .microbial_kinetic_fraction = &microbial_fraction,
        .residue_fraction = &residue_fraction,
        .dissolved_fraction = &dissolved_fraction,
        .adsorbed_fraction = &adsorbed_fraction,
        .heterotroph_population_fraction = &heterotroph_fraction,
        .autotroph_population_fraction = &autotroph_fraction,
        .microbial_nitrogen_to_carbon = &microbial_n,
        .microbial_phosphorus_to_carbon = &microbial_p,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), state.dissolved[1 * substrate_count + 4].carbon_g_c, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), state.adsorbed[1 * substrate_count + 4].carbon_g_c, 1.0e-15);
    var structural_carbon: f64 = 0;
    for (state.structural[(1 * substrate_count + 4) * structural_fraction_count ..][0..structural_fraction_count]) |pool| structural_carbon += pool.carbon_g_c;
    try std.testing.expectApproxEqAbs(@as(f64, 94.75), structural_carbon, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved[4].carbon_g_c);
    try state.initializeSurfaceLayer(0, .{
        .initial_complex = &initial,
        .microbial_carbon_g_c = &([_]f64{25} ** substrate_count),
        .carbon_allocation_fraction = &fives,
        .nitrogen_allocation_fraction = &fives,
        .phosphorus_allocation_fraction = &fives,
        .complex_nitrogen_to_carbon = &ratios_n,
        .complex_phosphorus_to_carbon = &ratios_p,
        .structural_fraction = &structural_fraction,
        .structural_nitrogen_to_carbon = &([_]f64{0.1} ** (substrate_count * structural_fraction_count)),
        .structural_phosphorus_to_carbon = &([_]f64{0.01} ** (substrate_count * structural_fraction_count)),
    }, .{
        .microbial_kinetic_fraction = &microbial_fraction,
        .residue_fraction = &residue_fraction,
        .dissolved_fraction = &dissolved_fraction,
        .adsorbed_fraction = &adsorbed_fraction,
        .heterotroph_population_fraction = &heterotroph_fraction,
        .autotroph_population_fraction = &autotroph_fraction,
        .microbial_nitrogen_to_carbon = &microbial_n,
        .microbial_phosphorus_to_carbon = &microbial_p,
    });
    try std.testing.expect(state.microbial[microbialIndex(1, 0, 0)].carbon_g_c > 0);
    try std.testing.expectEqual(@as(f64, 0), state.residue[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), state.adsorbed[0].carbon_g_c);
    try std.testing.expectApproxEqAbs(state.structural[0].carbon_g_c * microbial_fraction[0], state.colonized_structural_carbon_g_c[0], 1.0e-15);
}

test "failed organic initialization leaves published layer unchanged" {
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.dissolved[0].carbon_g_c = 7;
    const empty = [_]f64{};
    const empty_pools = [_]ElementPool{};
    try std.testing.expectError(error.OrganicInitializationDimensionMismatch, state.initializeMineralLayer(0, .{
        .initial_complex = &empty_pools,
        .microbial_carbon_g_c = &empty,
        .carbon_allocation_fraction = &empty,
        .nitrogen_allocation_fraction = &empty,
        .phosphorus_allocation_fraction = &empty,
        .complex_nitrogen_to_carbon = &empty,
        .complex_phosphorus_to_carbon = &empty,
        .structural_fraction = &empty,
        .structural_nitrogen_to_carbon = &empty,
        .structural_phosphorus_to_carbon = &empty,
    }, .{
        .microbial_kinetic_fraction = &empty,
        .residue_fraction = &empty,
        .dissolved_fraction = &empty,
        .adsorbed_fraction = &empty,
        .heterotroph_population_fraction = &empty,
        .autotroph_population_fraction = &empty,
        .microbial_nitrogen_to_carbon = &empty,
        .microbial_phosphorus_to_carbon = &empty,
    }));
    try std.testing.expectEqual(@as(f64, 7), state.dissolved[0].carbon_g_c);
}

test "STARTS mineral microbial carbon and humus allocation limits are derived at runtime" {
    const initial = [_]ElementPool{
        .{},                                                             .{},                                                             .{},
        .{ .carbon_g_c = 200, .nitrogen_g_n = 10, .phosphorus_g_p = 1 }, .{ .carbon_g_c = 800, .nitrogen_g_n = 80, .phosphorus_g_p = 8 },
    };
    const ratios_n = [_]f64{ 0, 0, 0, 0.05, 0.1 };
    const ratios_p = [_]f64{ 0, 0, 0, 0.005, 0.01 };
    const budget = [_]f64{0.01} ** substrate_count;
    const residue_budget = [_]f64{0.25} ** substrate_count;
    const dissolved_budget = [_]f64{0.005} ** substrate_count;
    const adsorbed_budget = [_]f64{0.05} ** substrate_count;
    const kinetic = [_]f64{0.01} ** (substrate_count * kinetic_fraction_count);
    const microbial_n = [_]f64{0.1} ** (substrate_count * microbial_population_count * kinetic_fraction_count);
    const microbial_p = [_]f64{0.01} ** (substrate_count * microbial_population_count * kinetic_fraction_count);
    const derived = try deriveMineralAllocations(&initial, 2, &ratios_n, &ratios_p, .{
        .residue_microbial_fraction = 0.25,
        .humus_microbial_half_saturation_g_c_per_megagram = 25_000,
        .depth_partition_factor = 0.5,
        .microbial_budget_fraction = &budget,
        .residue_budget_fraction = &residue_budget,
        .dissolved_budget_fraction = &dissolved_budget,
        .adsorbed_budget_fraction = &adsorbed_budget,
        .microbial_kinetic_fraction = &kinetic,
        .microbial_nitrogen_to_carbon = &microbial_n,
        .microbial_phosphorus_to_carbon = &microbial_p,
        .residue_nitrogen_to_carbon = &ratios_n,
        .residue_phosphorus_to_carbon = &ratios_p,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 98.4251968503937), derived.microbial_carbon_g_c[3], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 393.7007874015748), derived.microbial_carbon_g_c[4], 1.0e-12);
    try std.testing.expectEqual(derived.carbon_allocation_fraction[0], derived.carbon_allocation_fraction[4]);
    try std.testing.expect(derived.carbon_allocation_fraction[0] > 0 and derived.carbon_allocation_fraction[0] <= 1);
}

test "mapped STARTS organic initialization uses runtime profile selection and geometry" {
    const allocator = std.testing.allocator;
    const soil_profile = @import("../../state/soil_profile.zig");
    const fixture = try @import("../../core/test_fixtures.zig").soilProfileSource(allocator, @typeInfo(soil_profile.LayerProperty).@"enum".fields.len);
    defer allocator.free(fixture);
    var catalog = @import("../profile/catalog.zig").Catalog.init(allocator);
    defer catalog.deinit();
    _ = try catalog.appendFromSource("soil", fixture, @import("../water/retention.zig").compatibilityParameters(), @import("../profile/derivation.zig").compatibilityParameters());
    // Exercise the now-live buried-manure path. The stock fixture intentionally
    // leaves these optional STARTS inputs at zero.
    const manure_carbon_offset = @intFromEnum(soil_profile.LayerProperty.manure_carbon_g_m2) * catalog.entries.items[0].profile.total_layer_count;
    const manure_nitrogen_offset = @intFromEnum(soil_profile.LayerProperty.manure_nitrogen_g_m2) * catalog.entries.items[0].profile.total_layer_count;
    const manure_phosphorus_offset = @intFromEnum(soil_profile.LayerProperty.manure_phosphorus_g_m2) * catalog.entries.items[0].profile.total_layer_count;
    catalog.entries.items[0].profile.layer_properties[manure_carbon_offset] = 100;
    catalog.entries.items[0].profile.layer_properties[manure_nitrogen_offset] = 10;
    catalog.entries.items[0].profile.layer_properties[manure_phosphorus_offset] = 1;
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1.0e-8, .absolute_tolerance = 1.0e-11, .max_nonlinear_iterations = 20 });
    var grid = try GridState.init(allocator, config);
    defer grid.deinit();
    try @import("../../driver/model_initialization.zig").initializeCellHydrology(&grid, 0, catalog.entries.items[0].hydrology_per_m2);
    var properties = try SoilProperties.initMapped(allocator, &grid, catalog.entries.items, &.{0}, &.{1}, &.{1}, @import("../water/solver_properties.zig").compatibilityParameters());
    defer properties.deinit();
    var state = try State.init(allocator, grid.layer_count);
    defer state.deinit();
    const budget = [_]f64{0.01} ** substrate_count;
    const residue_budget = [_]f64{0.25} ** substrate_count;
    const dissolved_budget = [_]f64{0.005} ** substrate_count;
    const adsorbed_budget = [_]f64{0.05} ** substrate_count;
    const microbial_kinetic = [_]f64{0.01} ** (substrate_count * kinetic_fraction_count);
    const residue_fraction = [_]f64{0.01} ** (substrate_count * residue_fraction_count);
    const heterotroph = [_]f64{1.0 / 7.0} ** microbial_population_count;
    const autotroph = [_]f64{0} ** microbial_population_count;
    const microbial_n = [_]f64{0.1} ** (substrate_count * microbial_population_count * kinetic_fraction_count);
    const microbial_p = [_]f64{0.01} ** (substrate_count * microbial_population_count * kinetic_fraction_count);
    const default_n = [_]f64{ 0.0333, 0.0333, 0.0333, 0.05, 0.167 };
    const default_p = [_]f64{ 0.00333, 0.00333, 0.00333, 0.005, 0.0167 };
    const residue_structural = [_]f64{0.2} ** (3 * structural_fraction_count);
    const manure_structural = [_]f64{ 0.036, 0.044, 0.630, 0.290, 0, 0.138, 0.401, 0.316, 0.145, 0 };
    const particulate_structural = [_]f64{ 1, 0, 0, 0, 0 };
    const depth = [_]f64{1};
    const mapped_parameters: MappedRuntimeParameters = .{
        .pool_allocation = .{
            .microbial_kinetic_fraction = &microbial_kinetic,
            .residue_fraction = &residue_fraction,
            .dissolved_fraction = &dissolved_budget,
            .adsorbed_fraction = &adsorbed_budget,
            .heterotroph_population_fraction = &heterotroph,
            .autotroph_population_fraction = &autotroph,
            .microbial_nitrogen_to_carbon = &microbial_n,
            .microbial_phosphorus_to_carbon = &microbial_p,
        },
        .microbial_derivation = .{
            .residue_microbial_fraction = 0.25,
            .humus_microbial_half_saturation_g_c_per_megagram = 25_000,
            .depth_partition_factor = 0,
            .microbial_budget_fraction = &budget,
            .residue_budget_fraction = &residue_budget,
            .dissolved_budget_fraction = &dissolved_budget,
            .adsorbed_budget_fraction = &adsorbed_budget,
            .microbial_kinetic_fraction = &microbial_kinetic,
            .microbial_nitrogen_to_carbon = &microbial_n,
            .microbial_phosphorus_to_carbon = &microbial_p,
            .residue_nitrogen_to_carbon = &default_n,
            .residue_phosphorus_to_carbon = &default_p,
        },
        .depth_partition_factor_by_layer = &depth,
        .wetland_layer_by_layer = &.{false},
        .default_complex_nitrogen_to_carbon = &default_n,
        .default_complex_phosphorus_to_carbon = &default_p,
        .residue_structural_fraction = &residue_structural,
        .manure_structural_fraction_by_type = &manure_structural,
        .particulate_structural_fraction = &particulate_structural,
        .less_resistant_humus_fraction_at_surface = 0.2,
        .nutrient_protection_exponent = 5,
        .phosphorus_nutrient_weight = 10,
    };
    // The fixture header selects IXTYP(2)=2 (non-ruminant).
    try state.initializeMapped(&grid, &properties, catalog.entries.items, &.{0}, &.{1}, &.{1}, mapped_parameters);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved[3].carbon_g_c);
    try std.testing.expect(state.dissolved[4].carbon_g_c > 0);
    try std.testing.expectEqual(@as(f64, 0), state.dissolved[4].nitrogen_g_n);
    try std.testing.expect(state.structural[4 * structural_fraction_count].carbon_g_c > 0);
    const non_ruminant = state.structural[2 * structural_fraction_count ..][0..structural_fraction_count];
    var non_ruminant_total: f64 = 0;
    for (non_ruminant) |pool| non_ruminant_total += pool.carbon_g_c;
    try std.testing.expect(non_ruminant_total > 0);
    for (non_ruminant, manure_structural[structural_fraction_count..]) |pool, expected_fraction|
        try std.testing.expectApproxEqAbs(expected_fraction, pool.carbon_g_c / non_ruminant_total, 1.0e-15);

    // STARTS maps IXTYP(2)=1 to the ruminant row and every other value to the
    // non-ruminant/OTHER row. Prove the mapping reaches the actual mineral
    // structural pools, not merely the selector helper.
    var alternate_state = try State.init(allocator, grid.layer_count);
    defer alternate_state.deinit();
    catalog.entries.items[0].profile.surface_manure_type = 1;
    try alternate_state.initializeMapped(&grid, &properties, catalog.entries.items, &.{0}, &.{1}, &.{1}, mapped_parameters);
    const ruminant = alternate_state.structural[2 * structural_fraction_count ..][0..structural_fraction_count];
    var ruminant_total: f64 = 0;
    for (ruminant) |pool| ruminant_total += pool.carbon_g_c;
    try std.testing.expect(ruminant_total > 0);
    for (ruminant, manure_structural[0..structural_fraction_count]) |pool, expected_fraction|
        try std.testing.expectApproxEqAbs(expected_fraction, pool.carbon_g_c / ruminant_total, 1.0e-15);

    catalog.entries.items[0].profile.surface_manure_type = 99;
    try alternate_state.initializeMapped(&grid, &properties, catalog.entries.items, &.{0}, &.{1}, &.{1}, mapped_parameters);
    const other = alternate_state.structural[2 * structural_fraction_count ..][0..structural_fraction_count];
    var other_total: f64 = 0;
    for (other) |pool| other_total += pool.carbon_g_c;
    try std.testing.expect(other_total > 0);
    for (other, manure_structural[structural_fraction_count..]) |pool, expected_fraction|
        try std.testing.expectApproxEqAbs(expected_fraction, pool.carbon_g_c / other_total, 1.0e-15);
    var mapped_depth: [1]f64 = undefined;
    var mapped_wetland: [1]bool = undefined;
    try deriveMappedDepthPartition(allocator, &grid, &properties, catalog.entries.items, &.{0}, &.{1}, &.{1}, &.{0}, 0, &.{10}, &.{0}, .{
        .reference_accumulation_fraction = 0.25,
        .maximum_reference_humus_g_c_per_m2 = 5000,
        .fraction_at_reference_accumulation = 0.5,
    }, &mapped_depth, &mapped_wetland);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0625), mapped_depth[0], 1.0e-15);
    try std.testing.expect(!mapped_wetland[0]);
    // A water table at the surface switches this layer to the source wetland
    // branch, whose LOG(1) depth exponent leaves the factor at one, and whose
    // FC0 nutrient-protection exponential the source disables (SOIL-HUMPART-001).
    try deriveMappedDepthPartition(allocator, &grid, &properties, catalog.entries.items, &.{0}, &.{1}, &.{1}, &.{0}, 0, &.{0}, &.{0}, .{
        .reference_accumulation_fraction = 0.25,
        .maximum_reference_humus_g_c_per_m2 = 5000,
        .fraction_at_reference_accumulation = 0.5,
    }, &mapped_depth, &mapped_wetland);
    try std.testing.expectEqual(@as(f64, 1), mapped_depth[0]);
    try std.testing.expect(mapped_wetland[0]);

    const surface_woody = [_]f64{ 0, 0.045, 0.660, 0.295, 0 };
    const surface_plants = [_]f64{0.2} ** (12 * structural_fraction_count);
    const surface_nitrogen_weight = [_]f64{0.02} ** (3 * structural_fraction_count);
    const surface_phosphorus_weight = [_]f64{0.002} ** (3 * structural_fraction_count);
    try state.initializeMappedSurface(catalog.entries.items, &.{0}, &.{1}, &.{1}, .{
        .pool_allocation = .{
            .microbial_kinetic_fraction = &microbial_kinetic,
            .residue_fraction = &residue_fraction,
            .dissolved_fraction = &dissolved_budget,
            .adsorbed_fraction = &adsorbed_budget,
            .heterotroph_population_fraction = &heterotroph,
            .autotroph_population_fraction = &autotroph,
            .microbial_nitrogen_to_carbon = &microbial_n,
            .microbial_phosphorus_to_carbon = &microbial_p,
        },
        .residue_microbial_fraction = 0.25,
        .default_complex_nitrogen_to_carbon = &default_n,
        .default_complex_phosphorus_to_carbon = &default_p,
        .woody_structural_fraction = &surface_woody,
        .plant_structural_fraction_by_type = &surface_plants,
        .manure_structural_fraction_by_type = &manure_structural,
        .residue_nitrogen_weight = &surface_nitrogen_weight,
        .residue_phosphorus_weight = &surface_phosphorus_weight,
    });
    try std.testing.expectEqual(@as(f64, 0), state.dissolved[0].carbon_g_c);
    var woody_structural_carbon: f64 = 0;
    for (state.structural[0..structural_fraction_count]) |pool| woody_structural_carbon += pool.carbon_g_c;
    try std.testing.expectApproxEqAbs(@as(f64, 21.835), woody_structural_carbon, 1.0e-12);
    try std.testing.expectApproxEqAbs(state.structural[0].carbon_g_c * microbial_kinetic[0], state.colonized_structural_carbon_g_c[0], 1.0e-15);
}

test "STARTS buried manure uses site manure type kinetic partition" {
    const fractions = [_]f64{ 0.036, 0.044, 0.630, 0.290, 0, 0.138, 0.401, 0.316, 0.145, 0 };
    try std.testing.expectEqualSlices(
        f64,
        fractions[0..structural_fraction_count],
        manureStructuralFraction(1, &fractions),
    );
    try std.testing.expectEqualSlices(
        f64,
        fractions[structural_fraction_count..],
        manureStructuralFraction(2, &fractions),
    );
}

test "STARTS humus owner distinguishes dryland wetland and reconstructed arms" {
    const surface_fraction: f64 = 0.20;
    const nutrient_ratio: f64 = 0.09;
    const dryland = lessResistantHumusFraction(
        surface_fraction,
        5,
        nutrient_ratio,
        0.5,
        false,
    );
    const wetland = lessResistantHumusFraction(
        surface_fraction,
        5,
        nutrient_ratio,
        1,
        true,
    );
    const reconstructed = lessResistantHumusFraction(
        surface_fraction,
        5,
        nutrient_ratio,
        1,
        false,
    );
    try std.testing.expectApproxEqAbs(
        surface_fraction * @exp(-5 * nutrient_ratio) * 0.5,
        dryland,
        1e-15,
    );
    try std.testing.expectEqual(surface_fraction, wetland);
    try std.testing.expectApproxEqAbs(
        surface_fraction * @exp(-5 * nutrient_ratio),
        reconstructed,
        1e-15,
    );
    try std.testing.expect(wetland > reconstructed);
}

test "STARTS natural dryland humus depth partition uses midpoint accumulation" {
    const humus = [_]f64{ 1000, 2000, 3000 };
    var factors: [3]f64 = undefined;
    try deriveNaturalDrylandDepthPartition(&humus, 10, 2, .{
        .reference_accumulation_fraction = 0.25,
        .maximum_reference_humus_g_c_per_m2 = 5000,
        .fraction_at_reference_accumulation = 0.5,
    }, &factors);
    // Midpoint accumulations are 50, 200 and 450 g C m-2; the reference is
    // 0.25 * 450, so the bottom midpoint is 0.5^4.
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pow(f64, 0.5, 50.0 / 112.5)), factors[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0625), factors[2], 1.0e-15);
    try std.testing.expect(factors[0] > factors[1] and factors[1] > factors[2]);
}

test "STARTS organic carrier is mineral mass where a matrix exists" {
    // starts.f:1297 IF(BKVL.GT.ZEROS) -> OSCI(K)=CORGCX(K)*BKVL
    const carrier = try selectOrganicCarrier(12.5, 40.0, 0);
    try std.testing.expect(carrier.mineral_matrix_present);
    try std.testing.expectEqual(@as(f64, 12.5), carrier.amount);
}

test "STARTS organic carrier falls to total layer volume for a ponded layer" {
    // starts.f:1301 ELSE -> OSCI(K)=CORGCX(K)*VOLT. This is the
    // Meditteranean Pond CA case: bulk_density 0.00 in the upper layers is the
    // correct physical statement that they are open water, so the layer is
    // carried on volume. Before this owner existed the layer was REJECTED with
    // InvalidOrganicInitializationParameter.
    const carrier = try selectOrganicCarrier(0, 40.0, 0);
    try std.testing.expect(!carrier.mineral_matrix_present);
    try std.testing.expectEqual(@as(f64, 40.0), carrier.amount);
}

test "STARTS organic carrier honours the runtime ZEROS mineral-mass floor" {
    // The source test is against ZEROS, not against exact zero, so a mass at or
    // below the floor takes the volume branch. This pins the comparison as
    // strictly-greater, matching the `IF(...GT...)` semantics.
    const below = try selectOrganicCarrier(0.5, 40.0, 1.0);
    try std.testing.expect(!below.mineral_matrix_present);
    const at = try selectOrganicCarrier(1.0, 40.0, 1.0);
    try std.testing.expect(!at.mineral_matrix_present);
    const above = try selectOrganicCarrier(1.5, 40.0, 1.0);
    try std.testing.expect(above.mineral_matrix_present);
    try std.testing.expectEqual(@as(f64, 1.5), above.amount);
}

test "STARTS organic carrier still rejects a layer with neither mass nor volume" {
    // The correction must not become a blanket relaxation. A layer with no
    // mineral matrix AND no volume carries nothing, so no concentration can be
    // made extensive against it and it stays a hard error.
    try std.testing.expectError(error.InvalidOrganicInitializationParameter, selectOrganicCarrier(0, 0, 0));
    try std.testing.expectError(error.InvalidOrganicInitializationParameter, selectOrganicCarrier(-1, 40, 0));
    try std.testing.expectError(error.InvalidOrganicInitializationParameter, selectOrganicCarrier(1, std.math.nan(f64), 0));
}

test "deriveMineralAllocations accepts a volume-carried ponded layer" {
    // The end-to-end statement of the defect. `deriveMineralAllocations` holds
    // the predicate that rejected the pond. With the carrier selected per
    // STARTS, a ponded layer reaches it with a positive volume-based carrier and
    // is accepted, producing finite allocations. This assertion is what fails if
    // the guard is restored to rejecting a zero mineral mass.
    var initial = [_]ElementPool{.{}} ** substrate_count;
    initial[3] = .{ .carbon_g_c = 400, .nitrogen_g_n = 40, .phosphorus_g_p = 4 };
    initial[4] = .{ .carbon_g_c = 1600, .nitrogen_g_n = 160, .phosphorus_g_p = 16 };
    const ratios_n = [_]f64{ 0.1, 0.1, 0.1, 0.1, 0.1 };
    const ratios_p = [_]f64{ 0.01, 0.01, 0.01, 0.01, 0.01 };
    const carrier = try selectOrganicCarrier(0, 40.0, 0);
    const derived = try deriveMineralAllocations(&initial, carrier.amount, &ratios_n, &ratios_p, .{
        .residue_microbial_fraction = 0.01,
        .humus_microbial_half_saturation_g_c_per_megagram = 100,
        .depth_partition_factor = 1,
        .microbial_budget_fraction = &.{ 0.1, 0.1, 0.1, 0.1, 0.1 },
        .residue_budget_fraction = &.{ 0.1, 0.1, 0.1, 0.1, 0.1 },
        .dissolved_budget_fraction = &.{ 0.1, 0.1, 0.1, 0.1, 0.1 },
        .adsorbed_budget_fraction = &.{ 0.1, 0.1, 0.1, 0.1, 0.1 },
        .microbial_kinetic_fraction = &(.{0.1} ** (substrate_count * kinetic_fraction_count)),
        .microbial_nitrogen_to_carbon = &(.{0.1} ** (substrate_count * microbial_population_count * kinetic_fraction_count)),
        .microbial_phosphorus_to_carbon = &(.{0.01} ** (substrate_count * microbial_population_count * kinetic_fraction_count)),
        .residue_nitrogen_to_carbon = &ratios_n,
        .residue_phosphorus_to_carbon = &ratios_p,
    });
    for (derived.microbial_carbon_g_c) |value| try std.testing.expect(std.math.isFinite(value) and value >= 0);
    // The humus microbial seed is strictly positive, so the ponded layer is
    // genuinely initialized rather than accepted-but-empty.
    try std.testing.expect(derived.microbial_carbon_g_c[4] > 0);
}

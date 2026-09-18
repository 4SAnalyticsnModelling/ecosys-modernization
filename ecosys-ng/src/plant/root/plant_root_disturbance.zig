const std = @import("std");
const Symbiosis = @import("../../canopy/symbiosis/plant_symbiotic_fixation.zig");
const LitterPartition = @import("../partition/litter.zig");
const RootMetabolism = @import("plant_root_metabolism.zig");
const RootSystem = @import("plant_root_system.zig");

pub const CombustionParameters = struct {
    minimum_combustion_temperature_k: f64,
    maximum_arrhenius_response: f64,
    gas_constant_j_per_mol_k: f64,
    activation_energy_j_per_mol: f64,
    arrhenius_intercept: f64,
    mobile_and_leaf_specific_combustion_g_c_per_m2_h: f64,
    nonwoody_structural_specific_combustion_g_c_per_m2_h: f64,
    root_structural_specific_combustion_g_c_per_m2_h: f64,
    woody_structural_specific_combustion_g_c_per_m2_h: f64,
    standing_dead_specific_combustion_g_c_per_m2_h: f64,
    charcoal_activation_energy_j_per_mol: f64,
    charcoal_arrhenius_intercept: f64,
    charcoal_specific_combustion_g_c_per_m2_h: f64,
    oxygen_g_per_g_combusted_carbon: f64,
    maximum_aerobic_charcoal_fraction: f64,
    maximum_anaerobic_charcoal_fraction: f64,
    oxygen_half_saturation_umol_per_mol: f64,
    methane_half_saturation_umol_per_mol: f64,
    aerobic_combustion_energy_megajoules_per_g_c: f64,
    anaerobic_combustion_energy_megajoules_per_g_c: f64,
    methane_combustion_energy_megajoules_per_g_c: f64,

    pub fn validate(self: CombustionParameters) !void {
        inline for (@typeInfo(CombustionParameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value)) return error.InvalidPlantFireCombustionParameter;
            if (comptime std.mem.startsWith(u8, field.name, "maximum_") and std.mem.endsWith(u8, field.name, "_charcoal_fraction")) {
                if (value < 0 or value > 1) return error.InvalidPlantFireCombustionParameter;
            } else if (value <= 0) return error.InvalidPlantFireCombustionParameter;
        }
    }
};

pub fn sourceCombustionParameters() CombustionParameters {
    return .{
        .minimum_combustion_temperature_k = 473.15,
        .maximum_arrhenius_response = 2,
        .gas_constant_j_per_mol_k = 8.3143,
        .activation_energy_j_per_mol = 60_000,
        .arrhenius_intercept = 12.028,
        .mobile_and_leaf_specific_combustion_g_c_per_m2_h = 1_000,
        .nonwoody_structural_specific_combustion_g_c_per_m2_h = 1_000,
        .root_structural_specific_combustion_g_c_per_m2_h = 1_000,
        .woody_structural_specific_combustion_g_c_per_m2_h = 1_000,
        .standing_dead_specific_combustion_g_c_per_m2_h = 2_500,
        .charcoal_activation_energy_j_per_mol = 120_000,
        .charcoal_arrhenius_intercept = 20.620,
        .charcoal_specific_combustion_g_c_per_m2_h = 1,
        .oxygen_g_per_g_combusted_carbon = 2.667,
        .maximum_aerobic_charcoal_fraction = 0,
        .maximum_anaerobic_charcoal_fraction = 0.5,
        .oxygen_half_saturation_umol_per_mol = 2_100,
        .methane_half_saturation_umol_per_mol = 10,
        .aerobic_combustion_energy_megajoules_per_g_c = 0.0375,
        .anaerobic_combustion_energy_megajoules_per_g_c = 0.0125,
        .methane_combustion_energy_megajoules_per_g_c = 0.0743,
    };
}

pub fn combustionFraction(total_pool_carbon_g_c: f64, soil_temperature_k: f64, cell_area_m2: f64, timestep_h: f64, specific_combustion_g_c_per_m2_h: f64, parameters: CombustionParameters) !f64 {
    try parameters.validate();
    inline for (.{ total_pool_carbon_g_c, soil_temperature_k, cell_area_m2, timestep_h, specific_combustion_g_c_per_m2_h }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootNoduleCombustionInput;
    if (soil_temperature_k <= parameters.minimum_combustion_temperature_k or total_pool_carbon_g_c == 0) return 0;
    if (cell_area_m2 <= 0 or timestep_h <= 0) return error.InvalidRootNoduleCombustionInput;
    const response = @min(parameters.maximum_arrhenius_response, @exp(parameters.arrhenius_intercept - parameters.activation_energy_j_per_mol / (parameters.gas_constant_j_per_mol_k * soil_temperature_k)));
    return @min(1, specific_combustion_g_c_per_m2_h * response * cell_area_m2 * timestep_h / total_pool_carbon_g_c);
}

pub const ElementRetention = struct {
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,

    pub fn uniform(fraction: f64) ElementRetention {
        return .{ .carbon = fraction, .nitrogen = fraction, .phosphorus = fraction };
    }

    fn validate(self: ElementRetention) !void {
        inline for (.{ self.carbon, self.nitrogen, self.phosphorus }) |fraction|
            if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidRootSymbiontRetention;
    }
};

pub const Result = struct {
    structural: Symbiosis.Pool,
    mobile: Symbiosis.Pool,
    litterfall: RootMetabolism.RootLitter,
};

pub const SourceOrderNoduleTillageResult = struct {
    applied: bool,
    structural: Symbiosis.Pool,
    mobile: Symbiosis.Pool,
    litterfall: RootMetabolism.RootLitter,
};

/// Exact GROSUB 9947 entry gate. Fortran N=1 maps to zero-based domain zero.
pub fn sourceOrderNoduleHarvestIsEnabled(
    nitrogen_fixation_type: u8,
    biological_domain: usize,
    biological_domain_count: usize,
) !bool {
    if (biological_domain_count == 0 or biological_domain >= biological_domain_count)
        return error.InvalidNoduleHarvestDomain;
    return nitrogen_fixation_type != 0 and biological_domain == 0;
}

/// Exact GROSUB 10431-10449 nodule litter and retained state during tillage.
pub fn sourceOrderNoduleTillage(
    nitrogen_fixation_type: u8,
    biological_domain: usize,
    biological_domain_count: usize,
    structural: Symbiosis.Pool,
    mobile: Symbiosis.Pool,
    remaining_fraction: f64,
    fine_root_litter: LitterPartition.ElementFractions,
    nonstructural_litter: LitterPartition.ElementFractions,
) !SourceOrderNoduleTillageResult {
    try validatePool(structural);
    try validatePool(mobile);
    if (!std.math.isFinite(remaining_fraction) or remaining_fraction < 0 or remaining_fraction > 1)
        return error.InvalidRootSymbiontRetention;
    try fine_root_litter.validate();
    try nonstructural_litter.validate();
    if (!try sourceOrderNoduleHarvestIsEnabled(
        nitrogen_fixation_type,
        biological_domain,
        biological_domain_count,
    )) return .{
        .applied = false,
        .structural = structural,
        .mobile = mobile,
        .litterfall = std.mem.zeroes(RootMetabolism.RootLitter),
    };
    const result = try retainAndRelease(
        structural,
        mobile,
        ElementRetention.uniform(remaining_fraction),
        fine_root_litter,
        nonstructural_litter,
    );
    return .{
        .applied = true,
        .structural = result.structural,
        .mobile = result.mobile,
        .litterfall = result.litterfall,
    };
}

pub const HostHarvestResult = struct {
    removed: Symbiosis.Pool,
    litterfall: RootMetabolism.RootLitter,
};

pub const HostAxisHarvestState = struct {
    primary: Symbiosis.Pool,
    secondary: Symbiosis.Pool,
    total_primary: Symbiosis.Pool,
    primary_length_m: f64,
    secondary_length_m: f64,
    secondary_axis_count: f64,
};

pub const HostLayerHarvestState = struct {
    mobile: Symbiosis.Pool,
    active_root_carbon_g_c: f64,
    actual_root_carbon_g_c: f64,
    protein_mass_g: f64,
    primary_axis_count: f64,
    total_root_axis_count: f64,
    root_length_m_per_plant: f64,
    root_length_density_m_per_m3: f64,
    gaseous_volume_m3: f64,
    aqueous_volume_m3: f64,
    root_surface_area_m2_per_plant: f64,
    respiration_unlimited_by_oxygen_g_c_per_h: f64,
    respiration_unlimited_by_carbon_g_c_per_h: f64,
    actual_respiration_g_c_per_h: f64,
};

pub const ScaledHostHarvestState = struct {
    axis: HostAxisHarvestState,
    layer: HostLayerHarvestState,
};

/// Exact GROSUB 9905-9934 proportional root-state transform for one axis/layer.
pub fn sourceOrderScaleHostHarvestState(
    axis: HostAxisHarvestState,
    layer: HostLayerHarvestState,
    retention: ElementRetention,
) !ScaledHostHarvestState {
    try validatePool(axis.primary);
    try validatePool(axis.secondary);
    try validatePool(axis.total_primary);
    try validatePool(layer.mobile);
    try retention.validate();
    inline for (.{
        axis.primary_length_m,
        axis.secondary_length_m,
        axis.secondary_axis_count,
        layer.active_root_carbon_g_c,
        layer.actual_root_carbon_g_c,
        layer.protein_mass_g,
        layer.primary_axis_count,
        layer.total_root_axis_count,
        layer.root_length_m_per_plant,
        layer.root_length_density_m_per_m3,
        layer.gaseous_volume_m3,
        layer.aqueous_volume_m3,
        layer.root_surface_area_m2_per_plant,
        layer.respiration_unlimited_by_oxygen_g_c_per_h,
        layer.respiration_unlimited_by_carbon_g_c_per_h,
        layer.actual_respiration_g_c_per_h,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidHostRootHarvestState;
    const carbon = retention.carbon;
    return .{
        .axis = .{
            .primary = scalePool(axis.primary, retention),
            .secondary = scalePool(axis.secondary, retention),
            // GROSUB RTWT1N/RTWT1P deliberately use XHVST at 9913-9914.
            .total_primary = scalePoolUniform(axis.total_primary, carbon),
            .primary_length_m = axis.primary_length_m * carbon,
            .secondary_length_m = axis.secondary_length_m * carbon,
            .secondary_axis_count = axis.secondary_axis_count * carbon,
        },
        .layer = .{
            .mobile = scalePool(layer.mobile, retention),
            .active_root_carbon_g_c = layer.active_root_carbon_g_c * carbon,
            .actual_root_carbon_g_c = layer.actual_root_carbon_g_c * carbon,
            .protein_mass_g = layer.protein_mass_g * carbon,
            .primary_axis_count = layer.primary_axis_count * carbon,
            .total_root_axis_count = layer.total_root_axis_count * carbon,
            .root_length_m_per_plant = layer.root_length_m_per_plant * carbon,
            .root_length_density_m_per_m3 = layer.root_length_density_m_per_m3 * carbon,
            .gaseous_volume_m3 = layer.gaseous_volume_m3 * carbon,
            .aqueous_volume_m3 = layer.aqueous_volume_m3 * carbon,
            .root_surface_area_m2_per_plant = layer.root_surface_area_m2_per_plant * carbon,
            .respiration_unlimited_by_oxygen_g_c_per_h = layer.respiration_unlimited_by_oxygen_g_c_per_h * carbon,
            .respiration_unlimited_by_carbon_g_c_per_h = layer.respiration_unlimited_by_carbon_g_c_per_h * carbon,
            .actual_respiration_g_c_per_h = layer.actual_respiration_g_c_per_h * carbon,
        },
    };
}

/// Exact GROSUB 10389-10418 retained host-root state after tillage for one
/// runtime root axis and its owning biological-domain/layer state.
pub fn sourceOrderScaleHostTillageState(
    axis: HostAxisHarvestState,
    layer: HostLayerHarvestState,
    remaining_fraction: f64,
) !ScaledHostHarvestState {
    if (!std.math.isFinite(remaining_fraction) or remaining_fraction < 0 or remaining_fraction > 1)
        return error.InvalidHostRootTillageRetention;
    return sourceOrderScaleHostHarvestState(
        axis,
        layer,
        ElementRetention.uniform(remaining_fraction),
    );
}

fn scalePool(pool: Symbiosis.Pool, retention: ElementRetention) Symbiosis.Pool {
    return .{
        .carbon_g_c = pool.carbon_g_c * retention.carbon,
        .nitrogen_g_n = pool.nitrogen_g_n * retention.nitrogen,
        .phosphorus_g_p = pool.phosphorus_g_p * retention.phosphorus,
    };
}

fn scalePoolUniform(pool: Symbiosis.Pool, retention: f64) Symbiosis.Pool {
    return .{
        .carbon_g_c = pool.carbon_g_c * retention,
        .nitrogen_g_n = pool.nitrogen_g_n * retention,
        .phosphorus_g_p = pool.phosphorus_g_p * retention,
    };
}

/// Exact GROSUB 9806-9847 host-root litter allocation for one domain/layer.
/// Structural entries are primary-plus-secondary root C/N/P for runtime axes.
pub fn sourceOrderHostHarvestLitter(
    mobile: Symbiosis.Pool,
    structural_by_axis: []const Symbiosis.Pool,
    retention: ElementRetention,
    woody_fraction: ElementRetention,
    nonstructural_litter: LitterPartition.ElementFractions,
    fine_root_litter: LitterPartition.ElementFractions,
    coarse_root_litter: LitterPartition.ElementFractions,
) !HostHarvestResult {
    try validatePool(mobile);
    for (structural_by_axis) |structural| try validatePool(structural);
    try retention.validate();
    try woody_fraction.validate();
    try nonstructural_litter.validate();
    try fine_root_litter.validate();
    try coarse_root_litter.validate();

    const removed_mobile: Symbiosis.Pool = .{
        .carbon_g_c = (1 - retention.carbon) * mobile.carbon_g_c,
        .nitrogen_g_n = (1 - retention.nitrogen) * mobile.nitrogen_g_n,
        .phosphorus_g_p = (1 - retention.phosphorus) * mobile.phosphorus_g_p,
    };
    var result: HostHarvestResult = .{
        .removed = removed_mobile,
        .litterfall = std.mem.zeroes(RootMetabolism.RootLitter),
    };
    for (structural_by_axis) |structural| {
        result.removed.carbon_g_c += (1 - retention.carbon) * structural.carbon_g_c;
        result.removed.nitrogen_g_n += (1 - retention.nitrogen) * structural.nitrogen_g_n;
        result.removed.phosphorus_g_p += (1 - retention.phosphorus) * structural.phosphorus_g_p;
    }
    for (0..LitterPartition.kinetic_component_count) |component| {
        result.litterfall.nonwoody_carbon_g_c[component] =
            removed_mobile.carbon_g_c * nonstructural_litter.carbon[component];
        result.litterfall.nonwoody_nitrogen_g_n[component] =
            removed_mobile.nitrogen_g_n * nonstructural_litter.nitrogen[component];
        result.litterfall.nonwoody_phosphorus_g_p[component] =
            removed_mobile.phosphorus_g_p * nonstructural_litter.phosphorus[component];
        for (structural_by_axis) |structural| {
            const removed: Symbiosis.Pool = .{
                .carbon_g_c = (1 - retention.carbon) * structural.carbon_g_c,
                .nitrogen_g_n = (1 - retention.nitrogen) * structural.nitrogen_g_n,
                .phosphorus_g_p = (1 - retention.phosphorus) * structural.phosphorus_g_p,
            };
            result.litterfall.woody_carbon_g_c[component] +=
                removed.carbon_g_c * woody_fraction.carbon * coarse_root_litter.carbon[component];
            result.litterfall.woody_nitrogen_g_n[component] +=
                removed.nitrogen_g_n * woody_fraction.nitrogen * coarse_root_litter.nitrogen[component];
            result.litterfall.woody_phosphorus_g_p[component] +=
                removed.phosphorus_g_p * woody_fraction.phosphorus * coarse_root_litter.phosphorus[component];
            result.litterfall.nonwoody_carbon_g_c[component] +=
                removed.carbon_g_c * (1 - woody_fraction.carbon) * fine_root_litter.carbon[component];
            result.litterfall.nonwoody_nitrogen_g_n[component] +=
                removed.nitrogen_g_n * (1 - woody_fraction.nitrogen) * fine_root_litter.nitrogen[component];
            result.litterfall.nonwoody_phosphorus_g_p[component] +=
                removed.phosphorus_g_p * (1 - woody_fraction.phosphorus) * fine_root_litter.phosphorus[component];
        }
    }
    inline for (@typeInfo(Symbiosis.Pool).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result.removed, field.name))) return error.NonFiniteHostRootHarvest;
    return result;
}

/// Exact GROSUB 10305-10333 host-root litter allocation during tillage for
/// one biological domain and soil layer over all runtime root axes.
pub fn sourceOrderHostTillageLitter(
    mobile: Symbiosis.Pool,
    structural_by_axis: []const Symbiosis.Pool,
    remaining_fraction: f64,
    woody_fraction: ElementRetention,
    nonstructural_litter: LitterPartition.ElementFractions,
    fine_root_litter: LitterPartition.ElementFractions,
    coarse_root_litter: LitterPartition.ElementFractions,
) !HostHarvestResult {
    if (!std.math.isFinite(remaining_fraction) or remaining_fraction < 0 or remaining_fraction > 1)
        return error.InvalidHostRootTillageRetention;
    return sourceOrderHostHarvestLitter(
        mobile,
        structural_by_axis,
        ElementRetention.uniform(remaining_fraction),
        woody_fraction,
        nonstructural_litter,
        fine_root_litter,
        coarse_root_litter,
    );
}

pub const CombustionResult = struct {
    structural: Symbiosis.Pool,
    mobile: Symbiosis.Pool,
    emitted: Symbiosis.Pool,
};

/// GROSUB RCPOOLN/RWTNDL transaction. Mobile and structural nodule pools have
/// separate source-derived combustion fractions.
pub fn combustSymbiont(
    structural: Symbiosis.Pool,
    mobile: Symbiosis.Pool,
    structural_combustion_fraction: f64,
    mobile_combustion_fraction: f64,
) !CombustionResult {
    try validatePool(structural);
    try validatePool(mobile);
    inline for (.{ structural_combustion_fraction, mobile_combustion_fraction }) |fraction|
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidRootSymbiontCombustionFraction;
    const structural_burned: Symbiosis.Pool = .{
        .carbon_g_c = structural.carbon_g_c * structural_combustion_fraction,
        .nitrogen_g_n = structural.nitrogen_g_n * structural_combustion_fraction,
        .phosphorus_g_p = structural.phosphorus_g_p * structural_combustion_fraction,
    };
    const mobile_burned: Symbiosis.Pool = .{
        .carbon_g_c = mobile.carbon_g_c * mobile_combustion_fraction,
        .nitrogen_g_n = mobile.nitrogen_g_n * mobile_combustion_fraction,
        .phosphorus_g_p = mobile.phosphorus_g_p * mobile_combustion_fraction,
    };
    return .{
        .structural = .{
            .carbon_g_c = structural.carbon_g_c - structural_burned.carbon_g_c,
            .nitrogen_g_n = structural.nitrogen_g_n - structural_burned.nitrogen_g_n,
            .phosphorus_g_p = structural.phosphorus_g_p - structural_burned.phosphorus_g_p,
        },
        .mobile = .{
            .carbon_g_c = mobile.carbon_g_c - mobile_burned.carbon_g_c,
            .nitrogen_g_n = mobile.nitrogen_g_n - mobile_burned.nitrogen_g_n,
            .phosphorus_g_p = mobile.phosphorus_g_p - mobile_burned.phosphorus_g_p,
        },
        .emitted = .{
            .carbon_g_c = structural_burned.carbon_g_c + mobile_burned.carbon_g_c,
            .nitrogen_g_n = structural_burned.nitrogen_g_n + mobile_burned.nitrogen_g_n,
            .phosphorus_g_p = structural_burned.phosphorus_g_p + mobile_burned.phosphorus_g_p,
        },
    };
}

/// GROSUB nodule disturbance transaction shared by harvest, tillage, and
/// complete root death. Structural bacteria use fine-root kinetics (CFOP 4);
/// bacterial mobile pools use nonstructural kinetics (CFOP 0).
pub fn retainAndRelease(
    structural: Symbiosis.Pool,
    mobile: Symbiosis.Pool,
    retention: ElementRetention,
    fine_root_litter: LitterPartition.ElementFractions,
    nonstructural_litter: LitterPartition.ElementFractions,
) !Result {
    try validatePool(structural);
    try validatePool(mobile);
    try retention.validate();
    try fine_root_litter.validate();
    try nonstructural_litter.validate();

    const structural_removed: Symbiosis.Pool = .{
        .carbon_g_c = structural.carbon_g_c * (1 - retention.carbon),
        .nitrogen_g_n = structural.nitrogen_g_n * (1 - retention.nitrogen),
        .phosphorus_g_p = structural.phosphorus_g_p * (1 - retention.phosphorus),
    };
    const mobile_removed: Symbiosis.Pool = .{
        .carbon_g_c = mobile.carbon_g_c * (1 - retention.carbon),
        .nitrogen_g_n = mobile.nitrogen_g_n * (1 - retention.nitrogen),
        .phosphorus_g_p = mobile.phosphorus_g_p * (1 - retention.phosphorus),
    };
    var litterfall = std.mem.zeroes(RootMetabolism.RootLitter);
    for (0..LitterPartition.kinetic_component_count) |component| {
        litterfall.nonwoody_carbon_g_c[component] =
            structural_removed.carbon_g_c * fine_root_litter.carbon[component] +
            mobile_removed.carbon_g_c * nonstructural_litter.carbon[component];
        litterfall.nonwoody_nitrogen_g_n[component] =
            structural_removed.nitrogen_g_n * fine_root_litter.nitrogen[component] +
            mobile_removed.nitrogen_g_n * nonstructural_litter.nitrogen[component];
        litterfall.nonwoody_phosphorus_g_p[component] =
            structural_removed.phosphorus_g_p * fine_root_litter.phosphorus[component] +
            mobile_removed.phosphorus_g_p * nonstructural_litter.phosphorus[component];
    }
    return .{
        .structural = .{
            .carbon_g_c = structural.carbon_g_c * retention.carbon,
            .nitrogen_g_n = structural.nitrogen_g_n * retention.nitrogen,
            .phosphorus_g_p = structural.phosphorus_g_p * retention.phosphorus,
        },
        .mobile = .{
            .carbon_g_c = mobile.carbon_g_c * retention.carbon,
            .nitrogen_g_n = mobile.nitrogen_g_n * retention.nitrogen,
            .phosphorus_g_p = mobile.phosphorus_g_p * retention.phosphorus,
        },
        .litterfall = litterfall,
    };
}

const root_gas_fields = .{
    .{ "gaseous_carbon_dioxide_g_c", "aqueous_carbon_dioxide_g_c", "withdrawal_carbon_dioxide_loss_g_c_per_h", "withdrawal_carbon_dioxide_loss_g_c_per_h_by_root" },
    .{ "gaseous_oxygen_g_o", "aqueous_oxygen_g_o", "withdrawal_oxygen_loss_g_o_per_h", "withdrawal_oxygen_loss_g_o_per_h_by_root" },
    .{ "gaseous_methane_g_c", "aqueous_methane_g_c", "withdrawal_methane_loss_g_c_per_h", "withdrawal_methane_loss_g_c_per_h_by_root" },
    .{ "gaseous_nitrous_oxide_g_n", "aqueous_nitrous_oxide_g_n", "withdrawal_nitrous_oxide_loss_g_n_per_h", "withdrawal_nitrous_oxide_loss_g_n_per_h_by_root" },
    .{ "gaseous_ammonia_g_n", "aqueous_ammonia_g_n", "withdrawal_ammonia_loss_g_n_per_h", "withdrawal_ammonia_loss_g_n_per_h_by_root" },
    .{ "gaseous_hydrogen_g_h", "aqueous_hydrogen_g_h", "withdrawal_hydrogen_loss_g_h_per_h", "withdrawal_hydrogen_loss_g_h_per_h_by_root" },
};

/// GROSUB harvest/tillage release of gaseous plus aqueous root contents.
/// Source RCO2Z/ROXYZ/RCH4Z/RN2OZ/RNH3Z/RH2GZ signs are retained: release is
/// accumulated as a negative plant loss while both root phases are reduced.
pub fn validateRootGasRelease(roots: *const RootSystem.State, plant: usize, layer: usize, removed_fraction: f64) !void {
    if (plant >= roots.plant_count or layer >= roots.soil_layer_count or !std.math.isFinite(removed_fraction) or removed_fraction < 0 or removed_fraction > 1) return error.InvalidRootGasRelease;
    inline for (root_gas_fields) |fields| {
        const gaseous = @field(roots, fields[0]);
        const aqueous = @field(roots, fields[1]);
        const loss = @field(roots, fields[2]);
        const loss_by_root = @field(roots, fields[3]);
        var removed: f64 = 0;
        for (0..RootSystem.biological_domain_count) |domain| {
            const root = try roots.layerIndex(plant, domain, layer);
            if (!std.math.isFinite(gaseous[root]) or gaseous[root] < 0 or !std.math.isFinite(aqueous[root]) or aqueous[root] < 0) return error.InvalidRootGasRelease;
            const local_removed = removed_fraction * (gaseous[root] + aqueous[root]);
            if (!std.math.isFinite(loss_by_root[root] - local_removed)) return error.NonFiniteRootGasRelease;
            removed += local_removed;
        }
        if (!std.math.isFinite(loss[plant] - removed)) return error.NonFiniteRootGasRelease;
    }
}

pub fn releaseRootGasFraction(roots: *RootSystem.State, plant: usize, layer: usize, removed_fraction: f64) !void {
    try validateRootGasRelease(roots, plant, layer, removed_fraction);
    inline for (root_gas_fields) |fields| {
        const gaseous = @field(roots, fields[0]);
        const aqueous = @field(roots, fields[1]);
        const loss = @field(roots, fields[2]);
        const loss_by_root = @field(roots, fields[3]);
        var removed: f64 = 0;
        for (0..RootSystem.biological_domain_count) |domain| {
            const root = try roots.layerIndex(plant, domain, layer);
            const local_removed = removed_fraction * (gaseous[root] + aqueous[root]);
            removed += local_removed;
            loss_by_root[root] -= local_removed;
            gaseous[root] *= 1 - removed_fraction;
            aqueous[root] *= 1 - removed_fraction;
        }
        loss[plant] -= removed;
    }
}

/// Exact GROSUB 10345-10368 six-gas, two-phase root release during tillage.
pub fn sourceOrderTillageRootGasRelease(
    roots: *RootSystem.State,
    plant: usize,
    layer: usize,
    remaining_fraction: f64,
) !void {
    if (!std.math.isFinite(remaining_fraction) or remaining_fraction < 0 or remaining_fraction > 1)
        return error.InvalidRootGasRelease;
    try releaseRootGasFraction(roots, plant, layer, 1 - remaining_fraction);
}

pub const CellRootGasWithdrawal = struct {
    carbon_dioxide_g_c_per_h: f64 = 0,
    oxygen_g_o_per_h: f64 = 0,
    methane_g_c_per_h: f64 = 0,
    nitrous_oxide_g_n_per_h: f64 = 0,
    ammonia_g_n_per_h: f64 = 0,
    hydrogen_g_h_per_h: f64 = 0,
};

/// GROSUB 5115 (lines 7127--7292) source-order selection of layers vacated
/// after a primary tip retracts. Layer indexes are zero-based here. The
/// caller supplies output storage because the number of withdrawals is a
/// runtime grid/layer property.
pub fn selectSourceOrderWithdrawnLayers(
    current_layer: usize,
    deepest_active_layer: usize,
    planting_layer: usize,
    primary_root_depth_m: f64,
    seeding_depth_m: f64,
    minimum_layer_thickness_m: f64,
    layer_thickness_m: []const f64,
    layer_bottom_depth_m: []const f64,
    withdrawn_layers: []usize,
) !usize {
    if (layer_thickness_m.len != layer_bottom_depth_m.len or
        deepest_active_layer >= layer_thickness_m.len or
        planting_layer >= layer_thickness_m.len)
        return error.InvalidRootWithdrawalDimensions;
    inline for (.{
        primary_root_depth_m,
        seeding_depth_m,
        minimum_layer_thickness_m,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidRootWithdrawalInput;
    for (layer_thickness_m, layer_bottom_depth_m) |thickness, bottom| {
        if (!std.math.isFinite(thickness) or thickness < 0 or
            !std.math.isFinite(bottom) or bottom < 0)
            return error.InvalidRootWithdrawalInput;
    }
    if (current_layer != deepest_active_layer or deepest_active_layer <= planting_layer)
        return 0;

    var count: usize = 0;
    var source_layer = deepest_active_layer;
    while (source_layer > planting_layer) : (source_layer -= 1) {
        const destination_layer = source_layer - 1;
        if (!(layer_thickness_m[destination_layer] > minimum_layer_thickness_m and
            (primary_root_depth_m < layer_bottom_depth_m[destination_layer] or
                primary_root_depth_m < seeding_depth_m))) break;
        if (count >= withdrawn_layers.len) return error.RootWithdrawalOutputTooSmall;
        withdrawn_layers[count] = source_layer;
        count += 1;
    }
    return count;
}

/// EXTRACT aggregation of source-signed PFT R*Z ledgers into one grid cell.
pub fn rootGasWithdrawalForCell(roots: *const RootSystem.State, cell: usize, species_count: usize) !CellRootGasWithdrawal {
    if (species_count == 0 or roots.plant_count % species_count != 0 or cell >= roots.plant_count / species_count) return error.RootGasWithdrawalCellOutOfBounds;
    var result: CellRootGasWithdrawal = .{};
    for (0..species_count) |species| {
        const plant = cell * species_count + species;
        result.carbon_dioxide_g_c_per_h += roots.withdrawal_carbon_dioxide_loss_g_c_per_h[plant];
        result.oxygen_g_o_per_h += roots.withdrawal_oxygen_loss_g_o_per_h[plant];
        result.methane_g_c_per_h += roots.withdrawal_methane_loss_g_c_per_h[plant];
        result.nitrous_oxide_g_n_per_h += roots.withdrawal_nitrous_oxide_loss_g_n_per_h[plant];
        result.ammonia_g_n_per_h += roots.withdrawal_ammonia_loss_g_n_per_h[plant];
        result.hydrogen_g_h_per_h += roots.withdrawal_hydrogen_loss_g_h_per_h[plant];
    }
    inline for (@typeInfo(CellRootGasWithdrawal).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteRootGasWithdrawal;
    return result;
}

/// Exact GROSUB FRTN transfer of structural and mobile rhizobial C/N/P from a
/// withdrawing root layer to the adjacent surviving layer. All destinations
/// are validated before the six-pool transaction is published.
pub fn transferSymbiontLayerFraction(
    roots: *RootSystem.State,
    plant: usize,
    source_layer: usize,
    destination_layer: usize,
    fraction: f64,
) !void {
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidRootLayerTransferFraction;
    if (source_layer == destination_layer) return error.InvalidRootLayerTransferDirection;
    const source = try roots.layerIndex(plant, 0, source_layer);
    const destination = try roots.layerIndex(plant, 0, destination_layer);
    inline for (.{
        "symbiont_structural_carbon_g_c",
        "symbiont_structural_nitrogen_g_n",
        "symbiont_structural_phosphorus_g_p",
        "symbiont_mobile_carbon_g_c",
        "symbiont_mobile_nitrogen_g_n",
        "symbiont_mobile_phosphorus_g_p",
    }) |field_name| {
        const values = @field(roots, field_name);
        const transfer = fraction * values[source];
        const next_source = values[source] - transfer;
        const next_destination = values[destination] + transfer;
        if (!std.math.isFinite(next_source) or !std.math.isFinite(next_destination) or next_source < 0 or next_destination < 0) return error.NonFiniteRootLayerTransfer;
    }
    inline for (.{
        "symbiont_structural_carbon_g_c",
        "symbiont_structural_nitrogen_g_n",
        "symbiont_structural_phosphorus_g_p",
        "symbiont_mobile_carbon_g_c",
        "symbiont_mobile_nitrogen_g_n",
        "symbiont_mobile_phosphorus_g_p",
    }) |field_name| {
        const values = @field(roots, field_name);
        const transfer = fraction * values[source];
        values[source] -= transfer;
        values[destination] += transfer;
    }
}

/// Withdraws one complete root-axis layer after its tip retracts above the
/// layer boundary. This preserves the deliberately asymmetric GROSUB
/// 7138--7248 transaction: structural C/N/P and RTLG1 move through every
/// biological domain, RTLG2 does not move, and only host-domain RTN1/RTN2/RTNL
/// are updated. Host destination RTLG1 is then replaced by geometry formed
/// from the already-updated primary depth.
pub fn withdrawRootAxisLayer(
    roots: *RootSystem.State,
    plant: usize,
    axis: usize,
    biological_domain_count: usize,
    source_layer: usize,
    destination_layer: usize,
    sink_fraction: f64,
    seeding_depth_m: f64,
    layer_thickness_m: []const f64,
    layer_bottom_depth_m: []const f64,
) !void {
    if (!std.math.isFinite(sink_fraction) or sink_fraction < 0 or sink_fraction > 1) return error.InvalidRootLayerTransferFraction;
    if (biological_domain_count == 0 or biological_domain_count > RootSystem.biological_domain_count or
        layer_thickness_m.len != layer_bottom_depth_m.len or
        source_layer >= layer_thickness_m.len)
        return error.InvalidRootWithdrawalDimensions;
    if (source_layer == 0 or destination_layer + 1 != source_layer)
        return error.InvalidRootLayerTransferDirection;
    if (!std.math.isFinite(seeding_depth_m) or seeding_depth_m < 0)
        return error.InvalidRootWithdrawalInput;
    const planting_layer = roots.planting_layer_by_plant[plant];
    if (destination_layer < planting_layer) return error.InvalidRootWithdrawalLayerOrder;
    for (layer_thickness_m, layer_bottom_depth_m) |thickness, bottom|
        if (!std.math.isFinite(thickness) or thickness < 0 or
            !std.math.isFinite(bottom) or bottom < 0)
            return error.InvalidRootWithdrawalInput;
    const host_depth = roots.axis_depth_m[try roots.axisIndex(plant, 0, axis)];
    const host_destination_primary_length = if (destination_layer > planting_layer)
        layer_thickness_m[destination_layer] -
            (layer_bottom_depth_m[destination_layer] - host_depth)
    else
        host_depth - seeding_depth_m;
    if (!std.math.isFinite(host_destination_primary_length) or
        host_destination_primary_length < 0)
        return error.NonFiniteRootLayerTransfer;

    // Validate every domain before publishing the first mutation.
    for (0..biological_domain_count) |domain| {
        const source_root = try roots.layerIndex(plant, domain, source_layer);
        const destination_root = try roots.layerIndex(plant, domain, destination_layer);
        const source_axis = try roots.layerAxisIndex(plant, domain, source_layer, axis);
        const destination_axis = try roots.layerAxisIndex(plant, domain, destination_layer, axis);
        inline for (.{
            "axis_primary_carbon_g",
            "axis_primary_nitrogen_g",
            "axis_primary_phosphorus_g",
            "axis_secondary_carbon_g",
            "axis_secondary_nitrogen_g",
            "axis_secondary_phosphorus_g",
        }) |field_name| {
            const values = @field(roots, field_name);
            const next_destination = values[destination_axis] + values[source_axis];
            if (!std.math.isFinite(next_destination) or next_destination < 0) return error.NonFiniteRootLayerTransfer;
        }
        inline for (.{ roots.axis_primary_length_m[source_axis], roots.axis_primary_length_m[destination_axis], roots.axis_secondary_length_m[source_axis], roots.axis_secondary_length_m[destination_axis] }) |value|
            if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootLayerTransfer;
        if (domain != 0) {
            const next_primary_length = roots.axis_primary_length_m[destination_axis] + roots.axis_primary_length_m[source_axis];
            if (!std.math.isFinite(next_primary_length) or next_primary_length < 0) return error.NonFiniteRootLayerTransfer;
        }
        inline for (.{ "mobile_carbon_g", "mobile_nitrogen_g", "mobile_phosphorus_g", "protein_carbon_g" }) |field_name| {
            const values = @field(roots, field_name);
            const transfer = sink_fraction * values[source_root];
            if (!std.math.isFinite(values[source_root] - transfer) or
                !std.math.isFinite(values[destination_root] + transfer))
                return error.NonFiniteRootLayerTransfer;
        }
        inline for (.{
            .{ "gaseous_carbon_dioxide_g_c", "aqueous_carbon_dioxide_g_c", "withdrawal_carbon_dioxide_loss_g_c_per_h", "withdrawal_carbon_dioxide_loss_g_c_per_h_by_root" },
            .{ "gaseous_oxygen_g_o", "aqueous_oxygen_g_o", "withdrawal_oxygen_loss_g_o_per_h", "withdrawal_oxygen_loss_g_o_per_h_by_root" },
            .{ "gaseous_methane_g_c", "aqueous_methane_g_c", "withdrawal_methane_loss_g_c_per_h", "withdrawal_methane_loss_g_c_per_h_by_root" },
            .{ "gaseous_nitrous_oxide_g_n", "aqueous_nitrous_oxide_g_n", "withdrawal_nitrous_oxide_loss_g_n_per_h", "withdrawal_nitrous_oxide_loss_g_n_per_h_by_root" },
            .{ "gaseous_ammonia_g_n", "aqueous_ammonia_g_n", "withdrawal_ammonia_loss_g_n_per_h", "withdrawal_ammonia_loss_g_n_per_h_by_root" },
            .{ "gaseous_hydrogen_g_h", "aqueous_hydrogen_g_h", "withdrawal_hydrogen_loss_g_h_per_h", "withdrawal_hydrogen_loss_g_h_per_h_by_root" },
        }) |fields| {
            const gaseous = @field(roots, fields[0]);
            const aqueous = @field(roots, fields[1]);
            const loss = @field(roots, fields[2]);
            const loss_by_root = @field(roots, fields[3]);
            const removed = sink_fraction * (gaseous[source_root] + aqueous[source_root]);
            inline for (.{ gaseous[source_root] * (1 - sink_fraction), aqueous[source_root] * (1 - sink_fraction), loss[plant] - removed, loss_by_root[source_root] - removed }) |value|
                if (!std.math.isFinite(value)) return error.NonFiniteRootLayerTransfer;
        }
    }
    const host_source_root = try roots.layerIndex(plant, 0, source_layer);
    const host_destination_root = try roots.layerIndex(plant, 0, destination_layer);
    const host_source_axis = try roots.layerAxisIndex(plant, 0, source_layer, axis);
    const host_destination_axis = try roots.layerAxisIndex(plant, 0, destination_layer, axis);
    const host_rtn2 = roots.axis_secondary_count[host_source_axis];
    const next_source_rtnl = roots.secondary_axis_count_total[host_source_root] - host_rtn2;
    const next_destination_rtnl = roots.secondary_axis_count_total[host_destination_root] + host_rtn2;
    inline for (.{ host_rtn2, roots.axis_secondary_count[host_destination_axis], roots.axis_primary_count[host_source_axis], roots.axis_primary_count[host_destination_axis], next_source_rtnl, next_destination_rtnl }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.NonFiniteRootLayerTransfer;
    if (biological_domain_count > 0) {
        inline for (.{
            "symbiont_structural_carbon_g_c",
            "symbiont_structural_nitrogen_g_n",
            "symbiont_structural_phosphorus_g_p",
            "symbiont_mobile_carbon_g_c",
            "symbiont_mobile_nitrogen_g_n",
            "symbiont_mobile_phosphorus_g_p",
        }) |field_name| {
            const values = @field(roots, field_name);
            const transfer = sink_fraction * values[host_source_root];
            if (!std.math.isFinite(values[host_source_root] - transfer) or !std.math.isFinite(values[host_destination_root] + transfer)) return error.NonFiniteRootLayerTransfer;
        }
    }

    for (0..biological_domain_count) |domain| {
        const source_root = roots.layerIndex(plant, domain, source_layer) catch unreachable;
        const destination_root = roots.layerIndex(plant, domain, destination_layer) catch unreachable;
        const source_axis = roots.layerAxisIndex(plant, domain, source_layer, axis) catch unreachable;
        const destination_axis = roots.layerAxisIndex(plant, domain, destination_layer, axis) catch unreachable;
        inline for (.{
            "axis_primary_carbon_g",
            "axis_primary_nitrogen_g",
            "axis_primary_phosphorus_g",
            "axis_secondary_carbon_g",
            "axis_secondary_nitrogen_g",
            "axis_secondary_phosphorus_g",
        }) |field_name| {
            const values = @field(roots, field_name);
            values[destination_axis] += values[source_axis];
            values[source_axis] = 0;
        }
        if (domain == 0)
            roots.axis_primary_length_m[destination_axis] = host_destination_primary_length
        else
            roots.axis_primary_length_m[destination_axis] += roots.axis_primary_length_m[source_axis];
        roots.axis_primary_length_m[source_axis] = 0;
        inline for (.{ "mobile_carbon_g", "mobile_nitrogen_g", "mobile_phosphorus_g", "protein_carbon_g" }) |field_name| {
            const values = @field(roots, field_name);
            const transfer = sink_fraction * values[source_root];
            values[source_root] -= transfer;
            values[destination_root] += transfer;
        }
        inline for (.{
            .{ "gaseous_carbon_dioxide_g_c", "aqueous_carbon_dioxide_g_c", "withdrawal_carbon_dioxide_loss_g_c_per_h", "withdrawal_carbon_dioxide_loss_g_c_per_h_by_root" },
            .{ "gaseous_oxygen_g_o", "aqueous_oxygen_g_o", "withdrawal_oxygen_loss_g_o_per_h", "withdrawal_oxygen_loss_g_o_per_h_by_root" },
            .{ "gaseous_methane_g_c", "aqueous_methane_g_c", "withdrawal_methane_loss_g_c_per_h", "withdrawal_methane_loss_g_c_per_h_by_root" },
            .{ "gaseous_nitrous_oxide_g_n", "aqueous_nitrous_oxide_g_n", "withdrawal_nitrous_oxide_loss_g_n_per_h", "withdrawal_nitrous_oxide_loss_g_n_per_h_by_root" },
            .{ "gaseous_ammonia_g_n", "aqueous_ammonia_g_n", "withdrawal_ammonia_loss_g_n_per_h", "withdrawal_ammonia_loss_g_n_per_h_by_root" },
            .{ "gaseous_hydrogen_g_h", "aqueous_hydrogen_g_h", "withdrawal_hydrogen_loss_g_h_per_h", "withdrawal_hydrogen_loss_g_h_per_h_by_root" },
        }) |fields| {
            const gaseous = @field(roots, fields[0]);
            const aqueous = @field(roots, fields[1]);
            const loss = @field(roots, fields[2]);
            const loss_by_root = @field(roots, fields[3]);
            const removed = sink_fraction * (gaseous[source_root] + aqueous[source_root]);
            gaseous[source_root] *= 1 - sink_fraction;
            aqueous[source_root] *= 1 - sink_fraction;
            loss[plant] -= removed;
            loss_by_root[source_root] -= removed;
        }
    }
    try transferSymbiontLayerFraction(roots, plant, source_layer, destination_layer, sink_fraction);
    roots.secondary_axis_count_total[host_source_root] = next_source_rtnl;
    roots.secondary_axis_count_total[host_destination_root] = next_destination_rtnl;
    roots.axis_secondary_count[host_source_axis] = 0;
    roots.axis_primary_count[host_source_axis] = 0;
}

/// GROSUB 5110--5115 ordered withdrawal for one root axis. Each selected
/// layer moves that axis through every active biological domain before its
/// persistent `NINR` bound is reduced.
pub fn withdrawRootAxisLayersSourceOrder(
    roots: *RootSystem.State,
    plant: usize,
    axis: usize,
    biological_domain_count: usize,
    source_layers: []const usize,
    sink_fractions: []const f64,
    seeding_depth_m: f64,
    layer_thickness_m: []const f64,
    layer_bottom_depth_m: []const f64,
) !void {
    if (source_layers.len != sink_fractions.len or
        biological_domain_count == 0 or
        biological_domain_count > RootSystem.biological_domain_count)
        return error.InvalidRootWithdrawalDimensions;
    const root_axis = try roots.rootAxisIndex(plant, axis);
    const planting_layer = roots.planting_layer_by_plant[plant];
    var expected_source = roots.deepest_rooted_layer_by_axis[root_axis];
    for (source_layers, sink_fractions) |source_layer, sink_fraction| {
        if (source_layer != expected_source or source_layer <= planting_layer)
            return error.InvalidRootWithdrawalLayerOrder;
        if (!std.math.isFinite(sink_fraction) or sink_fraction < 0 or
            sink_fraction > 1)
            return error.InvalidRootLayerTransferFraction;
        expected_source = source_layer - 1;
    }
    expected_source = roots.deepest_rooted_layer_by_axis[root_axis];
    for (source_layers, sink_fractions) |source_layer, sink_fraction| {
        const destination_layer = source_layer - 1;
        try withdrawRootAxisLayer(
            roots,
            plant,
            axis,
            biological_domain_count,
            source_layer,
            destination_layer,
            sink_fraction,
            seeding_depth_m,
            layer_thickness_m,
            layer_bottom_depth_m,
        );
        expected_source = @max(planting_layer, destination_layer);
        roots.deepest_rooted_layer_by_axis[root_axis] = expected_source;
    }
}

fn validatePool(pool: Symbiosis.Pool) !void {
    inline for (@typeInfo(Symbiosis.Pool).@"struct".fields) |field| {
        const value = @field(pool, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidRootSymbiontPool;
    }
}

fn sum(values: [LitterPartition.kinetic_component_count]f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total;
}

test "harvest nodule disturbance preserves distinct C N P retention" {
    const fine: LitterPartition.ElementFractions = .{
        .carbon = .{ 0.4, 0.3, 0.2, 0.1 },
        .nitrogen = .{ 0.1, 0.2, 0.3, 0.4 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    const mobile_partition: LitterPartition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 0, 1, 0, 0 },
        .phosphorus = .{ 0, 0, 1, 0 },
    };
    const structural: Symbiosis.Pool = .{ .carbon_g_c = 10, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    const mobile: Symbiosis.Pool = .{ .carbon_g_c = 4, .nitrogen_g_n = 1, .phosphorus_g_p = 0.5 };
    const result = try retainAndRelease(structural, mobile, .{ .carbon = 0.5, .nitrogen = 0.25, .phosphorus = 0.8 }, fine, mobile_partition);
    try std.testing.expectApproxEqAbs(14, result.structural.carbon_g_c + result.mobile.carbon_g_c + sum(result.litterfall.nonwoody_carbon_g_c), 1e-14);
    try std.testing.expectApproxEqAbs(3, result.structural.nitrogen_g_n + result.mobile.nitrogen_g_n + sum(result.litterfall.nonwoody_nitrogen_g_n), 1e-14);
    try std.testing.expectApproxEqAbs(1.5, result.structural.phosphorus_g_p + result.mobile.phosphorus_g_p + sum(result.litterfall.nonwoody_phosphorus_g_p), 1e-14);
}

test "GROSUB nodule tillage retains and litters only fixing domain zero" {
    const fine: LitterPartition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 0, 1, 0, 0 },
        .phosphorus = .{ 0, 0, 1, 0 },
    };
    const mobile_kinetics: LitterPartition.ElementFractions = .{
        .carbon = .{ 0, 0, 0, 1 },
        .nitrogen = .{ 0, 0, 1, 0 },
        .phosphorus = .{ 0, 1, 0, 0 },
    };
    const structural: Symbiosis.Pool = .{ .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 2 };
    const mobile: Symbiosis.Pool = .{ .carbon_g_c = 4, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    const applied = try sourceOrderNoduleTillage(
        1,
        0,
        2,
        structural,
        mobile,
        0.25,
        fine,
        mobile_kinetics,
    );
    try std.testing.expect(applied.applied);
    try std.testing.expectEqual(@as(f64, 2), applied.structural.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1), applied.mobile.carbon_g_c);
    try std.testing.expectApproxEqAbs(
        9,
        sum(applied.litterfall.nonwoody_carbon_g_c),
        1.0e-14,
    );

    const skipped = try sourceOrderNoduleTillage(
        1,
        1,
        2,
        structural,
        mobile,
        0.25,
        fine,
        mobile_kinetics,
    );
    try std.testing.expect(!skipped.applied);
    try std.testing.expectEqualDeep(structural, skipped.structural);
    try std.testing.expectEqualDeep(mobile, skipped.mobile);
    try std.testing.expectEqual(@as(f64, 0), sum(skipped.litterfall.nonwoody_carbon_g_c));
}

test "GROSUB host-root harvest preserves element-specific woody fractions" {
    const mobile = Symbiosis.Pool{ .carbon_g_c = 4, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    const structural = [_]Symbiosis.Pool{
        .{ .carbon_g_c = 10, .nitrogen_g_n = 3, .phosphorus_g_p = 2 },
        .{ .carbon_g_c = 6, .nitrogen_g_n = 1, .phosphorus_g_p = 0.5 },
    };
    const nonstructural = LitterPartition.ElementFractions{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const fine = LitterPartition.ElementFractions{
        .carbon = .{ 0, 1, 0, 0 },
        .nitrogen = .{ 0, 1, 0, 0 },
        .phosphorus = .{ 0, 1, 0, 0 },
    };
    const coarse = LitterPartition.ElementFractions{
        .carbon = .{ 0, 0, 1, 0 },
        .nitrogen = .{ 0, 0, 1, 0 },
        .phosphorus = .{ 0, 0, 1, 0 },
    };
    const result = try sourceOrderHostHarvestLitter(
        mobile,
        &structural,
        .{ .carbon = 0.5, .nitrogen = 0.25, .phosphorus = 0.8 },
        .{ .carbon = 0.75, .nitrogen = 0.5, .phosphorus = 0.2 },
        nonstructural,
        fine,
        coarse,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 10), result.removed.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), result.removed.nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), result.removed.phosphorus_g_p, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 6), result.litterfall.woody_carbon_g_c[2], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.litterfall.woody_nitrogen_g_n[2], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result.litterfall.woody_phosphorus_g_p[2], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 10), sum(result.litterfall.woody_carbon_g_c) + sum(result.litterfall.nonwoody_carbon_g_c), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), sum(result.litterfall.woody_nitrogen_g_n) + sum(result.litterfall.nonwoody_nitrogen_g_n), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), sum(result.litterfall.woody_phosphorus_g_p) + sum(result.litterfall.nonwoody_phosphorus_g_p), 1e-14);
}

test "GROSUB root tillage litter uses uniform retention over runtime axes" {
    const mobile: Symbiosis.Pool = .{ .carbon_g_c = 4, .nitrogen_g_n = 2, .phosphorus_g_p = 1 };
    const structural = [_]Symbiosis.Pool{
        .{ .carbon_g_c = 6, .nitrogen_g_n = 3, .phosphorus_g_p = 1.5 },
        .{ .carbon_g_c = 10, .nitrogen_g_n = 5, .phosphorus_g_p = 2.5 },
        .{ .carbon_g_c = 14, .nitrogen_g_n = 7, .phosphorus_g_p = 3.5 },
    };
    const nonstructural: LitterPartition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 0, 1, 0, 0 },
        .phosphorus = .{ 0, 0, 1, 0 },
    };
    const fine: LitterPartition.ElementFractions = .{
        .carbon = .{ 0, 1, 0, 0 },
        .nitrogen = .{ 0, 0, 1, 0 },
        .phosphorus = .{ 0, 0, 0, 1 },
    };
    const coarse: LitterPartition.ElementFractions = .{
        .carbon = .{ 0, 0, 1, 0 },
        .nitrogen = .{ 0, 0, 0, 1 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const result = try sourceOrderHostTillageLitter(
        mobile,
        &structural,
        0.4,
        .{ .carbon = 0.5, .nitrogen = 0.25, .phosphorus = 0.75 },
        nonstructural,
        fine,
        coarse,
    );
    try std.testing.expectApproxEqAbs(20.4, result.removed.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(10.2, result.removed.nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(5.1, result.removed.phosphorus_g_p, 1e-14);
    try std.testing.expectApproxEqAbs(
        result.removed.carbon_g_c,
        sum(result.litterfall.woody_carbon_g_c) + sum(result.litterfall.nonwoody_carbon_g_c),
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        result.removed.nitrogen_g_n,
        sum(result.litterfall.woody_nitrogen_g_n) + sum(result.litterfall.nonwoody_nitrogen_g_n),
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        result.removed.phosphorus_g_p,
        sum(result.litterfall.woody_phosphorus_g_p) + sum(result.litterfall.nonwoody_phosphorus_g_p),
        1e-14,
    );
}

test "complete root death moves every nodule pool to litter" {
    const partition: LitterPartition.ElementFractions = .{
        .carbon = .{ 0.25, 0.25, 0.25, 0.25 },
        .nitrogen = .{ 0.25, 0.25, 0.25, 0.25 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    const result = try retainAndRelease(
        .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 },
        .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        ElementRetention.uniform(0),
        partition,
        partition,
    );
    try std.testing.expectEqual(@as(f64, 0), result.structural.carbon_g_c);
    try std.testing.expectApproxEqAbs(3, sum(result.litterfall.nonwoody_carbon_g_c), 1e-14);
}

test "harvest releases all six root gases from both phases and domains" {
    var roots = try RootSystem.State.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    inline for (root_gas_fields) |fields| {
        const gaseous = @field(roots, fields[0]);
        const aqueous = @field(roots, fields[1]);
        for (0..RootSystem.biological_domain_count) |domain| {
            const root = try roots.layerIndex(0, domain, 0);
            gaseous[root] = 1;
            aqueous[root] = 3;
        }
    }
    try releaseRootGasFraction(&roots, 0, 0, 0.25);
    inline for (root_gas_fields) |fields| {
        const gaseous = @field(roots, fields[0]);
        const aqueous = @field(roots, fields[1]);
        const loss = @field(roots, fields[2]);
        const loss_by_root = @field(roots, fields[3]);
        for (0..RootSystem.biological_domain_count) |domain| {
            const root = try roots.layerIndex(0, domain, 0);
            try std.testing.expectEqual(@as(f64, 0.75), gaseous[root]);
            try std.testing.expectEqual(@as(f64, 2.25), aqueous[root]);
            try std.testing.expectEqual(@as(f64, -1), loss_by_root[root]);
        }
        try std.testing.expectEqual(@as(f64, -2), loss[0]);
    }
}

test "GROSUB tillage releases all root gases only from the selected layer" {
    var roots = try RootSystem.State.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    inline for (root_gas_fields) |fields| {
        const gaseous = @field(roots, fields[0]);
        const aqueous = @field(roots, fields[1]);
        for (0..RootSystem.biological_domain_count) |domain| {
            const selected = try roots.layerIndex(0, domain, 1);
            const untouched = try roots.layerIndex(0, domain, 0);
            gaseous[selected] = 2;
            aqueous[selected] = 6;
            gaseous[untouched] = 4;
            aqueous[untouched] = 8;
        }
    }
    try sourceOrderTillageRootGasRelease(&roots, 0, 1, 0.25);
    inline for (root_gas_fields) |fields| {
        const gaseous = @field(roots, fields[0]);
        const aqueous = @field(roots, fields[1]);
        const loss = @field(roots, fields[2]);
        const loss_by_root = @field(roots, fields[3]);
        for (0..RootSystem.biological_domain_count) |domain| {
            const selected = try roots.layerIndex(0, domain, 1);
            const untouched = try roots.layerIndex(0, domain, 0);
            try std.testing.expectEqual(@as(f64, 0.5), gaseous[selected]);
            try std.testing.expectEqual(@as(f64, 1.5), aqueous[selected]);
            try std.testing.expectEqual(@as(f64, 4), gaseous[untouched]);
            try std.testing.expectEqual(@as(f64, 8), aqueous[untouched]);
            try std.testing.expectEqual(@as(f64, -6), loss_by_root[selected]);
            try std.testing.expectEqual(@as(f64, 0), loss_by_root[untouched]);
        }
        try std.testing.expectEqual(@as(f64, -12), loss[0]);
    }
}

test {
    _ = @import("plant_root_disturbance_test.zig");
}

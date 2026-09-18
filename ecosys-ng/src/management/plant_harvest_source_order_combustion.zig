//! `plant_harvest_source_order` declarations: combustion.
//!
//! Split out of `plant_harvest_source_order.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const management = @import("plant_management.zig");
const canopy = @import("../canopy/photosynthesis/photosynthesis.zig");
const phenology = @import("../plant/lifecycle/phenology.zig");
const litter_partition = @import("../plant/partition/litter.zig");
const grazing_manure = @import("grazing_manure.zig");
const __parent = @import("plant_harvest_runtime.zig");
const group_complete_death = @import("plant_harvest_source_order_complete_death.zig");
const group_dead_root = @import("plant_harvest_source_order_dead_root.zig");
const group_misc = @import("plant_harvest_source_order_misc.zig");

const boundedCombustionFraction = __parent.boundedCombustionFraction;
pub const validateCombustionNode = __parent.validateCombustionNode;

pub const SourceOrderFireShootCarbon = struct {
    canopy_nonstructural_g_c: f64,
    leaf_g_c: f64,
    sheath_g_c: f64,
    stalk_g_c: f64,
    reserve_g_c: f64,
    husk_g_c: f64,
    ear_g_c: f64,
    grain_g_c: f64,
    symbiont_nonstructural_g_c: f64,
    symbiont_biomass_g_c: f64,
    seasonal_storage_g_c: f64,
    standing_dead_g_c: f64,
};

pub const SourceOrderFirePlantInventory = struct {
    shoot: SourceOrderFireShootCarbon,
    canopy_symbiont_included: bool,
    root_domain_count: usize,
    root_axis_count: usize,
    nodule_nonstructural_by_layer_g_c: []const f64,
    nodule_biomass_by_layer_g_c: []const f64,
    root_nonstructural_by_layer_domain_g_c: []const f64,
    root_structural_by_layer_domain_axis: []const group_dead_root.SourceOrderDeadRootAxisPools,
};

pub const SourceOrderFireLayerCarbon = struct {
    root_nonstructural_g_c: f64,
    root_structural_g_c: f64,
    nodule_nonstructural_g_c: f64,
    nodule_biomass_g_c: f64,
};

pub const SourceOrderFireInventoryResult = struct {
    shoot: SourceOrderFireShootCarbon,
    layers: []SourceOrderFireLayerCarbon,

    pub fn deinit(self: SourceOrderFireInventoryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.layers);
    }
};

/// Exact GROSUB 11735-11795 fire-event canopy and root C inventory.
pub fn sourceOrderAggregateFireCarbonInventory(
    allocator: std.mem.Allocator,
    fire_in_progress: bool,
    active_layer_count: usize,
    plants: []const SourceOrderFirePlantInventory,
) !?SourceOrderFireInventoryResult {
    if (!fire_in_progress) return null;
    if (active_layer_count == 0) return error.InvalidFireInventoryDimensions;
    for (plants) |plant| {
        if (plant.root_domain_count == 0 or plant.root_axis_count == 0 or
            plant.nodule_nonstructural_by_layer_g_c.len != active_layer_count or
            plant.nodule_biomass_by_layer_g_c.len != active_layer_count)
            return error.InvalidFireInventoryDimensions;
        const domain_layers = std.math.mul(
            usize,
            active_layer_count,
            plant.root_domain_count,
        ) catch return error.InvalidFireInventoryDimensions;
        const axis_layers = std.math.mul(
            usize,
            domain_layers,
            plant.root_axis_count,
        ) catch return error.InvalidFireInventoryDimensions;
        if (plant.root_nonstructural_by_layer_domain_g_c.len != domain_layers or
            plant.root_structural_by_layer_domain_axis.len != axis_layers)
            return error.InvalidFireInventoryDimensions;
        inline for (@typeInfo(SourceOrderFireShootCarbon).@"struct".fields) |field| {
            const value = @field(plant.shoot, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidFireInventory;
        }
        for (plant.nodule_nonstructural_by_layer_g_c) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidFireInventory;
        for (plant.nodule_biomass_by_layer_g_c) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidFireInventory;
        for (plant.root_nonstructural_by_layer_domain_g_c) |value|
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidFireInventory;
        for (plant.root_structural_by_layer_domain_axis) |axis| {
            try group_complete_death.validateCompleteDeathMass(axis.primary);
            try group_complete_death.validateCompleteDeathMass(axis.secondary);
        }
    }

    const layers = try allocator.alloc(SourceOrderFireLayerCarbon, active_layer_count);
    errdefer allocator.free(layers);
    @memset(layers, std.mem.zeroes(SourceOrderFireLayerCarbon));
    var shoot = std.mem.zeroes(SourceOrderFireShootCarbon);
    for (plants) |plant| {
        shoot.canopy_nonstructural_g_c += plant.shoot.canopy_nonstructural_g_c;
        shoot.leaf_g_c += plant.shoot.leaf_g_c;
        shoot.sheath_g_c += plant.shoot.sheath_g_c;
        shoot.stalk_g_c += plant.shoot.stalk_g_c;
        shoot.reserve_g_c += plant.shoot.reserve_g_c;
        shoot.husk_g_c += plant.shoot.husk_g_c;
        shoot.ear_g_c += plant.shoot.ear_g_c;
        shoot.grain_g_c += plant.shoot.grain_g_c;
        if (plant.canopy_symbiont_included) {
            shoot.symbiont_nonstructural_g_c += plant.shoot.symbiont_nonstructural_g_c;
            shoot.symbiont_biomass_g_c += plant.shoot.symbiont_biomass_g_c;
        }
        shoot.standing_dead_g_c += plant.shoot.standing_dead_g_c;
        shoot.seasonal_storage_g_c += plant.shoot.seasonal_storage_g_c;
        for (0..active_layer_count) |layer| {
            layers[layer].nodule_nonstructural_g_c +=
                plant.nodule_nonstructural_by_layer_g_c[layer];
            layers[layer].nodule_biomass_g_c +=
                plant.nodule_biomass_by_layer_g_c[layer];
            for (0..plant.root_domain_count) |domain| {
                const domain_layer = layer * plant.root_domain_count + domain;
                layers[layer].root_nonstructural_g_c +=
                    plant.root_nonstructural_by_layer_domain_g_c[domain_layer];
                for (0..plant.root_axis_count) |axis| {
                    const pools = plant.root_structural_by_layer_domain_axis[
                        domain_layer * plant.root_axis_count + axis
                    ];
                    layers[layer].root_structural_g_c +=
                        pools.primary.carbon_g + pools.secondary.carbon_g;
                }
            }
        }
    }
    inline for (@typeInfo(SourceOrderFireShootCarbon).@"struct".fields) |field|
        if (!std.math.isFinite(@field(shoot, field.name)))
            return error.NonFiniteFireInventory;
    for (layers) |layer| inline for (@typeInfo(SourceOrderFireLayerCarbon).@"struct".fields) |field|
        if (!std.math.isFinite(@field(layer, field.name)))
            return error.NonFiniteFireInventory;
    return .{ .shoot = shoot, .layers = layers };
}

pub const SourceOrderCombustionSpecificRates = struct {
    living_nonstructural_and_leaf_g_c_m2_h: f64,
    living_sheath_g_c_m2_h: f64,
    living_stalk_g_c_m2_h: f64,
    living_reproductive_g_c_m2_h: f64,
    standing_dead_g_c_m2_h: f64,
};

pub const SourceOrderCombustionRates = struct {
    living_temperature_fraction: f64,
    standing_dead_temperature_fraction: f64,
    living_nonstructural_and_leaf_g_c_step: f64,
    living_sheath_g_c_step: f64,
    living_stalk_g_c_step: f64,
    living_reproductive_g_c_step: f64,
    standing_dead_g_c_step: f64,
};

/// Exact GROSUB 11812-11839 living and standing-dead combustion rates.
pub fn sourceOrderCombustionRates(
    canopy_temperature_k: f64,
    standing_dead_temperature_k: f64,
    minimum_combustion_temperature_k: f64,
    maximum_temperature_response: f64,
    surface_area_m2: f64,
    biological_timestep_h: f64,
    specific: SourceOrderCombustionSpecificRates,
) !SourceOrderCombustionRates {
    inline for (.{
        canopy_temperature_k,
        standing_dead_temperature_k,
        minimum_combustion_temperature_k,
        maximum_temperature_response,
        surface_area_m2,
        biological_timestep_h,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidCombustionRateInput;
    inline for (@typeInfo(SourceOrderCombustionSpecificRates).@"struct".fields) |field| {
        const value = @field(specific, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidCombustionRateInput;
    }
    var result = std.mem.zeroes(SourceOrderCombustionRates);
    if (canopy_temperature_k <= minimum_combustion_temperature_k and
        standing_dead_temperature_k <= minimum_combustion_temperature_k)
        return result;
    if (canopy_temperature_k > minimum_combustion_temperature_k) {
        const gas_constant_temperature = 8.3143 * canopy_temperature_k;
        const response = @min(
            maximum_temperature_response,
            @exp(12.028 - 60000 / gas_constant_temperature),
        );
        result.living_temperature_fraction = @min(@as(f64, 1), response);
        const base_rate = response * surface_area_m2 * biological_timestep_h;
        result.living_nonstructural_and_leaf_g_c_step =
            specific.living_nonstructural_and_leaf_g_c_m2_h * base_rate;
        result.living_sheath_g_c_step =
            specific.living_sheath_g_c_m2_h * base_rate;
        result.living_stalk_g_c_step =
            specific.living_stalk_g_c_m2_h * base_rate;
        result.living_reproductive_g_c_step =
            specific.living_reproductive_g_c_m2_h * base_rate;
    }
    if (standing_dead_temperature_k > minimum_combustion_temperature_k) {
        const gas_constant_temperature = 8.3143 * standing_dead_temperature_k;
        const response = @min(
            maximum_temperature_response,
            @exp(12.028 - 60000 / gas_constant_temperature),
        );
        result.standing_dead_temperature_fraction = @min(@as(f64, 1), response);
        const base_rate = response * surface_area_m2 * biological_timestep_h;
        result.standing_dead_g_c_step =
            specific.standing_dead_g_c_m2_h * base_rate;
    }
    inline for (@typeInfo(SourceOrderCombustionRates).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCombustionRate;
    return result;
}

pub const SourceOrderShootCombustionTotals = struct {
    canopy_nonstructural_g_c: f64,
    leaf_g_c: f64,
    sheath_g_c: f64,
    stalk_g_c: f64,
    husk_g_c: f64,
    ear_g_c: f64,
    grain_g_c: f64,
    symbiont_nonstructural_g_c: f64,
    symbiont_biomass_g_c: f64,
    standing_dead_g_c: f64,
};

pub const SourceOrderShootCombustionFractions = struct {
    canopy_nonstructural: f64,
    leaf: f64,
    sheath: f64,
    stalk: f64,
    reserve: f64,
    husk: f64,
    ear: f64,
    grain: f64,
    symbiont_nonstructural: f64,
    symbiont_biomass: f64,
    standing_dead: f64,
};

/// Exact GROSUB 11857-11915 shoot-pool combustion fractions.
pub fn sourceOrderShootCombustionFractions(
    totals: SourceOrderShootCombustionTotals,
    rates: SourceOrderCombustionRates,
    negligible_carbon_g_c: f64,
    biomass_type_code: i32,
    growth_type_code: i32,
) !SourceOrderShootCombustionFractions {
    if (!std.math.isFinite(negligible_carbon_g_c) or negligible_carbon_g_c < 0)
        return error.InvalidShootCombustionFractionInput;
    inline for (@typeInfo(SourceOrderShootCombustionTotals).@"struct".fields) |field| {
        const value = @field(totals, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidShootCombustionFractionInput;
    }
    inline for (@typeInfo(SourceOrderCombustionRates).@"struct".fields) |field| {
        const value = @field(rates, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidShootCombustionFractionInput;
    }
    const low_order_stem_routing =
        biomass_type_code == 0 or growth_type_code <= 1;
    const sheath_rate = if (low_order_stem_routing)
        rates.living_sheath_g_c_step
    else
        rates.living_stalk_g_c_step;
    const stalk_rate = if (low_order_stem_routing)
        rates.living_sheath_g_c_step
    else
        rates.living_reproductive_g_c_step;
    const fraction = struct {
        fn bounded(total_g_c: f64, rate_g_c_step: f64, threshold_g_c: f64) f64 {
            return if (total_g_c > threshold_g_c)
                @min(@as(f64, 1), rate_g_c_step / total_g_c)
            else
                0;
        }
    }.bounded;
    return .{
        .canopy_nonstructural = fraction(
            totals.canopy_nonstructural_g_c,
            rates.living_nonstructural_and_leaf_g_c_step,
            negligible_carbon_g_c,
        ),
        .leaf = fraction(
            totals.leaf_g_c,
            rates.living_nonstructural_and_leaf_g_c_step,
            negligible_carbon_g_c,
        ),
        .sheath = fraction(totals.sheath_g_c, sheath_rate, negligible_carbon_g_c),
        .stalk = fraction(totals.stalk_g_c, stalk_rate, negligible_carbon_g_c),
        .reserve = fraction(totals.stalk_g_c, stalk_rate, negligible_carbon_g_c),
        .husk = fraction(
            totals.husk_g_c,
            rates.living_nonstructural_and_leaf_g_c_step,
            negligible_carbon_g_c,
        ),
        .ear = fraction(
            totals.ear_g_c,
            rates.living_sheath_g_c_step,
            negligible_carbon_g_c,
        ),
        .grain = fraction(
            totals.grain_g_c,
            rates.living_sheath_g_c_step,
            negligible_carbon_g_c,
        ),
        .symbiont_nonstructural = fraction(
            totals.symbiont_nonstructural_g_c,
            rates.living_nonstructural_and_leaf_g_c_step,
            negligible_carbon_g_c,
        ),
        .symbiont_biomass = fraction(
            totals.symbiont_biomass_g_c,
            rates.living_sheath_g_c_step,
            negligible_carbon_g_c,
        ),
        .standing_dead = fraction(
            totals.standing_dead_g_c,
            rates.standing_dead_g_c_step,
            negligible_carbon_g_c,
        ),
    };
}

pub const SourceOrderShootCombustionBranchPools = struct {
    canopy_nonstructural: canopy.ElementalMass,
    leaf: canopy.ElementalMass,
    sheath: canopy.ElementalMass,
    stalk: canopy.ElementalMass,
    reserve: canopy.ElementalMass,
    husk: canopy.ElementalMass,
    ear: canopy.ElementalMass,
    grain: canopy.ElementalMass,
    symbiont_nonstructural: canopy.ElementalMass,
    symbiont_biomass: canopy.ElementalMass,
};

pub const SourceOrderShootCombustionBranchResult = struct {
    combusted: SourceOrderShootCombustionBranchPools,
    total_combusted: canopy.ElementalMass,
};

pub const SourceOrderShootCombustionResult = struct {
    branches: []SourceOrderShootCombustionBranchResult,
    cumulative_canopy_combustion_g_c: f64,
    disturbance_emission_ledger: canopy.ElementalMass,

    pub fn deinit(self: SourceOrderShootCombustionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.branches);
    }
};

/// Exact GROSUB 11934-11988 per-branch shoot combustion and loss ledgers.
pub fn sourceOrderShootCombustionLosses(
    allocator: std.mem.Allocator,
    pools: []const SourceOrderShootCombustionBranchPools,
    fractions: SourceOrderShootCombustionFractions,
    preceding_cumulative_canopy_combustion_g_c: f64,
    preceding_disturbance_emission_ledger: canopy.ElementalMass,
) !SourceOrderShootCombustionResult {
    if (!std.math.isFinite(preceding_cumulative_canopy_combustion_g_c))
        return error.InvalidShootCombustionLossInput;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(preceding_disturbance_emission_ledger, field.name)))
            return error.InvalidShootCombustionLossInput;
    inline for (@typeInfo(SourceOrderShootCombustionFractions).@"struct".fields) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidShootCombustionLossInput;
    }
    for (pools) |branch| inline for (@typeInfo(SourceOrderShootCombustionBranchPools).@"struct".fields) |field|
        try group_complete_death.validateCompleteDeathMass(@field(branch, field.name));

    const branches = try allocator.alloc(SourceOrderShootCombustionBranchResult, pools.len);
    errdefer allocator.free(branches);
    var cumulative = preceding_cumulative_canopy_combustion_g_c;
    var emissions = preceding_disturbance_emission_ledger;
    for (pools, branches) |branch, *result| {
        result.combusted = .{
            .canopy_nonstructural = group_misc.scaleElementalMass(
                branch.canopy_nonstructural,
                fractions.canopy_nonstructural,
            ),
            .leaf = group_misc.scaleElementalMass(branch.leaf, fractions.leaf),
            .sheath = group_misc.scaleElementalMass(branch.sheath, fractions.sheath),
            .stalk = group_misc.scaleElementalMass(branch.stalk, fractions.stalk),
            .reserve = group_misc.scaleElementalMass(branch.reserve, fractions.reserve),
            .husk = group_misc.scaleElementalMass(branch.husk, fractions.husk),
            .ear = group_misc.scaleElementalMass(branch.ear, fractions.ear),
            .grain = group_misc.scaleElementalMass(branch.grain, fractions.grain),
            .symbiont_nonstructural = group_misc.scaleElementalMass(
                branch.symbiont_nonstructural,
                fractions.symbiont_nonstructural,
            ),
            .symbiont_biomass = group_misc.scaleElementalMass(
                branch.symbiont_biomass,
                fractions.symbiont_biomass,
            ),
        };
        result.total_combusted = .{};
        inline for (@typeInfo(SourceOrderShootCombustionBranchPools).@"struct".fields) |field| {
            const mass = @field(result.combusted, field.name);
            result.total_combusted.carbon_g += mass.carbon_g;
            result.total_combusted.nitrogen_g += mass.nitrogen_g;
            result.total_combusted.phosphorus_g += mass.phosphorus_g;
        }
        cumulative += result.total_combusted.carbon_g;
        emissions.carbon_g -= result.total_combusted.carbon_g;
        emissions.nitrogen_g -= result.total_combusted.nitrogen_g;
        emissions.phosphorus_g -= result.total_combusted.phosphorus_g;
    }
    if (!std.math.isFinite(cumulative))
        return error.NonFiniteShootCombustionLoss;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(emissions, field.name)))
            return error.NonFiniteShootCombustionLoss;
    return .{
        .branches = branches,
        .cumulative_canopy_combustion_g_c = cumulative,
        .disturbance_emission_ledger = emissions,
    };
}

pub const SourceOrderShootSaltCombustionBranchResult = struct {
    combusted: group_misc.SourceOrderShootSaltInventory,
    remaining: group_misc.SourceOrderShootSaltInventory,
};

/// Exact GROSUB 12011-12028 dynamic-salt shoot combustion.
pub fn sourceOrderShootSaltCombustion(
    allocator: std.mem.Allocator,
    dynamic_salt_enabled: bool,
    canopy_nonstructural_combustion_fraction: f64,
    branches: []const group_misc.SourceOrderShootSaltInventory,
) !?[]SourceOrderShootSaltCombustionBranchResult {
    if (!dynamic_salt_enabled) return null;
    if (!std.math.isFinite(canopy_nonstructural_combustion_fraction) or
        canopy_nonstructural_combustion_fraction < 0 or
        canopy_nonstructural_combustion_fraction > 1)
        return error.InvalidShootSaltCombustionInput;
    for (branches) |branch| inline for (@typeInfo(group_misc.SourceOrderShootSaltInventory).@"struct".fields) |field| {
        const value = @field(branch, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidShootSaltCombustionInput;
    };
    const result = try allocator.alloc(
        SourceOrderShootSaltCombustionBranchResult,
        branches.len,
    );
    errdefer allocator.free(result);
    for (branches, result) |branch, *branch_result| {
        branch_result.combusted = .{
            .aluminum_mol = branch.aluminum_mol * canopy_nonstructural_combustion_fraction,
            .iron_mol = branch.iron_mol * canopy_nonstructural_combustion_fraction,
            .calcium_mol = branch.calcium_mol * canopy_nonstructural_combustion_fraction,
            .magnesium_mol = branch.magnesium_mol * canopy_nonstructural_combustion_fraction,
            .sodium_mol = branch.sodium_mol * canopy_nonstructural_combustion_fraction,
            .potassium_mol = branch.potassium_mol * canopy_nonstructural_combustion_fraction,
            .sulfate_mol = branch.sulfate_mol * canopy_nonstructural_combustion_fraction,
            .chloride_mol = branch.chloride_mol * canopy_nonstructural_combustion_fraction,
        };
        branch_result.remaining = .{
            .aluminum_mol = branch.aluminum_mol - branch_result.combusted.aluminum_mol,
            .iron_mol = branch.iron_mol - branch_result.combusted.iron_mol,
            .calcium_mol = branch.calcium_mol - branch_result.combusted.calcium_mol,
            .magnesium_mol = branch.magnesium_mol - branch_result.combusted.magnesium_mol,
            .sodium_mol = branch.sodium_mol - branch_result.combusted.sodium_mol,
            .potassium_mol = branch.potassium_mol - branch_result.combusted.potassium_mol,
            .sulfate_mol = branch.sulfate_mol - branch_result.combusted.sulfate_mol,
            .chloride_mol = branch.chloride_mol - branch_result.combusted.chloride_mol,
        };
        inline for (.{ branch_result.combusted, branch_result.remaining }) |inventory|
            inline for (@typeInfo(group_misc.SourceOrderShootSaltInventory).@"struct".fields) |field|
                if (!std.math.isFinite(@field(inventory, field.name)))
                    return error.NonFiniteShootSaltCombustion;
    }
    return result;
}

pub const SourceOrderShootCombustionNodeState = struct {
    leaf_area_m2: f64,
    sheath_height_m: f64,
    green_leaf: canopy.ElementalMass,
    senescent_leaf_carbon_g_c: f64,
    green_sheath: canopy.ElementalMass,
    senescent_sheath_carbon_g_c: f64,
    node: canopy.ElementalMass,
};

pub const SourceOrderShootCombustionNodeLayerState = struct {
    leaf_area_m2: f64,
    green_leaf: canopy.ElementalMass,
};

pub const SourceOrderStandingDeadCombustionComponent = struct {
    combusted: canopy.ElementalMass,
    remaining: canopy.ElementalMass,
};

pub const SourceOrderStandingDeadCombustionResult = struct {
    components: []SourceOrderStandingDeadCombustionComponent,
    cumulative_standing_dead_combustion_g_c: f64,
    disturbance_emission_ledger: canopy.ElementalMass,

    pub fn deinit(
        self: SourceOrderStandingDeadCombustionResult,
        allocator: std.mem.Allocator,
    ) void {
        allocator.free(self.components);
    }
};

/// Exact GROSUB 12112-12138 non-charcoal standing-dead combustion.
pub fn sourceOrderStandingDeadCombustion(
    allocator: std.mem.Allocator,
    components: []const canopy.ElementalMass,
    combustion_fraction: f64,
    preceding_cumulative_standing_dead_combustion_g_c: f64,
    preceding_disturbance_emission_ledger: canopy.ElementalMass,
) !SourceOrderStandingDeadCombustionResult {
    if (components.len == 0 or !std.math.isFinite(combustion_fraction) or
        combustion_fraction < 0 or combustion_fraction > 1 or
        !std.math.isFinite(preceding_cumulative_standing_dead_combustion_g_c))
        return error.InvalidStandingDeadCombustionInput;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(preceding_disturbance_emission_ledger, field.name)))
            return error.InvalidStandingDeadCombustionInput;
    for (components) |component| try group_complete_death.validateCompleteDeathMass(component);

    const result_components = try allocator.alloc(
        SourceOrderStandingDeadCombustionComponent,
        components.len,
    );
    errdefer allocator.free(result_components);
    var cumulative = preceding_cumulative_standing_dead_combustion_g_c;
    var emissions = preceding_disturbance_emission_ledger;
    for (components, result_components) |component, *result| {
        result.combusted = group_misc.scaleElementalMass(component, combustion_fraction);
        result.remaining = .{
            .carbon_g = component.carbon_g - result.combusted.carbon_g,
            .nitrogen_g = component.nitrogen_g - result.combusted.nitrogen_g,
            .phosphorus_g = component.phosphorus_g - result.combusted.phosphorus_g,
        };
        cumulative += result.combusted.carbon_g;
        emissions.carbon_g -= result.combusted.carbon_g;
        emissions.nitrogen_g -= result.combusted.nitrogen_g;
        emissions.phosphorus_g -= result.combusted.phosphorus_g;
        try group_complete_death.validateCompleteDeathResultMass(result.combusted);
        try group_complete_death.validateCompleteDeathResultMass(result.remaining);
    }
    if (!std.math.isFinite(cumulative))
        return error.NonFiniteStandingDeadCombustion;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(emissions, field.name)))
            return error.NonFiniteStandingDeadCombustion;
    return .{
        .components = result_components,
        .cumulative_standing_dead_combustion_g_c = cumulative,
        .disturbance_emission_ledger = emissions,
    };
}

pub const SourceOrderCharcoalCombustionResult = struct {
    temperature_response: f64,
    potential_combustion_g_c_step: f64,
    combustion_fraction: f64,
    combusted: canopy.ElementalMass,
    remaining: canopy.ElementalMass,
    cumulative_standing_dead_combustion_g_c: f64,
    disturbance_emission_ledger: canopy.ElementalMass,
    grid_total_combustion_g_c: f64,
};

/// Exact GROSUB 12152-12178 charcoal combustion and loss ledgers.
pub fn sourceOrderCharcoalCombustion(
    standing_dead_temperature_k: f64,
    maximum_temperature_response: f64,
    surface_area_m2: f64,
    biological_timestep_h: f64,
    specific_charcoal_combustion_g_c_m2_h: f64,
    grid_standing_dead_carbon_g_c: f64,
    negligible_carbon_g_c: f64,
    charcoal: canopy.ElementalMass,
    preceding_cumulative_standing_dead_combustion_g_c: f64,
    preceding_disturbance_emission_ledger: canopy.ElementalMass,
    preceding_grid_total_combustion_g_c: f64,
    plant_canopy_combustion_g_c: f64,
) !SourceOrderCharcoalCombustionResult {
    inline for (.{
        standing_dead_temperature_k,
        maximum_temperature_response,
        surface_area_m2,
        biological_timestep_h,
        specific_charcoal_combustion_g_c_m2_h,
        grid_standing_dead_carbon_g_c,
        negligible_carbon_g_c,
        preceding_cumulative_standing_dead_combustion_g_c,
        preceding_grid_total_combustion_g_c,
        plant_canopy_combustion_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidCharcoalCombustionInput;
    if (standing_dead_temperature_k == 0)
        return error.InvalidCharcoalCombustionTemperature;
    try group_complete_death.validateCompleteDeathMass(charcoal);
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(preceding_disturbance_emission_ledger, field.name)))
            return error.InvalidCharcoalCombustionInput;

    const gas_constant_temperature = 8.3143 * standing_dead_temperature_k;
    const response = @min(
        maximum_temperature_response,
        @exp(20.620 - 120000 / gas_constant_temperature),
    );
    const base_rate = response * surface_area_m2 * biological_timestep_h;
    const potential = specific_charcoal_combustion_g_c_m2_h * base_rate;
    const fraction = if (grid_standing_dead_carbon_g_c > negligible_carbon_g_c)
        @min(@as(f64, 1), potential / grid_standing_dead_carbon_g_c)
    else
        0;
    const combusted = group_misc.scaleElementalMass(charcoal, fraction);
    const remaining: canopy.ElementalMass = .{
        .carbon_g = charcoal.carbon_g - combusted.carbon_g,
        .nitrogen_g = charcoal.nitrogen_g - combusted.nitrogen_g,
        .phosphorus_g = charcoal.phosphorus_g - combusted.phosphorus_g,
    };
    const cumulative = preceding_cumulative_standing_dead_combustion_g_c +
        combusted.carbon_g;
    const emissions: canopy.ElementalMass = .{
        .carbon_g = preceding_disturbance_emission_ledger.carbon_g -
            combusted.carbon_g,
        .nitrogen_g = preceding_disturbance_emission_ledger.nitrogen_g -
            combusted.nitrogen_g,
        .phosphorus_g = preceding_disturbance_emission_ledger.phosphorus_g -
            combusted.phosphorus_g,
    };
    const grid_total = preceding_grid_total_combustion_g_c +
        plant_canopy_combustion_g_c + cumulative;
    inline for (.{ response, potential, fraction, cumulative, grid_total }) |value|
        if (!std.math.isFinite(value))
            return error.NonFiniteCharcoalCombustion;
    try group_complete_death.validateCompleteDeathResultMass(combusted);
    try group_complete_death.validateCompleteDeathResultMass(remaining);
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(emissions, field.name)))
            return error.NonFiniteCharcoalCombustion;
    return .{
        .temperature_response = response,
        .potential_combustion_g_c_step = potential,
        .combustion_fraction = fraction,
        .combusted = combusted,
        .remaining = remaining,
        .cumulative_standing_dead_combustion_g_c = cumulative,
        .disturbance_emission_ledger = emissions,
        .grid_total_combustion_g_c = grid_total,
    };
}

pub const SourceOrderNoCombustionReset = struct {
    canopy_combustion_g_c_step: f64 = 0,
    standing_dead_combustion_g_c_step: f64 = 0,
    canopy_temperature_response: f64 = 0,
    standing_dead_temperature_response: f64 = 0,
    branch_combustion: []SourceOrderShootCombustionBranchPools,
    branch_salt_combustion: ?[]group_misc.SourceOrderShootSaltInventory,
    standing_dead_combustion: []canopy.ElementalMass,

    pub fn deinit(self: SourceOrderNoCombustionReset, allocator: std.mem.Allocator) void {
        allocator.free(self.branch_combustion);
        if (self.branch_salt_combustion) |salt| allocator.free(salt);
        allocator.free(self.standing_dead_combustion);
    }
};

/// Exact GROSUB 12183-12234 cold-canopy combustion-rate reset.
pub fn sourceOrderResetNoCombustion(
    allocator: std.mem.Allocator,
    branch_count: usize,
    dynamic_salt_enabled: bool,
) !SourceOrderNoCombustionReset {
    const branch_combustion = try allocator.alloc(
        SourceOrderShootCombustionBranchPools,
        branch_count,
    );
    errdefer allocator.free(branch_combustion);
    @memset(branch_combustion, std.mem.zeroes(SourceOrderShootCombustionBranchPools));

    const branch_salt_combustion = if (dynamic_salt_enabled)
        try allocator.alloc(group_misc.SourceOrderShootSaltInventory, branch_count)
    else
        null;
    errdefer if (branch_salt_combustion) |salt| allocator.free(salt);
    if (branch_salt_combustion) |salt|
        @memset(salt, std.mem.zeroes(group_misc.SourceOrderShootSaltInventory));

    const standing_dead_combustion = try allocator.alloc(canopy.ElementalMass, 5);
    errdefer allocator.free(standing_dead_combustion);
    @memset(standing_dead_combustion, std.mem.zeroes(canopy.ElementalMass));
    return .{
        .branch_combustion = branch_combustion,
        .branch_salt_combustion = branch_salt_combustion,
        .standing_dead_combustion = standing_dead_combustion,
    };
}

pub const SourceOrderRootCombustionLayerTotals = struct {
    root_nonstructural_g_c: f64,
    active_root_g_c: f64,
    nodule_nonstructural_g_c: f64,
    nodule_biomass_g_c: f64,
};

pub const SourceOrderRootCombustionFractions = struct {
    root_nonstructural: f64,
    active_root: f64,
    nodule_nonstructural: f64,
    nodule_biomass: f64,
    storage: f64,
};

pub const SourceOrderRootCombustionPotentialRates = struct {
    root_nonstructural_g_c_step: f64,
    nodule_biomass_g_c_step: f64,
    active_root_g_c_step: f64,
    reproductive_g_c_step: f64,
    standing_dead_g_c_step: f64,
};

pub const SourceOrderRootStorageCombustionInput = struct {
    soil_temperature_k: f64,
    minimum_combustion_temperature_k: f64,
    maximum_temperature_response: f64,
    surface_area_m2: f64,
    biological_timestep_h: f64,
    specific_rates: SourceOrderCombustionSpecificRates,
    totals: SourceOrderRootCombustionLayerTotals,
    negligible_carbon_g_c: f64,
    is_surface_layer: bool,
    storage: canopy.ElementalMass,
    preceding_layer_combustion_g_c: f64,
    preceding_disturbance_emission_ledger: canopy.ElementalMass,
};

pub const SourceOrderRootStorageCombustionResult = struct {
    temperature_response: f64,
    potential_rates: SourceOrderRootCombustionPotentialRates,
    fractions: SourceOrderRootCombustionFractions,
    storage_combusted: canopy.ElementalMass,
    storage_remaining: canopy.ElementalMass,
    layer_combustion_g_c: f64,
    disturbance_emission_ledger: canopy.ElementalMass,
};

/// Exact GROSUB 12253-12332 soil-temperature rates, fractions, and storage loss.
pub fn sourceOrderRootStorageCombustion(
    input: SourceOrderRootStorageCombustionInput,
) !SourceOrderRootStorageCombustionResult {
    inline for (.{
        input.soil_temperature_k,
        input.minimum_combustion_temperature_k,
        input.maximum_temperature_response,
        input.surface_area_m2,
        input.biological_timestep_h,
        input.negligible_carbon_g_c,
        input.preceding_layer_combustion_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidRootStorageCombustionInput;
    inline for (@typeInfo(SourceOrderCombustionSpecificRates).@"struct".fields) |field| {
        const value = @field(input.specific_rates, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidRootStorageCombustionInput;
    }
    inline for (@typeInfo(SourceOrderRootCombustionLayerTotals).@"struct".fields) |field| {
        const value = @field(input.totals, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidRootStorageCombustionInput;
    }
    try group_complete_death.validateCompleteDeathMass(input.storage);
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(input.preceding_disturbance_emission_ledger, field.name)))
            return error.InvalidRootStorageCombustionInput;

    var result = std.mem.zeroes(SourceOrderRootStorageCombustionResult);
    result.storage_remaining = input.storage;
    result.layer_combustion_g_c = input.preceding_layer_combustion_g_c;
    result.disturbance_emission_ledger = input.preceding_disturbance_emission_ledger;
    if (input.soil_temperature_k <= input.minimum_combustion_temperature_k)
        return result;

    result.temperature_response = @min(
        input.maximum_temperature_response,
        @exp(12.028 - 60000 / (8.3143 * input.soil_temperature_k)),
    );
    const rate_scale = result.temperature_response *
        input.surface_area_m2 * input.biological_timestep_h;
    result.potential_rates = .{
        .root_nonstructural_g_c_step = input.specific_rates.living_nonstructural_and_leaf_g_c_m2_h * rate_scale,
        .nodule_biomass_g_c_step = input.specific_rates.living_sheath_g_c_m2_h * rate_scale,
        .active_root_g_c_step = input.specific_rates.living_stalk_g_c_m2_h * rate_scale,
        .reproductive_g_c_step = input.specific_rates.living_reproductive_g_c_m2_h * rate_scale,
        .standing_dead_g_c_step = input.specific_rates.standing_dead_g_c_m2_h * rate_scale,
    };
    result.fractions = .{
        .root_nonstructural = boundedCombustionFraction(
            input.totals.root_nonstructural_g_c,
            result.potential_rates.root_nonstructural_g_c_step,
            input.negligible_carbon_g_c,
        ),
        .active_root = boundedCombustionFraction(
            input.totals.active_root_g_c,
            result.potential_rates.active_root_g_c_step,
            input.negligible_carbon_g_c,
        ),
        .nodule_nonstructural = boundedCombustionFraction(
            input.totals.nodule_nonstructural_g_c,
            result.potential_rates.root_nonstructural_g_c_step,
            input.negligible_carbon_g_c,
        ),
        .nodule_biomass = boundedCombustionFraction(
            input.totals.nodule_biomass_g_c,
            result.potential_rates.nodule_biomass_g_c_step,
            input.negligible_carbon_g_c,
        ),
        .storage = 0,
    };
    if (input.is_surface_layer) {
        result.fractions.storage = result.fractions.active_root;
        result.storage_combusted = group_misc.scaleElementalMass(
            input.storage,
            result.fractions.storage,
        );
        result.storage_remaining = group_misc.subtractElementalMass(
            input.storage,
            result.storage_combusted,
        );
        result.layer_combustion_g_c += result.storage_combusted.carbon_g;
        result.disturbance_emission_ledger.carbon_g -=
            result.storage_combusted.carbon_g;
        result.disturbance_emission_ledger.nitrogen_g -=
            result.storage_combusted.nitrogen_g;
        result.disturbance_emission_ledger.phosphorus_g -=
            result.storage_combusted.phosphorus_g;
    }
    inline for (@typeInfo(SourceOrderRootCombustionPotentialRates).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result.potential_rates, field.name)))
            return error.NonFiniteRootStorageCombustion;
    inline for (@typeInfo(SourceOrderRootCombustionFractions).@"struct".fields) |field| {
        const value = @field(result.fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.NonFiniteRootStorageCombustion;
    }
    try group_complete_death.validateCompleteDeathResultMass(result.storage_combusted);
    try group_complete_death.validateCompleteDeathResultMass(result.storage_remaining);
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result.disturbance_emission_ledger, field.name)))
            return error.NonFiniteRootStorageCombustion;
    if (!std.math.isFinite(result.temperature_response) or
        !std.math.isFinite(result.layer_combustion_g_c))
        return error.NonFiniteRootStorageCombustion;
    return result;
}

pub const SourceOrderRootCombustionAxisState = struct {
    primary: canopy.ElementalMass,
    secondary: canopy.ElementalMass,
    whole_primary: canopy.ElementalMass,
    primary_length_m: f64,
    secondary_length_m: f64,
    secondary_root_number: f64,
};

pub const SourceOrderRootCombustionDomainState = struct {
    nonstructural: canopy.ElementalMass,
    salts: group_misc.SourceOrderShootSaltInventory,
    active_root_carbon_g_c: f64,
    root_density_g_c_m3: f64,
    root_surface_area_m2: f64,
    primary_root_number: f64,
    root_length_m: f64,
    root_length_growth_m_step: f64,
    root_depth_growth_m_step: f64,
    root_volume_growth_m3_step: f64,
    root_volume_m3: f64,
    root_area_m2: f64,
    axes: []SourceOrderRootCombustionAxisState,
};

pub const SourceOrderRootCombustionDomainLoss = struct {
    nonstructural: canopy.ElementalMass,
    salts: ?group_misc.SourceOrderShootSaltInventory,
    structural: canopy.ElementalMass,
};

pub const SourceOrderRootDomainCombustionResult = struct {
    losses: []SourceOrderRootCombustionDomainLoss,
    layer_combustion_g_c: f64,
    disturbance_emission_ledger: canopy.ElementalMass,

    pub fn deinit(self: SourceOrderRootDomainCombustionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.losses);
    }
};

/// Exact GROSUB 12339-12454 domain/axis root combustion and topology scaling.
pub fn sourceOrderApplyRootDomainCombustion(
    allocator: std.mem.Allocator,
    domains: []SourceOrderRootCombustionDomainState,
    root_nonstructural_fraction: f64,
    active_root_fraction: f64,
    dynamic_salt_enabled: bool,
    preceding_layer_combustion_g_c: f64,
    preceding_disturbance_emission_ledger: canopy.ElementalMass,
) !SourceOrderRootDomainCombustionResult {
    inline for (.{ root_nonstructural_fraction, active_root_fraction }) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidRootDomainCombustionInput;
    if (!std.math.isFinite(preceding_layer_combustion_g_c))
        return error.InvalidRootDomainCombustionInput;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(preceding_disturbance_emission_ledger, field.name)))
            return error.InvalidRootDomainCombustionInput;
    for (domains) |domain| {
        try group_complete_death.validateCompleteDeathMass(domain.nonstructural);
        inline for (@typeInfo(group_misc.SourceOrderShootSaltInventory).@"struct".fields) |field| {
            const value = @field(domain.salts, field.name);
            if (!std.math.isFinite(value) or value < 0)
                return error.InvalidRootDomainCombustionInput;
        }
        inline for (.{
            domain.active_root_carbon_g_c,
            domain.root_density_g_c_m3,
            domain.root_surface_area_m2,
            domain.primary_root_number,
            domain.root_length_m,
            domain.root_length_growth_m_step,
            domain.root_depth_growth_m_step,
            domain.root_volume_growth_m3_step,
            domain.root_volume_m3,
            domain.root_area_m2,
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidRootDomainCombustionInput;
        for (domain.axes) |axis| {
            try group_complete_death.validateCompleteDeathMass(axis.primary);
            try group_complete_death.validateCompleteDeathMass(axis.secondary);
            try group_complete_death.validateCompleteDeathMass(axis.whole_primary);
            inline for (.{
                axis.primary_length_m,
                axis.secondary_length_m,
                axis.secondary_root_number,
            }) |value| if (!std.math.isFinite(value) or value < 0)
                return error.InvalidRootDomainCombustionInput;
        }
    }

    const losses = try allocator.alloc(SourceOrderRootCombustionDomainLoss, domains.len);
    errdefer allocator.free(losses);
    var layer_combustion = preceding_layer_combustion_g_c;
    var emissions = preceding_disturbance_emission_ledger;
    for (domains, losses) |*domain, *loss| {
        loss.nonstructural = group_misc.scaleElementalMass(
            domain.nonstructural,
            root_nonstructural_fraction,
        );
        domain.nonstructural = group_misc.subtractElementalMass(
            domain.nonstructural,
            loss.nonstructural,
        );
        layer_combustion += loss.nonstructural.carbon_g;
        emissions.carbon_g -= loss.nonstructural.carbon_g;
        emissions.nitrogen_g -= loss.nonstructural.nitrogen_g;
        emissions.phosphorus_g -= loss.nonstructural.phosphorus_g;
        loss.salts = if (dynamic_salt_enabled)
            group_misc.scaleSaltInventory(domain.salts, root_nonstructural_fraction)
        else
            null;
        if (loss.salts) |salt_loss|
            domain.salts = group_misc.subtractSaltInventory(domain.salts, salt_loss);

        const remaining_active_fraction = 1 - active_root_fraction;
        inline for (.{
            &domain.active_root_carbon_g_c,
            &domain.root_density_g_c_m3,
            &domain.root_surface_area_m2,
            &domain.primary_root_number,
            &domain.root_length_m,
            &domain.root_length_growth_m_step,
            &domain.root_depth_growth_m_step,
            &domain.root_volume_growth_m3_step,
            &domain.root_volume_m3,
            &domain.root_area_m2,
        }) |attribute| attribute.* *= remaining_active_fraction;
        loss.structural = .{};
        for (domain.axes) |*axis| {
            const primary_loss = group_misc.scaleElementalMass(axis.primary, active_root_fraction);
            const secondary_loss = group_misc.scaleElementalMass(axis.secondary, active_root_fraction);
            axis.primary = group_misc.subtractElementalMass(axis.primary, primary_loss);
            axis.secondary = group_misc.subtractElementalMass(axis.secondary, secondary_loss);
            inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field| {
                @field(loss.structural, field.name) +=
                    @field(primary_loss, field.name) + @field(secondary_loss, field.name);
                @field(axis.whole_primary, field.name) *= remaining_active_fraction;
            }
            axis.primary_length_m *= remaining_active_fraction;
            axis.secondary_length_m *= remaining_active_fraction;
            axis.secondary_root_number *= remaining_active_fraction;
        }
        layer_combustion += loss.structural.carbon_g;
        emissions.carbon_g -= loss.structural.carbon_g;
        emissions.nitrogen_g -= loss.structural.nitrogen_g;
        emissions.phosphorus_g -= loss.structural.phosphorus_g;
    }
    if (!std.math.isFinite(layer_combustion))
        return error.NonFiniteRootDomainCombustion;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(emissions, field.name)))
            return error.NonFiniteRootDomainCombustion;
    return .{
        .losses = losses,
        .layer_combustion_g_c = layer_combustion,
        .disturbance_emission_ledger = emissions,
    };
}

pub const SourceOrderRootNoduleCombustionResult = struct {
    nonstructural_combusted: canopy.ElementalMass,
    nonstructural_remaining: canopy.ElementalMass,
    biomass_combusted: canopy.ElementalMass,
    biomass_remaining: canopy.ElementalMass,
    layer_plant_combustion_g_c: f64,
    grid_layer_combustion_g_c: f64,
    disturbance_emission_ledger: canopy.ElementalMass,
};

/// Exact GROSUB 12461-12492 root-nodule combustion and layer/grid ledgers.
pub fn sourceOrderRootNoduleCombustion(
    nonstructural: canopy.ElementalMass,
    biomass: canopy.ElementalMass,
    nonstructural_fraction: f64,
    biomass_fraction: f64,
    preceding_layer_plant_combustion_g_c: f64,
    preceding_grid_layer_combustion_g_c: f64,
    preceding_disturbance_emission_ledger: canopy.ElementalMass,
) !SourceOrderRootNoduleCombustionResult {
    try group_complete_death.validateCompleteDeathMass(nonstructural);
    try group_complete_death.validateCompleteDeathMass(biomass);
    inline for (.{ nonstructural_fraction, biomass_fraction }) |fraction|
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
            return error.InvalidRootNoduleCombustionInput;
    inline for (.{
        preceding_layer_plant_combustion_g_c,
        preceding_grid_layer_combustion_g_c,
    }) |value| if (!std.math.isFinite(value))
        return error.InvalidRootNoduleCombustionInput;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(preceding_disturbance_emission_ledger, field.name)))
            return error.InvalidRootNoduleCombustionInput;

    const nonstructural_loss = group_misc.scaleElementalMass(nonstructural, nonstructural_fraction);
    const biomass_loss = group_misc.scaleElementalMass(biomass, biomass_fraction);
    const combined_loss: canopy.ElementalMass = .{
        .carbon_g = nonstructural_loss.carbon_g + biomass_loss.carbon_g,
        .nitrogen_g = nonstructural_loss.nitrogen_g + biomass_loss.nitrogen_g,
        .phosphorus_g = nonstructural_loss.phosphorus_g + biomass_loss.phosphorus_g,
    };
    const plant_layer = preceding_layer_plant_combustion_g_c + combined_loss.carbon_g;
    const grid_layer = preceding_grid_layer_combustion_g_c + plant_layer;
    const emissions: canopy.ElementalMass = .{
        .carbon_g = preceding_disturbance_emission_ledger.carbon_g -
            combined_loss.carbon_g,
        .nitrogen_g = preceding_disturbance_emission_ledger.nitrogen_g -
            combined_loss.nitrogen_g,
        .phosphorus_g = preceding_disturbance_emission_ledger.phosphorus_g -
            combined_loss.phosphorus_g,
    };
    const result: SourceOrderRootNoduleCombustionResult = .{
        .nonstructural_combusted = nonstructural_loss,
        .nonstructural_remaining = group_misc.subtractElementalMass(nonstructural, nonstructural_loss),
        .biomass_combusted = biomass_loss,
        .biomass_remaining = group_misc.subtractElementalMass(biomass, biomass_loss),
        .layer_plant_combustion_g_c = plant_layer,
        .grid_layer_combustion_g_c = grid_layer,
        .disturbance_emission_ledger = emissions,
    };
    try group_complete_death.validateCompleteDeathResultMass(result.nonstructural_remaining);
    try group_complete_death.validateCompleteDeathResultMass(result.biomass_remaining);
    if (!std.math.isFinite(plant_layer) or !std.math.isFinite(grid_layer))
        return error.NonFiniteRootNoduleCombustion;
    inline for (@typeInfo(canopy.ElementalMass).@"struct".fields) |field|
        if (!std.math.isFinite(@field(emissions, field.name)))
            return error.NonFiniteRootNoduleCombustion;
    return result;
}

pub const SourceOrderRootAxisCombustionReset = struct {
    primary: canopy.ElementalMass,
    secondary: canopy.ElementalMass,
};

pub const SourceOrderColdSoilCombustionReset = struct {
    layer_plant_combustion_g_c: f64 = 0,
    storage_combustion: ?canopy.ElementalMass,
    domains: []SourceOrderRootCombustionDomainLoss,
    axis_offsets: []usize,
    axes: []SourceOrderRootAxisCombustionReset,
    nodule_nonstructural_combustion: canopy.ElementalMass = .{},
    nodule_biomass_combustion: canopy.ElementalMass = .{},

    pub fn deinit(self: SourceOrderColdSoilCombustionReset, allocator: std.mem.Allocator) void {
        allocator.free(self.domains);
        allocator.free(self.axis_offsets);
        allocator.free(self.axes);
    }
};

/// Exact GROSUB 12506-12541 cold-soil root/storage/nodule rate reset.
pub fn sourceOrderResetColdSoilCombustion(
    allocator: std.mem.Allocator,
    root_axis_counts_by_domain: []const usize,
    is_surface_layer: bool,
    dynamic_salt_enabled: bool,
) !SourceOrderColdSoilCombustionReset {
    const offset_count = std.math.add(
        usize,
        root_axis_counts_by_domain.len,
        1,
    ) catch return error.InvalidColdSoilCombustionDimensions;
    const axis_offsets = try allocator.alloc(usize, offset_count);
    errdefer allocator.free(axis_offsets);
    axis_offsets[0] = 0;
    for (root_axis_counts_by_domain, 0..) |axis_count, domain|
        axis_offsets[domain + 1] = std.math.add(
            usize,
            axis_offsets[domain],
            axis_count,
        ) catch return error.InvalidColdSoilCombustionDimensions;

    const domains = try allocator.alloc(
        SourceOrderRootCombustionDomainLoss,
        root_axis_counts_by_domain.len,
    );
    errdefer allocator.free(domains);
    for (domains) |*domain| domain.* = .{
        .nonstructural = .{},
        .salts = if (dynamic_salt_enabled)
            std.mem.zeroes(group_misc.SourceOrderShootSaltInventory)
        else
            null,
        .structural = .{},
    };

    const axes = try allocator.alloc(
        SourceOrderRootAxisCombustionReset,
        axis_offsets[axis_offsets.len - 1],
    );
    errdefer allocator.free(axes);
    @memset(axes, std.mem.zeroes(SourceOrderRootAxisCombustionReset));
    return .{
        .storage_combustion = if (is_surface_layer) .{} else null,
        .domains = domains,
        .axis_offsets = axis_offsets,
        .axes = axes,
    };
}

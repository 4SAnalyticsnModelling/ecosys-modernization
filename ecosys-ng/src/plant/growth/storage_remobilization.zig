const std = @import("std");
const CanopyState = @import("../../canopy/photosynthesis/photosynthesis.zig").State;
const RootState = @import("../root/plant_root_system.zig").State;
const LitterPartition = @import("../partition/litter.zig");
const RootLitter = @import("../root/plant_root_metabolism.zig").RootLitter;

pub const StorageElementMass = struct {
    carbon_g_c: f64,
    nitrogen_g_n: f64,
    phosphorus_g_p: f64,
};

pub const StorageRetention = struct {
    carbon: f64,
    nitrogen: f64,
    phosphorus: f64,
};

pub const StorageComposition = struct {
    carbon_woody_nonwoody: [2]f64,
    nitrogen_woody_nonwoody: [2]f64,
    phosphorus_woody_nonwoody: [2]f64,
};

pub const StorageHarvestResult = struct {
    remaining: StorageElementMass,
    litterfall: RootLitter,
};

/// Exact GROSUB 9980-9998 perennial storage harvest transaction.
pub fn sourceOrderPerennialStorageHarvest(
    perennial: bool,
    storage: StorageElementMass,
    retention: StorageRetention,
    composition: StorageComposition,
    nonstructural_litter: LitterPartition.ElementFractions,
) !StorageHarvestResult {
    inline for (.{ storage.carbon_g_c, storage.nitrogen_g_n, storage.phosphorus_g_p }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStorageHarvestInput;
    inline for (.{ retention.carbon, retention.nitrogen, retention.phosphorus }) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidStorageHarvestInput;
    inline for (.{
        composition.carbon_woody_nonwoody,
        composition.nitrogen_woody_nonwoody,
        composition.phosphorus_woody_nonwoody,
    }) |fractions| {
        for (fractions) |value|
            if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidStorageHarvestInput;
        if (@abs(fractions[0] + fractions[1] - 1) > 1e-12)
            return error.NonConservativeStorageComposition;
    }
    try nonstructural_litter.validate();
    if (!perennial) return .{
        .remaining = storage,
        .litterfall = std.mem.zeroes(RootLitter),
    };

    const removed = StorageElementMass{
        .carbon_g_c = (1 - retention.carbon) * storage.carbon_g_c,
        .nitrogen_g_n = (1 - retention.nitrogen) * storage.nitrogen_g_n,
        .phosphorus_g_p = (1 - retention.phosphorus) * storage.phosphorus_g_p,
    };
    var litterfall = std.mem.zeroes(RootLitter);
    for (0..LitterPartition.kinetic_component_count) |component| {
        litterfall.woody_carbon_g_c[component] = removed.carbon_g_c *
            nonstructural_litter.carbon[component] * composition.carbon_woody_nonwoody[0];
        litterfall.woody_nitrogen_g_n[component] = removed.nitrogen_g_n *
            nonstructural_litter.nitrogen[component] * composition.nitrogen_woody_nonwoody[0];
        litterfall.woody_phosphorus_g_p[component] = removed.phosphorus_g_p *
            nonstructural_litter.phosphorus[component] * composition.phosphorus_woody_nonwoody[0];
        litterfall.nonwoody_carbon_g_c[component] = removed.carbon_g_c *
            nonstructural_litter.carbon[component] * composition.carbon_woody_nonwoody[1];
        litterfall.nonwoody_nitrogen_g_n[component] = removed.nitrogen_g_n *
            nonstructural_litter.nitrogen[component] * composition.nitrogen_woody_nonwoody[1];
        litterfall.nonwoody_phosphorus_g_p[component] = removed.phosphorus_g_p *
            nonstructural_litter.phosphorus[component] * composition.phosphorus_woody_nonwoody[1];
    }
    return .{
        .remaining = .{
            .carbon_g_c = retention.carbon * storage.carbon_g_c,
            .nitrogen_g_n = retention.nitrogen * storage.nitrogen_g_n,
            .phosphorus_g_p = retention.phosphorus * storage.phosphorus_g_p,
        },
        .litterfall = litterfall,
    };
}

/// Exact GROSUB 10465-10481 seasonal-storage litter and retention during
/// tillage. This block is unconditional within an eligible tillage event.
pub fn sourceOrderStorageTillage(
    storage: StorageElementMass,
    remaining_fraction: f64,
    composition: StorageComposition,
    nonstructural_litter: LitterPartition.ElementFractions,
) !StorageHarvestResult {
    if (!std.math.isFinite(remaining_fraction) or remaining_fraction < 0 or remaining_fraction > 1)
        return error.InvalidStorageHarvestInput;
    return sourceOrderPerennialStorageHarvest(
        true,
        storage,
        .{
            .carbon = remaining_fraction,
            .nitrogen = remaining_fraction,
            .phosphorus = remaining_fraction,
        },
        composition,
        nonstructural_litter,
    );
}

pub const Parameters = struct {
    remobilization_duration_h: [2]f64,
    storage_carbon_oxidation_fraction_per_h: [2]f64,
    shoot_carbon_partition_fraction: [2]f64,
    root_carbon_partition_fraction: [2]f64,
    perennial_nutrient_equilibration_fraction_per_h: [6]f64,
    minimum_mobile_nitrogen_per_carbon_g_n_per_g_c: f64,
    maximum_mobile_nitrogen_per_carbon_g_n_per_g_c: f64,
    minimum_mobile_phosphorus_per_carbon_g_p_per_g_c: f64,
    maximum_mobile_phosphorus_per_carbon_g_p_per_g_c: f64,
    depleted_storage_threshold_g_c_per_g_root_c: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| {
            if (field.type == f64) {
                const value = @field(self, field.name);
                if (!std.math.isFinite(value) or value < 0) return error.InvalidStorageRemobilizationParameter;
            } else for (@field(self, field.name)) |value| {
                if (!std.math.isFinite(value) or value < 0) return error.InvalidStorageRemobilizationParameter;
            }
        }
        for (0..2) |habit| {
            if (self.remobilization_duration_h[habit] == 0 or @abs(self.shoot_carbon_partition_fraction[habit] + self.root_carbon_partition_fraction[habit] - 1) > 1.0e-12) return error.InvalidStorageRemobilizationParameter;
        }
        if (self.minimum_mobile_nitrogen_per_carbon_g_n_per_g_c <= 0 or self.minimum_mobile_phosphorus_per_carbon_g_p_per_g_c <= 0 or self.maximum_mobile_nitrogen_per_carbon_g_n_per_g_c < self.minimum_mobile_nitrogen_per_carbon_g_n_per_g_c or self.maximum_mobile_phosphorus_per_carbon_g_p_per_g_c < self.minimum_mobile_phosphorus_per_carbon_g_p_per_g_c) return error.InvalidStorageRemobilizationParameter;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .remobilization_duration_h = .{ 45.8, 138.4 },
        .storage_carbon_oxidation_fraction_per_h = .{ 0.015, 0.005 },
        .shoot_carbon_partition_fraction = .{ 0.25, 0.25 },
        .root_carbon_partition_fraction = .{ 0.75, 0.75 },
        .perennial_nutrient_equilibration_fraction_per_h = .{ 0.100, 0.100, 0.010, 0.100, 0.100, 0.100 },
        .minimum_mobile_nitrogen_per_carbon_g_n_per_g_c = 0.050,
        .maximum_mobile_nitrogen_per_carbon_g_n_per_g_c = 0.20,
        .minimum_mobile_phosphorus_per_carbon_g_p_per_g_c = 0.005,
        .maximum_mobile_phosphorus_per_carbon_g_p_per_g_c = 0.020,
        .depleted_storage_threshold_g_c_per_g_root_c = 0.10,
    };
}

pub const Inputs = struct {
    growth_habit: u8,
    aboveground_turnover_type: u8,
    accumulated_remobilization_h: f64,
    remobilization_time_increment_h: f64,
    biological_timestep_h: f64,
    storage_carbon_g_c: f64,
    storage_nitrogen_g_n: f64,
    storage_phosphorus_g_p: f64,
    shoot_mobile_carbon_g_c: f64,
    shoot_mobile_nitrogen_g_n: f64,
    shoot_mobile_phosphorus_g_p: f64,
    root_mobile_carbon_g_c: f64,
    root_mobile_nitrogen_g_n: f64,
    root_mobile_phosphorus_g_p: f64,
    continue_annual_remobilization_after_duration: bool,
    /// Population-scaled source ZEROP for this plant.
    presence_threshold_g_c: f64,
};

pub const ActivationInputs = struct {
    annual_growth_habit: bool,
    lifecycle_initialized: bool,
    current_day_of_year: u16,
    current_year: i32,
    planting_day_of_year: u16,
    planting_year: i32,
    accumulated_leafout_h: f64,
    required_leafout_h: f64,
    accumulated_leafoff_h: f64,
    required_leafoff_h: f64,
    leafoff_remobilization_start_fraction: f64,
};

/// GROSUB seasonal-storage outer gate preceding ATRP/DATRP.
pub fn activationEnabled(inputs: ActivationInputs) !bool {
    inline for (.{
        inputs.accumulated_leafout_h,
        inputs.required_leafout_h,
        inputs.accumulated_leafoff_h,
        inputs.required_leafoff_h,
        inputs.leafoff_remobilization_start_fraction,
    }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidStorageRemobilizationActivation;
    if (inputs.current_day_of_year == 0 or inputs.current_day_of_year > 366 or
        inputs.planting_day_of_year == 0 or inputs.planting_day_of_year > 366 or
        inputs.leafoff_remobilization_start_fraction > 1)
        return error.InvalidStorageRemobilizationActivation;
    const before_leafoff_remobilization =
        inputs.accumulated_leafoff_h <
        inputs.leafoff_remobilization_start_fraction * inputs.required_leafoff_h;
    return (inputs.annual_growth_habit and !inputs.lifecycle_initialized) or
        (inputs.current_year == inputs.planting_year and
            inputs.current_day_of_year >= inputs.planting_day_of_year and
            before_leafoff_remobilization) or
        (inputs.accumulated_leafout_h >= inputs.required_leafout_h and
            before_leafoff_remobilization);
}

/// Source DATRP = TFN3 * WFNSG * XNFH.
pub fn remobilizationTimeIncrementH(
    growth_temperature_response: f64,
    growth_water_fraction: f64,
    biological_timestep_h: f64,
) !f64 {
    inline for (.{ growth_temperature_response, growth_water_fraction, biological_timestep_h }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStorageRemobilizationTimeIncrement;
    if (biological_timestep_h <= 0)
        return error.InvalidStorageRemobilizationTimeIncrement;
    const increment_h = growth_temperature_response * growth_water_fraction * biological_timestep_h;
    if (!std.math.isFinite(increment_h)) return error.NonFiniteStorageRemobilizationTimeIncrement;
    return increment_h;
}

pub const Transfers = struct {
    oxidized_storage_carbon_g_c: f64,
    shoot_carbon_g_c: f64,
    root_carbon_g_c: f64,
    shoot_nitrogen_g_n: f64,
    root_nitrogen_g_n: f64,
    shoot_phosphorus_g_p: f64,
    root_phosphorus_g_p: f64,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    soil_layer_count: usize,
    root_layer_indices: []usize,
    structural_carbon_fractions: []f64,
    mobile_carbon_fractions: []f64,
    seasonal_storage_transfers: []ElementTransfer,
    /// GROSUB carried WTRT at entry, before any current-hour CH2OH, root
    /// metabolism/growth, or root-shoot exchange changes root pools.
    carried_total_root_carbon_g_c: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize, soil_layer_count: usize) !Workspace {
        if (plant_count == 0 or soil_layer_count == 0) return error.InvalidStorageRemobilizationDimensions;
        const count = try std.math.mul(usize, plant_count, soil_layer_count);
        const indices = try allocator.alloc(usize, count);
        errdefer allocator.free(indices);
        const structural = try allocator.alloc(f64, count);
        errdefer allocator.free(structural);
        const mobile = try allocator.alloc(f64, count);
        errdefer allocator.free(mobile);
        const seasonal = try allocator.alloc(ElementTransfer, count);
        errdefer allocator.free(seasonal);
        const carried_root = try allocator.alloc(f64, plant_count);
        @memset(indices, 0);
        @memset(structural, 0);
        @memset(mobile, 0);
        @memset(seasonal, .{});
        @memset(carried_root, 0);
        return .{ .allocator = allocator, .plant_count = plant_count, .soil_layer_count = soil_layer_count, .root_layer_indices = indices, .structural_carbon_fractions = structural, .mobile_carbon_fractions = mobile, .seasonal_storage_transfers = seasonal, .carried_total_root_carbon_g_c = carried_root };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.carried_total_root_carbon_g_c);
        self.allocator.free(self.seasonal_storage_transfers);
        self.allocator.free(self.mobile_carbon_fractions);
        self.allocator.free(self.structural_carbon_fractions);
        self.allocator.free(self.root_layer_indices);
        self.* = undefined;
    }

    pub const PlantSlices = struct {
        root_layer_indices: []usize,
        structural_carbon_fractions: []f64,
        mobile_carbon_fractions: []f64,
        seasonal_storage_transfers: []ElementTransfer,
    };

    /// GROSUB FXFC/FXFN allocation, including the planting-layer fallback.
    pub fn refreshPlant(self: *Workspace, roots: *const RootState, plant: usize) !PlantSlices {
        if (plant >= self.plant_count or roots.plant_count != self.plant_count or roots.soil_layer_count != self.soil_layer_count) return error.StorageRemobilizationDimensionMismatch;
        const first = plant * self.soil_layer_count;
        const indices = self.root_layer_indices[first..][0..self.soil_layer_count];
        const structural = self.structural_carbon_fractions[first..][0..self.soil_layer_count];
        const mobile = self.mobile_carbon_fractions[first..][0..self.soil_layer_count];
        // Reject corrupt authoritative pools before touching the reusable
        // workspace; negative mass must never disappear from allocation.
        for (0..self.soil_layer_count) |layer| {
            const root = try roots.layerIndex(plant, 0, layer);
            if (!std.math.isFinite(roots.mobile_carbon_g[root]) or roots.mobile_carbon_g[root] < 0) return error.InvalidStorageRemobilizationRootState;
            for (0..roots.root_axis_count) |axis| {
                const axis_layer = try roots.layerAxisIndex(plant, 0, layer, axis);
                inline for (.{ roots.axis_primary_carbon_g[axis_layer], roots.axis_secondary_carbon_g[axis_layer] }) |value|
                    if (!std.math.isFinite(value) or value < 0) return error.InvalidStorageRemobilizationRootState;
            }
        }
        var structural_total: f64 = 0;
        var mobile_total: f64 = 0;
        for (0..self.soil_layer_count) |layer| {
            const root = try roots.layerIndex(plant, 0, layer);
            indices[layer] = root;
            var layer_structural: f64 = 0;
            for (0..roots.root_axis_count) |axis| {
                const axis_layer = try roots.layerAxisIndex(plant, 0, layer, axis);
                layer_structural += roots.axis_primary_carbon_g[axis_layer] + roots.axis_secondary_carbon_g[axis_layer];
            }
            structural[layer] = layer_structural;
            mobile[layer] = roots.mobile_carbon_g[root];
            structural_total += structural[layer];
            mobile_total += mobile[layer];
        }
        const planting_layer = roots.planting_layer_by_plant[plant];
        for (0..self.soil_layer_count) |layer| {
            structural[layer] = if (structural_total > 0) structural[layer] / structural_total else @floatFromInt(@intFromBool(layer == planting_layer));
            // The source uses CPOOLR fractions only when both structural and
            // mobile root C totals exist; otherwise it uses the planting layer.
            mobile[layer] = if (structural_total > 0 and mobile_total > 0) mobile[layer] / mobile_total else @floatFromInt(@intFromBool(layer == planting_layer));
        }
        return .{ .root_layer_indices = indices, .structural_carbon_fractions = structural, .mobile_carbon_fractions = mobile, .seasonal_storage_transfers = self.seasonal_storage_transfers[first..][0..self.soil_layer_count] };
    }
};

pub const ElementTransfer = struct {
    carbon_g_c: f64 = 0,
    nitrogen_g_n: f64 = 0,
    phosphorus_g_p: f64 = 0,
};

pub const GrowthHabit = enum {
    annual,
    perennial,
};

pub const DepletedStorageInputs = struct {
    growth_habit: GrowthHabit,
    layer_is_rooted: bool,
    layer_active_root_carbon_g_c: f64,
    plant_total_root_carbon_g_c: f64,
    layer_mobile_carbon_g_c: f64,
    seasonal_storage_carbon_g_c: f64,
    storage_deficit_threshold_g_c_per_g_root_c: f64,
    exchange_fraction_per_h: f64,
    biological_timestep_h: f64,
    presence_threshold_g_c: f64,
};

pub const DepletedStorageResult = struct {
    root_to_storage_carbon_g_c: f64,
    next_layer_mobile_carbon_g_c: f64,
    next_seasonal_storage_carbon_g_c: f64,
};

pub const LowBranchReserveInputs = struct {
    branch_sapwood_carbon_g_c: f64,
    plant_total_sapwood_carbon_g_c: f64,
    plant_total_root_carbon_g_c: f64,
    branch_reserve_carbon_g_c: f64,
    seasonal_storage_carbon_g_c: f64,
    low_reserve_threshold_g_c_per_g_sapwood_c: f64,
    exchange_fraction_per_h: f64,
    biological_timestep_h: f64,
    presence_threshold_g_c: f64,
};

pub const LowBranchReserveResult = struct {
    storage_to_branch_reserve_carbon_g_c: f64,
    next_branch_reserve_carbon_g_c: f64,
    next_seasonal_storage_carbon_g_c: f64,
};

pub const BranchStorageRemobilizationInputs = struct {
    shoot_remobilization_enabled: bool,
    growth_habit: GrowthHabit,
    branch_reserve: ElementTransfer,
    branch_mobile: ElementTransfer,
    seasonal_storage: ElementTransfer,
    exchange_fraction_per_h: f64,
    biological_timestep_h: f64,
};

pub const BranchStorageRemobilizationResult = struct {
    next_branch_reserve: ElementTransfer,
    next_branch_mobile: ElementTransfer,
    next_seasonal_storage: ElementTransfer,
    reserve_to_storage: ElementTransfer,
    mobile_to_storage: ElementTransfer,
};

pub const AnnualRootReserveExchangeInputs = struct {
    growth_habit: GrowthHabit,
    final_seed_number_is_set: bool,
    layer_is_soil: bool,
    active_root_carbon_g_c: f64,
    /// GROSUB FWODR(1): fine/non-woody root carbon fraction.
    root_nonwoody_carbon_fraction: f64,
    branch_sapwood_carbon_g_c: f64,
    root_mobile: ElementTransfer,
    branch_reserve: ElementTransfer,
    carbon_exchange_fraction_per_h: f64,
    nutrient_exchange_fraction_per_h: f64,
    biological_timestep_h: f64,
    presence_threshold_g_c: f64,
};

pub const AnnualRootReserveExchangeResult = struct {
    next_root_mobile: ElementTransfer,
    next_branch_reserve: ElementTransfer,
    root_to_reserve: ElementTransfer,
};

pub const BranchMobileReserveExchangeInputs = struct {
    growth_habit: GrowthHabit,
    annual_final_seed_number_is_set: bool,
    perennial_stem_elongation_started: bool,
    branch_leaf_and_petiole_carbon_g_c: f64,
    branch_sapwood_carbon_g_c: f64,
    branch_mobile: ElementTransfer,
    branch_reserve: ElementTransfer,
    maximum_mobile_nitrogen_per_carbon_g_n_per_g_c: f64,
    maximum_mobile_phosphorus_per_carbon_g_p_per_g_c: f64,
    carbon_exchange_fraction_per_h: f64,
    nutrient_exchange_fraction_per_h: f64,
    biological_timestep_h: f64,
    presence_threshold_g_c: f64,
};

pub const BranchMobileReserveExchangeResult = struct {
    next_branch_mobile: ElementTransfer,
    next_branch_reserve: ElementTransfer,
    mobile_to_reserve: ElementTransfer,
};

/// GROSUB 4966-5020 signed branch-mobile/stalk-reserve equilibration. Carbon
/// is state_updateted conceptually before the N/P gradients and excess corrections.
pub fn equilibrateBranchMobileAndReserve(inputs: BranchMobileReserveExchangeInputs) !BranchMobileReserveExchangeResult {
    inline for (@typeInfo(BranchMobileReserveExchangeInputs).@"struct".fields) |field| {
        if (field.type == f64) {
            const value = @field(inputs, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidBranchMobileReserveExchangeInput;
        }
    }
    inline for (.{ inputs.branch_mobile, inputs.branch_reserve }) |pool|
        inline for (@typeInfo(ElementTransfer).@"struct".fields) |field| {
            const value = @field(pool, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidBranchMobileReserveExchangeInput;
        };
    if (inputs.biological_timestep_h <= 0) return error.InvalidBranchMobileReserveExchangeInput;

    const lifecycle_enabled = switch (inputs.growth_habit) {
        .annual => inputs.annual_final_seed_number_is_set,
        .perennial => inputs.perennial_stem_elongation_started,
    };
    if (!lifecycle_enabled or inputs.branch_leaf_and_petiole_carbon_g_c <= inputs.presence_threshold_g_c) return .{
        .next_branch_mobile = inputs.branch_mobile,
        .next_branch_reserve = inputs.branch_reserve,
        .mobile_to_reserve = .{},
    };

    const structural_total_g_c = inputs.branch_leaf_and_petiole_carbon_g_c + inputs.branch_sapwood_carbon_g_c;
    const mobile_carbon_total_g_c = inputs.branch_mobile.carbon_g_c + inputs.branch_reserve.carbon_g_c;
    const carbon_difference_g_c = (inputs.branch_mobile.carbon_g_c * inputs.branch_sapwood_carbon_g_c -
        inputs.branch_reserve.carbon_g_c * inputs.branch_leaf_and_petiole_carbon_g_c) / structural_total_g_c;
    var transfer: ElementTransfer = .{
        .carbon_g_c = inputs.carbon_exchange_fraction_per_h * carbon_difference_g_c * inputs.biological_timestep_h,
    };
    const mobile_after_carbon_g_c = inputs.branch_mobile.carbon_g_c - transfer.carbon_g_c;
    const reserve_after_carbon_g_c = inputs.branch_reserve.carbon_g_c + transfer.carbon_g_c;
    if (mobile_carbon_total_g_c > inputs.presence_threshold_g_c) {
        const nitrogen_difference_g_n = (inputs.branch_mobile.nitrogen_g_n * reserve_after_carbon_g_c -
            inputs.branch_reserve.nitrogen_g_n * mobile_after_carbon_g_c) / mobile_carbon_total_g_c;
        const phosphorus_difference_g_p = (inputs.branch_mobile.phosphorus_g_p * reserve_after_carbon_g_c -
            inputs.branch_reserve.phosphorus_g_p * mobile_after_carbon_g_c) / mobile_carbon_total_g_c;
        transfer.nitrogen_g_n = inputs.nutrient_exchange_fraction_per_h * nitrogen_difference_g_n * inputs.biological_timestep_h -
            @max(0, inputs.branch_reserve.nitrogen_g_n - reserve_after_carbon_g_c * inputs.maximum_mobile_nitrogen_per_carbon_g_n_per_g_c);
        transfer.phosphorus_g_p = inputs.nutrient_exchange_fraction_per_h * phosphorus_difference_g_p * inputs.biological_timestep_h -
            @max(0, inputs.branch_reserve.phosphorus_g_p - reserve_after_carbon_g_c * inputs.maximum_mobile_phosphorus_per_carbon_g_p_per_g_c);
    }
    const next_mobile = subtractElements(inputs.branch_mobile, transfer);
    const next_reserve = addElements(inputs.branch_reserve, transfer);
    inline for (.{ next_mobile, next_reserve }) |pool|
        inline for (@typeInfo(ElementTransfer).@"struct".fields) |field| {
            const value = @field(pool, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.BranchMobileReserveExchangeWouldOverdraw;
        };
    return .{ .next_branch_mobile = next_mobile, .next_branch_reserve = next_reserve, .mobile_to_reserve = transfer };
}

/// GROSUB 5050-5110 annual grain-fill transfer from one host-root layer into
/// stalk reserve. The source updates carbon before evaluating N and P.
pub fn transferAnnualRootMobileToBranchReserve(inputs: AnnualRootReserveExchangeInputs) !AnnualRootReserveExchangeResult {
    inline for (@typeInfo(AnnualRootReserveExchangeInputs).@"struct".fields) |field| {
        if (field.type == f64) {
            const value = @field(inputs, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidAnnualRootReserveExchangeInput;
        }
    }
    inline for (.{ inputs.root_mobile, inputs.branch_reserve }) |pool|
        inline for (@typeInfo(ElementTransfer).@"struct".fields) |field| {
            const value = @field(pool, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidAnnualRootReserveExchangeInput;
        };
    if (inputs.root_nonwoody_carbon_fraction > 1 or inputs.biological_timestep_h <= 0) return error.InvalidAnnualRootReserveExchangeInput;

    const unchanged: AnnualRootReserveExchangeResult = .{
        .next_root_mobile = inputs.root_mobile,
        .next_branch_reserve = inputs.branch_reserve,
        .root_to_reserve = .{},
    };
    if (inputs.growth_habit != .annual or !inputs.final_seed_number_is_set or !inputs.layer_is_soil or inputs.active_root_carbon_g_c <= inputs.presence_threshold_g_c)
        return unchanged;

    const effective_root_structural_carbon_g_c = @max(inputs.presence_threshold_g_c, inputs.active_root_carbon_g_c * inputs.root_nonwoody_carbon_fraction);
    const structural_total_g_c = effective_root_structural_carbon_g_c + inputs.branch_sapwood_carbon_g_c;
    const carbon_difference_g_c = (inputs.root_mobile.carbon_g_c * inputs.branch_sapwood_carbon_g_c -
        inputs.branch_reserve.carbon_g_c * effective_root_structural_carbon_g_c) / structural_total_g_c;
    var transfer: ElementTransfer = .{
        .carbon_g_c = @max(0, inputs.carbon_exchange_fraction_per_h * carbon_difference_g_c) * inputs.biological_timestep_h,
    };
    const root_after_carbon_g_c = inputs.root_mobile.carbon_g_c - transfer.carbon_g_c;
    const reserve_after_carbon_g_c = inputs.branch_reserve.carbon_g_c + transfer.carbon_g_c;
    const mobile_carbon_total_g_c = root_after_carbon_g_c + reserve_after_carbon_g_c;
    if (mobile_carbon_total_g_c > inputs.presence_threshold_g_c) {
        const nitrogen_difference_g_n = (inputs.root_mobile.nitrogen_g_n * reserve_after_carbon_g_c -
            inputs.branch_reserve.nitrogen_g_n * root_after_carbon_g_c) / mobile_carbon_total_g_c;
        const phosphorus_difference_g_p = (inputs.root_mobile.phosphorus_g_p * reserve_after_carbon_g_c -
            inputs.branch_reserve.phosphorus_g_p * root_after_carbon_g_c) / mobile_carbon_total_g_c;
        transfer.nitrogen_g_n = @max(0, @min(inputs.root_mobile.nitrogen_g_n, inputs.nutrient_exchange_fraction_per_h * nitrogen_difference_g_n)) * inputs.biological_timestep_h;
        // Exact source behavior: XFRP is capped by ZPOOLR, not PPOOLR.
        transfer.phosphorus_g_p = @max(0, @min(inputs.root_mobile.nitrogen_g_n, inputs.nutrient_exchange_fraction_per_h * phosphorus_difference_g_p)) * inputs.biological_timestep_h;
    }
    const next_root = subtractElements(inputs.root_mobile, transfer);
    const next_reserve = addElements(inputs.branch_reserve, transfer);
    inline for (.{ next_root, next_reserve }) |pool|
        inline for (@typeInfo(ElementTransfer).@"struct".fields) |field| {
            const value = @field(pool, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.AnnualRootReserveExchangeWouldOverdraw;
        };
    return .{ .next_root_mobile = next_root, .next_branch_reserve = next_reserve, .root_to_reserve = transfer };
}

/// GROSUB 4902-4964 transfers branch reserve and then branch mobile C/N/P to
/// perennial seasonal storage. Category order and the coupled element bounds
/// are retained exactly.
pub fn remobilizeBranchPoolsToSeasonalStorage(parameters: Parameters, inputs: BranchStorageRemobilizationInputs) !BranchStorageRemobilizationResult {
    try parameters.validate();
    inline for (.{ inputs.branch_reserve, inputs.branch_mobile, inputs.seasonal_storage }) |pool|
        inline for (@typeInfo(ElementTransfer).@"struct".fields) |field| {
            const value = @field(pool, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidBranchStorageRemobilizationInput;
        };
    inline for (.{ inputs.exchange_fraction_per_h, inputs.biological_timestep_h }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidBranchStorageRemobilizationInput;
    if (inputs.biological_timestep_h <= 0) return error.InvalidBranchStorageRemobilizationInput;

    const zero: ElementTransfer = .{};
    if (!inputs.shoot_remobilization_enabled or inputs.growth_habit == .annual) return .{
        .next_branch_reserve = inputs.branch_reserve,
        .next_branch_mobile = inputs.branch_mobile,
        .next_seasonal_storage = inputs.seasonal_storage,
        .reserve_to_storage = zero,
        .mobile_to_storage = zero,
    };
    const reserve_transfer = try rootToSeasonalStorage(
        parameters,
        inputs.branch_reserve.carbon_g_c,
        inputs.branch_reserve.nitrogen_g_n,
        inputs.branch_reserve.phosphorus_g_p,
        inputs.exchange_fraction_per_h,
        inputs.biological_timestep_h,
    );
    const mobile_transfer = try rootToSeasonalStorage(
        parameters,
        inputs.branch_mobile.carbon_g_c,
        inputs.branch_mobile.nitrogen_g_n,
        inputs.branch_mobile.phosphorus_g_p,
        inputs.exchange_fraction_per_h,
        inputs.biological_timestep_h,
    );
    const next_reserve = subtractElements(inputs.branch_reserve, reserve_transfer);
    const next_mobile = subtractElements(inputs.branch_mobile, mobile_transfer);
    const next_storage = addElements(addElements(inputs.seasonal_storage, reserve_transfer), mobile_transfer);
    inline for (.{ next_reserve, next_mobile, next_storage }) |pool|
        inline for (@typeInfo(ElementTransfer).@"struct".fields) |field| {
            const value = @field(pool, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.BranchStorageRemobilizationWouldOverdraw;
        };
    return .{
        .next_branch_reserve = next_reserve,
        .next_branch_mobile = next_mobile,
        .next_seasonal_storage = next_storage,
        .reserve_to_storage = reserve_transfer,
        .mobile_to_storage = mobile_transfer,
    };
}

fn addElements(a: ElementTransfer, b: ElementTransfer) ElementTransfer {
    return .{
        .carbon_g_c = a.carbon_g_c + b.carbon_g_c,
        .nitrogen_g_n = a.nitrogen_g_n + b.nitrogen_g_n,
        .phosphorus_g_p = a.phosphorus_g_p + b.phosphorus_g_p,
    };
}

fn subtractElements(a: ElementTransfer, b: ElementTransfer) ElementTransfer {
    return .{
        .carbon_g_c = a.carbon_g_c - b.carbon_g_c,
        .nitrogen_g_n = a.nitrogen_g_n - b.nitrogen_g_n,
        .phosphorus_g_p = a.phosphorus_g_p - b.phosphorus_g_p,
    };
}

/// GROSUB 5021-5047 seasonal-storage replenishment of a low branch reserve.
/// The source transfer `XFRC` is positive from whole-plant storage to branch.
pub fn replenishLowBranchReserve(inputs: LowBranchReserveInputs) !LowBranchReserveResult {
    inline for (@typeInfo(LowBranchReserveInputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidLowBranchReserveInput;
    }
    if (inputs.biological_timestep_h <= 0) return error.InvalidLowBranchReserveInput;

    const unchanged: LowBranchReserveResult = .{
        .storage_to_branch_reserve_carbon_g_c = 0,
        .next_branch_reserve_carbon_g_c = inputs.branch_reserve_carbon_g_c,
        .next_seasonal_storage_carbon_g_c = inputs.seasonal_storage_carbon_g_c,
    };
    if (inputs.branch_sapwood_carbon_g_c <= inputs.presence_threshold_g_c or
        inputs.plant_total_sapwood_carbon_g_c <= inputs.presence_threshold_g_c or
        inputs.plant_total_root_carbon_g_c <= inputs.presence_threshold_g_c or
        inputs.branch_reserve_carbon_g_c > inputs.low_reserve_threshold_g_c_per_g_sapwood_c * inputs.branch_sapwood_carbon_g_c)
        return unchanged;

    const branch_sapwood_fraction = inputs.branch_sapwood_carbon_g_c / inputs.plant_total_sapwood_carbon_g_c;
    const allocated_root_carbon_g_c = inputs.plant_total_root_carbon_g_c * branch_sapwood_fraction;
    const structural_total_g_c = inputs.branch_sapwood_carbon_g_c + allocated_root_carbon_g_c;
    const branch_storage_carbon_g_c = inputs.seasonal_storage_carbon_g_c * branch_sapwood_fraction;
    const concentration_difference_g_c = (branch_storage_carbon_g_c * inputs.branch_sapwood_carbon_g_c -
        inputs.branch_reserve_carbon_g_c * allocated_root_carbon_g_c) / structural_total_g_c;
    const transfer_g_c = @max(0, inputs.exchange_fraction_per_h * concentration_difference_g_c * inputs.biological_timestep_h);
    const next_reserve_g_c = inputs.branch_reserve_carbon_g_c + transfer_g_c;
    const next_storage_g_c = inputs.seasonal_storage_carbon_g_c - transfer_g_c;
    if (!std.math.isFinite(next_reserve_g_c) or !std.math.isFinite(next_storage_g_c) or next_storage_g_c < 0)
        return error.LowBranchReserveTransferWouldOverdrawStorage;
    return .{
        .storage_to_branch_reserve_carbon_g_c = transfer_g_c,
        .next_branch_reserve_carbon_g_c = next_reserve_g_c,
        .next_seasonal_storage_carbon_g_c = next_storage_g_c,
    };
}

/// GROSUB 7365-7399 root-mobile C replenishment of depleted perennial
/// seasonal storage. This preserves the source's operation order and one-way
/// `AMIN1(0, ...)` gate; the reported transfer is positive root-to-storage.
pub fn replenishDepletedSeasonalStorage(inputs: DepletedStorageInputs) !DepletedStorageResult {
    inline for (@typeInfo(DepletedStorageInputs).@"struct".fields) |field| {
        if (field.type == f64) {
            const value = @field(inputs, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidDepletedStorageInput;
        }
    }
    if (inputs.biological_timestep_h <= 0) return error.InvalidDepletedStorageInput;

    const unchanged: DepletedStorageResult = .{
        .root_to_storage_carbon_g_c = 0,
        .next_layer_mobile_carbon_g_c = inputs.layer_mobile_carbon_g_c,
        .next_seasonal_storage_carbon_g_c = inputs.seasonal_storage_carbon_g_c,
    };
    if (inputs.growth_habit == .annual or
        !inputs.layer_is_rooted or
        inputs.layer_active_root_carbon_g_c <= inputs.presence_threshold_g_c or
        inputs.plant_total_root_carbon_g_c <= inputs.presence_threshold_g_c or
        inputs.seasonal_storage_carbon_g_c >= inputs.storage_deficit_threshold_g_c_per_g_root_c * inputs.plant_total_root_carbon_g_c)
        return unchanged;

    const layer_root_fraction = inputs.layer_active_root_carbon_g_c / inputs.plant_total_root_carbon_g_c;
    const layer_storage_structural_carbon_g_c = inputs.plant_total_root_carbon_g_c * layer_root_fraction;
    const structural_total_g_c = inputs.layer_active_root_carbon_g_c + layer_storage_structural_carbon_g_c;
    const layer_storage_carbon_g_c = inputs.seasonal_storage_carbon_g_c * layer_root_fraction;
    const concentration_difference_g_c = (layer_storage_carbon_g_c * inputs.layer_active_root_carbon_g_c -
        inputs.layer_mobile_carbon_g_c * layer_storage_structural_carbon_g_c) / structural_total_g_c;
    const signed_root_gain_g_c = @min(0, inputs.exchange_fraction_per_h * concentration_difference_g_c * inputs.biological_timestep_h);
    const next_root_g_c = inputs.layer_mobile_carbon_g_c + signed_root_gain_g_c;
    const next_storage_g_c = inputs.seasonal_storage_carbon_g_c - signed_root_gain_g_c;
    if (!std.math.isFinite(next_root_g_c) or !std.math.isFinite(next_storage_g_c) or next_root_g_c < 0)
        return error.DepletedStorageTransferWouldOverdrawRoot;
    return .{
        .root_to_storage_carbon_g_c = -signed_root_gain_g_c,
        .next_layer_mobile_carbon_g_c = next_root_g_c,
        .next_seasonal_storage_carbon_g_c = next_storage_g_c,
    };
}

/// Exact GROSUB XFRC/XFRN/XFRP C:N:P-constrained transfer for one root layer.
/// Original routine: GROSUB, lines 8174-8199.
pub fn sourceOrderRootStorageTransferIsEnabled(
    remobilization_enabled: bool,
    growth_habit: GrowthHabit,
) bool {
    return remobilization_enabled and growth_habit == .perennial;
}

pub fn rootToSeasonalStorage(
    parameters: Parameters,
    mobile_carbon_g_c: f64,
    mobile_nitrogen_g_n: f64,
    mobile_phosphorus_g_p: f64,
    exchange_fraction_per_h: f64,
    timestep_h: f64,
) !ElementTransfer {
    try parameters.validate();
    inline for (.{ mobile_carbon_g_c, mobile_nitrogen_g_n, mobile_phosphorus_g_p, exchange_fraction_per_h, timestep_h }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootSeasonalStorageInput;
    const unconstrained_c = exchange_fraction_per_h * @max(0, mobile_carbon_g_c) * timestep_h;
    const unconstrained_n = exchange_fraction_per_h * @max(0, mobile_nitrogen_g_n) * timestep_h;
    const unconstrained_p = exchange_fraction_per_h * @max(0, mobile_phosphorus_g_p) * timestep_h;
    const carbon = @min(unconstrained_c, @min(unconstrained_n / parameters.minimum_mobile_nitrogen_per_carbon_g_n_per_g_c, unconstrained_p / parameters.minimum_mobile_phosphorus_per_carbon_g_p_per_g_c));
    const nitrogen = @min(unconstrained_n, @min(carbon * parameters.maximum_mobile_nitrogen_per_carbon_g_n_per_g_c, unconstrained_p * parameters.maximum_mobile_nitrogen_per_carbon_g_n_per_g_c / parameters.minimum_mobile_phosphorus_per_carbon_g_p_per_g_c));
    const phosphorus = @min(unconstrained_p, @min(carbon * parameters.maximum_mobile_phosphorus_per_carbon_g_p_per_g_c, unconstrained_n * parameters.maximum_mobile_phosphorus_per_carbon_g_p_per_g_c / parameters.minimum_mobile_nitrogen_per_carbon_g_n_per_g_c));
    const result: ElementTransfer = .{ .carbon_g_c = carbon, .nitrogen_g_n = nitrogen, .phosphorus_g_p = phosphorus };
    inline for (@typeInfo(ElementTransfer).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteRootSeasonalStorageTransfer;
    return result;
}

/// Publishes all runtime root layers and the perennial storage pool as one
/// validated transaction.
pub fn state_updateRootToSeasonalStorage(canopy: *CanopyState, roots: *RootState, plant: usize, root_layer_indices: []const usize, transfers: []const ElementTransfer) !void {
    if (plant >= canopy.plant_seed_storage_carbon_g.len or root_layer_indices.len == 0 or root_layer_indices.len != transfers.len) return error.RootSeasonalStorageDimensionMismatch;
    var total: ElementTransfer = .{};
    for (root_layer_indices, transfers) |root, transfer| {
        if (root >= roots.mobile_carbon_g.len) return error.RootSeasonalStorageDimensionMismatch;
        inline for (@typeInfo(ElementTransfer).@"struct".fields) |field| {
            const value = @field(transfer, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidRootSeasonalStorageTransfer;
            @field(total, field.name) += value;
        }
        inline for (.{
            roots.mobile_carbon_g[root] - transfer.carbon_g_c,
            roots.mobile_nitrogen_g[root] - transfer.nitrogen_g_n,
            roots.mobile_phosphorus_g[root] - transfer.phosphorus_g_p,
        }) |value| if (!std.math.isFinite(value) or value < 0) return error.RootSeasonalStorageWouldOverdraw;
    }
    inline for (.{
        canopy.plant_seed_storage_carbon_g[plant] + total.carbon_g_c,
        canopy.plant_seed_storage_nitrogen_g[plant] + total.nitrogen_g_n,
        canopy.plant_seed_storage_phosphorus_g[plant] + total.phosphorus_g_p,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootSeasonalStorageStateUpdate;
    for (root_layer_indices, transfers) |root, transfer| {
        roots.mobile_carbon_g[root] -= transfer.carbon_g_c;
        roots.mobile_nitrogen_g[root] -= transfer.nitrogen_g_n;
        roots.mobile_phosphorus_g[root] -= transfer.phosphorus_g_p;
    }
    canopy.plant_seed_storage_carbon_g[plant] += total.carbon_g_c;
    canopy.plant_seed_storage_nitrogen_g[plant] += total.nitrogen_g_n;
    canopy.plant_seed_storage_phosphorus_g[plant] += total.phosphorus_g_p;
}

/// GROSUB CH2OH, UPNH4B/R and UPPO4B/R germination/leafout equations.
pub fn calculate(parameters: Parameters, inputs: Inputs) !Transfers {
    try parameters.validate();
    if (inputs.growth_habit > 1 or inputs.aboveground_turnover_type >= 6) return error.InvalidStorageRemobilizationCode;
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == bool or field.type == u8) continue;
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0) return error.InvalidStorageRemobilizationInput;
    }
    if (inputs.biological_timestep_h == 0) return error.InvalidStorageRemobilizationInput;
    const enabled = inputs.accumulated_remobilization_h <= parameters.remobilization_duration_h[inputs.growth_habit] or
        (inputs.growth_habit == 0 and inputs.continue_annual_remobilization_after_duration);
    const oxidized = if (enabled and inputs.storage_carbon_g_c > inputs.presence_threshold_g_c)
        parameters.storage_carbon_oxidation_fraction_per_h[inputs.growth_habit] *
            inputs.remobilization_time_increment_h * inputs.storage_carbon_g_c
    else
        0;
    if (oxidized > inputs.storage_carbon_g_c) return error.StorageCarbonRemobilizationWouldOverdraw;
    const oxidized_storage_carbon_g_c = oxidized;
    const remaining_storage_c = inputs.storage_carbon_g_c - oxidized_storage_carbon_g_c;
    const shoot_c = oxidized_storage_carbon_g_c * parameters.shoot_carbon_partition_fraction[inputs.growth_habit];
    const root_c = oxidized_storage_carbon_g_c * parameters.root_carbon_partition_fraction[inputs.growth_habit];

    var shoot_n: f64 = 0;
    var root_n: f64 = 0;
    var shoot_p: f64 = 0;
    var root_p: f64 = 0;
    if (inputs.growth_habit != 0 and remaining_storage_c > inputs.presence_threshold_g_c) {
        // GROSUB 4726--4728 and 4730--4737 publish CH2OH carbon before
        // 4767--4780 evaluate the storage/shoot N/P gradient. The root
        // gradient at 4799--4815 likewise sums CPOOLR after the carbon
        // allocation. Using the pre-carbon inputs here changes both gradients.
        const shoot_mobile_after_carbon_g_c = inputs.shoot_mobile_carbon_g_c + shoot_c;
        const root_mobile_after_carbon_g_c = inputs.root_mobile_carbon_g_c + root_c;
        const shoot_total_c = @max(0, remaining_storage_c + shoot_mobile_after_carbon_g_c);
        if (shoot_total_c > 0) {
            const n_gradient = (inputs.storage_nitrogen_g_n * shoot_mobile_after_carbon_g_c - inputs.shoot_mobile_nitrogen_g_n * remaining_storage_c) / shoot_total_c;
            const p_gradient = (inputs.storage_phosphorus_g_p * shoot_mobile_after_carbon_g_c - inputs.shoot_mobile_phosphorus_g_p * remaining_storage_c) / shoot_total_c;
            shoot_n = @max(0, parameters.perennial_nutrient_equilibration_fraction_per_h[inputs.aboveground_turnover_type] * n_gradient) * inputs.biological_timestep_h;
            shoot_p = @max(0, parameters.perennial_nutrient_equilibration_fraction_per_h[inputs.aboveground_turnover_type] * p_gradient) * inputs.biological_timestep_h;
        }
        const root_total_c = @max(0, remaining_storage_c + root_mobile_after_carbon_g_c);
        if (root_total_c > 0) {
            const n_gradient = (inputs.storage_nitrogen_g_n * root_mobile_after_carbon_g_c - inputs.root_mobile_nitrogen_g_n * remaining_storage_c) / root_total_c;
            const p_gradient = (inputs.storage_phosphorus_g_p * root_mobile_after_carbon_g_c - inputs.root_mobile_phosphorus_g_p * remaining_storage_c) / root_total_c;
            root_n = @max(0, parameters.perennial_nutrient_equilibration_fraction_per_h[inputs.aboveground_turnover_type] * n_gradient) * inputs.biological_timestep_h;
            root_p = @max(0, parameters.perennial_nutrient_equilibration_fraction_per_h[inputs.aboveground_turnover_type] * p_gradient) * inputs.biological_timestep_h;
        }
    } else if (remaining_storage_c > inputs.presence_threshold_g_c) {
        shoot_n = @max(0, parameters.shoot_carbon_partition_fraction[inputs.growth_habit] * oxidized_storage_carbon_g_c * inputs.storage_nitrogen_g_n / remaining_storage_c);
        shoot_p = @max(0, parameters.shoot_carbon_partition_fraction[inputs.growth_habit] * oxidized_storage_carbon_g_c * inputs.storage_phosphorus_g_p / remaining_storage_c);
        root_n = @max(0, parameters.root_carbon_partition_fraction[inputs.growth_habit] * oxidized_storage_carbon_g_c * inputs.storage_nitrogen_g_n / remaining_storage_c);
        root_p = @max(0, parameters.root_carbon_partition_fraction[inputs.growth_habit] * oxidized_storage_carbon_g_c * inputs.storage_phosphorus_g_p / remaining_storage_c);
    } else {
        shoot_n = parameters.shoot_carbon_partition_fraction[inputs.growth_habit] * inputs.storage_nitrogen_g_n;
        shoot_p = parameters.shoot_carbon_partition_fraction[inputs.growth_habit] * inputs.storage_phosphorus_g_p;
        root_n = parameters.root_carbon_partition_fraction[inputs.growth_habit] * inputs.storage_nitrogen_g_n;
        root_p = parameters.root_carbon_partition_fraction[inputs.growth_habit] * inputs.storage_phosphorus_g_p;
    }
    const nitrogen_total = shoot_n + root_n;
    const phosphorus_total = shoot_p + root_p;
    if (nitrogen_total > inputs.storage_nitrogen_g_n or phosphorus_total > inputs.storage_phosphorus_g_p) return error.StorageRemobilizationWouldOverdrawNutrients;
    const result: Transfers = .{ .oxidized_storage_carbon_g_c = oxidized_storage_carbon_g_c, .shoot_carbon_g_c = shoot_c, .root_carbon_g_c = root_c, .shoot_nitrogen_g_n = shoot_n, .root_nitrogen_g_n = root_n, .shoot_phosphorus_g_p = shoot_p, .root_phosphorus_g_p = root_p };
    inline for (@typeInfo(Transfers).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteStorageRemobilizationResult;
    return result;
}

/// Atomic extensive-pool state_update. Root layer fractions are supplied from
/// the source WTRTD and CPOOLR rules and require no allocation.
pub fn state_update(
    canopy: *CanopyState,
    roots: *RootState,
    plant: usize,
    branch: usize,
    root_layer_indices: []const usize,
    structural_carbon_fractions: []const f64,
    mobile_carbon_fractions: []const f64,
    transfers: Transfers,
) !void {
    if (plant >= canopy.plant_seed_storage_carbon_g.len or branch >= canopy.branch_mobile_carbon_g.len) return error.PlantStorageIndexOutOfBounds;
    if (root_layer_indices.len == 0 or root_layer_indices.len != structural_carbon_fractions.len or root_layer_indices.len != mobile_carbon_fractions.len) return error.PlantStorageDimensionMismatch;
    var structural_sum: f64 = 0;
    var mobile_sum: f64 = 0;
    for (root_layer_indices, structural_carbon_fractions, mobile_carbon_fractions) |root, structural, mobile| {
        if (root >= roots.mobile_carbon_g.len or !std.math.isFinite(structural) or !std.math.isFinite(mobile) or structural < 0 or mobile < 0) return error.InvalidPlantStorageLayerFraction;
        structural_sum += structural;
        mobile_sum += mobile;
    }
    if (@abs(structural_sum - 1) > 1.0e-10 or @abs(mobile_sum - 1) > 1.0e-10) return error.InvalidPlantStorageLayerFraction;
    const next_storage_c = canopy.plant_seed_storage_carbon_g[plant] - transfers.oxidized_storage_carbon_g_c;
    const next_storage_n = canopy.plant_seed_storage_nitrogen_g[plant] - transfers.shoot_nitrogen_g_n - transfers.root_nitrogen_g_n;
    const next_storage_p = canopy.plant_seed_storage_phosphorus_g[plant] - transfers.shoot_phosphorus_g_p - transfers.root_phosphorus_g_p;
    inline for (.{ next_storage_c, next_storage_n, next_storage_p }) |value| if (!std.math.isFinite(value) or value < 0) return error.PlantStorageStateUpdateWouldOverdraw;
    for (root_layer_indices, structural_carbon_fractions, mobile_carbon_fractions) |root, structural, mobile| {
        inline for (.{
            roots.mobile_carbon_g[root] + transfers.root_carbon_g_c * structural,
            roots.mobile_nitrogen_g[root] + transfers.root_nitrogen_g_n * mobile,
            roots.mobile_phosphorus_g[root] + transfers.root_phosphorus_g_p * mobile,
        }) |value| if (!std.math.isFinite(value)) return error.NonFinitePlantStorageStateUpdate;
    }
    canopy.plant_seed_storage_carbon_g[plant] = next_storage_c;
    canopy.plant_seed_storage_nitrogen_g[plant] = next_storage_n;
    canopy.plant_seed_storage_phosphorus_g[plant] = next_storage_p;
    canopy.branch_mobile_carbon_g[branch] += transfers.shoot_carbon_g_c;
    canopy.branch_mobile_nitrogen_g[branch] += transfers.shoot_nitrogen_g_n;
    canopy.branch_mobile_phosphorus_g[branch] += transfers.shoot_phosphorus_g_p;
    for (root_layer_indices, structural_carbon_fractions, mobile_carbon_fractions) |root, structural, mobile| {
        roots.mobile_carbon_g[root] += transfers.root_carbon_g_c * structural;
        roots.mobile_nitrogen_g[root] += transfers.root_nitrogen_g_n * mobile;
        roots.mobile_phosphorus_g[root] += transfers.root_phosphorus_g_p * mobile;
    }
}

test "storage remobilization workspace supports runtime plant and layer counts" {
    const plant_count: usize = 8;
    const layer_count: usize = 7;
    var roots = try RootState.init(std.testing.allocator, plant_count, layer_count, 2);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, plant_count, layer_count);
    defer workspace.deinit();

    const plant: usize = 6;
    roots.planting_layer_by_plant[plant] = 4;
    var slices = try workspace.refreshPlant(&roots, plant);
    for (0..layer_count) |layer| {
        const expected: f64 = if (layer == 4) 1 else 0;
        try std.testing.expectEqual(expected, slices.structural_carbon_fractions[layer]);
        try std.testing.expectEqual(expected, slices.mobile_carbon_fractions[layer]);
    }

    const structural_layer = try roots.layerAxisIndex(plant, 0, 2, 1);
    roots.axis_primary_carbon_g[structural_layer] = 3;
    const mobile_root = try roots.layerIndex(plant, 0, 5);
    roots.mobile_carbon_g[mobile_root] = 2;
    slices = try workspace.refreshPlant(&roots, plant);
    try std.testing.expectEqual(@as(f64, 1), slices.structural_carbon_fractions[2]);
    try std.testing.expectEqual(@as(f64, 1), slices.mobile_carbon_fractions[5]);
    var structural_before: [layer_count]f64 = undefined;
    var mobile_before: [layer_count]f64 = undefined;
    @memcpy(&structural_before, slices.structural_carbon_fractions);
    @memcpy(&mobile_before, slices.mobile_carbon_fractions);
    roots.mobile_carbon_g[try roots.layerIndex(plant, 0, layer_count - 1)] = -1.0e-13;
    try std.testing.expectError(error.InvalidStorageRemobilizationRootState, workspace.refreshPlant(&roots, plant));
    try std.testing.expectEqualSlices(f64, &structural_before, slices.structural_carbon_fractions);
    try std.testing.expectEqualSlices(f64, &mobile_before, slices.mobile_carbon_fractions);
}

test "perennial root storage state_update is conservative and rollback safe across runtime layers" {
    var canopy = try CanopyState.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var roots = try RootState.init(std.testing.allocator, 1, 3, 1);
    defer roots.deinit();
    const indices = [_]usize{
        try roots.layerIndex(0, 0, 0),
        try roots.layerIndex(0, 0, 1),
        try roots.layerIndex(0, 0, 2),
    };
    for (indices) |root| {
        roots.mobile_carbon_g[root] = 2;
        roots.mobile_nitrogen_g[root] = 0.2;
        roots.mobile_phosphorus_g[root] = 0.02;
    }
    const transfers = [_]ElementTransfer{
        .{ .carbon_g_c = 0.2, .nitrogen_g_n = 0.02, .phosphorus_g_p = 0.002 },
        .{ .carbon_g_c = 0.3, .nitrogen_g_n = 0.03, .phosphorus_g_p = 0.003 },
        .{ .carbon_g_c = 0.4, .nitrogen_g_n = 0.04, .phosphorus_g_p = 0.004 },
    };
    try state_updateRootToSeasonalStorage(&canopy, &roots, 0, &indices, &transfers);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), canopy.plant_seed_storage_carbon_g[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.1), roots.mobile_carbon_g[indices[0]] + roots.mobile_carbon_g[indices[1]] + roots.mobile_carbon_g[indices[2]], 1.0e-12);

    const storage_before = canopy.plant_seed_storage_carbon_g[0];
    const root_before = roots.mobile_carbon_g[indices[0]];
    var invalid = transfers;
    invalid[1].carbon_g_c = 20;
    try std.testing.expectError(error.RootSeasonalStorageWouldOverdraw, state_updateRootToSeasonalStorage(&canopy, &roots, 0, &indices, &invalid));
    try std.testing.expectEqual(storage_before, canopy.plant_seed_storage_carbon_g[0]);
    try std.testing.expectEqual(root_before, roots.mobile_carbon_g[indices[0]]);
    invalid = transfers;
    invalid[1].carbon_g_c = roots.mobile_carbon_g[indices[1]] + 1.0e-13;
    try std.testing.expectError(error.RootSeasonalStorageWouldOverdraw, state_updateRootToSeasonalStorage(&canopy, &roots, 0, &indices, &invalid));
    try std.testing.expectEqual(storage_before, canopy.plant_seed_storage_carbon_g[0]);
    try std.testing.expectEqual(root_before, roots.mobile_carbon_g[indices[0]]);
}

test "storage remobilization state_update distributes runtime root layers atomically" {
    var canopy = try CanopyState.init(std.testing.allocator, 1, 1, &.{1}, &.{1}, &.{1});
    defer canopy.deinit();
    var roots = try RootState.init(std.testing.allocator, 1, 2, 1);
    defer roots.deinit();
    canopy.plant_seed_storage_carbon_g[0] = 10;
    canopy.plant_seed_storage_nitrogen_g[0] = 1;
    canopy.plant_seed_storage_phosphorus_g[0] = 0.1;
    const transfers: Transfers = .{
        .oxidized_storage_carbon_g_c = 2,
        .shoot_carbon_g_c = 0.5,
        .root_carbon_g_c = 1.5,
        .shoot_nitrogen_g_n = 0.1,
        .root_nitrogen_g_n = 0.3,
        .shoot_phosphorus_g_p = 0.01,
        .root_phosphorus_g_p = 0.03,
    };
    const root_indices = [_]usize{ try roots.layerIndex(0, 0, 0), try roots.layerIndex(0, 0, 1) };
    try state_update(&canopy, &roots, 0, 0, &root_indices, &.{ 0.25, 0.75 }, &.{ 0.4, 0.6 }, transfers);
    try std.testing.expectApproxEqAbs(@as(f64, 8), canopy.plant_seed_storage_carbon_g[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), roots.mobile_carbon_g[root_indices[0]] + roots.mobile_carbon_g[root_indices[1]], 1.0e-12);
    const root_before = roots.mobile_carbon_g[root_indices[0]];
    var invalid = transfers;
    invalid.oxidized_storage_carbon_g_c = 20;
    try std.testing.expectError(error.PlantStorageStateUpdateWouldOverdraw, state_update(&canopy, &roots, 0, 0, &root_indices, &.{ 0.25, 0.75 }, &.{ 0.4, 0.6 }, invalid));
    try std.testing.expectEqual(root_before, roots.mobile_carbon_g[root_indices[0]]);
    invalid = transfers;
    invalid.oxidized_storage_carbon_g_c = canopy.plant_seed_storage_carbon_g[0] + 1.0e-13;
    try std.testing.expectError(error.PlantStorageStateUpdateWouldOverdraw, state_update(&canopy, &roots, 0, 0, &root_indices, &.{ 0.25, 0.75 }, &.{ 0.4, 0.6 }, invalid));
    try std.testing.expectEqual(@as(f64, 8), canopy.plant_seed_storage_carbon_g[0]);
    try std.testing.expectEqual(root_before, roots.mobile_carbon_g[root_indices[0]]);
}

test "GROSUB perennial storage harvest conserves distinct C N P retention" {
    const kinetics = LitterPartition.ElementFractions{
        .carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen = .{ 0.4, 0.3, 0.2, 0.1 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    const initial = StorageElementMass{
        .carbon_g_c = 10,
        .nitrogen_g_n = 4,
        .phosphorus_g_p = 2,
    };
    const result = try sourceOrderPerennialStorageHarvest(
        true,
        initial,
        .{ .carbon = 0.5, .nitrogen = 0.25, .phosphorus = 0.8 },
        .{
            .carbon_woody_nonwoody = .{ 0.7, 0.3 },
            .nitrogen_woody_nonwoody = .{ 0.4, 0.6 },
            .phosphorus_woody_nonwoody = .{ 0.2, 0.8 },
        },
        kinetics,
    );
    var litter = StorageElementMass{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    for (0..LitterPartition.kinetic_component_count) |component| {
        litter.carbon_g_c += result.litterfall.woody_carbon_g_c[component] + result.litterfall.nonwoody_carbon_g_c[component];
        litter.nitrogen_g_n += result.litterfall.woody_nitrogen_g_n[component] + result.litterfall.nonwoody_nitrogen_g_n[component];
        litter.phosphorus_g_p += result.litterfall.woody_phosphorus_g_p[component] + result.litterfall.nonwoody_phosphorus_g_p[component];
    }
    try std.testing.expectApproxEqAbs(initial.carbon_g_c, result.remaining.carbon_g_c + litter.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(initial.nitrogen_g_n, result.remaining.nitrogen_g_n + litter.nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(initial.phosphorus_g_p, result.remaining.phosphorus_g_p + litter.phosphorus_g_p, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), sumFour(result.litterfall.woody_carbon_g_c), 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.8), sumFour(result.litterfall.nonwoody_nitrogen_g_n), 1e-14);
}

test "GROSUB tillage unconditionally scales seasonal storage and litter" {
    const initial: StorageElementMass = .{
        .carbon_g_c = 14,
        .nitrogen_g_n = 7,
        .phosphorus_g_p = 3.5,
    };
    const kinetics: LitterPartition.ElementFractions = .{
        .carbon = .{ 0.1, 0.2, 0.3, 0.4 },
        .nitrogen = .{ 0.4, 0.3, 0.2, 0.1 },
        .phosphorus = .{ 0.25, 0.25, 0.25, 0.25 },
    };
    const result = try sourceOrderStorageTillage(
        initial,
        0.25,
        .{
            .carbon_woody_nonwoody = .{ 0.6, 0.4 },
            .nitrogen_woody_nonwoody = .{ 0.5, 0.5 },
            .phosphorus_woody_nonwoody = .{ 0.2, 0.8 },
        },
        kinetics,
    );
    try std.testing.expectEqual(@as(f64, 3.5), result.remaining.carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1.75), result.remaining.nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 0.875), result.remaining.phosphorus_g_p);
    try std.testing.expectApproxEqAbs(10.5, sumFour(result.litterfall.woody_carbon_g_c) + sumFour(result.litterfall.nonwoody_carbon_g_c), 1e-14);
    try std.testing.expectApproxEqAbs(5.25, sumFour(result.litterfall.woody_nitrogen_g_n) + sumFour(result.litterfall.nonwoody_nitrogen_g_n), 1e-14);
    try std.testing.expectApproxEqAbs(2.625, sumFour(result.litterfall.woody_phosphorus_g_p) + sumFour(result.litterfall.nonwoody_phosphorus_g_p), 1e-14);
}

test "GROSUB annual storage bypasses harvest litter transaction" {
    const storage = StorageElementMass{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03 };
    const kinetics = LitterPartition.ElementFractions{
        .carbon = .{ 0, 1, 0, 0 },
        .nitrogen = .{ 0, 1, 0, 0 },
        .phosphorus = .{ 0, 1, 0, 0 },
    };
    const result = try sourceOrderPerennialStorageHarvest(
        false,
        storage,
        .{ .carbon = 0, .nitrogen = 0, .phosphorus = 0 },
        .{
            .carbon_woody_nonwoody = .{ 0, 1 },
            .nitrogen_woody_nonwoody = .{ 0, 1 },
            .phosphorus_woody_nonwoody = .{ 0, 1 },
        },
        kinetics,
    );
    try std.testing.expectEqual(storage, result.remaining);
    try std.testing.expectEqual(@as(f64, 0), sumFour(result.litterfall.nonwoody_carbon_g_c));
}

fn sumFour(values: [4]f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total;
}

test {
    _ = @import("storage_remobilization_test.zig");
}

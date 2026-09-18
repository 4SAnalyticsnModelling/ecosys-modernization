const std = @import("std");

pub const Pool = struct { carbon_g_c: f64, nitrogen_g_n: f64, phosphorus_g_p: f64 };

/// GROSUB `CNDLB = WTNDB / ARLFB`. A leafless branch has no canopy
/// decomposition-density contribution.
pub fn canopyDecompositionDensity(structural_carbon_g_c: f64, leaf_area_m2: f64, minimum_leaf_area_m2: f64) !f64 {
    inline for (.{ structural_carbon_g_c, leaf_area_m2, minimum_leaf_area_m2 }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidCanopySymbioticDensity;
    return if (leaf_area_m2 > minimum_leaf_area_m2) structural_carbon_g_c / leaf_area_m2 else 0;
}

fn initializeInfection(
    fixation_type: u8,
    minimum_fixation_type: u8,
    maximum_fixation_type: u8,
    first_subhour: bool,
    fire_active_this_hour: bool,
    current_structural: Pool,
    initial_bacterial_carbon_g_c_per_m2: f64,
    cell_area_m2: f64,
    target_nitrogen_per_carbon_g_n_per_g_c: f64,
    target_phosphorus_per_carbon_g_p_per_g_c: f64,
) !Pool {
    try validatePool(current_structural);
    inline for (.{ initial_bacterial_carbon_g_c_per_m2, cell_area_m2, target_nitrogen_per_carbon_g_n_per_g_c, target_phosphorus_per_carbon_g_p_per_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSymbioticInfectionInput;
    if (cell_area_m2 <= 0) return error.InvalidSymbioticInfectionInput;
    // GROSUB 5292--5299 and 7571--7578: NFZ==1, an empty structural-C
    // pool, and ICHKF==0 are the complete infection gate. ICHKF is the WTHR
    // fire flag, not checkpoint state. A resumed empty pool therefore behaves
    // exactly like the same uninterrupted no-fire hour.
    if (fixation_type < minimum_fixation_type or fixation_type > maximum_fixation_type or !first_subhour or fire_active_this_hour or current_structural.carbon_g_c > 0) return current_structural;
    const carbon_g_c = initial_bacterial_carbon_g_c_per_m2 * cell_area_m2;
    const result: Pool = .{
        // Source uses += for all three WTNDB/WTNDBN/WTNDBP carriers. C is
        // necessarily zero at admission (pools are nonnegative), while any
        // independently retained N/P must not be overwritten.
        .carbon_g_c = current_structural.carbon_g_c + carbon_g_c,
        .nitrogen_g_n = current_structural.nitrogen_g_n + carbon_g_c * target_nitrogen_per_carbon_g_n_per_g_c,
        .phosphorus_g_p = current_structural.phosphorus_g_p + carbon_g_c * target_phosphorus_per_carbon_g_p_per_g_c,
    };
    try validatePool(result);
    return result;
}

pub fn initializeCanopyInfection(
    fixation_type: u8,
    first_subhour: bool,
    fire_active_this_hour: bool,
    current_structural: Pool,
    initial_bacterial_carbon_g_c_per_m2: f64,
    cell_area_m2: f64,
    target_nitrogen_per_carbon_g_n_per_g_c: f64,
    target_phosphorus_per_carbon_g_p_per_g_c: f64,
) !Pool {
    return initializeInfection(fixation_type, 4, 6, first_subhour, fire_active_this_hour, current_structural, initial_bacterial_carbon_g_c_per_m2, cell_area_m2, target_nitrogen_per_carbon_g_n_per_g_c, target_phosphorus_per_carbon_g_p_per_g_c);
}

/// GROSUB root-rhizobia infection for fixation types one through three.
/// Initialization is first-subhour and suppressed by the current WTHR fire
/// flag. Checkpoint origin is deliberately irrelevant to the biological gate.
pub fn initializeRootInfection(
    fixation_type: u8,
    first_subhour: bool,
    fire_active_this_hour: bool,
    current_structural: Pool,
    initial_bacterial_carbon_g_c_per_m2: f64,
    cell_area_m2: f64,
    target_nitrogen_per_carbon_g_n_per_g_c: f64,
    target_phosphorus_per_carbon_g_p_per_g_c: f64,
) !Pool {
    return initializeInfection(fixation_type, 1, 3, first_subhour, fire_active_this_hour, current_structural, initial_bacterial_carbon_g_c_per_m2, cell_area_m2, target_nitrogen_per_carbon_g_n_per_g_c, target_phosphorus_per_carbon_g_p_per_g_c);
}

/// Exact external C/N/P introduced by WTNDI infection. This is separated
/// from later metabolism and host exchange so conservation books only the
/// source addition, never an internal transfer or subsequent loss.
pub fn infectionExternalInput(before: Pool, after: Pool) !Pool {
    try validatePool(before);
    try validatePool(after);
    const result: Pool = .{
        .carbon_g_c = after.carbon_g_c - before.carbon_g_c,
        .nitrogen_g_n = after.nitrogen_g_n - before.nitrogen_g_n,
        .phosphorus_g_p = after.phosphorus_g_p - before.phosphorus_g_p,
    };
    try validateExternalInput(result);
    return result;
}

/// Transactionally adds one infection input to its cell-hour accumulator.
pub fn accumulateExternalInput(total: *Pool, input: Pool) !void {
    try validateExternalInput(total.*);
    try validateExternalInput(input);
    const next: Pool = .{
        .carbon_g_c = total.carbon_g_c + input.carbon_g_c,
        .nitrogen_g_n = total.nitrogen_g_n + input.nitrogen_g_n,
        .phosphorus_g_p = total.phosphorus_g_p + input.phosphorus_g_p,
    };
    try validateExternalInput(next);
    total.* = next;
}

fn validateExternalInput(input: Pool) !void {
    inline for (@typeInfo(Pool).@"struct".fields) |field| {
        const value = @field(input, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSymbioticExternalInput;
    }
}

pub const HostExchange = struct {
    next_host: Pool,
    next_symbiont: Pool,
    host_to_symbiont: Pool,
};

/// Exact GROSUB FXRN concentration-gradient exchange after canopy nodule
/// metabolism. Signed transfers permit either partner to be the donor.
pub fn equilibrateHostAndSymbiont(
    host: Pool,
    symbiont: Pool,
    host_tissue_carbon_g_c: f64,
    symbiont_structural_carbon_g_c: f64,
    minimum_infection_carbon_g_c: f64,
    exchange_fraction_per_h: f64,
    timestep_h: f64,
    host_carbon_presence_threshold_g_c: f64,
    host_tissue_presence_threshold_g_c: f64,
    combined_carbon_presence_threshold_g_c: f64,
) !HostExchange {
    try validatePool(host);
    try validatePool(symbiont);
    inline for (.{ host_tissue_carbon_g_c, symbiont_structural_carbon_g_c, minimum_infection_carbon_g_c, exchange_fraction_per_h, timestep_h, host_carbon_presence_threshold_g_c, host_tissue_presence_threshold_g_c, combined_carbon_presence_threshold_g_c }) |value|
        if (!std.math.isFinite(value) or value < 0) return error.InvalidSymbioticExchangeInput;
    if (timestep_h <= 0 or exchange_fraction_per_h > 1) return error.InvalidSymbioticExchangeInput;
    if (host.carbon_g_c <= host_carbon_presence_threshold_g_c or host_tissue_carbon_g_c <= host_tissue_presence_threshold_g_c) return .{ .next_host = host, .next_symbiont = symbiont, .host_to_symbiont = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 } };

    const effective_symbiont_carbon_g_c = @min(host_tissue_carbon_g_c, @max(minimum_infection_carbon_g_c, symbiont_structural_carbon_g_c));
    const tissue_total_g_c = host_tissue_carbon_g_c + effective_symbiont_carbon_g_c;
    var transfer: Pool = .{
        .carbon_g_c = exchange_fraction_per_h * (host.carbon_g_c * effective_symbiont_carbon_g_c - symbiont.carbon_g_c * host_tissue_carbon_g_c) / tissue_total_g_c * timestep_h,
        .nitrogen_g_n = 0,
        .phosphorus_g_p = 0,
    };
    const next_host_carbon_g_c = host.carbon_g_c - transfer.carbon_g_c;
    const next_symbiont_carbon_g_c = symbiont.carbon_g_c + transfer.carbon_g_c;
    const mobile_total_g_c = next_host_carbon_g_c + next_symbiont_carbon_g_c;
    if (mobile_total_g_c > combined_carbon_presence_threshold_g_c) {
        transfer.nitrogen_g_n = exchange_fraction_per_h * (host.nitrogen_g_n * next_symbiont_carbon_g_c - symbiont.nitrogen_g_n * next_host_carbon_g_c) / mobile_total_g_c * timestep_h;
        transfer.phosphorus_g_p = exchange_fraction_per_h * (host.phosphorus_g_p * next_symbiont_carbon_g_c - symbiont.phosphorus_g_p * next_host_carbon_g_c) / mobile_total_g_c * timestep_h;
    }
    const next_host: Pool = .{ .carbon_g_c = next_host_carbon_g_c, .nitrogen_g_n = host.nitrogen_g_n - transfer.nitrogen_g_n, .phosphorus_g_p = host.phosphorus_g_p - transfer.phosphorus_g_p };
    const next_symbiont: Pool = .{ .carbon_g_c = next_symbiont_carbon_g_c, .nitrogen_g_n = symbiont.nitrogen_g_n + transfer.nitrogen_g_n, .phosphorus_g_p = symbiont.phosphorus_g_p + transfer.phosphorus_g_p };
    try validatePool(next_host);
    try validatePool(next_symbiont);
    return .{ .next_host = next_host, .next_symbiont = next_symbiont, .host_to_symbiont = transfer };
}

pub const Inputs = struct {
    structural: Pool,
    nonstructural: Pool,
    /// Source `CNDLB`/`CNDLR`: symbiont structural C divided by the
    /// process-specific host extent. Canopy callers use leaf area (g C m-2);
    /// root callers use host structural carbon (g C g C-1).
    decomposition_density: f64,
    temperature_response: f64,
    growth_water_response: f64,
    oxygen_constraint_fraction: f64 = 1,
    maintenance_temperature_response: f64,
    maintenance_water_response: f64,
    timestep_h: f64,
    structural_presence_threshold_g_c: f64 = 0,
    ratio_division_threshold: f64 = 0,
    fixation_respiration_presence_threshold_g_c: f64 = 0,
};

pub const Parameters = struct {
    target_nitrogen_per_carbon_g_n_per_g_c: f64,
    target_phosphorus_per_carbon_g_p_per_g_c: f64,
    nitrogen_inhibition_g_n_per_g_c: f64,
    phosphorus_inhibition_g_p_per_g_c: f64,
    specific_respiration_per_h: f64,
    specific_maintenance_g_c_per_g_n_h: f64,
    nitrogen_fixation_yield_g_n_per_g_c: f64,
    growth_yield_g_c_per_g_c: f64,
    nonstructural_nitrogen_half_saturation_g_n_per_g_c: f64,
    nonstructural_phosphorus_half_saturation_g_p_per_g_c: f64,
    excess_nitrogen_inhibition_g_n_per_g_c: f64,
    excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p: f64,
    decomposition_rate_per_h: f64,
    bacteria_to_host_decomposition_ratio: f64,
    minimum_carbon_recycling_fraction: f64,
    carbon_recycling_range_fraction: f64,
    maximum_nitrogen_recycling_fraction: f64,
    maximum_phosphorus_recycling_fraction: f64,
};

pub const RuntimeParameters = struct {
    initial_bacterial_carbon_g_c_per_m2: f64,
    specific_respiration_per_h: f64,
    specific_maintenance_g_c_per_g_n_h: f64,
    nitrogen_fixation_yield_g_n_per_g_c: f64,
    nitrogen_inhibition_g_n_per_g_c: f64,
    phosphorus_inhibition_g_p_per_g_c: f64,
    nonstructural_nitrogen_half_saturation_g_n_per_g_c: f64,
    nonstructural_phosphorus_half_saturation_g_p_per_g_c: f64,
    excess_nitrogen_inhibition_g_n_per_g_c: f64,
    excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p: f64,
    decomposition_rate_per_h: f64,
    minimum_carbon_recycling_fraction: f64,
    carbon_recycling_range_fraction: f64,
    maximum_nitrogen_recycling_fraction: f64,
    maximum_phosphorus_recycling_fraction: f64,
    host_exchange_fraction_per_h_by_fixation_type: [6]f64,
    decomposition_control_ratio_by_fixation_type: [6]f64,

    pub fn validate(self: RuntimeParameters) !void {
        inline for (@typeInfo(RuntimeParameters).@"struct".fields) |field| if (field.type == f64) {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSymbioticRuntimeParameter;
        };
        inline for (.{ self.host_exchange_fraction_per_h_by_fixation_type, self.decomposition_control_ratio_by_fixation_type }) |values|
            for (values) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSymbioticRuntimeParameter;
        if (self.nitrogen_fixation_yield_g_n_per_g_c <= 0 or self.nitrogen_inhibition_g_n_per_g_c <= 0 or self.phosphorus_inhibition_g_p_per_g_c <= 0 or self.nonstructural_nitrogen_half_saturation_g_n_per_g_c <= 0 or self.nonstructural_phosphorus_half_saturation_g_p_per_g_c <= 0 or self.excess_nitrogen_inhibition_g_n_per_g_c <= 0 or self.excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p <= 0 or self.minimum_carbon_recycling_fraction + self.carbon_recycling_range_fraction > 1 or self.maximum_nitrogen_recycling_fraction > 1 or self.maximum_phosphorus_recycling_fraction > 1) return error.InvalidSymbioticRuntimeParameter;
        for (self.host_exchange_fraction_per_h_by_fixation_type) |value| if (value > 1) return error.InvalidSymbioticRuntimeParameter;
        for (self.decomposition_control_ratio_by_fixation_type) |value| if (value <= 0) return error.InvalidSymbioticRuntimeParameter;
    }
};

pub fn sourceRuntimeParameters() RuntimeParameters {
    return .{
        .initial_bacterial_carbon_g_c_per_m2 = 1.0e-4,
        .specific_respiration_per_h = 0.125,
        .specific_maintenance_g_c_per_g_n_h = 0.010,
        .nitrogen_fixation_yield_g_n_per_g_c = 0.25,
        .nitrogen_inhibition_g_n_per_g_c = 0.1,
        .phosphorus_inhibition_g_p_per_g_c = 0.01,
        .nonstructural_nitrogen_half_saturation_g_n_per_g_c = 1.0e-4,
        .nonstructural_phosphorus_half_saturation_g_p_per_g_c = 1.0e-5,
        .excess_nitrogen_inhibition_g_n_per_g_c = 10,
        .excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p = 1000,
        .decomposition_rate_per_h = 1.0e-2,
        .minimum_carbon_recycling_fraction = 0.167,
        .carbon_recycling_range_fraction = 0.333,
        .maximum_nitrogen_recycling_fraction = 0.333,
        .maximum_phosphorus_recycling_fraction = 0.333,
        .host_exchange_fraction_per_h_by_fixation_type = .{ 0.20, 0.10, 0.05, 0.20, 0.10, 0.05 },
        .decomposition_control_ratio_by_fixation_type = .{ 0.50, 0.25, 0.125, 0.050, 0.025, 0.0125 },
    };
}

pub fn metabolicParameters(runtime: RuntimeParameters, fixation_type: u8, target_nitrogen_per_carbon_g_n_per_g_c: f64, target_phosphorus_per_carbon_g_p_per_g_c: f64, growth_yield_g_c_per_g_c: f64) !Parameters {
    try runtime.validate();
    if (fixation_type == 0 or fixation_type > 6) return error.InvalidSymbioticFixationType;
    return .{
        .target_nitrogen_per_carbon_g_n_per_g_c = target_nitrogen_per_carbon_g_n_per_g_c,
        .target_phosphorus_per_carbon_g_p_per_g_c = target_phosphorus_per_carbon_g_p_per_g_c,
        .nitrogen_inhibition_g_n_per_g_c = runtime.nitrogen_inhibition_g_n_per_g_c,
        .phosphorus_inhibition_g_p_per_g_c = runtime.phosphorus_inhibition_g_p_per_g_c,
        .specific_respiration_per_h = runtime.specific_respiration_per_h,
        .specific_maintenance_g_c_per_g_n_h = runtime.specific_maintenance_g_c_per_g_n_h,
        .nitrogen_fixation_yield_g_n_per_g_c = runtime.nitrogen_fixation_yield_g_n_per_g_c,
        .growth_yield_g_c_per_g_c = growth_yield_g_c_per_g_c,
        .nonstructural_nitrogen_half_saturation_g_n_per_g_c = runtime.nonstructural_nitrogen_half_saturation_g_n_per_g_c,
        .nonstructural_phosphorus_half_saturation_g_p_per_g_c = runtime.nonstructural_phosphorus_half_saturation_g_p_per_g_c,
        .excess_nitrogen_inhibition_g_n_per_g_c = runtime.excess_nitrogen_inhibition_g_n_per_g_c,
        .excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p = runtime.excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p,
        .decomposition_rate_per_h = runtime.decomposition_rate_per_h,
        .bacteria_to_host_decomposition_ratio = runtime.decomposition_control_ratio_by_fixation_type[fixation_type - 1],
        .minimum_carbon_recycling_fraction = runtime.minimum_carbon_recycling_fraction,
        .carbon_recycling_range_fraction = runtime.carbon_recycling_range_fraction,
        .maximum_nitrogen_recycling_fraction = runtime.maximum_nitrogen_recycling_fraction,
        .maximum_phosphorus_recycling_fraction = runtime.maximum_phosphorus_recycling_fraction,
    };
}

pub const Result = struct {
    next_structural: Pool,
    next_nonstructural: Pool,
    fixed_nitrogen_g_n: f64,
    fixation_respiration_g_c: f64,
    total_respiration_g_c: f64,
    total_respiration_oxygen_unlimited_g_c: f64,
    bacterial_growth_g_c: f64,
    decomposition_loss: Pool,
    senescence_loss: Pool,
    litterfall: Pool,
    recycled: Pool,
};

/// Shared constrained nodule pathway used by canopy cyanobacteria and root
/// rhizobia. Root O2-unlimited diagnostics are evaluated by a second call with
/// the unconstrained respiration input, leaving one scientific implementation.
pub fn calculate(inputs: Inputs, parameters: Parameters) !Result {
    try validate(inputs, parameters);
    const carbon_concentration = if (inputs.structural.carbon_g_c > inputs.structural_presence_threshold_g_c) inputs.nonstructural.carbon_g_c / inputs.structural.carbon_g_c else 1;
    const nitrogen_concentration = if (inputs.structural.carbon_g_c > inputs.structural_presence_threshold_g_c) inputs.nonstructural.nitrogen_g_n / inputs.structural.carbon_g_c else 1;
    const phosphorus_concentration = if (inputs.structural.carbon_g_c > inputs.structural_presence_threshold_g_c) inputs.nonstructural.phosphorus_g_p / inputs.structural.carbon_g_c else 1;
    const nitrogen_per_nonstructural_carbon = if (carbon_concentration > inputs.ratio_division_threshold) nitrogen_concentration / carbon_concentration else 0;
    const nitrogen_per_nonstructural_phosphorus = if (phosphorus_concentration > inputs.ratio_division_threshold) nitrogen_concentration / phosphorus_concentration else 0;
    var carbon_balance: f64 = 1;
    var nitrogen_balance: f64 = 0;
    var phosphorus_balance: f64 = 0;
    if (carbon_concentration > inputs.ratio_division_threshold) {
        carbon_balance = std.math.clamp(@min(nitrogen_concentration / (nitrogen_concentration + carbon_concentration * parameters.nitrogen_inhibition_g_n_per_g_c), phosphorus_concentration / (phosphorus_concentration + carbon_concentration * parameters.phosphorus_inhibition_g_p_per_g_c)), 0, 1);
        nitrogen_balance = std.math.clamp(carbon_concentration / (carbon_concentration + nitrogen_concentration / parameters.nitrogen_inhibition_g_n_per_g_c), 0, 1);
        phosphorus_balance = std.math.clamp(carbon_concentration / (carbon_concentration + phosphorus_concentration / parameters.phosphorus_inhibition_g_p_per_g_c), 0, 1);
    }
    const recycling_carbon = parameters.minimum_carbon_recycling_fraction + carbon_balance * parameters.carbon_recycling_range_fraction;
    const recycling_nitrogen = nitrogen_balance * parameters.maximum_nitrogen_recycling_fraction;
    const recycling_phosphorus = phosphorus_balance * parameters.maximum_phosphorus_recycling_fraction;
    if (recycling_carbon > 1 or recycling_nitrogen > 1 or recycling_phosphorus > 1) return error.InvalidSymbioticRecyclingFraction;
    const nutrient_activity = if (inputs.structural.carbon_g_c > inputs.structural_presence_threshold_g_c) @min(1, @sqrt(inputs.structural.nitrogen_g_n / (inputs.structural.carbon_g_c * parameters.target_nitrogen_per_carbon_g_n_per_g_c)), @sqrt(inputs.structural.phosphorus_g_p / (inputs.structural.carbon_g_c * parameters.target_phosphorus_per_carbon_g_p_per_g_c))) else 1;
    const product_inhibition = 1 + @max(nitrogen_per_nonstructural_carbon / parameters.excess_nitrogen_inhibition_g_n_per_g_c, nitrogen_per_nonstructural_phosphorus / parameters.excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p);
    const respiration_oxygen_unlimited = @max(0, @min(inputs.nonstructural.carbon_g_c, parameters.specific_respiration_per_h * inputs.structural.carbon_g_c) * nutrient_activity * inputs.temperature_response * inputs.growth_water_response * inputs.timestep_h) / product_inhibition;
    const respiration = respiration_oxygen_unlimited * inputs.oxygen_constraint_fraction;
    const maintenance = @max(0, parameters.specific_maintenance_g_c_per_g_n_h * inputs.maintenance_temperature_response * inputs.structural.nitrogen_g_n * inputs.maintenance_water_response * inputs.timestep_h);
    const growth_respiration = @max(0, respiration - maintenance);
    const growth_respiration_oxygen_unlimited = @max(0, respiration_oxygen_unlimited - maintenance);
    const senescence_respiration = @max(0, maintenance - respiration);
    const fixation_requirement = @max(0, inputs.structural.carbon_g_c * parameters.target_nitrogen_per_carbon_g_n_per_g_c - inputs.structural.nitrogen_g_n) / parameters.nitrogen_fixation_yield_g_n_per_g_c;
    const fixation_respiration = if (growth_respiration > inputs.fixation_respiration_presence_threshold_g_c and fixation_requirement > 0) growth_respiration * fixation_requirement / (growth_respiration + fixation_requirement) else 0;
    const fixed_nitrogen = fixation_respiration * parameters.nitrogen_fixation_yield_g_n_per_g_c;
    const decomposition_fraction = @min(1, parameters.decomposition_rate_per_h * inputs.decomposition_density / parameters.bacteria_to_host_decomposition_ratio) * @sqrt(inputs.temperature_response * inputs.growth_water_response) * inputs.timestep_h;
    if (decomposition_fraction > 1) return error.SymbioticDecompositionExceedsPool;
    const decomposition = scale(inputs.structural, decomposition_fraction);
    const decomposition_recycled = recycle(decomposition, recycling_carbon, recycling_nitrogen, recycling_phosphorus);
    const decomposition_litter = subtract(decomposition, decomposition_recycled);
    const available_growth_carbon = inputs.nonstructural.carbon_g_c - @min(maintenance, respiration) - fixation_respiration + decomposition_recycled.carbon_g_c;
    const yield_limited_carbon = (growth_respiration - fixation_respiration) / (1 - parameters.growth_yield_g_c_per_g_c);
    const total_growth_carbon = @min(available_growth_carbon, yield_limited_carbon);
    if (total_growth_carbon < 0) return error.NegativeSymbioticGrowthCarbon;
    const growth = total_growth_carbon * parameters.growth_yield_g_c_per_g_c;
    const growth_respiration_actual = fixation_respiration + total_growth_carbon * (1 - parameters.growth_yield_g_c_per_g_c);
    const nitrogen_added = @max(0, @min(inputs.nonstructural.nitrogen_g_n, growth * parameters.target_nitrogen_per_carbon_g_n_per_g_c)) * nitrogen_concentration / (nitrogen_concentration + parameters.nonstructural_nitrogen_half_saturation_g_n_per_g_c);
    const phosphorus_added = @max(0, @min(inputs.nonstructural.phosphorus_g_p, growth * parameters.target_phosphorus_per_carbon_g_p_per_g_c)) * phosphorus_concentration / (phosphorus_concentration + parameters.nonstructural_phosphorus_half_saturation_g_p_per_g_c);
    const structural_carbon_after_decomposition_g_c = inputs.structural.carbon_g_c - decomposition.carbon_g_c;
    if (senescence_respiration > structural_carbon_after_decomposition_g_c) return error.SymbioticSenescenceWouldOverdraw;
    const senescence = if (senescence_respiration > 0 and inputs.structural.carbon_g_c > inputs.structural_presence_threshold_g_c) Pool{ .carbon_g_c = senescence_respiration, .nitrogen_g_n = 0, .phosphorus_g_p = 0 } else Pool{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    var senescence_loss = senescence;
    if (senescence.carbon_g_c > 0) {
        senescence_loss.nitrogen_g_n = senescence.carbon_g_c * inputs.structural.nitrogen_g_n / inputs.structural.carbon_g_c;
        senescence_loss.phosphorus_g_p = senescence.carbon_g_c * inputs.structural.phosphorus_g_p / inputs.structural.carbon_g_c;
    }
    const senescence_recycled = recycle(senescence_loss, recycling_carbon, recycling_nitrogen, recycling_phosphorus);
    const senescence_litter = subtract(senescence_loss, senescence_recycled);
    const recycled = add(decomposition_recycled, senescence_recycled);
    const litterfall = add(decomposition_litter, senescence_litter);
    const next_structural: Pool = .{ .carbon_g_c = inputs.structural.carbon_g_c + growth - decomposition.carbon_g_c - senescence_loss.carbon_g_c, .nitrogen_g_n = inputs.structural.nitrogen_g_n + nitrogen_added - decomposition.nitrogen_g_n - senescence_loss.nitrogen_g_n, .phosphorus_g_p = inputs.structural.phosphorus_g_p + phosphorus_added - decomposition.phosphorus_g_p - senescence_loss.phosphorus_g_p };
    const next_nonstructural: Pool = .{ .carbon_g_c = inputs.nonstructural.carbon_g_c - @min(maintenance, respiration) - fixation_respiration - total_growth_carbon + decomposition_recycled.carbon_g_c, .nitrogen_g_n = inputs.nonstructural.nitrogen_g_n - nitrogen_added + decomposition_recycled.nitrogen_g_n + senescence_recycled.nitrogen_g_n + fixed_nitrogen, .phosphorus_g_p = inputs.nonstructural.phosphorus_g_p - phosphorus_added + decomposition_recycled.phosphorus_g_p + senescence_recycled.phosphorus_g_p };
    try validatePool(next_structural);
    try validatePool(next_nonstructural);
    return .{ .next_structural = next_structural, .next_nonstructural = next_nonstructural, .fixed_nitrogen_g_n = fixed_nitrogen, .fixation_respiration_g_c = fixation_respiration, .total_respiration_g_c = @min(maintenance, respiration) + growth_respiration_actual + senescence_recycled.carbon_g_c, .total_respiration_oxygen_unlimited_g_c = @min(maintenance, respiration_oxygen_unlimited) + growth_respiration_oxygen_unlimited + senescence_recycled.carbon_g_c, .bacterial_growth_g_c = growth, .decomposition_loss = decomposition, .senescence_loss = senescence_loss, .litterfall = litterfall, .recycled = recycled };
}

fn recycle(pool: Pool, carbon_fraction: f64, nitrogen_fraction: f64, phosphorus_fraction: f64) Pool {
    return .{ .carbon_g_c = pool.carbon_g_c * carbon_fraction, .nitrogen_g_n = pool.nitrogen_g_n * (nitrogen_fraction + (1 - nitrogen_fraction) * carbon_fraction), .phosphorus_g_p = pool.phosphorus_g_p * (phosphorus_fraction + (1 - phosphorus_fraction) * carbon_fraction) };
}

fn add(a: Pool, b: Pool) Pool {
    return .{ .carbon_g_c = a.carbon_g_c + b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n + b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p + b.phosphorus_g_p };
}

fn subtract(a: Pool, b: Pool) Pool {
    return .{ .carbon_g_c = a.carbon_g_c - b.carbon_g_c, .nitrogen_g_n = a.nitrogen_g_n - b.nitrogen_g_n, .phosphorus_g_p = a.phosphorus_g_p - b.phosphorus_g_p };
}

fn scale(pool: Pool, fraction: f64) Pool {
    return .{ .carbon_g_c = pool.carbon_g_c * fraction, .nitrogen_g_n = pool.nitrogen_g_n * fraction, .phosphorus_g_p = pool.phosphorus_g_p * fraction };
}

fn validatePool(pool: Pool) !void {
    inline for (@typeInfo(Pool).@"struct".fields) |field| if (!std.math.isFinite(@field(pool, field.name)) or @field(pool, field.name) < 0) return error.InvalidSymbioticPool;
}

fn validate(inputs: Inputs, parameters: Parameters) !void {
    try validatePool(inputs.structural);
    try validatePool(inputs.nonstructural);
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidSymbioticFixationInput;
    inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name)) or @field(parameters, field.name) < 0) return error.InvalidSymbioticFixationParameter;
    if (inputs.timestep_h <= 0 or inputs.oxygen_constraint_fraction > 1 or parameters.target_nitrogen_per_carbon_g_n_per_g_c <= 0 or parameters.target_phosphorus_per_carbon_g_p_per_g_c <= 0 or parameters.nitrogen_inhibition_g_n_per_g_c <= 0 or parameters.phosphorus_inhibition_g_p_per_g_c <= 0 or parameters.nitrogen_fixation_yield_g_n_per_g_c <= 0 or parameters.growth_yield_g_c_per_g_c < 0 or parameters.growth_yield_g_c_per_g_c >= 1 or parameters.nonstructural_nitrogen_half_saturation_g_n_per_g_c <= 0 or parameters.nonstructural_phosphorus_half_saturation_g_p_per_g_c <= 0 or parameters.excess_nitrogen_inhibition_g_n_per_g_c <= 0 or parameters.excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p <= 0 or parameters.bacteria_to_host_decomposition_ratio <= 0) return error.InvalidSymbioticFixationParameter;
}

test "symbiotic fixation conserves C and adds only fixed atmospheric N" {
    const inputs: Inputs = .{ .structural = .{ .carbon_g_c = 10, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 }, .nonstructural = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.1 }, .decomposition_density = 0.1, .temperature_response = 1, .growth_water_response = 1, .maintenance_temperature_response = 1, .maintenance_water_response = 1, .timestep_h = 1 };
    const result = try calculate(inputs, .{ .target_nitrogen_per_carbon_g_n_per_g_c = 0.1, .target_phosphorus_per_carbon_g_p_per_g_c = 0.02, .nitrogen_inhibition_g_n_per_g_c = 0.1, .phosphorus_inhibition_g_p_per_g_c = 0.01, .specific_respiration_per_h = 0.2, .specific_maintenance_g_c_per_g_n_h = 0.01, .nitrogen_fixation_yield_g_n_per_g_c = 0.05, .growth_yield_g_c_per_g_c = 0.4, .nonstructural_nitrogen_half_saturation_g_n_per_g_c = 0.01, .nonstructural_phosphorus_half_saturation_g_p_per_g_c = 0.005, .excess_nitrogen_inhibition_g_n_per_g_c = 1, .excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p = 10, .decomposition_rate_per_h = 0.01, .bacteria_to_host_decomposition_ratio = 0.1, .minimum_carbon_recycling_fraction = 0.1, .carbon_recycling_range_fraction = 0.5, .maximum_nitrogen_recycling_fraction = 0.8, .maximum_phosphorus_recycling_fraction = 0.8 });
    const before_c = inputs.structural.carbon_g_c + inputs.nonstructural.carbon_g_c;
    const after_c = result.next_structural.carbon_g_c + result.next_nonstructural.carbon_g_c + result.litterfall.carbon_g_c + result.total_respiration_g_c;
    try std.testing.expectApproxEqAbs(before_c, after_c, 1e-12);
    const before_n = inputs.structural.nitrogen_g_n + inputs.nonstructural.nitrogen_g_n;
    const after_n = result.next_structural.nitrogen_g_n + result.next_nonstructural.nitrogen_g_n + result.litterfall.nitrogen_g_n;
    try std.testing.expectApproxEqAbs(before_n + result.fixed_nitrogen_g_n, after_n, 1e-12);
}

test "symbiotic pools reject sub-legacy-tolerance negative inventory" {
    const inputs: Inputs = .{
        .structural = .{ .carbon_g_c = 1, .nitrogen_g_n = -5.0e-15, .phosphorus_g_p = 0.01 },
        .nonstructural = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .decomposition_density = 0,
        .temperature_response = 1,
        .growth_water_response = 1,
        .maintenance_temperature_response = 1,
        .maintenance_water_response = 1,
        .timestep_h = 1,
    };
    const parameters: Parameters = .{
        .target_nitrogen_per_carbon_g_n_per_g_c = 0.1,
        .target_phosphorus_per_carbon_g_p_per_g_c = 0.01,
        .nitrogen_inhibition_g_n_per_g_c = 0.1,
        .phosphorus_inhibition_g_p_per_g_c = 0.01,
        .specific_respiration_per_h = 0,
        .specific_maintenance_g_c_per_g_n_h = 0,
        .nitrogen_fixation_yield_g_n_per_g_c = 0.1,
        .growth_yield_g_c_per_g_c = 0.5,
        .nonstructural_nitrogen_half_saturation_g_n_per_g_c = 0.01,
        .nonstructural_phosphorus_half_saturation_g_p_per_g_c = 0.01,
        .excess_nitrogen_inhibition_g_n_per_g_c = 1,
        .excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p = 1,
        .decomposition_rate_per_h = 0,
        .bacteria_to_host_decomposition_ratio = 1,
        .minimum_carbon_recycling_fraction = 0,
        .carbon_recycling_range_fraction = 0,
        .maximum_nitrogen_recycling_fraction = 0,
        .maximum_phosphorus_recycling_fraction = 0,
    };
    try std.testing.expectError(error.InvalidSymbioticPool, calculate(inputs, parameters));
}

test "GROSUB canopy symbiont senescence fails instead of silently capping an overdraw" {
    const inputs: Inputs = .{
        .structural = .{ .carbon_g_c = 1, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 },
        .nonstructural = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        .decomposition_density = 0.1,
        .temperature_response = 1,
        .growth_water_response = 1,
        .maintenance_temperature_response = 1,
        .maintenance_water_response = 1,
        .timestep_h = 1,
    };
    const parameters: Parameters = .{
        .target_nitrogen_per_carbon_g_n_per_g_c = 0.1,
        .target_phosphorus_per_carbon_g_p_per_g_c = 0.02,
        .nitrogen_inhibition_g_n_per_g_c = 0.1,
        .phosphorus_inhibition_g_p_per_g_c = 0.01,
        .specific_respiration_per_h = 0,
        .specific_maintenance_g_c_per_g_n_h = 2,
        .nitrogen_fixation_yield_g_n_per_g_c = 0.05,
        .growth_yield_g_c_per_g_c = 0.4,
        .nonstructural_nitrogen_half_saturation_g_n_per_g_c = 0.01,
        .nonstructural_phosphorus_half_saturation_g_p_per_g_c = 0.005,
        .excess_nitrogen_inhibition_g_n_per_g_c = 1,
        .excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p = 10,
        .decomposition_rate_per_h = 0,
        .bacteria_to_host_decomposition_ratio = 0.1,
        .minimum_carbon_recycling_fraction = 0.1,
        .carbon_recycling_range_fraction = 0.5,
        .maximum_nitrogen_recycling_fraction = 0.8,
        .maximum_phosphorus_recycling_fraction = 0.8,
    };
    try std.testing.expectError(error.SymbioticSenescenceWouldOverdraw, calculate(inputs, parameters));
}

test "GROSUB canopy decomposition density uses branch leaf area" {
    try std.testing.expectApproxEqAbs(@as(f64, 4), try canopyDecompositionDensity(2, 0.5, 1.0e-12), 1.0e-15);
    try std.testing.expectEqual(@as(f64, 0), try canopyDecompositionDensity(2, 0, 1.0e-12));
    try std.testing.expectError(error.InvalidCanopySymbioticDensity, canopyDecompositionDensity(2, -0.5, 1.0e-12));
}

test "GROSUB WFR constrains nodule respiration without constraining decomposition" {
    const parameters = try metabolicParameters(sourceRuntimeParameters(), 1, 0.1, 0.02, 0.4);
    const unlimited_inputs: Inputs = .{
        .structural = .{ .carbon_g_c = 10, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 },
        .nonstructural = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.1 },
        .decomposition_density = 0.1,
        .temperature_response = 1,
        .growth_water_response = 0.64,
        .maintenance_temperature_response = 1,
        .maintenance_water_response = 1,
        .timestep_h = 1,
    };
    var limited_inputs = unlimited_inputs;
    limited_inputs.oxygen_constraint_fraction = 0.1;
    const unlimited = try calculate(unlimited_inputs, parameters);
    const limited = try calculate(limited_inputs, parameters);
    try std.testing.expectApproxEqAbs(unlimited.decomposition_loss.carbon_g_c, limited.decomposition_loss.carbon_g_c, 1e-15);
    try std.testing.expect(limited.total_respiration_g_c < limited.total_respiration_oxygen_unlimited_g_c);
    try std.testing.expectApproxEqAbs(unlimited.total_respiration_oxygen_unlimited_g_c, limited.total_respiration_oxygen_unlimited_g_c, 1e-15);
}

// GROSUB-001-WFNSR: with growth respiration held at zero, symbiont
// maintenance is drawn entirely through senescence recycling, so
// total_respiration_g_c = maintenance_water_response * specific_maintenance_g_c_per_g_n_h
// * structural.nitrogen_g_n * recycling_carbon exactly. This isolates
// maintenance_water_response (the WFNSR-equivalent input) from
// growth_water_response and proves the former, not a stomatal-resistance
// term, scales symbiont maintenance respiration.
test "GROSUB canopy symbiont maintenance respiration scales linearly with maintenance water response" {
    const parameters: Parameters = .{
        .target_nitrogen_per_carbon_g_n_per_g_c = 0.1,
        .target_phosphorus_per_carbon_g_p_per_g_c = 0.02,
        .nitrogen_inhibition_g_n_per_g_c = 0.1,
        .phosphorus_inhibition_g_p_per_g_c = 0.01,
        .specific_respiration_per_h = 0,
        .specific_maintenance_g_c_per_g_n_h = 0.01,
        .nitrogen_fixation_yield_g_n_per_g_c = 0.05,
        .growth_yield_g_c_per_g_c = 0.4,
        .nonstructural_nitrogen_half_saturation_g_n_per_g_c = 0.01,
        .nonstructural_phosphorus_half_saturation_g_p_per_g_c = 0.005,
        .excess_nitrogen_inhibition_g_n_per_g_c = 1,
        .excess_nitrogen_to_phosphorus_inhibition_g_n_per_g_p = 10,
        .decomposition_rate_per_h = 0,
        .bacteria_to_host_decomposition_ratio = 0.1,
        .minimum_carbon_recycling_fraction = 0.1,
        .carbon_recycling_range_fraction = 0.5,
        .maximum_nitrogen_recycling_fraction = 0.8,
        .maximum_phosphorus_recycling_fraction = 0.8,
    };
    const wet_inputs: Inputs = .{
        .structural = .{ .carbon_g_c = 10, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 },
        .nonstructural = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.1 },
        .decomposition_density = 0.1,
        .temperature_response = 1,
        .growth_water_response = 1,
        .maintenance_temperature_response = 1,
        .maintenance_water_response = 1,
        .timestep_h = 1,
    };
    var dry_inputs = wet_inputs;
    dry_inputs.maintenance_water_response = 0.25;
    const wet = try calculate(wet_inputs, parameters);
    const dry = try calculate(dry_inputs, parameters);
    try std.testing.expectEqual(@as(f64, 0), wet.fixation_respiration_g_c);
    try std.testing.expectEqual(@as(f64, 0), dry.fixation_respiration_g_c);
    try std.testing.expect(wet.total_respiration_g_c > 0);
    try std.testing.expect(dry.total_respiration_g_c < wet.total_respiration_g_c);
    try std.testing.expectApproxEqAbs(wet.total_respiration_g_c * 0.25, dry.total_respiration_g_c, 1e-12);
}

test "GROSUB canopy infection uses first-subhour empty-pool no-fire gate" {
    const empty: Pool = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    const infected = try initializeCanopyInfection(4, true, false, empty, 0.02, 100, 0.1, 0.02);
    try std.testing.expectEqual(Pool{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.04 }, infected);
    try std.testing.expectEqual(empty, try initializeCanopyInfection(3, true, false, empty, 0.02, 100, 0.1, 0.02));
    try std.testing.expectEqual(empty, try initializeCanopyInfection(4, true, true, empty, 0.02, 100, 0.1, 0.02));
    try std.testing.expectEqual(infected, try initializeCanopyInfection(4, true, false, infected, 0.02, 100, 0.1, 0.02));
}

test "GROSUB no-fire empty-pool restart is identical and WTNDI C N P is exact" {
    const empty_with_retained_nutrients: Pool = .{ .carbon_g_c = 0, .nitrogen_g_n = 0.003, .phosphorus_g_p = 0.004 };
    const uninterrupted = try initializeCanopyInfection(5, true, false, empty_with_retained_nutrients, 0.02, 100, 0.1, 0.02);
    const resumed = try initializeCanopyInfection(5, true, false, empty_with_retained_nutrients, 0.02, 100, 0.1, 0.02);
    try std.testing.expectEqual(uninterrupted, resumed);
    try std.testing.expectEqual(Pool{ .carbon_g_c = 2, .nitrogen_g_n = 0.203, .phosphorus_g_p = 0.044 }, resumed);
    const input = try infectionExternalInput(empty_with_retained_nutrients, resumed);
    try std.testing.expectApproxEqAbs(@as(f64, 2), input.carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), input.nitrogen_g_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), input.phosphorus_g_p, 1e-15);

    var cell_hour: Pool = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    try accumulateExternalInput(&cell_hour, input);
    try std.testing.expectApproxEqAbs(@as(f64, 3), cell_hour.carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), cell_hour.nitrogen_g_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), cell_hour.phosphorus_g_p, 1e-15);
}

test "GROSUB root infection accepts only rhizobial fixation types" {
    const empty: Pool = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 };
    const infected = try initializeRootInfection(2, true, false, empty, 0.02, 100, 0.1, 0.02);
    try std.testing.expectEqual(Pool{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.04 }, infected);
    try std.testing.expectEqual(empty, try initializeRootInfection(4, true, false, empty, 0.02, 100, 0.1, 0.02));
    try std.testing.expectEqual(empty, try initializeRootInfection(2, false, false, empty, 0.02, 100, 0.1, 0.02));
}

test "production binds WTHR fire to root and canopy before one-shot inoculum publication" {
    const root_source = @embedFile("../../stages/root_processes_metabolism.zig");
    const vegetation_source = @embedFile("../../stages/hourly_vegetation.zig");
    const production_source = @embedFile("../../ecosys_ng.zig");
    try std.testing.expect(std.mem.indexOf(
        u8,
        root_source,
        ".fire_active_this_hour = context.fire_active_this_hour[cell]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        root_source,
        ".restoring_checkpoint = context.restoring_checkpoint",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        vegetation_source,
        ".fire_active_this_hour = context.fire_active_this_hour",
    ) != null);
    const root = std.mem.indexOf(u8, vegetation_source, "root_processes.applyRootMetabolism(context.*,") orelse return error.MissingRootSymbiosisBinding;
    const canopy = std.mem.indexOf(u8, vegetation_source, "ecosys.shoot_growth_runtime.applyTile") orelse return error.MissingCanopySymbiosisBinding;
    const publish = std.mem.indexOf(u8, vegetation_source, "accumulateAcceptedSymbioticInoculum") orelse return error.MissingSymbioticInoculumPublication;
    try std.testing.expect(root < canopy);
    try std.testing.expect(canopy < publish);

    const prepare_start = std.mem.indexOf(u8, production_source, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(u8, production_source, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const prepare_phase = production_source[prepare_start..advance_start];
    const fire_dispatch = std.mem.indexOf(u8, prepare_phase, "ecosys.disturbance_management_dispatch.dispatchDatePhase") orelse return error.MissingPreScienceFireDispatch;
    _ = std.mem.indexOfPos(u8, prepare_phase, fire_dispatch, ".pre_science,") orelse return error.MissingPreScienceFirePhase;
    const timeline_start = std.mem.indexOfPos(u8, production_source, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const advance_phase = production_source[advance_start..timeline_start];
    const transaction = std.mem.indexOf(u8, advance_phase, "driver_context.outer_hour_transaction_workspace.*.begin(") orelse return error.MissingOuterHourTransaction;
    const prepare = std.mem.indexOf(u8, advance_phase, "try prepareHourlyScience(driver_context,") orelse return error.MissingHourlyPreparationCall;
    const science = std.mem.indexOfPos(u8, advance_phase, prepare, "executeHourlyScience(\n        driver_context.hourly_science_context.*") orelse return error.MissingHourlyScienceCall;
    const post_science = std.mem.indexOfPos(u8, advance_phase, science, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceCall;
    try std.testing.expect(transaction < prepare);
    try std.testing.expect(prepare < science);
    try std.testing.expect(science < post_science);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, vegetation_source, "accumulateAcceptedSymbioticInoculum"),
    );
}

test "GROSUB host nodule exchange conserves mobile C N P" {
    const host: Pool = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 };
    const symbiont: Pool = .{ .carbon_g_c = 0.2, .nitrogen_g_n = 0.002, .phosphorus_g_p = 0.0002 };
    const result = try equilibrateHostAndSymbiont(host, symbiont, 20, 2, 0.5, 0.05, 1, 0, 0, 0);
    try std.testing.expect(result.host_to_symbiont.carbon_g_c > 0);
    try std.testing.expect(result.host_to_symbiont.nitrogen_g_n > 0);
    try std.testing.expect(result.host_to_symbiont.phosphorus_g_p > 0);
    try std.testing.expectApproxEqAbs(host.carbon_g_c + symbiont.carbon_g_c, result.next_host.carbon_g_c + result.next_symbiont.carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(host.nitrogen_g_n + symbiont.nitrogen_g_n, result.next_host.nitrogen_g_n + result.next_symbiont.nitrogen_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(host.phosphorus_g_p + symbiont.phosphorus_g_p, result.next_host.phosphorus_g_p + result.next_symbiont.phosphorus_g_p, 1e-14);
}

test "GROSUB symbiotic source constants are runtime validated by fixation type" {
    const runtime = sourceRuntimeParameters();
    try runtime.validate();
    try std.testing.expectEqual(@as(f64, 0.1), runtime.nitrogen_inhibition_g_n_per_g_c);
    try std.testing.expectEqual(@as(f64, 0.01), runtime.phosphorus_inhibition_g_p_per_g_c);
    const canopy_slow = try metabolicParameters(runtime, 6, 0.1, 0.02, 0.4);
    try std.testing.expectEqual(@as(f64, 0.0125), canopy_slow.bacteria_to_host_decomposition_ratio);
    try std.testing.expectEqual(@as(f64, 0.05), runtime.host_exchange_fraction_per_h_by_fixation_type[5]);
    try std.testing.expectEqual(@as(f64, 0.25), canopy_slow.nitrogen_fixation_yield_g_n_per_g_c);
    try std.testing.expectError(error.InvalidSymbioticFixationType, metabolicParameters(runtime, 0, 0.1, 0.02, 0.4));
}

test "GROSUB canopy fixation and exchange use distinct strict runtime thresholds" {
    var runtime = sourceRuntimeParameters();
    runtime.specific_maintenance_g_c_per_g_n_h = 0;
    const parameters = try metabolicParameters(runtime, 4, 0.1, 0.02, 0.4);
    const base: Inputs = .{
        .structural = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.001, .phosphorus_g_p = 0.01 },
        .nonstructural = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.02 },
        .decomposition_density = 0,
        .temperature_response = 1,
        .growth_water_response = 1,
        .maintenance_temperature_response = 1,
        .maintenance_water_response = 1,
        .timestep_h = 1,
    };
    const admitted = try calculate(base, parameters);
    var blocked_inputs = base;
    blocked_inputs.fixation_respiration_presence_threshold_g_c = 2;
    const blocked = try calculate(blocked_inputs, parameters);
    try std.testing.expect(admitted.fixed_nitrogen_g_n > 0);
    try std.testing.expectEqual(@as(f64, 0), blocked.fixed_nitrogen_g_n);

    const host: Pool = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 };
    const symbiont: Pool = .{ .carbon_g_c = 0.1, .nitrogen_g_n = 0.001, .phosphorus_g_p = 0.0001 };
    const blocked_exchange = try equilibrateHostAndSymbiont(host, symbiont, 0.5, 0.1, 0.01, 0.1, 1, 1, 0.01, 0.01);
    try std.testing.expectEqual(@as(f64, 0), blocked_exchange.host_to_symbiont.carbon_g_c);
    const admitted_exchange = try equilibrateHostAndSymbiont(host, symbiont, 0.5, 0.1, 0.01, 0.1, 1, 0.99, 0.01, 0.01);
    try std.testing.expect(admitted_exchange.host_to_symbiont.carbon_g_c > 0);
}

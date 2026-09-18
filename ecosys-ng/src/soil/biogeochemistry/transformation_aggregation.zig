const std = @import("std");
const transport_flux = @import("transport_flux_aggregation.zig");

pub const Inputs = struct {
    complex_count: usize,
    population_count: usize,
    /// True only for the source `L == 0` surface-litter layer.
    surface_litter_layer: bool = false,
    /// True only for the source `L == NU(NY,NX)` upper soil layer.
    surface_soil_layer: bool,
    surface_non_band_ammonium_fraction: f64,
    surface_band_ammonium_fraction: f64,
    surface_non_band_nitrate_fraction: f64,
    surface_band_nitrate_fraction: f64,
    surface_non_band_dihydrogen_phosphate_fraction: f64,
    surface_band_dihydrogen_phosphate_fraction: f64,
    surface_non_band_hydrogen_phosphate_fraction: f64,
    surface_band_hydrogen_phosphate_fraction: f64,
    non_band_ammonium_exchange_g_n: []const f64,
    band_ammonium_exchange_g_n: []const f64,
    non_band_nitrate_exchange_g_n: []const f64,
    band_nitrate_exchange_g_n: []const f64,
    non_band_dihydrogen_phosphate_exchange_g_p: []const f64,
    band_dihydrogen_phosphate_exchange_g_p: []const f64,
    non_band_hydrogen_phosphate_exchange_g_p: []const f64,
    band_hydrogen_phosphate_exchange_g_p: []const f64,
    surface_ammonium_exchange_g_n: []const f64,
    surface_nitrate_exchange_g_n: []const f64,
    surface_dihydrogen_phosphate_exchange_g_p: []const f64,
    surface_hydrogen_phosphate_exchange_g_p: []const f64,
    fixed_dinitrogen_g_n: []const f64,
    carbon_dioxide_emission_g_c: []const f64,
    methane_emission_g_c: []const f64,
    denitrification_respiration_g_c: []const f64,
    oxygen_uptake_g_o: []const f64,
    non_band_nitrate_reduction_g_n: []const f64,
    band_nitrate_reduction_g_n: []const f64,
    non_band_nitrite_reduction_g_n: []const f64,
    band_nitrite_reduction_g_n: []const f64,
    nitrous_oxide_reduction_g_n: []const f64,
    hydrogen_emission_g_h: []const f64,
    total_carbon_uptake_g_c: []const f64,
};

pub const State = struct {
    non_band_ammonium_exchange_g_n: f64 = 0,
    non_band_nitrate_exchange_g_n: f64 = 0,
    non_band_dihydrogen_phosphate_exchange_g_p: f64 = 0,
    non_band_hydrogen_phosphate_exchange_g_p: f64 = 0,
    band_ammonium_exchange_g_n: f64 = 0,
    band_nitrate_exchange_g_n: f64 = 0,
    band_dihydrogen_phosphate_exchange_g_p: f64 = 0,
    band_hydrogen_phosphate_exchange_g_p: f64 = 0,
    carbon_dioxide_emission_g_c: f64 = 0,
    methane_emission_g_c: f64 = 0,
    denitrification_respiration_g_c: f64 = 0,
    autotrophic_carbon_uptake_g_c: f64 = 0,
    oxygen_uptake_g_o: f64 = 0,
    non_band_nitrate_reduction_g_n: f64 = 0,
    band_nitrate_reduction_g_n: f64 = 0,
    non_band_nitrite_reduction_g_n: f64 = 0,
    band_nitrite_reduction_g_n: f64 = 0,
    nitrous_oxide_reduction_g_n: f64 = 0,
    fixed_dinitrogen_g_n: f64 = 0,
    hydrogen_emission_g_h: f64 = 0,
};

/// Supply-limited production inputs at the NITRO label-640/645 boundary.
/// Each slice is one layer in zero-based complex-major, population-minor order.
pub const SupplyLimitedInputs = struct {
    complex_count: usize,
    population_count: usize,
    oxygen_satisfaction_fraction: []const f64,
    redox_satisfaction_fraction: []const f64,
    non_band_ammonia_oxidation_potential_g_n: []const f64,
    band_ammonia_oxidation_potential_g_n: []const f64,
    non_band_nitrite_oxidation_potential_g_n: []const f64,
    band_nitrite_oxidation_potential_g_n: []const f64,
    non_band_nitrate_reduction_potential_g_n: []const f64,
    band_nitrate_reduction_potential_g_n: []const f64,
    non_band_heterotrophic_nitrite_reduction_potential_g_n: []const f64,
    band_heterotrophic_nitrite_reduction_potential_g_n: []const f64,
    non_band_autotrophic_nitrite_reduction_potential_g_n: []const f64,
    band_autotrophic_nitrite_reduction_potential_g_n: []const f64,
    non_band_autotrophic_ammonium_oxidation_potential_g_n: []const f64,
    band_autotrophic_ammonium_oxidation_potential_g_n: []const f64,
    nitrous_oxide_reduction_potential_g_n: []const f64,
    non_band_ammonium_exchange_g_n: []const f64,
    band_ammonium_exchange_g_n: []const f64,
    non_band_nitrate_exchange_g_n: []const f64,
    band_nitrate_exchange_g_n: []const f64,
    non_band_h2po4_exchange_g_p: []const f64,
    band_h2po4_exchange_g_p: []const f64,
    non_band_hpo4_exchange_g_p: []const f64,
    band_hpo4_exchange_g_p: []const f64,
    fixed_dinitrogen_g_n: []const f64,
};

pub const SupplyLimitedTotals = struct {
    ammonia_oxidation_g_n: [2]f64 = .{ 0, 0 },
    nitrite_oxidation_g_n: [2]f64 = .{ 0, 0 },
    nitrate_reduction_g_n: [2]f64 = .{ 0, 0 },
    heterotrophic_nitrite_reduction_g_n: [2]f64 = .{ 0, 0 },
    autotrophic_nitrite_reduction_g_n: [2]f64 = .{ 0, 0 },
    autotrophic_ammonium_oxidation_g_n: [2]f64 = .{ 0, 0 },
    nitrous_oxide_reduction_g_n: f64 = 0,
    ammonium_exchange_g_n: [2]f64 = .{ 0, 0 },
    nitrate_exchange_g_n: [2]f64 = .{ 0, 0 },
    h2po4_exchange_g_p: [2]f64 = .{ 0, 0 },
    hpo4_exchange_g_p: [2]f64 = .{ 0, 0 },
    fixed_dinitrogen_g_n: f64 = 0,
};

pub const GasStateUpdateInputs = struct {
    autotrophic_carbon_dioxide_uptake_g_c: f64,
    heterotrophic_carbon_dioxide_emission_g_c: f64,
    denitrification_carbon_dioxide_emission_g_c: f64,
    methane_oxidation_respiration_g_c: f64,
    methanotrophic_carbon_uptake_g_c: f64,
    methane_emission_g_c: f64,
    hydrogen_uptake_g_h: f64,
    hydrogen_emission_g_h: f64,
    oxygen_uptake_g_o: f64,
    nitrous_oxide_reduction_g_n: f64,
    nitrous_acid_dinitrogen_production_g_n: f64,
    non_band_nitrite_reduction_g_n: f64,
    band_nitrite_reduction_g_n: f64,
    non_band_nitrous_acid_reduction_g_n: f64,
    band_nitrous_acid_reduction_g_n: f64,
};

pub const GasStateUpdate = struct {
    net_carbon_dioxide_uptake_g_c: f64,
    net_methane_uptake_g_c: f64,
    net_hydrogen_uptake_g_h: f64,
    oxygen_uptake_g_o: f64,
    dinitrogen_change_g_n: f64,
    nitrous_oxide_change_g_n: f64,
};

/// Exact NITRO.F 4142--4160 and 4247--4265 inactive-layer state_updates.
///
/// NITRO repeats the same assignments at the inactive inner- and outer-layer
/// branches. The caller owns one runtime-selected layer. Both REDIST-facing
/// owners are cleared together only after their runtime dimensions have
/// already selected that layer; `transport_temperature_response` and
/// `transport_active_water_m3` are intentionally retained because TFNQ and
/// VOLQ are not assignments in either source ELSE block.
pub fn clearInactiveLayerStateUpdate(
    gas: *GasStateUpdate,
    transport: *transport_flux.State,
) void {
    gas.* = .{
        .net_carbon_dioxide_uptake_g_c = 0,
        .net_methane_uptake_g_c = 0,
        .net_hydrogen_uptake_g_h = 0,
        .oxygen_uptake_g_o = 0,
        .dinitrogen_change_g_n = 0,
        .nitrous_oxide_change_g_n = 0,
    };
    transport.non_band_ammonium_change_g_n = 0;
    transport.non_band_nitrate_change_g_n = 0;
    transport.non_band_nitrite_change_g_n = 0;
    transport.non_band_dihydrogen_phosphate_change_g_p = 0;
    transport.non_band_hydrogen_phosphate_change_g_p = 0;
    transport.band_ammonium_change_g_n = 0;
    transport.band_nitrate_change_g_n = 0;
    transport.band_nitrite_change_g_n = 0;
    transport.band_dihydrogen_phosphate_change_g_p = 0;
    transport.band_hydrogen_phosphate_change_g_p = 0;
    transport.dinitrogen_fixation_g_n = 0;
}

/// Exact NITRO.F 3996--4020 REDIST-facing signed gas state_update.
///
/// DEAD CODE WARNING (GAS-STATE-UPDATE-DEAD-001): this function has zero
/// production callers -- it is referenced only from this file's own tests
/// (see `calculateGasStateUpdate` call sites at lines ~629/655/696). The
/// live N2O/N2 partition (RN2O/RN2G equivalent) is committed independently
/// in `src/soil/nutrients/nitrogen_state_update.zig`'s `applyZone`, and the
/// live CO2/CH4/H2/O2 terms are committed inline in the same file's
/// `calculate`/`applyMicrobialExchange` region (see the `carbon_dioxide`,
/// `methane`, `hydrogen`, `gaseous_oxygen`/`aqueous_oxygen` updates there).
/// A fix applied only here has NO effect on the simulation. See
/// `docs/discrepancy_register.md`'s `GAS-STATE-UPDATE-DEAD-001` entry
/// (same dead-shadow pattern as `NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001`).
pub fn calculateGasStateUpdate(inputs: GasStateUpdateInputs) !GasStateUpdate {
    inline for (std.meta.fields(GasStateUpdateInputs)) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidTransformationAggregationInput;
    }
    const result: GasStateUpdate = .{
        // RCO2O = ((TRGOA - TRGOM) - TRGOD) - RVOXA(3)
        .net_carbon_dioxide_uptake_g_c = inputs.autotrophic_carbon_dioxide_uptake_g_c -
            inputs.heterotrophic_carbon_dioxide_emission_g_c -
            inputs.denitrification_carbon_dioxide_emission_g_c -
            inputs.methane_oxidation_respiration_g_c,
        // RCH4O = (RVOXA(3) + CGOMC(3,5)) - TRGOC
        .net_methane_uptake_g_c = inputs.methane_oxidation_respiration_g_c +
            inputs.methanotrophic_carbon_uptake_g_c -
            inputs.methane_emission_g_c,
        // RH2GO = RH2GZ - TRGOH
        .net_hydrogen_uptake_g_h = inputs.hydrogen_uptake_g_h -
            inputs.hydrogen_emission_g_h,
        // RUPOXO = TUPOX
        .oxygen_uptake_g_o = inputs.oxygen_uptake_g_o,
        // RN2G = (-TRDNO) - RCN2G
        .dinitrogen_change_g_n = -inputs.nitrous_oxide_reduction_g_n -
            inputs.nitrous_acid_dinitrogen_production_g_n,
        // RN2O = ((((-TRDN2) - TRD2B) - RCN2O) - RCN2B) + TRDNO
        .nitrous_oxide_change_g_n = -inputs.non_band_nitrite_reduction_g_n -
            inputs.band_nitrite_reduction_g_n -
            inputs.non_band_nitrous_acid_reduction_g_n -
            inputs.band_nitrous_acid_reduction_g_n +
            inputs.nitrous_oxide_reduction_g_n,
    };
    inline for (std.meta.fields(GasStateUpdate)) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.InvalidTransformationAggregationResult;
    return result;
}

/// Production binding of NITRO.F 3907--3969 after oxygen/redox allocation.
/// Multipliers are applied here exactly once; downstream state_updates consume only
/// these totals.
pub fn calculateSupplyLimited(inputs: SupplyLimitedInputs) !SupplyLimitedTotals {
    const item_count = std.math.mul(usize, inputs.complex_count, inputs.population_count) catch
        return error.InvalidTransformationAggregationDimensions;
    if (inputs.complex_count == 0 or inputs.population_count == 0)
        return error.InvalidTransformationAggregationDimensions;
    inline for (std.meta.fields(SupplyLimitedInputs)) |field| if (field.type == []const f64) {
        if (@field(inputs, field.name).len != item_count)
            return error.InvalidTransformationAggregationDimensions;
    };
    var result: SupplyLimitedTotals = .{};
    for (0..inputs.complex_count) |complex| for (0..inputs.population_count) |population| {
        if (!sourceEnabled(false, complex, population)) continue;
        const item = complex * inputs.population_count + population;
        const oxygen = inputs.oxygen_satisfaction_fraction[item];
        const redox = inputs.redox_satisfaction_fraction[item];
        if (!std.math.isFinite(oxygen) or oxygen < 0 or oxygen > 1 or
            !std.math.isFinite(redox) or redox < 0 or redox > 1)
            return error.InvalidTransformationAggregationInput;
        inline for (std.meta.fields(SupplyLimitedInputs)) |field| if (field.type == []const f64 and
            !std.mem.eql(u8, field.name, "oxygen_satisfaction_fraction") and
            !std.mem.eql(u8, field.name, "redox_satisfaction_fraction"))
        {
            if (!std.math.isFinite(@field(inputs, field.name)[item]))
                return error.InvalidTransformationAggregationInput;
        };
        result.ammonia_oxidation_g_n[0] += inputs.non_band_ammonia_oxidation_potential_g_n[item] * oxygen;
        result.ammonia_oxidation_g_n[1] += inputs.band_ammonia_oxidation_potential_g_n[item] * oxygen;
        result.nitrite_oxidation_g_n[0] += inputs.non_band_nitrite_oxidation_potential_g_n[item] * oxygen;
        result.nitrite_oxidation_g_n[1] += inputs.band_nitrite_oxidation_potential_g_n[item] * oxygen;
        result.nitrate_reduction_g_n[0] += inputs.non_band_nitrate_reduction_potential_g_n[item] * redox;
        result.nitrate_reduction_g_n[1] += inputs.band_nitrate_reduction_potential_g_n[item] * redox;
        result.heterotrophic_nitrite_reduction_g_n[0] += inputs.non_band_heterotrophic_nitrite_reduction_potential_g_n[item] * redox;
        result.heterotrophic_nitrite_reduction_g_n[1] += inputs.band_heterotrophic_nitrite_reduction_potential_g_n[item] * redox;
        result.autotrophic_nitrite_reduction_g_n[0] += inputs.non_band_autotrophic_nitrite_reduction_potential_g_n[item] * redox;
        result.autotrophic_nitrite_reduction_g_n[1] += inputs.band_autotrophic_nitrite_reduction_potential_g_n[item] * redox;
        result.autotrophic_ammonium_oxidation_g_n[0] += inputs.non_band_autotrophic_ammonium_oxidation_potential_g_n[item] * redox;
        result.autotrophic_ammonium_oxidation_g_n[1] += inputs.band_autotrophic_ammonium_oxidation_potential_g_n[item] * redox;
        result.nitrous_oxide_reduction_g_n += inputs.nitrous_oxide_reduction_potential_g_n[item] * redox;
        result.ammonium_exchange_g_n[0] += inputs.non_band_ammonium_exchange_g_n[item];
        result.ammonium_exchange_g_n[1] += inputs.band_ammonium_exchange_g_n[item];
        result.nitrate_exchange_g_n[0] += inputs.non_band_nitrate_exchange_g_n[item];
        result.nitrate_exchange_g_n[1] += inputs.band_nitrate_exchange_g_n[item];
        result.h2po4_exchange_g_p[0] += inputs.non_band_h2po4_exchange_g_p[item];
        result.h2po4_exchange_g_p[1] += inputs.band_h2po4_exchange_g_p[item];
        result.hpo4_exchange_g_p[0] += inputs.non_band_hpo4_exchange_g_p[item];
        result.hpo4_exchange_g_p[1] += inputs.band_hpo4_exchange_g_p[item];
        result.fixed_dinitrogen_g_n += inputs.fixed_dinitrogen_g_n[item];
    };
    inline for (std.meta.fields(SupplyLimitedTotals)) |field| switch (@typeInfo(field.type)) {
        .float => if (!std.math.isFinite(@field(result, field.name)))
            return error.InvalidTransformationAggregationResult,
        .array => for (@field(result, field.name)) |value| if (!std.math.isFinite(value))
            return error.InvalidTransformationAggregationResult,
        else => {},
    };
    return result;
}

pub const AcidityInputs = struct {
    ammonia_oxidation_g_n: [2]f64,
    nitrate_reduction_g_n: [2]f64,
    nitrite_reduction_g_n: [2]f64,
    nitrous_oxide_reduction_g_n: f64,
    lignin_decomposition_g_c: f64,
    available_hydrogen_mol_h: f64,
    timestep_h: f64,
};

/// Exact NITRO.F 4110--4124 XZHYS source. Positive produces H+.
pub fn acidityChangeMolH(inputs: AcidityInputs) !f64 {
    inline for (std.meta.fields(AcidityInputs)) |field| {
        const value = @field(inputs, field.name);
        switch (@typeInfo(field.type)) {
            .float => if (!std.math.isFinite(value) or value < 0)
                return error.InvalidTransformationAggregationInput,
            .array => for (value) |item| if (!std.math.isFinite(item) or item < 0)
                return error.InvalidTransformationAggregationInput,
            else => {},
        }
    }
    // NITRO computes the complete 0.1429 parenthesis before the 0.0714 term.
    const nitrogen_acidity =
        0.1429 * (inputs.ammonia_oxidation_g_n[0] + inputs.ammonia_oxidation_g_n[1] -
            inputs.nitrate_reduction_g_n[0] - inputs.nitrate_reduction_g_n[1]) -
        0.0714 * (inputs.nitrite_reduction_g_n[0] + inputs.nitrite_reduction_g_n[1] +
            inputs.nitrous_oxide_reduction_g_n);
    // AMAX1 bounds only the nitrogen term; 0.139E-01*RDOSL is added afterward.
    const bounded_nitrogen_acidity = @max(
        -inputs.available_hydrogen_mol_h * inputs.timestep_h,
        nitrogen_acidity,
    );
    const result = bounded_nitrogen_acidity + 0.0139 * inputs.lignin_decomposition_g_c;
    if (!std.math.isFinite(result)) return error.InvalidTransformationAggregationResult;
    return result;
}

/// Exact NITRO.F 3904--3994 aggregation across microbial populations.
pub fn calculate(state: *State, inputs: Inputs) !void {
    try validate(inputs);
    var result: State = .{};
    for (0..inputs.complex_count) |complex| {
        for (0..inputs.population_count) |population| {
            if (!sourceEnabled(inputs.surface_litter_layer, complex, population)) continue;
            const item = complex * inputs.population_count + population;
            result.non_band_ammonium_exchange_g_n +=
                inputs.non_band_ammonium_exchange_g_n[item];
            result.non_band_nitrate_exchange_g_n +=
                inputs.non_band_nitrate_exchange_g_n[item];
            result.non_band_dihydrogen_phosphate_exchange_g_p +=
                inputs.non_band_dihydrogen_phosphate_exchange_g_p[item];
            result.non_band_hydrogen_phosphate_exchange_g_p +=
                inputs.non_band_hydrogen_phosphate_exchange_g_p[item];
            result.band_ammonium_exchange_g_n += inputs.band_ammonium_exchange_g_n[item];
            result.band_nitrate_exchange_g_n += inputs.band_nitrate_exchange_g_n[item];
            result.band_dihydrogen_phosphate_exchange_g_p +=
                inputs.band_dihydrogen_phosphate_exchange_g_p[item];
            result.band_hydrogen_phosphate_exchange_g_p +=
                inputs.band_hydrogen_phosphate_exchange_g_p[item];
            result.fixed_dinitrogen_g_n += inputs.fixed_dinitrogen_g_n[item];
            if (inputs.surface_soil_layer) {
                result.non_band_ammonium_exchange_g_n +=
                    inputs.surface_ammonium_exchange_g_n[item] *
                    inputs.surface_non_band_ammonium_fraction;
                result.band_ammonium_exchange_g_n +=
                    inputs.surface_ammonium_exchange_g_n[item] *
                    inputs.surface_band_ammonium_fraction;
                result.non_band_nitrate_exchange_g_n +=
                    inputs.surface_nitrate_exchange_g_n[item] *
                    inputs.surface_non_band_nitrate_fraction;
                result.band_nitrate_exchange_g_n +=
                    inputs.surface_nitrate_exchange_g_n[item] *
                    inputs.surface_band_nitrate_fraction;
                // Source intentionally cross-pairs H2PO4 exchange with HPO4 fractions.
                result.non_band_dihydrogen_phosphate_exchange_g_p +=
                    inputs.surface_dihydrogen_phosphate_exchange_g_p[item] *
                    inputs.surface_non_band_hydrogen_phosphate_fraction;
                result.band_dihydrogen_phosphate_exchange_g_p +=
                    inputs.surface_dihydrogen_phosphate_exchange_g_p[item] *
                    inputs.surface_band_hydrogen_phosphate_fraction;
                result.non_band_hydrogen_phosphate_exchange_g_p +=
                    inputs.surface_hydrogen_phosphate_exchange_g_p[item] *
                    inputs.surface_non_band_dihydrogen_phosphate_fraction;
                result.band_hydrogen_phosphate_exchange_g_p +=
                    inputs.surface_hydrogen_phosphate_exchange_g_p[item] *
                    inputs.surface_band_dihydrogen_phosphate_fraction;
            }
            result.carbon_dioxide_emission_g_c += inputs.carbon_dioxide_emission_g_c[item];
            result.methane_emission_g_c += inputs.methane_emission_g_c[item];
            result.denitrification_respiration_g_c +=
                inputs.denitrification_respiration_g_c[item];
            result.oxygen_uptake_g_o += inputs.oxygen_uptake_g_o[item];
            result.non_band_nitrate_reduction_g_n +=
                inputs.non_band_nitrate_reduction_g_n[item];
            result.band_nitrate_reduction_g_n += inputs.band_nitrate_reduction_g_n[item];
            result.non_band_nitrite_reduction_g_n +=
                inputs.non_band_nitrite_reduction_g_n[item];
            result.band_nitrite_reduction_g_n += inputs.band_nitrite_reduction_g_n[item];
            result.nitrous_oxide_reduction_g_n += inputs.nitrous_oxide_reduction_g_n[item];
            result.hydrogen_emission_g_h += inputs.hydrogen_emission_g_h[item];
            try ensureFiniteState(result);
        }
    }
    if (inputs.complex_count > 5) {
        const autotrophic_complex: usize = 5;
        for (0..inputs.population_count) |population| {
            if ((population <= 2 or population == 4) and population != 2) {
                const item = autotrophic_complex * inputs.population_count + population;
                result.autotrophic_carbon_uptake_g_c += inputs.total_carbon_uptake_g_c[item];
                try ensureFiniteState(result);
            }
        }
    }
    state.* = result;
}

pub fn sourceEnabled(
    surface_litter_layer: bool,
    zero_based_complex: usize,
    zero_based_population: usize,
) bool {
    if (zero_based_complex > 5 or zero_based_population > 6) return false;
    return (!surface_litter_layer or
        (zero_based_complex != 3 and zero_based_complex != 4)) and
        (zero_based_complex != 5 or
            zero_based_population <= 2 or zero_based_population == 4);
}

fn ensureFiniteState(state: State) !void {
    inline for (@typeInfo(State).@"struct".fields) |field|
        if (!std.math.isFinite(@field(state, field.name)))
            return error.InvalidTransformationAggregationResult;
}

fn validate(inputs: Inputs) !void {
    comptime {
        @setEvalBranchQuota(5000);
    }
    if (inputs.complex_count == 0 or inputs.population_count == 0)
        return error.InvalidTransformationAggregationDimensions;
    const items = std.math.mul(usize, inputs.complex_count, inputs.population_count) catch
        return error.InvalidTransformationAggregationDimensions;
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == []const f64) {
        const values = @field(inputs, field.name);
        if (values.len != items) return error.InvalidTransformationAggregationDimensions;
        for (values) |value| if (!std.math.isFinite(value))
            return error.InvalidTransformationAggregationInput;
        const signed = comptime std.mem.indexOf(u8, field.name, "_exchange_") != null;
        if (!signed) for (values) |value| if (value < 0)
            return error.InvalidTransformationAggregationInput;
    };
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == f64) {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidTransformationAggregationInput;
    };
}

fn fixture() Inputs {
    const values = [_]f64{1} ** 6;
    return .{
        .complex_count = 6,
        .population_count = 1,
        .surface_litter_layer = false,
        .surface_soil_layer = false,
        .surface_non_band_ammonium_fraction = 0.6,
        .surface_band_ammonium_fraction = 0.4,
        .surface_non_band_nitrate_fraction = 0.6,
        .surface_band_nitrate_fraction = 0.4,
        .surface_non_band_dihydrogen_phosphate_fraction = 0.6,
        .surface_band_dihydrogen_phosphate_fraction = 0.4,
        .surface_non_band_hydrogen_phosphate_fraction = 0.7,
        .surface_band_hydrogen_phosphate_fraction = 0.3,
        .non_band_ammonium_exchange_g_n = &values,
        .band_ammonium_exchange_g_n = &values,
        .non_band_nitrate_exchange_g_n = &values,
        .band_nitrate_exchange_g_n = &values,
        .non_band_dihydrogen_phosphate_exchange_g_p = &values,
        .band_dihydrogen_phosphate_exchange_g_p = &values,
        .non_band_hydrogen_phosphate_exchange_g_p = &values,
        .band_hydrogen_phosphate_exchange_g_p = &values,
        .surface_ammonium_exchange_g_n = &values,
        .surface_nitrate_exchange_g_n = &values,
        .surface_dihydrogen_phosphate_exchange_g_p = &values,
        .surface_hydrogen_phosphate_exchange_g_p = &values,
        .fixed_dinitrogen_g_n = &values,
        .carbon_dioxide_emission_g_c = &values,
        .methane_emission_g_c = &values,
        .denitrification_respiration_g_c = &values,
        .oxygen_uptake_g_o = &values,
        .non_band_nitrate_reduction_g_n = &values,
        .band_nitrate_reduction_g_n = &values,
        .non_band_nitrite_reduction_g_n = &values,
        .band_nitrite_reduction_g_n = &values,
        .nitrous_oxide_reduction_g_n = &values,
        .hydrogen_emission_g_h = &values,
        .total_carbon_uptake_g_c = &values,
    };
}

test "aggregation totals every enabled transformation" {
    var state: State = .{};
    try calculate(&state, fixture());
    try std.testing.expectEqual(6, state.carbon_dioxide_emission_g_c);
    try std.testing.expectEqual(6, state.non_band_ammonium_exchange_g_n);
    try std.testing.expectEqual(1, state.autotrophic_carbon_uptake_g_c);
}

test "surface gates exclude POC and humus complexes" {
    var state: State = .{};
    var inputs = fixture();
    inputs.surface_litter_layer = true;
    try calculate(&state, inputs);
    try std.testing.expectEqual(4, state.carbon_dioxide_emission_g_c);
}

test "upper soil exchange is independent of the surface-litter complex gate" {
    var state: State = .{};
    var inputs = fixture();
    inputs.surface_soil_layer = true;
    try calculate(&state, inputs);
    try std.testing.expectApproxEqAbs(9.6, state.non_band_ammonium_exchange_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(
        10.2,
        state.non_band_dihydrogen_phosphate_exchange_g_p,
        1e-12,
    );
}

test "runtime entries outside the source six by seven role axes are ignored" {
    const values = [_]f64{1} ** 56;
    var inputs = fixture();
    inputs.complex_count = 7;
    inputs.population_count = 8;
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == []const f64) @field(inputs, field.name) = &values;
    }
    var state: State = .{};
    try calculate(&state, inputs);
    // K=0..4 contribute seven populations and K=5 contributes N=1,2,3,5.
    try std.testing.expectEqual(@as(f64, 39), state.carbon_dioxide_emission_g_c);
    // The second source loop includes K=5 populations N=1,2,5 only.
    try std.testing.expectEqual(@as(f64, 3), state.autotrophic_carbon_uptake_g_c);
}

test "invalid input leaves state unchanged" {
    var state: State = .{ .carbon_dioxide_emission_g_c = 7 };
    var inputs = fixture();
    inputs.oxygen_uptake_g_o = &.{ 1, 1, std.math.nan(f64), 1, 1, 1 };
    try std.testing.expectError(error.InvalidTransformationAggregationInput, calculate(&state, inputs));
    try std.testing.expectEqual(7, state.carbon_dioxide_emission_g_c);
}

test "supply-limited state_update closes N and P and preserves source multipliers" {
    const count = 4;
    const zero = [_]f64{0} ** count;
    const one = [_]f64{1} ** count;
    const oxygen = [_]f64{ 1, 0.5, 0.25, 0 };
    const redox = [_]f64{ 0, 0.25, 0.5, 1 };
    const totals = try calculateSupplyLimited(.{
        .complex_count = 2,
        .population_count = 2,
        .oxygen_satisfaction_fraction = &oxygen,
        .redox_satisfaction_fraction = &redox,
        .non_band_ammonia_oxidation_potential_g_n = &one,
        .band_ammonia_oxidation_potential_g_n = &zero,
        .non_band_nitrite_oxidation_potential_g_n = &one,
        .band_nitrite_oxidation_potential_g_n = &zero,
        .non_band_nitrate_reduction_potential_g_n = &one,
        .band_nitrate_reduction_potential_g_n = &zero,
        .non_band_heterotrophic_nitrite_reduction_potential_g_n = &one,
        .band_heterotrophic_nitrite_reduction_potential_g_n = &zero,
        .non_band_autotrophic_nitrite_reduction_potential_g_n = &zero,
        .band_autotrophic_nitrite_reduction_potential_g_n = &zero,
        .non_band_autotrophic_ammonium_oxidation_potential_g_n = &zero,
        .band_autotrophic_ammonium_oxidation_potential_g_n = &zero,
        .nitrous_oxide_reduction_potential_g_n = &one,
        .non_band_ammonium_exchange_g_n = &one,
        .band_ammonium_exchange_g_n = &zero,
        .non_band_nitrate_exchange_g_n = &zero,
        .band_nitrate_exchange_g_n = &zero,
        .non_band_h2po4_exchange_g_p = &one,
        .band_h2po4_exchange_g_p = &zero,
        .non_band_hpo4_exchange_g_p = &zero,
        .band_hpo4_exchange_g_p = &zero,
        .fixed_dinitrogen_g_n = &one,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), totals.ammonia_oxidation_g_n[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), totals.nitrite_oxidation_g_n[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), totals.nitrate_reduction_g_n[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.75), totals.heterotrophic_nitrite_reduction_g_n[0], 1e-15);
    try std.testing.expectEqual(@as(f64, 4), totals.fixed_dinitrogen_g_n);

    const mineral_n_change =
        -totals.ammonia_oxidation_g_n[0] +
        totals.nitrite_oxidation_g_n[0] -
        totals.nitrate_reduction_g_n[0] +
        totals.ammonia_oxidation_g_n[0] -
        totals.nitrite_oxidation_g_n[0] +
        totals.nitrate_reduction_g_n[0] -
        totals.heterotrophic_nitrite_reduction_g_n[0];
    const gas_n_change =
        totals.heterotrophic_nitrite_reduction_g_n[0] -
        totals.nitrous_oxide_reduction_g_n +
        totals.nitrous_oxide_reduction_g_n -
        totals.fixed_dinitrogen_g_n;
    const microbial_fixed_n_change = totals.fixed_dinitrogen_g_n;
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        mineral_n_change + gas_n_change + microbial_fixed_n_change,
        1e-15,
    );
    const mineral_p_change = -totals.h2po4_exchange_g_p[0];
    const microbial_p_change = totals.h2po4_exchange_g_p[0];
    try std.testing.expectEqual(@as(f64, 0), mineral_p_change + microbial_p_change);
}

test "NITRO acidity state_update retains nitrogen lignin and hydrogen bound terms" {
    const result = try acidityChangeMolH(.{
        .ammonia_oxidation_g_n = .{ 2, 1 },
        .nitrate_reduction_g_n = .{ 0.5, 0.5 },
        .nitrite_reduction_g_n = .{ 0.25, 0.25 },
        .nitrous_oxide_reduction_g_n = 0.5,
        .lignin_decomposition_g_c = 2,
        .available_hydrogen_mol_h = 10,
        .timestep_h = 1,
    });
    const expected = 0.1429 * 2 - 0.0714 + 0.0139 * 2;
    try std.testing.expectApproxEqAbs(expected, result, 1e-15);
    const bounded = try acidityChangeMolH(.{
        .ammonia_oxidation_g_n = .{ 0, 0 },
        .nitrate_reduction_g_n = .{ 100, 100 },
        .nitrite_reduction_g_n = .{ 0, 0 },
        .nitrous_oxide_reduction_g_n = 0,
        .lignin_decomposition_g_c = 0,
        .available_hydrogen_mol_h = 0.25,
        .timestep_h = 1,
    });
    try std.testing.expectEqual(@as(f64, -0.25), bounded);
}

test "NITRO acidity adds lignin after applying the available-hydrogen bound" {
    const result = try acidityChangeMolH(.{
        .ammonia_oxidation_g_n = .{ 0, 0 },
        .nitrate_reduction_g_n = .{ 100, 100 },
        .nitrite_reduction_g_n = .{ 0, 0 },
        .nitrous_oxide_reduction_g_n = 0,
        .lignin_decomposition_g_c = 2,
        .available_hydrogen_mol_h = 0.25,
        .timestep_h = 1,
    });
    try std.testing.expectApproxEqAbs(@as(f64, -0.2222), result, 1e-15);
}

test "NITRO 3996-4020 gas state_update preserves signed source equations" {
    const result = try calculateGasStateUpdate(.{
        .autotrophic_carbon_dioxide_uptake_g_c = 8,
        .heterotrophic_carbon_dioxide_emission_g_c = 3,
        .denitrification_carbon_dioxide_emission_g_c = 1,
        .methane_oxidation_respiration_g_c = 0.5,
        .methanotrophic_carbon_uptake_g_c = 0.25,
        .methane_emission_g_c = 0.4,
        .hydrogen_uptake_g_h = 0.3,
        .hydrogen_emission_g_h = 0.1,
        .oxygen_uptake_g_o = 2,
        .nitrous_oxide_reduction_g_n = 0.4,
        .nitrous_acid_dinitrogen_production_g_n = 0.2,
        .non_band_nitrite_reduction_g_n = 0.7,
        .band_nitrite_reduction_g_n = 0.3,
        .non_band_nitrous_acid_reduction_g_n = 0.1,
        .band_nitrous_acid_reduction_g_n = 0.05,
    });
    try std.testing.expectEqual(@as(f64, 3.5), result.net_carbon_dioxide_uptake_g_c);
    try std.testing.expectApproxEqAbs(@as(f64, 0.35), result.net_methane_uptake_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.net_hydrogen_uptake_g_h, 1e-15);
    try std.testing.expectEqual(@as(f64, 2), result.oxygen_uptake_g_o);
    try std.testing.expectApproxEqAbs(@as(f64, -0.6), result.dinitrogen_change_g_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.75), result.nitrous_oxide_change_g_n, 1e-15);
}

test "NITRO gas state_update preserves branch-sensitive source operation order" {
    const result = try calculateGasStateUpdate(.{
        .autotrophic_carbon_dioxide_uptake_g_c = 1.0e16,
        .heterotrophic_carbon_dioxide_emission_g_c = 1.0e16,
        .denitrification_carbon_dioxide_emission_g_c = 1,
        .methane_oxidation_respiration_g_c = 1,
        .methanotrophic_carbon_uptake_g_c = 1,
        .methane_emission_g_c = 1.0e16,
        .hydrogen_uptake_g_h = 1,
        .hydrogen_emission_g_h = 1,
        .oxygen_uptake_g_o = 0,
        .nitrous_oxide_reduction_g_n = 1,
        .nitrous_acid_dinitrogen_production_g_n = 1,
        .non_band_nitrite_reduction_g_n = 1.0e16,
        .band_nitrite_reduction_g_n = 1,
        .non_band_nitrous_acid_reduction_g_n = 1,
        .band_nitrous_acid_reduction_g_n = 1,
    });
    try std.testing.expectEqual(@as(f64, -2), result.net_carbon_dioxide_uptake_g_c);
    try std.testing.expectEqual(@as(f64, -9.999999999999998e15), result.net_methane_uptake_g_c);
    try std.testing.expectEqual(@as(f64, -1.0e16), result.nitrous_oxide_change_g_n);
}

test "NITRO gas state_update rejects a non-finite late term before returning" {
    var inputs: GasStateUpdateInputs = .{
        .autotrophic_carbon_dioxide_uptake_g_c = 0,
        .heterotrophic_carbon_dioxide_emission_g_c = 0,
        .denitrification_carbon_dioxide_emission_g_c = 0,
        .methane_oxidation_respiration_g_c = 0,
        .methanotrophic_carbon_uptake_g_c = 0,
        .methane_emission_g_c = 0,
        .hydrogen_uptake_g_h = 0,
        .hydrogen_emission_g_h = 0,
        .oxygen_uptake_g_o = 0,
        .nitrous_oxide_reduction_g_n = 0,
        .nitrous_acid_dinitrogen_production_g_n = 0,
        .non_band_nitrite_reduction_g_n = 0,
        .band_nitrite_reduction_g_n = 0,
        .non_band_nitrous_acid_reduction_g_n = 0,
        .band_nitrous_acid_reduction_g_n = 0,
    };
    inputs.band_nitrous_acid_reduction_g_n = std.math.nan(f64);
    try std.testing.expectError(error.InvalidTransformationAggregationInput, calculateGasStateUpdate(inputs));
}

test "NITRO 4142-4160 and 4247-4265 inactive branches share exact clearing" {
    var gas: GasStateUpdate = .{
        .net_carbon_dioxide_uptake_g_c = 1,
        .net_methane_uptake_g_c = -2,
        .net_hydrogen_uptake_g_h = 3,
        .oxygen_uptake_g_o = 4,
        .dinitrogen_change_g_n = -5,
        .nitrous_oxide_change_g_n = 6,
    };
    var transport = try transport_flux.State.init(std.testing.allocator, 1);
    defer transport.deinit();
    transport.non_band_ammonium_change_g_n = 1;
    transport.band_ammonium_change_g_n = 2;
    transport.non_band_nitrate_change_g_n = 3;
    transport.band_nitrate_change_g_n = 4;
    transport.non_band_nitrite_change_g_n = 5;
    transport.band_nitrite_change_g_n = 6;
    transport.non_band_dihydrogen_phosphate_change_g_p = 7;
    transport.band_dihydrogen_phosphate_change_g_p = 8;
    transport.non_band_hydrogen_phosphate_change_g_p = 9;
    transport.band_hydrogen_phosphate_change_g_p = 10;
    transport.dinitrogen_fixation_g_n = 11;
    transport.transport_temperature_response = 0.75;
    transport.transport_active_water_m3 = 0.25;
    transport.dissolved_carbon_change_g_c[0] = 12;
    transport.dissolved_nitrogen_change_g_n[0] = 13;
    transport.dissolved_phosphorus_change_g_p[0] = 14;
    transport.acetate_change_g_c[0] = 15;

    clearInactiveLayerStateUpdate(&gas, &transport);

    inline for (std.meta.fields(GasStateUpdate)) |field|
        try std.testing.expectEqual(@as(f64, 0), @field(gas, field.name));
    inline for (.{
        transport.non_band_ammonium_change_g_n,
        transport.band_ammonium_change_g_n,
        transport.non_band_nitrate_change_g_n,
        transport.band_nitrate_change_g_n,
        transport.non_band_nitrite_change_g_n,
        transport.band_nitrite_change_g_n,
        transport.non_band_dihydrogen_phosphate_change_g_p,
        transport.band_dihydrogen_phosphate_change_g_p,
        transport.non_band_hydrogen_phosphate_change_g_p,
        transport.band_hydrogen_phosphate_change_g_p,
        transport.dinitrogen_fixation_g_n,
    }) |value| try std.testing.expectEqual(@as(f64, 0), value);
    try std.testing.expectEqual(@as(f64, 12), transport.dissolved_carbon_change_g_c[0]);
    try std.testing.expectEqual(@as(f64, 13), transport.dissolved_nitrogen_change_g_n[0]);
    try std.testing.expectEqual(@as(f64, 14), transport.dissolved_phosphorus_change_g_p[0]);
    try std.testing.expectEqual(@as(f64, 15), transport.acetate_change_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0.75), transport.transport_temperature_response);
    try std.testing.expectEqual(@as(f64, 0.25), transport.transport_active_water_m3);
}

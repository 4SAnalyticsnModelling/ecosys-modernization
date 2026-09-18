const std = @import("std");

pub const Parameters = struct {
    minimum_competition_fraction: f64,
    nitrate_half_saturation_g_n_per_m3: f64,
    nitrite_half_saturation_g_n_per_m3: f64,
    nitrous_oxide_half_saturation_g_n_per_m3: f64,
    product_inhibition_rate_g_n_per_m3_step: f64,
    carbon_per_nitrate_n_g_c_per_g_n: f64,
    carbon_per_nitrite_n_g_c_per_g_n: f64,
    carbon_per_nitrous_oxide_n_g_c_per_g_n: f64,
    nitrate_n_per_unmet_oxygen_g_n_per_g_o: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteDenitrificationParameter;
        if (self.minimum_competition_fraction < 0 or self.nitrate_half_saturation_g_n_per_m3 <= 0 or self.nitrite_half_saturation_g_n_per_m3 <= 0 or self.nitrous_oxide_half_saturation_g_n_per_m3 <= 0 or self.product_inhibition_rate_g_n_per_m3_step <= 0 or self.carbon_per_nitrate_n_g_c_per_g_n <= 0 or self.carbon_per_nitrite_n_g_c_per_g_n <= 0 or self.carbon_per_nitrous_oxide_n_g_c_per_g_n <= 0 or self.nitrate_n_per_unmet_oxygen_g_n_per_g_o < 0) return error.InvalidDenitrificationParameter;
    }
};

pub const Zone = struct {
    nitrate_fraction: f64,
    nitrite_fraction: f64,
    nitrate_concentration_g_n_per_m3: f64,
    nitrite_concentration_g_n_per_m3: f64,
    nitrate_amount_g_n: f64,
    nitrite_amount_g_n: f64,
    previous_total_nitrate_demand_g_n: f64,
    previous_nitrate_reduction_capacity_g_n: f64,
    previous_total_nitrite_demand_g_n: f64,
    previous_nitrite_reduction_capacity_g_n: f64,
    fallback_available_fraction: f64,
};

pub const Inputs = struct {
    non_band: Zone,
    band: Zone,
    oxygen_demand_g_o: f64,
    oxygen_reduction_g_o: f64,
    biologically_active_water_m3: f64,
    substrate_complex_fraction: f64,
    available_doc_g_c: f64,
    microbial_active_fraction: f64,
    nitrous_oxide_concentration_g_n_per_m3: f64,
    nitrous_oxide_amount_g_n: f64,
    previous_total_nitrous_oxide_demand_g_n: f64,
    previous_nitrous_oxide_reduction_capacity_g_n: f64,
    nitrous_oxide_competition_fraction: ?f64 = null,
    timestep_h: f64,
    negligible_water_volume_m3: f64,
    negligible_nitrogen_g_n: f64,
};

pub const Potential = struct {
    non_band_nitrate_reduction_g_n: f64,
    band_nitrate_reduction_g_n: f64,
    non_band_nitrite_reduction_g_n: f64,
    band_nitrite_reduction_g_n: f64,
    nitrous_oxide_reduction_g_n: f64,
    nitrate_reduction_respiration_g_c: f64,
    nitrite_reduction_respiration_g_c: f64,
    nitrous_oxide_reduction_respiration_g_c: f64,
    non_band_nitrate_capacity_g_n: f64,
    band_nitrate_capacity_g_n: f64,
    non_band_nitrite_capacity_g_n: f64,
    band_nitrite_capacity_g_n: f64,
    nitrous_oxide_capacity_g_n: f64,
};

/// Ports NITRO heterotrophic NO3 -> NO2 -> N2O -> N2 potential reduction.
/// Each electron-acceptor stage consumes the unmet redox demand and DOC left
/// by the preceding stage, retaining the original product-feedback equations.
pub fn calculateHeterotrophicPotential(inputs: Inputs, parameters: Parameters) !Potential {
    try parameters.validate();
    try validateInputs(inputs);
    const nitrate_competition = [_]f64{
        competitionFraction(inputs.non_band.previous_total_nitrate_demand_g_n, inputs.non_band.previous_nitrate_reduction_capacity_g_n, inputs.microbial_active_fraction * inputs.non_band.fallback_available_fraction, inputs.negligible_nitrogen_g_n, parameters.minimum_competition_fraction),
        competitionFraction(inputs.band.previous_total_nitrate_demand_g_n, inputs.band.previous_nitrate_reduction_capacity_g_n, inputs.microbial_active_fraction * inputs.band.fallback_available_fraction, inputs.negligible_nitrogen_g_n, parameters.minimum_competition_fraction),
    };
    const nitrite_competition = [_]f64{
        competitionFraction(inputs.non_band.previous_total_nitrite_demand_g_n, inputs.non_band.previous_nitrite_reduction_capacity_g_n, inputs.microbial_active_fraction * inputs.non_band.fallback_available_fraction, inputs.negligible_nitrogen_g_n, parameters.minimum_competition_fraction),
        competitionFraction(inputs.band.previous_total_nitrite_demand_g_n, inputs.band.previous_nitrite_reduction_capacity_g_n, inputs.microbial_active_fraction * inputs.band.fallback_available_fraction, inputs.negligible_nitrogen_g_n, parameters.minimum_competition_fraction),
    };
    const nitrous_oxide_competition = inputs.nitrous_oxide_competition_fraction orelse competitionFraction(inputs.previous_total_nitrous_oxide_demand_g_n, inputs.previous_nitrous_oxide_reduction_capacity_g_n, inputs.microbial_active_fraction, inputs.negligible_nitrogen_g_n, parameters.minimum_competition_fraction);
    const zones = [_]Zone{ inputs.non_band, inputs.band };
    const unmet_oxygen_g_o = @max(0, inputs.oxygen_demand_g_o - inputs.oxygen_reduction_g_o);
    const nitrate_demand_g_n = parameters.nitrate_n_per_unmet_oxygen_g_n_per_g_o * unmet_oxygen_g_o;
    var nitrate_raw_capacity: [2]f64 = .{ 0, 0 };
    for (zones, 0..) |zone, index| if (zone.nitrate_concentration_g_n_per_m3 > 0) {
        nitrate_raw_capacity[index] = zone.nitrate_fraction * nitrate_demand_g_n * monod(zone.nitrate_concentration_g_n_per_m3, parameters.nitrate_half_saturation_g_n_per_m3) /
            (1 + zone.nitrite_concentration_g_n_per_m3 * parameters.nitrate_half_saturation_g_n_per_m3 / (zone.nitrate_concentration_g_n_per_m3 * parameters.nitrite_half_saturation_g_n_per_m3));
    };
    const nitrate_product_factor = productFactor(nitrate_raw_capacity[0] + nitrate_raw_capacity[1], inputs, parameters);
    const nitrate_capacity = [_]f64{ nitrate_raw_capacity[0] * nitrate_product_factor, nitrate_raw_capacity[1] * nitrate_product_factor };
    const doc_nitrate_budget_g_n = inputs.available_doc_g_c / parameters.carbon_per_nitrate_n_g_c_per_g_n * inputs.timestep_h;
    const nitrate_reduction = [_]f64{
        @max(0, @min(nitrate_capacity[0], doc_nitrate_budget_g_n * inputs.non_band.nitrate_fraction, inputs.non_band.nitrate_amount_g_n * nitrate_competition[0] * inputs.timestep_h)),
        @max(0, @min(nitrate_capacity[1], doc_nitrate_budget_g_n * inputs.band.nitrate_fraction, inputs.band.nitrate_amount_g_n * nitrate_competition[1] * inputs.timestep_h)),
    };
    const nitrate_total = nitrate_reduction[0] + nitrate_reduction[1];
    const nitrate_respiration_g_c = parameters.carbon_per_nitrate_n_g_c_per_g_n * nitrate_total;

    const nitrite_demand_g_n = @max(0, nitrate_demand_g_n - nitrate_total);
    var nitrite_raw_capacity: [2]f64 = .{ 0, 0 };
    for (zones, 0..) |zone, index| if (zone.nitrite_concentration_g_n_per_m3 > 0) {
        nitrite_raw_capacity[index] = zone.nitrite_fraction * nitrite_demand_g_n * monod(zone.nitrite_concentration_g_n_per_m3, parameters.nitrite_half_saturation_g_n_per_m3) /
            (1 + inputs.nitrous_oxide_concentration_g_n_per_m3 * parameters.nitrite_half_saturation_g_n_per_m3 / (zone.nitrite_concentration_g_n_per_m3 * parameters.nitrous_oxide_half_saturation_g_n_per_m3));
    };
    const nitrite_product_factor = productFactor(nitrite_raw_capacity[0] + nitrite_raw_capacity[1], inputs, parameters);
    const nitrite_capacity = [_]f64{ nitrite_raw_capacity[0] * nitrite_product_factor, nitrite_raw_capacity[1] * nitrite_product_factor };
    const doc_after_nitrate_g_c = @max(0, inputs.available_doc_g_c - nitrate_respiration_g_c);
    const doc_nitrite_budget_g_n = doc_after_nitrate_g_c / parameters.carbon_per_nitrite_n_g_c_per_g_n * inputs.timestep_h;
    const nitrite_reduction = [_]f64{
        @max(0, @min(nitrite_capacity[0], doc_nitrite_budget_g_n * inputs.non_band.nitrate_fraction, (inputs.non_band.nitrite_amount_g_n * inputs.timestep_h + nitrate_reduction[0]) * nitrite_competition[0])),
        @max(0, @min(nitrite_capacity[1], doc_nitrite_budget_g_n * inputs.band.nitrate_fraction, (inputs.band.nitrite_amount_g_n * inputs.timestep_h + nitrate_reduction[1]) * nitrite_competition[1])),
    };
    const nitrite_total = nitrite_reduction[0] + nitrite_reduction[1];
    const nitrite_respiration_g_c = parameters.carbon_per_nitrite_n_g_c_per_g_n * nitrite_total;

    const nitrous_oxide_demand_g_n = @max(0, (nitrite_demand_g_n - nitrite_total) * 2);
    const nitrous_oxide_raw_capacity = nitrous_oxide_demand_g_n * monod(inputs.nitrous_oxide_concentration_g_n_per_m3, parameters.nitrous_oxide_half_saturation_g_n_per_m3);
    const nitrous_oxide_capacity = nitrous_oxide_raw_capacity * productFactor(nitrous_oxide_raw_capacity, inputs, parameters);
    const doc_after_nitrite_g_c = @max(0, doc_after_nitrate_g_c - nitrite_respiration_g_c);
    const doc_nitrous_oxide_budget_g_n = doc_after_nitrite_g_c / parameters.carbon_per_nitrous_oxide_n_g_c_per_g_n * inputs.timestep_h;
    const nitrous_oxide_supply_g_n = (inputs.nitrous_oxide_amount_g_n * inputs.timestep_h + nitrite_total) * nitrous_oxide_competition;
    const nitrous_oxide_reduction = @max(0, @min(nitrous_oxide_capacity, doc_nitrous_oxide_budget_g_n, nitrous_oxide_supply_g_n));
    return .{
        .non_band_nitrate_reduction_g_n = nitrate_reduction[0],
        .band_nitrate_reduction_g_n = nitrate_reduction[1],
        .non_band_nitrite_reduction_g_n = nitrite_reduction[0],
        .band_nitrite_reduction_g_n = nitrite_reduction[1],
        .nitrous_oxide_reduction_g_n = nitrous_oxide_reduction,
        .nitrate_reduction_respiration_g_c = nitrate_respiration_g_c,
        .nitrite_reduction_respiration_g_c = nitrite_respiration_g_c,
        .nitrous_oxide_reduction_respiration_g_c = parameters.carbon_per_nitrous_oxide_n_g_c_per_g_n * nitrous_oxide_reduction,
        .non_band_nitrate_capacity_g_n = nitrate_capacity[0],
        .band_nitrate_capacity_g_n = nitrate_capacity[1],
        .non_band_nitrite_capacity_g_n = nitrite_capacity[0],
        .band_nitrite_capacity_g_n = nitrite_capacity[1],
        .nitrous_oxide_capacity_g_n = nitrous_oxide_capacity,
    };
}

pub const AutotrophicZone = struct {
    nitrite_fraction: f64,
    nitrite_concentration_g_n_per_m3: f64,
    nitrite_amount_g_n: f64,
    ammonium_amount_g_n: f64,
    nitrite_competition_fraction: f64,
    ammonium_competition_fraction: f64,
    preceding_ammonia_oxidation_g_n: f64,
};

pub const AutotrophicInputs = struct {
    non_band: AutotrophicZone,
    band: AutotrophicZone,
    oxygen_demand_g_o: f64,
    oxygen_reduction_g_o: f64,
    aqueous_co2_activity: f64,
    biologically_active_water_m3: f64,
    timestep_h: f64,
    negligible_water_volume_m3: f64,
    nitrite_oxidizer_carbon_efficiency_g_c_per_g_n: f64,
    anaerobic_growth_respiration_fraction: f64,
    additional_ammonium_oxidation_per_nitrite_reduction: f64,
    /// Source NITRO.F 2029/2031 `FNH4*3.0*ZNH4S(L,NY,NX)*XNFH`: how much NO2
    /// reduction one gram of ammonium N can support as electron donor. This is
    /// a distinct constant from
    /// `additional_ammonium_oxidation_per_nitrite_reduction`, which is source
    /// `0.333` at NITRO.F 2040/2041. The bound path previously reconstructed
    /// this limit as `NH4 / 0.333 = 3.003003...*NH4`, conflating the two and
    /// overstating the donor ceiling by a factor of `1/(3*0.333) = 1.001001`.
    /// The isolated exact kernel `autotrophic_nitrite_reduction.zig`
    /// already carried both constants separately; see its test
    /// "NITRO autotrophic denitrification retains distinct 3 and 0.333
    /// factors".
    ammonium_supply_per_nitrite_reduction: f64 = 3,
};

pub const AutotrophicPotential = struct {
    non_band_nitrite_reduction_g_n: f64,
    band_nitrite_reduction_g_n: f64,
    non_band_additional_ammonium_oxidation_g_n: f64,
    band_additional_ammonium_oxidation_g_n: f64,
    growth_respiration_g_c: f64,
    non_band_capacity_g_n: f64,
    band_capacity_g_n: f64,
};

/// Ports NITRO's K=5,N=1 nitrifier-denitrification branch. NO2 reduction is
/// constrained by NO2, NH4 electron donor, CO2, and unmet O2 demand.
pub fn calculateAutotrophicPotential(inputs: AutotrophicInputs, parameters: Parameters) !AutotrophicPotential {
    try parameters.validate();
    inline for (@typeInfo(AutotrophicInputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidAutotrophicDenitrificationInput;
    inline for (.{ inputs.non_band, inputs.band }) |zone| inline for (@typeInfo(AutotrophicZone).@"struct".fields) |field| if (!std.math.isFinite(@field(zone, field.name)) or @field(zone, field.name) < 0) return error.InvalidAutotrophicDenitrificationZone;
    if (inputs.timestep_h <= 0 or inputs.additional_ammonium_oxidation_per_nitrite_reduction <= 0 or inputs.ammonium_supply_per_nitrite_reduction <= 0) return error.InvalidAutotrophicDenitrificationInput;
    const zones = [_]AutotrophicZone{ inputs.non_band, inputs.band };
    const unmet_oxygen_g_o = @max(0, inputs.oxygen_demand_g_o - inputs.oxygen_reduction_g_o);
    const nitrite_demand_g_n = parameters.nitrate_n_per_unmet_oxygen_g_n_per_g_o * unmet_oxygen_g_o * inputs.aqueous_co2_activity;
    var raw_capacity: [2]f64 = .{ 0, 0 };
    for (zones, 0..) |zone, index| raw_capacity[index] = zone.nitrite_fraction * nitrite_demand_g_n * monod(zone.nitrite_concentration_g_n_per_m3, parameters.nitrite_half_saturation_g_n_per_m3);
    const product_factor = if (inputs.biologically_active_water_m3 > inputs.negligible_water_volume_m3) 1 / (1 + (raw_capacity[0] + raw_capacity[1]) / (parameters.product_inhibition_rate_g_n_per_m3_step * inputs.biologically_active_water_m3)) else 0;
    const capacity = [_]f64{ raw_capacity[0] * product_factor, raw_capacity[1] * product_factor };
    var reduction: [2]f64 = .{ 0, 0 };
    for (zones, 0..) |zone, index| {
        const nitrite_supply = zone.nitrite_amount_g_n + zone.preceding_ammonia_oxidation_g_n;
        const electron_donor_limit = zone.ammonium_competition_fraction * inputs.ammonium_supply_per_nitrite_reduction * zone.ammonium_amount_g_n * inputs.timestep_h;
        reduction[index] = @max(0, @min(capacity[index], nitrite_supply, electron_donor_limit));
    }
    const total = reduction[0] + reduction[1];
    return .{
        .non_band_nitrite_reduction_g_n = reduction[0],
        .band_nitrite_reduction_g_n = reduction[1],
        .non_band_additional_ammonium_oxidation_g_n = inputs.additional_ammonium_oxidation_per_nitrite_reduction * reduction[0],
        .band_additional_ammonium_oxidation_g_n = inputs.additional_ammonium_oxidation_per_nitrite_reduction * reduction[1],
        .growth_respiration_g_c = total * inputs.nitrite_oxidizer_carbon_efficiency_g_c_per_g_n * inputs.anaerobic_growth_respiration_fraction,
        .non_band_capacity_g_n = capacity[0],
        .band_capacity_g_n = capacity[1],
    };
}

pub const AutotrophicState = struct { ammonium_g_n: f64, nitrite_g_n: f64, nitrous_oxide_g_n: f64 };

/// NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001: this is a reference
/// implementation with zero production callers (referenced only from this
/// file's own unit tests). Production applies autotrophic denitrification's
/// potentials via `src/soil/nutrients/nitrogen_state_update.zig`'s
/// `applyZone`, an independently-maintained reimplementation. A fix applied
/// only here has no effect on the simulation.
pub fn state_updateAutotrophicZone(state: *AutotrophicState, potential_nitrite_reduction_g_n: f64, redox_limitation_fraction: f64, additional_ammonium_oxidation_per_nitrite_reduction: f64) !f64 {
    inline for (@typeInfo(AutotrophicState).@"struct".fields) |field| if (!std.math.isFinite(@field(state.*, field.name)) or @field(state.*, field.name) < 0) return error.InvalidAutotrophicDenitrificationState;
    if (!std.math.isFinite(potential_nitrite_reduction_g_n) or potential_nitrite_reduction_g_n < 0 or !std.math.isFinite(redox_limitation_fraction) or redox_limitation_fraction < 0 or redox_limitation_fraction > 1 or !std.math.isFinite(additional_ammonium_oxidation_per_nitrite_reduction) or additional_ammonium_oxidation_per_nitrite_reduction <= 0 or additional_ammonium_oxidation_per_nitrite_reduction >= 1) return error.InvalidAutotrophicDenitrificationStateUpdate;
    const requested = potential_nitrite_reduction_g_n * redox_limitation_fraction;
    const reduction = @min(requested, state.ammonium_g_n / additional_ammonium_oxidation_per_nitrite_reduction, state.nitrite_g_n / (1 - additional_ammonium_oxidation_per_nitrite_reduction));
    const ammonium_oxidation = additional_ammonium_oxidation_per_nitrite_reduction * reduction;
    state.ammonium_g_n -= ammonium_oxidation;
    state.nitrite_g_n += ammonium_oxidation - reduction;
    state.nitrous_oxide_g_n += reduction;
    return reduction;
}

pub const State = struct {
    non_band_nitrate_g_n: f64,
    band_nitrate_g_n: f64,
    non_band_nitrite_g_n: f64,
    band_nitrite_g_n: f64,
    nitrous_oxide_g_n: f64,
    dinitrogen_g_n: f64,
};

pub const Actual = struct {
    non_band_nitrate_reduction_g_n: f64,
    band_nitrate_reduction_g_n: f64,
    non_band_nitrite_reduction_g_n: f64,
    band_nitrite_reduction_g_n: f64,
    nitrous_oxide_reduction_g_n: f64,
};

/// Applies the potential pathway after the coupled redox solve. Sequential
/// products are immediately available downstream and total N is conserved.
///
/// NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001: this is a reference
/// implementation with zero production callers (referenced only from this
/// file's own unit tests). Production applies heterotrophic denitrification's
/// potentials via `src/soil/nutrients/nitrogen_state_update.zig`'s
/// `applyZone`, an independently-maintained reimplementation. A fix applied
/// only here has no effect on the simulation.
pub fn state_update(state: *State, potential: Potential, redox_limitation_fraction: f64) !Actual {
    inline for (@typeInfo(State).@"struct".fields) |field| if (!std.math.isFinite(@field(state.*, field.name)) or @field(state.*, field.name) < 0) return error.InvalidDenitrificationState;
    if (!std.math.isFinite(redox_limitation_fraction) or redox_limitation_fraction < 0 or redox_limitation_fraction > 1) return error.InvalidDenitrificationStateUpdate;
    inline for (@typeInfo(Potential).@"struct".fields) |field| if (!std.math.isFinite(@field(potential, field.name)) or @field(potential, field.name) < 0) return error.InvalidDenitrificationPotential;
    const nitrate_non_band = @min(state.non_band_nitrate_g_n, potential.non_band_nitrate_reduction_g_n * redox_limitation_fraction);
    const nitrate_band = @min(state.band_nitrate_g_n, potential.band_nitrate_reduction_g_n * redox_limitation_fraction);
    const nitrite_non_band_available = state.non_band_nitrite_g_n + nitrate_non_band;
    const nitrite_band_available = state.band_nitrite_g_n + nitrate_band;
    const nitrite_non_band = @min(nitrite_non_band_available, potential.non_band_nitrite_reduction_g_n * redox_limitation_fraction);
    const nitrite_band = @min(nitrite_band_available, potential.band_nitrite_reduction_g_n * redox_limitation_fraction);
    const nitrous_oxide_available = state.nitrous_oxide_g_n + nitrite_non_band + nitrite_band;
    const nitrous_oxide = @min(nitrous_oxide_available, potential.nitrous_oxide_reduction_g_n * redox_limitation_fraction);
    state.non_band_nitrate_g_n -= nitrate_non_band;
    state.band_nitrate_g_n -= nitrate_band;
    state.non_band_nitrite_g_n = nitrite_non_band_available - nitrite_non_band;
    state.band_nitrite_g_n = nitrite_band_available - nitrite_band;
    state.nitrous_oxide_g_n = nitrous_oxide_available - nitrous_oxide;
    state.dinitrogen_g_n += nitrous_oxide;
    return .{ .non_band_nitrate_reduction_g_n = nitrate_non_band, .band_nitrate_reduction_g_n = nitrate_band, .non_band_nitrite_reduction_g_n = nitrite_non_band, .band_nitrite_reduction_g_n = nitrite_band, .nitrous_oxide_reduction_g_n = nitrous_oxide };
}

fn productFactor(raw_capacity: f64, inputs: Inputs, parameters: Parameters) f64 {
    if (inputs.biologically_active_water_m3 > inputs.negligible_water_volume_m3 and inputs.substrate_complex_fraction > 0) return 1 / (1 + raw_capacity / (parameters.product_inhibition_rate_g_n_per_m3_step * inputs.biologically_active_water_m3 * inputs.substrate_complex_fraction));
    return 0;
}

pub fn competitionFraction(previous_total: f64, previous_capacity: f64, fallback: f64, negligible: f64, minimum: f64) f64 {
    return @max(minimum, if (previous_total > negligible) previous_capacity / previous_total else fallback);
}

fn monod(concentration: f64, half_saturation: f64) f64 {
    return concentration / (concentration + half_saturation);
}

fn validateInputs(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == f64 and (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0)) return error.InvalidDenitrificationInput;
    inline for (.{ inputs.non_band, inputs.band }) |zone| inline for (@typeInfo(Zone).@"struct".fields) |field| if (!std.math.isFinite(@field(zone, field.name)) or @field(zone, field.name) < 0) return error.InvalidDenitrificationZone;
    if (inputs.nitrous_oxide_competition_fraction) |fraction| if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1) return error.InvalidDenitrificationInput;
    if (inputs.timestep_h <= 0) return error.InvalidDenitrificationInput;
}

fn testParameters() Parameters {
    return .{ .minimum_competition_fraction = 0.001, .nitrate_half_saturation_g_n_per_m3 = 1.4, .nitrite_half_saturation_g_n_per_m3 = 1.4, .nitrous_oxide_half_saturation_g_n_per_m3 = 0.014, .product_inhibition_rate_g_n_per_m3_step = 1, .carbon_per_nitrate_n_g_c_per_g_n = 0.429, .carbon_per_nitrite_n_g_c_per_g_n = 0.429, .carbon_per_nitrous_oxide_n_g_c_per_g_n = 0.214, .nitrate_n_per_unmet_oxygen_g_n_per_g_o = 0.875 };
}

fn testZone() Zone {
    return .{ .nitrate_fraction = 0.5, .nitrite_fraction = 0.5, .nitrate_concentration_g_n_per_m3 = 2, .nitrite_concentration_g_n_per_m3 = 1, .nitrate_amount_g_n = 10, .nitrite_amount_g_n = 2, .previous_total_nitrate_demand_g_n = 0, .previous_nitrate_reduction_capacity_g_n = 0, .previous_total_nitrite_demand_g_n = 0, .previous_nitrite_reduction_capacity_g_n = 0, .fallback_available_fraction = 1 };
}

test "heterotrophic pathway produces finite sequential reduction potentials" {
    const zone = testZone();
    const result = try calculateHeterotrophicPotential(.{ .non_band = zone, .band = zone, .oxygen_demand_g_o = 4, .oxygen_reduction_g_o = 1, .biologically_active_water_m3 = 10, .substrate_complex_fraction = 0.5, .available_doc_g_c = 10, .microbial_active_fraction = 1, .nitrous_oxide_concentration_g_n_per_m3 = 0.1, .nitrous_oxide_amount_g_n = 1, .previous_total_nitrous_oxide_demand_g_n = 0, .previous_nitrous_oxide_reduction_capacity_g_n = 0, .timestep_h = 1, .negligible_water_volume_m3 = 1e-12, .negligible_nitrogen_g_n = 1e-12 }, testParameters());
    try std.testing.expect(result.non_band_nitrate_reduction_g_n > 0);
    try std.testing.expect(result.non_band_nitrite_reduction_g_n > 0);
    try std.testing.expect(result.nitrous_oxide_reduction_g_n > 0);
}

test "denitrification state_update conserves N across all intermediates" {
    var state: State = .{ .non_band_nitrate_g_n = 1, .band_nitrate_g_n = 1, .non_band_nitrite_g_n = 0.2, .band_nitrite_g_n = 0.2, .nitrous_oxide_g_n = 0.1, .dinitrogen_g_n = 0 };
    const before = state.non_band_nitrate_g_n + state.band_nitrate_g_n + state.non_band_nitrite_g_n + state.band_nitrite_g_n + state.nitrous_oxide_g_n + state.dinitrogen_g_n;
    const potential: Potential = .{ .non_band_nitrate_reduction_g_n = 0.5, .band_nitrate_reduction_g_n = 0.5, .non_band_nitrite_reduction_g_n = 0.6, .band_nitrite_reduction_g_n = 0.6, .nitrous_oxide_reduction_g_n = 1, .nitrate_reduction_respiration_g_c = 0, .nitrite_reduction_respiration_g_c = 0, .nitrous_oxide_reduction_respiration_g_c = 0, .non_band_nitrate_capacity_g_n = 0.5, .band_nitrate_capacity_g_n = 0.5, .non_band_nitrite_capacity_g_n = 0.6, .band_nitrite_capacity_g_n = 0.6, .nitrous_oxide_capacity_g_n = 1 };
    _ = try state_update(&state, potential, 1);
    const after = state.non_band_nitrate_g_n + state.band_nitrate_g_n + state.non_band_nitrite_g_n + state.band_nitrite_g_n + state.nitrous_oxide_g_n + state.dinitrogen_g_n;
    try std.testing.expectApproxEqAbs(before, after, 1e-14);
}

test "autotrophic denitrification conserves N with coupled ammonium oxidation" {
    var state: AutotrophicState = .{ .ammonium_g_n = 1, .nitrite_g_n = 1, .nitrous_oxide_g_n = 0 };
    const before = state.ammonium_g_n + state.nitrite_g_n + state.nitrous_oxide_g_n;
    const reduction = try state_updateAutotrophicZone(&state, 0.9, 1, 0.333);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), reduction, 1e-14);
    try std.testing.expectApproxEqAbs(before, state.ammonium_g_n + state.nitrite_g_n + state.nitrous_oxide_g_n, 1e-14);
}

/// Builds the denitrifying regime the fertilizer sensitivity uses.
/// `substrate_scale` is the fertilizer multiplier: it scales the mineral
/// nitrogen inventory AND its concentration together, which is what adding
/// fertilizer N to a soil layer actually does.
fn fertilizerSensitivityInputs(substrate_scale: f64) Inputs {
    var zone = testZone();
    zone.nitrate_amount_g_n *= substrate_scale;
    zone.nitrate_concentration_g_n_per_m3 *= substrate_scale;
    zone.nitrite_amount_g_n *= substrate_scale;
    zone.nitrite_concentration_g_n_per_m3 *= substrate_scale;
    return .{
        .non_band = zone,
        .band = zone,
        // A large unmet oxygen demand opens the denitrification pathway:
        // `nitrate_demand_g_n = nitrate_n_per_unmet_oxygen * (demand -
        // reduction)`. DOC is ample so carbon never binds.
        .oxygen_demand_g_o = 400,
        .oxygen_reduction_g_o = 1,
        .biologically_active_water_m3 = 10,
        .substrate_complex_fraction = 0.5,
        .available_doc_g_c = 1000,
        .microbial_active_fraction = 1,
        .nitrous_oxide_concentration_g_n_per_m3 = 0.1,
        .nitrous_oxide_amount_g_n = 1,
        .previous_total_nitrous_oxide_demand_g_n = 0,
        .previous_nitrous_oxide_reduction_capacity_g_n = 0,
        .timestep_h = 1,
        .negligible_water_volume_m3 = 1e-12,
        .negligible_nitrogen_g_n = 1e-12,
    };
}

test "SENSITIVITY: doubling fertilizer nitrogen raises nitrous oxide PRODUCTION by 20%" {
    // P3 asks for oracle-independent sensitivity tests and names
    // "2x fertilizer -> N2O up" as one of three. It was repeatedly recorded as
    // blocked on the deck reaching the fertilizer date (doy 136-137, hour
    // ~3264) while the deck stops at hour 346. That reasoning was wrong: the
    // sensitivity is a property of the KERNEL. The deck is needed only to
    // measure it end to end, not to establish the direction.
    //
    // Nothing here reads legacy output, so it cannot fabricate agreement.
    //
    // The chain in `calculateHeterotrophicPotential`:
    //   nitrate_reduction        NO3  -> NO2
    //   nitrite_reduction        NO2  -> N2O   <- THE PRODUCTION TERM
    //   nitrous_oxide_reduction  N2O  -> N2    <- a competing SINK
    //
    // MECHANISM, measured rather than assumed, and not what I first guessed.
    // `nitrate_reduction` equals `nitrate_capacity` at EVERY scale below, so
    // this kernel is capacity-limited by unmet oxygen demand throughout, never
    // limited by the nitrate inventory. The fertilizer sensitivity therefore
    // enters through the MONOD CONCENTRATION term, not through the inventory
    // bound. A first draft asserted substrate-limitation as its vacuity guard
    // and failed for exactly this reason.
    const parameters = testParameters();
    const baseline = try calculateHeterotrophicPotential(fertilizerSensitivityInputs(1), parameters);
    const doubled = try calculateHeterotrophicPotential(fertilizerSensitivityInputs(2), parameters);

    // The regime, asserted so the mechanism above cannot silently change.
    try std.testing.expect(baseline.non_band_nitrate_reduction_g_n > 0);
    try std.testing.expectEqual(
        baseline.non_band_nitrate_capacity_g_n,
        baseline.non_band_nitrate_reduction_g_n,
    );

    // THE CLAIM. Doubling fertilizer raises N2O production by a MEANINGFUL
    // amount, not by float noise. Measured 2026-09-12: 1.8071610 -> 2.1774323,
    // +20.5%. Asserting >10% makes a kernel that merely returns a
    // one-part-in-1e12 difference fail, which a bare `>` would not.
    const baseline_production = baseline.non_band_nitrite_reduction_g_n +
        baseline.band_nitrite_reduction_g_n;
    const doubled_production = doubled.non_band_nitrite_reduction_g_n +
        doubled.band_nitrite_reduction_g_n;
    try std.testing.expect(doubled_production > 1.10 * baseline_production);

    // Monotone across the whole range, not just at 2x: a single ratio can be
    // satisfied by a non-monotone response that happens to be higher at one
    // point. Measured production, both zones summed, at
    // 0.5/1/2/4/8: 2.3163 / 3.6143 / 4.3549 / 4.6789 / 4.8151.
    var previous: f64 = 0;
    for ([_]f64{ 0.5, 1, 2, 4, 8 }) |scale| {
        const result = try calculateHeterotrophicPotential(
            fertilizerSensitivityInputs(scale),
            parameters,
        );
        const production = result.non_band_nitrite_reduction_g_n +
            result.band_nitrite_reduction_g_n;
        try std.testing.expect(production >= previous);
        previous = production;
    }

    // SATURATION, which is the Monod signature and a guard against a
    // linear-in-substrate defect. Going 1x -> 2x gains far more than 4x -> 8x,
    // because the concentration is already past its half-saturation constant
    // (2 against 1.4 g N m-3). A kernel that scaled linearly with fertilizer
    // would fail this.
    const quadrupled = try calculateHeterotrophicPotential(fertilizerSensitivityInputs(4), parameters);
    const octupled = try calculateHeterotrophicPotential(fertilizerSensitivityInputs(8), parameters);
    const first_doubling_gain = doubled_production - baseline_production;
    const last_doubling_gain =
        (octupled.non_band_nitrite_reduction_g_n + octupled.band_nitrite_reduction_g_n) -
        (quadrupled.non_band_nitrite_reduction_g_n + quadrupled.band_nitrite_reduction_g_n);
    try std.testing.expect(last_doubling_gain > 0);
    try std.testing.expect(last_doubling_gain < 0.5 * first_doubling_gain);

    // NOT asserted, deliberately: that net N2O EMISSION rises. Emission is
    // production minus `nitrous_oxide_reduction_g_n`, and the measured sink
    // rises too (4.6143 -> 4.9584) before saturating, so the net can move
    // either way. Asserting emission would assert something this kernel does
    // not guarantee. The oracle's end-to-end number, for whenever the deck can
    // be compared against it, is N2O_FLUX -0.41872 g N m-2 against FERTZR_N
    // 15.45 g N m-2 -- a 2.7% emission factor
    // (docs/legacy_growing_season_targets_1998.md).
}

test "SENSITIVITY: with no mineral nitrogen there is no nitrous oxide production" {
    // The zero end of the same curve, and the negative control for the test
    // above: a kernel that produced N2O from nothing would satisfy every
    // monotonicity and saturation check while being unphysical.
    const parameters = testParameters();
    var empty = fertilizerSensitivityInputs(1);
    empty.non_band.nitrate_amount_g_n = 0;
    empty.non_band.nitrate_concentration_g_n_per_m3 = 0;
    empty.non_band.nitrite_amount_g_n = 0;
    empty.non_band.nitrite_concentration_g_n_per_m3 = 0;
    empty.band = empty.non_band;
    const result = try calculateHeterotrophicPotential(empty, parameters);
    try std.testing.expectEqual(@as(f64, 0), result.non_band_nitrate_reduction_g_n);
    try std.testing.expectEqual(@as(f64, 0), result.band_nitrate_reduction_g_n);
    try std.testing.expectEqual(@as(f64, 0), result.non_band_nitrite_reduction_g_n);
    try std.testing.expectEqual(@as(f64, 0), result.band_nitrite_reduction_g_n);
}

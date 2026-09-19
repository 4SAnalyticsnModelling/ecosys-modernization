const std = @import("std");

pub const Parameters = struct {
    minimum_competition_fraction: f64,
    inhibition_decay_per_h: f64,
    inhibition_decay_ammonium_constant_g_n_per_m3: f64,
    ammonia_product_inhibition_g_n_per_m3: f64,
    ammonium_half_saturation_g_n_per_m3: f64,
    nitrite_half_saturation_g_n_per_m3: f64,
    ammonia_oxidation_rate_g_n_per_g_c_h: f64,
    nitrite_oxidation_rate_g_n_per_g_c_h: f64,
    ammonia_oxidizer_carbon_efficiency_g_c_per_g_n: f64,
    nitrite_oxidizer_carbon_efficiency_g_c_per_g_n: f64,
    growth_respiration_fraction: f64,
    oxygen_per_respired_carbon_g_o_per_g_c: f64,
    oxygen_per_ammonium_n_g_o_per_g_n: f64,
    oxygen_per_nitrite_n_g_o_per_g_n: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(self, field.name))) return error.NonFiniteNitrificationParameter;
        if (self.minimum_competition_fraction < 0 or self.inhibition_decay_per_h < 0 or self.inhibition_decay_ammonium_constant_g_n_per_m3 <= 0 or self.ammonia_product_inhibition_g_n_per_m3 <= 0 or self.ammonium_half_saturation_g_n_per_m3 <= 0 or self.nitrite_half_saturation_g_n_per_m3 <= 0 or self.ammonia_oxidation_rate_g_n_per_g_c_h < 0 or self.nitrite_oxidation_rate_g_n_per_g_c_h < 0 or self.ammonia_oxidizer_carbon_efficiency_g_c_per_g_n < 0 or self.nitrite_oxidizer_carbon_efficiency_g_c_per_g_n < 0 or self.growth_respiration_fraction < 0 or self.oxygen_per_respired_carbon_g_o_per_g_c < 0 or self.oxygen_per_ammonium_n_g_o_per_g_n < 0 or self.oxygen_per_nitrite_n_g_o_per_g_n < 0) return error.InvalidNitrificationParameter;
    }
};

pub const Zone = struct {
    substrate_access_fraction: f64,
    fallback_available_fraction: f64,
    ammonium_fallback_fraction: f64,
    ammonium_concentration_g_n_per_m3: f64,
    ammonia_concentration_g_n_per_m3: f64,
    nitrite_concentration_g_n_per_m3: f64,
    ammonium_amount_g_n: f64,
    nitrite_amount_g_n: f64,
    previous_total_ammonium_demand_g_n: f64,
    previous_ammonia_oxidation_capacity_g_n: f64,
    previous_total_nitrite_demand_g_n: f64,
    previous_nitrite_oxidation_capacity_g_n: f64,
};

pub const Inputs = struct {
    non_band: Zone,
    band: Zone,
    temperature_water_activity: f64,
    nitrogen_phosphorus_activity: f64,
    aqueous_co2_activity: f64,
    active_oxidizer_biomass_g_c: f64,
    microbial_active_fraction: f64,
    timestep_h: f64,
    initial_inhibition_activity: f64,
    current_inhibition_activity: f64,
    negligible_demand_g_n: f64,
};

pub const Potential = struct {
    updated_inhibition_activity: f64,
    non_band_ammonium_competition_fraction: f64,
    band_ammonium_competition_fraction: f64,
    non_band_nitrite_competition_fraction: f64,
    band_nitrite_competition_fraction: f64,
    non_band_ammonia_oxidation_g_n: f64,
    band_ammonia_oxidation_g_n: f64,
    non_band_nitrite_oxidation_g_n: f64,
    band_nitrite_oxidation_g_n: f64,
    non_band_ammonia_oxidation_capacity_g_n: f64,
    band_ammonia_oxidation_capacity_g_n: f64,
    non_band_nitrite_oxidation_capacity_g_n: f64,
    band_nitrite_oxidation_capacity_g_n: f64,
    ammonia_oxidizer_growth_respiration_g_c: f64,
    nitrite_oxidizer_growth_respiration_g_c: f64,
    ammonia_oxidation_oxygen_demand_g_o: f64,
    nitrite_oxidation_oxygen_demand_g_o: f64,
};

/// Ports NITRO's N=1 NH3-oxidizer and N=2 NO2-oxidizer potential rates.
/// These are single biological-step calculations; the old whole-process NPH
/// gas loops are not reproduced and actual rates are state_updateted after the
/// shared oxygen solve.
pub fn calculatePotential(inputs: Inputs, parameters: Parameters) !Potential {
    try parameters.validate();
    try validateInputs(inputs);
    const updated_inhibition = if (inputs.initial_inhibition_activity > inputs.negligible_demand_g_n) @max(0, inputs.current_inhibition_activity * (1 - parameters.inhibition_decay_per_h * inputs.temperature_water_activity * inputs.timestep_h)) else inputs.current_inhibition_activity;
    const non_band_ammonium_competition = competition(inputs.non_band.previous_total_ammonium_demand_g_n, inputs.non_band.previous_ammonia_oxidation_capacity_g_n, inputs.non_band.ammonium_fallback_fraction * inputs.microbial_active_fraction, inputs.negligible_demand_g_n, parameters.minimum_competition_fraction);
    const band_ammonium_competition = competition(inputs.band.previous_total_ammonium_demand_g_n, inputs.band.previous_ammonia_oxidation_capacity_g_n, inputs.band.ammonium_fallback_fraction * inputs.microbial_active_fraction, inputs.negligible_demand_g_n, parameters.minimum_competition_fraction);
    const non_band_nitrite_competition = competition(inputs.non_band.previous_total_nitrite_demand_g_n, inputs.non_band.previous_nitrite_oxidation_capacity_g_n, inputs.microbial_active_fraction * inputs.non_band.fallback_available_fraction, inputs.negligible_demand_g_n, parameters.minimum_competition_fraction);
    const band_nitrite_competition = competition(inputs.band.previous_total_nitrite_demand_g_n, inputs.band.previous_nitrite_oxidation_capacity_g_n, inputs.microbial_active_fraction * inputs.band.fallback_available_fraction, inputs.negligible_demand_g_n, parameters.minimum_competition_fraction);

    const common_activity = inputs.temperature_water_activity * inputs.nitrogen_phosphorus_activity * inputs.aqueous_co2_activity * inputs.active_oxidizer_biomass_g_c * inputs.timestep_h;
    const ammonia_unlimited = parameters.ammonia_oxidation_rate_g_n_per_g_c_h * common_activity;
    const non_band_ammonia_capacity = inputs.non_band.substrate_access_fraction * ammonia_unlimited / (1 + inputs.non_band.ammonia_concentration_g_n_per_m3 / parameters.ammonia_product_inhibition_g_n_per_m3) * monod(inputs.non_band.ammonium_concentration_g_n_per_m3, parameters.ammonium_half_saturation_g_n_per_m3);
    const band_ammonia_capacity = inputs.band.substrate_access_fraction * ammonia_unlimited / (1 + inputs.band.ammonia_concentration_g_n_per_m3 / parameters.ammonia_product_inhibition_g_n_per_m3) * monod(inputs.band.ammonium_concentration_g_n_per_m3, parameters.ammonium_half_saturation_g_n_per_m3);
    const non_band_inhibition = if (inputs.initial_inhibition_activity > inputs.negligible_demand_g_n) inputs.initial_inhibition_activity - updated_inhibition / (1 + inputs.non_band.ammonium_concentration_g_n_per_m3 / parameters.inhibition_decay_ammonium_constant_g_n_per_m3) else 1;
    const band_inhibition = if (inputs.initial_inhibition_activity > inputs.negligible_demand_g_n) inputs.initial_inhibition_activity - updated_inhibition / (1 + inputs.band.ammonium_concentration_g_n_per_m3 / parameters.inhibition_decay_ammonium_constant_g_n_per_m3) else 1;
    if (!std.math.isFinite(non_band_inhibition) or !std.math.isFinite(band_inhibition) or non_band_inhibition < 0 or band_inhibition < 0) return error.InvalidNitrificationInhibition;
    const non_band_ammonia = @max(0, @min(non_band_ammonia_capacity, non_band_ammonium_competition * inputs.non_band.ammonium_amount_g_n * inputs.timestep_h)) * non_band_inhibition;
    const band_ammonia = @max(0, @min(band_ammonia_capacity, band_ammonium_competition * inputs.band.ammonium_amount_g_n * inputs.timestep_h)) * band_inhibition;

    const nitrite_unlimited = parameters.nitrite_oxidation_rate_g_n_per_g_c_h * common_activity;
    const non_band_nitrite_capacity = nitrite_unlimited * inputs.non_band.substrate_access_fraction * monod(inputs.non_band.nitrite_concentration_g_n_per_m3, parameters.nitrite_half_saturation_g_n_per_m3);
    const band_nitrite_capacity = nitrite_unlimited * inputs.band.substrate_access_fraction * monod(inputs.band.nitrite_concentration_g_n_per_m3, parameters.nitrite_half_saturation_g_n_per_m3);
    const non_band_nitrite = @max(0, @min(non_band_nitrite_capacity, non_band_nitrite_competition * inputs.non_band.nitrite_amount_g_n * inputs.timestep_h));
    const band_nitrite = @max(0, @min(band_nitrite_capacity, band_nitrite_competition * inputs.band.nitrite_amount_g_n * inputs.timestep_h));
    const ammonia_total = non_band_ammonia + band_ammonia;
    const nitrite_total = non_band_nitrite + band_nitrite;
    const ammonia_respiration = @max(0, ammonia_total * parameters.ammonia_oxidizer_carbon_efficiency_g_c_per_g_n * parameters.growth_respiration_fraction);
    const nitrite_respiration = @max(0, nitrite_total * parameters.nitrite_oxidizer_carbon_efficiency_g_c_per_g_n * parameters.growth_respiration_fraction);
    return .{
        .updated_inhibition_activity = updated_inhibition,
        .non_band_ammonium_competition_fraction = non_band_ammonium_competition,
        .band_ammonium_competition_fraction = band_ammonium_competition,
        .non_band_nitrite_competition_fraction = non_band_nitrite_competition,
        .band_nitrite_competition_fraction = band_nitrite_competition,
        .non_band_ammonia_oxidation_g_n = non_band_ammonia,
        .band_ammonia_oxidation_g_n = band_ammonia,
        .non_band_nitrite_oxidation_g_n = non_band_nitrite,
        .band_nitrite_oxidation_g_n = band_nitrite,
        .non_band_ammonia_oxidation_capacity_g_n = non_band_ammonia_capacity,
        .band_ammonia_oxidation_capacity_g_n = band_ammonia_capacity,
        .non_band_nitrite_oxidation_capacity_g_n = non_band_nitrite_capacity,
        .band_nitrite_oxidation_capacity_g_n = band_nitrite_capacity,
        .ammonia_oxidizer_growth_respiration_g_c = ammonia_respiration,
        .nitrite_oxidizer_growth_respiration_g_c = nitrite_respiration,
        .ammonia_oxidation_oxygen_demand_g_o = parameters.oxygen_per_respired_carbon_g_o_per_g_c * ammonia_respiration + parameters.oxygen_per_ammonium_n_g_o_per_g_n * ammonia_total,
        .nitrite_oxidation_oxygen_demand_g_o = parameters.oxygen_per_respired_carbon_g_o_per_g_c * nitrite_respiration + parameters.oxygen_per_nitrite_n_g_o_per_g_n * nitrite_total,
    };
}

pub const MineralNitrogen = struct { ammonium_g_n: f64, nitrite_g_n: f64, nitrate_g_n: f64 };
pub const ActualFlux = struct { ammonium_oxidized_g_n: f64, nitrite_oxidized_g_n: f64 };

/// StateUpdates rates after the shared O2 solver. Sequential availability permits
/// newly produced NO2 to be oxidized in the same biological step and exactly
/// conserves mineral N.
///
/// NITRIFICATION-DENITRIFICATION-STATE-UPDATE-DEAD-001: this is a reference
/// implementation with zero production callers (referenced only from this
/// file's own unit tests). Production applies nitrification's potentials via
/// `src/soil/nutrients/nitrogen_state_update.zig`'s `applyZone`, an
/// independently-maintained reimplementation. A fix applied only here has no
/// effect on the simulation.
pub fn state_updateZone(state: *MineralNitrogen, potential_ammonia_oxidation_g_n: f64, potential_nitrite_oxidation_g_n: f64, oxygen_limitation_fraction: f64) !ActualFlux {
    inline for (@typeInfo(MineralNitrogen).@"struct".fields) |field| if (!std.math.isFinite(@field(state.*, field.name)) or @field(state.*, field.name) < 0) return error.InvalidMineralNitrogenState;
    if (!std.math.isFinite(potential_ammonia_oxidation_g_n) or potential_ammonia_oxidation_g_n < 0 or !std.math.isFinite(potential_nitrite_oxidation_g_n) or potential_nitrite_oxidation_g_n < 0 or !std.math.isFinite(oxygen_limitation_fraction) or oxygen_limitation_fraction < 0 or oxygen_limitation_fraction > 1) return error.InvalidNitrificationStateUpdate;
    const ammonium_oxidized = @min(state.ammonium_g_n, potential_ammonia_oxidation_g_n * oxygen_limitation_fraction);
    const nitrite_available = state.nitrite_g_n + ammonium_oxidized;
    const nitrite_oxidized = @min(nitrite_available, potential_nitrite_oxidation_g_n * oxygen_limitation_fraction);
    state.ammonium_g_n -= ammonium_oxidized;
    state.nitrite_g_n = nitrite_available - nitrite_oxidized;
    state.nitrate_g_n += nitrite_oxidized;
    return .{ .ammonium_oxidized_g_n = ammonium_oxidized, .nitrite_oxidized_g_n = nitrite_oxidized };
}

fn competition(previous_total: f64, previous_capacity: f64, fallback: f64, negligible: f64, minimum: f64) f64 {
    return @max(minimum, if (previous_total > negligible) previous_capacity / previous_total else fallback);
}

fn monod(concentration: f64, half_saturation: f64) f64 {
    return concentration / (concentration + half_saturation);
}

fn validateInputs(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteNitrificationInput;
    inline for (.{ inputs.non_band, inputs.band }) |zone| inline for (@typeInfo(Zone).@"struct".fields) |field| if (!std.math.isFinite(@field(zone, field.name)) or @field(zone, field.name) < 0) return error.InvalidNitrificationZone;
    if (inputs.temperature_water_activity < 0 or inputs.nitrogen_phosphorus_activity < 0 or inputs.aqueous_co2_activity < 0 or inputs.active_oxidizer_biomass_g_c < 0 or inputs.microbial_active_fraction < 0 or inputs.timestep_h <= 0 or inputs.initial_inhibition_activity < 0 or inputs.current_inhibition_activity < 0 or inputs.negligible_demand_g_n < 0) return error.InvalidNitrificationInput;
}

fn testParameters() Parameters {
    return .{ .minimum_competition_fraction = 0.001, .inhibition_decay_per_h = 0.0002, .inhibition_decay_ammonium_constant_g_n_per_m3 = 7000, .ammonia_product_inhibition_g_n_per_m3 = 14, .ammonium_half_saturation_g_n_per_m3 = 1.4, .nitrite_half_saturation_g_n_per_m3 = 1.4, .ammonia_oxidation_rate_g_n_per_g_c_h = 0.125, .nitrite_oxidation_rate_g_n_per_g_c_h = 0.125, .ammonia_oxidizer_carbon_efficiency_g_c_per_g_n = 0.3, .nitrite_oxidizer_carbon_efficiency_g_c_per_g_n = 0.1, .growth_respiration_fraction = 0.5, .oxygen_per_respired_carbon_g_o_per_g_c = 2.667, .oxygen_per_ammonium_n_g_o_per_g_n = 3.429, .oxygen_per_nitrite_n_g_o_per_g_n = 1.143 };
}

fn testZone() Zone {
    return .{ .substrate_access_fraction = 0.5, .fallback_available_fraction = 1, .ammonium_fallback_fraction = 1, .ammonium_concentration_g_n_per_m3 = 1.4, .ammonia_concentration_g_n_per_m3 = 0, .nitrite_concentration_g_n_per_m3 = 1.4, .ammonium_amount_g_n = 10, .nitrite_amount_g_n = 10, .previous_total_ammonium_demand_g_n = 0, .previous_ammonia_oxidation_capacity_g_n = 0, .previous_total_nitrite_demand_g_n = 0, .previous_nitrite_oxidation_capacity_g_n = 0 };
}

test "ammonia and nitrite potentials preserve NITRO Monod equations" {
    const zone = testZone();
    const result = try calculatePotential(.{ .non_band = zone, .band = zone, .temperature_water_activity = 1, .nitrogen_phosphorus_activity = 1, .aqueous_co2_activity = 1, .active_oxidizer_biomass_g_c = 10, .microbial_active_fraction = 1, .timestep_h = 1, .initial_inhibition_activity = 0, .current_inhibition_activity = 0, .negligible_demand_g_n = 1e-12 }, testParameters());
    try std.testing.expectApproxEqAbs(@as(f64, 0.3125), result.non_band_ammonia_oxidation_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3125), result.band_ammonia_oxidation_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3125), result.non_band_nitrite_oxidation_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3125), result.non_band_ammonia_oxidation_capacity_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3125), result.non_band_nitrite_oxidation_capacity_g_n, 1e-14);
}

test "historical capacity remains substrate-unlimited by competing inventory" {
    var zone = testZone();
    zone.ammonium_amount_g_n = 0.01;
    zone.nitrite_amount_g_n = 0.01;
    const result = try calculatePotential(.{ .non_band = zone, .band = zone, .temperature_water_activity = 1, .nitrogen_phosphorus_activity = 1, .aqueous_co2_activity = 1, .active_oxidizer_biomass_g_c = 10, .microbial_active_fraction = 1, .timestep_h = 1, .initial_inhibition_activity = 0, .current_inhibition_activity = 0, .negligible_demand_g_n = 1e-12 }, testParameters());
    try std.testing.expect(result.non_band_ammonia_oxidation_capacity_g_n > result.non_band_ammonia_oxidation_g_n);
    try std.testing.expect(result.non_band_nitrite_oxidation_capacity_g_n > result.non_band_nitrite_oxidation_g_n);
}

test "ammonium competition fallback scales with the ammonium zone fraction, not the nitrate zone fraction (issue-054)" {
    var zone = testZone();
    // Distinct, independently-placed ammonium (0.75) vs nitrate (0.65) zone
    // fractions, matching charge_classification.zig's own test values.
    // previous_total_ammonium_demand_g_n/previous_total_nitrite_demand_g_n are
    // already 0 in testZone(), so both competition terms take the fallback
    // branch (cold-start / newly-active-layer condition per issue-054).
    zone.ammonium_fallback_fraction = 0.75;
    zone.fallback_available_fraction = 0.65;
    const result = try calculatePotential(.{ .non_band = zone, .band = zone, .temperature_water_activity = 1, .nitrogen_phosphorus_activity = 1, .aqueous_co2_activity = 1, .active_oxidizer_biomass_g_c = 10, .microbial_active_fraction = 1, .timestep_h = 1, .initial_inhibition_activity = 0, .current_inhibition_activity = 0, .negligible_demand_g_n = 1e-12 }, testParameters());
    // Before the fix this evaluated to 0.65 (the nitrate-zone fraction, reused
    // in error for the ammonia-oxidizer's own NH4 fallback). After the fix it
    // must equal the ammonium-zone fraction, 0.75.
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), result.non_band_ammonium_competition_fraction, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), result.band_ammonium_competition_fraction, 1e-14);
    // The nitrite-oxidizer's own fallback must remain on the nitrate-zone
    // fraction (unchanged behavior).
    try std.testing.expectApproxEqAbs(@as(f64, 0.65), result.non_band_nitrite_competition_fraction, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.65), result.band_nitrite_competition_fraction, 1e-14);
}

test "nitrification state_update conserves mineral nitrogen and limits substrate" {
    var state: MineralNitrogen = .{ .ammonium_g_n = 0.2, .nitrite_g_n = 0.1, .nitrate_g_n = 1 };
    const before = state.ammonium_g_n + state.nitrite_g_n + state.nitrate_g_n;
    const flux = try state_updateZone(&state, 1, 1, 0.5);
    try std.testing.expectEqual(@as(f64, 0.2), flux.ammonium_oxidized_g_n);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), flux.nitrite_oxidized_g_n, 1e-14);
    try std.testing.expectApproxEqAbs(before, state.ammonium_g_n + state.nitrite_g_n + state.nitrate_g_n, 1e-14);
}

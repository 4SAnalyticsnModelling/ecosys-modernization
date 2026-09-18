const std = @import("std");
const aqueous_network = @import("../solute/aqueous_network.zig");

pub const LayerReactionAdmissionInputs = struct {
    /// Legacy DLYR(3,L,NY,NX), soil-layer thickness (m).
    layer_thickness_m: f64,
    /// Legacy DLYRM, minimum active soil-layer thickness (m).
    minimum_layer_thickness_m: f64,
    /// Legacy VOLW(L,NY,NX), water volume in the layer (m3).
    water_volume_m3: f64,
    /// Legacy ZEROS2(NY,NX), cell-specific minimum water volume (m3).
    minimum_water_volume_m3: f64,
};

/// Direct translation of SOLUTE.F lines 158--161, the admission gate around
/// the layer preparation and reactions beginning at line 163. Equality with
/// either threshold is inactive because the source uses strict `.GT.` tests.
pub fn admitsLayerReactions(inputs: LayerReactionAdmissionInputs) !bool {
    inline for (@typeInfo(LayerReactionAdmissionInputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidLayerReactionAdmissionInput;
    }
    return inputs.layer_thickness_m > inputs.minimum_layer_thickness_m and
        inputs.water_volume_m3 > inputs.minimum_water_volume_m3;
}

pub const LayerZoneFractions = struct {
    ammonium_non_band: f64,
    ammonium_band: f64,
    nitrate_non_band: f64,
    nitrate_band: f64,
    phosphate_non_band: f64,
    phosphate_band: f64,
};

pub const LayerZonePreparationInputs = struct {
    /// Legacy VOLW (m3 layer-1).
    water_volume_m3: f64,
    /// Legacy BKVL (Mg layer-1).
    soil_mass_megagrams: f64,
    /// Legacy VOLA (m3 layer-1), used by SOLUTE when soil mass is absent.
    soil_volume_m3: f64,
    fractions: LayerZoneFractions,
    /// Legacy ZEROS threshold applied to BKVL (Mg layer-1).
    positive_soil_mass_threshold_megagrams: f64,
};

/// SOLUTE's zone water volumes and normalization bases. A normalization base
/// has units of Mg when soil mass is present, but intentionally has units of
/// m3 in the source's zero-soil-mass fallback branch.
pub const LayerZonePreparation = struct {
    ammonium_non_band_water_m3: f64,
    ammonium_band_water_m3: f64,
    nitrate_non_band_water_m3: f64,
    nitrate_band_water_m3: f64,
    phosphate_non_band_water_m3: f64,
    phosphate_band_water_m3: f64,
    whole_layer_normalization_basis: f64,
    ammonium_non_band_normalization_basis: f64,
    ammonium_band_normalization_basis: f64,
    nitrate_non_band_normalization_basis: f64,
    nitrate_band_normalization_basis: f64,
    phosphate_non_band_normalization_basis: f64,
    phosphate_band_normalization_basis: f64,
};

/// Direct source-order translation of SOLUTE.F lines 163--193 (`VOLWNH`
/// through `BKVLPB`). The mixed-unit fallback is retained deliberately for
/// translation fidelity and surfaced in the result type's documentation.
pub fn prepareLayerZones(inputs: LayerZonePreparationInputs) !LayerZonePreparation {
    try validateLayerZonePreparationInputs(inputs);

    const ammonium_non_band_water_m3 = inputs.water_volume_m3 * inputs.fractions.ammonium_non_band;
    const ammonium_band_water_m3 = inputs.water_volume_m3 * inputs.fractions.ammonium_band;
    const nitrate_non_band_water_m3 = inputs.water_volume_m3 * inputs.fractions.nitrate_non_band;
    const nitrate_band_water_m3 = inputs.water_volume_m3 * inputs.fractions.nitrate_band;
    const phosphate_non_band_water_m3 = inputs.water_volume_m3 * inputs.fractions.phosphate_non_band;
    const phosphate_band_water_m3 = inputs.water_volume_m3 * inputs.fractions.phosphate_band;

    if (inputs.soil_mass_megagrams > inputs.positive_soil_mass_threshold_megagrams) {
        return .{
            .ammonium_non_band_water_m3 = ammonium_non_band_water_m3,
            .ammonium_band_water_m3 = ammonium_band_water_m3,
            .nitrate_non_band_water_m3 = nitrate_non_band_water_m3,
            .nitrate_band_water_m3 = nitrate_band_water_m3,
            .phosphate_non_band_water_m3 = phosphate_non_band_water_m3,
            .phosphate_band_water_m3 = phosphate_band_water_m3,
            .whole_layer_normalization_basis = inputs.soil_mass_megagrams,
            .ammonium_non_band_normalization_basis = inputs.soil_mass_megagrams * inputs.fractions.ammonium_non_band,
            .ammonium_band_normalization_basis = inputs.soil_mass_megagrams * inputs.fractions.ammonium_band,
            .nitrate_non_band_normalization_basis = inputs.soil_mass_megagrams * inputs.fractions.nitrate_non_band,
            .nitrate_band_normalization_basis = inputs.soil_mass_megagrams * inputs.fractions.nitrate_band,
            .phosphate_non_band_normalization_basis = inputs.soil_mass_megagrams * inputs.fractions.phosphate_non_band,
            .phosphate_band_normalization_basis = inputs.soil_mass_megagrams * inputs.fractions.phosphate_band,
        };
    }

    return .{
        .ammonium_non_band_water_m3 = ammonium_non_band_water_m3,
        .ammonium_band_water_m3 = ammonium_band_water_m3,
        .nitrate_non_band_water_m3 = nitrate_non_band_water_m3,
        .nitrate_band_water_m3 = nitrate_band_water_m3,
        .phosphate_non_band_water_m3 = phosphate_non_band_water_m3,
        .phosphate_band_water_m3 = phosphate_band_water_m3,
        .whole_layer_normalization_basis = inputs.soil_volume_m3,
        .ammonium_non_band_normalization_basis = ammonium_non_band_water_m3,
        .ammonium_band_normalization_basis = ammonium_band_water_m3,
        .nitrate_non_band_normalization_basis = nitrate_non_band_water_m3,
        .nitrate_band_normalization_basis = nitrate_band_water_m3,
        .phosphate_non_band_normalization_basis = phosphate_non_band_water_m3,
        .phosphate_band_normalization_basis = phosphate_band_water_m3,
    };
}

/// Converts one source normalization basis (`BKVL*`) to its corresponding
/// water-volume ratio. Dry or zero-width zones are inactive in SOLUTE and
/// therefore publish zero rather than inventing a denominator.
pub fn normalizationBasisPerWaterVolume(
    normalization_basis: f64,
    water_volume_m3: f64,
) !f64 {
    if (!std.math.isFinite(normalization_basis) or normalization_basis < 0 or
        !std.math.isFinite(water_volume_m3) or water_volume_m3 < 0)
        return error.InvalidLayerZoneNormalization;
    if (water_volume_m3 == 0) return 0;
    const ratio = normalization_basis / water_volume_m3;
    if (!std.math.isFinite(ratio))
        return error.NonFiniteLayerZoneNormalization;
    return ratio;
}

fn validateLayerZonePreparationInputs(inputs: LayerZonePreparationInputs) !void {
    if (!std.math.isFinite(inputs.water_volume_m3) or inputs.water_volume_m3 < 0 or
        !std.math.isFinite(inputs.soil_mass_megagrams) or inputs.soil_mass_megagrams < 0 or
        !std.math.isFinite(inputs.soil_volume_m3) or inputs.soil_volume_m3 < 0 or
        !std.math.isFinite(inputs.positive_soil_mass_threshold_megagrams) or inputs.positive_soil_mass_threshold_megagrams < 0)
        return error.InvalidLayerZonePreparationInput;
    inline for (@typeInfo(LayerZoneFractions).@"struct".fields) |field| {
        const fraction = @field(inputs.fractions, field.name);
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
            return error.InvalidLayerZoneFraction;
    }
}

pub const UreaInputs = struct {
    broadcast_urea_mol_n: f64,
    banded_urea_mol_n: f64,
    soil_mass_megagrams: f64,
    water_volume_m3: f64,
    biologically_active_water_volume_m3: f64,
    total_microbial_respiration_activity_g_c_per_step: f64,
    temperature_response: f64,
    initial_inhibitor_activity: f64,
    current_inhibitor_activity: f64,
    timestep_h: f64,
};

pub const UreaParameters = struct {
    minimum_half_saturation_mol_n_per_megagram: f64,
    microbial_activity_inhibition_g_c_per_m3_h: f64,
    specific_hydrolysis_mol_n_per_g_c_h: f64,
    inhibitor_decline_rate_per_h: f64,
    negligible_biologically_active_water_m3: f64,
    negligible_inhibitor_activity: f64,
    negligible_fertilizer_amount_mol_n: f64,
    negligible_soil_mass_megagrams: f64,
    negligible_water_volume_m3: f64,
    physical_relative_tolerance: f64,
};

pub const UreaResult = struct {
    broadcast_hydrolysis_mol_n: f64,
    banded_hydrolysis_mol_n: f64,
    effective_half_saturation_mol_n_per_megagram: f64,
    next_inhibitor_activity: f64,
};

pub fn ureaHydrolysis(inputs: UreaInputs, parameters: UreaParameters) !UreaResult {
    try validateUrea(inputs, parameters);
    // Legacy mapping: TOQCK / VOLQ / XNFH in FORTRAN SOLUTE.F.
    const coqck = if (inputs.biologically_active_water_volume_m3 > scaledPhysicalThreshold(
        parameters.negligible_biologically_active_water_m3,
        parameters.physical_relative_tolerance,
        inputs.water_volume_m3,
    ))
        @min(0.1e6, inputs.total_microbial_respiration_activity_g_c_per_step / (inputs.biologically_active_water_volume_m3 * inputs.timestep_h))
    else
        0.1e6;
    const effective_half_saturation = parameters.minimum_half_saturation_mol_n_per_megagram * (1 + coqck / parameters.microbial_activity_inhibition_g_c_per_m3_h);
    var next_inhibitor: f64 = 0;
    const inhibitor_threshold = scaledPhysicalThreshold(parameters.negligible_inhibitor_activity, parameters.physical_relative_tolerance, 1);
    if (inputs.initial_inhibitor_activity > inhibitor_threshold and inputs.current_inhibitor_activity > inhibitor_threshold) {
        const decline_per_step = parameters.inhibitor_decline_rate_per_h * inputs.timestep_h;
        next_inhibitor = inputs.current_inhibitor_activity - decline_per_step * inputs.current_inhibitor_activity * @max(decline_per_step, 1 - inputs.current_inhibitor_activity / inputs.initial_inhibitor_activity);
        if (next_inhibitor < 0 or next_inhibitor > 1) return error.InvalidUreaInhibitorEvolution;
    }
    const specific_hydrolysis = parameters.specific_hydrolysis_mol_n_per_g_c_h * inputs.timestep_h;
    const broadcast_concentration = fertilizerConcentration(inputs.broadcast_urea_mol_n, inputs.soil_mass_megagrams, inputs.water_volume_m3, parameters);
    const banded_concentration = fertilizerConcentration(inputs.banded_urea_mol_n, inputs.soil_mass_megagrams, inputs.water_volume_m3, parameters);
    const broadcast_limitation = broadcast_concentration / (broadcast_concentration + effective_half_saturation);
    const banded_limitation = banded_concentration / (banded_concentration + effective_half_saturation);
    const common_capacity = specific_hydrolysis * inputs.total_microbial_respiration_activity_g_c_per_step * inputs.temperature_response * (1 - next_inhibitor);
    return .{
        .broadcast_hydrolysis_mol_n = @min(inputs.broadcast_urea_mol_n, common_capacity * broadcast_limitation),
        .banded_hydrolysis_mol_n = @min(inputs.banded_urea_mol_n, common_capacity * banded_limitation),
        .effective_half_saturation_mol_n_per_megagram = effective_half_saturation,
        .next_inhibitor_activity = next_inhibitor,
    };
}

pub const FertilizerState = struct {
    broadcast_ammonium_mol_n: f64,
    broadcast_ammonia_mol_n: f64,
    broadcast_urea_mol_n: f64,
    broadcast_nitrate_mol_n: f64,
    banded_ammonium_mol_n: f64,
    banded_ammonia_mol_n: f64,
    banded_urea_mol_n: f64,
    banded_nitrate_mol_n: f64,
};

pub const ZoneFractions = struct { ammonium_non_band: f64, ammonium_band: f64, nitrate_non_band: f64, nitrate_band: f64 };
pub const DissolutionRates = struct { ammonium_per_h: f64, ammonia_per_h: f64, nitrate_per_h: f64 };

pub const DissolutionFlux = struct {
    broadcast_ammonium_non_band_mol_n: f64,
    broadcast_ammonia_non_band_mol_n: f64,
    broadcast_urea_non_band_mol_n: f64,
    broadcast_nitrate_non_band_mol_n: f64,
    broadcast_ammonium_band_mol_n: f64,
    broadcast_ammonia_band_mol_n: f64,
    broadcast_urea_band_mol_n: f64,
    broadcast_nitrate_band_mol_n: f64,
    banded_ammonium_mol_n: f64,
    banded_ammonia_mol_n: f64,
    banded_urea_mol_n: f64,
    banded_nitrate_mol_n: f64,
};

/// Direct source-order translation of SOLUTE.F lines 326--338.
pub fn dissolution(state: FertilizerState, hydrolysis: UreaResult, fractions: ZoneFractions, rates: DissolutionRates, water_content_m3_per_m3: f64, timestep_h: f64) !DissolutionFlux {
    try validateFertilizerState(state);
    inline for (@typeInfo(ZoneFractions).@"struct".fields) |field| if (!std.math.isFinite(@field(fractions, field.name)) or @field(fractions, field.name) < 0 or @field(fractions, field.name) > 1) return error.InvalidFertilizerZoneFraction;
    inline for (@typeInfo(DissolutionRates).@"struct".fields) |field| if (!std.math.isFinite(@field(rates, field.name)) or @field(rates, field.name) < 0) return error.InvalidFertilizerDissolutionRate;
    if (!std.math.isFinite(water_content_m3_per_m3) or water_content_m3_per_m3 < 0 or !std.math.isFinite(timestep_h) or timestep_h <= 0) return error.InvalidFertilizerDissolutionInput;
    const ammonium_rate = rates.ammonium_per_h * timestep_h;
    const ammonia_rate = rates.ammonia_per_h * timestep_h;
    const nitrate_rate = rates.nitrate_per_h * timestep_h;
    const result: DissolutionFlux = .{
        .broadcast_ammonium_non_band_mol_n = ammonium_rate * state.broadcast_ammonium_mol_n * fractions.ammonium_non_band * water_content_m3_per_m3,
        .broadcast_ammonia_non_band_mol_n = ammonia_rate * state.broadcast_ammonia_mol_n * fractions.ammonium_non_band,
        .broadcast_urea_non_band_mol_n = hydrolysis.broadcast_hydrolysis_mol_n * fractions.ammonium_non_band,
        .broadcast_nitrate_non_band_mol_n = nitrate_rate * state.broadcast_nitrate_mol_n * fractions.nitrate_non_band * water_content_m3_per_m3,
        .broadcast_ammonium_band_mol_n = ammonium_rate * state.broadcast_ammonium_mol_n * fractions.ammonium_band * water_content_m3_per_m3,
        .broadcast_ammonia_band_mol_n = ammonia_rate * state.broadcast_ammonia_mol_n * fractions.ammonium_band,
        .broadcast_urea_band_mol_n = hydrolysis.broadcast_hydrolysis_mol_n * fractions.ammonium_band,
        .broadcast_nitrate_band_mol_n = nitrate_rate * state.broadcast_nitrate_mol_n * fractions.nitrate_band * water_content_m3_per_m3,
        .banded_ammonium_mol_n = ammonium_rate * state.banded_ammonium_mol_n * water_content_m3_per_m3,
        .banded_ammonia_mol_n = ammonia_rate * state.banded_ammonia_mol_n,
        .banded_urea_mol_n = hydrolysis.banded_hydrolysis_mol_n * fractions.ammonium_band,
        .banded_nitrate_mol_n = nitrate_rate * state.banded_nitrate_mol_n * water_content_m3_per_m3,
    };
    try validateFluxAgainstState(result, state);
    return result;
}

pub fn state_update(state: *FertilizerState, flux: DissolutionFlux) !void {
    try validateFertilizerState(state.*);
    try validateFluxAgainstState(flux, state.*);
    var next = state.*;
    next.broadcast_ammonium_mol_n -= flux.broadcast_ammonium_non_band_mol_n + flux.broadcast_ammonium_band_mol_n;
    next.broadcast_ammonia_mol_n -= flux.broadcast_ammonia_non_band_mol_n + flux.broadcast_ammonia_band_mol_n;
    next.broadcast_urea_mol_n -= flux.broadcast_urea_non_band_mol_n + flux.broadcast_urea_band_mol_n;
    next.broadcast_nitrate_mol_n -= flux.broadcast_nitrate_non_band_mol_n + flux.broadcast_nitrate_band_mol_n;
    next.banded_ammonium_mol_n -= flux.banded_ammonium_mol_n;
    next.banded_ammonia_mol_n -= flux.banded_ammonia_mol_n;
    next.banded_urea_mol_n -= flux.banded_urea_mol_n;
    next.banded_nitrate_mol_n -= flux.banded_nitrate_mol_n;
    try validateFertilizerState(next);
    state.* = next;
}

/// Publishes the SOLUTE fertilizer recipients atomically. NH3 fertilizer
/// enters soil gas, while hydrolyzed urea enters aqueous NH3.
pub fn state_updateToRecipients(
    state: *FertilizerState,
    aqueous: *aqueous_network.State,
    gaseous_ammonia_g_n: *f64,
    flux: DissolutionFlux,
    fractions: ZoneFractions,
    water_volume_m3: f64,
    nitrogen_molar_mass_g_per_mol: f64,
) !void {
    try validateFertilizerState(state.*);
    try validateFluxAgainstState(flux, state.*);
    if (!std.math.isFinite(water_volume_m3) or water_volume_m3 < 0 or
        !std.math.isFinite(nitrogen_molar_mass_g_per_mol) or
        nitrogen_molar_mass_g_per_mol <= 0 or
        !std.math.isFinite(gaseous_ammonia_g_n.*) or gaseous_ammonia_g_n.* < 0)
        return error.InvalidFertilizerRecipientWaterVolume;
    inline for (@typeInfo(ZoneFractions).@"struct".fields) |field| {
        const fraction = @field(fractions, field.name);
        if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
            return error.InvalidFertilizerZoneFraction;
    }

    const ammonium_non_band_water =
        water_volume_m3 * fractions.ammonium_non_band;
    const ammonium_band_water =
        water_volume_m3 * fractions.ammonium_band;
    const nitrate_non_band_water =
        water_volume_m3 * fractions.nitrate_non_band;
    const nitrate_band_water =
        water_volume_m3 * fractions.nitrate_band;
    try requireRecipientVolume(
        flux.broadcast_ammonium_non_band_mol_n,
        ammonium_non_band_water,
    );
    try requireRecipientVolume(
        flux.broadcast_ammonium_band_mol_n +
            flux.banded_ammonium_mol_n,
        ammonium_band_water,
    );
    try requireRecipientVolume(
        flux.broadcast_urea_non_band_mol_n,
        ammonium_non_band_water,
    );
    try requireRecipientVolume(
        flux.broadcast_urea_band_mol_n +
            flux.banded_urea_mol_n,
        ammonium_band_water,
    );
    try requireRecipientVolume(
        flux.broadcast_nitrate_non_band_mol_n,
        nitrate_non_band_water,
    );
    try requireRecipientVolume(
        flux.broadcast_nitrate_band_mol_n +
            flux.banded_nitrate_mol_n,
        nitrate_band_water,
    );

    var next_state = state.*;
    var next_aqueous = aqueous.*;
    var next_gaseous_ammonia_g_n = gaseous_ammonia_g_n.*;
    try state_update(&next_state, flux);
    next_aqueous.ammonium_non_band +=
        flux.broadcast_ammonium_non_band_mol_n /
        nonzeroOrOne(ammonium_non_band_water);
    next_aqueous.ammonium_band +=
        (flux.broadcast_ammonium_band_mol_n +
            flux.banded_ammonium_mol_n) /
        nonzeroOrOne(ammonium_band_water);
    next_aqueous.ammonia_non_band +=
        flux.broadcast_urea_non_band_mol_n /
        nonzeroOrOne(ammonium_non_band_water);
    next_aqueous.ammonia_band +=
        (flux.broadcast_urea_band_mol_n +
            flux.banded_urea_mol_n) /
        nonzeroOrOne(ammonium_band_water);
    next_gaseous_ammonia_g_n +=
        (flux.broadcast_ammonia_non_band_mol_n +
            flux.broadcast_ammonia_band_mol_n +
            flux.banded_ammonia_mol_n) *
        nitrogen_molar_mass_g_per_mol;
    next_aqueous.nitrate_non_band +=
        flux.broadcast_nitrate_non_band_mol_n /
        nonzeroOrOne(nitrate_non_band_water);
    next_aqueous.nitrate_band +=
        (flux.broadcast_nitrate_band_mol_n +
            flux.banded_nitrate_mol_n) /
        nonzeroOrOne(nitrate_band_water);
    inline for (@typeInfo(aqueous_network.State).@"struct".fields) |field| {
        const value = @field(next_aqueous, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidFertilizerRecipientAqueousState;
    }
    if (!std.math.isFinite(next_gaseous_ammonia_g_n) or
        next_gaseous_ammonia_g_n < 0)
        return error.InvalidFertilizerRecipientGasState;
    state.* = next_state;
    aqueous.* = next_aqueous;
    gaseous_ammonia_g_n.* = next_gaseous_ammonia_g_n;
}

fn requireRecipientVolume(amount_mol_n: f64, volume_m3: f64) !void {
    if (amount_mol_n > 0 and volume_m3 <= 0)
        return error.MissingFertilizerRecipientWaterVolume;
}

fn nonzeroOrOne(value: f64) f64 {
    return if (value > 0) value else 1;
}

fn fertilizerConcentration(amount_mol_n: f64, soil_mass_megagrams: f64, water_volume_m3: f64, parameters: UreaParameters) f64 {
    const amount_threshold = scaledPhysicalThreshold(parameters.negligible_fertilizer_amount_mol_n, parameters.physical_relative_tolerance, amount_mol_n);
    const soil_mass_threshold = scaledPhysicalThreshold(parameters.negligible_soil_mass_megagrams, parameters.physical_relative_tolerance, soil_mass_megagrams);
    const water_threshold = scaledPhysicalThreshold(parameters.negligible_water_volume_m3, parameters.physical_relative_tolerance, water_volume_m3);
    if (amount_mol_n > amount_threshold and soil_mass_megagrams > soil_mass_threshold) return amount_mol_n / soil_mass_megagrams;
    if (water_volume_m3 > water_threshold) return amount_mol_n / water_volume_m3;
    return 0;
}

fn scaledPhysicalThreshold(absolute: f64, relative: f64, representative_scale: f64) f64 {
    return absolute + relative * @abs(representative_scale);
}

fn validateUrea(inputs: UreaInputs, parameters: UreaParameters) !void {
    inline for (@typeInfo(UreaInputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name)) or @field(inputs, field.name) < 0) return error.InvalidUreaHydrolysisInput;
    inline for (@typeInfo(UreaParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name)) or @field(parameters, field.name) < 0) return error.InvalidUreaHydrolysisParameter;
    if (parameters.physical_relative_tolerance >= 1) return error.InvalidUreaHydrolysisParameter;
    if (inputs.current_inhibitor_activity > 1 or inputs.timestep_h <= 0 or parameters.minimum_half_saturation_mol_n_per_megagram <= 0 or parameters.microbial_activity_inhibition_g_c_per_m3_h <= 0) return error.InvalidUreaHydrolysisInput;
}

fn validateFertilizerState(state: FertilizerState) !void {
    inline for (@typeInfo(FertilizerState).@"struct".fields) |field| if (!std.math.isFinite(@field(state, field.name)) or @field(state, field.name) < 0) return error.InvalidFertilizerState;
}

fn validateFluxAgainstState(flux: DissolutionFlux, state: FertilizerState) !void {
    inline for (@typeInfo(DissolutionFlux).@"struct".fields) |field| if (!std.math.isFinite(@field(flux, field.name)) or @field(flux, field.name) < 0) return error.InvalidFertilizerDissolutionFlux;
    if (flux.broadcast_ammonium_non_band_mol_n + flux.broadcast_ammonium_band_mol_n > state.broadcast_ammonium_mol_n or flux.broadcast_ammonia_non_band_mol_n + flux.broadcast_ammonia_band_mol_n > state.broadcast_ammonia_mol_n or flux.broadcast_urea_non_band_mol_n + flux.broadcast_urea_band_mol_n > state.broadcast_urea_mol_n or flux.broadcast_nitrate_non_band_mol_n + flux.broadcast_nitrate_band_mol_n > state.broadcast_nitrate_mol_n or flux.banded_ammonium_mol_n > state.banded_ammonium_mol_n or flux.banded_ammonia_mol_n > state.banded_ammonia_mol_n or flux.banded_urea_mol_n > state.banded_urea_mol_n or flux.banded_nitrate_mol_n > state.banded_nitrate_mol_n) return error.FertilizerDissolutionExceedsPool;
}

test "urea hydrolysis and fertilizer dissolution conserve fertilizer nitrogen" {
    var state: FertilizerState = .{ .broadcast_ammonium_mol_n = 1, .broadcast_ammonia_mol_n = 1, .broadcast_urea_mol_n = 1, .broadcast_nitrate_mol_n = 1, .banded_ammonium_mol_n = 1, .banded_ammonia_mol_n = 1, .banded_urea_mol_n = 1, .banded_nitrate_mol_n = 1 };
    const hydrolysis = try ureaHydrolysis(.{ .broadcast_urea_mol_n = 1, .banded_urea_mol_n = 1, .soil_mass_megagrams = 1, .water_volume_m3 = 1, .biologically_active_water_volume_m3 = 1, .total_microbial_respiration_activity_g_c_per_step = 0.1, .temperature_response = 1, .initial_inhibitor_activity = 1, .current_inhibitor_activity = 0.5, .timestep_h = 1 }, .{ .minimum_half_saturation_mol_n_per_megagram = 0.05, .microbial_activity_inhibition_g_c_per_m3_h = 50, .specific_hydrolysis_mol_n_per_g_c_h = 0.03, .inhibitor_decline_rate_per_h = 0.01, .negligible_biologically_active_water_m3 = 1e-12, .negligible_inhibitor_activity = 1e-12, .negligible_fertilizer_amount_mol_n = 1e-12, .negligible_soil_mass_megagrams = 1e-12, .negligible_water_volume_m3 = 1e-12, .physical_relative_tolerance = 1e-12 });
    const flux = try dissolution(state, hydrolysis, .{ .ammonium_non_band = 0.7, .ammonium_band = 0.3, .nitrate_non_band = 0.6, .nitrate_band = 0.4 }, .{ .ammonium_per_h = 0.1, .ammonia_per_h = 0.1, .nitrate_per_h = 0.1 }, 0.5, 1);
    const before = sumState(state);
    const dissolved = sumFlux(flux);
    try state_update(&state, flux);
    try std.testing.expectApproxEqAbs(before, sumState(state) + dissolved, 1e-13);
}

test "urea concentration presence thresholds retain their physical units" {
    var parameters: UreaParameters = .{
        .minimum_half_saturation_mol_n_per_megagram = 1,
        .microbial_activity_inhibition_g_c_per_m3_h = 1,
        .specific_hydrolysis_mol_n_per_g_c_h = 1,
        .inhibitor_decline_rate_per_h = 0,
        .negligible_biologically_active_water_m3 = 1e-12,
        .negligible_inhibitor_activity = 1e-12,
        .negligible_fertilizer_amount_mol_n = 1e-12,
        .negligible_soil_mass_megagrams = 1e-12,
        .negligible_water_volume_m3 = 1e-12,
        .physical_relative_tolerance = 1e-12,
    };
    try std.testing.expectEqual(@as(f64, 0.5), fertilizerConcentration(2, 4, 8, parameters));
    parameters.negligible_soil_mass_megagrams = 5;
    try std.testing.expectEqual(@as(f64, 0.25), fertilizerConcentration(2, 4, 8, parameters));
    parameters.negligible_fertilizer_amount_mol_n = 3;
    parameters.negligible_water_volume_m3 = 9;
    try std.testing.expectEqual(@as(f64, 0), fertilizerConcentration(2, 4, 8, parameters));
}

test "fertilizer state rejects any negative pool without clipping" {
    var state: FertilizerState = .{ .broadcast_ammonium_mol_n = -1e-30, .broadcast_ammonia_mol_n = 0, .broadcast_urea_mol_n = 0, .broadcast_nitrate_mol_n = 0, .banded_ammonium_mol_n = 0, .banded_ammonia_mol_n = 0, .banded_urea_mol_n = 0, .banded_nitrate_mol_n = 0 };
    const unchanged = state;
    try std.testing.expectError(error.InvalidFertilizerState, state_update(&state, std.mem.zeroes(DissolutionFlux)));
    try std.testing.expectEqualDeep(unchanged, state);
}

test "SOLUTE fertilizer state_update conserves nitrogen and is transactional" {
    var state: FertilizerState = .{
        .broadcast_ammonium_mol_n = 1,
        .broadcast_ammonia_mol_n = 2,
        .broadcast_urea_mol_n = 3,
        .broadcast_nitrate_mol_n = 4,
        .banded_ammonium_mol_n = 5,
        .banded_ammonia_mol_n = 6,
        .banded_urea_mol_n = 7,
        .banded_nitrate_mol_n = 8,
    };
    var aqueous = std.mem.zeroes(aqueous_network.State);
    const fractions: ZoneFractions = .{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
    };
    const flux: DissolutionFlux = .{
        .broadcast_ammonium_non_band_mol_n = 0.1,
        .broadcast_ammonium_band_mol_n = 0.2,
        .broadcast_ammonia_non_band_mol_n = 0.3,
        .broadcast_ammonia_band_mol_n = 0.4,
        .broadcast_urea_non_band_mol_n = 0.5,
        .broadcast_urea_band_mol_n = 0.6,
        .broadcast_nitrate_non_band_mol_n = 0.7,
        .broadcast_nitrate_band_mol_n = 0.8,
        .banded_ammonium_mol_n = 0.9,
        .banded_ammonia_mol_n = 1,
        .banded_urea_mol_n = 1.1,
        .banded_nitrate_mol_n = 1.2,
    };
    const before = sumState(state);
    var gaseous_ammonia_g_n: f64 = 0;
    try state_updateToRecipients(&state, &aqueous, &gaseous_ammonia_g_n, flux, fractions, 2, 14);
    const aqueous_n =
        aqueous.ammonium_non_band * 1.5 +
        aqueous.ammonium_band * 0.5 +
        aqueous.ammonia_non_band * 1.5 +
        aqueous.ammonia_band * 0.5 +
        aqueous.nitrate_non_band * 1.2 +
        aqueous.nitrate_band * 0.8;
    try std.testing.expectApproxEqAbs(
        before,
        sumState(state) + aqueous_n + gaseous_ammonia_g_n / 14,
        1e-13,
    );

    const donor_before_failure = state;
    const aqueous_before_failure = aqueous;
    const gaseous_before_failure = gaseous_ammonia_g_n;
    var invalid_flux = std.mem.zeroes(DissolutionFlux);
    invalid_flux.banded_ammonium_mol_n = 0.1;
    try std.testing.expectError(
        error.MissingFertilizerRecipientWaterVolume,
        state_updateToRecipients(
            &state,
            &aqueous,
            &gaseous_ammonia_g_n,
            invalid_flux,
            .{
                .ammonium_non_band = 1,
                .ammonium_band = 0,
                .nitrate_non_band = 1,
                .nitrate_band = 0,
            },
            2,
            14,
        ),
    );
    try std.testing.expectEqual(donor_before_failure, state);
    try std.testing.expectEqual(aqueous_before_failure, aqueous);
    try std.testing.expectEqual(gaseous_before_failure, gaseous_ammonia_g_n);
}

fn sumState(state: FertilizerState) f64 {
    var total: f64 = 0;
    inline for (@typeInfo(FertilizerState).@"struct".fields) |field| total += @field(state, field.name);
    return total;
}

fn sumFlux(flux: DissolutionFlux) f64 {
    var total: f64 = 0;
    inline for (@typeInfo(DissolutionFlux).@"struct".fields) |field| total += @field(flux, field.name);
    return total;
}

test {
    _ = @import("fertilizer_dissolution_test.zig");
}

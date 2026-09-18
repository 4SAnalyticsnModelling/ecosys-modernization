const std = @import("std");

/// WATSUB surface litter freeze-thaw, `watsub.f` lines 3145--3161.
///
/// The oracle is **energy-led**: the latent heat exchanged in a substep is
/// whatever the temperature deficit relative to the depressed freezing point can
/// drive, and the mass that changes phase is then *derived* by dividing that
/// energy by the latent heat of fusion. The available liquid or ice acts only as
/// a cap:
///
///     TFREEZ = -9.0959E+04/(PSISVR-333.0)
///     IF((TKR2.LT.TFREEZ .AND. VOLW2(0).GT.ZERO*VOLT(0))
///    .OR.(TKR2.GT.TFREEZ .AND. VOLI2(0).GT.ZERO*VOLT(0))) THEN
///     HFLFRX = VHCPR2*(TFREEZ-TKR2)*XNPR/(1.0+6.2913E-03*TFREEZ)
///     IF(HFLFRX.LT.0.0) HFLFR2 = AMAX1(-333.0*DENSI*VOLI2(0)*XNPRX, HFLFRX)
///     ELSE              HFLFR2 = AMIN1( 333.0*VOLW2(0)*XNPRX,       HFLFRX)
///     FLFR2 = -HFLFR2/333.0
///
/// Two properties are easy to lose and are pinned by the tests below:
///
///  1. The whole branch is **gated on the sign of the temperature deficit**. A
///     surface that is above the freezing point freezes nothing this substep; it
///     simply cools. Solving instead for a phase equilibrium at a below-freezing
///     root lets an entire reservoir freeze in one step, which measured 19.17x
///     the energy-permitted amount in the Ottawa example. See EXEC-002.
///  2. `333 * available` is a **cap, not the expected value**. Producing the cap
///     is the signature of a mass-led formulation.
///
/// Sign convention follows the source: `HFLFR2 > 0` is freezing, which releases
/// latent heat, and the derived water change `FLFR2 = -HFLFR2/333` is then
/// negative, i.e. liquid decreases.
pub const Parameters = struct {
    /// `333.0`, latent heat of fusion in MJ per m3 of liquid water.
    latent_heat_of_fusion_megajoules_per_m3: f64,
    /// `9.0959E+04`, freezing point depression numerator.
    freezing_point_depression_numerator: f64,
    /// `6.2913E-03`, the temperature correction in the `HFLFRX` denominator.
    freezing_temperature_coefficient: f64,
    pub const source: Parameters = .{
        .latent_heat_of_fusion_megajoules_per_m3 = 333.0,
        .freezing_point_depression_numerator = 9.0959e4,
        .freezing_temperature_coefficient = 6.2913e-3,
    };
};

pub const Inputs = struct {
    /// `TKR2`, surface temperature at the start of the substep, in kelvin.
    temperature_k: f64,
    /// `VHCPR2`, surface volumetric heat capacity in MJ per K.
    heat_capacity_megajoules_per_k: f64,
    /// `VOLW2(0)`, liquid water available to freeze, in m3.
    liquid_water_m3: f64,
    /// `VOLI2(0)`, ice available to thaw, as a water-equivalent volume in m3.
    ice_water_equivalent_m3: f64,
    /// `PSISVR = PSISM1(0) + PSISO(0)`, total surface water potential in MPa.
    /// Depresses the freezing point below the pure-water value.
    water_potential_megapascal: f64,
    /// `XNPR`, the substep fraction applied to the energy-limited flux.
    substep_energy_fraction: f64,
    /// `XNPRX`, the substep fraction applied to the mass cap. The source keeps
    /// these separate, so they are not merged here.
    substep_mass_fraction: f64,
    /// `ZERO*VOLT(0)`, the negligible-volume threshold below which a phase is
    /// treated as absent.
    negligible_volume_m3: f64,
};

pub const Result = struct {
    /// `HFLFR2`, latent heat exchanged in MJ. Positive is freezing, which
    /// releases heat; negative is thawing, which absorbs it.
    latent_heat_megajoules: f64,
    /// `FLFR2`, the derived change in liquid water in m3. Negative when
    /// freezing. Ice changes by the negation of this, in water equivalent.
    liquid_water_change_m3: f64,
    /// `TFREEZ`, the depressed freezing point in kelvin, reported so callers and
    /// tests can see which side of it the surface sits on.
    depressed_freezing_point_k: f64,
    /// True when the mass cap bound instead of the energy limit. Useful as a
    /// diagnostic: routinely hitting the cap suggests the caller is supplying a
    /// substep that is too long.
    mass_capped: bool,
};

/// Evaluates one substep of surface freeze-thaw.
pub fn apply(inputs: Inputs, parameters: Parameters) !Result {
    inline for (.{
        inputs.temperature_k,
        inputs.heat_capacity_megajoules_per_k,
        inputs.liquid_water_m3,
        inputs.ice_water_equivalent_m3,
        inputs.water_potential_megapascal,
        inputs.substep_energy_fraction,
        inputs.substep_mass_fraction,
        inputs.negligible_volume_m3,
    }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSurfaceFreezeThawInput;
    if (inputs.temperature_k <= 0 or
        inputs.heat_capacity_megajoules_per_k <= 0 or
        inputs.liquid_water_m3 < 0 or
        inputs.ice_water_equivalent_m3 < 0 or
        inputs.negligible_volume_m3 < 0 or
        inputs.substep_energy_fraction <= 0 or inputs.substep_energy_fraction > 1 or
        inputs.substep_mass_fraction <= 0 or inputs.substep_mass_fraction > 1)
        return error.InvalidSurfaceFreezeThawInput;
    const latent = parameters.latent_heat_of_fusion_megajoules_per_m3;
    if (!std.math.isFinite(latent) or latent <= 0) return error.InvalidSurfaceFreezeThawParameter;

    // `TFREEZ = -9.0959E+04/(PSISVR-333.0)`. At zero water potential this is the
    // pure-water freezing point; more negative potentials depress it.
    const denominator = inputs.water_potential_megapascal - latent;
    if (!std.math.isFinite(denominator) or denominator == 0)
        return error.InvalidSurfaceFreezingPointDepression;
    const depressed_freezing_point_k =
        -parameters.freezing_point_depression_numerator / denominator;
    if (!std.math.isFinite(depressed_freezing_point_k) or depressed_freezing_point_k <= 0)
        return error.InvalidSurfaceFreezingPointDepression;

    const deficit_k = depressed_freezing_point_k - inputs.temperature_k;
    const freezing = deficit_k > 0 and inputs.liquid_water_m3 > inputs.negligible_volume_m3;
    const thawing = deficit_k < 0 and inputs.ice_water_equivalent_m3 > inputs.negligible_volume_m3;
    if (!freezing and !thawing) return .{
        .latent_heat_megajoules = 0,
        .liquid_water_change_m3 = 0,
        .depressed_freezing_point_k = depressed_freezing_point_k,
        .mass_capped = false,
    };

    // `HFLFRX = VHCPR2*(TFREEZ-TKR2)*XNPR/(1.0+6.2913E-03*TFREEZ)`.
    // WATSUB carries both TFREEZ and TKR2 in kelvin and uses TFREEZ directly.
    const correction = 1.0 + parameters.freezing_temperature_coefficient *
        depressed_freezing_point_k;
    if (!std.math.isFinite(correction) or correction <= 0)
        return error.InvalidSurfaceFreezeThawCorrection;
    const energy_limited_megajoules = inputs.heat_capacity_megajoules_per_k *
        deficit_k * inputs.substep_energy_fraction / correction;
    if (!std.math.isFinite(energy_limited_megajoules))
        return error.NonFiniteSurfaceFreezeThawFlux;

    // The modern ice carrier is already liquid-water equivalent. The source's
    // `DENSI*VOLI` converts physical VOLI to this carrier, so applying density
    // again here would under-value available thaw mass.
    var latent_heat_megajoules = energy_limited_megajoules;
    var mass_capped = false;
    if (energy_limited_megajoules < 0) {
        const cap = -latent * inputs.ice_water_equivalent_m3 * inputs.substep_mass_fraction;
        if (energy_limited_megajoules < cap) {
            latent_heat_megajoules = cap;
            mass_capped = true;
        }
    } else {
        const cap = latent * inputs.liquid_water_m3 * inputs.substep_mass_fraction;
        if (energy_limited_megajoules > cap) {
            latent_heat_megajoules = cap;
            mass_capped = true;
        }
    }

    const liquid_water_change_m3 = -latent_heat_megajoules / latent;
    inline for (.{ latent_heat_megajoules, liquid_water_change_m3 }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSurfaceFreezeThawFlux;
    return .{
        .latent_heat_megajoules = latent_heat_megajoules,
        .liquid_water_change_m3 = liquid_water_change_m3,
        .depressed_freezing_point_k = depressed_freezing_point_k,
        .mass_capped = mass_capped,
    };
}

const test_inputs: Inputs = .{
    .temperature_k = 270,
    .heat_capacity_megajoules_per_k = 1000,
    .liquid_water_m3 = 100,
    .ice_water_equivalent_m3 = 100,
    .water_potential_megapascal = 0,
    .substep_energy_fraction = 1,
    .substep_mass_fraction = 1,
    .negligible_volume_m3 = 1e-9,
};

test "an above-freezing surface freezes nothing" {
    // This is the property the mass-led equilibrium formulation violated: it
    // solved for a below-freezing root and froze an entire reservoir in one step
    // even though the surface started above the freezing point.
    var inputs = test_inputs;
    inputs.temperature_k = 277.145;
    inputs.ice_water_equivalent_m3 = 0;
    const result = try apply(inputs, Parameters.source);
    try std.testing.expectEqual(@as(f64, 0), result.latent_heat_megajoules);
    try std.testing.expectEqual(@as(f64, 0), result.liquid_water_change_m3);
    try std.testing.expect(!result.mass_capped);
    // The surface really is above the depressed freezing point.
    try std.testing.expect(inputs.temperature_k > result.depressed_freezing_point_k);
}

test "freezing is limited by the energy the temperature deficit supports" {
    const result = try apply(test_inputs, Parameters.source);
    const freezing_point = result.depressed_freezing_point_k;
    const deficit = freezing_point - 270.0;
    const correction = 1.0 + 6.2913e-3 * freezing_point;
    try std.testing.expectApproxEqRel(
        1000.0 * deficit / correction,
        result.latent_heat_megajoules,
        1e-13,
    );
    // Freezing releases heat, so the sign is positive and liquid decreases.
    try std.testing.expect(result.latent_heat_megajoules > 0);
    try std.testing.expect(result.liquid_water_change_m3 < 0);
    // Mass is DERIVED from energy, not the other way round.
    try std.testing.expectApproxEqRel(
        -result.latent_heat_megajoules / 333.0,
        result.liquid_water_change_m3,
        1e-14,
    );
    // With ample liquid the energy limit binds, not the cap.
    try std.testing.expect(!result.mass_capped);
}

test "the available liquid acts only as a cap" {
    // Deep freezing with very little liquid: the cap binds and the result is
    // exactly the whole remaining liquid, no more.
    var inputs = test_inputs;
    inputs.temperature_k = 200;
    inputs.liquid_water_m3 = 0.5;
    const result = try apply(inputs, Parameters.source);
    try std.testing.expect(result.mass_capped);
    try std.testing.expectApproxEqRel(333.0 * 0.5, result.latent_heat_megajoules, 1e-14);
    try std.testing.expectApproxEqRel(@as(f64, -0.5), result.liquid_water_change_m3, 1e-14);
}

test "thawing absorbs heat and is limited by available ice" {
    var inputs = test_inputs;
    inputs.temperature_k = 280;
    inputs.liquid_water_m3 = 0;
    const result = try apply(inputs, Parameters.source);
    // Above freezing with ice present: thawing, which absorbs heat.
    try std.testing.expect(result.latent_heat_megajoules < 0);
    try std.testing.expect(result.liquid_water_change_m3 > 0);
    // Deep thaw against little WE ice hits the WE mass cap.
    var capped = inputs;
    capped.temperature_k = 400;
    capped.ice_water_equivalent_m3 = 0.25;
    const capped_result = try apply(capped, Parameters.source);
    try std.testing.expect(capped_result.mass_capped);
    try std.testing.expectApproxEqRel(
        -333.0 * 0.25,
        capped_result.latent_heat_megajoules,
        1e-14,
    );
}

test "a phase below the negligible volume threshold does not change" {
    var inputs = test_inputs;
    inputs.liquid_water_m3 = 1e-12;
    inputs.ice_water_equivalent_m3 = 0;
    inputs.negligible_volume_m3 = 1e-9;
    const result = try apply(inputs, Parameters.source);
    try std.testing.expectEqual(@as(f64, 0), result.latent_heat_megajoules);
}

test "substep fractions scale the energy limit" {
    var half = test_inputs;
    half.substep_energy_fraction = 0.5;
    const full_result = try apply(test_inputs, Parameters.source);
    const half_result = try apply(half, Parameters.source);
    try std.testing.expectApproxEqRel(
        full_result.latent_heat_megajoules * 0.5,
        half_result.latent_heat_megajoules,
        1e-14,
    );
}

test "a more negative water potential depresses the freezing point" {
    var saline = test_inputs;
    saline.water_potential_megapascal = -5;
    const fresh_result = try apply(test_inputs, Parameters.source);
    const saline_result = try apply(saline, Parameters.source);
    try std.testing.expect(
        saline_result.depressed_freezing_point_k < fresh_result.depressed_freezing_point_k,
    );
    // At zero potential the source formula gives the pure-water value.
    try std.testing.expectApproxEqRel(
        @as(f64, 9.0959e4 / 333.0),
        fresh_result.depressed_freezing_point_k,
        1e-13,
    );
}

test "invalid inputs are rejected" {
    var not_finite = test_inputs;
    not_finite.temperature_k = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteSurfaceFreezeThawInput, apply(not_finite, Parameters.source));
    var negative = test_inputs;
    negative.liquid_water_m3 = -1;
    try std.testing.expectError(error.InvalidSurfaceFreezeThawInput, apply(negative, Parameters.source));
    var zero_capacity = test_inputs;
    zero_capacity.heat_capacity_megajoules_per_k = 0;
    try std.testing.expectError(error.InvalidSurfaceFreezeThawInput, apply(zero_capacity, Parameters.source));
    var bad_fraction = test_inputs;
    bad_fraction.substep_energy_fraction = 1.5;
    try std.testing.expectError(error.InvalidSurfaceFreezeThawInput, apply(bad_fraction, Parameters.source));
}

test "reproduces the measured Ottawa hour-2 divergence" {
    // The state measured before the freeze: 6.973601907996609e4 m3 of litter
    // water at 277.14506556198114 K with a heat capacity of 4.19 x that volume.
    // Production froze 6.719838181924305e4 m3, releasing 2.2377061145807937e7 MJ.
    // The oracle's rule freezes nothing, because the surface is above freezing.
    const liquid_m3 = 6.973601907996609e4;
    const result = try apply(.{
        .temperature_k = 2.7714506556198114e2,
        .heat_capacity_megajoules_per_k = 4.19 * liquid_m3,
        .liquid_water_m3 = liquid_m3,
        .ice_water_equivalent_m3 = 0,
        .water_potential_megapascal = 0,
        .substep_energy_fraction = 1,
        .substep_mass_fraction = 1,
        .negligible_volume_m3 = 1e-9,
    }, Parameters.source);
    try std.testing.expectEqual(@as(f64, 0), result.latent_heat_megajoules);
    // Had the surface been just below freezing, the energy limit would still cap
    // the release far below the 2.2377e7 MJ production produced.
    const just_below = try apply(.{
        .temperature_k = result.depressed_freezing_point_k - 4.0,
        .heat_capacity_megajoules_per_k = 4.19 * liquid_m3,
        .liquid_water_m3 = liquid_m3,
        .ice_water_equivalent_m3 = 0,
        .water_potential_megapascal = 0,
        .substep_energy_fraction = 1,
        .substep_mass_fraction = 1,
        .negligible_volume_m3 = 1e-9,
    }, Parameters.source);
    try std.testing.expect(just_below.latent_heat_megajoules > 0);
    try std.testing.expect(just_below.latent_heat_megajoules < 2.2377061145807937e7 / 10.0);
}

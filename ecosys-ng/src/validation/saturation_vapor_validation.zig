//! Tier-1 physical-domain evidence for the saturation vapour-pressure
//! correlation, the third guard P3 names alongside retention and Henry.
//!
//! `docs/validation.md` ranks "dimensional consistency and valid physical
//! domains" first. P3 records that the tree had ONE tier-1 domain guard
//! (`soil_water_retention_validation.zig`) and asks for e_sat, retention and
//! Henry ceilings. Henry landed as `henry_solubility_validation.zig`; this is
//! e_sat, and it is the one with a live defect behind it.
//!
//! Why this correlation specifically. The ET investigation recorded a genuine
//! domain violation independent of any legacy comparison: at hour 2077 the
//! model evaporated into 1.543 kPa while its warmest surface state was
//! 3.74 degC, whose saturation pressure is about 0.795 kPa. That is a state no
//! amount of oracle agreement excuses -- vapour pressure above saturation at
//! the surface temperature is thermodynamically impossible. Driving the
//! production correlation and checking its own domain is the check that would
//! have caught it.
//!
//! What makes this oracle-independent. The reference is the **Magnus**
//! formula, `0.6112 * exp(17.62 T / (243.12 + T))` with T in degrees Celsius,
//! which is published physics and not the Fortran. Agreement with it is
//! evidence at validation-hierarchy level 5 (observations and published
//! benchmarks), which outranks level 8 legacy matching. Disagreement would be a
//! finding about the model, not about the translation.
//!
//! The production entry point is driven, not restated:
//! `ground_air_exchange.surfaceVaporFractionWithKelvinSuppression` carries the
//! whole expression including the Kelvin suppression factor.

const std = @import("std");
const ground_air = @import("../surface/ground_air_exchange.zig");

/// Published Magnus coefficients over water. Stated here as the independent
/// reference; this module must never be "corrected" toward the model.
pub const magnus_reference_kpa: f64 = 0.6112;
pub const magnus_numerator_per_c: f64 = 17.62;
pub const magnus_denominator_c: f64 = 243.12;

/// Saturation vapour pressure from published physics, in kilopascal.
pub fn magnusSaturationKpa(temperature_c: f64) !f64 {
    if (!std.math.isFinite(temperature_c) or temperature_c <= -magnus_denominator_c)
        return error.InvalidMagnusTemperature;
    return magnus_reference_kpa *
        @exp(magnus_numerator_per_c * temperature_c / (magnus_denominator_c + temperature_c));
}

/// Measured agreement between the production correlation and Magnus,
/// 2026-09-12. These are the numbers the tests below bound, recorded so a
/// future change to the runtime parameters is visible as a shift here rather
/// than as a mysteriously widened tolerance.
///
/// | degC | model kPa | Magnus kPa | relative |
/// | ---: | ---: | ---: | ---: |
/// | -20 | 0.129438 | 0.125965 | 2.76% |
/// | -10 | 0.289399 | 0.287031 | 0.83% |
/// |   0 | 0.610026 | 0.611200 | 0.19% |
/// | 3.74 | 0.795166 | 0.798210 | 0.38% |
/// |  10 | 1.219899 | 1.226030 | 0.50% |
/// |  20 | 2.326835 | 2.332596 | 0.25% |
/// |  30 | 4.253098 | 4.233724 | 0.46% |
/// |  40 | 7.480247 | 7.367458 | 1.53% |
///
/// Tightest over the temperate band and loosest at the cold and hot ends,
/// which is the expected behaviour of a two-parameter Clausius-Clapeyron fit
/// against a three-parameter Magnus fit.
pub const temperate_band_tolerance: f64 = 0.010;
pub const extended_band_tolerance: f64 = 0.035;

/// `ground_air.Parameters` declares no field defaults, so a complete literal is
/// required. These are the production values: the four saturation coefficients
/// are what `runscript.zig:955-958` parses for the Ottawa deck and what
/// `coupled_convergence.zig:848-850` and `ground_air_exchange.zig:1110` both
/// carry, and the remaining fields are this correlation's irrelevant
/// neighbours -- `surfaceVaporFractionWithKelvinSuppression` reads only the
/// four plus nothing else, which `validateParameters` nonetheless requires to
/// be present and admissible.
pub const production_parameters: ground_air.Parameters = .{
    .minimum_richardson_number = -0.1,
    .maximum_richardson_number = 0.05,
    .richardson_resistance_multiplier = 10,
    .minimum_aerodynamic_resistance_h_per_m = 0.00139,
    .maximum_aerodynamic_resistance_h_per_m = 0.0139,
    .volumetric_air_heat_capacity_megajoules_per_m3_k = 1.25e-3,
    .minimum_air_column_height_m = 5,
    .sensible_heat_conductivity_megajoules_per_m_h_k = 1.2e-3,
    .liquid_water_latent_heat_megajoules_per_m3 = 2465,
    .saturation_vapor_prefactor_k = 2.173e-3,
    .saturation_relative_humidity = 0.61,
    .saturation_temperature_k = 5360,
    .saturation_reference_inverse_temperature_per_k = 3.661e-3,
    .sublimation_latent_heat_megajoules_per_m3 = 2834,
    .pure_water_freezing_temperature_k = 273.15,
};
pub const DomainReport = struct {
    lowest_kpa: f64,
    highest_kpa: f64,
    worst_relative_disagreement: f64,
    worst_disagreement_temperature_c: f64,
    strictly_increasing: bool,
    samples: usize,
};

/// The production correlation expressed as a pressure, so it can be compared
/// with Magnus.
///
/// `surfaceVaporFractionWithKelvinSuppression` returns a volume FRACTION, and
/// `vaporPressureKpa` is the model's own inverse conversion, so composing them
/// keeps every coefficient inside production code. Unit activity and zero
/// water potential select the unsuppressed saturation value.
pub fn productionSaturationKpa(temperature_c: f64, parameters: ground_air.Parameters) !f64 {
    const temperature_k = temperature_c + 273.15;
    const fraction = try ground_air.surfaceVaporFractionWithKelvinSuppression(
        temperature_k,
        0,
        1,
        parameters,
    );
    return ground_air.vaporPressureKpa(fraction, temperature_k, parameters);
}

/// Tier 1: over the sampled range the saturation pressure must be finite and
/// strictly positive, must RISE with temperature, and must agree with
/// published physics. A saturation pressure that fell as air warmed would be
/// thermodynamically backwards whatever any oracle says.
pub fn saturationDomain(
    lowest_temperature_c: f64,
    highest_temperature_c: f64,
    sample_count: usize,
    parameters: ground_air.Parameters,
) !DomainReport {
    if (!std.math.isFinite(lowest_temperature_c) or !std.math.isFinite(highest_temperature_c) or
        lowest_temperature_c >= highest_temperature_c or sample_count < 2)
        return error.InvalidSaturationDomainRange;
    if (lowest_temperature_c <= -magnus_denominator_c)
        return error.InvalidSaturationDomainRange;

    var report: DomainReport = .{
        .lowest_kpa = std.math.inf(f64),
        .highest_kpa = 0,
        .worst_relative_disagreement = 0,
        .worst_disagreement_temperature_c = lowest_temperature_c,
        .strictly_increasing = true,
        .samples = sample_count,
    };
    var previous: ?f64 = null;
    for (0..sample_count) |index| {
        const fraction_of_range = @as(f64, @floatFromInt(index)) /
            @as(f64, @floatFromInt(sample_count - 1));
        const temperature_c = lowest_temperature_c +
            fraction_of_range * (highest_temperature_c - lowest_temperature_c);
        const produced = try productionSaturationKpa(temperature_c, parameters);
        if (!std.math.isFinite(produced)) return error.NonFiniteSaturationPressure;
        if (produced <= 0) return error.NonPositiveSaturationPressure;
        report.lowest_kpa = @min(report.lowest_kpa, produced);
        report.highest_kpa = @max(report.highest_kpa, produced);
        if (previous) |earlier| {
            if (produced <= earlier) report.strictly_increasing = false;
        }
        previous = produced;
        const published = try magnusSaturationKpa(temperature_c);
        const disagreement = @abs(produced - published) / published;
        if (disagreement > report.worst_relative_disagreement) {
            report.worst_relative_disagreement = disagreement;
            report.worst_disagreement_temperature_c = temperature_c;
        }
    }
    return report;
}

test "saturation vapour pressure is positive, finite and rises with temperature" {
    // The tier-1 claim. Checked over -30 to 60 C, wider than any temperate
    // site reaches, because a domain guard that only covers the expected range
    // is not a domain guard.
    const report = try saturationDomain(-30, 60, 181, production_parameters);
    try std.testing.expect(report.strictly_increasing);
    try std.testing.expect(report.lowest_kpa > 0);
    try std.testing.expect(std.math.isFinite(report.highest_kpa));
    // Monotonic and positive over 90 kelvin of span is not a weak statement:
    // the correlation is `A/T * exp(B*(C - 1/T))`, whose prefactor FALLS with
    // temperature, so the exponential must dominate everywhere in range for
    // this to hold at all.
    try std.testing.expect(report.highest_kpa > report.lowest_kpa * 100);
}

test "saturation vapour pressure agrees with the published Magnus formula" {
    // Level-5 evidence: agreement with published physics, which outranks the
    // level-8 legacy match. Magnus is NOT the oracle, so this is a statement
    // about the model rather than about the translation.
    const temperate = try saturationDomain(0, 30, 121, production_parameters);
    try std.testing.expect(temperate.worst_relative_disagreement < temperate_band_tolerance);
    const extended = try saturationDomain(-20, 40, 121, production_parameters);
    try std.testing.expect(extended.worst_relative_disagreement < extended_band_tolerance);
    // The fit is tighter where the site lives than at the extremes, and
    // asserting the ordering pins that shape rather than just the magnitudes.
    try std.testing.expect(
        temperate.worst_relative_disagreement < extended.worst_relative_disagreement,
    );
}

test "the 0 C anchor matches the textbook triple-point value" {
    // `saturation_relative_humidity = 0.61` and
    // `saturation_reference_inverse_temperature_per_k = 3.661e-3` are 0.61 kPa
    // at 1/273.15 K-1, so the correlation is anchored at the textbook
    // 0 C saturation pressure. Pinning it makes an accidental change to either
    // parameter fail here with an interpretable reason.
    const at_zero = try productionSaturationKpa(0, production_parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6100), at_zero, 5e-4);
    try std.testing.expectApproxEqRel(@as(f64, 0.6112), at_zero, 3e-3);
}

test "SOIL-EVAP-KELVIN-SUPPRESSION: drying suppresses vapour and saturation restores it" {
    // The Kelvin factor `exp(18*psi/(8.3143*T))` must be exactly 1 at zero
    // potential and strictly below 1 for the negative potentials a drying
    // surface has. A factor above 1 would let a dry surface evaporate MORE
    // than a saturated one at the same temperature.
    const temperature_k: f64 = 290;
    const saturated = try ground_air.surfaceVaporFractionWithKelvinSuppression(
        temperature_k,
        0,
        1,
        production_parameters,
    );
    var previous = saturated;
    for ([_]f64{ -0.01, -0.1, -1, -5, -20, -100 }) |potential_megapascal| {
        const dried = try ground_air.surfaceVaporFractionWithKelvinSuppression(
            temperature_k,
            potential_megapascal,
            1,
            production_parameters,
        );
        try std.testing.expect(dried < previous);
        try std.testing.expect(dried > 0);
        previous = dried;
    }
    // A positive potential is not a physical surface state for this factor and
    // would amplify rather than suppress; recorded here as the boundary the
    // production call does NOT reject, so a caller passing one is the defect.
    const amplified = try ground_air.surfaceVaporFractionWithKelvinSuppression(
        temperature_k,
        1,
        1,
        production_parameters,
    );
    try std.testing.expect(amplified > saturated);
}

test "the hour-2077 state is outside the physical domain, as recorded" {
    // The concrete violation this module exists for. `docs/discrepancy_register.md`
    // records that at hour 2077 the model evaporated into 1.543 kPa while its
    // warmest surface state was 3.74 C. This recomputes the saturation
    // pressure at that temperature from production code and confirms the
    // recorded figure, so the finding rests on a live computation rather than
    // on a number in a document.
    const at_observed = try productionSaturationKpa(3.74, production_parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7952), at_observed, 1e-3);
    // 1.543 kPa at that surface temperature is 1.94x saturation. Supersaturation
    // by a factor of two at the evaporating surface is not a tolerance
    // question.
    const observed_vapor_pressure_kpa: f64 = 1.543;
    try std.testing.expect(observed_vapor_pressure_kpa > 1.9 * at_observed);
}

test "the saturation domain rejects a degenerate or unphysical range" {
    try std.testing.expectError(
        error.InvalidSaturationDomainRange,
        saturationDomain(30, 0, 10, production_parameters),
    );
    try std.testing.expectError(
        error.InvalidSaturationDomainRange,
        saturationDomain(0, 30, 1, production_parameters),
    );
    // At -243.12 C the Magnus denominator vanishes, so the reference itself has
    // no value there and the range must be refused rather than sampled.
    try std.testing.expectError(
        error.InvalidSaturationDomainRange,
        saturationDomain(-243.12, 0, 10, production_parameters),
    );
    try std.testing.expectError(
        error.InvalidMagnusTemperature,
        magnusSaturationKpa(-243.12),
    );
}

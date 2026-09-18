//! Tier-1 physical-domain evidence for the Henry's-law dissolved-gas
//! correlation in `chemistry/precipitation_irrigation_dissolved_gases.zig`.
//!
//! Why this file exists. `docs/validation.md` ranks "dimensional consistency
//! and valid physical domains" first, above conservation closure, and the
//! standing production goal records that the tree had exactly ONE tier-1 domain
//! guard: `retentionDomain` in `soil_water_retention_validation.zig`. This is
//! the second, built in that file's shape: evaluate the constitutive relation
//! and check each output lies in its physical domain, with any floating-point
//! slack stated rather than absorbed.
//!
//! What it does NOT do. It does not change the correlation. The translation is
//! byte-faithful to `ecosys_f77/hour1.f:2463-2482` -- all five coefficient
//! pairs verified identical -- so any disagreement with textbook Henry
//! behaviour is an ORACLE property and is recorded, not corrected. See
//! `HENRY-REFERENCE-TEMPERATURE-OFFSET-001` in the discrepancy register.

const std = @import("std");
const dissolved = @import("../chemistry/precipitation_irrigation_dissolved_gases.zig");

/// The temperature at which each `exp(a - b * T)` factor is unity, measured
/// from the oracle's own coefficients rather than assumed.
///
/// `hour1.f:89` documents the solubility parameters as "solubility
/// (g m-3/g m-3) at 25 oC", so a reader calibrating them expects the model to
/// return exactly the declared value at 25 C. It does not: every factor is
/// unity at 30 C, so at 25 C the model returns 8-16% MORE dissolved gas than
/// declared.
///
/// All five land on 30.00 C, which is far too precise to be coincidence, so
/// the correlation's true reference is 30 C and the parameter documentation is
/// what disagrees. Pinned here so that "correcting" the coefficients toward a
/// 25 C unity point registers as a deliberate deviation from the oracle rather
/// than as a silent bug fix.
pub const unity_temperature_c: f64 = 30.0;

pub const GasCoefficients = struct {
    name: []const u8,
    intercept: f64,
    slope_per_c: f64,
};

/// Exactly the coefficients in `hour1.f:2463-2482`, restated here so this
/// module can check them arithmetically without reaching into the production
/// expression. A divergence between these and the production site is itself a
/// finding, which `henry coefficients match the production correlation` checks.
pub const coefficients = [_]GasCoefficients{
    .{ .name = "carbon_dioxide", .intercept = 0.843, .slope_per_c = 0.0281 },
    .{ .name = "methane", .intercept = 0.597, .slope_per_c = 0.0199 },
    .{ .name = "oxygen", .intercept = 0.516, .slope_per_c = 0.0172 },
    .{ .name = "nitrogen", .intercept = 0.456, .slope_per_c = 0.0152 },
    .{ .name = "nitrous_oxide", .intercept = 0.897, .slope_per_c = 0.0299 },
};

pub const DomainReport = struct {
    /// Largest dissolved concentration produced across the sampled range, in
    /// g m-3, so a caller can see the ceiling the correlation actually reaches.
    largest_concentration_g_m3: f64,
    /// Smallest, which must remain non-negative.
    smallest_concentration_g_m3: f64,
    /// Ratio of dissolved to atmospheric concentration at the STATED reference
    /// temperature of 25 C. Textbook Henry behaviour with a 25 C parameter set
    /// would make this the declared solubility ratio exactly.
    reference_ratio_at_25c: f64,
};

/// Unit atmospheric concentration and unit activity, so the report isolates
/// the temperature factor from the parameter values.
fn unitInputs() struct {
    atmospheric: dissolved.AtmosphericMassConcentrations,
    solubility: dissolved.SolubilitiesAt25C,
    activity: dissolved.Activities,
} {
    return .{
        .atmospheric = .{
            .carbon_dioxide_g_m3 = 1,
            .methane_g_m3 = 1,
            .oxygen_g_m3 = 1,
            .nitrogen_g_m3 = 1,
            .nitrous_oxide_g_m3 = 1,
        },
        .solubility = .{
            .carbon_dioxide_ratio = 1,
            .methane_ratio = 1,
            .oxygen_ratio = 1,
            .nitrogen_ratio = 1,
            .nitrous_oxide_ratio = 1,
        },
        .activity = .{
            .carbon_dioxide = 0,
            .methane = 0,
            .oxygen = 0,
            .nitrogen = 0,
            .nitrous_oxide = 0,
        },
    };
}

/// Tier 1: every dissolved concentration the correlation can produce over a
/// temperature range must be finite and non-negative, and must fall as
/// temperature rises. A gas that became MORE soluble when warmed would be
/// thermodynamically backwards regardless of what any oracle says.
pub fn henryDomain(
    lowest_temperature_c: f64,
    highest_temperature_c: f64,
    sample_count: usize,
) !DomainReport {
    if (!std.math.isFinite(lowest_temperature_c) or !std.math.isFinite(highest_temperature_c) or
        lowest_temperature_c > highest_temperature_c or sample_count < 2)
        return error.InvalidHenryDomainRange;
    if (lowest_temperature_c <= -273.15) return error.InvalidHenryDomainRange;

    const inputs = unitInputs();
    var report: DomainReport = .{
        .largest_concentration_g_m3 = 0,
        .smallest_concentration_g_m3 = std.math.inf(f64),
        .reference_ratio_at_25c = 0,
    };
    var previous: ?f64 = null;
    for (0..sample_count) |index| {
        const fraction = @as(f64, @floatFromInt(index)) /
            @as(f64, @floatFromInt(sample_count - 1));
        const temperature = lowest_temperature_c +
            fraction * (highest_temperature_c - lowest_temperature_c);
        const result = try dissolved.calculate(
            inputs.atmospheric,
            inputs.solubility,
            inputs.activity,
            temperature,
        );
        // Precipitation and irrigation share one expression in the source, so a
        // divergence between them would mean the translation lost that sharing.
        if (result.precipitation.carbon_dioxide_g_m3 != result.irrigation.carbon_dioxide_g_m3)
            return error.PrecipitationIrrigationSolubilityDisagreement;
        inline for (std.meta.fields(dissolved.DissolvedGasConcentrations)) |field| {
            const value = @field(result.precipitation, field.name);
            if (!std.math.isFinite(value)) return error.NonFiniteHenryConcentration;
            if (value < 0) return error.NegativeHenryConcentration;
            if (value > report.largest_concentration_g_m3)
                report.largest_concentration_g_m3 = value;
            if (value < report.smallest_concentration_g_m3)
                report.smallest_concentration_g_m3 = value;
        }
        // Monotonicity on one representative gas: the five share the same
        // functional form, so a violation would be shared too.
        const current = result.precipitation.carbon_dioxide_g_m3;
        if (previous) |earlier| {
            if (current > earlier) return error.HenrySolubilityRisesWithTemperature;
        }
        previous = current;
    }

    const at_reference = try dissolved.calculate(
        inputs.atmospheric,
        inputs.solubility,
        inputs.activity,
        25.0,
    );
    report.reference_ratio_at_25c = at_reference.precipitation.carbon_dioxide_g_m3;
    return report;
}

test "henry solubility stays in its physical domain and falls with temperature" {
    // 0 to 40 C spans the range a temperate site actually reaches.
    const report = try henryDomain(0, 40, 81);
    try std.testing.expect(report.smallest_concentration_g_m3 >= 0);
    try std.testing.expect(std.math.isFinite(report.largest_concentration_g_m3));
    // With unit atmospheric concentration and unit solubility the output IS the
    // temperature factor, so the ceiling over 0..40 C is the factor at 0 C.
    const factor_at_zero = @exp(0.897);
    try std.testing.expectApproxEqRel(factor_at_zero, report.largest_concentration_g_m3, 1e-12);
}

test "henry solubility is unity at 30 C, not at the documented 25 C" {
    // The finding this module exists to pin. `hour1.f:89` documents the
    // solubility parameters as being "at 25 oC", but every temperature factor
    // reaches unity at 30 C, so at 25 C the model returns MORE dissolved gas
    // than the declared solubility. Recorded as
    // HENRY-REFERENCE-TEMPERATURE-OFFSET-001; ng is byte-faithful to the
    // oracle, so this is an oracle property and must not be "corrected" here.
    for (coefficients) |gas| {
        const unity_at = gas.intercept / gas.slope_per_c;
        try std.testing.expectApproxEqAbs(unity_temperature_c, unity_at, 1e-9);
    }
    const report = try henryDomain(0, 40, 81);
    // 8-16% above the declared ratio at the documented reference temperature.
    try std.testing.expect(report.reference_ratio_at_25c > 1.0);
    try std.testing.expectApproxEqRel(
        @exp(0.843 - 0.0281 * 25.0),
        report.reference_ratio_at_25c,
        1e-12,
    );
}

test "henry domain rejects an inverted or degenerate range" {
    try std.testing.expectError(error.InvalidHenryDomainRange, henryDomain(40, 0, 10));
    try std.testing.expectError(error.InvalidHenryDomainRange, henryDomain(0, 40, 1));
    // Below absolute zero the correlation has no meaning, and the production
    // site rejects it too.
    try std.testing.expectError(error.InvalidHenryDomainRange, henryDomain(-300, 0, 10));
}

test "henry coefficients match the production correlation" {
    // Guards the restatement above against drifting from the production
    // expression. With unit inputs the output equals `exp(a - b*T)` exactly,
    // so each declared pair can be checked against what production computes.
    const inputs = unitInputs();
    const temperature: f64 = 17.0;
    const result = try dissolved.calculate(
        inputs.atmospheric,
        inputs.solubility,
        inputs.activity,
        temperature,
    );
    const produced = [_]f64{
        result.precipitation.carbon_dioxide_g_m3,
        result.precipitation.methane_g_m3,
        result.precipitation.oxygen_g_m3,
        result.precipitation.nitrogen_g_m3,
        result.precipitation.nitrous_oxide_g_m3,
    };
    for (coefficients, produced) |gas, value| {
        try std.testing.expectApproxEqRel(
            @exp(gas.intercept - gas.slope_per_c * temperature),
            value,
            1e-12,
        );
    }
}

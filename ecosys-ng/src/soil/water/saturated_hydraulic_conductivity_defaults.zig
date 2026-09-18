// **A8a DISPOSITION: superseded by `soil/water/solver_properties.zig`, which
// resolves the same default from per-layer retention rather than a per-cell
// log-potential triple, and re-derives the missing-value flag from the data.**
//
// Fortran: `hour1.f:2197--2221`, two structurally identical arms. `:2197`
// `IF(ISOIL(3,...)==1)` defaults the vertical conductivity `SCNV`, `:2210`
// `IF(ISOIL(4,...)==1)` the lateral `SCNH`; each computes
// `THETF=AMIN1(POROS,EXP((PSIMS-LOG(0.033))*(PSL-FCL)/PSISD+PSL))` and
// `1.54*((POROS-THETF)/THETF)**2` for mineral soil (`CORGC<FORGW`), else
// `(0.10+75.0*1.0E-15**BKDS)*FMPR`. This module reproduces both arms and both
// independent gates exactly; `compute:26--34` and `defaultConductivity:36--62`
// were read against the Fortran and agree term for term, including that `FMPR`
// multiplies only the organic branch.
//
// Production owner: `solver_properties.zig:250--271` `estimateSaturatedConductivity`,
// called once per layer from `initMapped:185`. Same two branches, same
// threshold (`parameters.retention.organic_soil_threshold_g_per_megagram` is
// `FORGW`), and the five literals are runtime parameters carried on
// `RuntimeParameters:14--18` with the HOUR1 values restored by
// `compatibilityParameters:31--35` (`1.54`, `0.033`, `0.10`, `75`, `1.0e-15`)
// and supplied for current runscripts by the `soil_solver` record
// (`driver/runscript.zig:1905`). `FMPR` is `entry.material.micropore_fraction`,
// built at `soil/profile/initialization.zig:49` as
// `(1-rock_fraction)*(1-macropore_fraction)`.
//
// Three ways the owner is the better home, which is why this module is retired
// rather than wired in:
//
// 1. The owner reads the missing-value condition from the data instead of
//    trusting a separately-stored declaration. `:186` and `:190` test
//    `entry.profile.vertical_saturated_conductivity_mm_h[layer] < 0` and the
//    lateral counterpart directly. That is exactly how `readi.f:472--481` sets
//    `ISOIL(3)`/`ISOIL(4)` in the first place, so production skips the
//    intermediate flag array and cannot desynchronize from it. This module's
//    `vertical_was_missing`/`lateral_was_missing` booleans would have to be
//    populated from something, and the only honest source is the same
//    comparison.
// 2. The owner's log potentials are per layer, not per cell. This module takes
//    `log_saturation_potential`, `log_porosity`, `log_field_capacity` and
//    `saturation_to_field_potential_interval` as four independent scalars,
//    mirroring Fortran's cell-scoped `PSIMS(NY,NX)` and `PSISD(NY,NX)`
//    (`starts.f:526--530`: `PSISD = log(-PSIFC) - log(-PSIPS)`). The owner
//    derives all four from the already-resolved `retention.ResolvedCurve` at
//    `:257--260`, so the interval is `log_field_potential -
//    log_saturation_potential` on that layer's own curve and cannot be passed
//    inconsistently with the porosity it is divided against. Binding this
//    module would reintroduce a four-scalar interface whose parts must agree.
// 3. The owner computes one estimate and applies it to whichever of the two
//    directions is missing (`:185`, then `:186--192`), where the Fortran
//    recomputes the identical expression twice. That is an exact
//    simplification, not an approximation: nothing between `:2201` and `:2214`
//    mutates `POROS`, `PSL`, `FCL`, `PSISD`, `BKDS` or `FMPR`. This module also
//    factors the duplicate into `defaultConductivity`, so on this point the two
//    agree; it is noted only to preempt the inference that the owner dropped an
//    arm.
//
// One divergence, deliberately not filed: this module raises
// `error.InvalidDefaultHydraulicConductivityDenominator` when `THETF <= 0`
// (`:48--49`), a guard the Fortran lacks. The owner instead validates the
// resolved result at `:269`, rejecting a non-finite or negative conductivity.
// Both catch the same degenerate profile; the owner's check is downstream of
// the division rather than upstream of it.
//
// missing saturated conductivity defaults group of
// docs/traceability/hour1_saturated_conductivity_defaults_are_owned_by_solver_properties.md

const std = @import("std");

pub const Inputs = struct {
    vertical_was_missing: bool,
    lateral_was_missing: bool,
    existing_vertical_m2_h_megapascal: f64,
    existing_lateral_m2_h_megapascal: f64,
    organic_carbon_g_per_megagram: f64,
    organic_soil_threshold_g_per_megagram: f64,
    porosity_m3_m3: f64,
    log_saturation_potential: f64,
    log_porosity: f64,
    log_field_capacity: f64,
    saturation_to_field_potential_interval: f64,
    bulk_density_megagrams_m3: f64,
    macropore_factor: f64,
};

pub const Result = struct {
    vertical_m2_h_megapascal: f64,
    lateral_m2_h_megapascal: f64,
};

/// `hour1.f` lines 2197--2221. Vertical and lateral missing-value gates remain
/// independent and repeat the source default calculation in their order.
pub fn compute(inputs: Inputs) !Result {
    try validate(inputs);
    var vertical = inputs.existing_vertical_m2_h_megapascal;
    var lateral = inputs.existing_lateral_m2_h_megapascal;
    if (inputs.vertical_was_missing)
        vertical = try defaultConductivity(inputs);
    if (inputs.lateral_was_missing)
        lateral = try defaultConductivity(inputs);
    return .{ .vertical_m2_h_megapascal = vertical, .lateral_m2_h_megapascal = lateral };
}

fn defaultConductivity(inputs: Inputs) !f64 {
    if (inputs.organic_carbon_g_per_megagram <
        inputs.organic_soil_threshold_g_per_megagram)
    {
        const field_equivalent_water_content = @min(
            inputs.porosity_m3_m3,
            @exp(
                (inputs.log_saturation_potential - @log(0.033)) *
                    (inputs.log_porosity - inputs.log_field_capacity) /
                    inputs.saturation_to_field_potential_interval +
                    inputs.log_porosity,
            ),
        );
        if (field_equivalent_water_content <= 0)
            return error.InvalidDefaultHydraulicConductivityDenominator;
        return 1.54 * std.math.pow(
            f64,
            (inputs.porosity_m3_m3 - field_equivalent_water_content) /
                field_equivalent_water_content,
            2.0,
        );
    }
    var conductivity = 0.10 + 75.0 *
        std.math.pow(f64, 1.0e-15, inputs.bulk_density_megagrams_m3);
    conductivity = conductivity * inputs.macropore_factor;
    return conductivity;
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteDefaultHydraulicConductivityInput;
    inline for (.{
        inputs.existing_vertical_m2_h_megapascal,
        inputs.existing_lateral_m2_h_megapascal,
        inputs.organic_carbon_g_per_megagram,
        inputs.organic_soil_threshold_g_per_megagram,
        inputs.porosity_m3_m3,
        inputs.bulk_density_megagrams_m3,
        inputs.macropore_factor,
    }) |value| if (value < 0)
        return error.InvalidDefaultHydraulicConductivityInput;
    if (inputs.saturation_to_field_potential_interval == 0)
        return error.InvalidDefaultHydraulicConductivityInput;
}

test "mineral defaults independently replace missing directions" {
    const result = try compute(.{
        .vertical_was_missing = true,
        .lateral_was_missing = false,
        .existing_vertical_m2_h_megapascal = 0,
        .existing_lateral_m2_h_megapascal = 9,
        .organic_carbon_g_per_megagram = 1000,
        .organic_soil_threshold_g_per_megagram = 100_000,
        .porosity_m3_m3 = 0.5,
        .log_saturation_potential = @log(0.001),
        .log_porosity = @log(0.5),
        .log_field_capacity = @log(0.3),
        .saturation_to_field_potential_interval = 3,
        .bulk_density_megagrams_m3 = 1.2,
        .macropore_factor = 2,
    });
    try std.testing.expect(result.vertical_m2_h_megapascal >= 0);
    try std.testing.expectEqual(@as(f64, 9), result.lateral_m2_h_megapascal);
}

test "organic default applies bulk density power then macropore factor" {
    const result = try compute(.{
        .vertical_was_missing = true,
        .lateral_was_missing = true,
        .existing_vertical_m2_h_megapascal = 0,
        .existing_lateral_m2_h_megapascal = 0,
        .organic_carbon_g_per_megagram = 200_000,
        .organic_soil_threshold_g_per_megagram = 100_000,
        .porosity_m3_m3 = 0.8,
        .log_saturation_potential = 0,
        .log_porosity = 0,
        .log_field_capacity = 0,
        .saturation_to_field_potential_interval = 1,
        .bulk_density_megagrams_m3 = 1,
        .macropore_factor = 2,
    });
    const expected = (0.10 + 75.0e-15) * 2;
    try std.testing.expectApproxEqAbs(
        expected,
        result.vertical_m2_h_megapascal,
        1e-15,
    );
    try std.testing.expectEqual(
        result.vertical_m2_h_megapascal,
        result.lateral_m2_h_megapascal,
    );
}

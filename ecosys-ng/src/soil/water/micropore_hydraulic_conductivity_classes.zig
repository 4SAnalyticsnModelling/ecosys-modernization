// **A8a DISPOSITION: retained translation oracle; no production reader.**
//
// Fortran: `hour1.f:2252--2304`. `SUM2` over `K=1..JK` of `(2K-1)/PSISK(K)**2`;
// then for each `K`, `YK=((JK-XK)/JK)**YKL`, `SUM1` over `M=K..JK` of
// `(2*XM+1-2*XK)/PSISK(M)**2`, and `HCND(N,K,...) = SCNH or SCNV * YK*SUM1/SUM2`
// with `N=3` taking `SCNV` and `N=1,2` taking `SCNH`. The air-entry pair
// `PSISA`/`THETS` is captured at `:2285--2288` on the first downward crossing of
// `FSCNV*SCNV` by the vertical class, and `hour1.f:2287--2288` is the only place
// in the entire legacy tree that assigns either.
//
// `hydraulic_conductivity.zig` retains the runtime-sized HCND table and its
// tests as the canonical executable legacy record, but production intentionally
// uses the Mualem-van Genuchten conductivity in `solver_hydraulics.zig`.
// `docs/model_changes.md` records that constitutive replacement and
// `validation/soil_water_retention_validation.zig` supplies its independent
// physical-invariant and convergence evidence. Neither HCND implementation has
// a production reader.
//
// The reason this candidate is retired is its input surface. It declares
// nineteen `f64` inputs, ten of which are logarithms and interval differences of
// the other nine (`log_porosity`, `log_field_capacity_to_wilting_point`,
// `saturation_to_field_potential_interval`, and so on), mirroring Fortran's
// separately-stored `PSL`/`FCL`/`WPL`/`PSD`/`FCD`/`PSIMD`/`PSISD` arrays. Its
// private `potential:97--117` then re-implements the four-branch retention
// curve from those scalars. Keeping that duplicate evaluator on a production
// path would reintroduce the exact retention/conductivity drift that the single
// MvG owner avoids.
//
// micropore conductivity classes group of
// docs/traceability/hour1_micropore_conductivity_classes_are_owned_by_hydraulic_conductivity.md

const std = @import("std");

pub const Inputs = struct {
    porosity_m3_m3: f64,
    field_capacity_m3_m3: f64,
    wilting_point_m3_m3: f64,
    saturation_margin_m3_m3: f64,
    log_porosity: f64,
    log_field_capacity: f64,
    log_wilting_point: f64,
    log_saturation_potential: f64,
    log_field_capacity_potential: f64,
    log_wilting_potential: f64,
    log_porosity_to_field_capacity: f64,
    log_field_capacity_to_wilting_point: f64,
    saturation_to_field_potential_interval: f64,
    field_to_wilting_potential_interval: f64,
    wet_end_shape: f64,
    dry_end_shape: f64,
    pore_interaction: f64,
    minimum_potential_megapascal: f64,
    saturation_potential_megapascal: f64,
    vertical_saturated_conductivity_m2_h_megapascal: f64,
    lateral_saturated_conductivity_m2_h_megapascal: f64,
    air_entry_conductivity_fraction: f64,
};

pub const Outputs = struct {
    water_content_m3_m3: []f64,
    water_potential_megapascal: []f64,
    lateral_x_conductivity_m2_h_megapascal: []f64,
    lateral_y_conductivity_m2_h_megapascal: []f64,
    vertical_conductivity_m2_h_megapascal: []f64,
};

pub const AirEntry = struct {
    potential_megapascal: f64,
    water_content_m3_m3: f64,
};

/// `hour1.f` lines 2252--2304. Runtime classes retain K, K->M, then direction
/// 1..3 traversal and the vertical air-entry threshold crossing.
pub fn compute(inputs: Inputs, outputs: Outputs) !?AirEntry {
    const count = try validate(inputs, outputs);
    const count_f = @as(f64, @floatFromInt(count));
    var denominator: f64 = 0;
    for (0..count) |class| {
        const k = @as(f64, @floatFromInt(class + 1));
        const x_k = @max(0.0, k - 0.01 * count_f);
        const theta =
            inputs.porosity_m3_m3 -
            x_k / count_f * inputs.porosity_m3_m3;
        outputs.water_content_m3_m3[class] = theta;
        const psi = potential(inputs, theta);
        outputs.water_potential_megapascal[class] = psi;
        denominator += (2.0 * k - 1.0) / (psi * psi);
    }
    if (!std.math.isFinite(denominator) or denominator <= 0)
        return error.InvalidSoilHydraulicClassDenominator;
    var air_entry: ?AirEntry = null;
    for (0..count) |class| {
        const k = @as(f64, @floatFromInt(class + 1));
        const x_k = @max(0.0, k - 0.01 * count_f);
        const shape =
            std.math.pow(f64, (count_f - x_k) / count_f, inputs.pore_interaction);
        var numerator: f64 = 0;
        for (class..count) |summed| {
            const m = @as(f64, @floatFromInt(summed + 1));
            const x_m = @max(0.0, m - 0.01 * count_f);
            const psi = outputs.water_potential_megapascal[summed];
            numerator += (2.0 * x_m + 1.0 - 2.0 * x_k) / (psi * psi);
        }
        outputs.lateral_x_conductivity_m2_h_megapascal[class] =
            inputs.lateral_saturated_conductivity_m2_h_megapascal *
            shape * numerator / denominator;
        outputs.lateral_y_conductivity_m2_h_megapascal[class] =
            inputs.lateral_saturated_conductivity_m2_h_megapascal *
            shape * numerator / denominator;
        outputs.vertical_conductivity_m2_h_megapascal[class] =
            inputs.vertical_saturated_conductivity_m2_h_megapascal *
            shape * numerator / denominator;
        if (class > 0 and
            outputs.vertical_conductivity_m2_h_megapascal[class] <
                inputs.air_entry_conductivity_fraction *
                    inputs.vertical_saturated_conductivity_m2_h_megapascal and
            outputs.vertical_conductivity_m2_h_megapascal[class - 1] >=
                inputs.air_entry_conductivity_fraction *
                    inputs.vertical_saturated_conductivity_m2_h_megapascal)
            air_entry = .{
                .potential_megapascal = outputs.water_potential_megapascal[class - 1],
                .water_content_m3_m3 = outputs.water_content_m3_m3[class - 1],
            };
    }
    return air_entry;
}

fn potential(inputs: Inputs, theta: f64) f64 {
    if (theta < inputs.wilting_point_m3_m3)
        return @max(inputs.minimum_potential_megapascal, -@exp(
            inputs.log_wilting_potential + inputs.dry_end_shape *
                ((inputs.log_wilting_point - @log(theta)) /
                    inputs.log_field_capacity_to_wilting_point *
                    inputs.field_to_wilting_potential_interval),
        ));
    if (theta < inputs.field_capacity_m3_m3)
        return -@exp(inputs.log_field_capacity_potential +
            (inputs.log_field_capacity - @log(theta)) /
                inputs.log_field_capacity_to_wilting_point *
                inputs.field_to_wilting_potential_interval);
    if (theta < inputs.porosity_m3_m3 - inputs.saturation_margin_m3_m3)
        return -@exp(inputs.log_saturation_potential + std.math.pow(
            f64,
            @max(0.0, inputs.log_porosity - @log(theta)) /
                inputs.log_porosity_to_field_capacity,
            inputs.wet_end_shape,
        ) * inputs.saturation_to_field_potential_interval);
    return inputs.saturation_potential_megapascal;
}

fn validate(inputs: Inputs, outputs: Outputs) !usize {
    const count = outputs.water_content_m3_m3.len;
    if (count == 0 or outputs.water_potential_megapascal.len != count or
        outputs.lateral_x_conductivity_m2_h_megapascal.len != count or
        outputs.lateral_y_conductivity_m2_h_megapascal.len != count or
        outputs.vertical_conductivity_m2_h_megapascal.len != count)
        return error.SoilHydraulicClassDimensionMismatch;
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteSoilHydraulicClassInput;
    if (inputs.porosity_m3_m3 <= 0 or inputs.field_capacity_m3_m3 <= 0 or
        inputs.wilting_point_m3_m3 <= 0 or
        inputs.log_porosity_to_field_capacity <= 0 or
        inputs.log_field_capacity_to_wilting_point <= 0 or
        inputs.minimum_potential_megapascal >= 0 or inputs.saturation_potential_megapascal >= 0)
        return error.InvalidSoilHydraulicClassInput;
    return count;
}

test "runtime soil classes produce two lateral and one vertical conductivity" {
    var theta: [8]f64 = undefined;
    var psi: [8]f64 = undefined;
    var lateral_x: [8]f64 = undefined;
    var lateral_y: [8]f64 = undefined;
    var vertical: [8]f64 = undefined;
    _ = try compute(.{
        .porosity_m3_m3 = 0.5,
        .field_capacity_m3_m3 = 0.3,
        .wilting_point_m3_m3 = 0.1,
        .saturation_margin_m3_m3 = 1e-6,
        .log_porosity = @log(0.5),
        .log_field_capacity = @log(0.3),
        .log_wilting_point = @log(0.1),
        .log_saturation_potential = @log(0.001),
        .log_field_capacity_potential = @log(0.033),
        .log_wilting_potential = @log(1.5),
        .log_porosity_to_field_capacity = @log(0.5) - @log(0.3),
        .log_field_capacity_to_wilting_point = @log(0.3) - @log(0.1),
        .saturation_to_field_potential_interval = 3,
        .field_to_wilting_potential_interval = 4,
        .wet_end_shape = 0.5,
        .dry_end_shape = 0.5,
        .pore_interaction = 1.33,
        .minimum_potential_megapascal = -1000,
        .saturation_potential_megapascal = -0.001,
        .vertical_saturated_conductivity_m2_h_megapascal = 0.02,
        .lateral_saturated_conductivity_m2_h_megapascal = 0.01,
        .air_entry_conductivity_fraction = 0.1,
    }, .{
        .water_content_m3_m3 = &theta,
        .water_potential_megapascal = &psi,
        .lateral_x_conductivity_m2_h_megapascal = &lateral_x,
        .lateral_y_conductivity_m2_h_megapascal = &lateral_y,
        .vertical_conductivity_m2_h_megapascal = &vertical,
    });
    try std.testing.expectEqualSlices(f64, &lateral_x, &lateral_y);
    for (vertical) |value| try std.testing.expect(std.math.isFinite(value));
}

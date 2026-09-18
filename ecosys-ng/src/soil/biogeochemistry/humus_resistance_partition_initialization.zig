// **A8a DISPOSITION: SUPERSEDED; SOIL-HUMPART-001 IS CLOSED.**
//
// The module is a faithful three-arm translation of `starts.f:997--1085`: the
// initial partition of layer humus into its less-resistant and more-resistant
// structural components, `FC1 = FC0*FCX`, published as `CFOSC(1..4,4,L)` at
// `:1067--1070`, plus the microbial-detritus split `CFOMC(1) =
// 5*FC1/(4*FC1+1)` at `:1077--1078`. Its `SoilOrigin` enum at `:3` is legacy's
// `ISOILR` test at `:997`, and it keeps the dryland/wetland split of
// `:1014--1015` and the reconstructed arm of `:1050` distinct - which is
// precisely why it is worth keeping.
//
// The bound owner is `soil/organic/initialization.zig`, reached from
// `ecosys_ng.zig:1427`. It gets the depth factor `FCX` right in all three arms:
// `deriveMappedDepthPartition:268--271` returns all ones for a
// `reconstructed_profile` (legacy `:1058`), `deriveNaturalDrylandDepthPartition
// :215--221` implements `HCX = LOG(0.5)/TORGM` and `FCX = EXP(HCX*TORGL)`
// (legacy `:1024--1028`), and `:294--298` overwrites the factor with 1 for any
// layer whose midpoint is below the reconstructed dryland depth limit, which is
// legacy's `HCX = LOG(1.0)/TORGM = 0` wetland neutralization at `:1041`.
//
// The authoritative owner now carries an explicit per-layer wetland-arm flag
// alongside the depth factor. It disables nutrient protection only for that
// branch, retains it for reconstructed layers, and has a direct three-arm
// regression.
//
// Do not bind this module. It is an initialization-time module with
// its own `State`, and binding it would create a second writer of the humus
// structural fractions that `initializeMappedInPlace:514--515` already writes.
// It remains as an equation-level oracle; production's composite owner is the
// sole writer and publishes both the factor and the explicit branch identity.

const std = @import("std");

pub const SoilOrigin = enum {
    natural,
    reconstructed,
};

pub const Inputs = struct {
    soil_origin: SoilOrigin,
    layer_midpoint_depth_m: f64,
    external_water_table_depth_m: f64,
    deepest_layer_depth_m: f64,
    maximum_profile_surface_elevation_m: f64,
    humus_carbon_g_c_per_megagram: f64,
    humus_nitrogen_g_n_per_megagram: f64,
    humus_phosphorus_g_p_per_megagram: f64,
    accumulated_humus_g_c_per_m2: f64,
    partitioning_humus_scale_g_c_per_m2: f64,
    calculation_floor: f64,
};

pub const State = struct {
    /// Less resistant, more resistant, cellulose, and lignin fractions.
    humus_kinetic_fraction: []f64,
    /// Microbial detritus allocation to less and more resistant humus.
    microbial_detritus_humus_fraction: []f64,
};

const Candidate = struct {
    humus_kinetic_fraction: [4]f64,
    microbial_detritus_humus_fraction: [2]f64,
};

fn nutrientAdjustedSurfaceFraction(inputs: Inputs) f64 {
    const surface_fraction = 0.20;
    if (inputs.humus_carbon_g_c_per_megagram > inputs.calculation_floor) {
        return surface_fraction * @exp(
            -5.0 * (@min(
                inputs.humus_nitrogen_g_n_per_megagram,
                10.0 * inputs.humus_phosphorus_g_p_per_megagram,
            ) / inputs.humus_carbon_g_c_per_megagram),
        );
    }
    return surface_fraction;
}

fn calculateCandidate(inputs: Inputs) Candidate {
    var surface_fraction: f64 = undefined;
    var depth_multiplier: f64 = undefined;

    if (inputs.soil_origin == .natural) {
        const dryland_depth_limit_m =
            inputs.external_water_table_depth_m +
            inputs.deepest_layer_depth_m -
            inputs.maximum_profile_surface_elevation_m;
        if (inputs.layer_midpoint_depth_m <= dryland_depth_limit_m) {
            surface_fraction = nutrientAdjustedSurfaceFraction(inputs);
            const depth_coefficient =
                if (inputs.partitioning_humus_scale_g_c_per_m2 >
                inputs.calculation_floor)
                    @log(0.5) /
                        inputs.partitioning_humus_scale_g_c_per_m2
                else
                    0.0;
            depth_multiplier = @exp(
                depth_coefficient * inputs.accumulated_humus_g_c_per_m2,
            );
        } else {
            surface_fraction = 0.20;
            const depth_coefficient =
                if (inputs.partitioning_humus_scale_g_c_per_m2 >
                inputs.calculation_floor)
                    @log(1.0) /
                        inputs.partitioning_humus_scale_g_c_per_m2
                else
                    0.0;
            depth_multiplier = @exp(
                depth_coefficient * inputs.accumulated_humus_g_c_per_m2,
            );
        }
    } else {
        surface_fraction = nutrientAdjustedSurfaceFraction(inputs);
        depth_multiplier = 1.0;
    }

    const less_resistant_fraction = surface_fraction * depth_multiplier;
    const microbial_less_resistant_fraction =
        5.0 * less_resistant_fraction /
        (4.0 * less_resistant_fraction + 1.0);
    return .{
        .humus_kinetic_fraction = .{
            less_resistant_fraction,
            1.0 - less_resistant_fraction,
            0.00,
            0.00,
        },
        .microbial_detritus_humus_fraction = .{
            microbial_less_resistant_fraction,
            1.0 - microbial_less_resistant_fraction,
        },
    };
}

fn validateInputs(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (field.type == f64 and
            !std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteHumusPartitionInput;
    }
    if (inputs.humus_carbon_g_c_per_megagram < 0.0 or
        inputs.humus_nitrogen_g_n_per_megagram < 0.0 or
        inputs.humus_phosphorus_g_p_per_megagram < 0.0 or
        inputs.accumulated_humus_g_c_per_m2 < 0.0 or
        inputs.partitioning_humus_scale_g_c_per_m2 < 0.0 or
        inputs.calculation_floor < 0.0)
        return error.InvalidHumusPartitionInput;
}

fn validateCandidate(candidate: Candidate) !void {
    inline for (@typeInfo(Candidate).@"struct".fields) |field| {
        for (@field(candidate, field.name)) |fraction| {
            if (!std.math.isFinite(fraction))
                return error.NonFiniteHumusPartitionResult;
            if (fraction < 0.0 or fraction > 1.0)
                return error.InvalidHumusPartitionResult;
        }
    }
}

/// Exact source-order translation of legacy `STARTS` lines 997--1085.
///
/// This routine applies only to mineral layers. Geometric depths are metres,
/// organic concentrations are g/Mg, and accumulated humus is g C/m2.
pub fn initialize(state: State, inputs: Inputs) !void {
    if (state.humus_kinetic_fraction.len != 4 or
        state.microbial_detritus_humus_fraction.len != 2)
        return error.HumusPartitionDimensionMismatch;
    try validateInputs(inputs);
    const candidate = calculateCandidate(inputs);
    try validateCandidate(candidate);

    @memcpy(
        state.humus_kinetic_fraction,
        candidate.humus_kinetic_fraction[0..],
    );
    @memcpy(
        state.microbial_detritus_humus_fraction,
        candidate.microbial_detritus_humus_fraction[0..],
    );
}

test "STARTS natural dryland humus partition follows nutrient and depth effects" {
    var humus = [_]f64{9.0} ** 4;
    var detritus = [_]f64{9.0} ** 2;
    const inputs: Inputs = .{
        .soil_origin = .natural,
        .layer_midpoint_depth_m = 0.5,
        .external_water_table_depth_m = 2.0,
        .deepest_layer_depth_m = 3.0,
        .maximum_profile_surface_elevation_m = 1.0,
        .humus_carbon_g_c_per_megagram = 100.0,
        .humus_nitrogen_g_n_per_megagram = 2.0,
        .humus_phosphorus_g_p_per_megagram = 0.1,
        .accumulated_humus_g_c_per_m2 = 1000.0,
        .partitioning_humus_scale_g_c_per_m2 = 2000.0,
        .calculation_floor = 1.0e-12,
    };
    try initialize(.{
        .humus_kinetic_fraction = &humus,
        .microbial_detritus_humus_fraction = &detritus,
    }, inputs);

    const expected_less = 0.20 * @exp(-0.05) * @sqrt(0.5);
    try std.testing.expectApproxEqAbs(expected_less, humus[0], 1.0e-15);
    try std.testing.expectApproxEqAbs(1.0, humus[0] + humus[1], 1.0e-15);
    try std.testing.expectApproxEqAbs(
        1.0,
        detritus[0] + detritus[1],
        1.0e-15,
    );
}

test "STARTS natural wetland uses invariant twenty percent partition" {
    var humus = [_]f64{9.0} ** 4;
    var detritus = [_]f64{9.0} ** 2;
    try initialize(.{
        .humus_kinetic_fraction = &humus,
        .microbial_detritus_humus_fraction = &detritus,
    }, .{
        .soil_origin = .natural,
        .layer_midpoint_depth_m = 2.0,
        .external_water_table_depth_m = 0.5,
        .deepest_layer_depth_m = 1.0,
        .maximum_profile_surface_elevation_m = 0.0,
        .humus_carbon_g_c_per_megagram = 100.0,
        .humus_nitrogen_g_n_per_megagram = 20.0,
        .humus_phosphorus_g_p_per_megagram = 2.0,
        .accumulated_humus_g_c_per_m2 = 5000.0,
        .partitioning_humus_scale_g_c_per_m2 = 1000.0,
        .calculation_floor = 1.0e-12,
    });
    try std.testing.expectEqual(@as(f64, 0.20), humus[0]);
    try std.testing.expectEqual(@as(f64, 0.80), humus[1]);
    try std.testing.expectEqual(@as(f64, 5.0 / 9.0), detritus[0]);
}

test "invalid input leaves partition state unchanged" {
    var humus = [_]f64{7.0} ** 4;
    var detritus = [_]f64{8.0} ** 2;
    try std.testing.expectError(
        error.InvalidHumusPartitionInput,
        initialize(.{
            .humus_kinetic_fraction = &humus,
            .microbial_detritus_humus_fraction = &detritus,
        }, .{
            .soil_origin = .reconstructed,
            .layer_midpoint_depth_m = 1.0,
            .external_water_table_depth_m = 2.0,
            .deepest_layer_depth_m = 3.0,
            .maximum_profile_surface_elevation_m = 1.0,
            .humus_carbon_g_c_per_megagram = -1.0,
            .humus_nitrogen_g_n_per_megagram = 1.0,
            .humus_phosphorus_g_p_per_megagram = 1.0,
            .accumulated_humus_g_c_per_m2 = 1.0,
            .partitioning_humus_scale_g_c_per_m2 = 1.0,
            .calculation_floor = 1.0e-12,
        }),
    );
    try std.testing.expectEqualSlices(f64, &.{ 7, 7, 7, 7 }, &humus);
    try std.testing.expectEqualSlices(f64, &.{ 8, 8 }, &detritus);
}

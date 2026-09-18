// **A8a DISPOSITION: NOT A BINDING CANDIDATE. Do not bind, do not delete.**
//
// The closed-form two-phase Stefan solution, used as the analytical oracle for
// the production freeze-thaw column. It translates no Fortran range; it is an
// independent analytical result, so neither SUPERSEDED nor GAP applies.
//
// Reachability resolved by grepping the exact declarations rather than assumed.
// Both public entry points have a live caller:
// `solveSimilarityParameter` (`:337`) and `compareProfile` (`:287`) are called
// from `validation/production_freezing_column_validation.zig` at `:204` and
// `:253`, which imports this file at its `:29` and instantiates `Parameters` at
// `:37`. That consumer is itself reported unbound by the census, yet it is a
// declared build root in `tools/gate.ps1:255` and the target of the
// `validate-freezing-column` step built at `build.zig:147--161`.
//
// Hazard, already filed as `GATE-FREEZE-SKIP-001`, stated here so no reader
// mistakes a green gate for executed evidence: that consumer is guarded
// `if (builtin.mode != .ReleaseFast) return error.SkipZigTest`, and
// `zig build test` builds Debug, so this oracle SKIPS in every ordinary gate
// run while the gate still reports PASS. `tools/gate.ps1:123--138` documents
// this and enforces two weaker things instead: that the step stays registered,
// and that it actually runs under `-FreezingColumn`. It costs roughly 36
// minutes wall for 648,000 solver steps over 500 cells, which is why it is not
// unconditional. This module is therefore correct, reached, and usually not
// executed. That is a gate coverage defect, not a reason to bind.
//
// VALIDATION-EVIDENCE group of docs/traceability/a8a_validation_dispositions.md
const std = @import("std");
const phase_change = @import("../soil/water/phase_change.zig");
const retention = @import("../soil/water/retention.zig");

pub const Parameters = struct {
    surface_temperature_c: f64 = -5,
    initial_temperature_c: f64 = 2,
    melting_temperature_c: f64 = 0,
    frozen_thermal_conductivity_w_per_m_k: f64 = 2.29,
    unfrozen_thermal_conductivity_w_per_m_k: f64 = 0.6,
    frozen_thermal_diffusivity_m2_per_s: f64 = 1.13e-6,
    unfrozen_thermal_diffusivity_m2_per_s: f64 = 1.43e-7,
    frozen_volumetric_heat_capacity_j_per_m3_k: f64 = 2_117_000,
    water_density_kg_per_m3: f64 = 1000,
    saturated_water_content_m3_per_m3: f64 = 1,
    latent_heat_of_fusion_j_per_kg: f64 = 333_700,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field|
            if (!std.math.isFinite(@field(self, field.name)))
                return error.NonFiniteStefanParameter;
        if (self.surface_temperature_c >= self.melting_temperature_c or
            self.initial_temperature_c <= self.melting_temperature_c or
            self.frozen_thermal_conductivity_w_per_m_k <= 0 or
            self.unfrozen_thermal_conductivity_w_per_m_k <= 0 or
            self.frozen_thermal_diffusivity_m2_per_s <= 0 or
            self.unfrozen_thermal_diffusivity_m2_per_s <= 0 or
            self.frozen_volumetric_heat_capacity_j_per_m3_k <= 0 or
            self.water_density_kg_per_m3 <= 0 or
            self.saturated_water_content_m3_per_m3 <= 0 or
            self.saturated_water_content_m3_per_m3 > 1 or
            self.latent_heat_of_fusion_j_per_kg <= 0)
            return error.InvalidStefanParameter;
    }
};

pub const SimilaritySolution = struct {
    parameters: Parameters,
    similarity_parameter: f64,

    pub fn interfaceDepthM(self: SimilaritySolution, elapsed_time_s: f64) !f64 {
        if (!std.math.isFinite(elapsed_time_s) or elapsed_time_s < 0)
            return error.InvalidStefanTime;
        return 2.0 * self.similarity_parameter *
            @sqrt(self.parameters.frozen_thermal_diffusivity_m2_per_s *
                elapsed_time_s);
    }

    pub fn temperatureC(
        self: SimilaritySolution,
        elapsed_time_s: f64,
        depth_m: f64,
    ) !f64 {
        if (!std.math.isFinite(elapsed_time_s) or elapsed_time_s <= 0 or
            !std.math.isFinite(depth_m) or depth_m < 0)
            return error.InvalidStefanCoordinate;
        const interface_depth_m = try self.interfaceDepthM(elapsed_time_s);
        if (depth_m <= interface_depth_m) {
            return self.parameters.surface_temperature_c +
                (self.parameters.melting_temperature_c -
                    self.parameters.surface_temperature_c) /
                    errorFunction(self.similarity_parameter) *
                    errorFunction(depth_m /
                        (2.0 * @sqrt(
                            self.parameters.frozen_thermal_diffusivity_m2_per_s *
                                elapsed_time_s,
                        )));
        }
        const scaled_interface =
            self.similarity_parameter *
            @sqrt(self.parameters.frozen_thermal_diffusivity_m2_per_s /
                self.parameters.unfrozen_thermal_diffusivity_m2_per_s);
        return self.parameters.initial_temperature_c -
            (self.parameters.initial_temperature_c -
                self.parameters.melting_temperature_c) /
                complementaryErrorFunction(scaled_interface) *
                complementaryErrorFunction(depth_m /
                    (2.0 * @sqrt(
                        self.parameters.unfrozen_thermal_diffusivity_m2_per_s *
                            elapsed_time_s,
                    )));
    }
};

pub const ProfileMetrics = struct {
    root_mean_square_temperature_error_k: f64,
    maximum_absolute_temperature_error_k: f64,
    analytical_interface_depth_m: f64,
    simulated_interface_depth_m: f64,
    absolute_interface_depth_error_m: f64,
};

pub const NumericalColumnOptions = struct {
    cell_count: usize = 500,
    cell_thickness_m: f64 = 0.01,
    time_step_s: f64 = 10,
    elapsed_time_s: f64,
};

pub const NumericalProfile = struct {
    allocator: std.mem.Allocator,
    cell_midpoint_depth_m: []f64,
    temperature_k: []f64,
    ice_water_equivalent_fraction: []f64,

    pub fn deinit(self: *NumericalProfile) void {
        self.allocator.free(self.ice_water_equivalent_fraction);
        self.allocator.free(self.temperature_k);
        self.allocator.free(self.cell_midpoint_depth_m);
        self.* = undefined;
    }
};

/// Runtime-sized pure-water limiting case of the production Dall'Amico
/// enthalpy convention. The published 10 s step is explicit-conduction
/// stable at 10 mm, including the half-cell Dirichlet boundary distances.
/// Phase inversion is exact for the Stefan step curve, so no artificial
/// sub-hour full-model cycle is introduced.
pub fn simulatePureWaterColumn(
    allocator: std.mem.Allocator,
    parameters: Parameters,
    options: NumericalColumnOptions,
) !NumericalProfile {
    try parameters.validate();
    if (options.cell_count < 3 or
        !std.math.isFinite(options.cell_thickness_m) or
        options.cell_thickness_m <= 0 or
        !std.math.isFinite(options.time_step_s) or
        options.time_step_s <= 0 or
        !std.math.isFinite(options.elapsed_time_s) or
        options.elapsed_time_s < 0)
        return error.InvalidStefanColumnOption;
    // A boundary control volume has twice the ordinary face coefficient
    // because its Dirichlet face is one half cell away. The factor four is
    // therefore the conservative explicit limit for the complete column.
    const maximum_stable_time_step_s =
        options.cell_thickness_m * options.cell_thickness_m /
        (4.0 * @max(
            parameters.frozen_thermal_diffusivity_m2_per_s,
            parameters.unfrozen_thermal_diffusivity_m2_per_s,
        ));
    if (options.time_step_s > maximum_stable_time_step_s)
        return error.UnstableStefanTimeStep;
    const step_count_float = options.elapsed_time_s / options.time_step_s;
    const step_count: usize = @intFromFloat(@round(step_count_float));
    if (@abs(@as(f64, @floatFromInt(step_count)) - step_count_float) >
        1e-10 * @max(1.0, step_count_float))
        return error.StefanElapsedTimeNotDivisibleByStep;

    const depths = try allocator.alloc(f64, options.cell_count);
    errdefer allocator.free(depths);
    const temperature_k = try allocator.alloc(f64, options.cell_count);
    errdefer allocator.free(temperature_k);
    const ice_fraction = try allocator.alloc(f64, options.cell_count);
    errdefer allocator.free(ice_fraction);
    const enthalpy_j_per_m3 = try allocator.alloc(f64, options.cell_count);
    defer allocator.free(enthalpy_j_per_m3);
    const next_enthalpy_j_per_m3 = try allocator.alloc(f64, options.cell_count);
    defer allocator.free(next_enthalpy_j_per_m3);
    const conductivity_w_per_m_k = try allocator.alloc(f64, options.cell_count);
    defer allocator.free(conductivity_w_per_m_k);

    const latent_heat_j_per_m3 =
        parameters.latent_heat_of_fusion_j_per_kg *
        parameters.water_density_kg_per_m3 *
        parameters.saturated_water_content_m3_per_m3;
    const unfrozen_volumetric_heat_capacity_j_per_m3_k =
        parameters.unfrozen_thermal_conductivity_w_per_m_k /
        parameters.unfrozen_thermal_diffusivity_m2_per_s;
    for (0..options.cell_count) |cell| {
        depths[cell] =
            (@as(f64, @floatFromInt(cell)) + 0.5) *
            options.cell_thickness_m;
        temperature_k[cell] = parameters.initial_temperature_c + 273.15;
        ice_fraction[cell] = 0;
        enthalpy_j_per_m3[cell] = latent_heat_j_per_m3 +
            unfrozen_volumetric_heat_capacity_j_per_m3_k *
                parameters.initial_temperature_c;
    }
    var step: usize = 0;
    while (step < step_count) : (step += 1) {
        for (0..options.cell_count) |cell| {
            const state = phaseStateFromEnthalpy(
                enthalpy_j_per_m3[cell],
                parameters,
                latent_heat_j_per_m3,
                unfrozen_volumetric_heat_capacity_j_per_m3_k,
            );
            temperature_k[cell] = state.temperature_k;
            ice_fraction[cell] = state.ice_fraction;
            conductivity_w_per_m_k[cell] =
                state.ice_fraction *
                parameters.frozen_thermal_conductivity_w_per_m_k +
                (1.0 - state.ice_fraction) *
                    parameters.unfrozen_thermal_conductivity_w_per_m_k;
        }
        for (0..options.cell_count) |cell| {
            const upper_flux_w_per_m2 = if (cell == 0)
                conductivity_w_per_m_k[cell] *
                    (parameters.surface_temperature_c -
                        (temperature_k[cell] - 273.15)) /
                    (0.5 * options.cell_thickness_m)
            else blk: {
                const upper_conductivity = harmonicMean(
                    conductivity_w_per_m_k[cell - 1],
                    conductivity_w_per_m_k[cell],
                );
                break :blk upper_conductivity *
                    (temperature_k[cell - 1] - temperature_k[cell]) /
                    options.cell_thickness_m;
            };
            const lower_flux_w_per_m2 =
                if (cell + 1 == options.cell_count)
                    conductivity_w_per_m_k[cell] *
                        (parameters.initial_temperature_c -
                            (temperature_k[cell] - 273.15)) /
                        (0.5 * options.cell_thickness_m)
                else blk: {
                    const lower_conductivity = harmonicMean(
                        conductivity_w_per_m_k[cell],
                        conductivity_w_per_m_k[cell + 1],
                    );
                    break :blk lower_conductivity *
                        (temperature_k[cell + 1] - temperature_k[cell]) /
                        options.cell_thickness_m;
                };
            next_enthalpy_j_per_m3[cell] =
                enthalpy_j_per_m3[cell] +
                options.time_step_s *
                    (upper_flux_w_per_m2 + lower_flux_w_per_m2) /
                    options.cell_thickness_m;
        }
        @memcpy(enthalpy_j_per_m3, next_enthalpy_j_per_m3);
    }
    for (0..options.cell_count) |cell| {
        const state = phaseStateFromEnthalpy(
            enthalpy_j_per_m3[cell],
            parameters,
            latent_heat_j_per_m3,
            unfrozen_volumetric_heat_capacity_j_per_m3_k,
        );
        temperature_k[cell] = state.temperature_k;
        ice_fraction[cell] = state.ice_fraction;
    }
    return .{
        .allocator = allocator,
        .cell_midpoint_depth_m = depths,
        .temperature_k = temperature_k,
        .ice_water_equivalent_fraction = ice_fraction,
    };
}

const EnthalpyPhaseState = struct {
    temperature_k: f64,
    ice_fraction: f64,
};

fn phaseStateFromEnthalpy(
    enthalpy_j_per_m3: f64,
    parameters: Parameters,
    latent_heat_j_per_m3: f64,
    unfrozen_volumetric_heat_capacity_j_per_m3_k: f64,
) EnthalpyPhaseState {
    if (enthalpy_j_per_m3 < 0) return .{
        .temperature_k = parameters.melting_temperature_c + 273.15 +
            enthalpy_j_per_m3 /
                parameters.frozen_volumetric_heat_capacity_j_per_m3_k,
        .ice_fraction = 1,
    };
    if (enthalpy_j_per_m3 <= latent_heat_j_per_m3) return .{
        .temperature_k = parameters.melting_temperature_c + 273.15,
        .ice_fraction = 1.0 -
            enthalpy_j_per_m3 / latent_heat_j_per_m3,
    };
    return .{
        .temperature_k = parameters.melting_temperature_c + 273.15 +
            (enthalpy_j_per_m3 - latent_heat_j_per_m3) /
                unfrozen_volumetric_heat_capacity_j_per_m3_k,
        .ice_fraction = 0,
    };
}

fn harmonicMean(first: f64, second: f64) f64 {
    return 2.0 * first * second / (first + second);
}

pub fn compareProfile(
    solution: SimilaritySolution,
    elapsed_time_s: f64,
    cell_midpoint_depth_m: []const f64,
    simulated_temperature_k: []const f64,
    simulated_ice_water_equivalent_fraction: []const f64,
    frozen_fraction_threshold: f64,
) !ProfileMetrics {
    const count = cell_midpoint_depth_m.len;
    if (count == 0 or simulated_temperature_k.len != count or
        simulated_ice_water_equivalent_fraction.len != count)
        return error.StefanProfileDimensionMismatch;
    if (!std.math.isFinite(frozen_fraction_threshold) or
        frozen_fraction_threshold <= 0 or frozen_fraction_threshold >= 1)
        return error.InvalidStefanFrozenThreshold;
    var squared_error_sum: f64 = 0;
    var maximum_error: f64 = 0;
    var simulated_interface_depth_m: f64 = 0;
    var found_frozen = false;
    var previous_depth_m: f64 = -1;
    for (cell_midpoint_depth_m, simulated_temperature_k, simulated_ice_water_equivalent_fraction) |depth_m, temperature_k, ice_fraction| {
        if (!std.math.isFinite(depth_m) or depth_m < 0 or
            depth_m <= previous_depth_m or
            !std.math.isFinite(temperature_k) or temperature_k <= 0 or
            !std.math.isFinite(ice_fraction) or
            ice_fraction < 0 or ice_fraction > 1)
            return error.InvalidStefanProfileValue;
        previous_depth_m = depth_m;
        const analytical_temperature_k =
            try solution.temperatureC(elapsed_time_s, depth_m) + 273.15;
        const error_k = temperature_k - analytical_temperature_k;
        squared_error_sum += error_k * error_k;
        maximum_error = @max(maximum_error, @abs(error_k));
        if (ice_fraction >= frozen_fraction_threshold) {
            simulated_interface_depth_m = depth_m;
            found_frozen = true;
        }
    }
    if (!found_frozen) simulated_interface_depth_m = 0;
    const analytical_interface_depth_m =
        try solution.interfaceDepthM(elapsed_time_s);
    return .{
        .root_mean_square_temperature_error_k = @sqrt(squared_error_sum / @as(f64, @floatFromInt(count))),
        .maximum_absolute_temperature_error_k = maximum_error,
        .analytical_interface_depth_m = analytical_interface_depth_m,
        .simulated_interface_depth_m = simulated_interface_depth_m,
        .absolute_interface_depth_error_m = @abs(simulated_interface_depth_m - analytical_interface_depth_m),
    };
}

pub fn solveSimilarityParameter(
    parameters: Parameters,
    maximum_iterations: u16,
    residual_tolerance: f64,
) !SimilaritySolution {
    try parameters.validate();
    if (maximum_iterations == 0 or !std.math.isFinite(residual_tolerance) or
        residual_tolerance <= 0)
        return error.InvalidStefanSolverOption;
    var lower: f64 = 1.0e-4;
    var upper: f64 = 0.01;
    var lower_residual = similarityResidual(parameters, lower);
    if (!std.math.isFinite(lower_residual))
        return error.StefanSimilarityRootNotBracketed;
    var upper_residual = similarityResidual(parameters, upper);
    while (std.math.isFinite(upper_residual) and
        lower_residual * upper_residual > 0 and upper < 2)
    {
        upper *= 2;
        upper_residual = similarityResidual(parameters, upper);
    }
    if (!std.math.isFinite(upper_residual) or
        lower_residual * upper_residual > 0)
        return error.StefanSimilarityRootNotBracketed;
    var iteration: u16 = 0;
    while (iteration < maximum_iterations) : (iteration += 1) {
        const midpoint = 0.5 * (lower + upper);
        const midpoint_residual = similarityResidual(parameters, midpoint);
        if (!std.math.isFinite(midpoint_residual))
            return error.NonFiniteStefanSimilarityResidual;
        if (@abs(midpoint_residual) <= residual_tolerance or
            upper - lower <= residual_tolerance)
            return .{
                .parameters = parameters,
                .similarity_parameter = midpoint,
            };
        if (lower_residual * midpoint_residual <= 0) {
            upper = midpoint;
        } else {
            lower = midpoint;
            lower_residual = midpoint_residual;
        }
    }
    return error.StefanSimilaritySolverDidNotConverge;
}

fn similarityResidual(parameters: Parameters, similarity_parameter: f64) f64 {
    const diffusivity_ratio =
        parameters.frozen_thermal_diffusivity_m2_per_s /
        parameters.unfrozen_thermal_diffusivity_m2_per_s;
    const frozen_term = @exp(-similarity_parameter * similarity_parameter) /
        (similarity_parameter * errorFunction(similarity_parameter));
    const unfrozen_term =
        parameters.unfrozen_thermal_conductivity_w_per_m_k *
        @sqrt(parameters.frozen_thermal_diffusivity_m2_per_s) *
        (parameters.initial_temperature_c - parameters.melting_temperature_c) *
        @exp(-diffusivity_ratio * similarity_parameter * similarity_parameter) /
        (parameters.frozen_thermal_conductivity_w_per_m_k *
            @sqrt(parameters.unfrozen_thermal_diffusivity_m2_per_s) *
            (parameters.melting_temperature_c -
                parameters.surface_temperature_c) *
            similarity_parameter *
            complementaryErrorFunction(similarity_parameter * @sqrt(diffusivity_ratio)));
    const latent_term =
        parameters.latent_heat_of_fusion_j_per_kg *
        parameters.water_density_kg_per_m3 *
        parameters.saturated_water_content_m3_per_m3 *
        @sqrt(std.math.pi) /
        (parameters.frozen_volumetric_heat_capacity_j_per_m3_k *
            (parameters.melting_temperature_c -
                parameters.surface_temperature_c));
    return frozen_term - unfrozen_term - latent_term;
}

// Stable complementary-error-function approximation from the standard
// rational form used for heat-diffusion similarity solutions. Keeping this
// local avoids a platform libm dependency, which Zig 0.16's std.math does not
// expose for erf/erfc.
fn complementaryErrorFunction(value: f64) f64 {
    const absolute = @abs(value);
    const t = 1.0 / (1.0 + 0.5 * absolute);
    const tau = t * @exp(
        -absolute * absolute - 1.26551223 +
            t * (1.00002368 +
                t * (0.37409196 +
                    t * (0.09678418 +
                        t * (-0.18628806 +
                            t * (0.27886807 +
                                t * (-1.13520398 +
                                    t * (1.48851587 +
                                        t * (-0.82215223 +
                                            t * 0.17087277)))))))),
    );
    return if (value >= 0) tau else 2.0 - tau;
}

fn errorFunction(value: f64) f64 {
    if (value == 0) return 0;
    return 1.0 - complementaryErrorFunction(value);
}

test "Appendix C Stefan solution satisfies boundaries and moving interface" {
    const solution = try solveSimilarityParameter(.{}, 100, 1e-12);
    const elapsed_time_s = 15.0 * 86_400.0;
    const interface_depth_m = try solution.interfaceDepthM(elapsed_time_s);
    try std.testing.expect(interface_depth_m > 0);
    try std.testing.expectApproxEqAbs(
        @as(f64, -5),
        try solution.temperatureC(elapsed_time_s, 0),
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        try solution.temperatureC(elapsed_time_s, interface_depth_m),
        1e-10,
    );
    try std.testing.expect(
        try solution.temperatureC(elapsed_time_s, 5) > 1.9,
    );
}

test "Appendix C interface follows square root of elapsed time" {
    const solution = try solveSimilarityParameter(.{}, 100, 1e-12);
    const first = try solution.interfaceDepthM(15 * 86_400);
    const second = try solution.interfaceDepthM(60 * 86_400);
    try std.testing.expectApproxEqRel(2.0 * first, second, 1e-14);
}

test "Stefan profile gate reports temperature and interface errors explicitly" {
    const solution = try solveSimilarityParameter(.{}, 100, 1e-12);
    const elapsed_time_s = 15.0 * 86_400.0;
    var depths: [50]f64 = undefined;
    var temperatures_k: [depths.len]f64 = undefined;
    var ice_fraction: [depths.len]f64 = undefined;
    const analytical_interface =
        try solution.interfaceDepthM(elapsed_time_s);
    for (0..depths.len) |index| {
        depths[index] = 0.005 + 0.01 * @as(f64, @floatFromInt(index));
        const depth_m = depths[index];
        temperatures_k[index] =
            try solution.temperatureC(elapsed_time_s, depth_m) + 273.15;
        ice_fraction[index] = if (depth_m <= analytical_interface) 1 else 0;
    }
    const metrics = try compareProfile(
        solution,
        elapsed_time_s,
        &depths,
        &temperatures_k,
        &ice_fraction,
        0.5,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        metrics.root_mean_square_temperature_error_k,
        1e-14,
    );
    // A cell-centred interface estimate is bounded by one 10 mm cell.
    try std.testing.expect(metrics.absolute_interface_depth_error_m <= 0.01);
}

test "runtime enthalpy column tracks the Appendix C front without phase cycling" {
    const parameters: Parameters = .{};
    const elapsed_time_s = 86_400.0;
    var profile = try simulatePureWaterColumn(
        std.testing.allocator,
        parameters,
        .{
            .cell_count = 100,
            .cell_thickness_m = 0.01,
            .time_step_s = 10,
            .elapsed_time_s = elapsed_time_s,
        },
    );
    defer profile.deinit();
    const analytical = try solveSimilarityParameter(parameters, 100, 1e-12);
    const metrics = try compareProfile(
        analytical,
        elapsed_time_s,
        profile.cell_midpoint_depth_m,
        profile.temperature_k,
        profile.ice_water_equivalent_fraction,
        0.5,
    );
    try std.testing.expect(metrics.root_mean_square_temperature_error_k < 0.2);
    try std.testing.expect(metrics.maximum_absolute_temperature_error_k < 1.0);
    try std.testing.expect(metrics.absolute_interface_depth_error_m <= 0.02);
}

test "published 500-cell Appendix C column passes all reported checkpoints" {
    const parameters: Parameters = .{};
    const analytical = try solveSimilarityParameter(parameters, 100, 1e-12);
    // Dall'Amico et al. Sect. 7.1 reports profiles at 0, 3, 15, 40, and
    // 75 days.
    var initial_profile = try simulatePureWaterColumn(
        std.testing.allocator,
        parameters,
        .{
            .cell_count = 500,
            .cell_thickness_m = 0.01,
            .time_step_s = 10,
            .elapsed_time_s = 0,
        },
    );
    defer initial_profile.deinit();
    for (initial_profile.temperature_k, initial_profile.ice_water_equivalent_fraction) |temperature_k, ice_fraction| {
        try std.testing.expectApproxEqAbs(
            parameters.initial_temperature_c + 273.15,
            temperature_k,
            1.0e-14,
        );
        try std.testing.expectEqual(@as(f64, 0), ice_fraction);
    }
    const checkpoint_days = [_]f64{ 3, 15, 40, 75 };
    for (checkpoint_days) |elapsed_days| {
        const elapsed_time_s = elapsed_days * 86_400.0;
        var profile = try simulatePureWaterColumn(
            std.testing.allocator,
            parameters,
            .{
                .cell_count = 500,
                .cell_thickness_m = 0.01,
                .time_step_s = 10,
                .elapsed_time_s = elapsed_time_s,
            },
        );
        defer profile.deinit();
        const metrics = try compareProfile(
            analytical,
            elapsed_time_s,
            profile.cell_midpoint_depth_m,
            profile.temperature_k,
            profile.ice_water_equivalent_fraction,
            // The Stefan interface is the deepest onset of ice, rather than
            // the midpoint of the numerically smeared latent-heat cell.
            1.0e-6,
        );
        if (metrics.root_mean_square_temperature_error_k >= 0.1 or
            metrics.maximum_absolute_temperature_error_k >= 1.0 or
            metrics.absolute_interface_depth_error_m > 0.02)
        {
            std.log.err(
                "Appendix C checkpoint failed: days={d} rmse_k={e} max_error_k={e} analytical_front_m={e} simulated_front_m={e} front_error_m={e}",
                .{
                    elapsed_days,
                    metrics.root_mean_square_temperature_error_k,
                    metrics.maximum_absolute_temperature_error_k,
                    metrics.analytical_interface_depth_m,
                    metrics.simulated_interface_depth_m,
                    metrics.absolute_interface_depth_error_m,
                },
            );
        }
        try std.testing.expect(metrics.root_mean_square_temperature_error_k < 0.1);
        try std.testing.expect(metrics.maximum_absolute_temperature_error_k < 1.0);
        try std.testing.expect(metrics.absolute_interface_depth_error_m <= 0.02);
    }
}

test "production Dall'Amico constitutive path resolves the Appendix C ice front" {
    const cell_count = 500;
    const cell_thickness_m = 0.01;
    const elapsed_time_s = 75.0 * 86_400.0;
    const parameters: Parameters = .{};
    const analytical = try solveSimilarityParameter(parameters, 100, 1e-12);
    const depths = try std.testing.allocator.alloc(f64, cell_count);
    defer std.testing.allocator.free(depths);
    const temperatures_k = try std.testing.allocator.alloc(f64, cell_count);
    defer std.testing.allocator.free(temperatures_k);
    const ice_fraction = try std.testing.allocator.alloc(f64, cell_count);
    defer std.testing.allocator.free(ice_fraction);
    const production_retention: retention.MualemVanGenuchtenParameters = .{
        .residual_water_content_m3_per_m3 = 0,
        .saturated_water_content_m3_per_m3 = 1,
        .alpha_per_m = 400,
        .n = 2.5,
        .saturated_hydraulic_conductivity_m_per_h = 1,
    };
    for (0..cell_count) |cell| {
        depths[cell] =
            (@as(f64, @floatFromInt(cell)) + 0.5) * cell_thickness_m;
        temperatures_k[cell] =
            try analytical.temperatureC(elapsed_time_s, depths[cell]) + 273.15;
        const equilibrium = try phase_change.dallAmicoEquilibrium(.{
            .temperature_k = temperatures_k[cell],
            .total_water_equivalent_m3 = cell_thickness_m,
            .porous_medium_volume_m3 = cell_thickness_m,
            .unfrozen_pressure_head_m = 0,
            .gravitational_water_potential_mpa_per_m = 0.00980665,
            .latent_heat_of_fusion_megajoules_per_m3 = 333.7,
            .pure_water_melting_temperature_k = 273.15,
            .mualem_van_genuchten = production_retention,
        });
        ice_fraction[cell] =
            equilibrium.ice_water_equivalent_m3 / cell_thickness_m;
    }
    const metrics = try compareProfile(
        analytical,
        elapsed_time_s,
        depths,
        temperatures_k,
        ice_fraction,
        1.0e-6,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        metrics.root_mean_square_temperature_error_k,
        1.0e-14,
    );
    try std.testing.expect(metrics.absolute_interface_depth_error_m <=
        cell_thickness_m);
}

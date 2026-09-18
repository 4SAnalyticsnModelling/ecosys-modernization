// **A8a DISPOSITION: SUPERSEDED BY BOUND OWNER, gap closed.**
//
// `uptake.f` 2173--2235, the demand-limited quadratic root oxygen uptake solve.
// This is the one module of the twelve in this source range that is not
// superseded. Oxygen is deliberately absent from `non_oxygen_gases`
// (`plant_root_gas_transport.zig:159`) because the source does not treat it as a
// passive tracer: its uptake draws down the soil aqueous and root aqueous pools
// competitively and its result feeds the `WFR` constraint that gates
// respiration. ecosys-ng mirrored that correctly by writing
// `plant_root_gas_exchange.solveOxygenUptake` (`:483`) and `state_updateOxygenUptake`
// (`:538`) as a dedicated path. Both are now called by
// `plant_root_gas_transport.advanceOxygen`, itself called from
// `stages/hourly_vegetation.zig` before root metabolism. This statement-shaped
// port remains an independent reference regression and must not be called as a
// second, duplicate oxygen solve.
//
// UPTAKE-RECONCILE-1872-2600 group of docs/traceability/a7b_reconcile_root_gas_cluster.md
const std = @import("std");
const numerics = @import("../../core/numerics.zig");

pub const Inputs = struct {
    soil_aqueous_oxygen_g_o: f64,
    preceding_soil_oxygen_aqueous_flux_g_o_per_step: f64,
    soil_oxygen_allocated_water_volume_m3: f64,
    root_aqueous_oxygen_g_o: f64,
    root_aqueous_volume_m3: f64,
    equilibrium_oxygen_concentration_g_o_per_m3: f64,
    soil_to_root_diffusivity_m3_per_step: f64,
    internal_root_diffusivity_m3_per_step: f64,
    root_water_uptake_m3_per_step: f64,
    oxygen_demand_per_plant_g_o_per_step: f64,
    oxygen_half_saturation_g_o_per_m3: f64,
    negligible_oxygen_g_o: f64,
    oxygen_competition_fraction: f64,
    plant_population: f64,
};

pub const SolverPolicy = struct {
    maximum_iterations: u16,
    absolute_tolerance_g_o_per_step: f64,
    relative_tolerance: f64,
    picard_relaxation: f64,
};

pub const Result = struct {
    soil_oxygen_concentration_g_o_per_m3: f64,
    root_oxygen_concentration_g_o_per_m3: f64,
    root_surface_oxygen_concentration_g_o_per_m3: f64,
    oxygen_uptake_per_plant_g_o_per_step: f64,
    soil_to_root_oxygen_flux_g_o_per_step: f64,
    internal_root_oxygen_flux_g_o_per_step: f64,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
};

const Quadratic = struct {
    b: f64,
    c: f64,
};

/// UPTAKE.F 2173--2235 oxygen residual, replacing the legacy nested NPT/NPH
/// cycles with a local Newton-Raphson/Picard solve bounded by runtime NPH.
pub fn solve(inputs: Inputs, policy: SolverPolicy) !Result {
    try validate(inputs, policy);
    const soil_amount =
        inputs.soil_aqueous_oxygen_g_o +
        inputs.preceding_soil_oxygen_aqueous_flux_g_o_per_step;
    const soil_concentration =
        if (inputs.soil_oxygen_allocated_water_volume_m3 > 0)
            @min(
                inputs.equilibrium_oxygen_concentration_g_o_per_m3,
                @max(
                    0,
                    soil_amount /
                        inputs.soil_oxygen_allocated_water_volume_m3,
                ),
            )
        else
            0;
    const root_concentration = @min(
        inputs.equilibrium_oxygen_concentration_g_o_per_m3,
        @max(
            0,
            inputs.root_aqueous_oxygen_g_o /
                inputs.root_aqueous_volume_m3,
        ),
    );
    const combined_diffusivity =
        inputs.soil_to_root_diffusivity_m3_per_step +
        inputs.internal_root_diffusivity_m3_per_step;
    var x =
        (inputs.soil_to_root_diffusivity_m3_per_step +
            inputs.root_water_uptake_m3_per_step) *
        soil_concentration +
        inputs.internal_root_diffusivity_m3_per_step *
            root_concentration;
    var soil_flux: f64 = 0;
    var internal_flux: f64 = 0;
    var root_surface_concentration: f64 = 0;
    var solved: ?numerics.SolveResult = null;

    if (x > 0 and soil_amount > inputs.negligible_oxygen_g_o and
        combined_diffusivity > 0)
    {
        const quadratic = Quadratic{
            .b = -inputs.oxygen_demand_per_plant_g_o_per_step -
                combined_diffusivity *
                    inputs.oxygen_half_saturation_g_o_per_m3 -
                x,
            .c = x * inputs.oxygen_demand_per_plant_g_o_per_step,
        };
        solved = try solveQuadratic(quadratic, inputs, policy, x);
        root_surface_concentration =
            (x - solved.?.root) / combined_diffusivity;
        soil_flux =
            inputs.root_water_uptake_m3_per_step * soil_concentration +
            inputs.soil_to_root_diffusivity_m3_per_step *
                (soil_concentration - root_surface_concentration);
        internal_flux =
            inputs.internal_root_diffusivity_m3_per_step *
            (root_concentration - root_surface_concentration);
    } else {
        x = inputs.internal_root_diffusivity_m3_per_step *
            root_concentration;
        if (x > 0 and
            inputs.root_aqueous_oxygen_g_o >
                inputs.negligible_oxygen_g_o and
            inputs.internal_root_diffusivity_m3_per_step > 0)
        {
            const quadratic = Quadratic{
                .b = -inputs.oxygen_demand_per_plant_g_o_per_step -
                    inputs.internal_root_diffusivity_m3_per_step *
                        inputs.oxygen_half_saturation_g_o_per_m3 -
                    x,
                .c = x * inputs.oxygen_demand_per_plant_g_o_per_step,
            };
            solved = try solveQuadratic(quadratic, inputs, policy, x);
            root_surface_concentration =
                (x - solved.?.root) /
                inputs.internal_root_diffusivity_m3_per_step;
            internal_flux = @min(
                @max(
                    0,
                    inputs.oxygen_competition_fraction *
                        inputs.root_aqueous_oxygen_g_o /
                        inputs.plant_population,
                ),
                inputs.internal_root_diffusivity_m3_per_step *
                    (root_concentration - root_surface_concentration),
            );
        }
    }
    const uptake = if (solved) |value| value.root else 0;
    inline for (.{
        soil_concentration,
        root_concentration,
        root_surface_concentration,
        uptake,
        soil_flux,
        internal_flux,
    }) |value|
        if (!std.math.isFinite(value))
            return error.NonFiniteRootOxygenUptakeResult;
    return .{
        .soil_oxygen_concentration_g_o_per_m3 = soil_concentration,
        .root_oxygen_concentration_g_o_per_m3 = root_concentration,
        .root_surface_oxygen_concentration_g_o_per_m3 = root_surface_concentration,
        .oxygen_uptake_per_plant_g_o_per_step = uptake,
        .soil_to_root_oxygen_flux_g_o_per_step = soil_flux,
        .internal_root_oxygen_flux_g_o_per_step = internal_flux,
        .iterations = if (solved) |value| value.iterations else 0,
        .newton_raphson_steps = if (solved) |value| value.newton_raphson_steps else 0,
        .picard_steps = if (solved) |value| value.picard_steps else 0,
    };
}

fn solveQuadratic(
    quadratic: Quadratic,
    inputs: Inputs,
    policy: SolverPolicy,
    scale: f64,
) !numerics.SolveResult {
    const Functions = struct {
        fn residual(context: Quadratic, uptake: f64) f64 {
            return uptake * uptake + context.b * uptake + context.c;
        }
        fn derivative(context: Quadratic, uptake: f64) f64 {
            return 2 * uptake + context.b;
        }
        fn picard(context: Quadratic, uptake: f64) f64 {
            const denominator = -context.b - uptake;
            return if (denominator > 0) context.c / denominator else 0;
        }
    };
    const upper = @max(
        inputs.oxygen_demand_per_plant_g_o_per_step,
        scale,
    );
    if (upper <= 0) return error.InvalidRootOxygenUptakeBounds;
    return numerics.newtonPicard(
        quadratic,
        Functions.residual,
        Functions.derivative,
        Functions.picard,
        0,
        upper,
        0,
        .{
            .max_iterations = policy.maximum_iterations,
            .absolute_tolerance = policy.absolute_tolerance_g_o_per_step,
            .relative_tolerance = policy.relative_tolerance,
            .picard_relaxation = policy.picard_relaxation,
            .residual_scale = @max(upper * upper, 1e-30),
            .safeguard_with_bracket = true,
        },
    );
}

fn validate(inputs: Inputs, policy: SolverPolicy) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.InvalidRootOxygenUptakeInput;
    inline for (.{
        policy.absolute_tolerance_g_o_per_step,
        policy.relative_tolerance,
        policy.picard_relaxation,
    }) |value|
        if (!std.math.isFinite(value))
            return error.InvalidRootOxygenUptakePolicy;
    if (inputs.soil_aqueous_oxygen_g_o < 0 or
        inputs.soil_oxygen_allocated_water_volume_m3 < 0 or
        inputs.root_aqueous_oxygen_g_o < 0 or
        inputs.root_aqueous_volume_m3 <= 0 or
        inputs.equilibrium_oxygen_concentration_g_o_per_m3 < 0 or
        inputs.soil_to_root_diffusivity_m3_per_step < 0 or
        inputs.internal_root_diffusivity_m3_per_step < 0 or
        inputs.oxygen_demand_per_plant_g_o_per_step < 0 or
        inputs.oxygen_half_saturation_g_o_per_m3 < 0 or
        inputs.negligible_oxygen_g_o < 0 or
        inputs.oxygen_competition_fraction < 0 or
        inputs.plant_population <= 0 or
        policy.maximum_iterations == 0 or
        policy.absolute_tolerance_g_o_per_step <= 0 or
        policy.relative_tolerance <= 0 or
        policy.picard_relaxation <= 0 or
        policy.picard_relaxation > 1)
        return error.InvalidRootOxygenUptakeInput;
}

fn sourceInputs() Inputs {
    return .{
        .soil_aqueous_oxygen_g_o = 4,
        .preceding_soil_oxygen_aqueous_flux_g_o_per_step = 0,
        .soil_oxygen_allocated_water_volume_m3 = 2,
        .root_aqueous_oxygen_g_o = 1,
        .root_aqueous_volume_m3 = 1,
        .equilibrium_oxygen_concentration_g_o_per_m3 = 10,
        .soil_to_root_diffusivity_m3_per_step = 0.5,
        .internal_root_diffusivity_m3_per_step = 0.25,
        .root_water_uptake_m3_per_step = 0.1,
        .oxygen_demand_per_plant_g_o_per_step = 0.8,
        .oxygen_half_saturation_g_o_per_m3 = 0.2,
        .negligible_oxygen_g_o = 1e-12,
        .oxygen_competition_fraction = 0.4,
        .plant_population = 2,
    };
}

fn testPolicy(maximum_iterations: u16) SolverPolicy {
    return .{
        .maximum_iterations = maximum_iterations,
        .absolute_tolerance_g_o_per_step = 1e-12,
        .relative_tolerance = 1e-10,
        .picard_relaxation = 0.5,
    };
}

test "manufactured quadratic oxygen uptake converges before runtime NPH" {
    const inputs = sourceInputs();
    const result = try solve(inputs, testPolicy(30));
    const combined =
        inputs.soil_to_root_diffusivity_m3_per_step +
        inputs.internal_root_diffusivity_m3_per_step;
    const x =
        (inputs.soil_to_root_diffusivity_m3_per_step +
            inputs.root_water_uptake_m3_per_step) * 2 +
        inputs.internal_root_diffusivity_m3_per_step * 1;
    const b = -inputs.oxygen_demand_per_plant_g_o_per_step -
        combined * inputs.oxygen_half_saturation_g_o_per_m3 - x;
    const c = x * inputs.oxygen_demand_per_plant_g_o_per_step;
    const residual =
        result.oxygen_uptake_per_plant_g_o_per_step *
        result.oxygen_uptake_per_plant_g_o_per_step +
        b * result.oxygen_uptake_per_plant_g_o_per_step + c;
    try std.testing.expectApproxEqAbs(@as(f64, 0), residual, 1e-10);
    try std.testing.expect(result.iterations < 30);
}

test "runtime NPH exhaustion reports nonconvergence" {
    try std.testing.expectError(
        error.NewtonPicardDidNotConverge,
        solve(sourceInputs(), testPolicy(1)),
    );
}

test "zero oxygen domain exits without nonlinear iterations" {
    var inputs = sourceInputs();
    inputs.soil_aqueous_oxygen_g_o = 0;
    inputs.root_aqueous_oxygen_g_o = 0;
    const result = try solve(inputs, testPolicy(30));
    try std.testing.expectEqual(@as(f64, 0), result.oxygen_uptake_per_plant_g_o_per_step);
    try std.testing.expectEqual(@as(u16, 0), result.iterations);
}

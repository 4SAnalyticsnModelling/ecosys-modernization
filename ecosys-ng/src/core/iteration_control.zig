const std = @import("std");
const SceneOptions = @import("options.zig").SceneOptions;

/// Runtime nonlinear iteration ceilings derived from the old sub-hour control
/// record. They are convergence budgets only: ecosys-ng never repeats a full
/// model cycle to consume the budget.
pub const Limits = struct {
    /// User runtime ceiling. Every process-specific/legacy budget is clamped to
    /// this value; it is never raised by a legacy minimum or derived product.
    hard_max_iterations: u16,
    water_heat_solute_max_iterations: u16,
    /// EROSION NPH: local suspended-sediment convergence.
    erosion_max_iterations: u16,
    gas_max_iterations: u16,
    /// REDIST dissolved-organic transport convergence.
    ///
    /// Floor of 100, per the project owner's iteration-floor policy. This
    /// previously shared the `water_heat_solute` ceiling of 20, which is not
    /// enough when a near-empty pool sits beside a large aqueous boundary
    /// transfer: the Ottawa example produced an `8.37e-6` g residual on a
    /// `1.43e-15` g pool while that hour moved `8.367e6` g across the boundary,
    /// and Newton accepted no step in 20 iterations. The fixed point is
    /// reachable, just slowly, so the ceiling does have to exceed 20.
    ///
    /// It was then set to 2000, which is a different error: a budget that large
    /// stops being a convergence ceiling and becomes a licence to grind on a
    /// residual that a whole-step solver should reach directly. 100 is the
    /// policy value. If a real deck cannot converge organic transport within
    /// 100 iterations, that is a defect in the residual or its scaling and must
    /// be fixed there rather than absorbed by raising this number again.
    organic_transport_max_iterations: u16 = 100,
    /// WTHR NPR: litter/surface water and heat convergence.
    litter_water_heat_max_iterations: u16 = 30,
    /// WTHR NPS: snow water and heat convergence.
    snowpack_max_iterations: u16 = 20,
    litter_under_snow_max_iterations: u16 = 10,
    /// SOLUTE MRXN: profile and surface-litter reaction equilibrium.
    solute_reaction_max_iterations: u16 = 60,
    /// STARTE MRXN: initial reaction-equilibrium establishment.
    initial_solute_reaction_max_iterations: u16 = 1000,
    canopy_energy_water_max_iterations: u16 = 100,
    leaf_co2_max_iterations: u16 = 100,

    pub fn fromSceneOptions(options: SceneOptions, hard_max_iterations: u16) !Limits {
        if (hard_max_iterations == 0) return error.ZeroNonlinearIterationLimit;
        const gas_iterations = try std.math.mul(u32, options.water_heat_solute_iteration_limit, options.gas_iterations_per_water_heat_solute_iteration);
        if (gas_iterations == 0) return error.ZeroNonlinearIterationLimit;
        // Floor of 100, per the project owner's iteration-floor policy:
        // gas_max_iterations = max(100, NPH*NPG). NPH*NPG is typically 80, so
        // on a default deck the floor is what binds.
        //
        // History, kept because it is the reason a floor exists at all: this was
        // 1000, justified by trace-gas species (NH3, H2) in partially frozen
        // soil where masses fall below 1 microgram, the tolerance floor
        // dominates, and the NH3 case at day 20 converged at ~0.37% per Newton
        // step from scaled_residual ~= 4.6, needing ~613 iterations. Under the
        // whole-step design a budget of 1000 is not a convergence ceiling, it is
        // a licence to grind, and a species needing 613 iterations is evidence
        // of a badly scaled residual at sub-microgram masses. If that case
        // regresses, fix the scaling; do not restore 1000.
        const minimum_gas_iterations: u16 = 100;
        // Floor of 100 for the water/heat/solute solve, same policy and the
        // same reason as the gas ceiling above.
        //
        // `water_heat_solute_iteration_limit` is the legacy NPH: a SUB-HOURLY
        // CYCLE COUNT, describing how many times legacy repeated the transport
        // cycle within an hour. ecosys-ng does not repeat the model cycle -- it
        // performs one whole-hour nonlinear solve -- so using NPH as that
        // solve's Newton budget is the category error already documented for
        // `standingDeadEnergyMaxIterations` below: "wrong in kind, not merely
        // in size", a ceiling scaled by a number that no longer describes
        // anything the solver does.
        //
        // Measured on the Ottawa deck at day 90, hour 2140: the matrix water
        // solve converges monotonically -- norm_trace falls 4.06e7 -> 1.02e6
        // across all 21 recorded entries, roughly 1.19x per step -- and simply
        // exhausts NPH=20 with about 80 steps still needed, then fails as
        // `soil water nonlinear ceiling exhausted` with
        // `scaled_residual=1.02e6`. It is not stalling or oscillating; it runs
        // out of budget.
        //
        // This changes no convergence criterion. It is also a FLOOR, not a
        // replacement: a deck that explicitly asks for more than 100 still
        // gets what it asked for, and `hard_max_iterations` still caps
        // everything.
        const minimum_water_heat_solute_iterations: u16 = 100;
        return .{
            .hard_max_iterations = hard_max_iterations,
            .water_heat_solute_max_iterations = @min(
                hard_max_iterations,
                @max(minimum_water_heat_solute_iterations, options.water_heat_solute_iteration_limit),
            ),
            .erosion_max_iterations = @min(hard_max_iterations, options.water_heat_solute_iteration_limit),
            .gas_max_iterations = @min(hard_max_iterations, @as(u16, @intCast(@min(@as(u32, std.math.maxInt(u16)), @max(@as(u32, minimum_gas_iterations), gas_iterations))))),
            .organic_transport_max_iterations = @min(hard_max_iterations, 100),
            .litter_water_heat_max_iterations = @min(hard_max_iterations, 30),
            .snowpack_max_iterations = @min(hard_max_iterations, 20),
            .litter_under_snow_max_iterations = @min(hard_max_iterations, 10),
            .solute_reaction_max_iterations = @min(hard_max_iterations, 60),
            .initial_solute_reaction_max_iterations = @min(hard_max_iterations, 1000),
            .canopy_energy_water_max_iterations = @min(hard_max_iterations, 100),
            .leaf_co2_max_iterations = @min(hard_max_iterations, 100),
        };
    }

    /// UPTAKE standing-dead energy used an outer NPH cycle and an inner MXN
    /// solve. ecosys-ng does not repeat the model cycle, so this is a flat 100
    /// rather than the legacy product NPH*MXN.
    ///
    /// The product was wrong in kind, not merely in size. Multiplying by NPH
    /// carried the sub-hourly cycle count into a budget for what is now a single
    /// whole-hour nonlinear solve, so the ceiling scaled with a number that no
    /// longer describes anything the solver does, and it moved whenever an
    /// unrelated option changed. A flat 100 is independent of NPH, which is the
    /// point. The error union is retained so call sites are unchanged.
    pub fn standingDeadEnergyMaxIterations(self: Limits) !u16 {
        return @min(self.hard_max_iterations, 100);
    }
};

/// Validates the legacy low-heat-capacity inputs without raising the caller's
/// requested nonlinear budget. Difficult thermal states are recovered by the
/// fixed-hour internal substep schedule; a state-dependent minimum would turn
/// `base_nph` from a hard ceiling into a target.
pub fn waterHeatSoluteCeilingForCurrentState(base_nph: u16, hard_max_iterations: u16, heat_capacity_megajoules_per_k: []const f64, horizontal_area_m2: []const f64, is_top_soil_layer: []const bool) !u16 {
    if (base_nph == 0 or hard_max_iterations == 0) return error.ZeroNonlinearIterationLimit;
    if (heat_capacity_megajoules_per_k.len != horizontal_area_m2.len or heat_capacity_megajoules_per_k.len != is_top_soil_layer.len) return error.IterationControlDimensionMismatch;
    for (heat_capacity_megajoules_per_k, horizontal_area_m2, is_top_soil_layer) |heat_capacity, area, is_top| {
        if (!std.math.isFinite(heat_capacity) or heat_capacity < 0 or !std.math.isFinite(area) or area <= 0) return error.InvalidIterationControlThermalState;
        _ = is_top;
    }
    return @min(hard_max_iterations, base_nph);
}

test "legacy option controls become convergence ceilings" {
    const options = try @import("options.zig").parse(@import("test_fixtures.zig").scene_options_source);
    const limits = try Limits.fromSceneOptions(options, 1000);
    // The fixture's NPH is 20. The water/heat/solute solve now takes the
    // 100 floor, because NPH is a sub-hourly cycle count and not a Newton
    // budget for a whole-hour solve; see `fromSceneOptions`.
    try std.testing.expectEqual(@as(u16, 100), limits.water_heat_solute_max_iterations);
    // Erosion deliberately still tracks NPH: nothing has been measured to show
    // it is budget-starved, and raising a ceiling without evidence is how a
    // floor policy turns into a licence to grind.
    try std.testing.expectEqual(@as(u16, 20), limits.erosion_max_iterations);
    try std.testing.expectEqual(@as(u16, 100), limits.gas_max_iterations);
    try std.testing.expectEqual(@as(u16, 30), limits.litter_water_heat_max_iterations);
    try std.testing.expectEqual(@as(u16, 20), limits.snowpack_max_iterations);
    try std.testing.expectEqual(@as(u16, 10), limits.litter_under_snow_max_iterations);
    try std.testing.expectEqual(@as(u16, 60), limits.solute_reaction_max_iterations);
    try std.testing.expectEqual(@as(u16, 1000), limits.initial_solute_reaction_max_iterations);
    try std.testing.expectEqual(@as(u16, 100), limits.canopy_energy_water_max_iterations);
    try std.testing.expectEqual(@as(u16, 100), limits.leaf_co2_max_iterations);
    try std.testing.expectEqual(@as(u16, 100), try limits.standingDeadEnergyMaxIterations());
}

test "standing-dead energy ceiling is flat and independent of the legacy sub-step count" {
    // This replaces an earlier "rejects overflow" test. That test asserted
    // error.Overflow out of the NPH*MXN product, which was only reachable
    // because the ceiling was a product in the first place. A flat ceiling
    // cannot overflow, so the old assertion no longer describes any behaviour.
    //
    // The property worth pinning instead is the reason the product was removed:
    // ecosys-ng runs one whole-hour solve, so the standing-dead budget must not
    // move when the legacy sub-hour cycle count moves. Driving
    // water_heat_solute_max_iterations to its extreme must leave the ceiling at
    // 100, which the old product could never have satisfied.
    var limits = try Limits.fromSceneOptions(try @import("options.zig").parse(@import("test_fixtures.zig").scene_options_source), 1000);
    try std.testing.expectEqual(@as(u16, 100), try limits.standingDeadEnergyMaxIterations());
    limits.water_heat_solute_max_iterations = std.math.maxInt(u16);
    try std.testing.expectEqual(@as(u16, 100), try limits.standingDeadEnergyMaxIterations());
    limits.water_heat_solute_max_iterations = 1;
    limits.canopy_energy_water_max_iterations = 1;
    try std.testing.expectEqual(@as(u16, 100), try limits.standingDeadEnergyMaxIterations());
}

test "gas ceiling floors at 100 and still honours a larger NPH times NPG" {
    // Policy: gas_max_iterations = max(100, NPH*NPG). The default deck gives
    // NPH*NPG = 20*4 = 80, so the floor binds. A deck asking for more than 100
    // must still get what it asked for, otherwise the floor would silently
    // become a cap.
    var options = try @import("options.zig").parse(@import("test_fixtures.zig").scene_options_source);
    try std.testing.expectEqual(@as(u16, 100), (try Limits.fromSceneOptions(options, 1000)).gas_max_iterations);
    options.water_heat_solute_iteration_limit = 60;
    options.gas_iterations_per_water_heat_solute_iteration = 4;
    try std.testing.expectEqual(@as(u16, 240), (try Limits.fromSceneOptions(options, 1000)).gas_max_iterations);
}

test "low top-layer heat capacity never raises the requested ceiling" {
    try std.testing.expectEqual(@as(u16, 10), try waterHeatSoluteCeilingForCurrentState(10, 1000, &.{ 0.004, 3.0 }, &.{ 1.0, 1.0 }, &.{ true, false }));
    try std.testing.expectEqual(@as(u16, 10), try waterHeatSoluteCeilingForCurrentState(10, 1000, &.{ 0.005, 0.001 }, &.{ 1.0, 1.0 }, &.{ true, false }));
    try std.testing.expectEqual(@as(u16, 30), try waterHeatSoluteCeilingForCurrentState(30, 1000, &.{0.001}, &.{1.0}, &.{true}));
}

test "low heat-capacity threshold is strict and only triggers on top layers" {
    try std.testing.expectEqual(
        @as(u16, 4),
        try waterHeatSoluteCeilingForCurrentState(4, 1000, &.{4.19e-3}, &.{1.0}, &.{true}),
    );
    try std.testing.expectEqual(
        @as(u16, 4),
        try waterHeatSoluteCeilingForCurrentState(4, 1000, &.{ 4.19e-3, 0.001 }, &.{ 1.0, 1.0 }, &.{ false, true }),
    );
    try std.testing.expectEqual(
        @as(u16, 4),
        try waterHeatSoluteCeilingForCurrentState(4, 1000, &.{ 4.19e-3, 3.0 }, &.{ 1.0, 1.0 }, &.{ false, false }),
    );
}

test "water-heat ceiling rejects non-top-layer heat-capacity changes and dimensional mismatch" {
    try std.testing.expectEqual(@as(u16, 12), try waterHeatSoluteCeilingForCurrentState(12, 1000, &.{ 0.001, 0.001 }, &.{ 1.0, 2.0 }, &.{ false, false }));
    try std.testing.expectError(
        error.IterationControlDimensionMismatch,
        waterHeatSoluteCeilingForCurrentState(12, 1000, &.{0.004}, &.{1.0}, &.{ true, false }),
    );
    try std.testing.expectError(
        error.IterationControlDimensionMismatch,
        waterHeatSoluteCeilingForCurrentState(12, 1000, &.{ 0.004, 0.005 }, &.{ 1.0, 2.0 }, &.{true}),
    );
}

test "water-heat ceiling rejects invalid thermal control state" {
    try std.testing.expectError(
        error.InvalidIterationControlThermalState,
        waterHeatSoluteCeilingForCurrentState(12, 1000, &.{-0.01}, &.{1.0}, &.{true}),
    );
    try std.testing.expectError(
        error.InvalidIterationControlThermalState,
        waterHeatSoluteCeilingForCurrentState(12, 1000, &.{0.004}, &.{0.0}, &.{true}),
    );
    try std.testing.expectError(
        error.InvalidIterationControlThermalState,
        waterHeatSoluteCeilingForCurrentState(12, 1000, &.{std.math.nan(f64)}, &.{1.0}, &.{true}),
    );
}

test "from-scene limits rejects invalid iteration-option combinations" {
    const options = try @import("options.zig").parse(@import("test_fixtures.zig").scene_options_source);
    var zero_nph = options;
    zero_nph.water_heat_solute_iteration_limit = 0;
    try std.testing.expectError(
        error.ZeroNonlinearIterationLimit,
        Limits.fromSceneOptions(zero_nph, 1000),
    );

    var zero_npg = options;
    zero_npg.gas_iterations_per_water_heat_solute_iteration = 0;
    try std.testing.expectError(
        error.ZeroNonlinearIterationLimit,
        Limits.fromSceneOptions(zero_npg, 1000),
    );

    try std.testing.expectError(error.ZeroNonlinearIterationLimit, Limits.fromSceneOptions(options, 0));
}

test "runtime maximum is a hard ceiling for every process budget" {
    var options = try @import("options.zig").parse(@import("test_fixtures.zig").scene_options_source);
    options.water_heat_solute_iteration_limit = 60;
    options.gas_iterations_per_water_heat_solute_iteration = 4;
    const limits = try Limits.fromSceneOptions(options, 7);
    inline for (@typeInfo(Limits).@"struct".fields) |field| {
        if (field.type == u16) try std.testing.expect(@field(limits, field.name) <= 7);
    }
    try std.testing.expectEqual(@as(u16, 7), try limits.standingDeadEnergyMaxIterations());
    try std.testing.expectEqual(@as(u16, 7), try waterHeatSoluteCeilingForCurrentState(7, 7, &.{0.001}, &.{1.0}, &.{true}));
}

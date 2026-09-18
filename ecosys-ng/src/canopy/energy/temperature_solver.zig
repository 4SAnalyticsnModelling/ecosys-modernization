// **A8a DISPOSITION: SUPERSEDED BY BOUND OWNER; CANOPY-TKC-001 is closed.**
// Production now solves the coupled live-canopy temperature/water system with
// `canopy/energy/coupled_convergence.zig::solveOuterCoupled` and commits TKC in
// `stages/hourly_snow_energy.zig`; this older standalone solver remains an oracle.
//
// **HISTORICAL A8a DISPOSITION: GAP.** This module has no production caller and must not be
// given one casually, but its absence is a real defect, not a supersession.
// `applyTile` `:166` is the only physical writer of `plants.canopy_temperature_k`
// (legacy `TKC`) anywhere outside tests: the other three assignments are the
// allocation memset at `state/grid.zig:183`, the planting constant at
// `plant/initialization/seed_and_population.zig:226`, and the checkpoint restore
// at `io/checkpoint/checkpoint.zig:56`. So in production the live canopy surface
// temperature is frozen at the site mean annual air temperature for the life of
// the plant, and it is not a diagnostic: `energy.zig:89` raises it to the fourth
// power for emitted longwave, and `carboxylation.zig:91`,
// `biochemistry.zig:115`, `shoot_growth_runtime.zig:1267`,
// `development.zig:77`/`:138` and `root_processes_metabolism.zig:74` all drive
// temperature responses from it. The neighbouring bound solve is not this one:
// `canopy_air_exchange.solveInto` (`hourly_science_snow_energy.zig:495`) owns
// `TKQC`, the canopy *air* temperature, which `uptake.f:1354--1361` assigns
// separately from `TKC`. The structural counterpart that does exist is
// `standing_dead_surface_exchange.solveSurfaceTemperature` at `:392` -- production
// balances dead stalks hourly and live foliage never. Binding is not a one-line
// dispatch: the four per-plant driver arrays and the `Result` state in
// `ApplyContext` are allocated nowhere in production, and the conductances must
// come from the bound `canopy_surface_exchange` rather than be recomputed here.
// CANOPY-TKC-001 group of
// docs/traceability/canopy_surface_temperature_is_never_updated_hourly.md
const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;
const PlantState = @import("../../state/grid.zig").PlantState;
const AtmosphericState = @import("../../atmosphere/atmospheric_forcing.zig").State;
const ExposureState = @import("../radiation/exposure.zig").State;
const InterceptionState = @import("interception.zig").State;
const numerics = @import("../../core/numerics.zig");

pub const Settings = struct {
    timestep_hours: f64,
    canopy_longwave_emissivity: f64,
    minimum_temperature_k: f64,
    maximum_temperature_k: f64,
    solver_options: numerics.SolverOptions,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    equilibrium_temperature_k: []f64,
    energy_residual_megajoules_per_m2: []f64,
    residual_tolerance_megajoules_per_m2: []f64,
    sensible_heat_flux_megajoules_per_m2: []f64,
    latent_heat_flux_megajoules_per_m2: []f64,
    storage_heat_flux_megajoules_per_m2: []f64,
    iteration_count: []u16,
    newton_raphson_step_count: []u16,
    picard_step_count: []u16,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize) !State {
        if (cell_count == 0 or species_count == 0) return error.InvalidCanopyTemperatureDimensions;
        const count = try std.math.mul(usize, cell_count, species_count);
        var result: State = undefined;
        result.allocator = allocator;
        result.cell_count = cell_count;
        result.species_count = species_count;
        var f64_allocated: usize = 0;
        errdefer freeF64Allocated(&result, f64_allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(result, field.name) = try allocator.alloc(f64, count);
            @memset(@field(result, field.name), 0);
            f64_allocated += 1;
        };
        result.iteration_count = try allocator.alloc(u16, count);
        errdefer allocator.free(result.iteration_count);
        result.newton_raphson_step_count = try allocator.alloc(u16, count);
        errdefer allocator.free(result.newton_raphson_step_count);
        result.picard_step_count = try allocator.alloc(u16, count);
        @memset(result.iteration_count, 0);
        @memset(result.newton_raphson_step_count, 0);
        @memset(result.picard_step_count, 0);
        return result;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.allocator.free(self.iteration_count);
        self.allocator.free(self.newton_raphson_step_count);
        self.allocator.free(self.picard_step_count);
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) for (@field(self, field.name), 0..) |value, index| if (!std.math.isFinite(value)) {
            std.log.err("non-finite canopy temperature solve: field={s} index={d} value={e}", .{ field.name, index, value });
            return error.NonFiniteCanopyTemperatureSolve;
        };
    }
};

pub const ApplyContext = struct {
    result: *State,
    plants: *PlantState,
    atmosphere: *const AtmosphericState,
    air_temperature_k: []const f64,
    air_vapor_pressure_kpa: []const f64,
    exposure: *const ExposureState,
    interception: *const InterceptionState,
    heat_capacity_megajoules_per_m2_k: []const f64,
    sensible_heat_conductance_megajoules_per_m2_h_k: []const f64,
    latent_heat_conductance_megajoules_per_m2_h_kpa: []const f64,
    surface_vapor_activity_fraction: []const f64,
    settings: Settings,
};

const ResidualContext = struct {
    absorbed_shortwave_megajoules_per_m2: f64,
    downward_longwave_megajoules_per_m2: f64,
    air_temperature_k: f64,
    atmospheric_vapor_pressure_kpa: f64,
    previous_temperature_k: f64,
    exposure_fraction: f64,
    emissivity: f64,
    sensible_conductance: f64,
    latent_conductance: f64,
    vapor_activity: f64,
    storage_conductance: f64,
};

pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    try validateSettings(context.settings);
    const result = context.result;
    const count = try std.math.mul(usize, result.cell_count, result.species_count);
    if (range.end > result.cell_count or context.plants.cell_count != result.cell_count or context.plants.species_count != result.species_count or context.atmosphere.cell_count != result.cell_count or context.exposure.cell_count != result.cell_count or context.exposure.species_count != result.species_count or context.interception.cell_count != result.cell_count or context.interception.species_count != result.species_count or context.air_temperature_k.len != result.cell_count or context.air_vapor_pressure_kpa.len != result.cell_count) return error.CanopyTemperatureDimensionMismatch;
    inline for (.{ context.heat_capacity_megajoules_per_m2_k, context.sensible_heat_conductance_megajoules_per_m2_h_k, context.latent_heat_conductance_megajoules_per_m2_h_kpa, context.surface_vapor_activity_fraction }) |values| if (values.len != count) return error.CanopyTemperatureDimensionMismatch;

    for (range.first..range.end) |cell| for (0..result.species_count) |species| {
        const index = cell * result.species_count + species;
        const heat_capacity = context.heat_capacity_megajoules_per_m2_k[index];
        const sensible_conductance = context.sensible_heat_conductance_megajoules_per_m2_h_k[index];
        const latent_conductance = context.latent_heat_conductance_megajoules_per_m2_h_kpa[index];
        const vapor_activity = context.surface_vapor_activity_fraction[index];
        if (!std.math.isFinite(heat_capacity) or heat_capacity <= 0 or !std.math.isFinite(sensible_conductance) or sensible_conductance < 0 or !std.math.isFinite(latent_conductance) or latent_conductance < 0 or !std.math.isFinite(vapor_activity) or vapor_activity < 0 or vapor_activity > 1) return error.InvalidCanopyTemperatureRuntimeInput;
        const residual_context: ResidualContext = .{
            .absorbed_shortwave_megajoules_per_m2 = context.interception.absorbed_shortwave_megajoules_per_m2[index],
            .downward_longwave_megajoules_per_m2 = context.atmosphere.longwave_radiation_megajoules_per_m2[cell],
            .air_temperature_k = context.air_temperature_k[cell],
            .atmospheric_vapor_pressure_kpa = context.air_vapor_pressure_kpa[cell],
            .previous_temperature_k = context.plants.canopy_temperature_k[index],
            .exposure_fraction = context.exposure.species_exposure_fraction[index],
            .emissivity = context.settings.canopy_longwave_emissivity,
            .sensible_conductance = sensible_conductance,
            .latent_conductance = latent_conductance,
            .vapor_activity = vapor_activity,
            .storage_conductance = heat_capacity / context.settings.timestep_hours,
        };
        var options = context.settings.solver_options;
        options.residual_scale = residualScale(residual_context, residual_context.previous_temperature_k);
        const solved = numerics.newtonPicard(residual_context, residual, derivative, picard, context.settings.minimum_temperature_k, context.settings.maximum_temperature_k, residual_context.previous_temperature_k, options) catch |err| {
            std.log.err("canopy temperature solve failed: cell={d} species={d} initial_temperature_k={e}", .{ cell, species, residual_context.previous_temperature_k });
            return err;
        };
        result.equilibrium_temperature_k[index] = solved.root;
        result.energy_residual_megajoules_per_m2[index] = solved.residual;
        result.residual_tolerance_megajoules_per_m2[index] = options.absolute_tolerance + options.relative_tolerance * options.residual_scale;
        result.sensible_heat_flux_megajoules_per_m2[index] = residual_context.sensible_conductance * (residual_context.air_temperature_k - solved.root);
        result.latent_heat_flux_megajoules_per_m2[index] = latentHeatFlux(residual_context, solved.root);
        result.storage_heat_flux_megajoules_per_m2[index] = residual_context.storage_conductance * (residual_context.previous_temperature_k - solved.root);
        result.iteration_count[index] = solved.iterations;
        result.newton_raphson_step_count[index] = solved.newton_raphson_steps;
        result.picard_step_count[index] = solved.picard_steps;
        context.plants.canopy_temperature_k[index] = solved.root;
    };
}

fn residual(context: ResidualContext, temperature_k: f64) f64 {
    return context.absorbed_shortwave_megajoules_per_m2 + context.downward_longwave_megajoules_per_m2 * context.exposure_fraction - emittedLongwave(context, temperature_k) + context.sensible_conductance * (context.air_temperature_k - temperature_k) + latentHeatFlux(context, temperature_k) + context.storage_conductance * (context.previous_temperature_k - temperature_k);
}

fn derivative(context: ResidualContext, temperature_k: f64) f64 {
    const saturation_pressure = saturationVaporPressureKpa(temperature_k);
    const saturation_derivative = saturation_pressure * 5360.0 / (temperature_k * temperature_k);
    return -4.0 * context.emissivity * 2.04e-10 * std.math.pow(f64, temperature_k, 3) * context.exposure_fraction - context.sensible_conductance - context.latent_conductance * context.vapor_activity * saturation_derivative - context.storage_conductance;
}

fn picard(context: ResidualContext, temperature_k: f64) f64 {
    const linear_conductance = context.sensible_conductance + context.storage_conductance;
    return (context.absorbed_shortwave_megajoules_per_m2 + context.downward_longwave_megajoules_per_m2 * context.exposure_fraction - emittedLongwave(context, temperature_k) + latentHeatFlux(context, temperature_k) + context.sensible_conductance * context.air_temperature_k + context.storage_conductance * context.previous_temperature_k) / linear_conductance;
}

fn emittedLongwave(context: ResidualContext, temperature_k: f64) f64 {
    return context.emissivity * 2.04e-10 * std.math.pow(f64, temperature_k, 4) * context.exposure_fraction;
}

fn saturationVaporPressureKpa(temperature_k: f64) f64 {
    return 0.61 * @exp(5360.0 * (3.661e-3 - 1.0 / temperature_k));
}

fn latentHeatFlux(context: ResidualContext, temperature_k: f64) f64 {
    return context.latent_conductance * (context.atmospheric_vapor_pressure_kpa - context.vapor_activity * saturationVaporPressureKpa(temperature_k));
}

fn residualScale(context: ResidualContext, temperature_k: f64) f64 {
    return @max(1.0, @abs(context.absorbed_shortwave_megajoules_per_m2) + @abs(context.downward_longwave_megajoules_per_m2 * context.exposure_fraction) + @abs(emittedLongwave(context, temperature_k)) + @abs(context.sensible_conductance * (context.air_temperature_k - temperature_k)) + @abs(latentHeatFlux(context, temperature_k)) + @abs(context.storage_conductance * (context.previous_temperature_k - temperature_k)));
}

fn validateSettings(settings: Settings) !void {
    if (!std.math.isFinite(settings.timestep_hours) or settings.timestep_hours <= 0 or !std.math.isFinite(settings.canopy_longwave_emissivity) or settings.canopy_longwave_emissivity < 0 or settings.canopy_longwave_emissivity > 1 or !std.math.isFinite(settings.minimum_temperature_k) or !std.math.isFinite(settings.maximum_temperature_k) or settings.minimum_temperature_k <= 0 or settings.minimum_temperature_k >= settings.maximum_temperature_k) return error.InvalidCanopyTemperatureSettings;
}

fn freeF64Allocated(state: *State, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) state.allocator.free(@field(state, field.name));
        visited += 1;
    };
}

test "canopy energy residual uses the uptake convergence ceiling" {
    const context: ResidualContext = .{ .absorbed_shortwave_megajoules_per_m2 = 0.8, .downward_longwave_megajoules_per_m2 = 0.7, .air_temperature_k = 290, .atmospheric_vapor_pressure_kpa = 1.2, .previous_temperature_k = 285, .exposure_fraction = 0.8, .emissivity = 0.97, .sensible_conductance = 0.3, .latent_conductance = 0.05, .vapor_activity = 0.9, .storage_conductance = 0.4 };
    // Same energy-balance scale the production path uses: the sum of the
    // competing flux magnitudes in MJ m-2 at the starting temperature.
    const solved = try numerics.newtonPicard(context, residual, derivative, picard, 173.15, 373.15, 285, .{ .max_iterations = 200, .residual_scale = residualScale(context, 285) });
    try std.testing.expect(solved.iterations < 200);
    try std.testing.expect(@abs(solved.residual) < 1.0e-6);
}

test "canopy energy analytic derivative matches finite difference" {
    const context: ResidualContext = .{ .absorbed_shortwave_megajoules_per_m2 = 0.8, .downward_longwave_megajoules_per_m2 = 0.7, .air_temperature_k = 290, .atmospheric_vapor_pressure_kpa = 1.2, .previous_temperature_k = 285, .exposure_fraction = 0.8, .emissivity = 0.97, .sensible_conductance = 0.3, .latent_conductance = 0.05, .vapor_activity = 0.9, .storage_conductance = 0.4 };
    const temperature_k: f64 = 288;
    const step: f64 = 1.0e-4;
    const finite_difference = (residual(context, temperature_k + step) - residual(context, temperature_k - step)) / (2 * step);
    try std.testing.expectApproxEqRel(finite_difference, derivative(context, temperature_k), 1.0e-8);
}

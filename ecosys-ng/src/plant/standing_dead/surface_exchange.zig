const std = @import("std");
const numerics = @import("../../core/numerics.zig");

pub const Parameters = struct {
    minimum_richardson_number: f64,
    maximum_richardson_number: f64,
    richardson_resistance_multiplier: f64,
    minimum_boundary_resistance_h_per_m: f64,
    maximum_boundary_resistance_h_per_m: f64,
    saturation_vapor_prefactor_k: f64,
    saturation_relative_humidity: f64,
    saturation_temperature_coefficient_k: f64,
    saturation_reference_inverse_temperature_per_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
};

pub const Inputs = struct {
    atmospheric_temperature_k: f64,
    standing_dead_air_temperature_k: f64,
    standing_dead_surface_temperature_k: f64,
    standing_dead_air_vapor_fraction: f64,
    bulk_richardson_coefficient_k: f64,
    biome_isothermal_boundary_resistance_h_per_m: f64,
    aerodynamic_resistance_below_biome_h_per_m: f64,
    aerodynamic_resistance_below_standing_dead_h_per_m: f64,
    standing_dead_radiation_fraction: f64,
    latent_boundary_numerator_m2_per_h: f64,
    sensible_boundary_numerator_megajoules_per_m_h_k: f64,
    sensible_surface_resistance_h_per_m: f64,
    latent_surface_resistance_h_per_m: f64,
    intercepted_water_volume_m3: f64,
};

pub const Result = struct {
    total_aerodynamic_resistance_h_per_m: f64,
    adjusted_surface_resistance_h_per_m: f64,
    surface_vapor_fraction: f64,
    intercepted_water_change_m3_per_h: f64,
    latent_heat_flux_megajoules_per_h: f64,
    sensible_heat_flux_megajoules_per_h: f64,
    vapor_sensible_heat_flux_megajoules_per_h: f64,
};

pub const SurfaceEnergyInputs = struct {
    exchange_inputs: Inputs,
    absorbed_shortwave_megajoules_per_h: f64,
    downward_longwave_megajoules_per_h: f64,
    lateral_longwave_megajoules_per_h: f64,
    ground_surface_temperature_k: f64,
    emission_coefficient_megajoules_per_h_k4: f64,
    dry_and_existing_water_heat_capacity_megajoules_per_k: f64,
    retained_precipitation_water_m3_per_h: f64,
    retained_precipitation_heat_megajoules_per_h: f64,
    minimum_effective_heat_capacity_megajoules_per_k: f64,
};

pub const SurfaceSolverOptions = struct {
    minimum_temperature_k: f64,
    maximum_temperature_k: f64,
    solver_options: numerics.SolverOptions,
};

pub const SurfaceTemperatureResult = struct {
    temperature_k: f64,
    exchange: Result,
    net_radiation_megajoules_per_h: f64,
    storage_heat_flux_megajoules_per_h: f64,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
};

const SurfaceResidualContext = struct {
    inputs: SurfaceEnergyInputs,
    parameters: Parameters,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    intercepted_water_change_m3_per_h: []f64,
    net_radiation_megajoules_per_h: []f64,
    sensible_heat_flux_megajoules_per_h: []f64,
    latent_heat_flux_megajoules_per_h: []f64,
    vapor_sensible_heat_flux_megajoules_per_h: []f64,
    storage_heat_flux_megajoules_per_h: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize) !State {
        if (cell_count == 0 or species_count == 0) return error.InvalidStandingDeadExchangeDimensions;
        const count = try std.math.mul(usize, cell_count, species_count);
        var arrays: [6][]f64 = undefined;
        var allocated: usize = 0;
        errdefer for (arrays[0..allocated]) |values| allocator.free(values);
        for (&arrays) |*values| {
            values.* = try allocator.alloc(f64, count);
            @memset(values.*, 0);
            allocated += 1;
        }
        return .{ .allocator = allocator, .cell_count = cell_count, .species_count = species_count, .intercepted_water_change_m3_per_h = arrays[0], .net_radiation_megajoules_per_h = arrays[1], .sensible_heat_flux_megajoules_per_h = arrays[2], .latent_heat_flux_megajoules_per_h = arrays[3], .vapor_sensible_heat_flux_megajoules_per_h = arrays[4], .storage_heat_flux_megajoules_per_h = arrays[5] };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.intercepted_water_change_m3_per_h);
        self.allocator.free(self.net_radiation_megajoules_per_h);
        self.allocator.free(self.sensible_heat_flux_megajoules_per_h);
        self.allocator.free(self.latent_heat_flux_megajoules_per_h);
        self.allocator.free(self.vapor_sensible_heat_flux_megajoules_per_h);
        self.allocator.free(self.storage_heat_flux_megajoules_per_h);
        self.* = undefined;
    }
};

pub fn calculate(inputs: Inputs, parameters: Parameters) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteStandingDeadExchangeInput;
    inline for (@typeInfo(Parameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteStandingDeadExchangeParameter;
    if (parameters.maximum_richardson_number < parameters.minimum_richardson_number or parameters.richardson_resistance_multiplier <= 0 or parameters.minimum_boundary_resistance_h_per_m <= 0 or parameters.maximum_boundary_resistance_h_per_m < 5.0 * parameters.minimum_boundary_resistance_h_per_m or parameters.saturation_vapor_prefactor_k <= 0 or parameters.saturation_relative_humidity < 0 or parameters.saturation_relative_humidity > 1 or parameters.saturation_temperature_coefficient_k <= 0 or parameters.saturation_reference_inverse_temperature_per_k <= 0 or parameters.latent_heat_of_vaporization_megajoules_per_m3 <= 0 or parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0) return error.InvalidStandingDeadExchangeParameter;
    if (inputs.atmospheric_temperature_k <= 0 or inputs.standing_dead_air_temperature_k <= 0 or inputs.standing_dead_surface_temperature_k <= 0 or inputs.standing_dead_air_vapor_fraction < 0 or inputs.biome_isothermal_boundary_resistance_h_per_m < 0 or inputs.aerodynamic_resistance_below_biome_h_per_m < 0 or inputs.aerodynamic_resistance_below_standing_dead_h_per_m <= 0 or inputs.standing_dead_radiation_fraction < 0 or inputs.latent_boundary_numerator_m2_per_h < 0 or inputs.sensible_boundary_numerator_megajoules_per_m_h_k < 0 or inputs.sensible_surface_resistance_h_per_m < 0 or inputs.latent_surface_resistance_h_per_m < 0 or inputs.intercepted_water_volume_m3 < 0) return error.InvalidStandingDeadExchangeInput;

    const atmospheric_difference_k = inputs.atmospheric_temperature_k - inputs.standing_dead_air_temperature_k;
    const atmospheric_richardson = std.math.clamp(inputs.bulk_richardson_coefficient_k / inputs.atmospheric_temperature_k * atmospheric_difference_k, parameters.minimum_richardson_number, parameters.maximum_richardson_number);
    const atmospheric_stability = 1.0 - parameters.richardson_resistance_multiplier * atmospheric_richardson;
    if (atmospheric_stability <= 0) return error.InvalidStandingDeadAtmosphericStability;
    const boundary_resistance = std.math.clamp(
        inputs.biome_isothermal_boundary_resistance_h_per_m / atmospheric_stability,
        5.0 * parameters.minimum_boundary_resistance_h_per_m,
        parameters.maximum_boundary_resistance_h_per_m,
    );
    const total_aerodynamic_resistance = boundary_resistance + @max(0.0, inputs.aerodynamic_resistance_below_biome_h_per_m - inputs.aerodynamic_resistance_below_standing_dead_h_per_m);
    const surface_difference_k = inputs.standing_dead_air_temperature_k - inputs.standing_dead_surface_temperature_k;
    const surface_richardson = std.math.clamp(inputs.bulk_richardson_coefficient_k / inputs.standing_dead_air_temperature_k * surface_difference_k, parameters.minimum_richardson_number, parameters.maximum_richardson_number);
    const surface_stability = 1.0 - parameters.richardson_resistance_multiplier * surface_richardson;
    if (surface_stability <= 0) return error.InvalidStandingDeadSurfaceStability;
    const adjusted_surface_resistance = std.math.clamp(
        inputs.sensible_surface_resistance_h_per_m / surface_stability,
        parameters.minimum_boundary_resistance_h_per_m,
        parameters.maximum_boundary_resistance_h_per_m,
    );
    const sensible_conductance = inputs.standing_dead_radiation_fraction * inputs.sensible_boundary_numerator_megajoules_per_m_h_k / adjusted_surface_resistance;
    const latent_conductance = inputs.standing_dead_radiation_fraction * inputs.latent_boundary_numerator_m2_per_h / (adjusted_surface_resistance + inputs.latent_surface_resistance_h_per_m);
    const surface_vapor_fraction = parameters.saturation_vapor_prefactor_k / inputs.standing_dead_surface_temperature_k *
        parameters.saturation_relative_humidity *
        @exp(parameters.saturation_temperature_coefficient_k * (parameters.saturation_reference_inverse_temperature_per_k - 1.0 / inputs.standing_dead_surface_temperature_k));
    const unrestricted_water_change = latent_conductance * (inputs.standing_dead_air_vapor_fraction - surface_vapor_fraction);
    const water_change = if (unrestricted_water_change > 0)
        unrestricted_water_change
    else
        @max(unrestricted_water_change, -inputs.intercepted_water_volume_m3);
    const sensible_heat = sensible_conductance * surface_difference_k;
    const latent_heat = water_change * parameters.latent_heat_of_vaporization_megajoules_per_m3;
    const vapor_sensible_heat = water_change * parameters.liquid_water_heat_capacity_megajoules_per_m3_k * inputs.standing_dead_surface_temperature_k;
    inline for (.{ total_aerodynamic_resistance, adjusted_surface_resistance, surface_vapor_fraction, water_change, sensible_heat, latent_heat, vapor_sensible_heat }) |value| if (!std.math.isFinite(value)) return error.NonFiniteStandingDeadExchangeResult;
    return .{
        .total_aerodynamic_resistance_h_per_m = total_aerodynamic_resistance,
        .adjusted_surface_resistance_h_per_m = adjusted_surface_resistance,
        .surface_vapor_fraction = surface_vapor_fraction,
        .intercepted_water_change_m3_per_h = water_change,
        .latent_heat_flux_megajoules_per_h = latent_heat,
        .sensible_heat_flux_megajoules_per_h = sensible_heat,
        .vapor_sensible_heat_flux_megajoules_per_h = vapor_sensible_heat,
    };
}

pub fn solveSurfaceTemperature(inputs: SurfaceEnergyInputs, parameters: Parameters, options: SurfaceSolverOptions) !SurfaceTemperatureResult {
    try validateSurfaceEnergyInputs(inputs, options);
    const context: SurfaceResidualContext = .{ .inputs = inputs, .parameters = parameters };
    var solver_options = options.solver_options;
    solver_options.residual_scale = @max(1.0, @abs(inputs.exchange_inputs.standing_dead_surface_temperature_k));
    const solved = try numerics.newtonPicard(
        context,
        surfaceTemperatureResidual,
        surfaceTemperatureDerivative,
        surfaceTemperaturePicard,
        options.minimum_temperature_k,
        options.maximum_temperature_k,
        inputs.exchange_inputs.standing_dead_surface_temperature_k,
        solver_options,
    );
    var final_inputs = inputs.exchange_inputs;
    final_inputs.standing_dead_surface_temperature_k = solved.root;
    const exchange = try calculate(final_inputs, parameters);
    const energy = surfaceEnergyAt(inputs, parameters, solved.root, exchange);
    if (!std.math.isFinite(energy.net_radiation_megajoules_per_h) or !std.math.isFinite(energy.storage_heat_flux_megajoules_per_h)) return error.NonFiniteStandingDeadSurfaceEnergyResult;
    return .{
        .temperature_k = solved.root,
        .exchange = exchange,
        .net_radiation_megajoules_per_h = energy.net_radiation_megajoules_per_h,
        .storage_heat_flux_megajoules_per_h = energy.storage_heat_flux_megajoules_per_h,
        .iterations = solved.iterations,
        .newton_raphson_steps = solved.newton_raphson_steps,
        .picard_steps = solved.picard_steps,
    };
}

fn surfaceTemperatureResidual(context: SurfaceResidualContext, temperature_k: f64) f64 {
    return surfaceTemperatureTarget(context, temperature_k) - temperature_k;
}

fn surfaceTemperatureDerivative(context: SurfaceResidualContext, temperature_k: f64) f64 {
    const step = std.math.cbrt(std.math.floatEps(f64)) * @max(1.0, @abs(temperature_k));
    const lower = @max(1.0, temperature_k - step);
    const upper = temperature_k + step;
    return (surfaceTemperatureResidual(context, upper) - surfaceTemperatureResidual(context, lower)) / (upper - lower);
}

fn surfaceTemperaturePicard(context: SurfaceResidualContext, temperature_k: f64) f64 {
    return surfaceTemperatureTarget(context, temperature_k);
}

fn surfaceTemperatureTarget(context: SurfaceResidualContext, temperature_k: f64) f64 {
    var exchange_inputs = context.inputs.exchange_inputs;
    exchange_inputs.standing_dead_surface_temperature_k = temperature_k;
    const exchange = calculate(exchange_inputs, context.parameters) catch return std.math.nan(f64);
    const energy = surfaceEnergyAt(context.inputs, context.parameters, temperature_k, exchange);
    const effective_heat_capacity = context.inputs.dry_and_existing_water_heat_capacity_megajoules_per_k +
        context.parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
            (exchange.intercepted_water_change_m3_per_h + context.inputs.retained_precipitation_water_m3_per_h);
    if (!std.math.isFinite(effective_heat_capacity) or effective_heat_capacity <= context.inputs.minimum_effective_heat_capacity_megajoules_per_k) return std.math.nan(f64);
    return (temperature_k * context.inputs.dry_and_existing_water_heat_capacity_megajoules_per_k + energy.storage_heat_flux_megajoules_per_h) / effective_heat_capacity;
}

const SurfaceEnergyFluxes = struct { net_radiation_megajoules_per_h: f64, storage_heat_flux_megajoules_per_h: f64 };

fn surfaceEnergyAt(inputs: SurfaceEnergyInputs, parameters: Parameters, temperature_k: f64, exchange: Result) SurfaceEnergyFluxes {
    const temperature_fourth = std.math.pow(f64, temperature_k, 4);
    const ground_fourth = std.math.pow(f64, inputs.ground_surface_temperature_k, 4);
    const emitted_to_sky = inputs.emission_coefficient_megajoules_per_h_k4 * temperature_fourth;
    const emitted_to_ground = inputs.emission_coefficient_megajoules_per_h_k4 * (temperature_fourth - ground_fourth) * inputs.exchange_inputs.standing_dead_radiation_fraction;
    const net_radiation = inputs.absorbed_shortwave_megajoules_per_h + inputs.downward_longwave_megajoules_per_h + inputs.lateral_longwave_megajoules_per_h - emitted_to_sky - emitted_to_ground;
    return .{
        .net_radiation_megajoules_per_h = net_radiation,
        .storage_heat_flux_megajoules_per_h = net_radiation + exchange.latent_heat_flux_megajoules_per_h + exchange.sensible_heat_flux_megajoules_per_h + exchange.vapor_sensible_heat_flux_megajoules_per_h + inputs.retained_precipitation_heat_megajoules_per_h + parameters.liquid_water_heat_capacity_megajoules_per_m3_k * inputs.retained_precipitation_water_m3_per_h * temperature_k,
    };
}

fn validateSurfaceEnergyInputs(inputs: SurfaceEnergyInputs, options: SurfaceSolverOptions) !void {
    inline for (@typeInfo(SurfaceEnergyInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteStandingDeadSurfaceEnergyInput;
    if (inputs.ground_surface_temperature_k <= 0 or inputs.emission_coefficient_megajoules_per_h_k4 < 0 or inputs.dry_and_existing_water_heat_capacity_megajoules_per_k <= 0 or inputs.retained_precipitation_water_m3_per_h < 0 or inputs.minimum_effective_heat_capacity_megajoules_per_k < 0 or !std.math.isFinite(options.minimum_temperature_k) or !std.math.isFinite(options.maximum_temperature_k) or options.minimum_temperature_k <= 0 or options.maximum_temperature_k <= options.minimum_temperature_k) return error.InvalidStandingDeadSurfaceEnergyInput;
}

test "UPTAKE standing-dead evaporation is water bounded for arbitrary runtime species" {
    var state = try State.init(std.testing.allocator, 1, 8);
    defer state.deinit();
    const result = try calculate(.{
        .atmospheric_temperature_k = 300,
        .standing_dead_air_temperature_k = 295,
        .standing_dead_surface_temperature_k = 305,
        .standing_dead_air_vapor_fraction = 0,
        .bulk_richardson_coefficient_k = 1,
        .biome_isothermal_boundary_resistance_h_per_m = 0.005,
        .aerodynamic_resistance_below_biome_h_per_m = 0.02,
        .aerodynamic_resistance_below_standing_dead_h_per_m = 0.01,
        .standing_dead_radiation_fraction = 0.5,
        .latent_boundary_numerator_m2_per_h = 1,
        .sensible_boundary_numerator_megajoules_per_m_h_k = 0.00125,
        .sensible_surface_resistance_h_per_m = 0.00139,
        .latent_surface_resistance_h_per_m = 0.0278,
        .intercepted_water_volume_m3 = 1.0e-4,
    }, .{
        .minimum_richardson_number = -0.2,
        .maximum_richardson_number = 0.2,
        .richardson_resistance_multiplier = 10,
        .minimum_boundary_resistance_h_per_m = 0.00139,
        .maximum_boundary_resistance_h_per_m = 0.0139,
        .saturation_vapor_prefactor_k = 2.173e-3,
        .saturation_relative_humidity = 0.61,
        .saturation_temperature_coefficient_k = 5360,
        .saturation_reference_inverse_temperature_per_k = 3.661e-3,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    });
    state.intercepted_water_change_m3_per_h[7] = result.intercepted_water_change_m3_per_h;
    try std.testing.expectApproxEqAbs(-1.0e-4, state.intercepted_water_change_m3_per_h[7], 1.0e-15);
}

test "UPTAKE standing-dead TKD Newton-Picard exits before canopy ceiling" {
    const temperature_k: f64 = 295;
    const vapor_fraction = 2.173e-3 / temperature_k * 0.61 * @exp(5360.0 * (3.661e-3 - 1.0 / temperature_k));
    const parameters: Parameters = .{
        .minimum_richardson_number = -0.05,
        .maximum_richardson_number = 0.05,
        .richardson_resistance_multiplier = 10,
        .minimum_boundary_resistance_h_per_m = 0.00139,
        .maximum_boundary_resistance_h_per_m = 0.0139,
        .saturation_vapor_prefactor_k = 2.173e-3,
        .saturation_relative_humidity = 0.61,
        .saturation_temperature_coefficient_k = 5360,
        .saturation_reference_inverse_temperature_per_k = 3.661e-3,
        .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    };
    const solved = try solveSurfaceTemperature(.{
        .exchange_inputs = .{
            .atmospheric_temperature_k = temperature_k,
            .standing_dead_air_temperature_k = temperature_k,
            .standing_dead_surface_temperature_k = temperature_k,
            .standing_dead_air_vapor_fraction = vapor_fraction,
            .bulk_richardson_coefficient_k = 0,
            .biome_isothermal_boundary_resistance_h_per_m = 0.005,
            .aerodynamic_resistance_below_biome_h_per_m = 0.02,
            .aerodynamic_resistance_below_standing_dead_h_per_m = 0.01,
            .standing_dead_radiation_fraction = 0.5,
            .latent_boundary_numerator_m2_per_h = 1,
            .sensible_boundary_numerator_megajoules_per_m_h_k = 0.00125,
            .sensible_surface_resistance_h_per_m = 0.00139,
            .latent_surface_resistance_h_per_m = 0.0278,
            .intercepted_water_volume_m3 = 0,
        },
        .absorbed_shortwave_megajoules_per_h = 0,
        .downward_longwave_megajoules_per_h = 0,
        .lateral_longwave_megajoules_per_h = 0,
        .ground_surface_temperature_k = temperature_k,
        .emission_coefficient_megajoules_per_h_k4 = 0,
        .dry_and_existing_water_heat_capacity_megajoules_per_k = 1,
        .retained_precipitation_water_m3_per_h = 0,
        .retained_precipitation_heat_megajoules_per_h = 0,
        .minimum_effective_heat_capacity_megajoules_per_k = 1.0e-12,
    }, parameters, .{
        .minimum_temperature_k = 200,
        .maximum_temperature_k = 350,
        // Overwritten by solve() with max(1, |T_dead|) K before solving.
        .solver_options = .{ .absolute_tolerance = 1.0e-10, .relative_tolerance = 1.0e-10, .max_iterations = 100, .picard_relaxation = 0.5, .residual_scale = 1.0 },
    });
    try std.testing.expectApproxEqAbs(temperature_k, solved.temperature_k, 1.0e-10);
    try std.testing.expect(solved.iterations < 100);
}

const std = @import("std");
const CellRange = @import("../../core/compute.zig").CellRange;

pub const Parameters = struct {
    minimum_richardson_number: f64,
    maximum_richardson_number: f64,
    richardson_resistance_multiplier: f64,
    minimum_boundary_resistance_h_per_m: f64,
    maximum_boundary_resistance_h_per_m: f64,
    saturation_vapor_prefactor_k: f64,
    saturation_relative_humidity: f64,
    saturation_temperature_k: f64,
    saturation_reference_inverse_temperature_per_k: f64,
    water_potential_vapor_coefficient_mol_per_m3: f64,
    universal_gas_constant_j_per_mol_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
};

pub const Inputs = struct {
    atmospheric_temperature_k: f64,
    canopy_air_temperature_k: f64,
    canopy_surface_temperature_k: f64,
    canopy_air_vapor_fraction: f64,
    bulk_richardson_coefficient_k: f64,
    biome_isothermal_boundary_resistance_h_per_m: f64,
    aerodynamic_resistance_below_biome_h_per_m: f64,
    aerodynamic_resistance_below_species_h_per_m: f64,
    species_canopy_radiation_fraction: f64,
    latent_boundary_numerator_m2_per_h: f64,
    sensible_boundary_numerator_megajoules_per_m_h_k: f64,
    sensible_surface_resistance_h_per_m: f64,
    latent_surface_resistance_h_per_m: f64,
    stomatal_resistance_h_per_m: f64,
    canopy_total_water_potential_megapascal: f64,
    intercepted_water_volume_m3: f64,
};

pub const Result = struct {
    boundary_layer_resistance_h_per_m: f64,
    total_aerodynamic_resistance_h_per_m: f64,
    adjusted_surface_resistance_h_per_m: f64,
    canopy_surface_vapor_fraction: f64,
    sensible_conductance_megajoules_per_h_k: f64,
    latent_conductance_m3_per_h: f64,
    intercepted_water_change_m3_per_h: f64,
    transpiration_m3_per_h: f64,
    latent_heat_flux_megajoules_per_h: f64,
    sensible_heat_flux_megajoules_per_h: f64,
    vapor_sensible_heat_flux_megajoules_per_h: f64,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    species_count: usize,
    boundary_layer_resistance_h_per_m: []f64,
    total_aerodynamic_resistance_h_per_m: []f64,
    adjusted_surface_resistance_h_per_m: []f64,
    canopy_surface_vapor_fraction: []f64,
    intercepted_water_change_m3_per_h: []f64,
    transpiration_m3_per_h: []f64,
    latent_heat_flux_megajoules_per_h: []f64,
    sensible_heat_flux_megajoules_per_h: []f64,
    vapor_sensible_heat_flux_megajoules_per_h: []f64,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, species_count: usize) !State {
        if (cell_count == 0 or species_count == 0) return error.InvalidCanopySurfaceExchangeDimensions;
        const count = try std.math.mul(usize, cell_count, species_count);
        var state: State = undefined;
        state.allocator = allocator;
        state.cell_count = cell_count;
        state.species_count = species_count;
        var allocated: usize = 0;
        errdefer freeAllocated(&state, allocated);
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            @field(state, field.name) = try allocator.alloc(f64, count);
            @memset(@field(state, field.name), 0);
            allocated += 1;
        };
        return state;
    }

    pub fn deinit(self: *State) void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    pub fn validateFinite(self: State) !void {
        inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
            for (@field(self, field.name), 0..) |value, index| if (!std.math.isFinite(value)) {
                std.log.err("non-finite canopy surface exchange: field={s} index={d} value={e}", .{ field.name, index, value });
                return error.NonFiniteCanopySurfaceExchangeState;
            };
        };
    }
};

pub const RuntimeInputs = struct {
    atmospheric_temperature_k_by_cell: []const f64,
    canopy_air_temperature_k: []const f64,
    canopy_air_vapor_fraction: []const f64,
    bulk_richardson_coefficient_k_by_cell: []const f64,
    biome_isothermal_boundary_resistance_h_per_m_by_cell: []const f64,
    latent_boundary_numerator_m2_per_h_by_cell: []const f64,
    sensible_boundary_numerator_megajoules_per_m_h_k_by_cell: []const f64,
    canopy_surface_temperature_k: []const f64,
    aerodynamic_resistance_below_biome_h_per_m_by_cell: []const f64,
    aerodynamic_resistance_below_species_h_per_m: []const f64,
    species_canopy_radiation_fraction: []const f64,
    sensible_surface_resistance_h_per_m: []const f64,
    latent_surface_resistance_h_per_m: []const f64,
    stomatal_resistance_h_per_m: []const f64,
    canopy_total_water_potential_megapascal: []const f64,
    intercepted_water_volume_m3: []const f64,
};

pub const SurfaceInputWorkspace = struct {
    allocator: std.mem.Allocator,
    plant_count: usize,
    canopy_air_vapor_fraction: []f64,
    sensible_surface_resistance_h_per_m: []f64,
    latent_surface_resistance_h_per_m: []f64,
    stomatal_resistance_h_per_m: []f64,

    pub fn init(allocator: std.mem.Allocator, plant_count: usize) !SurfaceInputWorkspace {
        if (plant_count == 0) return error.InvalidCanopySurfaceWorkspaceDimensions;
        var arrays: [4][]f64 = undefined;
        var allocated: usize = 0;
        errdefer for (arrays[0..allocated]) |values| allocator.free(values);
        for (&arrays) |*values| {
            values.* = try allocator.alloc(f64, plant_count);
            @memset(values.*, 0);
            allocated += 1;
        }
        return .{
            .allocator = allocator,
            .plant_count = plant_count,
            .canopy_air_vapor_fraction = arrays[0],
            .sensible_surface_resistance_h_per_m = arrays[1],
            .latent_surface_resistance_h_per_m = arrays[2],
            .stomatal_resistance_h_per_m = arrays[3],
        };
    }

    pub fn deinit(self: *SurfaceInputWorkspace) void {
        inline for (.{ self.canopy_air_vapor_fraction, self.sensible_surface_resistance_h_per_m, self.latent_surface_resistance_h_per_m, self.stomatal_resistance_h_per_m }) |values| self.allocator.free(values);
        self.* = undefined;
    }

    /// Adapts live runtime plant state to UPTAKE `VPQY/RAH/RAE/RC`.
    pub fn refresh(
        self: *SurfaceInputWorkspace,
        canopy_air_temperature_k: []const f64,
        canopy_air_vapor_pressure_kpa: []const f64,
        minimum_stomatal_resistance_h_per_m: []const f64,
        cuticular_resistance_h_per_m: []const f64,
        stomatal_turgor_shape_per_megapascal: []const f64,
        canopy_turgor_potential_megapascal: []const f64,
        isothermal_sensible_surface_resistance_h_per_m: f64,
        isothermal_latent_surface_resistance_h_per_m: f64,
        parameters: Parameters,
    ) !void {
        inline for (.{ canopy_air_temperature_k, canopy_air_vapor_pressure_kpa, minimum_stomatal_resistance_h_per_m, cuticular_resistance_h_per_m, stomatal_turgor_shape_per_megapascal, canopy_turgor_potential_megapascal }) |values| if (values.len != self.plant_count) return error.CanopySurfaceExchangeDimensionMismatch;
        if (!std.math.isFinite(isothermal_sensible_surface_resistance_h_per_m) or isothermal_sensible_surface_resistance_h_per_m < 0 or !std.math.isFinite(isothermal_latent_surface_resistance_h_per_m) or isothermal_latent_surface_resistance_h_per_m < 0) return error.InvalidCanopySurfaceResistance;
        for (0..self.plant_count) |plant| {
            inline for (.{ canopy_air_temperature_k[plant], canopy_air_vapor_pressure_kpa[plant], minimum_stomatal_resistance_h_per_m[plant], cuticular_resistance_h_per_m[plant], stomatal_turgor_shape_per_megapascal[plant], canopy_turgor_potential_megapascal[plant] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteCanopySurfaceWorkspaceInput;
            if (canopy_air_temperature_k[plant] < 0 or canopy_air_vapor_pressure_kpa[plant] < 0 or minimum_stomatal_resistance_h_per_m[plant] < 0 or cuticular_resistance_h_per_m[plant] < minimum_stomatal_resistance_h_per_m[plant] or canopy_turgor_potential_megapascal[plant] < 0) return error.InvalidCanopySurfaceWorkspaceInput;
            if (canopy_air_temperature_k[plant] == 0) {
                self.canopy_air_vapor_fraction[plant] = 0;
                self.sensible_surface_resistance_h_per_m[plant] = isothermal_sensible_surface_resistance_h_per_m;
                self.latent_surface_resistance_h_per_m[plant] = isothermal_latent_surface_resistance_h_per_m;
                self.stomatal_resistance_h_per_m[plant] = cuticular_resistance_h_per_m[plant];
                continue;
            }
            self.canopy_air_vapor_fraction[plant] = canopy_air_vapor_pressure_kpa[plant] * parameters.saturation_vapor_prefactor_k / canopy_air_temperature_k[plant];
            self.sensible_surface_resistance_h_per_m[plant] = isothermal_sensible_surface_resistance_h_per_m;
            self.latent_surface_resistance_h_per_m[plant] = isothermal_latent_surface_resistance_h_per_m;
            const water_stress = @exp(stomatal_turgor_shape_per_megapascal[plant] * canopy_turgor_potential_megapascal[plant]);
            self.stomatal_resistance_h_per_m[plant] = minimum_stomatal_resistance_h_per_m[plant] +
                (cuticular_resistance_h_per_m[plant] - minimum_stomatal_resistance_h_per_m[plant]) * water_stress;
            if (!std.math.isFinite(self.canopy_air_vapor_fraction[plant]) or !std.math.isFinite(self.stomatal_resistance_h_per_m[plant])) return error.NonFiniteCanopySurfaceWorkspaceResult;
        }
    }
};

pub const ApplyContext = struct {
    state: *State,
    inputs: RuntimeInputs,
    parameters: Parameters,
};

pub fn applyTile(context: *ApplyContext, range: CellRange) !void {
    const state = context.state;
    if (range.end > state.cell_count) return error.CanopySurfaceExchangeRangeOutOfBounds;
    const species_values = try std.math.mul(usize, state.cell_count, state.species_count);
    inline for (.{
        context.inputs.atmospheric_temperature_k_by_cell,
        context.inputs.bulk_richardson_coefficient_k_by_cell,
        context.inputs.biome_isothermal_boundary_resistance_h_per_m_by_cell,
        context.inputs.latent_boundary_numerator_m2_per_h_by_cell,
        context.inputs.sensible_boundary_numerator_megajoules_per_m_h_k_by_cell,
        context.inputs.aerodynamic_resistance_below_biome_h_per_m_by_cell,
    }) |values| if (values.len != state.cell_count) return error.CanopySurfaceExchangeDimensionMismatch;
    inline for (.{
        context.inputs.canopy_surface_temperature_k,
        context.inputs.canopy_air_temperature_k,
        context.inputs.canopy_air_vapor_fraction,
        context.inputs.aerodynamic_resistance_below_species_h_per_m,
        context.inputs.species_canopy_radiation_fraction,
        context.inputs.sensible_surface_resistance_h_per_m,
        context.inputs.latent_surface_resistance_h_per_m,
        context.inputs.stomatal_resistance_h_per_m,
        context.inputs.canopy_total_water_potential_megapascal,
        context.inputs.intercepted_water_volume_m3,
    }) |values| if (values.len != species_values) return error.CanopySurfaceExchangeDimensionMismatch;
    for (range.first..range.end) |cell| for (0..state.species_count) |species| {
        const index = cell * state.species_count + species;
        if (context.inputs.species_canopy_radiation_fraction[index] <= 0) {
            inline for (@typeInfo(State).@"struct".fields) |field| {
                if (field.type == []f64) @field(state, field.name)[index] = 0;
            }
            continue;
        }
        const result = try calculate(.{
            .atmospheric_temperature_k = context.inputs.atmospheric_temperature_k_by_cell[cell],
            .canopy_air_temperature_k = context.inputs.canopy_air_temperature_k[index],
            .canopy_surface_temperature_k = context.inputs.canopy_surface_temperature_k[index],
            .canopy_air_vapor_fraction = context.inputs.canopy_air_vapor_fraction[index],
            .bulk_richardson_coefficient_k = context.inputs.bulk_richardson_coefficient_k_by_cell[cell],
            .biome_isothermal_boundary_resistance_h_per_m = context.inputs.biome_isothermal_boundary_resistance_h_per_m_by_cell[cell],
            .aerodynamic_resistance_below_biome_h_per_m = context.inputs.aerodynamic_resistance_below_biome_h_per_m_by_cell[cell],
            .aerodynamic_resistance_below_species_h_per_m = context.inputs.aerodynamic_resistance_below_species_h_per_m[index],
            .species_canopy_radiation_fraction = context.inputs.species_canopy_radiation_fraction[index],
            .latent_boundary_numerator_m2_per_h = context.inputs.latent_boundary_numerator_m2_per_h_by_cell[cell],
            .sensible_boundary_numerator_megajoules_per_m_h_k = context.inputs.sensible_boundary_numerator_megajoules_per_m_h_k_by_cell[cell],
            .sensible_surface_resistance_h_per_m = context.inputs.sensible_surface_resistance_h_per_m[index],
            .latent_surface_resistance_h_per_m = context.inputs.latent_surface_resistance_h_per_m[index],
            .stomatal_resistance_h_per_m = context.inputs.stomatal_resistance_h_per_m[index],
            .canopy_total_water_potential_megapascal = context.inputs.canopy_total_water_potential_megapascal[index],
            .intercepted_water_volume_m3 = context.inputs.intercepted_water_volume_m3[index],
        }, context.parameters);
        inline for (@typeInfo(Result).@"struct".fields) |field| {
            if (@hasField(State, field.name)) @field(state, field.name)[index] = @field(result, field.name);
        }
    };
}

/// Adds canopy exchange to an existing per-cell near-ground-air ledger. Each
/// tile owns complete cells, so the species reduction is deterministic and
/// race-free. Positive canopy uptake is an equal negative air source.
pub fn addGroundAirSourcesTile(state: State, range: CellRange, sensible_heat_source_megajoules_per_h: []f64, vapor_source_m3_per_h: []f64) !void {
    if (range.end > state.cell_count or sensible_heat_source_megajoules_per_h.len != state.cell_count or vapor_source_m3_per_h.len != state.cell_count) return error.CanopySurfaceExchangeDimensionMismatch;
    for (range.first..range.end) |cell| {
        var canopy_sensible_megajoules_per_h: f64 = 0;
        var canopy_vapor_m3_per_h: f64 = 0;
        for (0..state.species_count) |species| {
            const index = cell * state.species_count + species;
            canopy_sensible_megajoules_per_h += state.sensible_heat_flux_megajoules_per_h[index];
            canopy_vapor_m3_per_h += state.intercepted_water_change_m3_per_h[index] + state.transpiration_m3_per_h[index];
        }
        sensible_heat_source_megajoules_per_h[cell] -= canopy_sensible_megajoules_per_h;
        vapor_source_m3_per_h[cell] -= canopy_vapor_m3_per_h;
        if (!std.math.isFinite(sensible_heat_source_megajoules_per_h[cell]) or !std.math.isFinite(vapor_source_m3_per_h[cell])) return error.NonFiniteGroundAirCanopySource;
    }
}

/// Exact local `uptake.f` canopy resistance and water-flux block. Flux signs
/// follow the source: positive intercepted-water change is condensation onto
/// the canopy; negative values are evaporation. Transpiration is non-positive.
pub fn calculate(inputs: Inputs, parameters: Parameters) !Result {
    try validateParameters(parameters);
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteCanopySurfaceExchangeInput;
    }
    if (inputs.atmospheric_temperature_k <= 0 or inputs.canopy_air_temperature_k <= 0 or inputs.canopy_surface_temperature_k <= 0 or
        inputs.canopy_air_vapor_fraction < 0 or inputs.biome_isothermal_boundary_resistance_h_per_m < 0 or
        inputs.aerodynamic_resistance_below_biome_h_per_m <= 0 or inputs.aerodynamic_resistance_below_species_h_per_m < 0 or
        inputs.species_canopy_radiation_fraction < 0 or
        inputs.latent_boundary_numerator_m2_per_h < 0 or inputs.sensible_boundary_numerator_megajoules_per_m_h_k < 0 or
        inputs.sensible_surface_resistance_h_per_m < 0 or inputs.latent_surface_resistance_h_per_m < 0 or
        inputs.stomatal_resistance_h_per_m < 0 or inputs.intercepted_water_volume_m3 < 0)
        return error.InvalidCanopySurfaceExchangeInput;

    const atmospheric_richardson = std.math.clamp(
        inputs.bulk_richardson_coefficient_k / inputs.atmospheric_temperature_k *
            (inputs.atmospheric_temperature_k - inputs.canopy_air_temperature_k),
        parameters.minimum_richardson_number,
        parameters.maximum_richardson_number,
    );
    const atmospheric_stability = 1 - parameters.richardson_resistance_multiplier * atmospheric_richardson;
    if (atmospheric_stability <= 0) return error.InvalidCanopyAtmosphericStability;
    const boundary_resistance = std.math.clamp(
        inputs.biome_isothermal_boundary_resistance_h_per_m / atmospheric_stability,
        parameters.minimum_boundary_resistance_h_per_m,
        parameters.maximum_boundary_resistance_h_per_m,
    );
    const within_canopy_resistance = @max(0.0, inputs.aerodynamic_resistance_below_biome_h_per_m - inputs.aerodynamic_resistance_below_species_h_per_m);
    const total_aerodynamic_resistance = boundary_resistance + within_canopy_resistance;

    const surface_richardson = std.math.clamp(
        inputs.bulk_richardson_coefficient_k / inputs.canopy_air_temperature_k *
            (inputs.canopy_air_temperature_k - inputs.canopy_surface_temperature_k),
        parameters.minimum_richardson_number,
        parameters.maximum_richardson_number,
    );
    const surface_stability = 1 - parameters.richardson_resistance_multiplier * surface_richardson;
    if (surface_stability <= 0) return error.InvalidCanopySurfaceStability;
    const adjusted_surface_resistance = std.math.clamp(
        inputs.sensible_surface_resistance_h_per_m / surface_stability,
        parameters.minimum_boundary_resistance_h_per_m,
        parameters.maximum_boundary_resistance_h_per_m,
    );

    const sensible_numerator = inputs.species_canopy_radiation_fraction * inputs.sensible_boundary_numerator_megajoules_per_m_h_k;
    const latent_numerator = inputs.species_canopy_radiation_fraction * inputs.latent_boundary_numerator_m2_per_h;
    const sensible_conductance = sensible_numerator / adjusted_surface_resistance;
    const latent_conductance = latent_numerator / (adjusted_surface_resistance + inputs.latent_surface_resistance_h_per_m);
    const surface_vapor_fraction = parameters.saturation_vapor_prefactor_k / inputs.canopy_surface_temperature_k *
        parameters.saturation_relative_humidity *
        @exp(parameters.saturation_temperature_k * (parameters.saturation_reference_inverse_temperature_per_k - 1 / inputs.canopy_surface_temperature_k)) *
        @exp(parameters.water_potential_vapor_coefficient_mol_per_m3 * inputs.canopy_total_water_potential_megapascal /
            (parameters.universal_gas_constant_j_per_mol_k * inputs.canopy_surface_temperature_k));

    var residual_vapor_flux = latent_conductance * (inputs.canopy_air_vapor_fraction - surface_vapor_fraction);
    const intercepted_water_change = if (residual_vapor_flux > 0) blk: {
        const condensation = residual_vapor_flux;
        residual_vapor_flux = 0;
        break :blk condensation;
    } else blk: {
        const evaporation = @max(residual_vapor_flux, -inputs.intercepted_water_volume_m3);
        residual_vapor_flux -= evaporation;
        break :blk evaporation;
    };
    const transpiration = residual_vapor_flux *
        (adjusted_surface_resistance + inputs.latent_surface_resistance_h_per_m) /
        (adjusted_surface_resistance + inputs.stomatal_resistance_h_per_m);
    const sensible_heat_flux = sensible_conductance * (inputs.canopy_air_temperature_k - inputs.canopy_surface_temperature_k);
    const latent_heat_flux = (transpiration + intercepted_water_change) * parameters.latent_heat_of_vaporization_megajoules_per_m3;
    const vapor_sensible_heat_flux = intercepted_water_change * parameters.liquid_water_heat_capacity_megajoules_per_m3_k * inputs.canopy_surface_temperature_k;

    inline for (.{ boundary_resistance, total_aerodynamic_resistance, adjusted_surface_resistance, surface_vapor_fraction, sensible_conductance, latent_conductance, intercepted_water_change, transpiration, latent_heat_flux, sensible_heat_flux, vapor_sensible_heat_flux }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteCanopySurfaceExchangeResult;
    }
    return .{
        .boundary_layer_resistance_h_per_m = boundary_resistance,
        .total_aerodynamic_resistance_h_per_m = total_aerodynamic_resistance,
        .adjusted_surface_resistance_h_per_m = adjusted_surface_resistance,
        .canopy_surface_vapor_fraction = surface_vapor_fraction,
        .sensible_conductance_megajoules_per_h_k = sensible_conductance,
        .latent_conductance_m3_per_h = latent_conductance,
        .intercepted_water_change_m3_per_h = intercepted_water_change,
        .transpiration_m3_per_h = transpiration,
        .latent_heat_flux_megajoules_per_h = latent_heat_flux,
        .sensible_heat_flux_megajoules_per_h = sensible_heat_flux,
        .vapor_sensible_heat_flux_megajoules_per_h = vapor_sensible_heat_flux,
    };
}

fn validateParameters(parameters: Parameters) !void {
    inline for (@typeInfo(Parameters).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteCanopySurfaceExchangeParameter;
    }
    if (parameters.maximum_richardson_number < parameters.minimum_richardson_number or
        parameters.richardson_resistance_multiplier <= 0 or parameters.minimum_boundary_resistance_h_per_m <= 0 or
        parameters.maximum_boundary_resistance_h_per_m < parameters.minimum_boundary_resistance_h_per_m or
        parameters.saturation_vapor_prefactor_k <= 0 or parameters.saturation_relative_humidity < 0 or parameters.saturation_relative_humidity > 1 or
        parameters.saturation_temperature_k <= 0 or parameters.saturation_reference_inverse_temperature_per_k <= 0 or
        parameters.water_potential_vapor_coefficient_mol_per_m3 <= 0 or parameters.universal_gas_constant_j_per_mol_k <= 0 or
        parameters.latent_heat_of_vaporization_megajoules_per_m3 <= 0 or parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidCanopySurfaceExchangeParameter;
}

fn freeAllocated(state: *State, count: usize) void {
    var visited: usize = 0;
    inline for (@typeInfo(State).@"struct".fields) |field| if (field.type == []f64) {
        if (visited < count) state.allocator.free(@field(state, field.name));
        visited += 1;
    };
}

const test_parameters: Parameters = .{
    .minimum_richardson_number = -0.1,
    .maximum_richardson_number = 0.05,
    .richardson_resistance_multiplier = 10,
    .minimum_boundary_resistance_h_per_m = 0.00139,
    .maximum_boundary_resistance_h_per_m = 0.0139,
    .saturation_vapor_prefactor_k = 2.173e-3,
    .saturation_relative_humidity = 0.61,
    .saturation_temperature_k = 5360,
    .saturation_reference_inverse_temperature_per_k = 3.661e-3,
    .water_potential_vapor_coefficient_mol_per_m3 = 18,
    .universal_gas_constant_j_per_mol_k = 8.3143,
    .latent_heat_of_vaporization_megajoules_per_m3 = 2465,
    .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
};

test "uptake canopy condensation is assigned entirely to intercepted water" {
    const result = try calculate(.{
        .atmospheric_temperature_k = 290,
        .canopy_air_temperature_k = 289,
        .canopy_surface_temperature_k = 280,
        .canopy_air_vapor_fraction = 0.02,
        .bulk_richardson_coefficient_k = 1,
        .biome_isothermal_boundary_resistance_h_per_m = 0.005,
        .aerodynamic_resistance_below_biome_h_per_m = 0.01,
        .aerodynamic_resistance_below_species_h_per_m = 0.004,
        .species_canopy_radiation_fraction = 0.5,
        .latent_boundary_numerator_m2_per_h = 0.1,
        .sensible_boundary_numerator_megajoules_per_m_h_k = 0.02,
        .sensible_surface_resistance_h_per_m = 0.004,
        .latent_surface_resistance_h_per_m = 0.002,
        .stomatal_resistance_h_per_m = 0.01,
        .canopy_total_water_potential_megapascal = -0.5,
        .intercepted_water_volume_m3 = 0.001,
    }, test_parameters);
    try std.testing.expect(result.intercepted_water_change_m3_per_h > 0);
    try std.testing.expectEqual(@as(f64, 0), result.transpiration_m3_per_h);
    try std.testing.expectApproxEqAbs(result.intercepted_water_change_m3_per_h * test_parameters.latent_heat_of_vaporization_megajoules_per_m3, result.latent_heat_flux_megajoules_per_h, 1e-12);
}

test "uptake canopy evaporation cannot exceed intercepted water" {
    const result = try calculate(.{
        .atmospheric_temperature_k = 300,
        .canopy_air_temperature_k = 300,
        .canopy_surface_temperature_k = 310,
        .canopy_air_vapor_fraction = 0.000001,
        .bulk_richardson_coefficient_k = 0,
        .biome_isothermal_boundary_resistance_h_per_m = 0.005,
        .aerodynamic_resistance_below_biome_h_per_m = 0.01,
        .aerodynamic_resistance_below_species_h_per_m = 0.004,
        .species_canopy_radiation_fraction = 0.5,
        .latent_boundary_numerator_m2_per_h = 0.1,
        .sensible_boundary_numerator_megajoules_per_m_h_k = 0.02,
        .sensible_surface_resistance_h_per_m = 0.004,
        .latent_surface_resistance_h_per_m = 0.002,
        .stomatal_resistance_h_per_m = 0.01,
        .canopy_total_water_potential_megapascal = -1,
        .intercepted_water_volume_m3 = 0.0001,
    }, test_parameters);
    try std.testing.expectApproxEqAbs(-0.0001, result.intercepted_water_change_m3_per_h, 1e-15);
    try std.testing.expect(result.transpiration_m3_per_h < 0);
}

test "runtime tiled canopy exchange supports more than five species and conserves air flux" {
    const species_count: usize = 7;
    var state = try State.init(std.testing.allocator, 1, species_count);
    defer state.deinit();
    const temperatures = [_]f64{310} ** species_count;
    const below_species = [_]f64{0.004} ** species_count;
    const radiation_fraction = [_]f64{0.1} ** species_count;
    const sensible_resistance = [_]f64{0.004} ** species_count;
    const latent_resistance = [_]f64{0.002} ** species_count;
    const stomatal_resistance = [_]f64{0.01} ** species_count;
    const water_potential = [_]f64{-1} ** species_count;
    const intercepted_water = [_]f64{0.0001} ** species_count;
    var context: ApplyContext = .{
        .state = &state,
        .inputs = .{
            .atmospheric_temperature_k_by_cell = &.{300},
            .canopy_air_temperature_k = &temperatures,
            .canopy_air_vapor_fraction = &([_]f64{0.000001} ** species_count),
            .bulk_richardson_coefficient_k_by_cell = &.{0},
            .biome_isothermal_boundary_resistance_h_per_m_by_cell = &.{0.005},
            .latent_boundary_numerator_m2_per_h_by_cell = &.{0.1},
            .sensible_boundary_numerator_megajoules_per_m_h_k_by_cell = &.{0.02},
            .canopy_surface_temperature_k = &temperatures,
            .aerodynamic_resistance_below_biome_h_per_m_by_cell = &.{0.01},
            .aerodynamic_resistance_below_species_h_per_m = &below_species,
            .species_canopy_radiation_fraction = &radiation_fraction,
            .sensible_surface_resistance_h_per_m = &sensible_resistance,
            .latent_surface_resistance_h_per_m = &latent_resistance,
            .stomatal_resistance_h_per_m = &stomatal_resistance,
            .canopy_total_water_potential_megapascal = &water_potential,
            .intercepted_water_volume_m3 = &intercepted_water,
        },
        .parameters = test_parameters,
    };
    try applyTile(&context, .{ .first = 0, .end = 1 });
    try state.validateFinite();
    var sensible_source = [_]f64{0};
    var vapor_source = [_]f64{0};
    try addGroundAirSourcesTile(state, .{ .first = 0, .end = 1 }, &sensible_source, &vapor_source);
    var expected_sensible: f64 = 0;
    var expected_vapor: f64 = 0;
    for (0..species_count) |species| {
        expected_sensible -= state.sensible_heat_flux_megajoules_per_h[species];
        expected_vapor -= state.intercepted_water_change_m3_per_h[species] + state.transpiration_m3_per_h[species];
    }
    try std.testing.expectApproxEqAbs(expected_sensible, sensible_source[0], 1e-15);
    try std.testing.expectApproxEqAbs(expected_vapor, vapor_source[0], 1e-15);
}

test "UPTAKE runtime surface workspace derives vapor fraction and stomatal resistance" {
    var workspace = try SurfaceInputWorkspace.init(std.testing.allocator, 2);
    defer workspace.deinit();
    try workspace.refresh(
        &.{ 290, 300 },
        &.{ 1.2, 1.5 },
        &.{ 0.003, 0.004 },
        &.{ 0.03, 0.04 },
        &.{ -0.2, -0.3 },
        &.{ 1.0, 0.5 },
        0.00139,
        0.0278,
        test_parameters,
    );
    try std.testing.expectApproxEqAbs(1.2 * test_parameters.saturation_vapor_prefactor_k / 290.0, workspace.canopy_air_vapor_fraction[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.003 + (0.03 - 0.003) * @exp(-0.2), workspace.stomatal_resistance_h_per_m[0], 1e-15);
    try std.testing.expectEqual(@as(f64, 0.00139), workspace.sensible_surface_resistance_h_per_m[1]);
    try std.testing.expectEqual(@as(f64, 0.0278), workspace.latent_surface_resistance_h_per_m[1]);
}

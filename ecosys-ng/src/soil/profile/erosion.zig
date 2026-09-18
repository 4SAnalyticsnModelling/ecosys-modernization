const std = @import("std");
const sediment_routing = @import("../../erosion/sediment_routing.zig");
const numerics = @import("../../core/numerics.zig");

pub const RuntimeState = struct {
    allocator: std.mem.Allocator,
    cell_count: usize,
    surface_sediment_megagrams: []f64,
    local_detachment_megagrams: []f64,
    transportable_sediment_megagrams: []f64,
    /// REDIST TSEDSK: mineral sediment settled from the pond this hour (Mg).
    pond_settled_sediment_megagrams: []f64,
    /// HOUR1 BKVLNM: immutable initial surface mineral carrier
    /// SAND + SILT + CLAY (Mg). BKVLNU is rebuilt from this anchor every hour.
    minimum_surface_mineral_mass_megagrams: []f64,
    surface_soil_mass_megagrams: []f64,
    surface_soil_mass_initialized: []bool,
    east_boundary_open: []bool,
    west_boundary_open: []bool,
    south_boundary_open: []bool,
    north_boundary_open: []bool,
    routing: sediment_routing.RoutingState,

    pub fn init(allocator: std.mem.Allocator, columns: usize, rows: usize) !RuntimeState {
        const count = try std.math.mul(usize, columns, rows);
        if (count == 0) return error.InvalidSedimentGridDimensions;
        var result: RuntimeState = undefined;
        result.allocator = allocator;
        result.cell_count = count;
        var allocated: usize = 0;
        errdefer {
            inline for (@typeInfo(RuntimeState).@"struct".fields) |field| if ((field.type == []f64 or field.type == []bool) and allocated > 0) {
                allocated -= 1;
                allocator.free(@field(result, field.name));
            };
        }
        inline for (@typeInfo(RuntimeState).@"struct".fields) |field| {
            if (field.type == []f64) {
                @field(result, field.name) = try allocator.alloc(f64, count);
                @memset(@field(result, field.name), 0);
                allocated += 1;
            } else if (field.type == []bool) {
                @field(result, field.name) = try allocator.alloc(bool, count);
                @memset(@field(result, field.name), false);
                allocated += 1;
            }
        }
        result.routing = try sediment_routing.RoutingState.init(allocator, columns, rows);
        return result;
    }

    pub fn deinit(self: *RuntimeState) void {
        self.routing.deinit();
        inline for (@typeInfo(RuntimeState).@"struct".fields) |field| if (field.type == []f64 or field.type == []bool) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    /// Capture BKVLNM once. Accepted erosion/deposition may change the live
    /// texture inventories, but must never move this initial HOUR1 anchor.
    pub fn ensureMinimumSurfaceMineralMass(
        self: *RuntimeState,
        cell: usize,
        sand_megagrams: f64,
        silt_megagrams: f64,
        clay_megagrams: f64,
    ) !f64 {
        if (cell >= self.cell_count) return error.ErosionCellOutOfBounds;
        inline for (.{ sand_megagrams, silt_megagrams, clay_megagrams }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteErosionInput;
        if (sand_megagrams < 0 or silt_megagrams < 0 or clay_megagrams < 0)
            return error.InvalidErosionInput;
        if (!self.surface_soil_mass_initialized[cell]) {
            const mineral_mass = sand_megagrams + silt_megagrams + clay_megagrams;
            if (!std.math.isFinite(mineral_mass) or mineral_mass <= 0)
                return error.InvalidErosionInput;
            self.minimum_surface_mineral_mass_megagrams[cell] = mineral_mass;
            self.surface_soil_mass_initialized[cell] = true;
        }
        const minimum = self.minimum_surface_mineral_mass_megagrams[cell];
        if (!std.math.isFinite(minimum) or minimum <= 0)
            return error.InvalidErosionInput;
        return minimum;
    }
};

pub const SourceShapedSurfaceInputs = struct {
    canonical_matrix_soil_mass_megagrams: f64,
    minimum_surface_mineral_mass_megagrams: f64,
    sand_megagrams: f64,
    silt_megagrams: f64,
    clay_megagrams: f64,
    total_organic_carbon_g: f64,
    residue_organic_carbon_g: f64,
};

pub const SourceShapedSurface = struct {
    /// BKVLNU: soil-mass denominator used by erosion transport.
    surface_soil_mass_megagrams: f64,
    /// BKVLNX: current mineral + organic matter carrier used only to derive
    /// the five surface particle fractions.
    property_carrier_megagrams: f64,
    sand_mass_fraction: f64,
    silt_mass_fraction: f64,
    clay_mass_fraction: f64,
    humus_mass_fraction: f64,
    residue_mass_fraction: f64,
};

/// Source HOUR1 carrier equations:
/// BKVLNU=max(BKVL,BKVLNM+1.82E-6*ORGCZ)
/// BKVLNX=SAND+SILT+CLAY+1.82E-6*ORGCZ.
/// The current five particle fractions all use BKVLNX independently; BKVLNU
/// is deliberately not substituted as their denominator.
pub fn deriveSourceShapedSurface(inputs: SourceShapedSurfaceInputs) !SourceShapedSurface {
    inline for (@typeInfo(SourceShapedSurfaceInputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteErosionInput;
    if (inputs.canonical_matrix_soil_mass_megagrams <= 0 or
        inputs.minimum_surface_mineral_mass_megagrams <= 0 or
        inputs.sand_megagrams < 0 or
        inputs.silt_megagrams < 0 or
        inputs.clay_megagrams < 0 or
        inputs.total_organic_carbon_g < 0 or
        inputs.residue_organic_carbon_g < 0 or
        inputs.residue_organic_carbon_g > inputs.total_organic_carbon_g)
        return error.InvalidErosionInput;

    const organic_matter_megagrams = 1.82e-6 * inputs.total_organic_carbon_g;
    const residue_megagrams = 1.82e-6 * inputs.residue_organic_carbon_g;
    const humus_megagrams = organic_matter_megagrams - residue_megagrams;
    const property_carrier = inputs.sand_megagrams + inputs.silt_megagrams +
        inputs.clay_megagrams + organic_matter_megagrams;
    const surface_soil_mass = @max(
        inputs.canonical_matrix_soil_mass_megagrams,
        inputs.minimum_surface_mineral_mass_megagrams + organic_matter_megagrams,
    );
    if (!std.math.isFinite(property_carrier) or property_carrier <= 0 or
        !std.math.isFinite(surface_soil_mass) or surface_soil_mass <= 0)
        return error.InvalidErosionInput;
    return .{
        .surface_soil_mass_megagrams = surface_soil_mass,
        .property_carrier_megagrams = property_carrier,
        .sand_mass_fraction = inputs.sand_megagrams / property_carrier,
        .silt_mass_fraction = inputs.silt_megagrams / property_carrier,
        .clay_mass_fraction = inputs.clay_megagrams / property_carrier,
        .humus_mass_fraction = humus_megagrams / property_carrier,
        .residue_mass_fraction = residue_megagrams / property_carrier,
    };
}

pub const SurfacePropertyParameters = struct {
    clay_particle_diameter_um: f64 = 1,
    silt_particle_diameter_um: f64 = 10,
    sand_particle_diameter_um: f64 = 100,
    humus_particle_diameter_um: f64 = 10,
    residue_particle_diameter_um: f64 = 100,
    mineral_particle_density_megagrams_per_m3: f64 = 2.66,
    organic_particle_density_megagrams_per_m3: f64 = 1.30,
    reference_water_viscosity_megagrams_per_m_s: f64,
    viscosity_temperature_intercept: f64,
    viscosity_temperature_coefficient_per_c: f64,
    gravitational_acceleration_m_per_s2: f64 = 9.8,
};

pub const SurfacePropertyInputs = struct {
    sand_mass_fraction: f64,
    silt_mass_fraction: f64,
    clay_mass_fraction: f64,
    humus_mass_fraction: f64,
    residue_mass_fraction: f64,
    root_length_density_m_per_m3: f64,
    surface_temperature_c: f64,
};

pub const SurfaceProperties = struct {
    mean_particle_diameter_um: f64,
    rainfall_detachability_g_per_j: f64,
    runoff_detachability: f64,
    particle_density_megagrams_per_m3: f64,
    settling_velocity_m_per_h: f64,
    transport_capacity_coefficient: f64,
    transport_capacity_exponent: f64,
};

/// HOUR1 surface cohesion and EUROSEM erosion properties. These are refreshed
/// from runtime soil and organic state rather than frozen compile-time values.
pub fn deriveSurfaceProperties(inputs: SurfacePropertyInputs, parameters: SurfacePropertyParameters) !SurfaceProperties {
    inline for (@typeInfo(SurfacePropertyInputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteErosionInput;
    inline for (@typeInfo(SurfacePropertyParameters).@"struct".fields) |field| if (!std.math.isFinite(@field(parameters, field.name))) return error.NonFiniteErosionInput;
    if (inputs.sand_mass_fraction < 0 or inputs.silt_mass_fraction < 0 or inputs.clay_mass_fraction < 0 or inputs.humus_mass_fraction < 0 or inputs.residue_mass_fraction < 0 or inputs.root_length_density_m_per_m3 < 0 or parameters.reference_water_viscosity_megagrams_per_m_s <= 0 or parameters.mineral_particle_density_megagrams_per_m3 <= 1 or parameters.organic_particle_density_megagrams_per_m3 <= 1 or parameters.gravitational_acceleration_m_per_s2 <= 0) return error.InvalidErosionInput;
    const diameter_um =
        parameters.clay_particle_diameter_um * inputs.clay_mass_fraction +
        parameters.silt_particle_diameter_um * inputs.silt_mass_fraction +
        parameters.sand_particle_diameter_um * inputs.sand_mass_fraction +
        parameters.humus_particle_diameter_um * inputs.humus_mass_fraction +
        parameters.residue_particle_diameter_um * inputs.residue_mass_fraction;
    const organic_fraction = std.math.clamp(inputs.humus_mass_fraction + inputs.residue_mass_fraction, 0, 1);
    const cohesion_kpa = 2 + 5 * inputs.residue_mass_fraction + 5 * inputs.humus_mass_fraction + 5 * inputs.clay_mass_fraction + 5 * (1 - @exp(-1.0e-5 * inputs.root_length_density_m_per_m3));
    const particle_density = parameters.organic_particle_density_megagrams_per_m3 * organic_fraction + parameters.mineral_particle_density_megagrams_per_m3 * (1 - organic_fraction);
    const viscosity = parameters.reference_water_viscosity_megagrams_per_m_s * @exp(parameters.viscosity_temperature_intercept - parameters.viscosity_temperature_coefficient_per_c * inputs.surface_temperature_c);
    const settling_velocity = 3.6e3 * parameters.gravitational_acceleration_m_per_s2 * (particle_density - 1) * std.math.pow(f64, 1.0e-6 * diameter_um, 2) / (18 * viscosity);
    const result: SurfaceProperties = .{
        .mean_particle_diameter_um = diameter_um,
        .rainfall_detachability_g_per_j = 1.0e-6 * (1.5 + 2.5 * (1 - inputs.silt_mass_fraction - inputs.residue_mass_fraction)),
        .runoff_detachability = 0.79 * @exp(-0.85 * cohesion_kpa),
        .particle_density_megagrams_per_m3 = particle_density,
        .settling_velocity_m_per_h = settling_velocity,
        .transport_capacity_coefficient = std.math.pow(f64, (diameter_um + 5) / 0.32, -0.6),
        .transport_capacity_exponent = std.math.pow(f64, (diameter_um + 5) / 300, 0.25),
    };
    inline for (@typeInfo(SurfaceProperties).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.NonFiniteErosionResult;
    return result;
}

pub const StepInputs = struct {
    erosion_enabled: bool,
    surface_soil_bulk_density_megagrams_per_m3: f64,
    surface_soil_mass_megagrams: f64,
    surface_soil_water_m3: f64,
    surface_soil_pore_volume_m3: f64,
    excess_surface_water_m3: f64,
    excess_surface_ice_m3: f64,
    surface_ponding_capacity_m3: f64,
    sediment_in_surface_water_megagrams: f64,
    rainfall_kinetic_energy_j: f64,
    soil_rainfall_detachability_g_per_j: f64,
    soil_runoff_detachability: f64,
    sediment_settling_velocity_m_per_h: f64,
    grid_cell_area_m2: f64,
    soil_matrix_fraction: f64,
    snow_free_fraction: f64,
    runoff_velocity_m_per_s: f64,
    slope_sine: f64,
    surface_particle_density_megagrams_per_m3: f64,
    transport_capacity_coefficient: f64,
    transport_capacity_exponent: f64,
    maximum_erodible_soil_fraction_per_step: f64,
    water_transport_timestep_h: f64,
    negligible_volume_m3: f64,
    negligible_mass_megagrams: f64,
};

pub const StepResult = struct {
    rainfall_detachment_megagrams: f64,
    immobile_water_deposition_megagrams: f64,
    runoff_detachment_or_deposition_megagrams: f64,
    net_detachment_megagrams: f64,
    runoff_sediment_capacity_megagrams_per_m3: f64,
    surface_sediment_concentration_megagrams_per_m3: f64,
};

pub const HourlySolveOptions = struct {
    absolute_tolerance_megagrams: f64,
    relative_tolerance: f64,
    picard_relaxation: f64,
    /// The runtime NPH input is a convergence ceiling, not a sub-hour loop.
    max_iterations: u16,
};

pub const HourlySolveResult = struct {
    local: StepResult,
    final_surface_sediment_megagrams: f64,
    iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
};

/// EROSION RERSED0: sediment available to downslope runoff after local
/// detachment/deposition, limited by both available mass and runoff volume.
pub fn calculateDownslopeTransport_megagrams(surface_sediment_megagrams: f64, net_local_detachment_megagrams: f64, excess_surface_water_m3: f64, downslope_runoff_m3: f64, surface_soil_bulk_density_megagrams_per_m3: f64, negligible_volume_m3: f64) !f64 {
    const values = [_]f64{ surface_sediment_megagrams, net_local_detachment_megagrams, excess_surface_water_m3, downslope_runoff_m3, surface_soil_bulk_density_megagrams_per_m3, negligible_volume_m3 };
    for (values) |value| if (!std.math.isFinite(value)) return error.NonFiniteErosionInput;
    if (surface_sediment_megagrams < 0 or excess_surface_water_m3 < 0 or downslope_runoff_m3 < 0 or surface_soil_bulk_density_megagrams_per_m3 < 0 or negligible_volume_m3 < 0) return error.InvalidErosionInput;
    if (downslope_runoff_m3 <= 0 or surface_soil_bulk_density_megagrams_per_m3 <= 0 or excess_surface_water_m3 <= negligible_volume_m3) return 0;
    const available_sediment_megagrams = @max(0, surface_sediment_megagrams + net_local_detachment_megagrams);
    const concentration_megagrams_per_m3 = available_sediment_megagrams / excess_surface_water_m3;
    return @min(available_sediment_megagrams, concentration_megagrams_per_m3 * downslope_runoff_m3);
}

/// Ports EROSION's cell-local source terms. It is called once for each
/// converged hydrology step; the former NPH full-cycle repetition is absent.
pub fn calculateLocalStep(inputs: StepInputs) !StepResult {
    var result: StepResult = .{ .rainfall_detachment_megagrams = 0, .immobile_water_deposition_megagrams = 0, .runoff_detachment_or_deposition_megagrams = 0, .net_detachment_megagrams = 0, .runoff_sediment_capacity_megagrams_per_m3 = 0, .surface_sediment_concentration_megagrams_per_m3 = 0 };
    if (!inputs.erosion_enabled) return result;
    try validate(inputs);

    const water_fraction = std.math.clamp(inputs.excess_surface_water_m3 / inputs.surface_ponding_capacity_m3, 0, 1);
    const ice_fraction = std.math.clamp(inputs.excess_surface_ice_m3 / inputs.surface_ponding_capacity_m3, 0, 1);
    const mobile_surface_fraction = (1 - ice_fraction) * water_fraction;
    const soil_mass_limit_megagrams = inputs.surface_soil_mass_megagrams * inputs.maximum_erodible_soil_fraction_per_step;

    if (inputs.surface_soil_bulk_density_megagrams_per_m3 > 0 and inputs.rainfall_kinetic_energy_j > 0 and inputs.excess_surface_water_m3 > inputs.negligible_volume_m3) {
        const water_attenuated_detachability_g_per_j = inputs.soil_rainfall_detachability_g_per_j * (1 + 2 * inputs.surface_soil_water_m3 / inputs.surface_soil_pore_volume_m3);
        result.rainfall_detachment_megagrams = @min(soil_mass_limit_megagrams, water_attenuated_detachability_g_per_j * inputs.rainfall_kinetic_energy_j * inputs.grid_cell_area_m2 * inputs.soil_matrix_fraction * inputs.snow_free_fraction * (1 - ice_fraction));
    }

    if (inputs.surface_soil_bulk_density_megagrams_per_m3 > 0 and inputs.sediment_in_surface_water_megagrams > inputs.negligible_mass_megagrams and inputs.excess_surface_water_m3 > inputs.negligible_volume_m3 and mobile_surface_fraction > 0) {
        result.surface_sediment_concentration_megagrams_per_m3 = @max(0, inputs.sediment_in_surface_water_megagrams / inputs.excess_surface_water_m3);
        result.immobile_water_deposition_megagrams = @max(-inputs.sediment_in_surface_water_megagrams, -inputs.sediment_settling_velocity_m_per_h * result.surface_sediment_concentration_megagrams_per_m3 * inputs.grid_cell_area_m2 * mobile_surface_fraction * inputs.soil_matrix_fraction * inputs.water_transport_timestep_h);
    }

    if (inputs.surface_soil_bulk_density_megagrams_per_m3 > 0 and inputs.excess_surface_water_m3 > inputs.surface_ponding_capacity_m3 and mobile_surface_fraction > 0) {
        const stream_power_cm_per_s = 100 * inputs.runoff_velocity_m_per_s * @abs(inputs.slope_sine);
        result.runoff_sediment_capacity_megagrams_per_m3 = inputs.surface_particle_density_megagrams_per_m3 * inputs.transport_capacity_coefficient * std.math.pow(f64, @max(0, stream_power_cm_per_s - 0.4), inputs.transport_capacity_exponent);
        result.surface_sediment_concentration_megagrams_per_m3 = @max(0, inputs.sediment_in_surface_water_megagrams / inputs.excess_surface_water_m3);
        const concentration_difference = result.runoff_sediment_capacity_megagrams_per_m3 - result.surface_sediment_concentration_megagrams_per_m3;
        const potential_megagrams = inputs.sediment_settling_velocity_m_per_h * concentration_difference * inputs.grid_cell_area_m2 * mobile_surface_fraction * inputs.soil_matrix_fraction * inputs.water_transport_timestep_h;
        if (concentration_difference > 0) {
            result.runoff_detachment_or_deposition_megagrams = @min(soil_mass_limit_megagrams, inputs.soil_runoff_detachability * potential_megagrams);
        } else if (inputs.sediment_in_surface_water_megagrams > inputs.negligible_mass_megagrams) {
            result.runoff_detachment_or_deposition_megagrams = @max(-inputs.sediment_in_surface_water_megagrams, potential_megagrams);
        }
    }
    result.net_detachment_megagrams = @max(
        -inputs.sediment_in_surface_water_megagrams,
        result.rainfall_detachment_megagrams + result.immobile_water_deposition_megagrams + result.runoff_detachment_or_deposition_megagrams,
    );
    if (!std.math.isFinite(result.net_detachment_megagrams)) return error.NonFiniteErosionResult;
    return result;
}

const HourlyBalance = struct {
    inputs: StepInputs,
    initial_sediment_megagrams: f64,
    rainfall_detachment_megagrams: f64,
    upper_sediment_megagrams: f64,

    fn source(self: HourlyBalance, suspended_sediment_megagrams: f64) f64 {
        const flux = concentrationDependentFluxes(
            self.inputs,
            suspended_sediment_megagrams,
        );
        return self.rainfall_detachment_megagrams +
            flux.immobile_water_deposition_megagrams +
            flux.runoff_detachment_or_deposition_megagrams;
    }
};

fn hourlyResidual(balance: HourlyBalance, suspended_sediment_megagrams: f64) f64 {
    return suspended_sediment_megagrams -
        balance.initial_sediment_megagrams -
        balance.source(suspended_sediment_megagrams);
}

fn hourlyPicard(balance: HourlyBalance, suspended_sediment_megagrams: f64) f64 {
    return std.math.clamp(
        balance.initial_sediment_megagrams + balance.source(suspended_sediment_megagrams),
        0,
        balance.upper_sediment_megagrams,
    );
}

const ConcentrationFluxes = struct {
    immobile_water_deposition_megagrams: f64,
    runoff_detachment_or_deposition_megagrams: f64,
    runoff_sediment_capacity_megagrams_per_m3: f64,
    surface_sediment_concentration_megagrams_per_m3: f64,
};

fn concentrationDependentFluxes(
    inputs: StepInputs,
    suspended_sediment_megagrams: f64,
) ConcentrationFluxes {
    var result: ConcentrationFluxes = .{
        .immobile_water_deposition_megagrams = 0,
        .runoff_detachment_or_deposition_megagrams = 0,
        .runoff_sediment_capacity_megagrams_per_m3 = 0,
        .surface_sediment_concentration_megagrams_per_m3 = 0,
    };
    const water_fraction = std.math.clamp(
        inputs.excess_surface_water_m3 / inputs.surface_ponding_capacity_m3,
        0,
        1,
    );
    const ice_fraction = std.math.clamp(
        inputs.excess_surface_ice_m3 / inputs.surface_ponding_capacity_m3,
        0,
        1,
    );
    const mobile_surface_fraction = (1 - ice_fraction) * water_fraction;
    const soil_mass_limit_megagrams =
        inputs.surface_soil_mass_megagrams *
        inputs.maximum_erodible_soil_fraction_per_step;
    if (inputs.surface_soil_bulk_density_megagrams_per_m3 > 0 and
        suspended_sediment_megagrams > inputs.negligible_mass_megagrams and
        inputs.excess_surface_water_m3 > inputs.negligible_volume_m3 and
        mobile_surface_fraction > 0)
    {
        result.surface_sediment_concentration_megagrams_per_m3 =
            suspended_sediment_megagrams / inputs.excess_surface_water_m3;
        result.immobile_water_deposition_megagrams = @max(
            -suspended_sediment_megagrams,
            -inputs.sediment_settling_velocity_m_per_h *
                result.surface_sediment_concentration_megagrams_per_m3 *
                inputs.grid_cell_area_m2 *
                mobile_surface_fraction *
                inputs.soil_matrix_fraction *
                inputs.water_transport_timestep_h,
        );
    }
    if (inputs.surface_soil_bulk_density_megagrams_per_m3 > 0 and
        inputs.excess_surface_water_m3 > inputs.surface_ponding_capacity_m3 and
        mobile_surface_fraction > 0)
    {
        const stream_power_cm_per_s =
            100 * inputs.runoff_velocity_m_per_s * @abs(inputs.slope_sine);
        result.runoff_sediment_capacity_megagrams_per_m3 =
            inputs.surface_particle_density_megagrams_per_m3 *
            inputs.transport_capacity_coefficient *
            std.math.pow(
                f64,
                @max(0, stream_power_cm_per_s - 0.4),
                inputs.transport_capacity_exponent,
            );
        result.surface_sediment_concentration_megagrams_per_m3 =
            suspended_sediment_megagrams / inputs.excess_surface_water_m3;
        const concentration_difference =
            result.runoff_sediment_capacity_megagrams_per_m3 -
            result.surface_sediment_concentration_megagrams_per_m3;
        const potential_megagrams =
            inputs.sediment_settling_velocity_m_per_h *
            concentration_difference *
            inputs.grid_cell_area_m2 *
            mobile_surface_fraction *
            inputs.soil_matrix_fraction *
            inputs.water_transport_timestep_h;
        if (concentration_difference > 0) {
            result.runoff_detachment_or_deposition_megagrams =
                @min(soil_mass_limit_megagrams, inputs.soil_runoff_detachability * potential_megagrams);
        } else if (suspended_sediment_megagrams > inputs.negligible_mass_megagrams) {
            result.runoff_detachment_or_deposition_megagrams =
                @max(-suspended_sediment_megagrams, potential_megagrams);
        }
    }
    return result;
}

/// Replaces EROSION's repeated NPH mutation of `SED` with one bounded
/// backward-Euler balance. Newton–Raphson is attempted first and Picard is
/// the safeguarded fallback. The caller-provided NPH is only the maximum
/// number of nonlinear iterations and the solve exits as soon as its
/// extensive sediment residual converges.
pub fn calculateConvergedHourlyLocalStep(
    inputs: StepInputs,
    options: HourlySolveOptions,
) !HourlySolveResult {
    try validate(inputs);
    if (!std.math.isFinite(options.absolute_tolerance_megagrams) or
        options.absolute_tolerance_megagrams <= 0 or
        !std.math.isFinite(options.relative_tolerance) or
        options.relative_tolerance <= 0 or
        !std.math.isFinite(options.picard_relaxation) or
        options.picard_relaxation <= 0 or
        options.picard_relaxation > 1 or
        options.max_iterations == 0)
        return error.InvalidErosionSolverOptions;
    if (!inputs.erosion_enabled) return .{
        .local = .{
            .rainfall_detachment_megagrams = 0,
            .immobile_water_deposition_megagrams = 0,
            .runoff_detachment_or_deposition_megagrams = 0,
            .net_detachment_megagrams = 0,
            .runoff_sediment_capacity_megagrams_per_m3 = 0,
            .surface_sediment_concentration_megagrams_per_m3 = 0,
        },
        .final_surface_sediment_megagrams = inputs.sediment_in_surface_water_megagrams,
        .iterations = 0,
        .newton_raphson_steps = 0,
        .picard_steps = 0,
    };

    var rainfall_only = inputs;
    rainfall_only.sediment_in_surface_water_megagrams = 0;
    rainfall_only.sediment_settling_velocity_m_per_h = 0;
    const rainfall_detachment_megagrams =
        (try calculateLocalStep(rainfall_only)).rainfall_detachment_megagrams;
    const soil_mass_limit_megagrams =
        inputs.surface_soil_mass_megagrams *
        inputs.maximum_erodible_soil_fraction_per_step;
    const upper_sediment_megagrams =
        inputs.sediment_in_surface_water_megagrams +
        rainfall_detachment_megagrams +
        soil_mass_limit_megagrams +
        @max(options.absolute_tolerance_megagrams, std.math.floatEps(f64));
    if (upper_sediment_megagrams <= options.absolute_tolerance_megagrams) return .{
        .local = .{
            .rainfall_detachment_megagrams = rainfall_detachment_megagrams,
            .immobile_water_deposition_megagrams = 0,
            .runoff_detachment_or_deposition_megagrams = 0,
            .net_detachment_megagrams = rainfall_detachment_megagrams,
            .runoff_sediment_capacity_megagrams_per_m3 = 0,
            .surface_sediment_concentration_megagrams_per_m3 = 0,
        },
        .final_surface_sediment_megagrams = rainfall_detachment_megagrams,
        .iterations = 0,
        .newton_raphson_steps = 0,
        .picard_steps = 0,
    };
    const balance: HourlyBalance = .{
        .inputs = inputs,
        .initial_sediment_megagrams = inputs.sediment_in_surface_water_megagrams,
        .rainfall_detachment_megagrams = rainfall_detachment_megagrams,
        .upper_sediment_megagrams = upper_sediment_megagrams,
    };
    const solved = try numerics.newtonPicardFiniteDifference(
        balance,
        hourlyResidual,
        hourlyPicard,
        0,
        upper_sediment_megagrams,
        std.math.clamp(
            inputs.sediment_in_surface_water_megagrams + rainfall_detachment_megagrams,
            0,
            upper_sediment_megagrams,
        ),
        .{
            .absolute_tolerance = options.absolute_tolerance_megagrams,
            .relative_tolerance = options.relative_tolerance,
            .picard_relaxation = options.picard_relaxation,
            .residual_scale = @max(
                options.absolute_tolerance_megagrams,
                inputs.sediment_in_surface_water_megagrams + rainfall_detachment_megagrams,
            ),
            .max_iterations = options.max_iterations,
            .safeguard_with_bracket = true,
        },
    );
    const flux = concentrationDependentFluxes(inputs, solved.root);
    const net_detachment_megagrams =
        solved.root - inputs.sediment_in_surface_water_megagrams;
    if (!std.math.isFinite(net_detachment_megagrams) or solved.root < 0)
        return error.NonFiniteErosionResult;
    return .{
        .local = .{
            .rainfall_detachment_megagrams = rainfall_detachment_megagrams,
            .immobile_water_deposition_megagrams = flux.immobile_water_deposition_megagrams,
            // Close the accepted extensive balance exactly; the residual is
            // below tolerance but must not enter the authoritative ledger.
            .runoff_detachment_or_deposition_megagrams = net_detachment_megagrams -
                rainfall_detachment_megagrams -
                flux.immobile_water_deposition_megagrams,
            .net_detachment_megagrams = net_detachment_megagrams,
            .runoff_sediment_capacity_megagrams_per_m3 = flux.runoff_sediment_capacity_megagrams_per_m3,
            .surface_sediment_concentration_megagrams_per_m3 = flux.surface_sediment_concentration_megagrams_per_m3,
        },
        .final_surface_sediment_megagrams = solved.root,
        .iterations = solved.iterations,
        .newton_raphson_steps = solved.newton_raphson_steps,
        .picard_steps = solved.picard_steps,
    };
}

fn validate(inputs: StepInputs) !void {
    inline for (@typeInfo(StepInputs).@"struct".fields) |field| if (field.type == f64 and !std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteErosionInput;
    if (inputs.surface_soil_bulk_density_megagrams_per_m3 < 0 or inputs.surface_soil_mass_megagrams < 0 or inputs.surface_soil_water_m3 < 0 or inputs.surface_soil_pore_volume_m3 <= 0 or inputs.excess_surface_water_m3 < 0 or inputs.excess_surface_ice_m3 < 0 or inputs.surface_ponding_capacity_m3 <= 0 or inputs.sediment_in_surface_water_megagrams < 0 or inputs.rainfall_kinetic_energy_j < 0 or inputs.soil_rainfall_detachability_g_per_j < 0 or inputs.soil_runoff_detachability < 0 or inputs.sediment_settling_velocity_m_per_h < 0 or inputs.grid_cell_area_m2 <= 0 or inputs.soil_matrix_fraction < 0 or inputs.soil_matrix_fraction > 1 or inputs.snow_free_fraction < 0 or inputs.snow_free_fraction > 1 or inputs.surface_particle_density_megagrams_per_m3 < 0 or inputs.transport_capacity_coefficient < 0 or inputs.transport_capacity_exponent < 0 or inputs.maximum_erodible_soil_fraction_per_step < 0 or inputs.maximum_erodible_soil_fraction_per_step > 1 or inputs.water_transport_timestep_h <= 0 or inputs.negligible_volume_m3 < 0 or inputs.negligible_mass_megagrams < 0) return error.InvalidErosionInput;
}

fn baseline() StepInputs {
    return .{ .erosion_enabled = true, .surface_soil_bulk_density_megagrams_per_m3 = 1.2, .surface_soil_mass_megagrams = 100, .surface_soil_water_m3 = 0.2, .surface_soil_pore_volume_m3 = 1, .excess_surface_water_m3 = 2, .excess_surface_ice_m3 = 0, .surface_ponding_capacity_m3 = 1, .sediment_in_surface_water_megagrams = 0.2, .rainfall_kinetic_energy_j = 1, .soil_rainfall_detachability_g_per_j = 0.01, .soil_runoff_detachability = 0.5, .sediment_settling_velocity_m_per_h = 0.01, .grid_cell_area_m2 = 10, .soil_matrix_fraction = 0.8, .snow_free_fraction = 1, .runoff_velocity_m_per_s = 0.01, .slope_sine = 0.1, .surface_particle_density_megagrams_per_m3 = 2.65, .transport_capacity_coefficient = 1, .transport_capacity_exponent = 1, .maximum_erodible_soil_fraction_per_step = 0.01, .water_transport_timestep_h = 0.25, .negligible_volume_m3 = 1e-12, .negligible_mass_megagrams = 1e-12 };
}

test "rainfall detachment preserves EROSION water attenuation and soil mass cap" {
    var inputs = baseline();
    inputs.rainfall_kinetic_energy_j = 100;
    const result = try calculateLocalStep(inputs);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.rainfall_detachment_megagrams, 1e-12);
}

test "inactive EROSION guard skips dormant local inputs before validation" {
    var inputs = baseline();
    inputs.erosion_enabled = false;
    inputs.surface_soil_pore_volume_m3 = 0;
    inputs.rainfall_kinetic_energy_j = std.math.nan(f64);
    const result = try calculateLocalStep(inputs);
    try std.testing.expectEqual(@as(f64, 0), result.rainfall_detachment_megagrams);
    try std.testing.expectEqual(@as(f64, 0), result.net_detachment_megagrams);
}

test "ponded surface makes the D50 divergence from HOUR1 inert" {
    // `hour1.f:2955--2961` computes D50 only when
    // `BKDS(NU).GT.ZERO`, and forces `D50=0` for a ponded surface cell.
    // `deriveSurfaceProperties` has no such branch: it always builds D50 from
    // texture, so for a ponded cell production carries a nonzero D50, and
    // hence nonzero CER/XER/VLS, where HOUR1 carries zero. This guard records
    // why that is inert rather than a defect: every consumer of those three
    // properties in `calculateLocalStep` is itself gated on
    // `surface_soil_bulk_density_megagrams_per_m3 > 0` (`erosion.zig:197`,
    // `:202`, `:207`, `:289`, `:306`), which is the same BKDS predicate. So the
    // divergent values are never read on the ponded branch.
    var inputs = baseline();
    inputs.surface_soil_bulk_density_megagrams_per_m3 = 0;
    // Give the transport properties deliberately hostile values: these are what
    // a texture-derived D50 would supply where HOUR1 would supply zero.
    inputs.transport_capacity_coefficient = 1e6;
    inputs.transport_capacity_exponent = 3;
    inputs.sediment_settling_velocity_m_per_h = 1e6;
    inputs.soil_rainfall_detachability_g_per_j = 1e6;
    inputs.soil_runoff_detachability = 1e6;
    const ponded = try calculateLocalStep(inputs);
    try std.testing.expectEqual(@as(f64, 0), ponded.rainfall_detachment_megagrams);
    try std.testing.expectEqual(@as(f64, 0), ponded.net_detachment_megagrams);
    // Now the same hostile properties with a soil surface, to prove the zeros
    // above come from the BKDS gate and not from the properties being ignored
    // everywhere. Without this leg the guard would pass vacuously.
    inputs.surface_soil_bulk_density_megagrams_per_m3 = 1.2;
    const soil = try calculateLocalStep(inputs);
    try std.testing.expect(soil.rainfall_detachment_megagrams > 0);
}

test "settling never deposits more sediment than surface water contains" {
    var inputs = baseline();
    inputs.excess_surface_water_m3 = 0.5;
    inputs.sediment_settling_velocity_m_per_h = 100;
    inputs.rainfall_kinetic_energy_j = 0;
    const result = try calculateLocalStep(inputs);
    try std.testing.expectEqual(@as(f64, -0.2), result.immobile_water_deposition_megagrams);
}

test "combined deposition mechanisms cannot exceed suspended sediment" {
    var inputs = baseline();
    inputs.rainfall_kinetic_energy_j = 0;
    inputs.sediment_settling_velocity_m_per_h = 100;
    const result = try calculateLocalStep(inputs);
    try std.testing.expect(result.net_detachment_megagrams >= -inputs.sediment_in_surface_water_megagrams);
}

test "runoff below stream-power threshold has zero carrying capacity" {
    var inputs = baseline();
    inputs.runoff_velocity_m_per_s = 0.001;
    const result = try calculateLocalStep(inputs);
    try std.testing.expectEqual(@as(f64, 0), result.runoff_sediment_capacity_megagrams_per_m3);
    try std.testing.expect(result.runoff_detachment_or_deposition_megagrams <= 0);
}

test "downslope sediment transport is limited by available sediment" {
    try std.testing.expectEqual(@as(f64, 0.6), try calculateDownslopeTransport_megagrams(0.5, 0.1, 1, 2, 1.2, 1e-12));
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), try calculateDownslopeTransport_megagrams(0.5, 0.1, 2, 0.5, 1.2, 1e-12), 1e-14);
}

test "HOUR1 erosion properties are derived from runtime texture and temperature" {
    const properties = try deriveSurfaceProperties(.{ .sand_mass_fraction = 0.6, .silt_mass_fraction = 0.25, .clay_mass_fraction = 0.15, .humus_mass_fraction = 0, .residue_mass_fraction = 0, .root_length_density_m_per_m3 = 0, .surface_temperature_c = 20 }, .{ .reference_water_viscosity_megagrams_per_m_s = 1.0e-3, .viscosity_temperature_intercept = 0.533, .viscosity_temperature_coefficient_per_c = 0.0267 });
    try std.testing.expectApproxEqAbs(@as(f64, 62.65), properties.mean_particle_diameter_um, 1e-12);
    try std.testing.expect(properties.rainfall_detachability_g_per_j > 0);
    try std.testing.expect(properties.settling_velocity_m_per_h > 0);
}

test "HOUR1 BKVLNM surface mineral anchor is initialized once" {
    var state = try RuntimeState.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try std.testing.expectEqual(
        @as(f64, 100),
        try state.ensureMinimumSurfaceMineralMass(0, 60, 25, 15),
    );
    // Live texture can change after erosion, but BKVLNM is immutable.
    try std.testing.expectEqual(
        @as(f64, 100),
        try state.ensureMinimumSurfaceMineralMass(0, 30, 20, 10),
    );
    try std.testing.expectEqual(
        @as(f64, 100),
        state.minimum_surface_mineral_mass_megagrams[0],
    );
}

test "HOUR1 source surface keeps BKVLNU distinct from BKVLNX" {
    const surface = try deriveSourceShapedSurface(.{
        .canonical_matrix_soil_mass_megagrams = 80,
        .minimum_surface_mineral_mass_megagrams = 100,
        .sand_megagrams = 54,
        .silt_megagrams = 27,
        .clay_megagrams = 9,
        .total_organic_carbon_g = 1.0e6,
        .residue_organic_carbon_g = 0.25e6,
    });
    // BKVLNU=max(80,100+1.82), while BKVLNX=90+1.82.
    try std.testing.expectApproxEqAbs(@as(f64, 101.82), surface.surface_soil_mass_megagrams, 1e-13);
    try std.testing.expectApproxEqAbs(@as(f64, 91.82), surface.property_carrier_megagrams, 1e-13);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        surface.sand_mass_fraction + surface.silt_mass_fraction +
            surface.clay_mass_fraction + surface.humus_mass_fraction +
            surface.residue_mass_fraction,
        2e-15,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 27.0 / 91.82), surface.silt_mass_fraction, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.455 / 91.82), surface.residue_mass_fraction, 1e-15);
}

test "hourly erosion converges before NPH without explicit sub-hour mutation" {
    var inputs = baseline();
    inputs.water_transport_timestep_h = 1;
    // The implicit solve represents the complete hour, so the NPH sequence
    // of per-pass 1/NPH caps becomes one full-hour cap.
    inputs.maximum_erodible_soil_fraction_per_step = 1;
    inputs.sediment_settling_velocity_m_per_h = 0.2;
    const solved = try calculateConvergedHourlyLocalStep(inputs, .{
        .absolute_tolerance_megagrams = 1.0e-12,
        .relative_tolerance = 1.0e-10,
        .picard_relaxation = 0.5,
        .max_iterations = 20,
    });
    try std.testing.expect(solved.iterations < 20);
    try std.testing.expect(solved.newton_raphson_steps + solved.picard_steps > 0);
    try std.testing.expect(solved.final_surface_sediment_megagrams >= 0);
    try std.testing.expectApproxEqAbs(
        solved.final_surface_sediment_megagrams,
        inputs.sediment_in_surface_water_megagrams + solved.local.net_detachment_megagrams,
        1.0e-14,
    );
    try std.testing.expectApproxEqAbs(
        solved.local.net_detachment_megagrams,
        solved.local.rainfall_detachment_megagrams +
            solved.local.immobile_water_deposition_megagrams +
            solved.local.runoff_detachment_or_deposition_megagrams,
        1.0e-14,
    );
}

test "implicit erosion remains nonnegative under stiff settling" {
    var inputs = baseline();
    inputs.rainfall_kinetic_energy_j = 0;
    inputs.sediment_settling_velocity_m_per_h = 1.0e6;
    inputs.water_transport_timestep_h = 1;
    const solved = try calculateConvergedHourlyLocalStep(inputs, .{
        .absolute_tolerance_megagrams = 1.0e-11,
        .relative_tolerance = 1.0e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 20,
    });
    try std.testing.expect(solved.final_surface_sediment_megagrams >= 0);
    try std.testing.expect(solved.final_surface_sediment_megagrams <= inputs.sediment_in_surface_water_megagrams);
}

test "disabled converged erosion returns unchanged sediment without iterations" {
    var inputs = baseline();
    inputs.erosion_enabled = false;
    const solved = try calculateConvergedHourlyLocalStep(inputs, .{
        .absolute_tolerance_megagrams = 1.0e-12,
        .relative_tolerance = 1.0e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 20,
    });
    try std.testing.expectEqual(@as(u16, 0), solved.iterations);
    try std.testing.expectEqual(inputs.sediment_in_surface_water_megagrams, solved.final_surface_sediment_megagrams);
    try std.testing.expectEqual(@as(f64, 0), solved.local.net_detachment_megagrams);
}

test "invalid hourly erosion solve cannot mutate caller state" {
    const inputs = baseline();
    const before = inputs;
    try std.testing.expectError(
        error.InvalidErosionSolverOptions,
        calculateConvergedHourlyLocalStep(inputs, .{
            .absolute_tolerance_megagrams = 1.0e-12,
            .relative_tolerance = 1.0e-8,
            .picard_relaxation = 0.5,
            .max_iterations = 0,
        }),
    );
    try std.testing.expectEqual(before, inputs);
}

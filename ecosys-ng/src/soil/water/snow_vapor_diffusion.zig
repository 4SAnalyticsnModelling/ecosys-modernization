const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");
const snow_cover_fraction = @import("snow_cover_fraction.zig");

pub const Parameters = struct {
    reference_vapor_diffusivity_m2_per_h: f64,
    reference_temperature_k: f64,
    temperature_exponent: f64,
    minimum_air_fraction: f64,
    vapor_sensible_heat_capacity_megajoules_per_m3_k: f64,
};

pub const Options = struct {
    /// WATSUB `XNPYX`: physical integration of `FLVC`.
    physical_time_step_hours: f64,
    /// WATSUB `XNPXX`: donor inventory available to this accepted pass. The
    /// legacy nested loop and a modern whole-step pass do not share this
    /// factor, so it must never be inferred from physical time.
    donor_availability_fraction: f64,
    full_snow_cover_depth_m: f64,
    /// Canonical WATSUB carrier heat capacities used to rebuild `VHCPW` after
    /// vapor mass moves. The transported-vapor coefficient above must match
    /// the liquid/vapor carrier coefficient here.
    thermodynamics: snow.ThermodynamicParameters,
    /// WATSUB `FSNW(DPTHS0)`, frozen before same-substep snowfall.
    snow_cover_fraction_by_cell: []const f64 = &.{},
    /// Accepted signed interface water-equivalent and donor-temperature heat,
    /// indexed by the lower/destination layer. Positive moves downward.
    /// Both must be supplied together; empty preserves isolated-call support.
    accepted_interface_vapor_water_m3: []f64 = &.{},
    accepted_interface_heat_megajoules: []f64 = &.{},
    /// Restrict this call to one local upper-layer face in every cell. The
    /// coupled WATSUB driver advances these faces top-down. In this mode the
    /// helper publishes vapor mass and the donor-temperature carrier ledger
    /// only; the caller retains face-entry capacity/temperature and consumes
    /// pending carrier heat when that destination layer takes its source-order
    /// turn.
    local_face_index: ?usize = null,
    /// Optional temperature frozen at face-entry for FLVC and donor sensible
    /// heat. State energy still starts from the current accepted temperature,
    /// allowing conduction and vapor calculated from one face-entry state to
    /// be applied without either calculation seeing the other's update.
    calculation_temperature_k: []const f64 = &.{},
};

pub const Report = struct { iterations: u16, converged: bool, maximum_interface_flux_m3: f64 };

/// WATSUB 1423--1516 interlayer vapor diffusion. Faces are visited top-down;
/// each next face sees the vapor inventory accepted by the preceding face,
/// matching the source's in-loop `VOLV02(L/L2)` updates. Signed carrier heat
/// uses the current face donor temperature and publication remains atomic.
pub fn solve(allocator: std.mem.Allocator, state: *snow.State, parameters: Parameters, options: Options) !Report {
    inline for (.{ parameters.reference_vapor_diffusivity_m2_per_h, parameters.reference_temperature_k, parameters.temperature_exponent, parameters.minimum_air_fraction, parameters.vapor_sensible_heat_capacity_megajoules_per_m3_k, options.physical_time_step_hours, options.donor_availability_fraction, options.full_snow_cover_depth_m }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowVaporDiffusionParameter;
    if (parameters.reference_vapor_diffusivity_m2_per_h < 0 or parameters.reference_temperature_k <= 0 or parameters.temperature_exponent < 0 or parameters.minimum_air_fraction < 0 or parameters.minimum_air_fraction > 1 or parameters.vapor_sensible_heat_capacity_megajoules_per_m3_k <= 0 or options.physical_time_step_hours <= 0 or options.physical_time_step_hours > 1 or options.donor_availability_fraction <= 0 or options.donor_availability_fraction > 1 or options.full_snow_cover_depth_m <= 0) return error.InvalidSnowVaporDiffusionParameter;
    inline for (std.meta.fields(snow.ThermodynamicParameters)) |field| {
        const value = @field(options.thermodynamics, field.name);
        if (!std.math.isFinite(value) or value <= 0)
            return error.InvalidSnowVaporDiffusionThermodynamics;
    }
    const carrier_scale = @max(
        parameters.vapor_sensible_heat_capacity_megajoules_per_m3_k,
        options.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
    );
    if (@abs(parameters.vapor_sensible_heat_capacity_megajoules_per_m3_k -
        options.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k) >
        8 * std.math.floatEps(f64) * carrier_scale)
        return error.InconsistentSnowVaporHeatCapacity;
    const layer_count = state.cell_count * state.layer_capacity;
    if (options.snow_cover_fraction_by_cell.len != 0 and
        options.snow_cover_fraction_by_cell.len != state.cell_count)
        return error.SnowVaporCoverDimensionMismatch;
    if (options.accepted_interface_vapor_water_m3.len != options.accepted_interface_heat_megajoules.len or
        (options.accepted_interface_vapor_water_m3.len != 0 and
            options.accepted_interface_vapor_water_m3.len != layer_count))
        return error.SnowVaporInterfaceLedgerDimensionMismatch;
    if (options.local_face_index) |face|
        if (face + 1 >= state.layer_capacity) return error.SnowVaporFaceOutOfBounds;
    if (options.calculation_temperature_k.len != 0 and
        options.calculation_temperature_k.len != layer_count)
        return error.SnowVaporCalculationTemperatureDimensionMismatch;
    const vapor = try allocator.dupe(f64, state.vapor_water_equivalent_m3);
    defer allocator.free(vapor);
    const temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(temperature);
    const heat_capacity = try allocator.dupe(f64, state.heat_capacity_megajoules_per_k);
    defer allocator.free(heat_capacity);
    const sensible_energy_megajoules = try allocator.alloc(f64, state.temperature_k.len);
    defer allocator.free(sensible_energy_megajoules);
    for (sensible_energy_megajoules, state.heat_capacity_megajoules_per_k, state.temperature_k, state.solid_snow_water_equivalent_m3, state.liquid_water_volume_m3, state.vapor_water_equivalent_m3, state.ice_volume_m3) |*energy, capacity, temperature_k, solid, liquid, initial_vapor, ice| {
        const canonical_capacity = options.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid +
            options.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (liquid + initial_vapor) +
            options.thermodynamics.ice_heat_capacity_megajoules_per_m3_k * ice;
        const scale = @max(1, @max(@abs(capacity), @abs(canonical_capacity)));
        if (!std.math.isFinite(capacity) or capacity < 0 or
            !std.math.isFinite(canonical_capacity) or
            (options.local_face_index == null and
                @abs(capacity - canonical_capacity) >
                    128 * std.math.floatEps(f64) * scale))
            return error.InconsistentSnowVaporDiffusionHeatCapacity;
        energy.* = capacity * temperature_k;
    }
    for (0..layer_count) |index| {
        inline for (.{
            state.vapor_water_equivalent_m3[index],
            state.air_filled_volume_m3[index],
            state.total_layer_volume_m3[index],
            state.layer_thickness_m[index],
            state.horizontal_area_m2[index],
            temperature[index],
        }) |value| if (!std.math.isFinite(value)) return error.InvalidSnowVaporDiffusionState;
        if (state.vapor_water_equivalent_m3[index] < 0 or
            state.air_filled_volume_m3[index] < 0 or
            state.total_layer_volume_m3[index] < 0 or
            state.layer_thickness_m[index] < 0 or
            state.horizontal_area_m2[index] <= 0 or
            temperature[index] <= 0)
            return error.InvalidSnowVaporDiffusionState;
        if (state.air_filled_volume_m3[index] == 0 and state.vapor_water_equivalent_m3[index] != 0)
            return error.SnowVaporInventoryWithoutAirVolume;
    }
    const accepted_interface_vapor = try allocator.alloc(f64, layer_count);
    defer allocator.free(accepted_interface_vapor);
    const accepted_interface_heat = try allocator.alloc(f64, layer_count);
    defer allocator.free(accepted_interface_heat);
    @memset(accepted_interface_vapor, 0);
    @memset(accepted_interface_heat, 0);
    var maximum_flux: f64 = 0;
    for (0..state.cell_count) |cell| {
        const base = cell * state.layer_capacity;
        // WATSUB 886--892: bind to the sole FSNW owner rather than silently
        // substituting a linear depth ratio.
        const cover = if (options.snow_cover_fraction_by_cell.len == 0)
            (try snow_cover_fraction.evaluate(
                state.cumulative_depth_m[base + state.layer_capacity - 1],
                options.full_snow_cover_depth_m,
            )).snow_fraction
        else
            options.snow_cover_fraction_by_cell[cell];
        if (!std.math.isFinite(cover) or cover < 0 or cover > 1)
            return error.InvalidSnowVaporCoverFraction;
        const first_face = options.local_face_index orelse 0;
        const face_end = if (options.local_face_index) |face| face + 1 else state.layer_capacity -| 1;
        for (first_face..face_end) |layer| {
            const first = base + layer;
            const second = first + 1;
            const first_calculation_temperature = if (options.calculation_temperature_k.len == 0)
                temperature[first]
            else
                options.calculation_temperature_k[first];
            const second_calculation_temperature = if (options.calculation_temperature_k.len == 0)
                temperature[second]
            else
                options.calculation_temperature_k[second];
            if (!std.math.isFinite(first_calculation_temperature) or
                !std.math.isFinite(second_calculation_temperature) or
                first_calculation_temperature <= 0 or second_calculation_temperature <= 0)
                return error.InvalidSnowVaporCalculationTemperature;
            const first_threshold = snow.activation_heat_capacity_megajoules_per_m2_k * state.horizontal_area_m2[first];
            const second_threshold = snow.activation_heat_capacity_megajoules_per_m2_k * state.horizontal_area_m2[second];
            if (state.heat_capacity_megajoules_per_k[first] <= first_threshold or
                state.heat_capacity_megajoules_per_k[second] <= second_threshold or
                state.air_filled_volume_m3[first] <= 0 or state.air_filled_volume_m3[second] <= 0 or
                state.total_layer_volume_m3[first] <= 0 or state.total_layer_volume_m3[second] <= 0)
            {
                continue;
            }
            const first_air_fraction = @max(parameters.minimum_air_fraction, state.air_filled_volume_m3[first] / state.total_layer_volume_m3[first]);
            const second_air_fraction = @max(parameters.minimum_air_fraction, state.air_filled_volume_m3[second] / state.total_layer_volume_m3[second]);
            const first_diffusivity = parameters.reference_vapor_diffusivity_m2_per_h * std.math.pow(f64, first_calculation_temperature / parameters.reference_temperature_k, parameters.temperature_exponent);
            const second_diffusivity = parameters.reference_vapor_diffusivity_m2_per_h * std.math.pow(f64, second_calculation_temperature / parameters.reference_temperature_k, parameters.temperature_exponent);
            const first_conductivity = first_air_fraction * first_air_fraction * first_diffusivity;
            const second_conductivity = second_air_fraction * second_air_fraction * second_diffusivity;
            const denominator = first_conductivity * state.layer_thickness_m[second] + second_conductivity * state.layer_thickness_m[first];
            const conductance_m_per_h = if (denominator > 0)
                2 * first_conductivity * second_conductivity / denominator
            else
                0;
            if (!std.math.isFinite(conductance_m_per_h) or conductance_m_per_h < 0)
                return error.InvalidSnowVaporDiffusionConductance;
            const first_concentration = @max(0, vapor[first] / state.air_filled_volume_m3[first]);
            const second_concentration = @max(0, vapor[second] / state.air_filled_volume_m3[second]);
            const unlimited_flux_m3 = conductance_m_per_h *
                (first_concentration - second_concentration) *
                state.horizontal_area_m2[first] * cover * options.physical_time_step_hours;
            // WATSUB 1507--1512. Its XNPXX availability multiplier is the
            // donor fraction, intentionally separate from `XNPYX`.
            const flux_m3 = if (unlimited_flux_m3 >= 0)
                @max(0, @min(unlimited_flux_m3, vapor[first] * options.donor_availability_fraction))
            else
                @min(0, @max(unlimited_flux_m3, -vapor[second] * options.donor_availability_fraction));
            maximum_flux = @max(maximum_flux, @abs(flux_m3));
            const donor = if (flux_m3 >= 0) first else second;
            const donor_temperature = if (donor == first) first_calculation_temperature else second_calculation_temperature;
            const heat_megajoules = parameters.vapor_sensible_heat_capacity_megajoules_per_m3_k * donor_temperature * flux_m3;
            if (!std.math.isFinite(flux_m3) or !std.math.isFinite(heat_megajoules))
                return error.InvalidSnowVaporInterfaceLedger;
            accepted_interface_vapor[second] = flux_m3;
            accepted_interface_heat[second] = heat_megajoules;
            vapor[first] -= flux_m3;
            vapor[second] += flux_m3;
            sensible_energy_megajoules[first] -= heat_megajoules;
            sensible_energy_megajoules[second] += heat_megajoules;
        }
    }
    // A face-local source-order call deliberately leaves the destination's
    // added vapor capacity represented by the caller's pending carrier ledger.
    // Publishing a rebuilt C/T here only to have the driver restore it makes
    // the next face see new vapor beside stale capacity and then reject its own
    // staged state. Mass plus the signed interface ledger are the complete
    // face-local result.
    if (options.local_face_index != null) {
        @memcpy(state.vapor_water_equivalent_m3, vapor);
        if (options.accepted_interface_vapor_water_m3.len != 0) {
            @memcpy(options.accepted_interface_vapor_water_m3, accepted_interface_vapor);
            @memcpy(options.accepted_interface_heat_megajoules, accepted_interface_heat);
        }
        return .{ .iterations = 1, .converged = true, .maximum_interface_flux_m3 = maximum_flux };
    }

    for (vapor, heat_capacity, state.solid_snow_water_equivalent_m3, state.liquid_water_volume_m3, state.ice_volume_m3) |next_vapor, *capacity, solid, liquid, ice| {
        if (!std.math.isFinite(next_vapor) or next_vapor < 0)
            return error.InvalidSnowVaporDiffusionResult;
        capacity.* = options.thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * solid +
            options.thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (liquid + next_vapor) +
            options.thermodynamics.ice_heat_capacity_megajoules_per_m3_k * ice;
        if (!std.math.isFinite(capacity.*) or capacity.* < 0)
            return error.InvalidSnowVaporDiffusionHeatCapacity;
    }
    for (temperature, sensible_energy_megajoules, heat_capacity) |*temperature_k, energy_megajoules, capacity| if (capacity > 0) {
        temperature_k.* = energy_megajoules / capacity;
    };
    for (temperature) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidSnowVaporDiffusionTemperature;
    @memcpy(state.vapor_water_equivalent_m3, vapor);
    @memcpy(state.temperature_k, temperature);
    @memcpy(state.heat_capacity_megajoules_per_k, heat_capacity);
    if (options.accepted_interface_vapor_water_m3.len != 0) {
        @memcpy(options.accepted_interface_vapor_water_m3, accepted_interface_vapor);
        @memcpy(options.accepted_interface_heat_megajoules, accepted_interface_heat);
    }
    return .{ .iterations = 1, .converged = true, .maximum_interface_flux_m3 = maximum_flux };
}

test "interlayer vapor diffusion conserves vapor and sensible energy" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.1, snow.test_thermodynamics);
    state.vapor_water_equivalent_m3[0] = 1e-4;
    state.heat_capacity_megajoules_per_k[0] +=
        snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * 1e-4;
    state.vapor_water_equivalent_m3[1] = 0;
    const vapor_by_layer_before = state.vapor_water_equivalent_m3[0..2].*;
    const capacity_by_layer_before = state.heat_capacity_megajoules_per_k[0..2].*;
    const energy_by_layer_before = [_]f64{
        state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0],
        state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1],
    };
    var accepted_interface_vapor = [_]f64{ 99, 99 };
    var accepted_interface_heat = [_]f64{ 99, 99 };
    const vapor_before = state.vapor_water_equivalent_m3[0];
    var energy_before: f64 = 0;
    for (state.heat_capacity_megajoules_per_k, state.temperature_k) |capacity, temperature_k| energy_before += capacity * temperature_k;
    const report = try solve(std.testing.allocator, &state, .{ .reference_vapor_diffusivity_m2_per_h = 0.0896, .reference_temperature_k = 298.15, .temperature_exponent = 1.75, .minimum_air_fraction = 0, .vapor_sensible_heat_capacity_megajoules_per_m3_k = 4.19 }, .{ .physical_time_step_hours = 1, .donor_availability_fraction = 1, .full_snow_cover_depth_m = 0.07, .thermodynamics = snow.test_thermodynamics, .accepted_interface_vapor_water_m3 = &accepted_interface_vapor, .accepted_interface_heat_megajoules = &accepted_interface_heat });
    var energy_after: f64 = 0;
    for (state.heat_capacity_megajoules_per_k, state.temperature_k) |capacity, temperature_k| energy_after += capacity * temperature_k;
    try std.testing.expect(report.maximum_interface_flux_m3 > 0);
    try std.testing.expectEqual(@as(f64, 0), accepted_interface_vapor[0]);
    try std.testing.expect(accepted_interface_vapor[1] > 0);
    try std.testing.expect(accepted_interface_heat[1] > 0);
    try std.testing.expectApproxEqAbs(
        -accepted_interface_vapor[1],
        state.vapor_water_equivalent_m3[0] - vapor_by_layer_before[0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        accepted_interface_vapor[1],
        state.vapor_water_equivalent_m3[1] - vapor_by_layer_before[1],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        -snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * accepted_interface_vapor[1],
        state.heat_capacity_megajoules_per_k[0] - capacity_by_layer_before[0],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * accepted_interface_vapor[1],
        state.heat_capacity_megajoules_per_k[1] - capacity_by_layer_before[1],
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        -accepted_interface_heat[1],
        state.heat_capacity_megajoules_per_k[0] * state.temperature_k[0] - energy_by_layer_before[0],
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        accepted_interface_heat[1],
        state.heat_capacity_megajoules_per_k[1] * state.temperature_k[1] - energy_by_layer_before[1],
        1e-12,
    );
    try std.testing.expect(state.vapor_water_equivalent_m3[1] > 0);
    try std.testing.expectApproxEqAbs(vapor_before, state.vapor_water_equivalent_m3[0] + state.vapor_water_equivalent_m3[1], 1e-12);
    try std.testing.expectApproxEqAbs(energy_before, energy_after, 1e-10);
}

test "snow vapor diffusion preserves isothermal state and canonical carrier capacity" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.0175}, &.{1}, &.{268}, &.{ 0.00875, 0.0175 }, 0.1, snow.test_thermodynamics);
    state.vapor_water_equivalent_m3[0] = 1e-4;
    state.heat_capacity_megajoules_per_k[0] +=
        snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * 1e-4;
    var accepted_vapor = [_]f64{ 0, 0 };
    var accepted_heat = [_]f64{ 0, 0 };
    _ = try solve(std.testing.allocator, &state, .{
        .reference_vapor_diffusivity_m2_per_h = 0.0896,
        .reference_temperature_k = 298.15,
        .temperature_exponent = 1.75,
        .minimum_air_fraction = 0,
        .vapor_sensible_heat_capacity_megajoules_per_m3_k = 4.19,
    }, .{
        .physical_time_step_hours = 1,
        .donor_availability_fraction = 1,
        .full_snow_cover_depth_m = 0.07,
        .thermodynamics = snow.test_thermodynamics,
        .accepted_interface_vapor_water_m3 = &accepted_vapor,
        .accepted_interface_heat_megajoules = &accepted_heat,
    });
    try std.testing.expect(accepted_vapor[1] > 0);
    for (state.temperature_k) |temperature_k|
        try std.testing.expectApproxEqAbs(@as(f64, 268), temperature_k, 1e-12);
    for (0..2) |layer| {
        const expected = snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * state.solid_snow_water_equivalent_m3[layer] +
            snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * (state.liquid_water_volume_m3[layer] + state.vapor_water_equivalent_m3[layer]) +
            snow.test_thermodynamics.ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[layer];
        try std.testing.expectApproxEqAbs(expected, state.heat_capacity_megajoules_per_k[layer], 1e-15);
    }
    const quarter = try snow_cover_fraction.evaluate(0.0175, 0.07);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), quarter.snow_fraction, 1e-15);
    const near_full = try snow_cover_fraction.evaluate(0.06999999, 0.07);
    try std.testing.expectEqual(@as(f64, 0.999), near_full.snow_fraction);
}

test "snow vapor diffusion rejects isolated vapor without deleting inventory" {
    var state = try snow.State.init(std.testing.allocator, 1, 1);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.01}, &.{1}, &.{268}, &.{0.01}, 0.1, snow.test_thermodynamics);
    state.vapor_water_equivalent_m3[0] = 1e-4;
    state.heat_capacity_megajoules_per_k[0] += 4.19e-4;
    state.air_filled_volume_m3[0] = 0;
    const vapor_before = state.vapor_water_equivalent_m3[0];
    const capacity_before = state.heat_capacity_megajoules_per_k[0];
    const temperature_before = state.temperature_k[0];
    try std.testing.expectError(
        error.SnowVaporInventoryWithoutAirVolume,
        solve(std.testing.allocator, &state, .{
            .reference_vapor_diffusivity_m2_per_h = 0.0896,
            .reference_temperature_k = 298.15,
            .temperature_exponent = 1.75,
            .minimum_air_fraction = 0,
            .vapor_sensible_heat_capacity_megajoules_per_m3_k = 4.19,
        }, .{
            .physical_time_step_hours = 1,
            .donor_availability_fraction = 1,
            .full_snow_cover_depth_m = 0.07,
            .thermodynamics = snow.test_thermodynamics,
        }),
    );
    try std.testing.expectEqual(vapor_before, state.vapor_water_equivalent_m3[0]);
    try std.testing.expectEqual(capacity_before, state.heat_capacity_megajoules_per_k[0]);
    try std.testing.expectEqual(temperature_before, state.temperature_k[0]);
}

const two_layer_parameters: Parameters = .{
    .reference_vapor_diffusivity_m2_per_h = 0.1,
    .reference_temperature_k = 298.15,
    .temperature_exponent = 0,
    .minimum_air_fraction = 0,
    .vapor_sensible_heat_capacity_megajoules_per_m3_k = 4.19,
};

fn initializeTwoLayerGoldenState(state: *snow.State, first_vapor_m3: f64, second_vapor_m3: f64) !void {
    try state.initializePhysicalState(&.{0.2}, &.{1}, &.{268}, &.{ 0.1, 0.2 }, 0.1, snow.test_thermodynamics);
    state.vapor_water_equivalent_m3[0] = first_vapor_m3;
    state.vapor_water_equivalent_m3[1] = second_vapor_m3;
    for (0..2) |layer| {
        state.air_filled_volume_m3[layer] = 0.4;
        state.total_layer_volume_m3[layer] = 0.5;
        state.layer_thickness_m[layer] = 0.1;
        state.cumulative_depth_m[layer] = 0.1 * @as(f64, @floatFromInt(layer + 1));
        state.temperature_k[layer] = 268;
        state.heat_capacity_megajoules_per_k[layer] =
            snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * state.solid_snow_water_equivalent_m3[layer] +
            snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * state.vapor_water_equivalent_m3[layer];
    }
}

test "snow vapor explicit two-layer uncapped WATSUB golden" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try initializeTwoLayerGoldenState(&state, 0.01, 0.002);
    var accepted_vapor = [_]f64{ 99, 99 };
    var accepted_heat = [_]f64{ 99, 99 };
    const report = try solve(std.testing.allocator, &state, two_layer_parameters, .{
        .physical_time_step_hours = 0.25,
        .donor_availability_fraction = 0.25,
        .full_snow_cover_depth_m = 0.05,
        .thermodynamics = snow.test_thermodynamics,
        .snow_cover_fraction_by_cell = &.{0.5},
        .accepted_interface_vapor_water_m3 = &accepted_vapor,
        .accepted_interface_heat_megajoules = &accepted_heat,
    });

    // CNV1=CNV2=0.8^2*0.1=0.064; AVCNVW=0.64 m h-1;
    // FLVC=0.64*(0.01/0.4-0.002/0.4)*1*0.5*0.25=0.0016 m3.
    const expected_flux_m3: f64 = 0.0016;
    try std.testing.expectEqual(@as(u16, 1), report.iterations);
    try std.testing.expect(report.converged);
    try std.testing.expectApproxEqAbs(expected_flux_m3, report.maximum_interface_flux_m3, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), accepted_vapor[0]);
    try std.testing.expectApproxEqAbs(expected_flux_m3, accepted_vapor[1], 1e-15);
    try std.testing.expectApproxEqAbs(4.19 * 268 * expected_flux_m3, accepted_heat[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0084), state.vapor_water_equivalent_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0036), state.vapor_water_equivalent_m3[1], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 268), state.temperature_k[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 268), state.temperature_k[1], 1e-12);
}

test "snow vapor explicit two-layer donor-capped WATSUB golden" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try initializeTwoLayerGoldenState(&state, 0.01, 0.002);
    var accepted_vapor = [_]f64{ 99, 99 };
    var accepted_heat = [_]f64{ 99, 99 };
    var parameters = two_layer_parameters;
    parameters.reference_vapor_diffusivity_m2_per_h = 1;
    const report = try solve(std.testing.allocator, &state, parameters, .{
        .physical_time_step_hours = 0.25,
        .donor_availability_fraction = 0.25,
        .full_snow_cover_depth_m = 0.05,
        .thermodynamics = snow.test_thermodynamics,
        .snow_cover_fraction_by_cell = &.{0.5},
        .accepted_interface_vapor_water_m3 = &accepted_vapor,
        .accepted_interface_heat_megajoules = &accepted_heat,
    });

    // Unlimited FLVC is 0.016 m3, so WATSUB's VOLV02*XNPXX cap accepts
    // only 0.01*0.25=0.0025 m3 from the entry-state donor.
    const expected_flux_m3: f64 = 0.0025;
    try std.testing.expectApproxEqAbs(expected_flux_m3, report.maximum_interface_flux_m3, 1e-15);
    try std.testing.expectApproxEqAbs(expected_flux_m3, accepted_vapor[1], 1e-15);
    try std.testing.expectApproxEqAbs(4.19 * 268 * expected_flux_m3, accepted_heat[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0075), state.vapor_water_equivalent_m3[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0045), state.vapor_water_equivalent_m3[1], 1e-15);
}

test "snow vapor uses production pre-input cover and physical timestep linearly" {
    var quarter_cover = try snow.State.init(std.testing.allocator, 1, 2);
    defer quarter_cover.deinit();
    var half_cover = try snow.State.init(std.testing.allocator, 1, 2);
    defer half_cover.deinit();
    var half_time = try snow.State.init(std.testing.allocator, 1, 2);
    defer half_time.deinit();
    try initializeTwoLayerGoldenState(&quarter_cover, 0.01, 0.002);
    try initializeTwoLayerGoldenState(&half_cover, 0.01, 0.002);
    try initializeTwoLayerGoldenState(&half_time, 0.01, 0.002);
    var parameters = two_layer_parameters;
    parameters.reference_vapor_diffusivity_m2_per_h = 0.001;
    const base_options: Options = .{
        .physical_time_step_hours = 0.25,
        .donor_availability_fraction = 1,
        .full_snow_cover_depth_m = 0.05,
        .thermodynamics = snow.test_thermodynamics,
        .snow_cover_fraction_by_cell = &.{0.25},
    };
    const quarter_report = try solve(std.testing.allocator, &quarter_cover, parameters, base_options);
    var half_cover_options = base_options;
    half_cover_options.snow_cover_fraction_by_cell = &.{0.5};
    const half_cover_report = try solve(std.testing.allocator, &half_cover, parameters, half_cover_options);
    var half_time_options = base_options;
    half_time_options.physical_time_step_hours = 0.5;
    const half_time_report = try solve(std.testing.allocator, &half_time, parameters, half_time_options);

    // The state depth is 0.2 m (> the 0.05-m full-cover depth), so these
    // ratios prove the caller's frozen pre-input FSNW is used, not recomputed
    // after precipitation changes the snow state.
    try std.testing.expectApproxEqAbs(2 * quarter_report.maximum_interface_flux_m3, half_cover_report.maximum_interface_flux_m3, 1e-18);
    try std.testing.expectApproxEqAbs(2 * quarter_report.maximum_interface_flux_m3, half_time_report.maximum_interface_flux_m3, 1e-18);
}

test "snow vapor next face sees preceding accepted interim inventory" {
    var state = try snow.State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.3}, &.{1}, &.{268}, &.{ 0.1, 0.2, 0.3 }, 0.1, snow.test_thermodynamics);
    state.vapor_water_equivalent_m3[0] = 0.01;
    for (0..3) |layer| {
        state.air_filled_volume_m3[layer] = 0.4;
        state.total_layer_volume_m3[layer] = 0.5;
        state.layer_thickness_m[layer] = 0.1;
        state.heat_capacity_megajoules_per_k[layer] =
            snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * state.solid_snow_water_equivalent_m3[layer] +
            snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k * state.vapor_water_equivalent_m3[layer];
    }
    var accepted_vapor = [_]f64{ 99, 99, 99 };
    var accepted_heat = [_]f64{ 99, 99, 99 };
    var parameters = two_layer_parameters;
    parameters.reference_vapor_diffusivity_m2_per_h = 0.001;
    _ = try solve(std.testing.allocator, &state, parameters, .{
        .physical_time_step_hours = 0.25,
        .donor_availability_fraction = 1,
        .full_snow_cover_depth_m = 0.05,
        .thermodynamics = snow.test_thermodynamics,
        .snow_cover_fraction_by_cell = &.{0.5},
        .accepted_interface_vapor_water_m3 = &accepted_vapor,
        .accepted_interface_heat_megajoules = &accepted_heat,
    });

    try std.testing.expect(accepted_vapor[1] > 0);
    // WATSUB updates VOLV02(L/L2) before advancing L. The second face must
    // therefore relay part of face one; an all-faces entry snapshot is wrong.
    try std.testing.expect(accepted_vapor[2] > 0);
    try std.testing.expect(accepted_heat[2] > 0);
}

test "face-local snow vapor stages mass and carrier heat across sequential faces" {
    var state = try snow.State.init(std.testing.allocator, 1, 3);
    defer state.deinit();
    try state.initializePhysicalState(
        &.{0.3},
        &.{1},
        &.{268},
        &.{ 0.1, 0.2, 0.3 },
        0.1,
        snow.test_thermodynamics,
    );
    state.vapor_water_equivalent_m3[0] = 0.01;
    for (0..3) |layer| {
        state.air_filled_volume_m3[layer] = 0.4;
        state.total_layer_volume_m3[layer] = 0.5;
        state.layer_thickness_m[layer] = 0.1;
        state.heat_capacity_megajoules_per_k[layer] =
            snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k *
            state.solid_snow_water_equivalent_m3[layer] +
            snow.test_thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                state.vapor_water_equivalent_m3[layer];
    }
    const entry_capacity = state.heat_capacity_megajoules_per_k[0..3].*;
    const entry_temperature = state.temperature_k[0..3].*;
    var accepted_vapor = [_]f64{ 99, 99, 99 };
    var accepted_heat = [_]f64{ 99, 99, 99 };
    var parameters = two_layer_parameters;
    parameters.reference_vapor_diffusivity_m2_per_h = 0.001;
    const base_options: Options = .{
        .physical_time_step_hours = 0.25,
        .donor_availability_fraction = 1,
        .full_snow_cover_depth_m = 0.05,
        .thermodynamics = snow.test_thermodynamics,
        .snow_cover_fraction_by_cell = &.{0.5},
        .accepted_interface_vapor_water_m3 = &accepted_vapor,
        .accepted_interface_heat_megajoules = &accepted_heat,
        .local_face_index = 0,
        .calculation_temperature_k = &entry_temperature,
    };
    _ = try solve(
        std.testing.allocator,
        &state,
        parameters,
        base_options,
    );
    try std.testing.expect(accepted_vapor[1] > 0);
    try std.testing.expect(accepted_heat[1] > 0);
    try std.testing.expectEqualSlices(
        f64,
        &entry_capacity,
        state.heat_capacity_megajoules_per_k,
    );
    try std.testing.expectEqualSlices(
        f64,
        &entry_temperature,
        state.temperature_k,
    );

    var second_options = base_options;
    second_options.local_face_index = 1;
    _ = try solve(
        std.testing.allocator,
        &state,
        parameters,
        second_options,
    );
    try std.testing.expect(accepted_vapor[2] > 0);
    try std.testing.expect(accepted_heat[2] > 0);
    try std.testing.expectEqualSlices(
        f64,
        &entry_capacity,
        state.heat_capacity_megajoules_per_k,
    );
    try std.testing.expectEqualSlices(
        f64,
        &entry_temperature,
        state.temperature_k,
    );
}

test "snow vapor requires strict VHCPW greater-than VHCPWX activation" {
    var at_threshold = try snow.State.init(std.testing.allocator, 1, 2);
    defer at_threshold.deinit();
    var above_threshold = try snow.State.init(std.testing.allocator, 1, 2);
    defer above_threshold.deinit();
    try initializeTwoLayerGoldenState(&at_threshold, 0, 0.002);
    try initializeTwoLayerGoldenState(&above_threshold, 0, 0.002);
    const threshold = snow.activation_heat_capacity_megajoules_per_m2_k;
    at_threshold.solid_snow_water_equivalent_m3[0] = threshold /
        snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k;
    at_threshold.heat_capacity_megajoules_per_k[0] = threshold;
    above_threshold.solid_snow_water_equivalent_m3[0] = threshold * 1.000001 /
        snow.test_thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k;
    above_threshold.heat_capacity_megajoules_per_k[0] = threshold * 1.000001;
    var at_threshold_ledger = [_]f64{ 99, 99 };
    var above_threshold_ledger = [_]f64{ 99, 99 };
    var options: Options = .{
        .physical_time_step_hours = 0.25,
        .donor_availability_fraction = 1,
        .full_snow_cover_depth_m = 0.05,
        .thermodynamics = snow.test_thermodynamics,
        .snow_cover_fraction_by_cell = &.{0.5},
        .accepted_interface_vapor_water_m3 = &at_threshold_ledger,
        .accepted_interface_heat_megajoules = &.{},
    };
    var at_threshold_heat = [_]f64{ 99, 99 };
    options.accepted_interface_heat_megajoules = &at_threshold_heat;
    _ = try solve(std.testing.allocator, &at_threshold, two_layer_parameters, options);
    var above_threshold_heat = [_]f64{ 99, 99 };
    options.accepted_interface_vapor_water_m3 = &above_threshold_ledger;
    options.accepted_interface_heat_megajoules = &above_threshold_heat;
    _ = try solve(std.testing.allocator, &above_threshold, two_layer_parameters, options);

    try std.testing.expectEqual(@as(f64, 0), at_threshold_ledger[1]);
    try std.testing.expect(above_threshold_ledger[1] < 0);
}

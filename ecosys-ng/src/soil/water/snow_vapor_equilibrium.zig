const std = @import("std");
const snow = @import("../solute/snow_solute_transport.zig");
const ice_units = @import("../../core/ice_units.zig");
const surface_exchange = @import("snow_surface_atmosphere_exchange.zig");

pub const Parameters = struct {
    vapor_volume_prefactor_k: f64,
    equilibrium_relative_humidity: f64,
    clausius_clapeyron_temperature_k: f64,
    reference_inverse_temperature_per_k: f64,
    liquid_evaporation_latent_heat_megajoules_per_m3: f64,
    snow_sublimation_latent_heat_megajoules_per_m3: f64,
    /// HEAT-001 resolution A. Latent heat of fusion, needed only to express
    /// this solve's energy change on the same enthalpy reference state that
    /// `landscape_mass_inventory.aggregateSnow` uses. Sublimation moves water
    /// from the solid carrier, which the census holds one latent heat of
    /// fusion below liquid, so the frozen-mass change must be included.
    ///
    latent_heat_of_fusion_megajoules_per_m3: f64,
    /// HEAT-001 census booking, mirroring `snow_phase_change.Options`. The
    /// landscape heat census does not store `-L` per unit frozen water; it
    /// stores the re-basing constant `K = (C_l - C_i) * Tm - L`. Reporting a
    /// change against `-L` therefore left `(C_l - C_i) * Tm` per cubic metre
    /// of sublimated snow unbooked. These three values reconstruct `K` on the
    /// exact definition `landscape_mass_inventory_support.frozenWaterEnthalpyPerM3`
    /// uses, so the two sides cannot drift apart independently.
    solid_snow_heat_capacity_megajoules_per_m3_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    ice_density_megagrams_per_m3: f64,
    pure_water_melting_temperature_k: f64,
};

pub const Options = struct {
    /// WATSUB `XNPSX` donor inventory fraction. This is intentionally not a
    /// physical timestep because the equilibrium equation is explicit.
    donor_availability_fraction: f64 = 1,
    energy_conservation_absolute_tolerance_megajoules_per_m2: f64,
    energy_conservation_relative_tolerance: f64,
    /// Restrict the source-ordered coupled driver to one local snow layer in
    /// every cell. Layer zero is owned by the surface-equilibrium routine.
    local_layer_index: ?usize = null,
};

pub const Report = struct {
    /// Largest unfilled vapor-equilibrium deficit after the source-prescribed
    /// donor cap. This is a diagnostic, not a nonlinear residual: WATSUB's
    /// equation is explicit at the accepted pre-transfer temperature.
    maximum_vapor_residual_m3: f64,
    /// Independently measured canonical storage change, certified against
    /// the accepted process term before publication.
    enthalpy_change_megajoules: f64,
    /// Independently derived internal process term from accepted liquid and
    /// solid phase deltas. This, never storage post-minus-pre, is published.
    sensible_energy_change_megajoules: f64,
    sensible_energy_change_megajoules_by_cell: []f64,
    /// Exact accepted process heat at each snow layer. This is published from
    /// the same donor phase deltas as the canonical total, so layer-local
    /// conservation does not infer activity from storage post-minus-pre.
    sensible_energy_change_megajoules_by_layer: []f64,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.sensible_energy_change_megajoules_by_layer);
        allocator.free(self.sensible_energy_change_megajoules_by_cell);
        self.* = undefined;
    }
};

pub const ExplicitTransfer = struct {
    equilibrium_fraction: f64,
    liquid_change_m3: f64,
    solid_change_m3: f64,
    vapor_change_m3: f64,
    remaining_residual_m3: f64,
};

/// Exact WATSUB 1275--1282/2313--2321 algebra at the frozen layer-entry
/// temperature. This is deliberately not a nonlinear solve: the source never
/// reevaluates saturation at the post-latent-heat temperature.
pub fn explicitTransfer(
    solid_m3: f64,
    liquid_m3: f64,
    vapor_m3: f64,
    air_m3: f64,
    entry_temperature_k: f64,
    parameters: Parameters,
    donor_availability_fraction: f64,
) !ExplicitTransfer {
    inline for (.{ solid_m3, liquid_m3, vapor_m3, air_m3, entry_temperature_k, donor_availability_fraction }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSnowVaporState;
    if (solid_m3 < 0 or liquid_m3 < 0 or vapor_m3 < 0 or air_m3 < 0 or
        entry_temperature_k <= 0 or donor_availability_fraction <= 0 or
        donor_availability_fraction > 1)
        return error.InvalidSnowVaporState;
    const equilibrium_fraction = parameters.vapor_volume_prefactor_k / entry_temperature_k *
        parameters.equilibrium_relative_humidity *
        std.math.exp(parameters.clausius_clapeyron_temperature_k *
            (parameters.reference_inverse_temperature_per_k - 1 / entry_temperature_k));
    const transfer_from_vapor_m3 = vapor_m3 - equilibrium_fraction * air_m3;
    const liquid_change_m3 = @max(
        transfer_from_vapor_m3,
        -liquid_m3 * donor_availability_fraction,
    );
    const residual_deficit_m3 = @min(0, transfer_from_vapor_m3 - liquid_change_m3);
    const solid_change_m3 = @max(
        residual_deficit_m3,
        -solid_m3 * donor_availability_fraction,
    );
    const vapor_change_m3 = -liquid_change_m3 - solid_change_m3;
    const remaining_residual_m3 = vapor_m3 + vapor_change_m3 - equilibrium_fraction * air_m3;
    inline for (.{ equilibrium_fraction, liquid_change_m3, solid_change_m3, vapor_change_m3, remaining_residual_m3 }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSnowVaporState;
    return .{
        .equilibrium_fraction = equilibrium_fraction,
        .liquid_change_m3 = liquid_change_m3,
        .solid_change_m3 = solid_change_m3,
        .vapor_change_m3 = vapor_change_m3,
        .remaining_residual_m3 = remaining_residual_m3,
    };
}

test "explicit snow vapor transfer uses frozen entry temperature and exact donor caps" {
    const parameters: Parameters = .{
        .vapor_volume_prefactor_k = 1,
        .equilibrium_relative_humidity = 1,
        .clausius_clapeyron_temperature_k = 1,
        .reference_inverse_temperature_per_k = 1,
        .liquid_evaporation_latent_heat_megajoules_per_m3 = 1,
        .snow_sublimation_latent_heat_megajoules_per_m3 = 1,
        .latent_heat_of_fusion_megajoules_per_m3 = 1,
        .solid_snow_heat_capacity_megajoules_per_m3_k = 1,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 1,
        .ice_heat_capacity_megajoules_per_m3_k = 1,
        .ice_density_megagrams_per_m3 = 1,
        .pure_water_melting_temperature_k = 1,
    };
    const transfer = try explicitTransfer(0.3, 0.2, 0, 1, 1, parameters, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, -0.02), transfer.liquid_change_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.03), transfer.solid_change_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), transfer.vapor_change_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.95), transfer.remaining_residual_m3, 1e-15);
}

fn censusEnthalpyMegajoules(
    heat_capacity_megajoules_per_k: f64,
    temperature_k: f64,
    solid_snow_water_equivalent_m3: f64,
    physical_ice_volume_m3: f64,
    parameters: Parameters,
) !f64 {
    const ice_capacity_we = try ice_units.heatCapacityPerWaterEquivalentM3K(
        parameters.ice_heat_capacity_megajoules_per_m3_k,
        parameters.ice_density_megagrams_per_m3,
    );
    const ice_we = try ice_units.waterEquivalentM3FromPhysicalVolume(
        physical_ice_volume_m3,
        parameters.ice_density_megagrams_per_m3,
    );
    const solid_correction = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        parameters.solid_snow_heat_capacity_megajoules_per_m3_k,
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.latent_heat_of_fusion_megajoules_per_m3,
        parameters.pure_water_melting_temperature_k,
    );
    const ice_correction = try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
        ice_capacity_we,
        parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        parameters.latent_heat_of_fusion_megajoules_per_m3,
        parameters.pure_water_melting_temperature_k,
    );
    const enthalpy = heat_capacity_megajoules_per_k * temperature_k +
        solid_correction * solid_snow_water_equivalent_m3 +
        ice_correction * ice_we;
    if (!std.math.isFinite(enthalpy)) return error.NonFiniteSnowVaporEnergyChange;
    return enthalpy;
}

/// WATSUB internal-layer evaporation/condensation. Liquid water supplies a
/// vapor deficit first and solid snow supplies the remainder, exactly matching
/// WFLVW2/WFLVS2 ordering. WATSUB evaluates the explicit transfer at the
/// accepted pre-transfer temperature; there is no nonlinear solve here.
pub fn solve(allocator: std.mem.Allocator, state: *snow.State, parameters: Parameters, options: Options) !Report {
    inline for (.{ parameters.vapor_volume_prefactor_k, parameters.equilibrium_relative_humidity, parameters.clausius_clapeyron_temperature_k, parameters.reference_inverse_temperature_per_k, parameters.liquid_evaporation_latent_heat_megajoules_per_m3, parameters.snow_sublimation_latent_heat_megajoules_per_m3, options.donor_availability_fraction, options.energy_conservation_absolute_tolerance_megajoules_per_m2, options.energy_conservation_relative_tolerance }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowVaporParameter;
    if (options.donor_availability_fraction <= 0 or options.donor_availability_fraction > 1 or parameters.vapor_volume_prefactor_k <= 0 or parameters.equilibrium_relative_humidity < 0 or parameters.equilibrium_relative_humidity > 1 or parameters.clausius_clapeyron_temperature_k <= 0 or parameters.reference_inverse_temperature_per_k <= 0 or parameters.liquid_evaporation_latent_heat_megajoules_per_m3 <= 0 or parameters.snow_sublimation_latent_heat_megajoules_per_m3 <= 0 or parameters.latent_heat_of_fusion_megajoules_per_m3 <= 0 or parameters.solid_snow_heat_capacity_megajoules_per_m3_k <= 0 or parameters.liquid_water_heat_capacity_megajoules_per_m3_k <= 0 or parameters.ice_heat_capacity_megajoules_per_m3_k <= 0 or parameters.ice_density_megagrams_per_m3 <= 0 or parameters.ice_density_megagrams_per_m3 > 1 or parameters.pure_water_melting_temperature_k <= 0 or options.energy_conservation_absolute_tolerance_megajoules_per_m2 < 0 or options.energy_conservation_relative_tolerance < 0) return error.InvalidSnowVaporParameter;
    inline for (std.meta.fields(Parameters)) |field|
        if (!std.math.isFinite(@field(parameters, field.name))) return error.InvalidSnowVaporParameter;
    if (options.local_layer_index) |layer|
        if (layer == 0 or layer >= state.layer_capacity) return error.SnowVaporEquilibriumLayerOutOfBounds;
    const sensible_energy_change_megajoules_by_cell = try allocator.alloc(f64, state.cell_count);
    errdefer allocator.free(sensible_energy_change_megajoules_by_cell);
    @memset(sensible_energy_change_megajoules_by_cell, 0);
    const sensible_energy_change_megajoules_by_layer = try allocator.alloc(f64, state.cell_count * state.layer_capacity);
    errdefer allocator.free(sensible_energy_change_megajoules_by_layer);
    @memset(sensible_energy_change_megajoules_by_layer, 0);
    const solid = try allocator.dupe(f64, state.solid_snow_water_equivalent_m3);
    defer allocator.free(solid);
    const liquid = try allocator.dupe(f64, state.liquid_water_volume_m3);
    defer allocator.free(liquid);
    const vapor = try allocator.dupe(f64, state.vapor_water_equivalent_m3);
    defer allocator.free(vapor);
    const temperature = try allocator.dupe(f64, state.temperature_k);
    defer allocator.free(temperature);
    const heat_capacity = try allocator.dupe(f64, state.heat_capacity_megajoules_per_k);
    defer allocator.free(heat_capacity);
    var report: Report = .{ .maximum_vapor_residual_m3 = 0, .enthalpy_change_megajoules = 0, .sensible_energy_change_megajoules = 0, .sensible_energy_change_megajoules_by_cell = sensible_energy_change_megajoules_by_cell, .sensible_energy_change_megajoules_by_layer = sensible_energy_change_megajoules_by_layer };
    for (0..state.cell_count) |cell| {
        // WATSUB applies this internal equilibrium only below the surface layer.
        const first_layer = options.local_layer_index orelse 1;
        const layer_end = if (options.local_layer_index) |layer| layer + 1 else state.layer_capacity;
        for (first_layer..layer_end) |layer| {
            const index = cell * state.layer_capacity + layer;
            inline for (.{ solid[index], liquid[index], vapor[index], temperature[index], heat_capacity[index], state.air_filled_volume_m3[index] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSnowVaporState;
            if (solid[index] < 0 or liquid[index] < 0 or vapor[index] < 0 or temperature[index] <= 0 or heat_capacity[index] < 0 or state.air_filled_volume_m3[index] < 0) return error.InvalidSnowVaporState;
            const activation_threshold = snow.activation_heat_capacity_megajoules_per_m2_k *
                state.horizontal_area_m2[index];
            if (heat_capacity[index] <= activation_threshold or
                state.air_filled_volume_m3[index] <= 0) continue;
            // WATSUB 2313--2321 is the same explicit, pre-transfer-T equation
            // as surface L=1 (1275--1282). `XNPSX` limits each donor; it is
            // not a saturation solve at the post-latent-heat temperature.
            const transfer = try explicitTransfer(
                solid[index],
                liquid[index],
                vapor[index],
                state.air_filled_volume_m3[index],
                temperature[index],
                parameters,
                options.donor_availability_fraction,
            );
            const liquid_change_m3 = transfer.liquid_change_m3;
            const solid_change_m3 = transfer.solid_change_m3;
            const vapor_change_m3 = transfer.vapor_change_m3;
            const next_solid = solid[index] + solid_change_m3;
            const next_liquid = liquid[index] + liquid_change_m3;
            const next_vapor = vapor[index] + vapor_change_m3;
            const latent_heat_megajoules = parameters.liquid_evaporation_latent_heat_megajoules_per_m3 * liquid_change_m3 +
                parameters.snow_sublimation_latent_heat_megajoules_per_m3 * solid_change_m3;
            const next_capacity = parameters.solid_snow_heat_capacity_megajoules_per_m3_k * next_solid +
                parameters.liquid_water_heat_capacity_megajoules_per_m3_k * (next_liquid + next_vapor) +
                parameters.ice_heat_capacity_megajoules_per_m3_k * state.ice_volume_m3[index];
            const next_temperature = (heat_capacity[index] * temperature[index] + latent_heat_megajoules) / next_capacity;
            inline for (.{ transfer.equilibrium_fraction, liquid_change_m3, solid_change_m3, vapor_change_m3, next_solid, next_liquid, next_vapor, next_capacity, next_temperature }) |value|
                if (!std.math.isFinite(value)) return error.NonFiniteSnowVaporState;
            if (next_solid < 0 or next_liquid < 0 or next_vapor < 0 or next_capacity <= 0 or next_temperature <= 0)
                return error.InvalidSnowVaporCandidate;
            report.maximum_vapor_residual_m3 = @max(
                report.maximum_vapor_residual_m3,
                @abs(transfer.remaining_residual_m3),
            );
            solid[index] = next_solid;
            liquid[index] = next_liquid;
            vapor[index] = next_vapor;
            temperature[index] = next_temperature;
            heat_capacity[index] = next_capacity;
        }
    }
    const solid_frozen_reference_megajoules_per_m3 =
        try ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
            parameters.solid_snow_heat_capacity_megajoules_per_m3_k,
            parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            parameters.latent_heat_of_fusion_megajoules_per_m3,
            parameters.pure_water_melting_temperature_k,
        );
    for (
        heat_capacity,
        temperature,
        solid,
        liquid,
        state.heat_capacity_megajoules_per_k,
        state.temperature_k,
        state.solid_snow_water_equivalent_m3,
        state.liquid_water_volume_m3,
        0..,
    ) |
        next_capacity,
        next_temperature,
        next_solid,
        next_liquid,
        previous_capacity,
        previous_temperature,
        previous_solid,
        previous_liquid,
        layer_index,
    | {
        const solid_change_m3 = next_solid - previous_solid;
        const liquid_change_m3 = next_liquid - previous_liquid;
        // Independent WATSUB process term: accepted donor deltas determine
        // latent heat; the solid carrier then contributes its canonical
        // reference change. This is not derived from storage post-minus-pre.
        const expected_process_heat_megajoules =
            parameters.liquid_evaporation_latent_heat_megajoules_per_m3 * liquid_change_m3 +
            parameters.snow_sublimation_latent_heat_megajoules_per_m3 * solid_change_m3 +
            solid_frozen_reference_megajoules_per_m3 * solid_change_m3;
        const before = try censusEnthalpyMegajoules(
            previous_capacity,
            previous_temperature,
            previous_solid,
            state.ice_volume_m3[layer_index],
            parameters,
        );
        const after = try censusEnthalpyMegajoules(
            next_capacity,
            next_temperature,
            next_solid,
            state.ice_volume_m3[layer_index],
            parameters,
        );
        const census_change = after - before;
        const cell = layer_index / state.layer_capacity;
        const scale = @max(@max(@abs(before), @abs(after)), @abs(expected_process_heat_megajoules));
        const tolerance = options.energy_conservation_absolute_tolerance_megajoules_per_m2 *
            state.horizontal_area_m2[cell] +
            options.energy_conservation_relative_tolerance * scale +
            256 * std.math.floatEps(f64) * scale;
        inline for (.{ expected_process_heat_megajoules, before, after, census_change, scale, tolerance }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteSnowVaporEnergyChange;
        if (@abs(census_change - expected_process_heat_megajoules) > tolerance)
            return error.SnowVaporEnergyConservationFailure;
        sensible_energy_change_megajoules_by_layer[layer_index] = expected_process_heat_megajoules;
        sensible_energy_change_megajoules_by_cell[cell] += expected_process_heat_megajoules;
        if (!std.math.isFinite(sensible_energy_change_megajoules_by_cell[cell]))
            return error.NonFiniteSnowVaporEnergyChange;
        report.sensible_energy_change_megajoules += expected_process_heat_megajoules;
        report.enthalpy_change_megajoules += census_change;
        if (!std.math.isFinite(report.sensible_energy_change_megajoules) or
            !std.math.isFinite(report.enthalpy_change_megajoules))
            return error.NonFiniteSnowVaporEnergyChange;
    }
    var per_cell_total: f64 = 0;
    for (0..state.cell_count) |cell| {
        const start = cell * state.layer_capacity;
        var layer_total: f64 = 0;
        for (sensible_energy_change_megajoules_by_layer[start..][0..state.layer_capacity]) |value|
            layer_total += value;
        const scale = @max(1, @max(@abs(layer_total), @abs(sensible_energy_change_megajoules_by_cell[cell])));
        if (!std.math.isFinite(layer_total) or
            @abs(layer_total - sensible_energy_change_megajoules_by_cell[cell]) > 64 * std.math.floatEps(f64) * scale)
            return error.SnowVaporPerLayerEnergyMismatch;
        per_cell_total += sensible_energy_change_megajoules_by_cell[cell];
    }
    if (!std.math.isFinite(per_cell_total) or @abs(per_cell_total - report.sensible_energy_change_megajoules) >
        64 * std.math.floatEps(f64) * @max(1, @abs(report.sensible_energy_change_megajoules)))
        return error.SnowVaporPerCellEnergyMismatch;
    @memcpy(state.solid_snow_water_equivalent_m3, solid);
    @memcpy(state.liquid_water_volume_m3, liquid);
    @memcpy(state.vapor_water_equivalent_m3, vapor);
    @memcpy(state.temperature_k, temperature);
    @memcpy(state.heat_capacity_megajoules_per_k, heat_capacity);
    state.refreshAllGeometry();
    return report;
}

test "internal vapor equilibrium conserves total water and responds below surface" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.1, snow.test_thermodynamics);
    state.liquid_water_volume_m3[1] = 1e-7;
    state.vapor_water_equivalent_m3[1] = 0;
    state.heat_capacity_megajoules_per_k[1] += 4.19e-7;
    state.refreshAllGeometry();
    const solid_before = state.solid_snow_water_equivalent_m3[1];
    const liquid_before = state.liquid_water_volume_m3[1];
    const before = state.solid_snow_water_equivalent_m3[1] + state.liquid_water_volume_m3[1] + state.vapor_water_equivalent_m3[1];
    var report = try solve(std.testing.allocator, &state, .{ .vapor_volume_prefactor_k = 2.173e-3, .equilibrium_relative_humidity = 0.61, .clausius_clapeyron_temperature_k = 5360, .reference_inverse_temperature_per_k = 3.661e-3, .liquid_evaporation_latent_heat_megajoules_per_m3 = 2465, .snow_sublimation_latent_heat_megajoules_per_m3 = 2834, .latent_heat_of_fusion_megajoules_per_m3 = 333, .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .ice_density_megagrams_per_m3 = 0.917, .pure_water_melting_temperature_k = 273.15 }, .{ .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12, .energy_conservation_relative_tolerance = 1e-10 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(state.vapor_water_equivalent_m3[1] > 0);
    try std.testing.expectApproxEqAbs(before, state.solid_snow_water_equivalent_m3[1] + state.liquid_water_volume_m3[1] + state.vapor_water_equivalent_m3[1], 1e-14);
    const solid_correction = (4.19 - 2.095) * 273.15 - 333;
    const expected_process_heat = 2465 * (state.liquid_water_volume_m3[1] - liquid_before) +
        (2834 + solid_correction) * (state.solid_snow_water_equivalent_m3[1] - solid_before);
    try std.testing.expect(state.solid_snow_water_equivalent_m3[1] < solid_before);
    try std.testing.expectEqual(@as(f64, 0), report.sensible_energy_change_megajoules_by_layer[0]);
    try std.testing.expectApproxEqAbs(expected_process_heat, report.sensible_energy_change_megajoules_by_layer[1], 1e-12);
    try std.testing.expectApproxEqAbs(expected_process_heat, report.sensible_energy_change_megajoules_by_cell[0], 1e-12);
    try std.testing.expectApproxEqAbs(expected_process_heat, report.sensible_energy_change_megajoules, 1e-12);
    try std.testing.expectApproxEqAbs(expected_process_heat, report.enthalpy_change_megajoules, 1e-12);
}

test "WATSUB surface and interior vapor equilibrium use the same explicit equation and donor caps" {
    var state = try snow.State.init(std.testing.allocator, 1, 2);
    defer state.deinit();
    try state.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.1, snow.test_thermodynamics);
    // Make the two layers identical so layer index is the only distinction.
    state.solid_snow_water_equivalent_m3[1] = state.solid_snow_water_equivalent_m3[0];
    state.liquid_water_volume_m3[0] = 0.001;
    state.liquid_water_volume_m3[1] = 0.001;
    state.vapor_water_equivalent_m3[0] = 0;
    state.vapor_water_equivalent_m3[1] = 0;
    state.ice_volume_m3[1] = state.ice_volume_m3[0];
    state.air_filled_volume_m3[1] = state.air_filled_volume_m3[0];
    state.temperature_k[1] = state.temperature_k[0];
    const capacity = 2.095 * state.solid_snow_water_equivalent_m3[0] + 4.19 * 0.001;
    state.heat_capacity_megajoules_per_k[0] = capacity;
    state.heat_capacity_megajoules_per_k[1] = capacity;
    state.active[0] = true;
    state.active[1] = true;

    const parameters: Parameters = .{
        .vapor_volume_prefactor_k = 5,
        .equilibrium_relative_humidity = 1,
        .clausius_clapeyron_temperature_k = 5360,
        .reference_inverse_temperature_per_k = 3.661e-3,
        .liquid_evaporation_latent_heat_megajoules_per_m3 = 2465,
        .snow_sublimation_latent_heat_megajoules_per_m3 = 2834,
        .latent_heat_of_fusion_megajoules_per_m3 = 333,
        .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
        .ice_heat_capacity_megajoules_per_m3_k = 1.9274,
        .ice_density_megagrams_per_m3 = 0.917,
        .pure_water_melting_temperature_k = 273.15,
    };
    var surface_latent = [_]f64{0};
    var surface_reference = [_]f64{0};
    try surface_exchange.equilibrateSurface(std.testing.allocator, &state, .{
        .vapor_volume_prefactor_k = parameters.vapor_volume_prefactor_k,
        .equilibrium_relative_humidity = parameters.equilibrium_relative_humidity,
        .clausius_clapeyron_temperature_k = parameters.clausius_clapeyron_temperature_k,
        .reference_inverse_temperature_per_k = parameters.reference_inverse_temperature_per_k,
        .liquid_evaporation_latent_heat_megajoules_per_m3 = parameters.liquid_evaporation_latent_heat_megajoules_per_m3,
        .snow_sublimation_latent_heat_megajoules_per_m3 = parameters.snow_sublimation_latent_heat_megajoules_per_m3,
        .latent_heat_of_fusion_megajoules_per_m3 = parameters.latent_heat_of_fusion_megajoules_per_m3,
        .liquid_water_heat_capacity_megajoules_per_m3_k = parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        .ice_heat_capacity_megajoules_per_m3_k = parameters.ice_heat_capacity_megajoules_per_m3_k,
        .ice_density_megagrams_per_m3 = parameters.ice_density_megagrams_per_m3,
        .pure_water_melting_temperature_k = parameters.pure_water_melting_temperature_k,
    }, .{
        .donor_availability_fraction = 0.25,
        .latent_heat_megajoules = &surface_latent,
        .reference_state_heat_megajoules = &surface_reference,
        .cell_area_m2 = &.{1},
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
    });
    var report = try solve(std.testing.allocator, &state, parameters, .{
        .donor_availability_fraction = 0.25,
        .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12,
        .energy_conservation_relative_tolerance = 1e-10,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectApproxEqAbs(state.solid_snow_water_equivalent_m3[0], state.solid_snow_water_equivalent_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(state.liquid_water_volume_m3[0], state.liquid_water_volume_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(state.vapor_water_equivalent_m3[0], state.vapor_water_equivalent_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(state.temperature_k[0], state.temperature_k[1], 1e-12);
    try std.testing.expectApproxEqAbs(state.heat_capacity_megajoules_per_k[0], state.heat_capacity_megajoules_per_k[1], 1e-14);
    try std.testing.expectApproxEqAbs(0.00075, state.liquid_water_volume_m3[1], 1e-14);
    try std.testing.expect(state.solid_snow_water_equivalent_m3[1] < 0.005);
    try std.testing.expectApproxEqAbs(surface_reference[0], report.sensible_energy_change_megajoules_by_layer[1], 1e-12);
}

test "interior vapor equilibrium donor limits use explicit availability fraction" {
    var one_hour = try snow.State.init(std.testing.allocator, 1, 2);
    defer one_hour.deinit();
    try one_hour.initializePhysicalState(&.{0.1}, &.{1}, &.{268}, &.{ 0.05, 0.10 }, 0.1, snow.test_thermodynamics);
    one_hour.liquid_water_volume_m3[1] = 0.001;
    one_hour.vapor_water_equivalent_m3[1] = 0;
    one_hour.heat_capacity_megajoules_per_k[1] += 4.19 * 0.001;
    one_hour.refreshAllGeometry();
    var quarter_hour = try snow.State.init(std.testing.allocator, 1, 2);
    defer quarter_hour.deinit();
    @memcpy(quarter_hour.active, one_hour.active);
    inline for (.{
        "solid_snow_water_equivalent_m3",
        "liquid_water_volume_m3",
        "vapor_water_equivalent_m3",
        "ice_volume_m3",
        "air_filled_volume_m3",
        "total_layer_volume_m3",
        "target_layer_volume_m3",
        "layer_thickness_m",
        "cumulative_depth_m",
        "snow_density_megagrams_per_m3",
        "temperature_k",
        "heat_capacity_megajoules_per_k",
        "horizontal_area_m2",
    }) |field_name| @memcpy(@field(&quarter_hour, field_name), @field(&one_hour, field_name));

    const parameters: Parameters = .{ .vapor_volume_prefactor_k = 5, .equilibrium_relative_humidity = 1, .clausius_clapeyron_temperature_k = 5360, .reference_inverse_temperature_per_k = 3.661e-3, .liquid_evaporation_latent_heat_megajoules_per_m3 = 2465, .snow_sublimation_latent_heat_megajoules_per_m3 = 2834, .latent_heat_of_fusion_megajoules_per_m3 = 333, .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274, .ice_density_megagrams_per_m3 = 0.917, .pure_water_melting_temperature_k = 273.15 };
    var full_report = try solve(std.testing.allocator, &one_hour, parameters, .{ .donor_availability_fraction = 1, .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12, .energy_conservation_relative_tolerance = 1e-10 });
    defer full_report.deinit(std.testing.allocator);
    var quarter_report = try solve(std.testing.allocator, &quarter_hour, parameters, .{ .donor_availability_fraction = 0.25, .energy_conservation_absolute_tolerance_megajoules_per_m2 = 1e-12, .energy_conservation_relative_tolerance = 1e-10 });
    defer quarter_report.deinit(std.testing.allocator);

    try std.testing.expect(one_hour.liquid_water_volume_m3[1] < 0.00075);
    try std.testing.expectApproxEqAbs(0.005, one_hour.solid_snow_water_equivalent_m3[1], 1e-14);
    try std.testing.expectApproxEqAbs(0.00075, quarter_hour.liquid_water_volume_m3[1], 1e-14);
    try std.testing.expect(quarter_hour.solid_snow_water_equivalent_m3[1] < 0.005);
}

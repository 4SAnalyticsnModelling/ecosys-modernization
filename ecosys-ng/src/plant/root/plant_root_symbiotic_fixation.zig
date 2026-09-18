const std = @import("std");
const Symbiosis = @import("../../canopy/symbiosis/plant_symbiotic_fixation.zig");
const LitterPartition = @import("../partition/litter.zig");
const RootMetabolism = @import("plant_root_metabolism.zig");

pub const Inputs = struct {
    fixation_type: u8,
    first_subhour: bool,
    fire_active_this_hour: bool,
    structural: Symbiosis.Pool,
    mobile: Symbiosis.Pool,
    host_mobile: Symbiosis.Pool,
    host_structural_carbon_g_c: f64,
    host_presence_threshold_g_c: f64,
    cell_area_m2: f64,
    temperature_response: f64,
    growth_water_response: f64,
    maintenance_temperature_response: f64,
    maintenance_water_response: f64,
    oxygen_constraint_fraction: f64,
    host_exchange_enabled: bool,
    timestep_h: f64,
};

pub const Result = struct {
    structural: Symbiosis.Pool,
    mobile: Symbiosis.Pool,
    host_mobile: Symbiosis.Pool,
    litterfall: RootMetabolism.RootLitter,
    fixed_nitrogen_g_n: f64,
    respiration_actual_g_c: f64,
    respiration_oxygen_unlimited_g_c: f64,
    /// External WTNDI inoculum only; host exchange, fixation, respiration,
    /// and litterfall remain separate internal/process fluxes.
    external_inoculum_input: Symbiosis.Pool,
};

/// grosub.f lines 7643--7646 computes CNDLR after first-subhour infection, so
/// newly initialized rhizobia participate in decomposition immediately.
pub fn sourceOrderRootDecompositionDensity(
    structural_carbon_after_infection_g_c: f64,
    host_structural_carbon_g_c: f64,
    host_presence_threshold_g_c: f64,
) !f64 {
    inline for (.{
        structural_carbon_after_infection_g_c,
        host_structural_carbon_g_c,
        host_presence_threshold_g_c,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidRootSymbioticDecompositionDensity;
    return if (host_structural_carbon_g_c > host_presence_threshold_g_c)
        structural_carbon_after_infection_g_c / host_structural_carbon_g_c
    else
        0;
}

/// grosub.f line 7690 always uses WFNRR for rhizobial maintenance. Host-root
/// profile/phenology switching applies elsewhere, not to this nodule term.
pub fn sourceOrderMaintenanceWaterResponse(
    growth_water_response: f64,
    maintenance_water_response: f64,
) !f64 {
    inline for (.{ growth_water_response, maintenance_water_response }) |value|
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidRootSymbioticWaterResponse;
    return maintenance_water_response;
}

/// One local GROSUB rhizobial solve. The second evaluation changes only the
/// oxygen constraint and is diagnostic; it never advances a second model
/// state or creates a sub-hourly full-model cycle.
pub fn calculate(
    inputs: Inputs,
    runtime: Symbiosis.RuntimeParameters,
    target_nitrogen_per_carbon_g_n_per_g_c: f64,
    target_phosphorus_per_carbon_g_p_per_g_c: f64,
    growth_yield_g_c_per_g_c: f64,
    fine_root_litter: LitterPartition.ElementFractions,
) !Result {
    if (inputs.fixation_type < 1 or inputs.fixation_type > 3) return error.InvalidRootSymbioticFixationType;
    try fine_root_litter.validate();
    const parameters = try Symbiosis.metabolicParameters(runtime, inputs.fixation_type, target_nitrogen_per_carbon_g_n_per_g_c, target_phosphorus_per_carbon_g_p_per_g_c, growth_yield_g_c_per_g_c);
    const structural = try Symbiosis.initializeRootInfection(
        inputs.fixation_type,
        inputs.first_subhour,
        inputs.fire_active_this_hour,
        inputs.structural,
        runtime.initial_bacterial_carbon_g_c_per_m2,
        inputs.cell_area_m2,
        target_nitrogen_per_carbon_g_n_per_g_c,
        target_phosphorus_per_carbon_g_p_per_g_c,
    );
    const common: Symbiosis.Inputs = .{
        .structural = structural,
        .nonstructural = inputs.mobile,
        .decomposition_density = try sourceOrderRootDecompositionDensity(
            structural.carbon_g_c,
            inputs.host_structural_carbon_g_c,
            inputs.host_presence_threshold_g_c,
        ),
        .temperature_response = inputs.temperature_response,
        .growth_water_response = inputs.growth_water_response,
        .oxygen_constraint_fraction = std.math.clamp(inputs.oxygen_constraint_fraction, 0, 1),
        .maintenance_temperature_response = inputs.maintenance_temperature_response,
        .maintenance_water_response = try sourceOrderMaintenanceWaterResponse(
            inputs.growth_water_response,
            inputs.maintenance_water_response,
        ),
        .timestep_h = inputs.timestep_h,
    };
    const actual = try Symbiosis.calculate(common, parameters);
    const minimum_infection_carbon_g_c = runtime.initial_bacterial_carbon_g_c_per_m2 * inputs.cell_area_m2;
    const exchange = if (inputs.host_exchange_enabled)
        try Symbiosis.equilibrateHostAndSymbiont(
            inputs.host_mobile,
            actual.next_nonstructural,
            inputs.host_structural_carbon_g_c,
            actual.next_structural.carbon_g_c,
            minimum_infection_carbon_g_c,
            runtime.host_exchange_fraction_per_h_by_fixation_type[inputs.fixation_type - 1],
            inputs.timestep_h,
            0,
            0,
            0,
        )
    else
        Symbiosis.HostExchange{
            .next_host = inputs.host_mobile,
            .next_symbiont = actual.next_nonstructural,
            .host_to_symbiont = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        };
    var litterfall = std.mem.zeroes(RootMetabolism.RootLitter);
    for (0..LitterPartition.kinetic_component_count) |component| {
        litterfall.nonwoody_carbon_g_c[component] = actual.litterfall.carbon_g_c * fine_root_litter.carbon[component];
        litterfall.nonwoody_nitrogen_g_n[component] = actual.litterfall.nitrogen_g_n * fine_root_litter.nitrogen[component];
        litterfall.nonwoody_phosphorus_g_p[component] = actual.litterfall.phosphorus_g_p * fine_root_litter.phosphorus[component];
    }
    return .{
        .structural = actual.next_structural,
        .mobile = exchange.next_symbiont,
        .host_mobile = exchange.next_host,
        .litterfall = litterfall,
        .fixed_nitrogen_g_n = actual.fixed_nitrogen_g_n,
        .respiration_actual_g_c = actual.total_respiration_g_c,
        .respiration_oxygen_unlimited_g_c = actual.total_respiration_oxygen_unlimited_g_c,
        .external_inoculum_input = try Symbiosis.infectionExternalInput(inputs.structural, structural),
    };
}

test "root rhizobia retain one actual state and expose oxygen-unlimited respiration" {
    const fractions: LitterPartition.ElementFractions = .{
        .carbon = .{ 0.4, 0.3, 0.2, 0.1 },
        .nitrogen = .{ 0.4, 0.3, 0.2, 0.1 },
        .phosphorus = .{ 0.4, 0.3, 0.2, 0.1 },
    };
    const result = try calculate(.{
        .fixation_type = 1,
        .first_subhour = true,
        .fire_active_this_hour = false,
        .structural = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        .mobile = .{ .carbon_g_c = 1, .nitrogen_g_n = 0, .phosphorus_g_p = 0.02 },
        .host_mobile = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.05 },
        .host_structural_carbon_g_c = 10,
        .host_presence_threshold_g_c = 0,
        .cell_area_m2 = 100,
        .temperature_response = 1,
        .growth_water_response = 1,
        .maintenance_temperature_response = 1,
        .maintenance_water_response = 1,
        .oxygen_constraint_fraction = 0.2,
        .host_exchange_enabled = true,
        .timestep_h = 1,
    }, Symbiosis.sourceRuntimeParameters(), 0.1, 0.02, 0.4, fractions);
    try std.testing.expect(result.structural.carbon_g_c > 0);
    try std.testing.expect(result.respiration_oxygen_unlimited_g_c >= result.respiration_actual_g_c);
    try std.testing.expectEqual(
        Symbiosis.Pool{ .carbon_g_c = 0.01, .nitrogen_g_n = 0.001, .phosphorus_g_p = 0.0002 },
        result.external_inoculum_input,
    );
}

test "mature annual root rhizobia stop host exchange without stopping metabolism" {
    const fractions: LitterPartition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const host: Symbiosis.Pool = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.05 };
    const result = try calculate(.{
        .fixation_type = 2,
        .first_subhour = true,
        .fire_active_this_hour = false,
        .structural = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.02, .phosphorus_g_p = 0.02 },
        .mobile = .{ .carbon_g_c = 1, .nitrogen_g_n = 0, .phosphorus_g_p = 0.02 },
        .host_mobile = host,
        .host_structural_carbon_g_c = 10,
        .host_presence_threshold_g_c = 0,
        .cell_area_m2 = 100,
        .temperature_response = 1,
        .growth_water_response = 1,
        .maintenance_temperature_response = 1,
        .maintenance_water_response = 1,
        .oxygen_constraint_fraction = 1,
        .host_exchange_enabled = false,
        .timestep_h = 1,
    }, Symbiosis.sourceRuntimeParameters(), 0.1, 0.02, 0.4, fractions);
    try std.testing.expectEqual(host, result.host_mobile);
    try std.testing.expect(result.respiration_actual_g_c > 0);
}

test "GROSUB root fire suppresses WTNDI infection without suppressing existing nodules" {
    const fractions: LitterPartition.ElementFractions = .{
        .carbon = .{ 1, 0, 0, 0 },
        .nitrogen = .{ 1, 0, 0, 0 },
        .phosphorus = .{ 1, 0, 0, 0 },
    };
    const result = try calculate(.{
        .fixation_type = 1,
        .first_subhour = true,
        .fire_active_this_hour = true,
        .structural = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        .mobile = .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        .host_mobile = .{ .carbon_g_c = 1, .nitrogen_g_n = 0.1, .phosphorus_g_p = 0.01 },
        .host_structural_carbon_g_c = 10,
        .host_presence_threshold_g_c = 0,
        .cell_area_m2 = 100,
        .temperature_response = 1,
        .growth_water_response = 1,
        .maintenance_temperature_response = 1,
        .maintenance_water_response = 1,
        .oxygen_constraint_fraction = 1,
        .host_exchange_enabled = false,
        .timestep_h = 1,
    }, Symbiosis.sourceRuntimeParameters(), 0.1, 0.02, 0.4, fractions);
    try std.testing.expectEqual(
        Symbiosis.Pool{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        result.external_inoculum_input,
    );
}

test "GROSUB newly infected rhizobia immediately contribute CNDLR" {
    try std.testing.expectEqual(
        @as(f64, 0.02),
        try sourceOrderRootDecompositionDensity(0.2, 10, 1.0e-9),
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        try sourceOrderRootDecompositionDensity(0.2, 1.0e-9, 1.0e-9),
    );
}

test "GROSUB root rhizobial maintenance always selects WFNRR" {
    try std.testing.expectEqual(
        @as(f64, 0.25),
        try sourceOrderMaintenanceWaterResponse(0.8, 0.25),
    );
    try std.testing.expectError(
        error.InvalidRootSymbioticWaterResponse,
        sourceOrderMaintenanceWaterResponse(1.1, 0.25),
    );
}

const std = @import("std");

pub const Inputs = struct {
    litter_water_m3: f64,
    reference_litter_volume_m3: f64,
    surface_porosity_m3_per_m3: f64,
    field_capacity_m3_per_m3: f64,
    inactive_water_threshold_m3_per_m3: f64,
    negligible_reference_volume_m3: f64,
    litter_temperature_k: f64,
    thermal_adaptation_offset_k: f64,
};

pub const Result = struct {
    biologically_active_water_m3: f64,
    growth_temperature_response: f64,
    maintenance_temperature_response: f64,
    aqueous_diffusion_temperature_response: f64,
};

/// NITRO.F surface (`L=0`) VOLWY and TFNX equations. This is a pure runtime
/// calculation; respiration activity TOQCK is produced by the microbial
/// reaction ledger and deliberately is not inferred here.
pub fn calculate(inputs: Inputs) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteSurfaceMicrobialEnvironment;
    if (inputs.litter_water_m3 < 0 or inputs.reference_litter_volume_m3 < 0 or inputs.surface_porosity_m3_per_m3 < 0 or inputs.surface_porosity_m3_per_m3 > 1 or inputs.field_capacity_m3_per_m3 < 0 or inputs.field_capacity_m3_per_m3 > 1 or inputs.inactive_water_threshold_m3_per_m3 < 0 or inputs.negligible_reference_volume_m3 < 0 or inputs.litter_temperature_k <= 0 or inputs.litter_temperature_k + inputs.thermal_adaptation_offset_k <= 0) return error.InvalidSurfaceMicrobialEnvironment;

    var active_water_m3: f64 = 0;
    // NITRO.F 270--284: VOLWRX must exceed runtime ZEROS2 before division.
    if (inputs.reference_litter_volume_m3 > inputs.negligible_reference_volume_m3) {
        const relative_water = inputs.litter_water_m3 / inputs.reference_litter_volume_m3;
        const retained_water = @min(@max(0.75 * inputs.surface_porosity_m3_per_m3, inputs.field_capacity_m3_per_m3), relative_water);
        const active_water_concentration = @max(0, retained_water - inputs.inactive_water_threshold_m3_per_m3);
        active_water_m3 = active_water_concentration / (1 + active_water_concentration) * inputs.reference_litter_volume_m3;
    }

    const adapted_temperature_k = inputs.litter_temperature_k + inputs.thermal_adaptation_offset_k;
    const rt_j_per_mol = 8.3143 * adapted_temperature_k;
    const entropy_temperature_j_per_mol = 710 * adapted_temperature_k;
    const inactivation = 1 + @exp((197500 - entropy_temperature_j_per_mol) / rt_j_per_mol) + @exp((entropy_temperature_j_per_mol - 222500) / rt_j_per_mol);
    const temperature_response = @exp(25.229 - 62500 / rt_j_per_mol) / inactivation;
    const maintenance_inactivation = 1 + @exp((197500 - entropy_temperature_j_per_mol) / rt_j_per_mol);
    const maintenance_temperature_response = @min(1e3, @exp(25.216 - 62500 / rt_j_per_mol) / maintenance_inactivation);
    const aqueous_diffusion_temperature_response = std.math.pow(f64, inputs.litter_temperature_k / 298.15, 6);
    if (!std.math.isFinite(active_water_m3) or !std.math.isFinite(temperature_response) or !std.math.isFinite(maintenance_temperature_response) or !std.math.isFinite(aqueous_diffusion_temperature_response) or active_water_m3 < 0 or temperature_response < 0 or maintenance_temperature_response < 0 or aqueous_diffusion_temperature_response < 0) return error.NonFiniteSurfaceMicrobialEnvironment;
    return .{ .biologically_active_water_m3 = active_water_m3, .growth_temperature_response = temperature_response, .maintenance_temperature_response = maintenance_temperature_response, .aqueous_diffusion_temperature_response = aqueous_diffusion_temperature_response };
}

test "surface microbial environment reproduces NITRO active water and TFNX" {
    const result = try calculate(.{ .litter_water_m3 = 0.4, .reference_litter_volume_m3 = 1, .surface_porosity_m3_per_m3 = 0.5, .field_capacity_m3_per_m3 = 0.3, .inactive_water_threshold_m3_per_m3 = 0.1, .negligible_reference_volume_m3 = 1e-12, .litter_temperature_k = 293.15, .thermal_adaptation_offset_k = 0 });
    const active_concentration: f64 = 0.275;
    try std.testing.expectApproxEqAbs(active_concentration / (1 + active_concentration), result.biologically_active_water_m3, 1e-15);
    const rt: f64 = 8.3143 * 293.15;
    const stk: f64 = 710 * 293.15;
    const expected = @exp(25.229 - 62500 / rt) / (1 + @exp((197500 - stk) / rt) + @exp((stk - 222500) / rt));
    try std.testing.expectApproxEqAbs(expected, result.growth_temperature_response, 5e-15);
    const expected_maintenance = @min(1e3, @exp(25.216 - 62500 / rt) / (1 + @exp((197500 - stk) / rt)));
    try std.testing.expectApproxEqAbs(expected_maintenance, result.maintenance_temperature_response, 5e-15);
    try std.testing.expectApproxEqAbs(std.math.pow(f64, 293.15 / 298.15, 6), result.aqueous_diffusion_temperature_response, 5e-15);
}

test "NITRO 270-284 surface active water applies runtime ZEROS2 gate" {
    const result = try calculate(.{
        .litter_water_m3 = 1,
        .reference_litter_volume_m3 = 1e-12,
        .surface_porosity_m3_per_m3 = 0.5,
        .field_capacity_m3_per_m3 = 0.3,
        .inactive_water_threshold_m3_per_m3 = 0.1,
        .negligible_reference_volume_m3 = 1e-12,
        .litter_temperature_k = 293.15,
        .thermal_adaptation_offset_k = 0,
    });
    try std.testing.expectEqual(@as(f64, 0), result.biologically_active_water_m3);
}

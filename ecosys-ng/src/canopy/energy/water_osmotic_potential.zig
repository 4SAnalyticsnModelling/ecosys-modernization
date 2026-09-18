// **A8a DISPOSITION: BOUND; CANOPY-TURGOR-001 closed with CANOPY-TKC-001.**
// `canopy_coupled_convergence` evaluates these UPTAKE.F 957--962 osmotic and
// turgor equations at every TKCY/root-water iterate. The accepted pair is
// published atomically to the detailed canopy before downstream dormancy,
// growth, reproduction, and output consumers run.
const std = @import("std");

pub const Inputs = struct {
    canopy_total_water_potential_megapascal: f64,
    minimum_dry_matter_fraction_g_c_per_g: f64,
    canopy_water_mass_g: f64,
    osmotic_potential_at_zero_total_megapascal: f64,
    canopy_surface_temperature_k: f64,
    nonstructural_solute_concentration_g_per_g_c: f64,
    solute_molar_mass_g_per_mol: f64,
    canopy_salt_concentration_mol_per_g_c: f64,
};

pub const Result = struct {
    absolute_total_water_potential_megapascal: f64,
    dry_matter_fraction_g_c_per_g: f64,
    canopy_water_volume_m3: f64,
    osmotic_water_potential_megapascal: f64,
    turgor_water_potential_megapascal: f64,
};

/// UPTAKE.F 957--962. Evaluates canopy water content and osmotic/turgor
/// potentials inside one runtime Newton/Picard residual evaluation.
pub fn calculate(inputs: Inputs) !Result {
    try validate(inputs);
    const absolute_potential = @abs(inputs.canopy_total_water_potential_megapascal);
    const dry_matter_fraction =
        inputs.minimum_dry_matter_fraction_g_c_per_g +
        0.10 * absolute_potential / (0.05 * absolute_potential + 2.0);
    if (dry_matter_fraction <= 0)
        return error.InvalidCanopyDryMatterFraction;
    const water_volume =
        1.0e-6 * inputs.canopy_water_mass_g / dry_matter_fraction;
    const osmotic_potential =
        dry_matter_fraction /
        inputs.minimum_dry_matter_fraction_g_c_per_g *
        inputs.osmotic_potential_at_zero_total_megapascal -
        8.3143 * inputs.canopy_surface_temperature_k *
            dry_matter_fraction *
            (inputs.nonstructural_solute_concentration_g_per_g_c /
                inputs.solute_molar_mass_g_per_mol +
                inputs.canopy_salt_concentration_mol_per_g_c);
    const turgor_potential = @max(
        0,
        inputs.canopy_total_water_potential_megapascal - osmotic_potential,
    );
    const result = Result{
        .absolute_total_water_potential_megapascal = absolute_potential,
        .dry_matter_fraction_g_c_per_g = dry_matter_fraction,
        .canopy_water_volume_m3 = water_volume,
        .osmotic_water_potential_megapascal = osmotic_potential,
        .turgor_water_potential_megapascal = turgor_potential,
    };
    inline for (@typeInfo(Result).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteCanopyWaterPotentialResult;
    return result;
}

fn validate(inputs: Inputs) !void {
    inline for (@typeInfo(Inputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.InvalidCanopyWaterPotentialInput;
    if (inputs.minimum_dry_matter_fraction_g_c_per_g <= 0 or
        inputs.canopy_water_mass_g < 0 or
        inputs.canopy_surface_temperature_k <= 0 or
        inputs.nonstructural_solute_concentration_g_per_g_c < 0 or
        inputs.solute_molar_mass_g_per_mol <= 0 or
        inputs.canopy_salt_concentration_mol_per_g_c < 0)
        return error.InvalidCanopyWaterPotentialInput;
}

fn sourceInputs() Inputs {
    return .{
        .canopy_total_water_potential_megapascal = -1,
        .minimum_dry_matter_fraction_g_c_per_g = 0.16,
        .canopy_water_mass_g = 100,
        .osmotic_potential_at_zero_total_megapascal = -1.5,
        .canopy_surface_temperature_k = 300,
        .nonstructural_solute_concentration_g_per_g_c = 0.12,
        .solute_molar_mass_g_per_mol = 200,
        .canopy_salt_concentration_mol_per_g_c = 0.001,
    };
}

test "UPTAKE canopy water and osmotic potentials preserve source order" {
    const inputs = sourceInputs();
    const result = try calculate(inputs);
    const absolute_potential = @abs(inputs.canopy_total_water_potential_megapascal);
    const dry_matter_fraction =
        inputs.minimum_dry_matter_fraction_g_c_per_g +
        0.10 * absolute_potential / (0.05 * absolute_potential + 2.0);
    const water_volume =
        1.0e-6 * inputs.canopy_water_mass_g / dry_matter_fraction;
    const osmotic_potential =
        dry_matter_fraction /
        inputs.minimum_dry_matter_fraction_g_c_per_g *
        inputs.osmotic_potential_at_zero_total_megapascal -
        8.3143 * inputs.canopy_surface_temperature_k *
            dry_matter_fraction *
            (inputs.nonstructural_solute_concentration_g_per_g_c /
                inputs.solute_molar_mass_g_per_mol +
                inputs.canopy_salt_concentration_mol_per_g_c);
    try std.testing.expectEqual(absolute_potential, result.absolute_total_water_potential_megapascal);
    try std.testing.expectEqual(dry_matter_fraction, result.dry_matter_fraction_g_c_per_g);
    try std.testing.expectEqual(water_volume, result.canopy_water_volume_m3);
    try std.testing.expectEqual(osmotic_potential, result.osmotic_water_potential_megapascal);
    try std.testing.expectEqual(
        @max(0, inputs.canopy_total_water_potential_megapascal - osmotic_potential),
        result.turgor_water_potential_megapascal,
    );
}

test "UPTAKE turgor potential retains zero floor" {
    var inputs = sourceInputs();
    inputs.canopy_total_water_potential_megapascal = -10;
    inputs.osmotic_potential_at_zero_total_megapascal = -0.1;
    inputs.nonstructural_solute_concentration_g_per_g_c = 0;
    inputs.canopy_salt_concentration_mol_per_g_c = 0;
    const result = try calculate(inputs);
    try std.testing.expectEqual(@as(f64, 0), result.turgor_water_potential_megapascal);
}

test "invalid divisors and non-finite inputs fail explicitly" {
    var inputs = sourceInputs();
    inputs.solute_molar_mass_g_per_mol = 0;
    try std.testing.expectError(
        error.InvalidCanopyWaterPotentialInput,
        calculate(inputs),
    );
    inputs = sourceInputs();
    inputs.canopy_total_water_potential_megapascal = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidCanopyWaterPotentialInput,
        calculate(inputs),
    );
}

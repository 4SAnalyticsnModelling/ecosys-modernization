const std = @import("std");

pub const Parameters = struct {
    particulate_carbon_fraction: f64,
    organic_nitrogen_maximum_fraction_of_carbon: f64,
    organic_nitrogen_scale_g_per_megagram: f64,
    organic_nitrogen_reference_carbon_g_per_megagram: f64,
    organic_nitrogen_exponent: f64,
    organic_phosphorus_maximum_fraction_of_carbon: f64,
    organic_phosphorus_scale_g_per_megagram: f64,
    organic_phosphorus_reference_carbon_g_per_megagram: f64,
    organic_phosphorus_exponent: f64,
    cec_conversion_mol_per_megagram_per_cmol_per_kg: f64,
    organic_matter_per_carbon: f64,
    organic_matter_cec_cmol_per_kg: f64,
    clay_cec_cmol_per_kg: f64,
    silt_cec_cmol_per_kg: f64,
    sand_cec_cmol_per_kg: f64,
    minimum_ammonium_g_per_megagram: f64,
    minimum_calcium_g_per_megagram: f64,

    pub fn validate(self: Parameters) !void {
        inline for (@typeInfo(Parameters).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilProfileDerivationParameter;
        }
        if (self.organic_nitrogen_reference_carbon_g_per_megagram <= 0 or self.organic_phosphorus_reference_carbon_g_per_megagram <= 0 or self.cec_conversion_mol_per_megagram_per_cmol_per_kg <= 0) return error.InvalidSoilProfileDerivationParameter;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .particulate_carbon_fraction = 0.067,
        .organic_nitrogen_maximum_fraction_of_carbon = 0.125,
        .organic_nitrogen_scale_g_per_megagram = 890,
        .organic_nitrogen_reference_carbon_g_per_megagram = 10_000,
        .organic_nitrogen_exponent = 0.80,
        .organic_phosphorus_maximum_fraction_of_carbon = 0.0125,
        .organic_phosphorus_scale_g_per_megagram = 120,
        .organic_phosphorus_reference_carbon_g_per_megagram = 10_000,
        .organic_phosphorus_exponent = 0.52,
        .cec_conversion_mol_per_megagram_per_cmol_per_kg = 10,
        .organic_matter_per_carbon = 1.82,
        .organic_matter_cec_cmol_per_kg = 200,
        .clay_cec_cmol_per_kg = 80,
        .silt_cec_cmol_per_kg = 20,
        .sand_cec_cmol_per_kg = 5,
        .minimum_ammonium_g_per_megagram = 1,
        .minimum_calcium_g_per_megagram = 1,
    };
}

pub const Resolved = struct {
    particulate_organic_carbon_g_per_megagram: f64,
    organic_nitrogen_g_per_megagram: f64,
    organic_phosphorus_g_per_megagram: f64,
    cation_exchange_capacity_mol_per_megagram: f64,
    ammonium_g_per_megagram: f64,
    calcium_g_per_megagram: f64,
};

pub fn resolve(parameters: Parameters, total_organic_carbon_g_per_megagram: f64, supplied_particulate_carbon_g_per_megagram: f64, supplied_organic_nitrogen_g_per_megagram: f64, supplied_organic_phosphorus_g_per_megagram: f64, supplied_cec_cmol_per_kg: f64, supplied_ammonium_g_per_megagram: f64, supplied_calcium_g_per_megagram: f64, sand_fraction: f64, silt_fraction: f64, clay_fraction: f64) !Resolved {
    try parameters.validate();
    inline for (.{ total_organic_carbon_g_per_megagram, supplied_particulate_carbon_g_per_megagram, supplied_organic_nitrogen_g_per_megagram, supplied_organic_phosphorus_g_per_megagram, supplied_cec_cmol_per_kg, supplied_ammonium_g_per_megagram, supplied_calcium_g_per_megagram, sand_fraction, silt_fraction, clay_fraction }) |value| if (!std.math.isFinite(value)) return error.NonFiniteSoilProfileDerivationInput;
    if (total_organic_carbon_g_per_megagram < 0 or sand_fraction < 0 or silt_fraction < 0 or clay_fraction < 0) return error.InvalidSoilProfileDerivationInput;
    const particulate = if (supplied_particulate_carbon_g_per_megagram < 0)
        parameters.particulate_carbon_fraction * total_organic_carbon_g_per_megagram
    else
        supplied_particulate_carbon_g_per_megagram;
    const nitrogen = if (supplied_organic_nitrogen_g_per_megagram < 0)
        @min(
            parameters.organic_nitrogen_maximum_fraction_of_carbon * total_organic_carbon_g_per_megagram,
            parameters.organic_nitrogen_scale_g_per_megagram * std.math.pow(f64, total_organic_carbon_g_per_megagram / parameters.organic_nitrogen_reference_carbon_g_per_megagram, parameters.organic_nitrogen_exponent),
        )
    else
        supplied_organic_nitrogen_g_per_megagram;
    const phosphorus = if (supplied_organic_phosphorus_g_per_megagram < 0)
        @min(
            parameters.organic_phosphorus_maximum_fraction_of_carbon * total_organic_carbon_g_per_megagram,
            parameters.organic_phosphorus_scale_g_per_megagram * std.math.pow(f64, total_organic_carbon_g_per_megagram / parameters.organic_phosphorus_reference_carbon_g_per_megagram, parameters.organic_phosphorus_exponent),
        )
    else
        supplied_organic_phosphorus_g_per_megagram;
    const cec = if (supplied_cec_cmol_per_kg < 0)
        parameters.cec_conversion_mol_per_megagram_per_cmol_per_kg *
            (parameters.organic_matter_cec_cmol_per_kg * parameters.organic_matter_per_carbon * total_organic_carbon_g_per_megagram / 1.0e6 +
                parameters.clay_cec_cmol_per_kg * clay_fraction +
                parameters.silt_cec_cmol_per_kg * silt_fraction +
                parameters.sand_cec_cmol_per_kg * sand_fraction)
    else
        parameters.cec_conversion_mol_per_megagram_per_cmol_per_kg * supplied_cec_cmol_per_kg;
    const result: Resolved = .{
        .particulate_organic_carbon_g_per_megagram = particulate,
        .organic_nitrogen_g_per_megagram = nitrogen,
        .organic_phosphorus_g_per_megagram = phosphorus,
        .cation_exchange_capacity_mol_per_megagram = cec,
        .ammonium_g_per_megagram = @max(parameters.minimum_ammonium_g_per_megagram, supplied_ammonium_g_per_megagram),
        .calcium_g_per_megagram = @max(parameters.minimum_calcium_g_per_megagram, supplied_calcium_g_per_megagram),
    };
    inline for (@typeInfo(Resolved).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0) return error.InvalidResolvedSoilProfileProperty;
    return result;
}

test "READI derives missing particulate carbon SON SOP and CEC" {
    const result = try resolve(compatibilityParameters(), 20_000, -1, -1, -1, -1, 0, 0, 0.4, 0.4, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 1_340), result.particulate_organic_carbon_g_per_megagram, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 890 * std.math.pow(f64, 2, 0.8)), result.organic_nitrogen_g_per_megagram, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 120 * std.math.pow(f64, 2, 0.52)), result.organic_phosphorus_g_per_megagram, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10 * (200 * 1.82 * 20_000 / 1e6 + 80 * 0.2 + 20 * 0.4 + 5 * 0.4)), result.cation_exchange_capacity_mol_per_megagram, 1e-12);
    try std.testing.expectEqual(@as(f64, 1), result.ammonium_g_per_megagram);
    try std.testing.expectEqual(@as(f64, 1), result.calcium_g_per_megagram);
}

const std = @import("std");

/// Layer totals accumulated from the runtime-sized microbial populations and
/// substrate complexes before NITRO publishes its REDIST gas-flux arrays.
pub const Inputs = struct {
    autotrophic_carbon_dioxide_uptake_g_c: f64,
    aerobic_heterotrophic_carbon_dioxide_emission_g_c: f64,
    denitrification_carbon_dioxide_emission_g_c: f64,
    methane_oxidation_g_c: f64,
    methanotrophic_carbon_uptake_g_c: f64,
    methane_emission_g_c: f64,
    hydrogenotrophic_hydrogen_uptake_g_h: f64,
    fermentative_hydrogen_emission_g_h: f64,
    oxygen_uptake_g_o: f64,
    nitrous_oxide_reduction_g_n: f64,
    chemodenitrification_dinitrogen_production_g_n: f64,
    biological_nitrite_reduction_g_n: f64,
    chemodenitrification_nitrous_oxide_production_g_n: f64,
};

/// Source-equation oracle for nitro.f:3996-4020. Production state is committed
/// by the nitrogen, methane, oxygen, and autotrophic-carbon owners; the former
/// unread runtime aggregation shadow was removed after independent comparison
/// proved that it had zero consumers and contained stale, incomplete terms.
pub const Result = struct {
    /// Source `RCO2O`: positive is net biological CO2 uptake.
    source_signed_net_carbon_dioxide_uptake_g_c: f64,
    /// Source `RCH4O`: positive is net biological CH4 uptake.
    source_signed_net_methane_uptake_g_c: f64,
    /// Source `RH2GO`: positive is net biological H2 uptake.
    source_signed_net_hydrogen_uptake_g_h: f64,
    /// Source `RUPOXO`: positive oxygen removal from the gas/water domain.
    oxygen_uptake_g_o: f64,
    /// Source `RN2G`: production is negative under the transport flux sign.
    source_signed_dinitrogen_flux_g_n: f64,
    /// Source `RN2O`: production is negative and reduction is positive.
    source_signed_nitrous_oxide_flux_g_n: f64,
};

/// Exact NITRO aggregation following labels 640/645:
/// RCO2O, RCH4O, RH2GO, RUPOXO, RN2G, and RN2O.
pub fn aggregate(inputs: Inputs) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteSoilBiogeochemicalGasFlux;
        if (value < 0) return error.NegativeSoilBiogeochemicalGasComponent;
    }
    const result: Result = .{
        .source_signed_net_carbon_dioxide_uptake_g_c = inputs.autotrophic_carbon_dioxide_uptake_g_c -
            inputs.aerobic_heterotrophic_carbon_dioxide_emission_g_c -
            inputs.denitrification_carbon_dioxide_emission_g_c -
            inputs.methane_oxidation_g_c,
        .source_signed_net_methane_uptake_g_c = inputs.methane_oxidation_g_c +
            inputs.methanotrophic_carbon_uptake_g_c -
            inputs.methane_emission_g_c,
        .source_signed_net_hydrogen_uptake_g_h = inputs.hydrogenotrophic_hydrogen_uptake_g_h -
            inputs.fermentative_hydrogen_emission_g_h,
        .oxygen_uptake_g_o = inputs.oxygen_uptake_g_o,
        .source_signed_dinitrogen_flux_g_n = -inputs.nitrous_oxide_reduction_g_n -
            inputs.chemodenitrification_dinitrogen_production_g_n,
        .source_signed_nitrous_oxide_flux_g_n = -inputs.biological_nitrite_reduction_g_n -
            inputs.chemodenitrification_nitrous_oxide_production_g_n +
            inputs.nitrous_oxide_reduction_g_n,
    };
    inline for (@typeInfo(Result).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteSoilBiogeochemicalGasFlux;
    }
    return result;
}

test "NITRO layer gas aggregation preserves exact source signs and terms" {
    const result = try aggregate(.{
        .autotrophic_carbon_dioxide_uptake_g_c = 10,
        .aerobic_heterotrophic_carbon_dioxide_emission_g_c = 2,
        .denitrification_carbon_dioxide_emission_g_c = 1,
        .methane_oxidation_g_c = 0.5,
        .methanotrophic_carbon_uptake_g_c = 0.25,
        .methane_emission_g_c = 1.5,
        .hydrogenotrophic_hydrogen_uptake_g_h = 0.8,
        .fermentative_hydrogen_emission_g_h = 0.3,
        .oxygen_uptake_g_o = 4,
        .nitrous_oxide_reduction_g_n = 0.6,
        .chemodenitrification_dinitrogen_production_g_n = 0.1,
        .biological_nitrite_reduction_g_n = 1.2,
        .chemodenitrification_nitrous_oxide_production_g_n = 0.2,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 6.5), result.source_signed_net_carbon_dioxide_uptake_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.75), result.source_signed_net_methane_uptake_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.source_signed_net_hydrogen_uptake_g_h, 1e-15);
    try std.testing.expectEqual(@as(f64, 4), result.oxygen_uptake_g_o);
    try std.testing.expectApproxEqAbs(@as(f64, -0.7), result.source_signed_dinitrogen_flux_g_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -0.8), result.source_signed_nitrous_oxide_flux_g_n, 1e-15);
}

test "gas aggregation rejects invalid components instead of propagating them" {
    const zero: Inputs = std.mem.zeroes(Inputs);
    var invalid = zero;
    invalid.methane_emission_g_c = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteSoilBiogeochemicalGasFlux, aggregate(invalid));
    invalid = zero;
    invalid.oxygen_uptake_g_o = -1;
    try std.testing.expectError(error.NegativeSoilBiogeochemicalGasComponent, aggregate(invalid));
}

test "dead gas aggregation shadow cannot re-enter production" {
    const module = @This();
    try std.testing.expect(!@hasDecl(module, "State"));
    try std.testing.expect(!@hasDecl(module, "ApplyContext"));
    try std.testing.expect(!@hasDecl(module, "ProcessContext"));
    try std.testing.expect(!@hasDecl(module, "applyTile"));
    try std.testing.expect(!@hasDecl(module, "aggregateProcess" ++ "Tile"));
}

const std = @import("std");
const PlantLedger = @import("../../plant/accounting/daily_flux.zig").State;

pub const Result = struct {
    gross_primary_productivity_g_c: f64 = 0,
    autotrophic_respiration_g_c: f64 = 0,
    net_primary_productivity_g_c: f64 = 0,
    plant_litterfall_g_c: f64 = 0,
    harvested_carbon_g_c: f64 = 0,
};

/// EXTRACT/REDIST aggregation of TGPP, TRAU, TNPP, UXCSN, and XHVSTC.
/// TGPP is accumulated from the authoritative carboxylation ledger so
/// disturbance deductions in HCNET cannot be mistaken for lost fixation.
/// TRAU includes signed shoot+root respiration and TNPP retains the source
/// `TGPP + TRAU` identity.
pub fn calculate(ledger: *const PlantLedger, cell: usize, species_count: usize) !Result {
    if (species_count == 0 or ledger.plant_count % species_count != 0 or cell >= ledger.plant_count / species_count) return error.DailyPlantCarbonCellOutOfBounds;
    var result: Result = .{};
    for (0..species_count) |species| {
        const plant = cell * species_count + species;
        result.gross_primary_productivity_g_c += ledger.gross_primary_productivity_g[plant];
        result.autotrophic_respiration_g_c += ledger.signed_total_respiration_carbon_g[plant];
        result.plant_litterfall_g_c += ledger.carbon_sink_g[plant];
        result.harvested_carbon_g_c += ledger.harvested_carbon_g[plant];
    }
    result.net_primary_productivity_g_c = result.gross_primary_productivity_g_c + result.autotrophic_respiration_g_c;
    inline for (@typeInfo(Result).@"struct".fields) |field| if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteDailyPlantCarbonFlux;
    if (result.gross_primary_productivity_g_c < 0 or result.plant_litterfall_g_c < 0 or result.harvested_carbon_g_c < 0) return error.InvalidDailyPlantCarbonFlux;
    return result;
}

test "REDIST ecosystem plant carbon identities support runtime species" {
    var ledger = try PlantLedger.init(std.testing.allocator, 7);
    defer ledger.deinit();
    for (0..7) |plant| {
        ledger.net_carbon_change_g[plant] = 8;
        ledger.gross_primary_productivity_g[plant] = 10;
        ledger.signed_aboveground_respiration_carbon_g[plant] = -2;
        ledger.signed_total_respiration_carbon_g[plant] = -3;
        ledger.carbon_sink_g[plant] = 0.5;
        ledger.harvested_carbon_g[plant] = 0.25;
    }
    const result = try calculate(&ledger, 0, 7);
    try std.testing.expectEqual(@as(f64, 70), result.gross_primary_productivity_g_c);
    try std.testing.expectEqual(@as(f64, -21), result.autotrophic_respiration_g_c);
    try std.testing.expectEqual(@as(f64, 49), result.net_primary_productivity_g_c);
    try std.testing.expectEqual(@as(f64, 3.5), result.plant_litterfall_g_c);
    try std.testing.expectEqual(@as(f64, 1.75), result.harvested_carbon_g_c);
}

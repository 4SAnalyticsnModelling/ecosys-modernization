//! Tests for `combustion.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const SoilOrganic = @import("initialization.zig");
const FireExchange = @import("../biogeochemistry/organic_matter_fire_exchange.zig");
const combustion_module = @import("combustion.zig");

test "runtime organic pool combustion removes elements proportionally" {
    var pools = [_]combustion_module.OrganicPool{ .{ .carbon_g_c = 10, .associated_carbon_g_c = 2, .nitrogen_g_n = 1, .phosphorus_g_p = 0.2 }, .{ .carbon_g_c = 5, .associated_carbon_g_c = 1, .nitrogen_g_n = 0.5, .phosphorus_g_p = 0.1 }, .{ .carbon_g_c = 0, .associated_carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 } };
    var fluxes: [3]combustion_module.OrganicPool = undefined;
    const result = try combustion_module.burnPools(&pools, &fluxes, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 3), result.combusted_carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 12), pools[0].carbon_g_c + pools[1].carbon_g_c, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), result.combusted_nitrogen_g_n, 1e-14);
}

test "regular and charcoal Arrhenius fractions are bounded" {
    const inputs: combustion_module.LayerInputs = .{ .fire_active = true, .soil_temperature_k = 700, .combustion_temperature_threshold_k = 500, .maximum_arrhenius_response = 10, .total_soil_organic_carbon_g_c = 100, .negligible_carbon_g_c = 0, .cell_layer_area_m2 = 10, .timestep_h = 1 };
    const regular = try combustion_module.regularCombustionFraction(inputs, 1);
    const charcoal = try combustion_module.charcoalCombustionFraction(inputs, 10, 1);
    try std.testing.expect(regular.fraction >= 0 and regular.fraction <= 1);
    try std.testing.expect(charcoal >= 0 and charcoal <= 1);
}

test "NITRO 4299-4311 regular fractions preserve K order and source arithmetic" {
    const inputs: combustion_module.LayerInputs = .{
        .fire_active = true,
        .soil_temperature_k = 600,
        .combustion_temperature_threshold_k = 500,
        .maximum_arrhenius_response = 10,
        .total_soil_organic_carbon_g_c = 1.0e9,
        .negligible_carbon_g_c = 0,
        .cell_layer_area_m2 = 3,
        .timestep_h = 0.25,
    };
    const rates = (combustion_module.Parameters{}).specific_combustion_by_substrate_g_c_per_m2_h;
    const response = @min(
        inputs.maximum_arrhenius_response,
        @exp(12.028 - 60000 / (8.3143 * inputs.soil_temperature_k)),
    );
    for (rates) |rate| {
        const result = try combustion_module.regularCombustionFraction(inputs, rate);
        const expected = @min(
            1,
            rate * response / inputs.total_soil_organic_carbon_g_c *
                inputs.cell_layer_area_m2 * inputs.timestep_h,
        );
        try std.testing.expectEqual(expected, result.fraction);
        try std.testing.expectEqual(@min(1, response), result.transfer_response);
    }
}

test "inactive NITRO fire leaves existing pools and transfer response unchanged" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(
        std.testing.allocator,
        1,
        SoilOrganic.microbial_substrate_count,
    );
    defer fire_exchange.deinit();
    organic.microbial[0].carbon_g_c = 10;
    fire_exchange.combustion_temperature_response[0] = 0.75;
    const result = try combustion_module.burnOrganicStateLayer(
        &organic,
        &fire_exchange,
        0,
        false,
        600,
        1,
        1,
        .{},
    );
    try std.testing.expectEqual(@as(f64, 0), result.combusted_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 10), organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(
        @as(f64, 0.75),
        fire_exchange.combustion_temperature_response[0],
    );
}

test "NITRO 4299-4311 ZEROS gate retains TFNCOS but clears every FRCBCO" {
    const inputs: combustion_module.LayerInputs = .{
        .fire_active = true,
        .soil_temperature_k = 700,
        .combustion_temperature_threshold_k = 500,
        .maximum_arrhenius_response = 10,
        .total_soil_organic_carbon_g_c = 1.0e-10,
        .negligible_carbon_g_c = 1.0e-10,
        .cell_layer_area_m2 = 10,
        .timestep_h = 1,
    };
    const result = try combustion_module.regularCombustionFraction(inputs, 1_000);
    try std.testing.expectEqual(@as(f64, 0), result.fraction);
    try std.testing.expect(result.transfer_response > 0 and result.transfer_response <= 1);
}

test "NITRO 4299-4311 evaluates FRCBCO before per-pool temperature gates" {
    const inputs: combustion_module.LayerInputs = .{
        .fire_active = true,
        .soil_temperature_k = 450,
        .combustion_temperature_threshold_k = 500,
        .maximum_arrhenius_response = 10,
        .total_soil_organic_carbon_g_c = 100,
        .negligible_carbon_g_c = 0,
        .cell_layer_area_m2 = 10,
        .timestep_h = 1,
    };
    const result = try combustion_module.regularCombustionFraction(inputs, 1_000);
    try std.testing.expect(result.fraction > 0);
    try std.testing.expect(result.transfer_response > 0);
}

test "NITRO 4344-4346 and 4389-4391 publish negative combustion losses" {
    const loss = try combustion_module.sourceSignedCombustionLoss(12, 1.5, 0.25);
    try std.testing.expectEqual(@as(f64, -12), loss.carbon_change_g_c);
    try std.testing.expectEqual(@as(f64, -1.5), loss.nitrogen_change_g_n);
    try std.testing.expectEqual(@as(f64, -0.25), loss.phosphorus_change_g_p);
}

test "NITRO combustion loss diagnostic rejects a non-finite late element" {
    try std.testing.expectError(
        error.InvalidCombustionLossDiagnostic,
        combustion_module.sourceSignedCombustionLoss(1, 2, std.math.nan(f64)),
    );
}

test "NITRO soil fire publishes all organic pool families to shared layer ledger" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 2);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 2, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.microbial[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 };
    organic.residue[0] = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 };
    organic.dissolved[0] = .{ .carbon_g_c = 6, .nitrogen_g_n = 0.6, .phosphorus_g_p = 0.06 };
    organic.adsorbed[0] = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 };
    organic.structural[0] = .{ .carbon_g_c = 12, .nitrogen_g_n = 1.2, .phosphorus_g_p = 0.12 };
    organic.structural[SoilOrganic.structural_fraction_count - 1] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 };
    const before_c = try organic.totalCarbon_g_c(0);
    const before_n: f64 = 1 + 0.8 + 0.6 + 0.4 + 1.2 + 0.2;
    const before_p: f64 = 0.1 + 0.08 + 0.06 + 0.04 + 0.12 + 0.02;
    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, .{});
    const after_c = try organic.totalCarbon_g_c(0);
    const after_n = organic.microbial[0].nitrogen_g_n + organic.residue[0].nitrogen_g_n + organic.dissolved[0].nitrogen_g_n + organic.adsorbed[0].nitrogen_g_n + organic.structural[0].nitrogen_g_n + organic.structural[SoilOrganic.structural_fraction_count - 1].nitrogen_g_n;
    const after_p = organic.microbial[0].phosphorus_g_p + organic.residue[0].phosphorus_g_p + organic.dissolved[0].phosphorus_g_p + organic.adsorbed[0].phosphorus_g_p + organic.structural[0].phosphorus_g_p + organic.structural[SoilOrganic.structural_fraction_count - 1].phosphorus_g_p;
    try std.testing.expect(result.combusted_carbon_g_c > 0);
    try std.testing.expectApproxEqAbs(before_c, after_c + result.combusted_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(before_n, after_n + result.combusted_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(before_p, after_p + result.combusted_phosphorus_g_p, 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_carbon_g_c, fire_exchange.unlimited_combustion_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_nitrogen_g_n, fire_exchange.combusted_nitrogen_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_phosphorus_g_p, fire_exchange.combusted_phosphorus_g_p[0], 1e-12);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.unlimited_combustion_carbon_g_c[1]);
}

test "NITRO organic combustion state_update rolls back all C N P owners on late ledger failure" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.microbial[0] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 };
    organic.residue[0] = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 };
    organic.dissolved[0] = .{ .carbon_g_c = 6, .nitrogen_g_n = 0.6, .phosphorus_g_p = 0.06 };
    organic.dissolved_acetate_carbon_g_c[0] = 1.5;
    organic.adsorbed[0] = .{ .carbon_g_c = 4, .nitrogen_g_n = 0.4, .phosphorus_g_p = 0.04 };
    organic.adsorbed_acetate_carbon_g_c[0] = 0.75;
    organic.structural[0] = .{ .carbon_g_c = 12, .nitrogen_g_n = 1.2, .phosphorus_g_p = 0.12 };
    organic.colonized_structural_carbon_g_c[0] = 2.4;
    const charcoal_index = SoilOrganic.structural_fraction_count - 1;
    organic.structural[charcoal_index] = .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.03 };
    organic.colonized_structural_carbon_g_c[charcoal_index] = 0.6;
    const microbial_before = organic.microbial[0];
    const residue_before = organic.residue[0];
    const dissolved_before = organic.dissolved[0];
    const dissolved_acetate_before = organic.dissolved_acetate_carbon_g_c[0];
    const adsorbed_before = organic.adsorbed[0];
    const adsorbed_acetate_before = organic.adsorbed_acetate_carbon_g_c[0];
    const structural_before = organic.structural[0];
    const colonized_structural_before = organic.colonized_structural_carbon_g_c[0];
    const charcoal_before = organic.structural[charcoal_index];
    const colonized_charcoal_before = organic.colonized_structural_carbon_g_c[charcoal_index];
    fire_exchange.combusted_nitrogen_g_n[0] = std.math.inf(f64);

    try std.testing.expectError(
        error.NonFiniteOrganicMatterFireLedger,
        combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, .{}),
    );

    try std.testing.expectEqual(microbial_before.carbon_g_c, organic.microbial[0].carbon_g_c);
    try std.testing.expectEqual(microbial_before.nitrogen_g_n, organic.microbial[0].nitrogen_g_n);
    try std.testing.expectEqual(microbial_before.phosphorus_g_p, organic.microbial[0].phosphorus_g_p);
    try std.testing.expectEqual(residue_before.carbon_g_c, organic.residue[0].carbon_g_c);
    try std.testing.expectEqual(residue_before.nitrogen_g_n, organic.residue[0].nitrogen_g_n);
    try std.testing.expectEqual(residue_before.phosphorus_g_p, organic.residue[0].phosphorus_g_p);
    try std.testing.expectEqual(dissolved_before.carbon_g_c, organic.dissolved[0].carbon_g_c);
    try std.testing.expectEqual(dissolved_before.nitrogen_g_n, organic.dissolved[0].nitrogen_g_n);
    try std.testing.expectEqual(dissolved_before.phosphorus_g_p, organic.dissolved[0].phosphorus_g_p);
    try std.testing.expectEqual(dissolved_acetate_before, organic.dissolved_acetate_carbon_g_c[0]);
    try std.testing.expectEqual(adsorbed_before.carbon_g_c, organic.adsorbed[0].carbon_g_c);
    try std.testing.expectEqual(adsorbed_before.nitrogen_g_n, organic.adsorbed[0].nitrogen_g_n);
    try std.testing.expectEqual(adsorbed_before.phosphorus_g_p, organic.adsorbed[0].phosphorus_g_p);
    try std.testing.expectEqual(adsorbed_acetate_before, organic.adsorbed_acetate_carbon_g_c[0]);
    try std.testing.expectEqual(structural_before.carbon_g_c, organic.structural[0].carbon_g_c);
    try std.testing.expectEqual(structural_before.nitrogen_g_n, organic.structural[0].nitrogen_g_n);
    try std.testing.expectEqual(structural_before.phosphorus_g_p, organic.structural[0].phosphorus_g_p);
    try std.testing.expectEqual(colonized_structural_before, organic.colonized_structural_carbon_g_c[0]);
    try std.testing.expectEqual(charcoal_before.carbon_g_c, organic.structural[charcoal_index].carbon_g_c);
    try std.testing.expectEqual(charcoal_before.nitrogen_g_n, organic.structural[charcoal_index].nitrogen_g_n);
    try std.testing.expectEqual(charcoal_before.phosphorus_g_p, organic.structural[charcoal_index].phosphorus_g_p);
    try std.testing.expectEqual(colonized_charcoal_before, organic.colonized_structural_carbon_g_c[charcoal_index]);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.unlimited_combustion_carbon_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.combusted_carbon_by_substrate_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.combusted_phosphorus_g_p[0]);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.combustion_temperature_response[0]);
}

test "NITRO 4361-4400 microbial residue fire conserves C N P independently" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.residue[0] = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.8, .phosphorus_g_p = 0.08 };
    organic.residue[SoilOrganic.residue_fraction_count + 1] = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.25, .phosphorus_g_p = 0.015 };
    const before_c: f64 = 13;
    const before_n: f64 = 1.05;
    const before_p: f64 = 0.095;

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, .{});

    const after_c = organic.residue[0].carbon_g_c + organic.residue[SoilOrganic.residue_fraction_count + 1].carbon_g_c;
    const after_n = organic.residue[0].nitrogen_g_n + organic.residue[SoilOrganic.residue_fraction_count + 1].nitrogen_g_n;
    const after_p = organic.residue[0].phosphorus_g_p + organic.residue[SoilOrganic.residue_fraction_count + 1].phosphorus_g_p;
    try std.testing.expectApproxEqAbs(before_c, after_c + result.combusted_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(before_n, after_n + result.combusted_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(before_p, after_p + result.combusted_phosphorus_g_p, 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_carbon_g_c, fire_exchange.unlimited_combustion_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_nitrogen_g_n, fire_exchange.combusted_nitrogen_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_phosphorus_g_p, fire_exchange.combusted_phosphorus_g_p[0], 1e-12);
}

test "NITRO microbial residue fire retains pools at the scaled runtime ZEROS threshold" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.residue[0] = .{ .carbon_g_c = 1e-10, .nitrogen_g_n = 1e-11, .phosphorus_g_p = 1e-12 };
    var parameters: combustion_module.Parameters = .{};
    parameters.negligible_carbon_g_c = 0;
    parameters.physical_relative_tolerance = 1;

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, parameters);

    try std.testing.expectEqual(@as(f64, 1e-10), organic.residue[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1e-11), organic.residue[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1e-12), organic.residue[0].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 0), result.combusted_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.unlimited_combustion_carbon_g_c[0]);
    try std.testing.expect(result.transfer_temperature_response > 0);
    try std.testing.expectEqual(result.transfer_temperature_response, fire_exchange.combustion_temperature_response[0]);
}

test "NITRO 4402-4443 dissolved organic fire conserves C N P and acetate fraction" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.dissolved[0] = .{ .carbon_g_c = 12, .nitrogen_g_n = 0.9, .phosphorus_g_p = 0.12 };
    organic.dissolved_acetate_carbon_g_c[0] = 3;
    organic.dissolved[2] = .{ .carbon_g_c = 5, .nitrogen_g_n = 0.25, .phosphorus_g_p = 0.015 };
    organic.dissolved_acetate_carbon_g_c[2] = 0.5;
    const before_c: f64 = 17;
    const before_n: f64 = 1.15;
    const before_p: f64 = 0.135;
    const before_carbon_0 = organic.dissolved[0].carbon_g_c;
    const before_carbon_2 = organic.dissolved[2].carbon_g_c;
    const before_acetate_0 = organic.dissolved_acetate_carbon_g_c[0];
    const before_acetate_2 = organic.dissolved_acetate_carbon_g_c[2];
    const acetate_ratio_0 = before_acetate_0 / before_carbon_0;
    const acetate_ratio_2 = before_acetate_2 / before_carbon_2;

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, .{});

    const after_c = organic.dissolved[0].carbon_g_c + organic.dissolved[2].carbon_g_c;
    const after_n = organic.dissolved[0].nitrogen_g_n + organic.dissolved[2].nitrogen_g_n;
    const after_p = organic.dissolved[0].phosphorus_g_p + organic.dissolved[2].phosphorus_g_p;
    try std.testing.expectApproxEqAbs(before_c, after_c + result.combusted_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(before_n, after_n + result.combusted_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(before_p, after_p + result.combusted_phosphorus_g_p, 1e-12);
    const burned_carbon_0 = before_carbon_0 - organic.dissolved[0].carbon_g_c;
    const burned_carbon_2 = before_carbon_2 - organic.dissolved[2].carbon_g_c;
    const burned_acetate_0 = before_acetate_0 - organic.dissolved_acetate_carbon_g_c[0];
    const burned_acetate_2 = before_acetate_2 - organic.dissolved_acetate_carbon_g_c[2];
    try std.testing.expectApproxEqAbs(acetate_ratio_0, burned_acetate_0 / burned_carbon_0, 1e-14);
    try std.testing.expectApproxEqAbs(acetate_ratio_2, burned_acetate_2 / burned_carbon_2, 1e-14);
    inline for (.{ organic.dissolved[0].carbon_g_c, organic.dissolved[0].nitrogen_g_n, organic.dissolved[0].phosphorus_g_p, organic.dissolved_acetate_carbon_g_c[0], organic.dissolved[2].carbon_g_c, organic.dissolved[2].nitrogen_g_n, organic.dissolved[2].phosphorus_g_p, organic.dissolved_acetate_carbon_g_c[2] }) |remaining|
        try std.testing.expect(std.math.isFinite(remaining) and remaining >= 0);
    try std.testing.expectApproxEqAbs(result.combusted_carbon_g_c, fire_exchange.unlimited_combustion_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_nitrogen_g_n, fire_exchange.combusted_nitrogen_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_phosphorus_g_p, fire_exchange.combusted_phosphorus_g_p[0], 1e-12);
}

test "NITRO dissolved organic fire applies OQC ZEROS gate to associated OQA" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.dissolved[0] = .{ .carbon_g_c = 1e-10, .nitrogen_g_n = 1e-11, .phosphorus_g_p = 1e-12 };
    organic.dissolved_acetate_carbon_g_c[0] = 5e-11;
    var parameters: combustion_module.Parameters = .{};
    parameters.negligible_carbon_g_c = 1e-10;

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, parameters);

    try std.testing.expectEqual(@as(f64, 1e-10), organic.dissolved[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1e-11), organic.dissolved[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1e-12), organic.dissolved[0].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 5e-11), organic.dissolved_acetate_carbon_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), result.combusted_carbon_g_c);
}

test "NITRO 4445-4486 adsorbed organic fire conserves C N P and acetate fraction" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.adsorbed[1] = .{ .carbon_g_c = 9, .nitrogen_g_n = 0.72, .phosphorus_g_p = 0.09 };
    organic.adsorbed_acetate_carbon_g_c[1] = 1.8;
    organic.adsorbed[4] = .{ .carbon_g_c = 7, .nitrogen_g_n = 0.35, .phosphorus_g_p = 0.021 };
    organic.adsorbed_acetate_carbon_g_c[4] = 0.7;
    const before_c: f64 = 16;
    const before_n: f64 = 1.07;
    const before_p: f64 = 0.111;
    const before_carbon_1 = organic.adsorbed[1].carbon_g_c;
    const before_carbon_4 = organic.adsorbed[4].carbon_g_c;
    const before_acetate_1 = organic.adsorbed_acetate_carbon_g_c[1];
    const before_acetate_4 = organic.adsorbed_acetate_carbon_g_c[4];

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, .{});

    const after_c = organic.adsorbed[1].carbon_g_c + organic.adsorbed[4].carbon_g_c;
    const after_n = organic.adsorbed[1].nitrogen_g_n + organic.adsorbed[4].nitrogen_g_n;
    const after_p = organic.adsorbed[1].phosphorus_g_p + organic.adsorbed[4].phosphorus_g_p;
    try std.testing.expectApproxEqAbs(before_c, after_c + result.combusted_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(before_n, after_n + result.combusted_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(before_p, after_p + result.combusted_phosphorus_g_p, 1e-12);
    const burned_carbon_1 = before_carbon_1 - organic.adsorbed[1].carbon_g_c;
    const burned_carbon_4 = before_carbon_4 - organic.adsorbed[4].carbon_g_c;
    const burned_acetate_1 = before_acetate_1 - organic.adsorbed_acetate_carbon_g_c[1];
    const burned_acetate_4 = before_acetate_4 - organic.adsorbed_acetate_carbon_g_c[4];
    try std.testing.expectApproxEqAbs(before_acetate_1 / before_carbon_1, burned_acetate_1 / burned_carbon_1, 1e-14);
    try std.testing.expectApproxEqAbs(before_acetate_4 / before_carbon_4, burned_acetate_4 / burned_carbon_4, 1e-14);
    inline for (.{ organic.adsorbed[1].carbon_g_c, organic.adsorbed[1].nitrogen_g_n, organic.adsorbed[1].phosphorus_g_p, organic.adsorbed_acetate_carbon_g_c[1], organic.adsorbed[4].carbon_g_c, organic.adsorbed[4].nitrogen_g_n, organic.adsorbed[4].phosphorus_g_p, organic.adsorbed_acetate_carbon_g_c[4] }) |remaining|
        try std.testing.expect(std.math.isFinite(remaining) and remaining >= 0);
    try std.testing.expectApproxEqAbs(result.combusted_carbon_g_c, fire_exchange.unlimited_combustion_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_nitrogen_g_n, fire_exchange.combusted_nitrogen_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_phosphorus_g_p, fire_exchange.combusted_phosphorus_g_p[0], 1e-12);
}

test "NITRO adsorbed organic fire applies OHC ZEROS gate to associated OHA" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.adsorbed[0] = .{ .carbon_g_c = 1e-10, .nitrogen_g_n = 1e-11, .phosphorus_g_p = 1e-12 };
    organic.adsorbed_acetate_carbon_g_c[0] = 4e-11;
    var parameters: combustion_module.Parameters = .{};
    parameters.negligible_carbon_g_c = 1e-10;

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, parameters);

    try std.testing.expectEqual(@as(f64, 1e-10), organic.adsorbed[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1e-11), organic.adsorbed[0].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1e-12), organic.adsorbed[0].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 4e-11), organic.adsorbed_acetate_carbon_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), result.combusted_carbon_g_c);
}

test "NITRO 4488-4537 structural SOM fire conserves C N P and colonized carbon fraction" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    const structural_index_0 = 1;
    const structural_index_3 = 3 * SoilOrganic.structural_fraction_count + 2;
    organic.structural[structural_index_0] = .{ .carbon_g_c = 14, .nitrogen_g_n = 1.12, .phosphorus_g_p = 0.14 };
    organic.colonized_structural_carbon_g_c[structural_index_0] = 3.5;
    organic.structural[structural_index_3] = .{ .carbon_g_c = 6, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.018 };
    organic.colonized_structural_carbon_g_c[structural_index_3] = 0.6;
    const before_c: f64 = 20;
    const before_n: f64 = 1.42;
    const before_p: f64 = 0.158;
    const before_carbon_0 = organic.structural[structural_index_0].carbon_g_c;
    const before_carbon_3 = organic.structural[structural_index_3].carbon_g_c;
    const before_colonized_0 = organic.colonized_structural_carbon_g_c[structural_index_0];
    const before_colonized_3 = organic.colonized_structural_carbon_g_c[structural_index_3];

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, .{});

    const after_c = organic.structural[structural_index_0].carbon_g_c + organic.structural[structural_index_3].carbon_g_c;
    const after_n = organic.structural[structural_index_0].nitrogen_g_n + organic.structural[structural_index_3].nitrogen_g_n;
    const after_p = organic.structural[structural_index_0].phosphorus_g_p + organic.structural[structural_index_3].phosphorus_g_p;
    try std.testing.expectApproxEqAbs(before_c, after_c + result.combusted_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(before_n, after_n + result.combusted_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(before_p, after_p + result.combusted_phosphorus_g_p, 1e-12);
    const burned_carbon_0 = before_carbon_0 - organic.structural[structural_index_0].carbon_g_c;
    const burned_carbon_3 = before_carbon_3 - organic.structural[structural_index_3].carbon_g_c;
    const burned_colonized_0 = before_colonized_0 - organic.colonized_structural_carbon_g_c[structural_index_0];
    const burned_colonized_3 = before_colonized_3 - organic.colonized_structural_carbon_g_c[structural_index_3];
    try std.testing.expectApproxEqAbs(before_colonized_0 / before_carbon_0, burned_colonized_0 / burned_carbon_0, 1e-14);
    try std.testing.expectApproxEqAbs(before_colonized_3 / before_carbon_3, burned_colonized_3 / burned_carbon_3, 1e-14);
    inline for (.{ organic.structural[structural_index_0].carbon_g_c, organic.structural[structural_index_0].nitrogen_g_n, organic.structural[structural_index_0].phosphorus_g_p, organic.colonized_structural_carbon_g_c[structural_index_0], organic.structural[structural_index_3].carbon_g_c, organic.structural[structural_index_3].nitrogen_g_n, organic.structural[structural_index_3].phosphorus_g_p, organic.colonized_structural_carbon_g_c[structural_index_3] }) |remaining|
        try std.testing.expect(std.math.isFinite(remaining) and remaining >= 0);
    try std.testing.expectApproxEqAbs(result.combusted_carbon_g_c, fire_exchange.unlimited_combustion_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_nitrogen_g_n, fire_exchange.combusted_nitrogen_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_phosphorus_g_p, fire_exchange.combusted_phosphorus_g_p[0], 1e-12);
}

test "NITRO structural SOM fire applies OSC ZEROS gate to OSA" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.structural[0] = .{ .carbon_g_c = 1e-10, .nitrogen_g_n = 1e-11, .phosphorus_g_p = 1e-12 };
    organic.colonized_structural_carbon_g_c[0] = 4e-11;
    var parameters: combustion_module.Parameters = .{};
    parameters.negligible_carbon_g_c = 1e-10;

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, parameters);

    try std.testing.expectEqual(@as(f64, 1e-10), organic.structural[0].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 4e-11), organic.colonized_structural_carbon_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), result.combusted_carbon_g_c);
}

test "NITRO structural SOM fire rolls back before non-finite OSA ratio state_update" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.structural[0] = .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.02 };
    organic.colonized_structural_carbon_g_c[0] = std.math.floatMax(f64);
    const pool_before = organic.structural[0];
    const colonized_before = organic.colonized_structural_carbon_g_c[0];

    try std.testing.expectError(
        error.NonFiniteCombustionPool,
        combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, .{}),
    );

    try std.testing.expectEqual(pool_before.carbon_g_c, organic.structural[0].carbon_g_c);
    try std.testing.expectEqual(pool_before.nitrogen_g_n, organic.structural[0].nitrogen_g_n);
    try std.testing.expectEqual(pool_before.phosphorus_g_p, organic.structural[0].phosphorus_g_p);
    try std.testing.expectEqual(colonized_before, organic.colonized_structural_carbon_g_c[0]);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.unlimited_combustion_carbon_g_c[0]);
}

test "NITRO 4539-4586 charcoal fire conserves C N P and colonized carbon fraction" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    const charcoal_0 = SoilOrganic.structural_fraction_count - 1;
    const charcoal_2 = 2 * SoilOrganic.structural_fraction_count + SoilOrganic.structural_fraction_count - 1;
    organic.structural[charcoal_0] = .{ .carbon_g_c = 8, .nitrogen_g_n = 0.64, .phosphorus_g_p = 0.08 };
    organic.colonized_structural_carbon_g_c[charcoal_0] = 2;
    organic.structural[charcoal_2] = .{ .carbon_g_c = 12, .nitrogen_g_n = 0.6, .phosphorus_g_p = 0.036 };
    organic.colonized_structural_carbon_g_c[charcoal_2] = 1.2;
    const before_c: f64 = 20;
    const before_n: f64 = 1.24;
    const before_p: f64 = 0.116;
    const before_colonized_0 = organic.colonized_structural_carbon_g_c[charcoal_0];
    const before_colonized_2 = organic.colonized_structural_carbon_g_c[charcoal_2];

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, .{});

    const after_c = organic.structural[charcoal_0].carbon_g_c + organic.structural[charcoal_2].carbon_g_c;
    const after_n = organic.structural[charcoal_0].nitrogen_g_n + organic.structural[charcoal_2].nitrogen_g_n;
    const after_p = organic.structural[charcoal_0].phosphorus_g_p + organic.structural[charcoal_2].phosphorus_g_p;
    try std.testing.expectApproxEqAbs(before_c, after_c + result.combusted_carbon_g_c, 1e-12);
    try std.testing.expectApproxEqAbs(before_n, after_n + result.combusted_nitrogen_g_n, 1e-12);
    try std.testing.expectApproxEqAbs(before_p, after_p + result.combusted_phosphorus_g_p, 1e-12);
    const burned_carbon_0 = 8 - organic.structural[charcoal_0].carbon_g_c;
    const burned_carbon_2 = 12 - organic.structural[charcoal_2].carbon_g_c;
    const burned_colonized_0 = before_colonized_0 - organic.colonized_structural_carbon_g_c[charcoal_0];
    const burned_colonized_2 = before_colonized_2 - organic.colonized_structural_carbon_g_c[charcoal_2];
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 8.0), burned_colonized_0 / burned_carbon_0, 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2 / 12.0), burned_colonized_2 / burned_carbon_2, 1e-14);
    inline for (.{ organic.structural[charcoal_0].carbon_g_c, organic.structural[charcoal_0].nitrogen_g_n, organic.structural[charcoal_0].phosphorus_g_p, organic.colonized_structural_carbon_g_c[charcoal_0], organic.structural[charcoal_2].carbon_g_c, organic.structural[charcoal_2].nitrogen_g_n, organic.structural[charcoal_2].phosphorus_g_p, organic.colonized_structural_carbon_g_c[charcoal_2] }) |remaining|
        try std.testing.expect(std.math.isFinite(remaining) and remaining >= 0);
    try std.testing.expectApproxEqAbs(result.combusted_carbon_g_c, fire_exchange.unlimited_combustion_carbon_g_c[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_nitrogen_g_n, fire_exchange.combusted_nitrogen_g_n[0], 1e-12);
    try std.testing.expectApproxEqAbs(result.combusted_phosphorus_g_p, fire_exchange.combusted_phosphorus_g_p[0], 1e-12);
}

test "NITRO ORGC regular fraction denominator excludes ORGCC charcoal" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.structural[0].carbon_g_c = 10;
    organic.structural[SoilOrganic.structural_fraction_count - 1].carbon_g_c = 90;
    var parameters: combustion_module.Parameters = .{};
    parameters.specific_combustion_by_substrate_g_c_per_m2_h = @splat(1);
    const response = @min(
        parameters.maximum_arrhenius_response,
        @exp(parameters.arrhenius_intercept -
            parameters.activation_energy_j_per_mol /
                (parameters.gas_constant_j_per_mol_k * 700)),
    );

    const result = try combustion_module.burnOrganicStateLayer(
        &organic,
        &fire_exchange,
        0,
        true,
        700,
        1,
        1,
        parameters,
    );

    try std.testing.expectApproxEqAbs(
        @min(1, response / 10),
        result.combustion_fraction,
        1e-15,
    );
}

test "NITRO charcoal combustion proceeds when regular ORGC is zero" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    organic.structural[SoilOrganic.structural_fraction_count - 1] = .{
        .carbon_g_c = 10,
        .nitrogen_g_n = 1,
        .phosphorus_g_p = 0.1,
    };

    const result = try combustion_module.burnOrganicStateLayer(
        &organic,
        &fire_exchange,
        0,
        true,
        700,
        1,
        1,
        .{},
    );

    try std.testing.expectEqual(@as(f64, 0), result.combustion_fraction);
    try std.testing.expect(result.combusted_carbon_g_c > 0);
}

test "NITRO charcoal fire applies ORGCC and OSC ZEROS gates" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    const charcoal_index = SoilOrganic.structural_fraction_count - 1;
    organic.structural[charcoal_index] = .{ .carbon_g_c = 1e-10, .nitrogen_g_n = 1e-11, .phosphorus_g_p = 1e-12 };
    organic.colonized_structural_carbon_g_c[charcoal_index] = 3e-11;
    var parameters: combustion_module.Parameters = .{};
    parameters.negligible_carbon_g_c = 1e-10;

    const result = try combustion_module.burnOrganicStateLayer(&organic, &fire_exchange, 0, true, 700, 1, 1, parameters);

    try std.testing.expectEqual(@as(f64, 1e-10), organic.structural[charcoal_index].carbon_g_c);
    try std.testing.expectEqual(@as(f64, 1e-11), organic.structural[charcoal_index].nitrogen_g_n);
    try std.testing.expectEqual(@as(f64, 1e-12), organic.structural[charcoal_index].phosphorus_g_p);
    try std.testing.expectEqual(@as(f64, 3e-11), organic.colonized_structural_carbon_g_c[charcoal_index]);
    try std.testing.expectEqual(@as(f64, 0), result.combusted_carbon_g_c);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.unlimited_combustion_carbon_g_c[0]);
}

test "NITRO surface fire excludes microbial substrates K3 and K4" {
    var organic = try SoilOrganic.State.init(std.testing.allocator, 1);
    defer organic.deinit();
    var fire_exchange = try FireExchange.State.init(std.testing.allocator, 1, SoilOrganic.microbial_substrate_count);
    defer fire_exchange.deinit();
    const stride = SoilOrganic.microbial_population_count * SoilOrganic.kinetic_fraction_count;
    for (0..SoilOrganic.microbial_substrate_count) |substrate| {
        organic.microbial[substrate * stride] = .{ .carbon_g_c = 10, .nitrogen_g_n = 1, .phosphorus_g_p = 0.1 };
    }
    var parameters: combustion_module.Parameters = .{};
    parameters.minimum_combustion_temperature_k = 300;
    _ = try combustion_module.burnSurfaceOrganicStateCell(&organic, &fire_exchange, 0, true, 700, 1, 1, parameters);
    for (0..SoilOrganic.microbial_substrate_count) |substrate| {
        const remaining = organic.microbial[substrate * stride].carbon_g_c;
        if (substrate == 3 or substrate == 4)
            try std.testing.expectEqual(@as(f64, 10), remaining)
        else
            try std.testing.expect(remaining < 10);
    }
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.combusted_carbon_by_substrate_g_c[3]);
    try std.testing.expectEqual(@as(f64, 0), fire_exchange.combusted_carbon_by_substrate_g_c[4]);
}

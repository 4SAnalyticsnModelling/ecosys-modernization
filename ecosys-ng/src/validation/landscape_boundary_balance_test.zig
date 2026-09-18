//! Tests for `landscape_boundary_balance.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const audit = @import("mass_balance_audit.zig");
const gas = @import("../soil/gas/transport.zig");
const soil_daily_gas = @import("../soil/diagnostics/daily_gas_flux.zig");
const canopy_daily_gas = @import("../canopy/gas/daily_exchange.zig");
const atmospheric_solutes = @import("../atmosphere/atmospheric_solute_inputs.zig");
const snow = @import("../soil/solute/snow_solute_transport.zig");
const snow_discharge = @import("../soil/water/snow_surface_discharge.zig");
const inventory = @import("landscape_mass_inventory.zig");
const ledger_module = @import("landscape_boundary_balance.zig");
const hourly = @import("hourly_cell_conservation.zig");
const symbiosis = @import("../canopy/symbiosis/plant_symbiotic_fixation.zig");

const precipitation_heat_parameters: ledger_module.PrecipitationHeatParameters = .{
    .snow_latent_heat_of_fusion_megajoules_per_m3 = 333,
    .solid_snow_heat_capacity_megajoules_per_m3_k = 2.095,
    .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19,
    .pure_water_melting_temperature_k = 273.15,
};

test "accepted landscape boundary transactions publish every EXEC ledger" {
    var state: ledger_module.State = .{};
    var first = std.mem.zeroes(ledger_module.Fluxes);
    inline for (std.meta.fields(ledger_module.Fluxes), 0..) |field, index|
        @field(first, field.name) = @floatFromInt(index + 1);
    try state.accumulateAccepted(first);
    try state.accumulateAccepted(first);

    var totals = std.mem.zeroes(audit.Totals);
    totals.landscape_area_m2 = 99;
    totals.water_storage_m3 = 77;
    try state.publish(&totals);
    try std.testing.expectEqual(@as(f64, 6), totals.cumulative_rain_m3);
    try std.testing.expectEqual(@as(f64, 2) * first.ion_output_mol, totals.cumulative_ion_output_mol);
    try std.testing.expectEqual(@as(f64, 99), totals.landscape_area_m2);
    try std.testing.expectEqual(@as(f64, 77), totals.water_storage_m3);
}

test "accepted WTNDI inoculum publishes exact cell and domain C N P once" {
    var state: ledger_module.State = .{};
    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 2);
    defer cell_ledger.deinit();
    var inputs = [_]symbiosis.Pool{
        .{ .carbon_g_c = 2, .nitrogen_g_n = 0.2, .phosphorus_g_p = 0.04 },
        .{ .carbon_g_c = 3, .nitrogen_g_n = 0.3, .phosphorus_g_p = 0.06 },
    };
    try state.accumulateAcceptedSymbioticInoculum(&cell_ledger, &inputs);
    try std.testing.expectEqual(@as(f64, 2), cell_ledger.cells[0].carbon_input_g);
    try std.testing.expectEqual(@as(f64, 0.3), cell_ledger.cells[1].nitrogen_input_g);
    try std.testing.expectEqual(@as(f64, 0.06), cell_ledger.cells[1].phosphorus_input_g);
    try std.testing.expectEqual(@as(f64, 5), state.cumulative.symbiotic_inoculum_carbon_input_g_c);
    try std.testing.expectEqual(@as(f64, 0.5), state.cumulative.symbiotic_inoculum_nitrogen_input_g_n);
    try std.testing.expectEqual(@as(f64, 0.1), state.cumulative.symbiotic_inoculum_phosphorus_input_g_p);
    try std.testing.expectEqualDeep(
        [_]symbiosis.Pool{
            .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
            .{ .carbon_g_c = 0, .nitrogen_g_n = 0, .phosphorus_g_p = 0 },
        },
        inputs,
    );

    // Consumed activity cannot be double-counted by a repeated publisher.
    try state.accumulateAcceptedSymbioticInoculum(&cell_ledger, &inputs);
    try std.testing.expectEqual(@as(f64, 5), state.cumulative.symbiotic_inoculum_carbon_input_g_c);
    try std.testing.expectEqual(@as(f64, 2), cell_ledger.cells[0].carbon_input_g);

    var totals = std.mem.zeroes(audit.Totals);
    totals.landscape_area_m2 = 1;
    totals.plant_carbon_g = 5;
    totals.plant_nitrogen_g = 0.5;
    totals.plant_phosphorus_g = 0.1;
    try state.publish(&totals);
    const closed = try audit.balance(totals);
    try std.testing.expectEqual(@as(f64, 0), closed.carbon_g);
    try std.testing.expectEqual(@as(f64, 0), closed.nitrogen_g);
    try std.testing.expectEqual(@as(f64, 0), closed.phosphorus_g);
}

test "invalid WTNDI activity leaves cell domain and source buffers unchanged" {
    var state: ledger_module.State = .{};
    var cell_ledger = try hourly.BoundaryLedger.init(std.testing.allocator, 1);
    defer cell_ledger.deinit();
    var inputs = [_]symbiosis.Pool{.{
        .carbon_g_c = 1,
        .nitrogen_g_n = std.math.nan(f64),
        .phosphorus_g_p = 0.02,
    }};
    const before_state = state;
    const before_cell = cell_ledger.cells[0];
    try std.testing.expectError(
        error.InvalidSymbioticExternalInput,
        state.accumulateAcceptedSymbioticInoculum(&cell_ledger, &inputs),
    );
    try std.testing.expectEqualDeep(before_state, state);
    try std.testing.expectEqualDeep(before_cell, cell_ledger.cells[0]);
    try std.testing.expect(std.math.isNan(inputs[0].nitrogen_g_n));
}

test "root soil and aqueous oxygen uptake reaches EXEC internal consumption atomically" {
    var state: ledger_module.State = .{};
    try state.accumulateAccepted(.{ .oxygen_output_g = 5 });
    try state.accumulateAcceptedRootOxygenUptake(
        &.{ 1, 2 },
        &.{ 0.25, 0.75 },
    );
    try std.testing.expectEqual(@as(f64, 5), state.cumulative.oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 4), state.cumulative_internal.oxygen_consumption_g_o);

    // A valid zero-activity hour is a no-op, not an absent producer.
    try state.accumulateAcceptedRootOxygenUptake(&.{ 0, 0 }, &.{ 0, 0 });
    try std.testing.expectEqual(@as(f64, 5), state.cumulative.oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 4), state.cumulative_internal.oxygen_consumption_g_o);

    const before = state.cumulative;
    const before_internal = state.cumulative_internal;
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedRootOxygenUptake(
            &.{ 1, 2 },
            &.{ 3, std.math.nan(f64) },
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
    try std.testing.expectEqualDeep(before_internal, state.cumulative_internal);
    try std.testing.expectError(
        error.LandscapeBoundaryGridDimensionMismatch,
        state.accumulateAcceptedRootOxygenUptake(&.{ 1, 2 }, &.{1}),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
    try std.testing.expectError(
        error.EmptyLandscapeBoundaryGrid,
        state.accumulateAcceptedRootOxygenUptake(&.{}, &.{}),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
}

test "dissolved external gas faces preserve active O2 and H2 directions" {
    var state: ledger_module.State = .{};
    var boundary = [_]f64{0} ** (3 * gas.species_count);
    boundary[@intFromEnum(gas.Species.oxygen)] = 3;
    boundary[@intFromEnum(gas.Species.hydrogen)] = -4;
    // Inactive capacity must not contribute even when it contains stale data.
    boundary[gas.species_count + @intFromEnum(gas.Species.oxygen)] = 500;
    boundary[gas.species_count + @intFromEnum(gas.Species.hydrogen)] = -600;
    boundary[2 * gas.species_count + @intFromEnum(gas.Species.oxygen)] = -2;
    boundary[2 * gas.species_count + @intFromEnum(gas.Species.hydrogen)] = 1;
    try state.accumulateAcceptedDissolvedGasExternalBoundaries(
        &.{ true, false, true },
        &boundary,
    );
    try std.testing.expectEqual(@as(f64, 3), state.cumulative.oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 2), state.cumulative.oxygen_output_g);
    try std.testing.expectEqual(@as(f64, 1), state.cumulative.hydrogen_input_g);
    try std.testing.expectEqual(@as(f64, 4), state.cumulative.hydrogen_output_g);

    const before = state;
    boundary[2 * gas.species_count + @intFromEnum(gas.Species.oxygen)] =
        std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedDissolvedGasExternalBoundaries(
            &.{ true, false, true },
            &boundary,
        ),
    );
    try std.testing.expectEqualDeep(before, state);
    try std.testing.expectError(
        error.LandscapeBoundaryGridDimensionMismatch,
        state.accumulateAcceptedDissolvedGasExternalBoundaries(&.{true}, &.{}),
    );
}

test "surface microbial and active fire oxygen sinks agree at cell and landscape scales" {
    var state: ledger_module.State = .{};
    var cells = try hourly.BoundaryLedger.init(std.testing.allocator, 2);
    defer cells.deinit();

    const microbial = [_]f64{ 0.5, 1.5, 5, 15 };
    const surface_fire = [_]f64{ 2, 20 };
    // Cell 0 has one active layer; 700 is inactive capacity and must not enter
    // either cell or landscape output. Cell 1 has both layers active.
    const subsurface_fire = [_]f64{ 7, 700, 70, 80 };
    try hourly.accumulateSurfaceMicrobialAndFireOxygenUptake(
        &cells,
        2,
        &microbial,
        &surface_fire,
    );
    for (0..2) |cell| {
        const uptake = try hourly.soilFireOxygenConsumptionForCell(
            &subsurface_fire,
            cell,
            (&[_]usize{ 1, 2 })[cell],
            2,
        );
        try cells.accumulate(cell, .{
            .oxygen_internal_consumption_g = uptake,
        });
    }
    try state.accumulateAcceptedSurfaceMicrobialAndFireOxygenUptake(
        &.{ 1, 2 },
        2,
        2,
        &microbial,
        &surface_fire,
        &subsurface_fire,
    );
    const cell_total = cells.cells[0].oxygen_internal_consumption_g +
        cells.cells[1].oxygen_internal_consumption_g;
    try std.testing.expectEqual(@as(f64, 201), cell_total);
    try std.testing.expectEqual(cell_total, state.cumulative_internal.oxygen_consumption_g_o);
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.oxygen_output_g);

    // A valid no-reaction hour is an exact no-op.
    try state.accumulateAcceptedSurfaceMicrobialAndFireOxygenUptake(
        &.{ 0, 0 },
        2,
        2,
        &.{ 0, 0, 0, 0 },
        &.{ 0, 0 },
        &.{ 0, 99, 0, 88 },
    );
    try std.testing.expectEqual(cell_total, state.cumulative_internal.oxygen_consumption_g_o);

    const before = state.cumulative;
    const before_internal = state.cumulative_internal;
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedSurfaceMicrobialAndFireOxygenUptake(
            &.{ 1, 2 },
            2,
            2,
            &.{ 0, std.math.nan(f64), 0, 0 },
            &.{ 0, 0 },
            &.{ 0, 0, 0, 0 },
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
    try std.testing.expectEqualDeep(before_internal, state.cumulative_internal);
    try std.testing.expectError(
        error.NegativeLandscapeBoundaryFlux,
        state.accumulateAcceptedSurfaceMicrobialAndFireOxygenUptake(
            &.{ 1, 2 },
            2,
            2,
            &.{ 0, 0, 0, 0 },
            &.{ 0, 0 },
            &.{ -1, 0, 0, 0 },
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
    try std.testing.expectError(
        error.LandscapeBoundaryGridDimensionMismatch,
        state.accumulateAcceptedSurfaceMicrobialAndFireOxygenUptake(
            &.{ 3, 2 },
            2,
            2,
            &.{ 0, 0, 0, 0 },
            &.{ 0, 0 },
            &.{ 0, 0, 0, 0 },
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
}

test "delayed fire and root heat agree at cell and landscape scales atomically" {
    var state: ledger_module.State = .{};
    var cells = try hourly.BoundaryLedger.init(std.testing.allocator, 2);
    defer cells.deinit();

    const surface_fire = [_]f64{ 2, 20 };
    const subsurface_fire = [_]f64{ 7, 700, 70, 80 };
    // Root heat retains REDIST's sign. Cell 0 layer 1 is inactive, so its
    // deliberately large padding value must not reach either scale.
    const root_heat = [_]f64{ -1, 800, 3, -4 };
    try cells.accumulateSignedInternalHeat(&surface_fire);
    try state.accumulateAcceptedSurfaceCombustionHeat(&surface_fire);
    try hourly.accumulateSubsurfaceCombustionAndRootHeat(
        &cells,
        &.{ 1, 2 },
        2,
        &subsurface_fire,
        &root_heat,
    );
    try state.accumulateAcceptedSubsurfaceCombustionAndRootHeat(
        &.{ 1, 2 },
        2,
        &subsurface_fire,
        &root_heat,
    );
    try std.testing.expectEqual(@as(f64, 9), cells.cells[0].heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 1), cells.cells[0].heat_internal_consumption_megajoules);
    try std.testing.expectEqual(@as(f64, 173), cells.cells[1].heat_internal_production_megajoules);
    try std.testing.expectEqual(@as(f64, 4), cells.cells[1].heat_internal_consumption_megajoules);
    try std.testing.expectEqual(
        cells.cells[0].heat_internal_production_megajoules + cells.cells[1].heat_internal_production_megajoules,
        state.cumulative_internal.heat_production_megajoules,
    );
    try std.testing.expectEqual(
        cells.cells[0].heat_internal_consumption_megajoules + cells.cells[1].heat_internal_consumption_megajoules,
        state.cumulative_internal.heat_consumption_megajoules,
    );

    // Valid zero activity is a no-op, and inactive padding remains excluded.
    try state.accumulateAcceptedSurfaceCombustionHeat(&.{ 0, 0 });
    try state.accumulateAcceptedSubsurfaceCombustionAndRootHeat(
        &.{ 0, 0 },
        2,
        &.{ 99, 98, 97, 96 },
        &.{ std.math.nan(f64), 95, 94, 93 },
    );
    try std.testing.expectEqual(@as(f64, 182), state.cumulative_internal.heat_production_megajoules);
    try std.testing.expectEqual(@as(f64, 5), state.cumulative_internal.heat_consumption_megajoules);

    const landscape_before = state;
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedSurfaceCombustionHeat(&.{ 0, std.math.nan(f64) }),
    );
    try std.testing.expectEqualDeep(landscape_before, state);
    try std.testing.expectError(
        error.NegativeLandscapeBoundaryFlux,
        state.accumulateAcceptedSubsurfaceCombustionAndRootHeat(
            &.{ 1, 2 },
            2,
            &.{ 0, 0, -1, 0 },
            &.{ 0, 0, 0, 0 },
        ),
    );
    try std.testing.expectEqualDeep(landscape_before, state);
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedSubsurfaceCombustionAndRootHeat(
            &.{ 1, 2 },
            2,
            &.{ 0, 0, 0, 0 },
            &.{ 0, 0, 0, std.math.nan(f64) },
        ),
    );
    try std.testing.expectEqualDeep(landscape_before, state);

    const cells_before = [_]hourly.BoundaryActivity{ cells.cells[0], cells.cells[1] };
    try std.testing.expectError(
        error.InvalidHourlyCellBoundaryActivity,
        hourly.accumulateSubsurfaceCombustionAndRootHeat(
            &cells,
            &.{ 1, 2 },
            2,
            &.{ 0, 0, 0, 0 },
            &.{ 0, 0, 0, std.math.inf(f64) },
        ),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, &cells_before, cells.cells);
    try std.testing.expectError(
        error.HourlyCellBoundaryDimensionMismatch,
        hourly.accumulateSubsurfaceCombustionAndRootHeat(
            &cells,
            &.{ 3, 2 },
            2,
            &.{ 0, 0, 0, 0 },
            &.{ 0, 0, 0, 0 },
        ),
    );
    try std.testing.expectEqualSlices(hourly.BoundaryActivity, &cells_before, cells.cells);
}

test "domain heat and oxygen transformation directions publish atomically" {
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedHeatTransformationTotals(9, 2);
    try state.accumulateAcceptedOxygenTransformationTotals(20, 8);
    var totals = std.mem.zeroes(@import("mass_balance_audit.zig").Totals);
    totals.landscape_area_m2 = 1;
    try state.publish(&totals);
    try std.testing.expectEqual(@as(f64, 9), totals.cumulative_internal_heat_production_megajoules);
    try std.testing.expectEqual(@as(f64, 2), totals.cumulative_internal_heat_consumption_megajoules);
    try std.testing.expectEqual(@as(f64, 20), totals.cumulative_internal_oxygen_production_g);
    try std.testing.expectEqual(@as(f64, 8), totals.cumulative_internal_oxygen_consumption_g);

    const before = state;
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedHeatTransformationTotals(1, std.math.nan(f64)),
    );
    try std.testing.expectEqualDeep(before, state);
    state.cumulative_internal.oxygen_production_g_o = std.math.floatMax(f64);
    const overflow_before = state;
    try std.testing.expectError(
        error.LandscapeBoundaryLedgerOverflow,
        state.accumulateAcceptedOxygenTransformationTotals(std.math.floatMax(f64), 1),
    );
    try std.testing.expectEqualDeep(overflow_before, state);
}

test "invalid boundary transaction cannot partially advance cumulative state" {
    var state: ledger_module.State = .{};
    try state.accumulateAccepted(.{ .rain_m3 = 3, .nitrogen_input_g_n = 4 });
    const before = state.cumulative;
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAccepted(.{
            .rain_m3 = 5,
            .phosphorus_output_g_p = std.math.nan(f64),
        }),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
}

test "mineral fertilizer carbon boundary rejects invalid publication atomically" {
    var state: ledger_module.State = .{};
    try state.accumulateAccepted(.{ .mineral_fertilizer_carbon_g_c = 108 });
    const before = state;
    for ([_]f64{ -1, std.math.nan(f64), std.math.inf(f64) }) |invalid| {
        if (state.accumulateAccepted(.{ .mineral_fertilizer_carbon_g_c = invalid })) |_| {
            return error.ExpectedInvalidMineralCarbonRejection;
        } else |_| {}
        try std.testing.expectEqualDeep(before, state);
    }
    try state.accumulateAccepted(.{ .mineral_fertilizer_carbon_g_c = std.math.floatMax(f64) });
    const before_overflow = state;
    try std.testing.expectError(error.LandscapeBoundaryLedgerOverflow, state.accumulateAccepted(.{ .mineral_fertilizer_carbon_g_c = std.math.floatMax(f64) }));
    try std.testing.expectEqualDeep(before_overflow, state);
}

test "accepted runtime grid ledgers aggregate water fertilizer and exports" {
    var state: ledger_module.State = .{};
    const first = [_]f64{ 1, 2 };
    const second = [_]f64{ 3, 4 };
    const third = [_]f64{ 5, 6 };
    const fourth = [_]f64{ 7, 8 };
    try state.accumulateAcceptedWater(
        &first,
        &second,
        &third,
        &fourth,
        &first,
        &second,
    );
    try state.accumulateAcceptedFertilizer(
        &first,
        &second,
        &third,
        &fourth,
        &first,
    );
    try std.testing.expectEqual(@as(f64, 3), state.cumulative.organic_fertilizer_carbon_g_c);
    try state.accumulateAcceptedExports(
        .{ &first, &second, &third, &fourth },
        .{ &first, &second, &third, &fourth },
        .{ &first, &second, &third, &fourth },
        &second,
    );
    try state.accumulateAcceptedIonTransportInputs(&third);
    try state.accumulateAcceptedPlantLitter(&first, &second, &third);
    try std.testing.expectEqual(@as(f64, 3), state.cumulative.rain_m3);
    try std.testing.expectEqual(@as(f64, 7), state.cumulative.boundary_water_inflow_m3);
    try std.testing.expectEqual(
        @as(f64, 36),
        state.cumulative.carbon_output_g_c,
    );
    try std.testing.expectEqual(
        @as(f64, 7),
        state.cumulative.ion_output_mol,
    );
    try std.testing.expectEqual(
        @as(f64, 11),
        state.cumulative.ion_input_mol,
    );
    try std.testing.expectEqual(
        @as(f64, 3),
        state.cumulative.carbon_sink_g_c,
    );
}

test "precipitation heat counts raw liquid and snow once across runtime cells" {
    var state: ledger_module.State = .{};
    var heat_by_cell: [2]f64 = undefined;
    try state.accumulateAcceptedPrecipitationHeat(
        &.{ 0.001, 0.002 },
        &.{ 0.003, 0.004 },
        &.{ 10, 20 },
        &.{ 280, 285 },
        precipitation_heat_parameters,
        &heat_by_cell,
    );
    // HEAT-001 third layer. Snowfall arrives frozen, so the enthalpy it
    // delivers on the census reference state (liquid water at 0 K) is the
    // solid-snow branch `C_l*Tm - L + C_s*(T - Tm)`, NOT `C_i*T - L`.
    // Rain carries no latent
    // offset. Written here as the closed form rather than by calling the
    // production helper, so the test is an independent statement of the
    // reference state and not a restatement of the code under test.
    const latent = precipitation_heat_parameters.snow_latent_heat_of_fusion_megajoules_per_m3;
    const melting = precipitation_heat_parameters.pure_water_melting_temperature_k;
    const liquid_capacity = precipitation_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k;
    const solid_capacity = precipitation_heat_parameters.solid_snow_heat_capacity_megajoules_per_m3_k;
    // Per cubic metre of snowfall water equivalent at temperature T.
    const snowfallEnthalpy = struct {
        fn at(temperature: f64) f64 {
            return liquid_capacity * melting - latent +
                solid_capacity * (temperature - melting);
        }
    }.at;
    const expected =
        280 * 10 * liquid_capacity * 0.001 + snowfallEnthalpy(280) * 0.003 * 10 +
        285 * 20 * liquid_capacity * 0.002 + snowfallEnthalpy(285) * 0.004 * 20;
    // The ice-branch offset `(C_l - C_i)*Tm = 617.5 MJ m-3` is nearly twice the
    // latent heat, so the corrected snowfall enthalpy is *positive* where the
    // superseded `C*T - L` form was negative at these depths. That sign change
    // is the whole day-one Ottawa correction, and pinning it here is what stops
    // the boundary from silently drifting away from the census again.
    try std.testing.expect(snowfallEnthalpy(280) > 0);
    try std.testing.expectApproxEqAbs(
        (liquid_capacity - solid_capacity) * melting,
        snowfallEnthalpy(280) - (solid_capacity * 280 - latent),
        1.0e-9,
    );
    try std.testing.expect(expected > 0);
    try std.testing.expectApproxEqAbs(
        expected,
        state.cumulative.heat_input_megajoules,
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(expected, heat_by_cell[0] + heat_by_cell[1], 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.heat_output_megajoules);
}

test "invalid precipitation heat transaction cannot advance ledger" {
    var state: ledger_module.State = .{};
    try state.accumulateAccepted(.{ .heat_input_megajoules = 7 });
    const before = state.cumulative;
    var heat_by_cell = [_]f64{99};
    try std.testing.expectError(
        error.InvalidPrecipitationHeatBoundaryInput,
        state.accumulateAcceptedPrecipitationHeat(
            &.{0.001},
            &.{0.002},
            &.{0},
            &.{280},
            precipitation_heat_parameters,
            &heat_by_cell,
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
    try std.testing.expectEqual(@as(f64, 99), heat_by_cell[0]);
}

test "non-default precipitation thermodynamics are used without fallback constants" {
    const parameters: ledger_module.PrecipitationHeatParameters = .{
        .snow_latent_heat_of_fusion_megajoules_per_m3 = 301,
        .solid_snow_heat_capacity_megajoules_per_m3_k = 2.3,
        .liquid_water_heat_capacity_megajoules_per_m3_k = 4.5,
        .pure_water_melting_temperature_k = 269,
    };
    var state: ledger_module.State = .{};
    var heat_by_cell: [1]f64 = undefined;
    try state.accumulateAcceptedPrecipitationHeat(
        &.{0.2},
        &.{0.3},
        &.{5},
        &.{271},
        parameters,
        &heat_by_cell,
    );
    const frozen = parameters.liquid_water_heat_capacity_megajoules_per_m3_k * parameters.pure_water_melting_temperature_k -
        parameters.snow_latent_heat_of_fusion_megajoules_per_m3 +
        parameters.solid_snow_heat_capacity_megajoules_per_m3_k *
            (271 - parameters.pure_water_melting_temperature_k);
    const expected = 5 * (0.2 * 4.5 * 271 + 0.3 * frozen);
    try std.testing.expectApproxEqAbs(expected, heat_by_cell[0], 1e-12);
    try std.testing.expectApproxEqAbs(expected, state.cumulative.heat_input_megajoules, 1e-12);
}

test "surface HEATH and canopy THFLXC retain signed boundary direction" {
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedSurfaceAndCanopyHeat(
        &.{ 2, -1 },
        &.{ 0.5, -0.5 },
        &.{ -0.25, 0.25 },
        &.{ -0.05, 0.05 },
        &.{ 10, 20 },
        &.{ -2, 1 },
    );
    // Ground: 22 MJ + (-24 MJ); canopy: -1 MJ.
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.heat_input_megajoules);
    try std.testing.expectApproxEqAbs(
        @as(f64, 3),
        state.cumulative.heat_output_megajoules,
        1.0e-12,
    );
}

test "invalid late canopy heat leaves boundary ledger unchanged" {
    var state: ledger_module.State = .{};
    try state.accumulateAccepted(.{ .heat_input_megajoules = 4 });
    const before = state.cumulative;
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedSurfaceAndCanopyHeat(
            &.{1},
            &.{2},
            &.{3},
            &.{4},
            &.{5},
            &.{std.math.nan(f64)},
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
}

test "surface endpoint reference heat books fixed phase and internal vapor terms" {
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedSurfaceEndpointReferenceHeat(
        &.{0.25},
        &.{0.001},
        4,
        2,
        273.15,
        2400,
    );
    const expected = (4.0 - 2.0) * 273.15 * 0.25 - 2400.0 * 0.001;
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.heat_input_megajoules);
    try std.testing.expectApproxEqAbs(
        expected,
        state.cumulative_internal.heat_production_megajoules,
        1e-12,
    );
}

test "surface endpoint phase reference pairs exactly with enthalpy census" {
    const liquid_capacity = 4.19;
    const ice_capacity = 1.9274;
    const latent = 333.0;
    const melting = inventory.default_pure_water_melting_temperature_k;
    for ([_]f64{ 250, 260, 270, melting, 280, 290 }) |temperature_k| {
        for ([_]f64{ 0.5, -0.25 }) |ice_change_m3| {
            var ledger: ledger_module.State = .{};
            try ledger.accumulateAcceptedSurfaceEndpointReferenceHeat(
                &.{ice_change_m3},
                &.{0},
                liquid_capacity,
                ice_capacity,
                melting,
                2465,
            );
            const booked = ledger.cumulative_internal.heat_production_megajoules -
                ledger.cumulative_internal.heat_consumption_megajoules;
            const census_change = (try inventory.frozenWaterEnthalpyPerM3(
                temperature_k,
                liquid_capacity,
                ice_capacity,
                latent,
                melting,
            ) - liquid_capacity * temperature_k) * ice_change_m3;
            // Endpoint storage includes the `C_i*T-C_l*T` part and the solved
            // phase flux includes `-L*dI`; the fixed reference is the rest.
            const already_booked_by_surface_flux_and_storage =
                (ice_capacity - liquid_capacity) * temperature_k * ice_change_m3 -
                latent * ice_change_m3;
            try std.testing.expectApproxEqAbs(
                census_change - already_booked_by_surface_flux_and_storage,
                booked,
                1e-12,
            );
        }
    }
}

test "ecosystem atmospheric gases include canopy exchange fixation and ammonia once" {
    var soil = try soil_daily_gas.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    var canopy = try canopy_daily_gas.State.init(std.testing.allocator, 1);
    defer canopy.deinit();
    // Soil gas convention matches the gas transport solver: positive = atmosphere
    // entering the ecosystem, negative = ecosystem emitting to atmosphere.
    soil.tracked_element_mass_g_by_cell_and_species[
        @intFromEnum(gas.Species.carbon_dioxide)
    ] = -3; // CO2 emitted from soil
    soil.tracked_element_mass_g_by_cell_and_species[
        @intFromEnum(gas.Species.methane)
    ] = 2; // CH4 absorbed from atmosphere into soil
    soil.tracked_element_mass_g_by_cell_and_species[
        @intFromEnum(gas.Species.oxygen)
    ] = -4; // O2 emitted from soil
    soil.tracked_element_mass_g_by_cell_and_species[
        @intFromEnum(gas.Species.nitrogen)
    ] = 7; // N2 entering soil from atmosphere
    soil.tracked_element_mass_g_by_cell_and_species[
        @intFromEnum(gas.Species.nitrous_oxide)
    ] = -8; // N2O emitted from soil
    soil.tracked_element_mass_g_by_cell_and_species[
        @intFromEnum(gas.Species.ammonia)
    ] = 9; // NH3 absorbed from atmosphere into soil
    soil.tracked_element_mass_g_by_cell_and_species[
        @intFromEnum(gas.Species.hydrogen)
    ] = -10; // H2 emitted from soil
    canopy.net_carbon_dioxide_uptake_g_c[0] = 5;
    canopy.net_methane_uptake_g_c[0] = -1;
    canopy.net_oxygen_uptake_g_o[0] = 6;
    canopy.fire_carbon_dioxide_emission_g_c[0] = 11;
    canopy.fire_methane_emission_g_c[0] = 13;
    canopy.fire_oxygen_consumption_g_o[0] = 17;

    var state: ledger_module.State = .{};
    try state.accumulateAcceptedAtmosphericGas(&soil, &canopy, &.{ 2, -0.5 }, &.{ 3, 4 });
    try std.testing.expectEqual(
        @as(f64, 30),
        state.cumulative.carbon_dioxide_input_g_c,
    );
    try std.testing.expectEqual(
        @as(f64, 27),
        state.cumulative.carbon_output_g_c,
    );
    try std.testing.expectEqual(
        @as(f64, 17),
        state.cumulative.oxygen_input_g,
    );
    try std.testing.expectEqual(
        @as(f64, 15),
        state.cumulative.oxygen_output_g,
    );
    try std.testing.expectEqual(
        @as(f64, 25),
        state.cumulative.dinitrogen_input_g_n,
    );
    try std.testing.expectEqual(
        @as(f64, 8.5),
        state.cumulative.nitrogen_output_g_n,
    );
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.hydrogen_input_g);
    try std.testing.expectEqual(@as(f64, 10), state.cumulative.hydrogen_output_g);
}

test "shoot fire N P domain reduction matches cell subset without duplicating ammonia" {
    const cell = try hourly.plantAtmosphereActivity(
        10,
        2,
        3,
        4,
        2.5,
        -0.25,
        1.25,
        -0.5,
        -0.75,
    );
    // The cell N output contains 0.25 outward NH3 plus 0.5 shoot-fire gas.
    try std.testing.expectEqual(@as(f64, 0.75), cell.nitrogen_output_g);
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedPlantFireNutrientEmissionTotals(0.5, 0.75);
    try std.testing.expectEqual(@as(f64, 0.5), state.cumulative.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 0.75), state.cumulative.phosphorus_output_g_p);

    const before = state;
    try std.testing.expectError(
        error.NegativeLandscapeBoundaryFlux,
        state.accumulateAcceptedPlantFireNutrientEmissionTotals(1, -0.1),
    );
    try std.testing.expectEqualDeep(before, state);
}

test "hourly and accumulated plant atmosphere ledgers have identical net C N and O activity" {
    const hourly_activity = try hourly.plantAtmosphereActivity(
        10,
        2,
        3,
        4,
        2.5,
        -0.25,
        1.25,
        0,
        0,
    );
    var soil = try soil_daily_gas.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    var canopy = try canopy_daily_gas.State.init(std.testing.allocator, 1);
    defer canopy.deinit();
    try canopy.accumulateHour(0, 10, 2, 3, 4, 2.5);
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedAtmosphericGas(&soil, &canopy, &.{-0.25}, &.{1.25});
    try std.testing.expectEqual(
        hourly_activity.carbon_input_g - hourly_activity.carbon_output_g,
        state.cumulative.carbon_dioxide_input_g_c - state.cumulative.carbon_output_g_c,
    );
    try std.testing.expectEqual(
        hourly_activity.nitrogen_input_g - hourly_activity.nitrogen_output_g,
        state.cumulative.dinitrogen_input_g_n - state.cumulative.nitrogen_output_g_n,
    );
    try std.testing.expectEqual(
        hourly_activity.oxygen_input_g - hourly_activity.oxygen_output_g,
        state.cumulative.oxygen_input_g - state.cumulative.oxygen_output_g,
    );
}

test "plant harvest is the external complement of authoritative plant storage loss" {
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedPlantHarvest(&.{ 2, 3 }, &.{ 5, 7 }, &.{ 11, 13 });
    try std.testing.expectEqual(@as(f64, 5), state.cumulative.carbon_output_g_c);
    try std.testing.expectEqual(@as(f64, 12), state.cumulative.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 24), state.cumulative.phosphorus_output_g_p);
}

test "accepted signed subsurface oxygen reaches EXEC physical boundary exactly once" {
    var soil = try soil_daily_gas.State.init(std.testing.allocator, 1);
    defer soil.deinit();
    var canopy = try canopy_daily_gas.State.init(std.testing.allocator, 1);
    defer canopy.deinit();
    var inward = [_]f64{0} ** gas.species_count;
    var outward = [_]f64{0} ** gas.species_count;
    const oxygen = @intFromEnum(gas.Species.oxygen);
    inward[oxygen] = 8.75;
    outward[oxygen] = -3.25;
    try soil.accumulateSubsurfacePhysicalBoundaryHour(1, &.{1}, &inward);
    try soil.accumulateSubsurfacePhysicalBoundaryHour(1, &.{1}, &outward);

    // These source-compatible REDIST diagnostics deliberately remain disjoint
    // from the accepted physical boundary consumed by the EXEC O2 equation.
    try soil.accumulateRedistSurfaceGasHour(0, 0, 0, 101, 103, 0, 0);
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedAtmosphericGas(&soil, &canopy, &.{0}, &.{0});

    try std.testing.expectEqual(@as(f64, 5.5), try soil.get(0, .oxygen));
    try std.testing.expectEqual(@as(f64, 5.5), state.cumulative.oxygen_input_g);
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.oxygen_output_g);
    try std.testing.expectEqual(
        @as(f64, 101),
        (try soil.getRedistSurfaceGasTotals()).oxygen_surface_input_g_o,
    );
    try std.testing.expectEqual(
        @as(f64, 103),
        (try soil.getRedistSurfaceGasTotals()).oxygen_subsurface_output_g_o,
    );
}

test "FIRE-NOX-BOUNDARY-001: fire gaseous N and P reach the boundary as exports" {
    var state: ledger_module.State = .{};
    // Two cells: cell 0 has both a soil and a root fire contribution, cell 1
    // has soil only. Values retain the source's negative (export-only) sign.
    const soil_nitrogen_g_n = [_]f64{ -3, -5 };
    const root_nitrogen_g_n = [_]f64{ -2, 0 };
    const soil_phosphorus_g_p = [_]f64{ -1, -4 };
    const root_phosphorus_g_p = [_]f64{ -0.5, 0 };
    try state.accumulateAcceptedFireNutrientEmission(
        &soil_nitrogen_g_n,
        &root_nitrogen_g_n,
        &soil_phosphorus_g_p,
        &root_phosphorus_g_p,
    );
    try std.testing.expectEqual(@as(f64, 10), state.cumulative.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 5.5), state.cumulative.phosphorus_output_g_p);
    // Every other field stays untouched.
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.nitrogen_input_g_n);
    try std.testing.expectEqual(@as(f64, 0), state.cumulative.phosphorus_input_g_p);

    // A second hour's worth of fire accumulates rather than overwrites.
    try state.accumulateAcceptedFireNutrientEmission(
        &soil_nitrogen_g_n,
        &root_nitrogen_g_n,
        &soil_phosphorus_g_p,
        &root_phosphorus_g_p,
    );
    try std.testing.expectEqual(@as(f64, 20), state.cumulative.nitrogen_output_g_n);
    try std.testing.expectEqual(@as(f64, 11), state.cumulative.phosphorus_output_g_p);
}

test "FIRE-NOX-BOUNDARY-001: a positive fire emission cannot partially advance the ledger" {
    var state: ledger_module.State = .{};
    try state.accumulateAccepted(.{ .nitrogen_output_g_n = 7 });
    const before = state.cumulative;
    try std.testing.expectError(
        error.PositiveFireNutrientEmissionFlux,
        state.accumulateAcceptedFireNutrientEmission(
            &.{1}, // sign-convention violation: fire emission must be <= 0
            &.{0},
            &.{-1},
            &.{0},
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
}

test "FIRE-NOX-BOUNDARY-001: non-finite fire emission cannot partially advance the ledger" {
    var state: ledger_module.State = .{};
    try state.accumulateAccepted(.{ .phosphorus_output_g_p = 2 });
    const before = state.cumulative;
    try std.testing.expectError(
        error.NonFiniteLandscapeBoundaryFlux,
        state.accumulateAcceptedFireNutrientEmission(
            &.{-1},
            &.{0},
            &.{std.math.nan(f64)},
            &.{0},
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative);
}

test "FIRE-NOX-BOUNDARY-001: mismatched fire ledger lengths are rejected" {
    var state: ledger_module.State = .{};
    try std.testing.expectError(
        error.LandscapeBoundaryGridDimensionMismatch,
        state.accumulateAcceptedFireNutrientEmission(
            &.{ -1, -2 },
            &.{-1},
            &.{-1},
            &.{-1},
        ),
    );
}

test "atmospheric solutes map tracked elements and phosphate atom counts" {
    var inputs = try atmospheric_solutes.State.init(std.testing.allocator, 1);
    defer inputs.deinit();
    const amounts = inputs.daily_input_g[0..snow.species_count];
    amounts[@intFromEnum(snow.Species.carbon_dioxide_carbon)] = 1;
    amounts[@intFromEnum(snow.Species.methane_carbon)] = 2;
    amounts[@intFromEnum(snow.Species.oxygen)] = 3;
    amounts[@intFromEnum(snow.Species.dinitrogen_nitrogen)] = 4;
    amounts[@intFromEnum(snow.Species.nitrous_oxide_nitrogen)] = 5;
    amounts[@intFromEnum(snow.Species.ammonium_nitrogen)] = 6;
    amounts[@intFromEnum(snow.Species.ammonia_nitrogen)] = 7;
    amounts[@intFromEnum(snow.Species.nitrate_nitrogen)] = 8;
    amounts[@intFromEnum(snow.Species.hydrogen_phosphate_phosphorus)] = 31;
    amounts[@intFromEnum(snow.Species.dihydrogen_phosphate_phosphorus)] = 62;
    inline for (0..8) |ion|
        amounts[10 + ion] += @as(f64, @floatFromInt(ion + 1));
    @memset(inputs.daily_salt_input_mol, 1);

    var state: ledger_module.State = .{};
    try state.accumulateAcceptedAtmosphericSolutes(&inputs, .{
        .aluminum = 1,
        .iron = 2,
        .calcium = 3,
        .magnesium = 4,
        .sodium = 5,
        .potassium = 6,
        .sulfur = 7,
        .chloride = 8,
    });
    try std.testing.expectEqual(
        @as(f64, 87),
        state.cumulative.carbon_dioxide_input_g_c,
    );
    try std.testing.expectEqual(
        @as(f64, 9),
        state.cumulative.dinitrogen_input_g_n,
    );
    try std.testing.expectEqual(
        @as(f64, 21),
        state.cumulative.nitrogen_input_g_n,
    );
    try std.testing.expectEqual(
        @as(f64, 341),
        state.cumulative.phosphorus_input_g_p,
    );
    // Primary carriers contribute 16 REDIST pseudo-ions: HPO4 and H2PO4
    // contribute 2 and 3, respectively, plus the eight free salt carriers.
    // One mole of each of the 41 snow equilibrium species contributes 93
    // REDIST pseudo-ions: all formula H/C/P and tracked elements, but no O.
    // Together with the 16 primary-carrier pseudo-ions this is 109.
    try std.testing.expectEqual(
        @as(f64, 109),
        state.cumulative.ion_input_mol,
    );
}

test "hydrogen transformations accumulate physical directions transactionally" {
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedHydrogenTransformations(
        &.{ 0.1, 0.2 },
        &.{ 0.04, 0.06 },
        &.{0.5},
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.8),
        state.cumulative_internal.hydrogen_production_g_h,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        state.cumulative_internal.hydrogen_consumption_g_h,
        1e-15,
    );

    const before = state.cumulative_internal;
    try std.testing.expectError(
        error.NegativeLandscapeBoundaryFlux,
        state.accumulateAcceptedHydrogenTransformations(
            &.{0.1},
            &.{-0.01},
            &.{0.2},
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative_internal);

    try std.testing.expectError(
        error.NegativeLandscapeBoundaryFlux,
        state.accumulateAcceptedHydrogenTransformationTotals(0.1, -0.1),
    );
    try std.testing.expectEqualDeep(before, state.cumulative_internal);
}

test "hydrogen transformation owners may have different native dimensions" {
    var state: ledger_module.State = .{};
    try state.accumulateAcceptedHydrogenTransformations(
        &.{ 0.1, 0.2 },
        &.{0.1},
        &.{0.2},
    );
    try std.testing.expectEqual(
        @as(f64, 0.5),
        state.cumulative_internal.hydrogen_production_g_h,
    );
    try std.testing.expectEqual(
        @as(f64, 0.1),
        state.cumulative_internal.hydrogen_consumption_g_h,
    );

    const before = state.cumulative_internal;
    try std.testing.expectError(
        error.HydrogenTransformationDimensionMismatch,
        state.accumulateAcceptedHydrogenTransformations(
            &.{ 0.1, 0.2 },
            &.{},
            &.{0.2},
        ),
    );
    try std.testing.expectEqualDeep(before, state.cumulative_internal);
}

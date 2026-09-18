//! Tests for `cation_exchange.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const exchange_module = @import("cation_exchange.zig");

test "Gapon exchange flux conserves charge equivalents" {
    const all = exchange_module.Cations{ .ammonium_non_band = 0.2, .ammonium_band = 0.1, .hydrogen = 0.05, .aluminum = 0.03, .iron = 0.02, .calcium = 0.5, .magnesium = 0.2, .sodium = 0.1, .potassium = 0.08 };
    const flux = try exchange_module.calculate(.{ .cation_exchange_capacity_mol_charge_per_megagram = 2, .aqueous_concentration_mol_per_m3 = all, .aqueous_activity_mol_per_m3 = all, .exchange_concentration_mol_per_megagram = all, .ammonium_non_band_fraction = 0.8, .ammonium_band_fraction = 0.2, .soil_mass_per_water_volume_megagrams_per_m3 = 1.4 }, .{ .selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, .substrate_limit_fraction = 0.2, .maximum_adsorption_mol_charge_per_m3_step = 0.01 });
    const charge = 0.8 * flux.ammonium_non_band + 0.2 * flux.ammonium_band + flux.hydrogen + 3 * flux.aluminum + 3 * flux.iron + 2 * flux.calcium + 2 * flux.magnesium + flux.sodium + flux.potassium;
    try std.testing.expectApproxEqAbs(@as(f64, 0), charge, 1e-14);
}

test "source cation state update is unfloored and skipped at ceiling" {
    const current = exchange_module.Cations{
        .ammonium_non_band = 1,
        .ammonium_band = 2,
        .hydrogen = 3,
        .aluminum = 4,
        .iron = 5,
        .calcium = 6,
        .magnesium = 7,
        .sodium = 8,
        .potassium = 9,
    };
    const changes = exchange_module.Cations{
        .ammonium_non_band = -1,
        .ammonium_band = 0.25,
        .hydrogen = -0.5,
        .aluminum = 0,
        .iron = 0,
        .calcium = 0,
        .magnesium = 0,
        .sodium = 0,
        .potassium = 0,
    };
    const terminal = try exchange_module.applySourceOrderStateUpdate(
        current,
        changes,
        .iteration_ceiling,
    );
    try std.testing.expectEqualDeep(current, terminal);

    const continuing = try exchange_module.applySourceOrderStateUpdate(
        current,
        changes,
        .before_iteration_ceiling,
    );
    try std.testing.expectEqual(@as(f64, 0), continuing.ammonium_non_band);
    try std.testing.expectEqual(@as(f64, 2.25), continuing.ammonium_band);
    try std.testing.expectEqual(@as(f64, 2.5), continuing.hydrogen);
}

test "SOLUTE repeated source-order Gapon blocks preserve fraction-weighted CEC" {
    const inputs = exchange_module.Inputs{
        .cation_exchange_capacity_mol_charge_per_megagram = 1,
        .aqueous_concentration_mol_per_m3 = .{
            .ammonium_non_band = 1,
            .ammonium_band = 1,
            .hydrogen = 0,
            .aluminum = 0,
            .iron = 0,
            .calcium = 1,
            .magnesium = 0,
            .sodium = 0,
            .potassium = 0,
        },
        .aqueous_activity_mol_per_m3 = .{
            .ammonium_non_band = 1,
            .ammonium_band = 1,
            .hydrogen = 0,
            .aluminum = 0,
            .iron = 0,
            .calcium = 1,
            .magnesium = 0,
            .sodium = 0,
            .potassium = 0,
        },
        .exchange_concentration_mol_per_megagram = .{
            .ammonium_non_band = 0.3,
            .ammonium_band = 0.1,
            .hydrogen = 0,
            .aluminum = 0,
            .iron = 0,
            .calcium = 0.3,
            .magnesium = 0,
            .sodium = 0,
            .potassium = 0,
        },
        .ammonium_non_band_fraction = 0.75,
        .ammonium_band_fraction = 0.25,
        .soil_mass_per_water_volume_megagrams_per_m3 = 1,
    };
    const selectivity = exchange_module.Selectivity{
        .calcium_ammonium = 1,
        .calcium_hydrogen = 0,
        .calcium_aluminum_and_iron = 0,
        .calcium_magnesium = 0,
        .calcium_sodium = 0,
        .calcium_potassium = 0,
    };
    const changes = try exchange_module.calculateSourceOrder(inputs, .{
        .selectivity = selectivity,
        .substrate_limit_fraction = 1,
        .maximum_adsorption_mol_charge_per_m3_step = 1,
    }, .{ .minimum_activity_mol_per_m3 = 1e-32 });

    try std.testing.expect(changes.ammonium_non_band < 0);
    try std.testing.expect(changes.ammonium_band > 0);
    try std.testing.expect(changes.calcium < 0);
    const charge = inputs.ammonium_non_band_fraction * changes.ammonium_non_band +
        inputs.ammonium_band_fraction * changes.ammonium_band +
        2 * changes.calcium;
    try std.testing.expectApproxEqAbs(@as(f64, 0), charge, 1e-15);
}

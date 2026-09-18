//! Tests for `water_equilibrium.zig`.
//!
//! Extracted so the module beside it carries only model code. Tests
//! that reach a private declaration of that module stay there, since a
//! sibling file can only see `pub` declarations.

const std = @import("std");
const water_equilibrium = @import("water_equilibrium.zig");

test "water equilibrium reaches activity product with equal transformation" {
    const inputs: water_equilibrium.Inputs = .{ .hydrogen_concentration_mol_per_m3 = 1e-3, .hydroxide_concentration_mol_per_m3 = 2e-3, .monovalent_activity_coefficient = 0.8, .water_activity_product_mol2_per_m6 = 1e-8, .negligible_concentration_mol_per_m3 = 1e-32 };
    const result = try water_equilibrium.solve(inputs);
    try std.testing.expectApproxEqRel(inputs.water_activity_product_mol2_per_m6, result.hydrogen_activity_mol_per_m3 * result.hydroxide_activity_mol_per_m3, 1e-13);
    try std.testing.expectApproxEqAbs(inputs.hydrogen_concentration_mol_per_m3 * inputs.monovalent_activity_coefficient - result.hydrogen_activity_mol_per_m3, inputs.hydroxide_concentration_mol_per_m3 * inputs.monovalent_activity_coefficient - result.hydroxide_activity_mol_per_m3, 1e-15);
    try std.testing.expect(std.math.isFinite(result.ph));
}

test "water equilibrium matches source quadratic away from cancellation" {
    const inputs: water_equilibrium.Inputs = .{
        .hydrogen_concentration_mol_per_m3 = 0.4,
        .hydroxide_concentration_mol_per_m3 = 0.1,
        .monovalent_activity_coefficient = 0.8,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .negligible_concentration_mol_per_m3 = 1.0e-32,
    };
    const source_hydrogen_activity =
        inputs.hydrogen_concentration_mol_per_m3 *
        inputs.monovalent_activity_coefficient;
    const source_hydroxide_activity =
        inputs.hydroxide_concentration_mol_per_m3 *
        inputs.monovalent_activity_coefficient;
    const source_sum =
        source_hydrogen_activity + source_hydroxide_activity;
    const source_discriminant = @max(
        0,
        source_sum * source_sum -
            4 * (source_hydrogen_activity *
                source_hydroxide_activity -
                inputs.water_activity_product_mol2_per_m6),
    );
    const source_extent =
        0.5 * (source_sum - @sqrt(source_discriminant));
    const result = try water_equilibrium.solve(inputs);
    try std.testing.expectApproxEqAbs(
        source_hydrogen_activity - source_extent,
        result.hydrogen_activity_mol_per_m3,
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        source_hydroxide_activity - source_extent,
        result.hydroxide_activity_mol_per_m3,
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        source_extent,
        result.equal_reaction_extent_mol_per_m3,
        1.0e-15,
    );
}

test "SOLUTE surface pH reset preserves every source expression" {
    const inputs: water_equilibrium.Inputs = .{
        .hydrogen_concentration_mol_per_m3 = 0.4,
        .hydroxide_concentration_mol_per_m3 = 0.1,
        .monovalent_activity_coefficient = 0.8,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .negligible_concentration_mol_per_m3 = 1.0e-32,
    };
    const result = try water_equilibrium.calculateSourceOrderSurfaceReset(inputs);
    const expected_hydrogen_activity =
        inputs.hydrogen_concentration_mol_per_m3 *
        inputs.monovalent_activity_coefficient;
    const expected_hydroxide_activity =
        inputs.hydroxide_concentration_mol_per_m3 *
        inputs.monovalent_activity_coefficient;
    const expected_sum =
        expected_hydrogen_activity + expected_hydroxide_activity;
    const expected_discriminant = @max(
        0.0,
        expected_sum * expected_sum -
            4.0 *
                (expected_hydrogen_activity *
                    expected_hydroxide_activity -
                    inputs.water_activity_product_mol2_per_m6),
    );
    const expected_extent =
        0.5 * (expected_sum - @sqrt(expected_discriminant));
    const expected_final_hydrogen = @max(
        inputs.negligible_concentration_mol_per_m3,
        expected_hydrogen_activity - expected_extent,
    );
    const expected_final_hydroxide = @max(
        inputs.negligible_concentration_mol_per_m3,
        expected_hydroxide_activity - expected_extent,
    );

    try std.testing.expectEqual(
        expected_hydrogen_activity,
        result.initial_hydrogen_activity_mol_per_m3,
    );
    try std.testing.expectEqual(
        expected_hydroxide_activity,
        result.initial_hydroxide_activity_mol_per_m3,
    );
    try std.testing.expectEqual(
        expected_sum,
        result.activity_sum_mol_per_m3,
    );
    try std.testing.expectEqual(
        expected_discriminant,
        result.nonnegative_discriminant_mol2_per_m6,
    );
    try std.testing.expectEqual(
        expected_extent,
        result.equal_reaction_extent_activity_mol_per_m3,
    );
    try std.testing.expectEqual(
        expected_final_hydrogen,
        result.hydrogen_activity_mol_per_m3,
    );
    try std.testing.expectEqual(
        expected_final_hydroxide,
        result.hydroxide_activity_mol_per_m3,
    );
    try std.testing.expectEqual(
        expected_final_hydrogen /
            inputs.monovalent_activity_coefficient,
        result.hydrogen_concentration_mol_per_m3,
    );
    try std.testing.expectEqual(
        expected_final_hydroxide /
            inputs.monovalent_activity_coefficient,
        result.hydroxide_concentration_mol_per_m3,
    );
    try std.testing.expectEqual(
        -@log10(expected_final_hydrogen * 1.0e-3),
        result.ph,
    );
}

test "SOLUTE surface pH activity gates are strict" {
    const inputs: water_equilibrium.Inputs = .{
        .hydrogen_concentration_mol_per_m3 = 1.0e-4,
        .hydroxide_concentration_mol_per_m3 = 1.0e-4,
        .monovalent_activity_coefficient = 0.5,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .negligible_concentration_mol_per_m3 = 1.0e-4,
    };
    const result = try water_equilibrium.calculateSourceOrderSurfaceReset(inputs);
    try std.testing.expectEqual(
        inputs.hydrogen_concentration_mol_per_m3,
        result.initial_hydrogen_activity_mol_per_m3,
    );
    try std.testing.expectEqual(
        inputs.hydroxide_concentration_mol_per_m3,
        result.initial_hydroxide_activity_mol_per_m3,
    );
}

test "production water equilibrium preserves trace ion lost by source arithmetic" {
    const inputs: water_equilibrium.Inputs = .{
        .hydrogen_concentration_mol_per_m3 = 1.0e12,
        .hydroxide_concentration_mol_per_m3 = 1.0e-20,
        .monovalent_activity_coefficient = 0.7,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .negligible_concentration_mol_per_m3 = 1.0e-32,
    };
    const source = try water_equilibrium.calculateSourceOrderSurfaceReset(inputs);
    const production = try water_equilibrium.solve(inputs);
    const source_product =
        source.hydrogen_activity_mol_per_m3 *
        source.hydroxide_activity_mol_per_m3;
    const production_product =
        production.hydrogen_activity_mol_per_m3 *
        production.hydroxide_activity_mol_per_m3;

    try std.testing.expect(
        @abs(source_product -
            inputs.water_activity_product_mol2_per_m6) >
            0.1 * inputs.water_activity_product_mol2_per_m6,
    );
    try std.testing.expectApproxEqRel(
        inputs.water_activity_product_mol2_per_m6,
        production_product,
        4 * std.math.floatEps(f64),
    );
}

test "SOLUTE surface pH reset rejects invalid input and overflow" {
    var inputs: water_equilibrium.Inputs = .{
        .hydrogen_concentration_mol_per_m3 = 0.4,
        .hydroxide_concentration_mol_per_m3 = 0.1,
        .monovalent_activity_coefficient = 0.8,
        .water_activity_product_mol2_per_m6 = 1.0e-8,
        .negligible_concentration_mol_per_m3 = 1.0e-32,
    };
    inputs.negligible_concentration_mol_per_m3 = 0;
    try std.testing.expectError(
        error.InvalidWaterEquilibriumInput,
        water_equilibrium.calculateSourceOrderSurfaceReset(inputs),
    );

    inputs.negligible_concentration_mol_per_m3 = 1.0e-32;
    inputs.hydrogen_concentration_mol_per_m3 = std.math.nan(f64);
    try std.testing.expectError(
        error.NonFiniteWaterEquilibriumInput,
        water_equilibrium.calculateSourceOrderSurfaceReset(inputs),
    );

    inputs.hydrogen_concentration_mol_per_m3 =
        std.math.floatMax(f64);
    inputs.monovalent_activity_coefficient = 2;
    try std.testing.expectError(
        error.NonFiniteWaterEquilibriumSolution,
        water_equilibrium.calculateSourceOrderSurfaceReset(inputs),
    );
}

test "cancellation-safe water equilibrium handles nearly balanced activities" {
    const result = try water_equilibrium.solve(.{ .hydrogen_concentration_mol_per_m3 = 1.000001e-4, .hydroxide_concentration_mol_per_m3 = 1e-4, .monovalent_activity_coefficient = 1, .water_activity_product_mol2_per_m6 = 1e-8, .negligible_concentration_mol_per_m3 = 1e-32 });
    try std.testing.expectApproxEqRel(@as(f64, 1e-8), result.hydrogen_activity_mol_per_m3 * result.hydroxide_activity_mol_per_m3, 1e-14);
}

test "water equilibrium preserves trace hydroxide under extreme acidity" {
    const result = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = 1e12,
        .hydroxide_concentration_mol_per_m3 = 1e-20,
        .monovalent_activity_coefficient = 0.7,
        .water_activity_product_mol2_per_m6 = 1e-8,
        .negligible_concentration_mol_per_m3 = 1e-32,
    });
    try std.testing.expect(result.hydroxide_activity_mol_per_m3 > 0);
    try std.testing.expectApproxEqRel(
        @as(f64, 1e-8),
        result.hydrogen_activity_mol_per_m3 *
            result.hydroxide_activity_mol_per_m3,
        4 * std.math.floatEps(f64),
    );
}

test "water equilibrium projects a provisional negative free ion" {
    const result = try water_equilibrium.projectProvisional(-0.2, 0.1, 0.8, 1e-8);
    try std.testing.expect(result.hydrogen_concentration_mol_per_m3 > 0);
    try std.testing.expect(result.hydroxide_concentration_mol_per_m3 > 0);
    try std.testing.expectApproxEqRel(
        @as(f64, 1e-8),
        result.hydrogen_activity_mol_per_m3 *
            result.hydroxide_activity_mol_per_m3,
        8 * std.math.floatEps(f64),
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.3),
        result.hydrogen_concentration_mol_per_m3 -
            result.hydroxide_concentration_mol_per_m3,
        1e-15,
    );
}

test "final source reset mixes activity extent into concentration totals" {
    const source = try water_equilibrium.calculateSourceOrderFinalReset(.{
        .initial_hydrogen_concentration_mol_per_m3 = 0.4,
        .initial_hydroxide_concentration_mol_per_m3 = 0.1,
        .accumulated_hydrogen_change_mol_per_m3 = 0,
        .accumulated_hydroxide_change_mol_per_m3 = 0,
        .monovalent_activity_coefficient = 0.8,
        .water_activity_product_mol2_per_m6 = 1e-8,
        .negligible_concentration_mol_per_m3 = 1e-32,
    });
    try std.testing.expectApproxEqRel(
        @as(f64, 1e-8),
        source.hydrogen_activity_mol_per_m3 *
            source.hydroxide_activity_mol_per_m3,
        2e-10,
    );
    const source_published_product =
        source.published_hydrogen_concentration_mol_per_m3 *
        source.published_hydroxide_concentration_mol_per_m3 *
        0.8 * 0.8;
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.0799999583333406),
        source.equal_reaction_extent_activity_mol_per_m3,
        1e-15,
    );
    try std.testing.expectEqual(
        source.equal_reaction_extent_activity_mol_per_m3,
        source.water_balance_increment_mol_per_m3,
    );
    try std.testing.expect(source_published_product > 0.004);

    const corrected = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = 0.4,
        .hydroxide_concentration_mol_per_m3 = 0.1,
        .monovalent_activity_coefficient = 0.8,
        .water_activity_product_mol2_per_m6 = 1e-8,
        .negligible_concentration_mol_per_m3 = 1e-32,
    });
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.019999989583342537),
        corrected.hydrogen_concentration_mol_per_m3 -
            source.published_hydrogen_concentration_mol_per_m3,
        1e-14,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.01999998958334254),
        corrected.hydroxide_concentration_mol_per_m3 -
            source.published_hydroxide_concentration_mol_per_m3,
        1e-14,
    );
}

test "SOLUTE 3647-3650 fixed pH reset subtracts preceding transformations" {
    const result = try water_equilibrium.calculateFixedPhResetSourceOrder(.{
        .soil_ph = 3,
        .monovalent_activity_coefficient = 0.5,
        .water_activity_product_mol2_per_m6 = 2,
        .current_hydrogen_activity_mol_per_m3 = 0.2,
        .current_hydroxide_activity_mol_per_m3 = 0.3,
        .preceding_hydrogen_transformation_mol_per_m3 = 0.1,
        .preceding_hydroxide_transformation_mol_per_m3 = -0.2,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result.target_hydrogen_activity_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4), result.target_hydroxide_activity_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result.hydrogen_reset_mol_per_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3.9), result.hydroxide_reset_mol_per_m3, 1e-15);
}

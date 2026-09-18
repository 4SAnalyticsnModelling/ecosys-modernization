const std = @import("std");

pub const Inputs = struct {
    hydrogen_concentration_mol_per_m3: f64,
    hydroxide_concentration_mol_per_m3: f64,
    monovalent_activity_coefficient: f64,
    water_activity_product_mol2_per_m6: f64,
    negligible_concentration_mol_per_m3: f64,
};

pub const Result = struct {
    hydrogen_concentration_mol_per_m3: f64,
    hydroxide_concentration_mol_per_m3: f64,
    hydrogen_activity_mol_per_m3: f64,
    hydroxide_activity_mol_per_m3: f64,
    equal_reaction_extent_mol_per_m3: f64,
    ph: f64,
};

pub const FinalResetInputs = struct {
    initial_hydrogen_concentration_mol_per_m3: f64,
    initial_hydroxide_concentration_mol_per_m3: f64,
    accumulated_hydrogen_change_mol_per_m3: f64,
    accumulated_hydroxide_change_mol_per_m3: f64,
    monovalent_activity_coefficient: f64,
    water_activity_product_mol2_per_m6: f64,
    negligible_concentration_mol_per_m3: f64,
};

pub const SourceOrderFinalReset = struct {
    hydrogen_activity_mol_per_m3: f64,
    hydroxide_activity_mol_per_m3: f64,
    equal_reaction_extent_activity_mol_per_m3: f64,
    accumulated_hydrogen_change_mol_per_m3: f64,
    accumulated_hydroxide_change_mol_per_m3: f64,
    water_balance_increment_mol_per_m3: f64,
    published_hydrogen_concentration_mol_per_m3: f64,
    published_hydroxide_concentration_mol_per_m3: f64,
};

pub const SourceOrderSurfaceReset = struct {
    initial_hydrogen_activity_mol_per_m3: f64,
    initial_hydroxide_activity_mol_per_m3: f64,
    activity_sum_mol_per_m3: f64,
    nonnegative_discriminant_mol2_per_m6: f64,
    equal_reaction_extent_activity_mol_per_m3: f64,
    hydrogen_activity_mol_per_m3: f64,
    hydroxide_activity_mol_per_m3: f64,
    hydrogen_concentration_mol_per_m3: f64,
    hydroxide_concentration_mol_per_m3: f64,
    ph: f64,
    hydrogen_floor_was_applied: bool,
    hydroxide_floor_was_applied: bool,
};

pub const FixedPhResetInputs = struct {
    soil_ph: f64,
    monovalent_activity_coefficient: f64,
    water_activity_product_mol2_per_m6: f64,
    current_hydrogen_activity_mol_per_m3: f64,
    current_hydroxide_activity_mol_per_m3: f64,
    preceding_hydrogen_transformation_mol_per_m3: f64,
    preceding_hydroxide_transformation_mol_per_m3: f64,
};

pub const FixedPhReset = struct {
    target_hydrogen_activity_mol_per_m3: f64,
    target_hydroxide_activity_mol_per_m3: f64,
    hydrogen_reset_mol_per_m3: f64,
    hydroxide_reset_mol_per_m3: f64,
};

/// Exact fixed-soil-pH reset from SOLUTE.F lines 3647--3650. The source
/// subtracts both the current activity and the preceding transformation so
/// that their sum reaches the prescribed activity in this iteration.
pub fn calculateFixedPhResetSourceOrder(inputs: FixedPhResetInputs) !FixedPhReset {
    inline for (@typeInfo(FixedPhResetInputs).@"struct".fields) |field|
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteWaterEquilibriumInput;
    if (inputs.monovalent_activity_coefficient <= 0 or
        inputs.water_activity_product_mol2_per_m6 <= 0 or
        inputs.current_hydrogen_activity_mol_per_m3 < 0 or
        inputs.current_hydroxide_activity_mol_per_m3 < 0)
        return error.InvalidWaterEquilibriumInput;

    const target_hydrogen_activity = std.math.pow(f64, 10, -inputs.soil_ph) *
        1.0e3 * inputs.monovalent_activity_coefficient;
    const target_hydroxide_activity = inputs.water_activity_product_mol2_per_m6 /
        target_hydrogen_activity;
    const result = FixedPhReset{
        .target_hydrogen_activity_mol_per_m3 = target_hydrogen_activity,
        .target_hydroxide_activity_mol_per_m3 = target_hydroxide_activity,
        .hydrogen_reset_mol_per_m3 = target_hydrogen_activity -
            inputs.current_hydrogen_activity_mol_per_m3 -
            inputs.preceding_hydrogen_transformation_mol_per_m3,
        .hydroxide_reset_mol_per_m3 = target_hydroxide_activity -
            inputs.current_hydroxide_activity_mol_per_m3 -
            inputs.preceding_hydroxide_transformation_mol_per_m3,
    };
    inline for (@typeInfo(FixedPhReset).@"struct".fields) |field|
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteWaterEquilibriumSolution;
    if (target_hydrogen_activity <= 0 or target_hydroxide_activity <= 0)
        return error.InvalidWaterEquilibriumSolution;
    return result;
}

/// SOLUTE lines 834--854 H2O equilibrium reset with a cancellation-safe
/// quadratic evaluation. The reaction preserves the H+-OH- activity
/// difference. Solve the larger ion from that invariant, then obtain the
/// smaller ion by division from Kw; this remains accurate for the extreme
/// acid/base ratios that lose the smaller source-form root.
pub fn solve(inputs: Inputs) !Result {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| if (!std.math.isFinite(@field(inputs, field.name))) return error.NonFiniteWaterEquilibriumInput;
    if (inputs.hydrogen_concentration_mol_per_m3 < 0 or inputs.hydroxide_concentration_mol_per_m3 < 0 or inputs.monovalent_activity_coefficient <= 0 or inputs.water_activity_product_mol2_per_m6 <= 0 or inputs.negligible_concentration_mol_per_m3 < 0) return error.InvalidWaterEquilibriumInput;
    const hydrogen_activity = if (inputs.hydrogen_concentration_mol_per_m3 > inputs.negligible_concentration_mol_per_m3) inputs.hydrogen_concentration_mol_per_m3 * inputs.monovalent_activity_coefficient else inputs.hydrogen_concentration_mol_per_m3;
    const hydroxide_activity = if (inputs.hydroxide_concentration_mol_per_m3 > inputs.negligible_concentration_mol_per_m3) inputs.hydroxide_concentration_mol_per_m3 * inputs.monovalent_activity_coefficient else inputs.hydroxide_concentration_mol_per_m3;
    const activity_difference = hydrogen_activity - hydroxide_activity;
    const discriminant = std.math.hypot(
        activity_difference,
        2 * @sqrt(inputs.water_activity_product_mol2_per_m6),
    );
    const next_hydrogen_activity, const next_hydroxide_activity =
        if (activity_difference >= 0) .{
            0.5 * (activity_difference + discriminant),
            inputs.water_activity_product_mol2_per_m6 /
                (0.5 * (activity_difference + discriminant)),
        } else .{
            inputs.water_activity_product_mol2_per_m6 /
                (0.5 * (-activity_difference + discriminant)),
            0.5 * (-activity_difference + discriminant),
        };
    const extent = hydrogen_activity - next_hydrogen_activity;
    if (next_hydrogen_activity <= 0 or next_hydroxide_activity <= 0) return error.InvalidWaterEquilibriumSolution;
    const tolerance = 32 * std.math.floatEps(f64) * @max(inputs.water_activity_product_mol2_per_m6, next_hydrogen_activity * next_hydroxide_activity);
    if (@abs(next_hydrogen_activity * next_hydroxide_activity - inputs.water_activity_product_mol2_per_m6) > tolerance) return error.WaterActivityProductFailure;
    return .{
        .hydrogen_concentration_mol_per_m3 = next_hydrogen_activity / inputs.monovalent_activity_coefficient,
        .hydroxide_concentration_mol_per_m3 = next_hydroxide_activity / inputs.monovalent_activity_coefficient,
        .hydrogen_activity_mol_per_m3 = next_hydrogen_activity,
        .hydroxide_activity_mol_per_m3 = next_hydroxide_activity,
        .equal_reaction_extent_mol_per_m3 = extent,
        .ph = -@log10(next_hydrogen_activity * 1e-3),
    };
}

/// Exact equation-order diagnostic for the surface reset at SOLUTE.F
/// lines 4238--4265.
///
/// Production uses `solve`, which preserves the activity-difference
/// invariant while avoiding cancellation of the smaller quadratic root.
pub fn calculateSourceOrderSurfaceReset(
    inputs: Inputs,
) !SourceOrderSurfaceReset {
    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteWaterEquilibriumInput;
    }
    if (inputs.hydrogen_concentration_mol_per_m3 < 0 or
        inputs.hydroxide_concentration_mol_per_m3 < 0 or
        inputs.monovalent_activity_coefficient <= 0 or
        inputs.water_activity_product_mol2_per_m6 <= 0 or
        inputs.negligible_concentration_mol_per_m3 <= 0)
    {
        return error.InvalidWaterEquilibriumInput;
    }

    // SOLUTE.F 4248--4265. Preserve strict gates and arithmetic order.
    const initial_hydrogen_activity =
        if (inputs.hydrogen_concentration_mol_per_m3 >
        inputs.negligible_concentration_mol_per_m3)
            inputs.hydrogen_concentration_mol_per_m3 *
                inputs.monovalent_activity_coefficient
        else
            inputs.hydrogen_concentration_mol_per_m3;
    const initial_hydroxide_activity =
        if (inputs.hydroxide_concentration_mol_per_m3 >
        inputs.negligible_concentration_mol_per_m3)
            inputs.hydroxide_concentration_mol_per_m3 *
                inputs.monovalent_activity_coefficient
        else
            inputs.hydroxide_concentration_mol_per_m3;
    const activity_sum =
        initial_hydrogen_activity + initial_hydroxide_activity;
    const discriminant = @max(
        0.0,
        activity_sum * activity_sum -
            4.0 *
                (initial_hydrogen_activity *
                    initial_hydroxide_activity -
                    inputs.water_activity_product_mol2_per_m6),
    );
    const extent =
        0.5 * (activity_sum - @sqrt(discriminant));
    const unconstrained_hydrogen_activity =
        initial_hydrogen_activity - extent;
    const unconstrained_hydroxide_activity =
        initial_hydroxide_activity - extent;
    const hydrogen_activity = @max(
        inputs.negligible_concentration_mol_per_m3,
        unconstrained_hydrogen_activity,
    );
    const hydroxide_activity = @max(
        inputs.negligible_concentration_mol_per_m3,
        unconstrained_hydroxide_activity,
    );
    const hydrogen_concentration =
        hydrogen_activity / inputs.monovalent_activity_coefficient;
    const hydroxide_concentration =
        hydroxide_activity / inputs.monovalent_activity_coefficient;
    const ph = -@log10(hydrogen_activity * 1.0e-3);

    const result: SourceOrderSurfaceReset = .{
        .initial_hydrogen_activity_mol_per_m3 = initial_hydrogen_activity,
        .initial_hydroxide_activity_mol_per_m3 = initial_hydroxide_activity,
        .activity_sum_mol_per_m3 = activity_sum,
        .nonnegative_discriminant_mol2_per_m6 = discriminant,
        .equal_reaction_extent_activity_mol_per_m3 = extent,
        .hydrogen_activity_mol_per_m3 = hydrogen_activity,
        .hydroxide_activity_mol_per_m3 = hydroxide_activity,
        .hydrogen_concentration_mol_per_m3 = hydrogen_concentration,
        .hydroxide_concentration_mol_per_m3 = hydroxide_concentration,
        .ph = ph,
        .hydrogen_floor_was_applied = unconstrained_hydrogen_activity <
            inputs.negligible_concentration_mol_per_m3,
        .hydroxide_floor_was_applied = unconstrained_hydroxide_activity <
            inputs.negligible_concentration_mol_per_m3,
    };
    inline for (@typeInfo(SourceOrderSurfaceReset).@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .float => if (!std.math.isFinite(@field(result, field.name)))
                return error.NonFiniteWaterEquilibriumSolution,
            .bool => {},
            else => unreachable,
        }
    }
    if (result.hydrogen_activity_mol_per_m3 <= 0 or
        result.hydroxide_activity_mol_per_m3 <= 0 or
        result.hydrogen_concentration_mol_per_m3 <= 0 or
        result.hydroxide_concentration_mol_per_m3 <= 0)
    {
        return error.InvalidWaterEquilibriumSolution;
    }
    return result;
}

/// Projects a possibly signed, provisional H+/OH- pair onto the water
/// activity product while preserving its activity difference. Chemical
/// transformations are allowed to cross either free-ion inventory because
/// H+ and OH- are dependent coordinates joined by H2O dissociation; only the
/// projected thermodynamic state must be positive.
pub fn projectProvisional(
    provisional_hydrogen_concentration_mol_per_m3: f64,
    provisional_hydroxide_concentration_mol_per_m3: f64,
    monovalent_activity_coefficient: f64,
    water_activity_product_mol2_per_m6: f64,
) !Result {
    if (!std.math.isFinite(provisional_hydrogen_concentration_mol_per_m3) or
        !std.math.isFinite(provisional_hydroxide_concentration_mol_per_m3) or
        !std.math.isFinite(monovalent_activity_coefficient) or
        !std.math.isFinite(water_activity_product_mol2_per_m6))
        return error.NonFiniteWaterEquilibriumInput;
    if (monovalent_activity_coefficient <= 0 or
        water_activity_product_mol2_per_m6 <= 0)
        return error.InvalidWaterEquilibriumInput;

    const activity_difference = monovalent_activity_coefficient *
        (provisional_hydrogen_concentration_mol_per_m3 -
            provisional_hydroxide_concentration_mol_per_m3);
    const discriminant = std.math.hypot(
        activity_difference,
        2 * @sqrt(water_activity_product_mol2_per_m6),
    );
    const hydrogen_activity, const hydroxide_activity =
        if (activity_difference >= 0) .{
            0.5 * (activity_difference + discriminant),
            water_activity_product_mol2_per_m6 /
                (0.5 * (activity_difference + discriminant)),
        } else .{
            water_activity_product_mol2_per_m6 /
                (0.5 * (-activity_difference + discriminant)),
            0.5 * (-activity_difference + discriminant),
        };
    if (hydrogen_activity <= 0 or hydroxide_activity <= 0)
        return error.InvalidWaterEquilibriumSolution;
    return .{
        .hydrogen_concentration_mol_per_m3 = hydrogen_activity / monovalent_activity_coefficient,
        .hydroxide_concentration_mol_per_m3 = hydroxide_activity / monovalent_activity_coefficient,
        .hydrogen_activity_mol_per_m3 = hydrogen_activity,
        .hydroxide_activity_mol_per_m3 = hydroxide_activity,
        .equal_reaction_extent_mol_per_m3 = provisional_hydrogen_concentration_mol_per_m3 -
            hydrogen_activity / monovalent_activity_coefficient,
        .ph = -@log10(hydrogen_activity * 1e-3),
    };
}

/// Exact equation-order diagnostic for the final reset at SOLUTE.F
/// lines 2727--2746.
///
/// The source computes the equal extent from activities, then subtracts that
/// activity-space value directly from concentration-space transformation
/// totals. The returned published concentrations expose this dimensional
/// mismatch for attribution; production uses `solve`/`projectProvisional`.
pub fn calculateSourceOrderFinalReset(inputs: FinalResetInputs) !SourceOrderFinalReset {
    inline for (@typeInfo(FinalResetInputs).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(inputs, field.name)))
            return error.NonFiniteWaterEquilibriumInput;
    }
    if (inputs.initial_hydrogen_concentration_mol_per_m3 < 0 or
        inputs.initial_hydroxide_concentration_mol_per_m3 < 0 or
        inputs.monovalent_activity_coefficient <= 0 or
        inputs.water_activity_product_mol2_per_m6 <= 0 or
        inputs.negligible_concentration_mol_per_m3 < 0)
        return error.InvalidWaterEquilibriumInput;

    const provisional_hydrogen =
        inputs.initial_hydrogen_concentration_mol_per_m3 +
        inputs.accumulated_hydrogen_change_mol_per_m3;
    const provisional_hydroxide =
        inputs.initial_hydroxide_concentration_mol_per_m3 +
        inputs.accumulated_hydroxide_change_mol_per_m3;
    const hydrogen_activity = if (provisional_hydrogen >
        inputs.negligible_concentration_mol_per_m3)
        provisional_hydrogen * inputs.monovalent_activity_coefficient
    else
        provisional_hydrogen;
    const hydroxide_activity = if (provisional_hydroxide >
        inputs.negligible_concentration_mol_per_m3)
        provisional_hydroxide * inputs.monovalent_activity_coefficient
    else
        provisional_hydroxide;
    const activity_sum = hydrogen_activity + hydroxide_activity;
    const discriminant = @max(
        0,
        activity_sum * activity_sum -
            4 * (hydrogen_activity * hydroxide_activity -
                inputs.water_activity_product_mol2_per_m6),
    );
    const extent = 0.5 * (activity_sum - @sqrt(discriminant));
    const hydrogen_change =
        inputs.accumulated_hydrogen_change_mol_per_m3 - extent;
    const hydroxide_change =
        inputs.accumulated_hydroxide_change_mol_per_m3 - extent;
    const result = SourceOrderFinalReset{
        .hydrogen_activity_mol_per_m3 = hydrogen_activity - extent,
        .hydroxide_activity_mol_per_m3 = hydroxide_activity - extent,
        .equal_reaction_extent_activity_mol_per_m3 = extent,
        .accumulated_hydrogen_change_mol_per_m3 = hydrogen_change,
        .accumulated_hydroxide_change_mol_per_m3 = hydroxide_change,
        .water_balance_increment_mol_per_m3 = extent,
        .published_hydrogen_concentration_mol_per_m3 = inputs.initial_hydrogen_concentration_mol_per_m3 +
            hydrogen_change,
        .published_hydroxide_concentration_mol_per_m3 = inputs.initial_hydroxide_concentration_mol_per_m3 +
            hydroxide_change,
    };
    inline for (@typeInfo(SourceOrderFinalReset).@"struct".fields) |field| {
        if (!std.math.isFinite(@field(result, field.name)))
            return error.NonFiniteWaterEquilibriumSolution;
    }
    return result;
}

test {
    _ = @import("water_equilibrium_test.zig");
}

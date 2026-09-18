const std = @import("std");
const nutrient_uptake = @import("plant_root_nutrient_uptake.zig");

pub const SaltUptakeMol = struct {
    aluminum: f64 = 0,
    iron: f64 = 0,
    calcium: f64 = 0,
    magnesium: f64 = 0,
    sodium: f64 = 0,
    potassium: f64 = 0,
    sulfate: f64 = 0,
    chloride: f64 = 0,
};

/// GROSUB XZHYS before its available-H+ bound. Positive values produce H+;
/// negative values consume H+. The phosphate coefficients intentionally
/// preserve the source model's two equivalents for H2PO4 and one for HPO4.
pub fn hydrogenChargeMol(
    results: []const nutrient_uptake.Result,
    nitrogen_molar_mass_g_per_mol: f64,
    phosphorus_molar_mass_g_per_mol: f64,
    salts: SaltUptakeMol,
) !f64 {
    if (results.len != nutrient_uptake.nutrient_pool_count) return error.RootNutrientPoolCountMismatch;
    if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0 or
        !std.math.isFinite(phosphorus_molar_mass_g_per_mol) or phosphorus_molar_mass_g_per_mol <= 0)
        return error.InvalidRootIonMolarMass;
    inline for (@typeInfo(SaltUptakeMol).@"struct".fields) |field| {
        const value = @field(salts, field.name);
        if (!std.math.isFinite(value)) return error.NonFiniteRootSaltUptake;
    }
    for (results) |result| {
        inline for (@typeInfo(nutrient_uptake.Result).@"struct".fields) |field|
            if (!std.math.isFinite(@field(result, field.name)) or @field(result, field.name) < 0)
                return error.InvalidRootIonNutrientUptake;
    }

    const nh4_g_n = results[@intFromEnum(nutrient_uptake.NutrientPool.ammonium_nonband)].uptake_g_element +
        results[@intFromEnum(nutrient_uptake.NutrientPool.ammonium_band)].uptake_g_element;
    const no3_g_n = results[@intFromEnum(nutrient_uptake.NutrientPool.nitrate_nonband)].uptake_g_element +
        results[@intFromEnum(nutrient_uptake.NutrientPool.nitrate_band)].uptake_g_element;
    const h2po4_g_p = results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h2_nonband)].uptake_g_element +
        results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h2_band)].uptake_g_element;
    const hpo4_g_p = results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h_nonband)].uptake_g_element +
        results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h_band)].uptake_g_element;
    const charge = (nh4_g_n - no3_g_n) / nitrogen_molar_mass_g_per_mol -
        (2 * h2po4_g_p + hpo4_g_p) / phosphorus_molar_mass_g_per_mol +
        3 * (salts.aluminum + salts.iron) +
        2 * (salts.calcium + salts.magnesium) +
        salts.sodium + salts.potassium -
        2 * salts.sulfate - salts.chloride;
    if (!std.math.isFinite(charge)) return error.NonFiniteRootHydrogenCharge;
    return charge;
}

/// Direct grosub.f lines 5759--5767 compatibility equation. The decimal
/// coefficients and addition order are deliberately retained so comparison
/// against a trusted Fortran intermediate does not conflate translation with
/// the runtime-molar-mass formulation used by `hydrogenChargeMol`.
pub fn sourceOrderHydrogenChargeMol(
    results: []const nutrient_uptake.Result,
    salts: SaltUptakeMol,
) !f64 {
    _ = try hydrogenChargeMol(results, 14, 31, salts);
    const nh4_g_n = results[@intFromEnum(nutrient_uptake.NutrientPool.ammonium_nonband)].uptake_g_element +
        results[@intFromEnum(nutrient_uptake.NutrientPool.ammonium_band)].uptake_g_element;
    const no3_g_n = results[@intFromEnum(nutrient_uptake.NutrientPool.nitrate_nonband)].uptake_g_element +
        results[@intFromEnum(nutrient_uptake.NutrientPool.nitrate_band)].uptake_g_element;
    const h2po4_g_p = results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h2_nonband)].uptake_g_element +
        results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h2_band)].uptake_g_element;
    const hpo4_g_p = results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h_nonband)].uptake_g_element +
        results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h_band)].uptake_g_element;
    const charge = 0.0714 * nh4_g_n -
        0.0714 * no3_g_n -
        0.0645 * h2po4_g_p -
        0.0323 * hpo4_g_p +
        3.0 * (salts.aluminum + salts.iron) +
        2.0 * (salts.calcium + salts.magnesium) +
        salts.sodium + salts.potassium -
        2.0 * salts.sulfate - salts.chloride;
    if (!std.math.isFinite(charge)) return error.NonFiniteRootHydrogenCharge;
    return charge;
}

/// Replays GROSUB's domain-loop state_update into XZHYS. Each domain applies
/// the same `-ZHY*XNFH` floor independently; ZHY is not reduced inside this
/// loop. This comparator intentionally exposes that traversal-sensitive
/// behavior and must not be used as the production conservation guard.
pub fn sourceOrderBoundedHydrogenChargeMol(
    initial_charge_mol: f64,
    hydrogen_content_mol: f64,
    biological_timestep_h: f64,
    requested_charge_mol_by_domain: []const f64,
) !f64 {
    inline for (.{ initial_charge_mol, hydrogen_content_mol, biological_timestep_h }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootHydrogenStateUpdate;
    if (hydrogen_content_mol < 0 or biological_timestep_h < 0) return error.InvalidRootHydrogenStateUpdate;
    var charge_mol = initial_charge_mol;
    for (requested_charge_mol_by_domain) |requested_charge_mol| {
        if (!std.math.isFinite(requested_charge_mol)) return error.NonFiniteRootHydrogenStateUpdate;
        charge_mol += @max(-hydrogen_content_mol * biological_timestep_h, requested_charge_mol);
        if (!std.math.isFinite(charge_mol)) return error.NonFiniteRootHydrogenStateUpdate;
    }
    return charge_mol;
}

/// Publishes the hourly extensive charge into concentration state. Aggregating
/// all roots before this call prevents traversal-order-dependent H+ depletion.
pub fn state_updateHydrogenCharge(
    hydrogen_mol_per_m3: *f64,
    water_volume_m3: f64,
    requested_charge_mol: f64,
    time_fraction: f64,
) !f64 {
    inline for (.{ hydrogen_mol_per_m3.*, water_volume_m3, requested_charge_mol, time_fraction }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteRootHydrogenStateUpdate;
    if (hydrogen_mol_per_m3.* < 0 or water_volume_m3 <= 0 or time_fraction < 0 or time_fraction > 1)
        return error.InvalidRootHydrogenStateUpdate;
    const available_mol = hydrogen_mol_per_m3.* * water_volume_m3;
    const applied_mol = @max(-available_mol * time_fraction, requested_charge_mol);
    // Evaluate the conservative extensive remainder before converting back to
    // concentration.  The source floor proves this nonnegative; a negative
    // value is therefore an invalid transaction, not disposable roundoff.
    const remaining_mol = available_mol + applied_mol;
    const next = remaining_mol / water_volume_m3;
    if (!std.math.isFinite(next) or remaining_mol < 0 or next < 0) return error.InvalidRootHydrogenStateUpdate;
    hydrogen_mol_per_m3.* = next;
    return applied_mol;
}

test "GROSUB XZHYS preserves nutrient and eight-salt charge equivalents" {
    var results = [_]nutrient_uptake.Result{.{ .demand_g_element = 0, .uptake_g_element = 0, .oxygen_unlimited_uptake_g_element = 0, .carbon_unlimited_uptake_g_element = 0, .available_g_element = 0 }} ** nutrient_uptake.nutrient_pool_count;
    results[@intFromEnum(nutrient_uptake.NutrientPool.ammonium_nonband)].uptake_g_element = 14;
    results[@intFromEnum(nutrient_uptake.NutrientPool.nitrate_band)].uptake_g_element = 7;
    results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h2_nonband)].uptake_g_element = 31;
    results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h_band)].uptake_g_element = 15.5;
    const salts: SaltUptakeMol = .{ .aluminum = 1, .iron = 2, .calcium = 3, .magnesium = 4, .sodium = 5, .potassium = 6, .sulfate = 7, .chloride = 8 };
    const expected = 1.0 - 0.5 - 2.0 - 0.5 + 3.0 * 3.0 + 2.0 * 7.0 + 5.0 + 6.0 - 2.0 * 7.0 - 8.0;
    try std.testing.expectApproxEqAbs(expected, try hydrogenChargeMol(&results, 14, 31, salts), 1.0e-12);
}

test "GROSUB XZHYS source comparator retains literal conversion coefficients" {
    var results = [_]nutrient_uptake.Result{.{ .demand_g_element = 0, .uptake_g_element = 0, .oxygen_unlimited_uptake_g_element = 0, .carbon_unlimited_uptake_g_element = 0, .available_g_element = 0 }} ** nutrient_uptake.nutrient_pool_count;
    results[@intFromEnum(nutrient_uptake.NutrientPool.ammonium_nonband)].uptake_g_element = 14;
    results[@intFromEnum(nutrient_uptake.NutrientPool.nitrate_band)].uptake_g_element = 7;
    results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h2_nonband)].uptake_g_element = 31;
    results[@intFromEnum(nutrient_uptake.NutrientPool.phosphate_h_band)].uptake_g_element = 15.5;
    const salts: SaltUptakeMol = .{};
    const source = 0.0714 * 14 - 0.0714 * 7 - 0.0645 * 31 - 0.0323 * 15.5;
    try std.testing.expectEqual(source, try sourceOrderHydrogenChargeMol(&results, salts));
    try std.testing.expect(@abs(source - try hydrogenChargeMol(&results, 14, 31, salts)) > 1.0e-6);
}

test "root ion balance bounds aggregate hydrogen consumption" {
    var hydrogen: f64 = 0.2;
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), try state_updateHydrogenCharge(&hydrogen, 2, -1, 0.5), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), hydrogen, 1.0e-12);
}

test "GROSUB per-domain hydrogen floor can exceed the aggregate available pool" {
    const requests = [_]f64{ -1, -1 };
    const source_charge = try sourceOrderBoundedHydrogenChargeMol(0, 0.2, 1, &requests);
    try std.testing.expectApproxEqAbs(@as(f64, -0.4), source_charge, 1.0e-12);

    var production_hydrogen_mol_per_m3: f64 = 0.1;
    const production_charge = try state_updateHydrogenCharge(&production_hydrogen_mol_per_m3, 2, requests[0] + requests[1], 1);
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), production_charge, 1.0e-12);
    try std.testing.expectEqual(@as(f64, 0), production_hydrogen_mol_per_m3);
}

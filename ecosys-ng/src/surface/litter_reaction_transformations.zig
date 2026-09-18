const std = @import("std");
const phosphate_exchange = @import("../soil/solute/phosphate_exchange.zig");

pub const ExchangeAdsorption = struct {
    ammonium_mol_per_megagram: f64,
    hydrogen_mol_per_megagram: f64,
    aluminum_mol_per_megagram: f64,
    iron_mol_per_megagram: f64,
    calcium_mol_per_megagram: f64,
    magnesium_mol_per_megagram: f64,
    sodium_mol_per_megagram: f64,
    potassium_mol_per_megagram: f64,
};

pub const PhosphateMineralExtents = struct {
    aluminum_phosphate_mol_per_m3: f64,
    iron_phosphate_mol_per_m3: f64,
    dicalcium_phosphate_mol_per_m3: f64,
    hydroxyapatite_mol_per_m3: f64,
    monocalcium_phosphate_mol_per_m3: f64,
};

pub const PhosphateSurfaceState = struct {
    deprotonated_site_mol_per_megagram: f64,
    hydroxyl_site_mol_per_megagram: f64,
    protonated_site_mol_per_megagram: f64,
    adsorbed_hpo4_mol_p_per_megagram: f64,
    adsorbed_h2po4_mol_p_per_megagram: f64,
};

pub const SaltMineralExtents = struct {
    gibbsite_mol_per_m3: f64,
    iron_hydroxide_mol_per_m3: f64,
    calcite_mol_per_m3: f64,
    gypsum_mol_per_m3: f64,
};

pub const ReactionExtents = struct {
    water_ion_recombination_mol_per_m3: f64,
    ammonium_association_mol_per_m3: f64,
    h2po4_association_mol_p_per_m3: f64,
    bicarbonate_hydrogen_association_mol_per_m3: f64,
    carbonate_hydrogen_association_mol_per_m3: f64,
    carboxyl_hydrogen_adsorption_mol_per_megagram: f64,
    external_hydrogen_mol_per_m3: f64,
    exchange: ExchangeAdsorption,
    phosphate_surface: phosphate_exchange.Flux = .{
        .protonated_to_hydroxyl_site_mol_per_megagram = 0,
        .hydroxyl_to_deprotonated_site_mol_per_megagram = 0,
        .h2po4_with_protonated_site_mol_p_per_megagram = 0,
        .h2po4_with_hydroxyl_site_mol_p_per_megagram = 0,
        .hpo4_with_hydroxyl_site_mol_p_per_megagram = 0,
    },
    phosphate_minerals: PhosphateMineralExtents,
    salt_minerals: SaltMineralExtents,
};

pub const Transformations = struct {
    ammonium_mol_per_m3: f64,
    ammonia_mol_per_m3: f64,
    nitrate_mol_per_m3: f64,
    chloride_mol_per_m3: f64,
    hpo4_mol_p_per_m3: f64,
    h2po4_mol_p_per_m3: f64,
    hydrogen_mol_per_m3: f64,
    hydroxide_mol_per_m3: f64,
    aluminum_mol_per_m3: f64,
    iron_mol_per_m3: f64,
    calcium_mol_per_m3: f64,
    magnesium_mol_per_m3: f64,
    sodium_mol_per_m3: f64,
    potassium_mol_per_m3: f64,
    carbonate_mol_per_m3: f64,
    bicarbonate_mol_per_m3: f64,
    carbon_dioxide_mol_per_m3: f64,
    sulfate_mol_per_m3: f64,
    water_mol_per_m3: f64,
    carboxyl_hydrogen_mol_per_megagram: f64,
    exchange: ExchangeAdsorption,
    phosphate_surface: PhosphateSurfaceState,
    phosphate_minerals: PhosphateMineralExtents,
    salt_minerals: SaltMineralExtents,
};

/// Exact surface-litter `TOTAL ION TRANSFORMATIONS` ledger in SOLUTE.F.
/// Positive exchange values move ions from litter water to exchange sites;
/// positive mineral values precipitate dissolved ions.
pub fn assemble(extents: ReactionExtents, litter_mass_per_water_volume_megagrams_per_m3: f64, dynamic_salts: bool) !Transformations {
    try validate(extents, litter_mass_per_water_volume_megagrams_per_m3);
    const x = extents.exchange;
    const p = extents.phosphate_minerals;
    const q = extents.phosphate_surface;
    const s = extents.salt_minerals;
    const density = litter_mass_per_water_volume_megagrams_per_m3;

    var result = Transformations{
        .ammonium_mol_per_m3 = extents.ammonium_association_mol_per_m3 - x.ammonium_mol_per_megagram * density,
        .ammonia_mol_per_m3 = -extents.ammonium_association_mol_per_m3,
        .nitrate_mol_per_m3 = 0,
        .chloride_mol_per_m3 = 0,
        .hpo4_mol_p_per_m3 = -extents.h2po4_association_mol_p_per_m3 - q.hpo4_with_hydroxyl_site_mol_p_per_megagram * density,
        .h2po4_mol_p_per_m3 = extents.h2po4_association_mol_p_per_m3 - p.aluminum_phosphate_mol_per_m3 - p.iron_phosphate_mol_per_m3 - p.dicalcium_phosphate_mol_per_m3 - 2 * p.monocalcium_phosphate_mol_per_m3 - 3 * p.hydroxyapatite_mol_per_m3 - (q.h2po4_with_protonated_site_mol_p_per_megagram + q.h2po4_with_hydroxyl_site_mol_p_per_megagram) * density,
        .hydrogen_mol_per_m3 = -x.hydrogen_mol_per_megagram * density - extents.water_ion_recombination_mol_per_m3 - (q.protonated_to_hydroxyl_site_mol_per_megagram + q.hydroxyl_to_deprotonated_site_mol_per_megagram) * density,
        .hydroxide_mol_per_m3 = -extents.water_ion_recombination_mol_per_m3 + (q.h2po4_with_hydroxyl_site_mol_p_per_megagram + q.hpo4_with_hydroxyl_site_mol_p_per_megagram) * density,
        .aluminum_mol_per_m3 = -x.aluminum_mol_per_megagram * density,
        .iron_mol_per_m3 = -x.iron_mol_per_megagram * density,
        .calcium_mol_per_m3 = -x.calcium_mol_per_megagram * density,
        .magnesium_mol_per_m3 = -x.magnesium_mol_per_megagram * density,
        .sodium_mol_per_m3 = -x.sodium_mol_per_megagram * density,
        .potassium_mol_per_m3 = -x.potassium_mol_per_megagram * density,
        .carbonate_mol_per_m3 = 0,
        .bicarbonate_mol_per_m3 = 0,
        .carbon_dioxide_mol_per_m3 = 0,
        .sulfate_mol_per_m3 = 0,
        .water_mol_per_m3 = if (dynamic_salts)
            extents.water_ion_recombination_mol_per_m3 + q.h2po4_with_protonated_site_mol_p_per_megagram * density
        else
            0,
        .carboxyl_hydrogen_mol_per_megagram = if (dynamic_salts) extents.carboxyl_hydrogen_adsorption_mol_per_megagram else 0,
        .exchange = x,
        .phosphate_surface = .{
            .deprotonated_site_mol_per_megagram = -q.hydroxyl_to_deprotonated_site_mol_per_megagram,
            .hydroxyl_site_mol_per_megagram = q.hydroxyl_to_deprotonated_site_mol_per_megagram - q.protonated_to_hydroxyl_site_mol_per_megagram - q.h2po4_with_hydroxyl_site_mol_p_per_megagram - q.hpo4_with_hydroxyl_site_mol_p_per_megagram,
            .protonated_site_mol_per_megagram = q.protonated_to_hydroxyl_site_mol_per_megagram - q.h2po4_with_protonated_site_mol_p_per_megagram,
            .adsorbed_hpo4_mol_p_per_megagram = q.hpo4_with_hydroxyl_site_mol_p_per_megagram,
            .adsorbed_h2po4_mol_p_per_megagram = q.h2po4_with_protonated_site_mol_p_per_megagram + q.h2po4_with_hydroxyl_site_mol_p_per_megagram,
        },
        .phosphate_minerals = p,
        .salt_minerals = if (dynamic_salts) s else zeroSaltMinerals(),
    };

    if (dynamic_salts) {
        result.hydrogen_mol_per_m3 += extents.external_hydrogen_mol_per_m3 - extents.carboxyl_hydrogen_adsorption_mol_per_megagram * density - extents.bicarbonate_hydrogen_association_mol_per_m3 - extents.carbonate_hydrogen_association_mol_per_m3 + 2 * (p.aluminum_phosphate_mol_per_m3 + p.iron_phosphate_mol_per_m3) + p.dicalcium_phosphate_mol_per_m3 + 6 * p.hydroxyapatite_mol_per_m3 - extents.h2po4_association_mol_p_per_m3 - extents.ammonium_association_mol_per_m3;
        result.hydroxide_mol_per_m3 -= p.hydroxyapatite_mol_per_m3;
        result.aluminum_mol_per_m3 -= p.aluminum_phosphate_mol_per_m3;
        result.iron_mol_per_m3 -= p.iron_phosphate_mol_per_m3;
        result.calcium_mol_per_m3 -= p.dicalcium_phosphate_mol_per_m3 + 5 * p.hydroxyapatite_mol_per_m3 + p.monocalcium_phosphate_mol_per_m3;
        result.carbonate_mol_per_m3 = -extents.carbonate_hydrogen_association_mol_per_m3;
        result.bicarbonate_mol_per_m3 = -extents.bicarbonate_hydrogen_association_mol_per_m3 + extents.carbonate_hydrogen_association_mol_per_m3;
        result.carbon_dioxide_mol_per_m3 = extents.bicarbonate_hydrogen_association_mol_per_m3;

        result.aluminum_mol_per_m3 -= s.gibbsite_mol_per_m3;
        result.iron_mol_per_m3 -= s.iron_hydroxide_mol_per_m3;
        result.calcium_mol_per_m3 -= s.calcite_mol_per_m3 + s.gypsum_mol_per_m3;
        result.hydroxide_mol_per_m3 -= 3 * (s.gibbsite_mol_per_m3 + s.iron_hydroxide_mol_per_m3);
        result.carbonate_mol_per_m3 -= s.calcite_mol_per_m3;
        result.sulfate_mol_per_m3 -= s.gypsum_mol_per_m3;
        result.water_mol_per_m3 += extents.bicarbonate_hydrogen_association_mol_per_m3;
    } else {
        // The source fixed-pH branch treats H+, OH-, and solvent water as an
        // external buffer. Reactions still transform ammonium, phosphate,
        // exchange sites, and minerals, but cannot deplete those placeholder
        // aqueous inventories.
        result.hydrogen_mol_per_m3 = 0;
        result.hydroxide_mol_per_m3 = 0;
    }
    return result;
}

fn validate(extents: ReactionExtents, density: f64) !void {
    if (!std.math.isFinite(density) or density <= 0) return error.InvalidLitterMassWaterRatio;
    inline for (@typeInfo(ReactionExtents).@"struct".fields) |field| {
        const Field = field.type;
        switch (@typeInfo(Field)) {
            .float => if (!std.math.isFinite(@field(extents, field.name))) return error.NonFiniteLitterReactionExtent,
            .@"struct" => inline for (@typeInfo(Field).@"struct".fields) |nested|
                if (!std.math.isFinite(@field(@field(extents, field.name), nested.name))) return error.NonFiniteLitterReactionExtent,
            else => unreachable,
        }
    }
}

fn zeroSaltMinerals() SaltMineralExtents {
    return .{ .gibbsite_mol_per_m3 = 0, .iron_hydroxide_mol_per_m3 = 0, .calcite_mol_per_m3 = 0, .gypsum_mol_per_m3 = 0 };
}

fn zeroExchange() ExchangeAdsorption {
    return .{ .ammonium_mol_per_megagram = 0, .hydrogen_mol_per_megagram = 0, .aluminum_mol_per_megagram = 0, .iron_mol_per_megagram = 0, .calcium_mol_per_megagram = 0, .magnesium_mol_per_megagram = 0, .sodium_mol_per_megagram = 0, .potassium_mol_per_megagram = 0 };
}

test "litter ammonium and phosphate ledger matches SOLUTE stoichiometry" {
    const result = try assemble(.{
        .water_ion_recombination_mol_per_m3 = 0,
        .ammonium_association_mol_per_m3 = 2,
        .h2po4_association_mol_p_per_m3 = 3,
        .bicarbonate_hydrogen_association_mol_per_m3 = 0,
        .carbonate_hydrogen_association_mol_per_m3 = 0,
        .carboxyl_hydrogen_adsorption_mol_per_megagram = 0,
        .external_hydrogen_mol_per_m3 = 0,
        .exchange = zeroExchange(),
        .phosphate_minerals = .{ .aluminum_phosphate_mol_per_m3 = 0.1, .iron_phosphate_mol_per_m3 = 0.2, .dicalcium_phosphate_mol_per_m3 = 0.3, .hydroxyapatite_mol_per_m3 = 0.4, .monocalcium_phosphate_mol_per_m3 = 0.5 },
        .salt_minerals = zeroSaltMinerals(),
    }, 4, true);
    try std.testing.expectEqual(@as(f64, 2), result.ammonium_mol_per_m3);
    try std.testing.expectEqual(@as(f64, -2), result.ammonia_mol_per_m3);
    const phosphorus = result.hpo4_mol_p_per_m3 + result.h2po4_mol_p_per_m3 + 0.1 + 0.2 + 0.3 + 3 * 0.4 + 2 * 0.5;
    try std.testing.expectApproxEqAbs(@as(f64, 0), phosphorus, 1e-14);
}

test "fixed-pH formulation excludes salt-only reactions" {
    var extents = ReactionExtents{
        .water_ion_recombination_mol_per_m3 = 0,
        .ammonium_association_mol_per_m3 = 0,
        .h2po4_association_mol_p_per_m3 = 0,
        .bicarbonate_hydrogen_association_mol_per_m3 = 2,
        .carbonate_hydrogen_association_mol_per_m3 = 3,
        .carboxyl_hydrogen_adsorption_mol_per_megagram = 4,
        .external_hydrogen_mol_per_m3 = 5,
        .exchange = zeroExchange(),
        .phosphate_minerals = .{ .aluminum_phosphate_mol_per_m3 = 0, .iron_phosphate_mol_per_m3 = 0, .dicalcium_phosphate_mol_per_m3 = 0, .hydroxyapatite_mol_per_m3 = 0, .monocalcium_phosphate_mol_per_m3 = 0 },
        .salt_minerals = .{ .gibbsite_mol_per_m3 = 1, .iron_hydroxide_mol_per_m3 = 1, .calcite_mol_per_m3 = 1, .gypsum_mol_per_m3 = 1 },
    };
    const result = try assemble(extents, 2, false);
    try std.testing.expectEqual(@as(f64, 0), result.carbon_dioxide_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), result.salt_minerals.calcite_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), result.hydrogen_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), result.water_mol_per_m3);
    extents.exchange.hydrogen_mol_per_megagram = 0.5;
    const exchange_only = try assemble(extents, 2, false);
    try std.testing.expectEqual(@as(f64, 0), exchange_only.hydrogen_mol_per_m3);
}

test "carboxyl hydrogen has its own exchange inventory" {
    var extents: ReactionExtents = undefined;
    inline for (@typeInfo(ReactionExtents).@"struct".fields) |field| switch (@typeInfo(field.type)) {
        .float => @field(extents, field.name) = 0,
        .@"struct" => {
            inline for (@typeInfo(field.type).@"struct".fields) |nested| @field(@field(extents, field.name), nested.name) = 0;
        },
        else => unreachable,
    };
    extents.carboxyl_hydrogen_adsorption_mol_per_megagram = 0.25;
    const result = try assemble(extents, 4, true);
    try std.testing.expectEqual(@as(f64, 0.25), result.carboxyl_hydrogen_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, -1), result.hydrogen_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 0), result.exchange.hydrogen_mol_per_megagram);
}

test "surface phosphate exchange conserves phosphorus and site inventory" {
    var extents = std.mem.zeroes(ReactionExtents);
    extents.phosphate_surface = .{
        .protonated_to_hydroxyl_site_mol_per_megagram = 0.01,
        .hydroxyl_to_deprotonated_site_mol_per_megagram = 0.02,
        .h2po4_with_protonated_site_mol_p_per_megagram = 0.03,
        .h2po4_with_hydroxyl_site_mol_p_per_megagram = 0.04,
        .hpo4_with_hydroxyl_site_mol_p_per_megagram = 0.05,
    };
    const density: f64 = 2;
    const changes = try assemble(extents, density, true);
    const aqueous_p = changes.hpo4_mol_p_per_m3 + changes.h2po4_mol_p_per_m3;
    const adsorbed_p = density * (changes.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram + changes.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram);
    const site_change = changes.phosphate_surface.deprotonated_site_mol_per_megagram + changes.phosphate_surface.hydroxyl_site_mol_per_megagram + changes.phosphate_surface.protonated_site_mol_per_megagram + changes.phosphate_surface.adsorbed_hpo4_mol_p_per_megagram + changes.phosphate_surface.adsorbed_h2po4_mol_p_per_megagram;
    try std.testing.expectApproxEqAbs(@as(f64, 0), aqueous_p + adsorbed_p, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0), site_change, 1e-15);
}

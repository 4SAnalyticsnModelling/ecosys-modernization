const std = @import("std");

/// Fixed scientific species identity from TRNSFRS.F. Grid, layer, face, and
/// state extents remain runtime values; this enum prevents anonymous indices
/// from silently applying the wrong diffusivity or fertilizer-zone fraction.
pub const AqueousSpecies = enum(u8) {
    aluminum,
    iron,
    hydrogen,
    calcium,
    magnesium,
    sodium,
    potassium,
    hydroxide,
    sulfate,
    chloride,
    carbonate,
    bicarbonate,
    aluminum_hydroxide_1,
    aluminum_hydroxide_2,
    aluminum_hydroxide_3,
    aluminum_hydroxide_4,
    aluminum_sulfate,
    iron_hydroxide_1,
    iron_hydroxide_2,
    iron_hydroxide_3,
    iron_hydroxide_4,
    iron_sulfate,
    calcium_hydroxide,
    calcium_carbonate,
    calcium_bicarbonate,
    calcium_sulfate,
    magnesium_hydroxide,
    magnesium_carbonate,
    magnesium_bicarbonate,
    magnesium_sulfate,
    sodium_carbonate,
    sodium_sulfate,
    potassium_sulfate,
    hydrogen_silicate,
    non_band_phosphate,
    non_band_phosphoric_acid,
    non_band_iron_hpo4,
    non_band_iron_h2po4,
    non_band_calcium_phosphate,
    non_band_calcium_hpo4,
    non_band_calcium_h2po4,
    non_band_magnesium_hpo4,
    band_phosphate,
    band_phosphoric_acid,
    band_iron_hpo4,
    band_iron_h2po4,
    band_calcium_phosphate,
    band_calcium_hpo4,
    band_calcium_h2po4,
    band_magnesium_hpo4,
    // Appended to preserve the established 0..49 layout consumed by the
    // snow/litter compatibility adapters and existing checkpoints.
    non_band_hpo4,
    non_band_h2po4,
    band_hpo4,
    band_h2po4,

    pub const count = @typeInfo(AqueousSpecies).@"enum".fields.len;
};

pub const DiffusivityClass = enum(u8) {
    phosphate,
    aluminum,
    iron,
    hydrogen,
    calcium,
    magnesium,
    sodium,
    potassium,
    hydroxide,
    sulfate,
    chloride,
    carbonate,
    bicarbonate,
    hydrogen_silicate,
};

pub const DiffusiveConductance = struct {
    phosphate_m3_per_step: f64,
    aluminum_m3_per_step: f64,
    iron_m3_per_step: f64,
    hydrogen_m3_per_step: f64,
    calcium_m3_per_step: f64,
    magnesium_m3_per_step: f64,
    sodium_m3_per_step: f64,
    potassium_m3_per_step: f64,
    hydroxide_m3_per_step: f64,
    sulfate_m3_per_step: f64,
    chloride_m3_per_step: f64,
    carbonate_m3_per_step: f64,
    bicarbonate_m3_per_step: f64,
    hydrogen_silicate_m3_per_step: f64,
};

pub const ZoneFractions = struct {
    phosphate_non_band: f64,
    phosphate_band: f64,
};

pub fn index(species: AqueousSpecies) usize {
    return @intFromEnum(species);
}

/// Fraction of matrix water occupied by this chemistry coordinate. Runtime
/// transport amounts are physical, zone-extensive moles (`C * water * f`),
/// so the fraction belongs in the concentration bridge rather than being
/// applied a second time to an already extensive amount.
pub fn zoneFraction(species: AqueousSpecies, fractions: ZoneFractions) f64 {
    return switch (species) {
        .non_band_phosphate, .non_band_hpo4, .non_band_h2po4, .non_band_phosphoric_acid, .non_band_iron_hpo4, .non_band_iron_h2po4, .non_band_calcium_phosphate, .non_band_calcium_hpo4, .non_band_calcium_h2po4, .non_band_magnesium_hpo4 => fractions.phosphate_non_band,
        .band_phosphate, .band_hpo4, .band_h2po4, .band_phosphoric_acid, .band_iron_hpo4, .band_iron_h2po4, .band_calcium_phosphate, .band_calcium_hpo4, .band_calcium_h2po4, .band_magnesium_hpo4 => fractions.phosphate_band,
        else => 1,
    };
}

/// Transport inventories are already physical extensive amounts. Applying a
/// second band/non-band factor at a face would produce `f^2` transport.
pub fn transportMobilityFraction(species: AqueousSpecies, fractions: ZoneFractions) f64 {
    _ = species;
    _ = fractions;
    return 1;
}

/// REDIST `SSS`/`SSH` pseudo-ion inventory coefficient for one mole of an
/// aqueous carrier. Oxygen is deliberately excluded by the source balance;
/// the coefficient is nevertheless conservative across acid dissociation and
/// complex formation when both storage and boundary flux use this same map.
pub fn legacyIonCount(species: AqueousSpecies) f64 {
    return switch (species) {
        .aluminum,
        .iron,
        .hydrogen,
        .calcium,
        .magnesium,
        .sodium,
        .potassium,
        .hydroxide,
        .sulfate,
        .chloride,
        .carbonate,
        .non_band_phosphate,
        .band_phosphate,
        => 1,
        .bicarbonate,
        .aluminum_hydroxide_1,
        .aluminum_sulfate,
        .iron_hydroxide_1,
        .iron_sulfate,
        .calcium_hydroxide,
        .calcium_carbonate,
        .calcium_sulfate,
        .magnesium_hydroxide,
        .magnesium_carbonate,
        .magnesium_sulfate,
        .sodium_carbonate,
        .sodium_sulfate,
        .potassium_sulfate,
        .non_band_calcium_phosphate,
        .band_calcium_phosphate,
        .non_band_hpo4,
        .band_hpo4,
        => 2,
        .aluminum_hydroxide_2,
        .iron_hydroxide_2,
        .calcium_bicarbonate,
        .magnesium_bicarbonate,
        .non_band_iron_hpo4,
        .non_band_calcium_hpo4,
        .non_band_magnesium_hpo4,
        .band_iron_hpo4,
        .band_calcium_hpo4,
        .band_magnesium_hpo4,
        .non_band_h2po4,
        .band_h2po4,
        => 3,
        .aluminum_hydroxide_3,
        .iron_hydroxide_3,
        .hydrogen_silicate,
        .non_band_phosphoric_acid,
        .non_band_iron_h2po4,
        .non_band_calcium_h2po4,
        .band_phosphoric_acid,
        .band_iron_h2po4,
        .band_calcium_h2po4,
        => 4,
        .aluminum_hydroxide_4,
        .iron_hydroxide_4,
        => 5,
    };
}

/// Reduces source-signed external transport fluxes to the same REDIST
/// pseudo-ion basis as inventory. Negative flux leaves the domain; positive
/// flux is an input and is intentionally excluded from this outflow reducer.
pub fn legacyBoundaryIonOutflow(net_flux_mol: []const f64) !f64 {
    return legacyBoundaryIonDirection(net_flux_mol, false);
}

/// Reduces positive source-signed external recharge to the same REDIST
/// pseudo-ion basis as inventory. Discharge is intentionally excluded.
pub fn legacyBoundaryIonInput(net_flux_mol: []const f64) !f64 {
    return legacyBoundaryIonDirection(net_flux_mol, true);
}

fn legacyBoundaryIonDirection(net_flux_mol: []const f64, input: bool) !f64 {
    if (net_flux_mol.len == 0 or net_flux_mol.len % AqueousSpecies.count != 0)
        return error.TransportSpeciesCountMismatch;
    var total: f64 = 0;
    for (net_flux_mol, 0..) |flux_mol, component| {
        if (!std.math.isFinite(flux_mol)) return error.NonFiniteTransportBoundaryFlux;
        if ((input and flux_mol <= 0) or (!input and flux_mol >= 0)) continue;
        const species: AqueousSpecies = @enumFromInt(component % AqueousSpecies.count);
        total += @abs(flux_mol) * legacyIonCount(species);
        if (!std.math.isFinite(total)) return error.NonFiniteTransportBoundaryFlux;
    }
    return total;
}

pub fn diffusivityClass(species: AqueousSpecies) DiffusivityClass {
    return switch (species) {
        .aluminum, .aluminum_hydroxide_1, .aluminum_hydroxide_2, .aluminum_hydroxide_3, .aluminum_hydroxide_4, .aluminum_sulfate => .aluminum,
        .iron, .iron_hydroxide_1, .iron_hydroxide_2, .iron_hydroxide_3, .iron_hydroxide_4, .iron_sulfate => .iron,
        .hydrogen => .hydrogen,
        .calcium, .calcium_hydroxide, .calcium_carbonate, .calcium_bicarbonate, .calcium_sulfate => .calcium,
        .magnesium, .magnesium_hydroxide, .magnesium_carbonate, .magnesium_bicarbonate, .magnesium_sulfate => .magnesium,
        .sodium, .sodium_carbonate, .sodium_sulfate => .sodium,
        .potassium, .potassium_sulfate => .potassium,
        .hydroxide => .hydroxide,
        .sulfate => .sulfate,
        .chloride => .chloride,
        .carbonate => .carbonate,
        .bicarbonate => .bicarbonate,
        .hydrogen_silicate => .hydrogen_silicate,
        .non_band_phosphate, .non_band_hpo4, .non_band_h2po4, .non_band_phosphoric_acid, .non_band_iron_hpo4, .non_band_iron_h2po4, .non_band_calcium_phosphate, .non_band_calcium_hpo4, .non_band_calcium_h2po4, .non_band_magnesium_hpo4, .band_phosphate, .band_hpo4, .band_h2po4, .band_phosphoric_acid, .band_iron_hpo4, .band_iron_h2po4, .band_calcium_phosphate, .band_calcium_hpo4, .band_calcium_h2po4, .band_magnesium_hpo4 => .phosphate,
    };
}

pub fn fillFaceParameters(conductance: DiffusiveConductance, fractions: ZoneFractions, output_conductance_m3_per_step: []f64, output_mobility_fraction: []f64) !void {
    if (output_conductance_m3_per_step.len != AqueousSpecies.count or output_mobility_fraction.len != AqueousSpecies.count) return error.TransportSpeciesCountMismatch;
    try validate(conductance, fractions);
    inline for (@typeInfo(AqueousSpecies).@"enum".fields) |field| {
        const species: AqueousSpecies = @enumFromInt(field.value);
        output_conductance_m3_per_step[index(species)] = conductanceForClass(conductance, diffusivityClass(species));
        output_mobility_fraction[index(species)] = transportMobilityFraction(species, fractions);
    }
}

fn conductanceForClass(values: DiffusiveConductance, class: DiffusivityClass) f64 {
    return switch (class) {
        .phosphate => values.phosphate_m3_per_step,
        .aluminum => values.aluminum_m3_per_step,
        .iron => values.iron_m3_per_step,
        .hydrogen => values.hydrogen_m3_per_step,
        .calcium => values.calcium_m3_per_step,
        .magnesium => values.magnesium_m3_per_step,
        .sodium => values.sodium_m3_per_step,
        .potassium => values.potassium_m3_per_step,
        .hydroxide => values.hydroxide_m3_per_step,
        .sulfate => values.sulfate_m3_per_step,
        .chloride => values.chloride_m3_per_step,
        .carbonate => values.carbonate_m3_per_step,
        .bicarbonate => values.bicarbonate_m3_per_step,
        .hydrogen_silicate => values.hydrogen_silicate_m3_per_step,
    };
}

fn validate(conductance: DiffusiveConductance, fractions: ZoneFractions) !void {
    inline for (@typeInfo(DiffusiveConductance).@"struct".fields) |field| if (!std.math.isFinite(@field(conductance, field.name)) or @field(conductance, field.name) < 0) return error.InvalidTransportConductance;
    inline for (@typeInfo(ZoneFractions).@"struct".fields) |field| if (!std.math.isFinite(@field(fractions, field.name)) or @field(fractions, field.name) < 0 or @field(fractions, field.name) > 1) return error.InvalidTransportZoneFraction;
}

test "all named TRNSFRS species receive conductance and mobility" {
    var conductance: [AqueousSpecies.count]f64 = undefined;
    var mobility: [AqueousSpecies.count]f64 = undefined;
    try fillFaceParameters(.{ .phosphate_m3_per_step = 2, .aluminum_m3_per_step = 3, .iron_m3_per_step = 4, .hydrogen_m3_per_step = 5, .calcium_m3_per_step = 6, .magnesium_m3_per_step = 7, .sodium_m3_per_step = 8, .potassium_m3_per_step = 9, .hydroxide_m3_per_step = 10, .sulfate_m3_per_step = 11, .chloride_m3_per_step = 12, .carbonate_m3_per_step = 13, .bicarbonate_m3_per_step = 14, .hydrogen_silicate_m3_per_step = 15 }, .{ .phosphate_non_band = 0.7, .phosphate_band = 0.3 }, &conductance, &mobility);
    try std.testing.expectEqual(@as(f64, 3), conductance[index(.aluminum_hydroxide_4)]);
    try std.testing.expectEqual(@as(f64, 6), conductance[index(.calcium_bicarbonate)]);
    try std.testing.expectEqual(@as(f64, 2), conductance[index(.band_iron_hpo4)]);
    try std.testing.expectEqual(@as(f64, 2), conductance[index(.non_band_hpo4)]);
    try std.testing.expectEqual(@as(f64, 2), conductance[index(.band_h2po4)]);
    try std.testing.expectEqual(@as(f64, 1), mobility[index(.sulfate)]);
    try std.testing.expectEqual(@as(f64, 1), mobility[index(.non_band_calcium_hpo4)]);
    try std.testing.expectEqual(@as(f64, 1), mobility[index(.non_band_h2po4)]);
    try std.testing.expectEqual(@as(f64, 1), mobility[index(.band_magnesium_hpo4)]);
    try std.testing.expectEqual(@as(f64, 1), mobility[index(.band_hpo4)]);
}

test "boundary ion outflow uses the exact inventory coefficient map" {
    var flux = [_]f64{0} ** AqueousSpecies.count;
    flux[index(.aluminum)] = -2;
    flux[index(.aluminum_hydroxide_4)] = -3;
    flux[index(.non_band_hpo4)] = -5;
    flux[index(.band_h2po4)] = -7;
    flux[index(.calcium)] = 11; // domain input is not an outflow
    try std.testing.expectEqual(@as(f64, 48), try legacyBoundaryIonOutflow(&flux));
    try std.testing.expectEqual(@as(f64, 11), try legacyBoundaryIonInput(&flux));
    flux[index(.iron)] = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteTransportBoundaryFlux, legacyBoundaryIonOutflow(&flux));
}

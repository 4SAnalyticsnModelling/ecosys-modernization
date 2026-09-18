//! STARTE 1642--1662 natural-silicate initialization.
//!
//! Production binds this before initial chemistry equilibration. The source
//! stores extensive Q*SI mol; runtime geochemistry stores mol per matrix-water
//! m3, so `initializePerWaterVolume` performs the explicit carrier conversion.
//! Aluminum and iron are seeded at every pH, Ca/Mg/Na/K only above pH 4.5, and
//! all six ground-rock pools start at zero exactly as in STARTE.

const std = @import("std");

pub const ProfileSource = enum { atmospheric_equilibrium, supplied_profile };
pub const Control = struct { profile_source: ProfileSource, gas_initialization_index: usize };

pub const Texture = struct {
    // Runtime profiles retain the dimensionless CSAND/CSILT/CCLAY values that
    // STARTE consumes. READI first reads kg Mg-1 and multiplies by 1e-3
    // (`readi.f` 638--643); the nearby legacy "g Mg-1" comment is inconsistent
    // with both that conversion and all downstream uses of these variables.
    sand_mass_fraction: f64,
    silt_mass_fraction: f64,
    clay_mass_fraction: f64,
};

pub const ElementInventories = struct {
    aluminum_mol: f64,
    iron_mol: f64,
    calcium_mol: f64,
    magnesium_mol: f64,
    sodium_mol: f64,
    potassium_mol: f64,
};

pub const Inventories = struct {
    mineral_surface_area_m2: f64, // SSAL
    soil_silicates: ElementInventories, // Q*SI
    ground_rock_silicates: ElementInventories, // Q*SIF
};

pub const Concentrations = struct {
    soil_silicates_mol_per_m3: ElementInventories,
    ground_rock_silicates_mol_per_m3: ElementInventories,
};

fn zeroElements() ElementInventories {
    return .{ .aluminum_mol = 0, .iron_mol = 0, .calcium_mol = 0, .magnesium_mol = 0, .sodium_mol = 0, .potassium_mol = 0 };
}

/// Direct translation of `starte.f` lines 1642--1662 inside the enclosing
/// `DATA(20) == 'NO' .AND. IGO == 0` branch.
pub fn initialize(control: Control, texture: Texture, soil_mass_megagrams: f64, ph: f64) !?Inventories {
    if (control.profile_source != .atmospheric_equilibrium or
        control.gas_initialization_index != 0) return null;
    inline for (@typeInfo(Texture).@"struct".fields) |field| {
        const value = @field(texture, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidSoilTexture;
    }
    if (texture.sand_mass_fraction + texture.silt_mass_fraction + texture.clay_mass_fraction >
        1 + 64 * std.math.floatEps(f64)) return error.InvalidSoilTexture;
    if (!std.math.isFinite(soil_mass_megagrams) or soil_mass_megagrams < 0) return error.InvalidSoilMass;
    if (!std.math.isFinite(ph) or ph < 0 or ph > 14) return error.InvalidSoilPh;

    const surface_area_m2 = (0.3 * texture.sand_mass_fraction +
        2.2 * texture.silt_mass_fraction +
        8.0 * texture.clay_mass_fraction) * soil_mass_megagrams;
    const acid_insensitive_mol = 0.167 * surface_area_m2 * 5.0e3;
    if (!std.math.isFinite(surface_area_m2) or !std.math.isFinite(acid_insensitive_mol))
        return error.InvalidSilicateInventory;
    const base_silicate_mol = if (ph > 4.5) acid_insensitive_mol else 0.0;
    return .{
        .mineral_surface_area_m2 = surface_area_m2,
        .soil_silicates = .{
            .aluminum_mol = acid_insensitive_mol,
            .iron_mol = acid_insensitive_mol,
            .calcium_mol = base_silicate_mol,
            .magnesium_mol = base_silicate_mol,
            .sodium_mol = base_silicate_mol,
            .potassium_mol = base_silicate_mol,
        },
        .ground_rock_silicates = zeroElements(),
    };
}

/// Converts STARTE's extensive Q*SI inventories to the runtime chemistry
/// owner's water-volume concentration basis. Multiplying every returned field
/// by `water_volume_m3` recovers the source inventory exactly.
pub fn initializePerWaterVolume(
    control: Control,
    texture: Texture,
    soil_mass_megagrams: f64,
    water_volume_m3: f64,
    ph: f64,
) !?Concentrations {
    const inventories = (try initialize(control, texture, soil_mass_megagrams, ph)) orelse return null;
    if (!std.math.isFinite(water_volume_m3) or water_volume_m3 <= 0)
        return error.InvalidSilicateWaterVolume;
    var soil = inventories.soil_silicates;
    var ground = inventories.ground_rock_silicates;
    inline for (@typeInfo(ElementInventories).@"struct".fields) |field| {
        @field(soil, field.name) /= water_volume_m3;
        @field(ground, field.name) /= water_volume_m3;
        if (!std.math.isFinite(@field(soil, field.name)) or
            !std.math.isFinite(@field(ground, field.name)))
            return error.InvalidSilicateInventory;
    }
    return .{
        .soil_silicates_mol_per_m3 = soil,
        .ground_rock_silicates_mol_per_m3 = ground,
    };
}

test "STARTE silicate initialization preserves texture operation order and alkaline branch" {
    const result = (try initialize(.{ .profile_source = .atmospheric_equilibrium, .gas_initialization_index = 0 }, .{
        .sand_mass_fraction = 0.1,
        .silt_mass_fraction = 0.2,
        .clay_mass_fraction = 0.3,
    }, 2, 4.6)).?;
    const expected_area = (0.3 * 0.1 + 2.2 * 0.2 + 8.0 * 0.3) * 2.0;
    const expected_mol = 0.167 * expected_area * 5.0e3;
    try std.testing.expectApproxEqRel(expected_area, result.mineral_surface_area_m2, 16 * std.math.floatEps(f64));
    try std.testing.expectApproxEqRel(expected_mol, result.soil_silicates.aluminum_mol, 16 * std.math.floatEps(f64));
    try std.testing.expectApproxEqRel(expected_mol, result.soil_silicates.potassium_mol, 16 * std.math.floatEps(f64));
    try std.testing.expectEqual(@as(f64, 0), result.ground_rock_silicates.aluminum_mol);
}

test "STARTE pH threshold is strict and suppresses four base silicates" {
    const result = (try initialize(.{ .profile_source = .atmospheric_equilibrium, .gas_initialization_index = 0 }, .{ .sand_mass_fraction = 0.3, .silt_mass_fraction = 0.3, .clay_mass_fraction = 0.4 }, 1, 4.5)).?;
    try std.testing.expect(result.soil_silicates.aluminum_mol > 0);
    try std.testing.expect(result.soil_silicates.iron_mol > 0);
    try std.testing.expectEqual(@as(f64, 0), result.soil_silicates.calcium_mol);
    try std.testing.expectEqual(@as(f64, 0), result.soil_silicates.magnesium_mol);
    try std.testing.expectEqual(@as(f64, 0), result.soil_silicates.sodium_mol);
    try std.testing.expectEqual(@as(f64, 0), result.soil_silicates.potassium_mol);
}

test "STARTE inactive silicate initialization ignores invalid dormant input" {
    const nan = std.math.nan(f64);
    try std.testing.expectEqual(@as(?Inventories, null), try initialize(.{ .profile_source = .supplied_profile, .gas_initialization_index = 0 }, .{ .sand_mass_fraction = nan, .silt_mass_fraction = nan, .clay_mass_fraction = nan }, nan, nan));
}

test "STARTE silicate concentrations preserve every extensive source inventory" {
    const water_volume_m3 = 0.25;
    const control: Control = .{ .profile_source = .atmospheric_equilibrium, .gas_initialization_index = 0 };
    const texture: Texture = .{ .sand_mass_fraction = 0.4, .silt_mass_fraction = 0.35, .clay_mass_fraction = 0.25 };
    const inventory = (try initialize(control, texture, 2, 6.5)).?;
    const concentrations = (try initializePerWaterVolume(control, texture, 2, water_volume_m3, 6.5)).?;
    inline for (@typeInfo(ElementInventories).@"struct".fields) |field| {
        try std.testing.expectEqual(
            @field(inventory.soil_silicates, field.name),
            @field(concentrations.soil_silicates_mol_per_m3, field.name) * water_volume_m3,
        );
        try std.testing.expectEqual(
            @field(inventory.ground_rock_silicates, field.name),
            @field(concentrations.ground_rock_silicates_mol_per_m3, field.name) * water_volume_m3,
        );
    }
}

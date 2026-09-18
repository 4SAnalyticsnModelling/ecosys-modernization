// **A8a DISPOSITION: superseded, do not bind.** This module recomputes the
// legacy `FSEDER = AMIN1(1.0, XSEDER/BKVLNU)` transported-mass fraction
// (`erosion.f:542`, restated `:1178`) and multiplies it into one named list of
// surface-layer pools. Production factors that differently: the identical
// clamped fraction is computed once per cell in
// `erosion/eroded_constituents.zig` `calculatePackedFluxes` (`:105`) and
// applied to a packed pool array whose membership and order are declared by
// the four `soil/profile/erosion_*_bridge.zig` modules, dispatched from
// `stages/hourly_science_sediment.zig:57, :77, :90, :105`. This kernel has no
// call site anywhere in the tree, so binding it would not install a competing
// writer; it would duplicate a fraction already derived from the same inputs.
//
// Group B of docs/traceability/erosion_unbound_family_disposition.md

const std = @import("std");

pub const SurfacePools = struct {
    aluminum_hydroxide_precipitate_mol: f64, // PALOH
    iron_hydroxide_precipitate_mol: f64, // PFEOH
    calcium_carbonate_precipitate_mol: f64, // PCACO
    calcium_sulfate_precipitate_mol: f64, // PCASO
    aluminum_silicate_mol: f64, // QALSI
    iron_silicate_mol: f64, // QFESI
    calcium_silicate_mol: f64, // QCASI
    magnesium_silicate_mol: f64, // QMGSI
    sodium_silicate_mol: f64, // QNASI
    potassium_silicate_mol: f64, // QKASI
    aluminum_silicate_secondary_mol: f64, // QALSIF
    iron_silicate_secondary_mol: f64, // QFESIF
    calcium_silicate_secondary_mol: f64, // QCASIF
    magnesium_silicate_secondary_mol: f64, // QMGSIF
    sodium_silicate_secondary_mol: f64, // QNASIF
    potassium_silicate_secondary_mol: f64, // QKASIF
    aluminum_phosphate_non_band_mol: f64, // PALPO
    iron_phosphate_non_band_mol: f64, // PFEPO
    dicalcium_phosphate_non_band_mol: f64, // PCAPD
    hydroxyapatite_non_band_mol: f64, // PCAPH
    monocalcium_phosphate_non_band_mol: f64, // PCAPM
    aluminum_phosphate_band_mol: f64, // PALPB
    iron_phosphate_band_mol: f64, // PFEPB
    dicalcium_phosphate_band_mol: f64, // PCPDB
    hydroxyapatite_band_mol: f64, // PCPHB
    monocalcium_phosphate_band_mol: f64, // PCPMB
};

pub const Fluxes = SurfacePools;

/// Direct named binding of EROSION 615--640 for one runtime cell face.
pub fn calculate(transported_surface_mass_fraction: f64, pools: SurfacePools) !Fluxes {
    if (!std.math.isFinite(transported_surface_mass_fraction) or transported_surface_mass_fraction < 0 or transported_surface_mass_fraction > 1) return error.InvalidErosionPrecipitateSilicateFraction;
    var result: Fluxes = undefined;
    inline for (@typeInfo(SurfacePools).@"struct".fields) |field| {
        const pool_mol = @field(pools, field.name);
        if (!std.math.isFinite(pool_mol) or pool_mol < 0) return error.InvalidErosionPrecipitateSilicatePool;
        @field(result, field.name) = transported_surface_mass_fraction * pool_mol;
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteErosionPrecipitateSilicateResult;
    }
    return result;
}

fn fixture() SurfacePools {
    var result: SurfacePools = undefined;
    inline for (@typeInfo(SurfacePools).@"struct".fields, 1..) |field, value| @field(result, field.name) = @floatFromInt(value);
    return result;
}

test "EROSION precipitate and silicate flux preserves all 26 source mappings" {
    const flux = try calculate(0.25, fixture());
    try std.testing.expectEqual(@as(f64, 0.25), flux.aluminum_hydroxide_precipitate_mol);
    try std.testing.expectEqual(@as(f64, 1), flux.calcium_sulfate_precipitate_mol);
    try std.testing.expectEqual(@as(f64, 2.5), flux.potassium_silicate_mol);
    try std.testing.expectEqual(@as(f64, 4), flux.potassium_silicate_secondary_mol);
    try std.testing.expectEqual(@as(f64, 4.25), flux.aluminum_phosphate_non_band_mol);
    try std.testing.expectEqual(@as(f64, 5.25), flux.monocalcium_phosphate_non_band_mol);
    try std.testing.expectEqual(@as(f64, 6.5), flux.monocalcium_phosphate_band_mol);
}

test "EROSION precipitate and silicate flux retains exact fraction cap result" {
    const pools = fixture();
    const flux = try calculate(1, pools);
    try std.testing.expectEqualDeep(pools, flux);
}

test "EROSION precipitate and silicate validation rejects a late invalid pool" {
    var pools = fixture();
    pools.monocalcium_phosphate_band_mol = std.math.inf(f64);
    try std.testing.expectError(error.InvalidErosionPrecipitateSilicatePool, calculate(0.5, pools));
}

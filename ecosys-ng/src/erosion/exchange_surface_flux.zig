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
    adsorbed_ammonium_non_band_mol: f64, // XN4
    adsorbed_ammonium_band_mol: f64, // XNB
    adsorbed_hydrogen_mol: f64, // XHY
    adsorbed_aluminum_mol: f64, // XAL
    adsorbed_iron_mol: f64, // XFE
    adsorbed_calcium_mol: f64, // XCA
    adsorbed_magnesium_mol: f64, // XMG
    adsorbed_sodium_mol: f64, // XNA
    adsorbed_potassium_mol: f64, // XKA
    adsorbed_bicarbonate_mol: f64, // XHC
    deprotonated_site_non_band_mol: f64, // XOH0
    neutral_hydroxyl_site_non_band_mol: f64, // XOH1
    protonated_hydroxyl_site_non_band_mol: f64, // XOH2
    adsorbed_hydrogen_phosphate_non_band_mol: f64, // XH1P
    adsorbed_dihydrogen_phosphate_non_band_mol: f64, // XH2P
    deprotonated_site_band_mol: f64, // XOH0B
    neutral_hydroxyl_site_band_mol: f64, // XOH1B
    protonated_hydroxyl_site_band_mol: f64, // XOH2B
    adsorbed_hydrogen_phosphate_band_mol: f64, // XH1PB
    adsorbed_dihydrogen_phosphate_band_mol: f64, // XH2PB
};

pub const Fluxes = SurfacePools;

/// Direct named binding of EROSION 582--601 for one runtime cell face.
pub fn calculate(transported_surface_mass_fraction: f64, pools: SurfacePools) !Fluxes {
    if (!std.math.isFinite(transported_surface_mass_fraction) or transported_surface_mass_fraction < 0 or transported_surface_mass_fraction > 1) return error.InvalidErosionExchangeSurfaceFraction;
    var result: Fluxes = undefined;
    inline for (@typeInfo(SurfacePools).@"struct".fields) |field| {
        const pool_mol = @field(pools, field.name);
        if (!std.math.isFinite(pool_mol) or pool_mol < 0) return error.InvalidErosionExchangeSurfacePool;
        @field(result, field.name) = transported_surface_mass_fraction * pool_mol;
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteErosionExchangeSurfaceResult;
    }
    return result;
}

fn fixture() SurfacePools {
    var result: SurfacePools = undefined;
    inline for (@typeInfo(SurfacePools).@"struct".fields, 1..) |field, value| @field(result, field.name) = @floatFromInt(value);
    return result;
}

test "EROSION exchange-surface flux preserves all 20 named source mappings" {
    const flux = try calculate(0.25, fixture());
    try std.testing.expectEqual(@as(f64, 0.25), flux.adsorbed_ammonium_non_band_mol);
    try std.testing.expectEqual(@as(f64, 0.5), flux.adsorbed_ammonium_band_mol);
    try std.testing.expectEqual(@as(f64, 2.5), flux.adsorbed_bicarbonate_mol);
    try std.testing.expectEqual(@as(f64, 3.5), flux.adsorbed_hydrogen_phosphate_non_band_mol);
    try std.testing.expectEqual(@as(f64, 5), flux.adsorbed_dihydrogen_phosphate_band_mol);
}

test "EROSION exchange-surface zero fraction returns exact zero fluxes" {
    const flux = try calculate(0, fixture());
    inline for (@typeInfo(Fluxes).@"struct".fields) |field| try std.testing.expectEqual(@as(f64, 0), @field(flux, field.name));
}

test "EROSION exchange-surface validation rejects a late invalid pool" {
    var pools = fixture();
    pools.adsorbed_dihydrogen_phosphate_band_mol = std.math.nan(f64);
    try std.testing.expectError(error.InvalidErosionExchangeSurfacePool, calculate(0.5, pools));
}

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
    sand_megagrams: f64,
    silt_megagrams: f64,
    clay_megagrams: f64,
    cation_exchange_capacity_mol: f64,
    anion_exchange_capacity_mol: f64,
    ammonium_non_band_mol: f64,
    ammonia_non_band_mol: f64,
    urea_non_band_mol: f64,
    nitrate_non_band_mol: f64,
    ammonium_band_mol: f64,
    ammonia_band_mol: f64,
    urea_band_mol: f64,
    nitrate_band_mol: f64,
};

pub const Fluxes = SurfacePools;

fn validateFiniteNonnegative(value: f64) !void {
    if (!std.math.isFinite(value) or value < 0) return error.InvalidErosionMineralFertilizerInput;
}

/// Direct named binding of EROSION 541--569 for one runtime cell face.
pub fn calculate(cumulative_sediment_megagrams: f64, surface_soil_mass_megagrams: f64, pools: SurfacePools) !Fluxes {
    return calculateFromFraction(try transportedFraction(cumulative_sediment_megagrams, surface_soil_mass_megagrams), pools);
}

pub fn transportedFraction(cumulative_sediment_megagrams: f64, surface_soil_mass_megagrams: f64) !f64 {
    try validateFiniteNonnegative(cumulative_sediment_megagrams);
    try validateFiniteNonnegative(surface_soil_mass_megagrams);
    if (surface_soil_mass_megagrams == 0) return error.ZeroErosionSurfaceSoilMass;
    return @min(1.0, cumulative_sediment_megagrams / surface_soil_mass_megagrams);
}

pub fn calculateFromFraction(transported_fraction: f64, pools: SurfacePools) !Fluxes {
    if (!std.math.isFinite(transported_fraction) or transported_fraction < 0 or transported_fraction > 1) return error.InvalidErosionMineralFertilizerInput;
    inline for (@typeInfo(SurfacePools).@"struct".fields) |field| try validateFiniteNonnegative(@field(pools, field.name));
    var result: Fluxes = undefined;
    inline for (@typeInfo(SurfacePools).@"struct".fields) |field| {
        @field(result, field.name) = transported_fraction * @field(pools, field.name);
        if (!std.math.isFinite(@field(result, field.name))) return error.NonFiniteErosionMineralFertilizerResult;
    }
    return result;
}

fn fixture() SurfacePools {
    return .{
        .sand_megagrams = 1,
        .silt_megagrams = 2,
        .clay_megagrams = 3,
        .cation_exchange_capacity_mol = 4,
        .anion_exchange_capacity_mol = 5,
        .ammonium_non_band_mol = 6,
        .ammonia_non_band_mol = 7,
        .urea_non_band_mol = 8,
        .nitrate_non_band_mol = 9,
        .ammonium_band_mol = 10,
        .ammonia_band_mol = 11,
        .urea_band_mol = 12,
        .nitrate_band_mol = 13,
    };
}

test "EROSION named mineral and fertilizer fluxes preserve source mapping" {
    const pools = fixture();
    const flux = try calculate(2, 10, pools);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), flux.sand_megagrams, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), flux.cation_exchange_capacity_mol, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), flux.ammonium_non_band_mol, 1.0e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 2.6), flux.nitrate_band_mol, 1.0e-15);
}

test "EROSION transported fraction retains the source upper cap" {
    const pools = fixture();
    const flux = try calculate(20, 10, pools);
    try std.testing.expectEqualDeep(pools, flux);
}

test "EROSION mineral fertilizer calculation fails before returning partial flux" {
    var pools = fixture();
    pools.nitrate_band_mol = std.math.nan(f64);
    try std.testing.expectError(error.InvalidErosionMineralFertilizerInput, calculate(1, 10, pools));
}

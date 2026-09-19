//! Shared derivation of legacy `ZEROS2`'s per-cell water-volume noise floor.
//! `f77src/starts.f:94`: `ZERO2=1.0E-06`. `f77src/starts.f:270`:
//! `ZEROS2(NY,NX)=ZERO2*DH(NY,NX)*DV(NY,NX)`, scaling the bare literal by the
//! cell's horizontal footprint (m2) so the floor grows/shrinks with cell size
//! exactly as the water volume it gates does (see `f77src/solute.f:610`).
//!
//! Centralized (issue-061) so every Zig translation site that widens an
//! exact-zero water-carrier guard to legacy's actual `ZEROS2` floor agrees on
//! the same literal and scaling, rather than re-deriving it independently:
//! issue-060's `landscape_mass_inventory_phosphorus_ions.zig` `aqueousCarrierM3`
//! (the first fixed instance, whose private literal now delegates here) and
//! issue-061's siblings (`water_carrier_rebase.zig`,
//! `landscape_mass_inventory_surface.zig`, `metabolism_state_update.zig`).

const std = @import("std");

/// `ZERO2 = 1.0E-06` (`starts.f:94`).
pub const legacy_negligible_water_volume_m3_per_m2: f64 = 1.0e-6;

/// `ZEROS2(NY,NX) = ZERO2*DH(NY,NX)*DV(NY,NX)` (`starts.f:270`), scaled to
/// one cell's actual horizontal footprint (m2).
pub fn legacyNegligibleWaterVolumeM3(cell_area_m2: f64) f64 {
    return legacy_negligible_water_volume_m3_per_m2 * cell_area_m2;
}

test "issue-061: shared ZEROS2 floor matches issue-060's own literal and Ottawa-deck value" {
    // `starts.f:94`: `ZERO2=1.0E-06`. `starts.f:270`:
    // `ZEROS2(NY,NX)=ZERO2*DH(NY,NX)*DV(NY,NX)`.
    try std.testing.expectEqual(@as(f64, 1.0e-6), legacy_negligible_water_volume_m3_per_m2);
    // The Ottawa deck's site file (`f25si98`) gives every cell DH=DV=1.0 m,
    // so ZEROS2 = 1.0e-6 * 1.0 * 1.0 = 1.0e-6 m3 for this deck.
    try std.testing.expectEqual(@as(f64, 1.0e-6), legacyNegligibleWaterVolumeM3(1.0));
    // A cell with a larger footprint gets a proportionally larger floor,
    // exactly mirroring how VOLW itself scales with cell size.
    try std.testing.expectEqual(@as(f64, 4.0e-6), legacyNegligibleWaterVolumeM3(4.0));
}

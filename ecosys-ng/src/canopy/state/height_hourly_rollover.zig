// **A8a DISPOSITION: GAP, closed 2026-08-16.** This module previously had no
// production caller. It is now bound from
// `canopy/radiation/layer_distribution.zig`'s `refresh`, called once per
// hour before the growth sweep over its persistent
// `previous_canopy_height_m_by_plant`/`canopy_height_m_by_plant` fields, and
// the rotated previous-hour value feeds the leaf base/tip height ceiling at
// `grosub.f:3816--3817`. See register entry CANOPY-ZCX-001 at
// `docs/discrepancy_register.md:9521` (amended 2026-08-16 with the fix).
//
// Legacy `grosub.f:303--304` copies `ZCX(NZ,NY,NX)=ZC(NZ,NY,NX)` and then
// zeroes `ZC(NZ,NY,NX)`, inside the `9980` per-plant preamble that runs
// before any growth for the hour, so `ZCX` holds the previous hour's
// converged canopy height while `ZC` re-accumulates. `rollover` at this
// module's `:67` is that rotation, validate-before-mutate at `:71--80` so a
// corrupt late plant cannot leave a mixture of previous and current heights
// visible, over runtime-sized per-plant slices.
//
// The sole scientific consumer of `ZCX` in the whole Fortran corpus is the
// leaf inclination-class placement loop at `grosub.f:3816--3817`, which
// bounds each leaf's base and tip height by `ZCX + 0.01`. The remaining two
// mentions in `grosub.f` are a debug write at `:41` and a comment at
// `:3806`, and `ZCX` does not appear in `uptake.f`, `hour1.f`, `stomate.f`,
// `redist.f`, `trnsfrs.f` or `extract.f`. As of the 2026-08-16 fix, that
// ceiling is `layer_distribution.zig`'s `previous_canopy_height_m_by_plant`,
// fed into `allocateLeafAcrossCanopyLayers`'s `maximum_canopy_height_m`
// parameter at the node loop inside `refresh`. `plant_canopy_height_m`
// (declared `:354`, passed as `canopy_height_before_branch_m` at `:447`,
// updated from the orchestrator's return at `:451`, where
// `canopy/leaf/branch_orchestration.zig:60` raises it by each node's
// allocated leaf top height) is a *different* quantity -- `ZC`'s own
// 0-seeded, per-plant, per-hour running max (`grosub.f:304`/`:3877`) -- and
// was correctly left untouched by the fix; only the `:405`-area ceiling was
// the actual unbound `ZCX` consumer.
//
// Binding this module alone would not have closed the gap by itself: the
// rotation needed a consumer reading its previous-hour output. That
// plumbing -- the two persistent `State` fields, the `rollover` call at the
// top of `refresh`, and retargeting the leaf-height ceiling -- now lives in
// `canopy/radiation/layer_distribution.zig`.
//
// Hazard for future readers, by name: `plant/lifecycle/development.zig:228`
// `refreshCanopyHeight` is not this module's owner. It recomputes the
// current maximum node height into `context.development_canopy_height_m`
// from `stages/hourly_science_snow_energy.zig:244` and
// `stages/hourly_science_vegetation.zig:182`; it refreshes rather than
// rotating, and it keeps no previous-hour copy. The only other mention of
// `ZCX` anywhere in `src/` is a comment in
// `canopy/symbiosis/canopy_symbiotic_fixation_reset.zig:4`, and that whole
// directory is vacuous because no shipped example selects a canopy nitrogen
// fixer.
//
// The family argument, stated in full here because each module must carry
// it: uptake.f's hourly canopy water and energy solve, together with the
// grosub.f per-plant hourly preamble, was translated twice. One translation
// became the seven modules in src/canopy/state; the other became the bound
// canopy energy chain in src/canopy/energy plus the inline blocks in
// stages/hourly_science_snow_energy.zig. Two of the seven are production-
// bound and carry no banner: `absent_species.zig` (registered
// `module_index.zig:258`, reached through `absent_standing_dead.zig:2`) and
// `absent_standing_dead.zig` (registered `module_index.zig:265`, called at
// `stages/hourly_science_snow_energy.zig:330` on the
// `!standing_dead_present` branch). The remaining five are unbound and are
// dispositioned individually; three of them turn out to preserve a policy
// production does not have, so they are GAP rather than SUPERSEDED.
// A8a phase 2, src/canopy/state directory sweep. CANOPY-ZCX-001 group of docs/traceability/a8a_canopy_state_dispositions.md
const std = @import("std");

/// Exact grosub.f lines 303--304 canopy-height rollover (ZCX=ZC; ZC=0).
///
/// Both slices use the production cell-major, species-minor runtime plant
/// order. Validation precedes mutation so a corrupt late plant cannot expose
/// a mixture of previous and current hourly canopy heights.
pub fn rollover(
    previous_canopy_height_m_by_plant: []f64,
    current_canopy_height_m_by_plant: []f64,
) !void {
    if (current_canopy_height_m_by_plant.len == 0 or
        previous_canopy_height_m_by_plant.len !=
            current_canopy_height_m_by_plant.len)
        return error.CanopyHeightRolloverDimensionMismatch;
    for (current_canopy_height_m_by_plant) |height_m| {
        if (!std.math.isFinite(height_m))
            return error.NonFiniteCanopyHeight;
        if (height_m < 0)
            return error.NegativeCanopyHeight;
    }
    for (previous_canopy_height_m_by_plant, current_canopy_height_m_by_plant) |*previous_height_m, *current_height_m| {
        previous_height_m.* = current_height_m.*;
        current_height_m.* = 0;
    }
}

test "GROSUB rolls arbitrary runtime plant heights in source order" {
    const allocator = std.testing.allocator;
    const plant_count = 41;
    const previous = try allocator.alloc(f64, plant_count);
    defer allocator.free(previous);
    const current = try allocator.alloc(f64, plant_count);
    defer allocator.free(current);
    @memset(previous, -1);
    for (current, 0..) |*height_m, plant|
        height_m.* = @as(f64, @floatFromInt(plant)) * 0.125;

    try rollover(previous, current);

    for (previous, current, 0..) |previous_height_m, current_height_m, plant| {
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(plant)) * 0.125,
            previous_height_m,
        );
        try std.testing.expectEqual(@as(f64, 0), current_height_m);
    }
}

test "invalid late canopy height leaves both generations unchanged" {
    var previous = [_]f64{ 1, 2, 3 };
    var current = [_]f64{ 4, 5, std.math.nan(f64) };
    const previous_before = previous;
    const current_before = current;

    try std.testing.expectError(
        error.NonFiniteCanopyHeight,
        rollover(&previous, &current),
    );

    try std.testing.expectEqualSlices(f64, &previous_before, &previous);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&current_before),
        std.mem.asBytes(&current),
    );
}

test "dimension mismatch and negative height fail explicitly" {
    var previous = [_]f64{ 1, 2 };
    var short_current = [_]f64{3};
    try std.testing.expectError(
        error.CanopyHeightRolloverDimensionMismatch,
        rollover(&previous, &short_current),
    );
    var negative_current = [_]f64{ -0.1, 0 };
    try std.testing.expectError(
        error.NegativeCanopyHeight,
        rollover(&previous, &negative_current),
    );
}

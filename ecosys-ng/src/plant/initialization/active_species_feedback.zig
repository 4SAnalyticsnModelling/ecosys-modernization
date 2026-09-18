// **A8a DISPOSITION: unwired pure kernel, superseded; do not bind piecemeal.**
// Source: `startq.f` 912--915 (`HCBFCZ`/`HCBFDZ` zeroing).
// Covered by production: the combustion-heat arrays allocated and zeroed at `ecosys_ng.zig:2085-2099` and wired at `:3130-3134`, so this zeroing is already performed once by allocation.
// This is NOT a double-mutation case. Nothing in `ecosys_ng.zig` names this
// module, and its entry point takes only structs it defines itself, so it has no
// path to production state and cannot compete for ownership. It is retained, not
// deleted, because it carries an exact source range and tests; binding it is part
// of the single consolidation refactor tracked as INIT-004, not an isolated wire.
// Group INDEX of docs/traceability/plant_initialization_unbound_family_are_unwired_kernels_not_competing_owners.md
const std = @import("std");

pub const CombustionHeat = struct {
    living_canopy_megajoules_per_timestep: []f64,
    standing_dead_megajoules_per_timestep: []f64,
};

pub const InitializationError = error{
    SpeciesCountMismatch,
};

/// Translates `startq.f` lines 912--915 for runtime active plant species.
pub fn initialize(heat: CombustionHeat) InitializationError!void {
    if (heat.living_canopy_megajoules_per_timestep.len !=
        heat.standing_dead_megajoules_per_timestep.len)
    {
        return error.SpeciesCountMismatch;
    }

    for (0..heat.living_canopy_megajoules_per_timestep.len) |species| {
        heat.living_canopy_megajoules_per_timestep[species] = 0.0;
        heat.standing_dead_megajoules_per_timestep[species] = 0.0;
    }
}

test "runtime active species combustion heat resets in STARTQ order" {
    var living_canopy = [_]f64{ 1.0, 2.0, 3.0 };
    var standing_dead = [_]f64{ 4.0, 5.0, 6.0 };

    try initialize(.{
        .living_canopy_megajoules_per_timestep = &living_canopy,
        .standing_dead_megajoules_per_timestep = &standing_dead,
    });

    try std.testing.expectEqualSlices(f64, &.{ 0.0, 0.0, 0.0 }, &living_canopy);
    try std.testing.expectEqualSlices(f64, &.{ 0.0, 0.0, 0.0 }, &standing_dead);
}

test "species mismatch fails before either heat ledger mutates" {
    var living_canopy = [_]f64{ 1.0, 2.0 };
    var standing_dead = [_]f64{3.0};

    try std.testing.expectError(error.SpeciesCountMismatch, initialize(.{
        .living_canopy_megajoules_per_timestep = &living_canopy,
        .standing_dead_megajoules_per_timestep = &standing_dead,
    }));
    try std.testing.expectEqualSlices(f64, &.{ 1.0, 2.0 }, &living_canopy);
    try std.testing.expectEqualSlices(f64, &.{3.0}, &standing_dead);
}

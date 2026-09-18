// **A8a DISPOSITION: superseded, do not bind.** The three ponding fractions of
// `erosion.f` 49--54 (`FVOLWM`, `FVOLIM`, `FERSNM=(1-FVOLIM)*FVOLWM`) are
// fused into the bound owner: `soil/profile/erosion.calculateLocalStep`
// computes them at `:191--193` with `std.math.clamp(..., 0, 1)` for the
// `AMIN1/AMAX1` pair and consumes the mobile fraction in all three flux
// branches (`:202`, `:207`, `:209`). `FERSNM` is never materialized as a
// field, which is why searching for that name finds nothing outside
// `src/erosion/`. The two accumulators zeroed here are handled by the
// `@memset` in `erosion/sediment_routing.zig` `route`.
//
// Group F of docs/traceability/erosion_unbound_family_disposition.md

const std = @import("std");

pub const DisturbanceEffects = enum {
    none,
    freeze_thaw,
    freeze_thaw_and_erosion,
    freeze_thaw_and_organic_change,
    freeze_thaw_erosion_and_organic_change,

    fn includesErosion(self: DisturbanceEffects) bool {
        return self == .freeze_thaw_and_erosion or self == .freeze_thaw_erosion_and_organic_change;
    }
};

pub const State = struct {
    net_routed_sediment_megagrams_per_step: f64, // TERSED
    local_detachment_megagrams_per_step: f64, // RDTSED
    ponding_water_fraction: f64, // FVOLWM
    ponding_ice_fraction: f64, // FVOLIM
    mobile_unfrozen_surface_fraction: f64, // FERSNM
};

pub const Inputs = struct {
    disturbance_effects: DisturbanceEffects,
    excess_surface_water_m3: f64, // XVOLWM(M,...)
    excess_surface_ice_m3: f64, // XVOLIM(M,...)
    surface_ponding_capacity_m3: f64, // VOLWG
};

/// Direct translation of EROSION lines 49--54 for one runtime cell and
/// hydrology step. Inactive disturbance modes retain the preceding state.
pub fn initialize(state: *State, inputs: Inputs) !void {
    if (!inputs.disturbance_effects.includesErosion()) return;
    inline for (.{ inputs.excess_surface_water_m3, inputs.excess_surface_ice_m3, inputs.surface_ponding_capacity_m3 }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteErosionSubstepInitializationInput;
    }
    if (inputs.surface_ponding_capacity_m3 <= 0) return error.InvalidErosionSurfacePondingCapacity;
    const water_fraction = @min(1.0, @max(0.0, inputs.excess_surface_water_m3 / inputs.surface_ponding_capacity_m3));
    const ice_fraction = @min(1.0, @max(0.0, inputs.excess_surface_ice_m3 / inputs.surface_ponding_capacity_m3));
    const mobile_fraction = (1.0 - ice_fraction) * water_fraction;
    inline for (.{ water_fraction, ice_fraction, mobile_fraction }) |value| {
        if (!std.math.isFinite(value)) return error.NonFiniteErosionSubstepInitializationResult;
    }
    state.* = .{
        .net_routed_sediment_megagrams_per_step = 0,
        .local_detachment_megagrams_per_step = 0,
        .ponding_water_fraction = water_fraction,
        .ponding_ice_fraction = ice_fraction,
        .mobile_unfrozen_surface_fraction = mobile_fraction,
    };
}

test "EROSION substep initialization preserves clamp and source order" {
    var state: State = .{
        .net_routed_sediment_megagrams_per_step = 8,
        .local_detachment_megagrams_per_step = 7,
        .ponding_water_fraction = 6,
        .ponding_ice_fraction = 5,
        .mobile_unfrozen_surface_fraction = 4,
    };
    try initialize(&state, .{
        .disturbance_effects = .freeze_thaw_and_erosion,
        .excess_surface_water_m3 = 3,
        .excess_surface_ice_m3 = 0.5,
        .surface_ponding_capacity_m3 = 2,
    });
    try std.testing.expectEqual(@as(f64, 0), state.net_routed_sediment_megagrams_per_step);
    try std.testing.expectEqual(@as(f64, 0), state.local_detachment_megagrams_per_step);
    try std.testing.expectEqual(@as(f64, 1), state.ponding_water_fraction);
    try std.testing.expectEqual(@as(f64, 0.25), state.ponding_ice_fraction);
    try std.testing.expectEqual(@as(f64, 0.75), state.mobile_unfrozen_surface_fraction);
}

test "EROSION inactive mode retains state without evaluating unused inputs" {
    var state: State = .{
        .net_routed_sediment_megagrams_per_step = 8,
        .local_detachment_megagrams_per_step = 7,
        .ponding_water_fraction = 0.6,
        .ponding_ice_fraction = 0.5,
        .mobile_unfrozen_surface_fraction = 0.4,
    };
    const before = state;
    try initialize(&state, .{
        .disturbance_effects = .freeze_thaw_and_organic_change,
        .excess_surface_water_m3 = std.math.nan(f64),
        .excess_surface_ice_m3 = std.math.nan(f64),
        .surface_ponding_capacity_m3 = 0,
    });
    try std.testing.expectEqualDeep(before, state);
}

test "EROSION active invalid capacity fails atomically" {
    var state: State = .{
        .net_routed_sediment_megagrams_per_step = 8,
        .local_detachment_megagrams_per_step = 7,
        .ponding_water_fraction = 0.6,
        .ponding_ice_fraction = 0.5,
        .mobile_unfrozen_surface_fraction = 0.4,
    };
    const before = state;
    try std.testing.expectError(error.InvalidErosionSurfacePondingCapacity, initialize(&state, .{
        .disturbance_effects = .freeze_thaw_erosion_and_organic_change,
        .excess_surface_water_m3 = 1,
        .excess_surface_ice_m3 = 0,
        .surface_ponding_capacity_m3 = 0,
    }));
    try std.testing.expectEqualDeep(before, state);
}

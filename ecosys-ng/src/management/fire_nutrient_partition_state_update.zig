// **A8a DISPOSITION: SUPERSEDED BY BOUND OWNER; EXTRACT-004/005 are closed.**
// `plant/growth/shoot_fire.zig` now partitions shoot N/P, credits surface
// NH4/H2PO4 through `addSurfaceNutrients`, and returns dynamic salts.
//
// **HISTORICAL A8a DISPOSITION: GAP, held under EXTRACT-004.** Do not bind this module. The
// gap it belongs to is real and already filed, but this file is explicitly *not*
// the right place to fix it.
//
// This module applies the EXTRACT fire nutrient partition step, splitting
// combusted N and P into gaseous oxide and mineral halves by `FCOMN`/`FCOMP`, in
// source assignment order over the ranges its header cites.
//
// EXTRACT-004 in docs/discrepancy_register.md records the live defect: the bound
// shoot consumer publishes only the aggregate signed N and P loss
// (`plant/growth/shoot_fire.zig`), discarding the mineral return to litter,
// which under the shipped `TFNCOC = 0` is 50 percent of combusted shoot N and 90
// percent of combusted shoot P. The root path books both. Only the shoot path is
// incomplete.
//
// That entry states the resolution explicitly, and it is a warning aimed at this
// file: bind through `plant/exchange/soil.zig:635 combustPlantPools`, which
// already computes the identical fractions
// (`0.1 + (0.5-0.1)*(1-response)` and `0.7 + (0.9-0.7)*(1-response)`, `:641--642`)
// and returns `ammonium_nitrogen_g` and `phosphate_phosphorus_g` alongside the
// gaseous halves, and state_update the mineral return via
// `soil/biogeochemistry/organic_matter_fire_exchange.addSurfaceNutrients` as an
// additional physically distinct contributor. Binding *this* module instead would
// install a second, competing partition of the same combusted mass.
//
// Hazard worth recording: `combustPlantPools` is itself currently reached only
// from its own tests plus a comment in `shoot_fire.zig:428`, so it is not a live
// owner today either. The fix is one binding request that wires the applier and
// the sink together, owed to lane A1 because it edits `ecosys_ng.zig`.
//
// The family argument in full, for completeness: unbound `src/management/` is
// otherwise superseded because production replaced per-statement HOUR1/GROSUB
// decomposition with three runscript-catalog schedule dispatchers, each legacy
// statement landing in a bound applier. This module is not superseded; its
// science is owed, just not from here.
//
// Register: EXTRACT-004, and EXTRACT-005 for the sibling salt half.
// M4 disturbance group of
// docs/traceability/management_unbound_family_is_superseded_by_the_schedule_dispatchers.md
const std = @import("std");

pub const Fractions = struct {
    mineral_nitrogen_fraction: f64, // FCOMN
    mineral_phosphorus_fraction: f64, // FCOMP
};

pub const Inputs = struct {
    combusted_nitrogen_g_n: f64, // RCMBN/RWTSTDN...
    combusted_phosphorus_g_p: f64, // RCMBP/RWTSTDP...
};

pub const State = struct {
    gaseous_nitrogen_oxide_g_n: f64, // ZOX
    gaseous_phosphorus_oxide_g_p: f64, // POX
    mineral_ammonium_g_n: f64, // Z4M
    mineral_dihydrogen_phosphate_g_p: f64, // P4M
};

/// EXTRACT lines 281--284, 351--354, 387--390, 472--475, 484--487, 498--501,
/// and 513--516. Applies one source-equation partition step to running fire
/// nutrient products in source assignment order.
pub fn publishStep(state: *State, inputs: Inputs, fractions: Fractions) !void {
    inline for (std.meta.fields(Inputs)) |field| {
        const value = @field(inputs, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidFireNutrientPartitionInput;
    }
    inline for (std.meta.fields(Fractions)) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidFireNutrientPartitionFraction;
    }
    inline for (std.meta.fields(State)) |field| {
        const value = @field(state.*, field.name);
        if (!std.math.isFinite(value))
            return error.NonFiniteFireNutrientPartitionState;
    }

    const gaseous_nitrogen = inputs.combusted_nitrogen_g_n *
        (1.0 - fractions.mineral_nitrogen_fraction);
    const gaseous_phosphorus = inputs.combusted_phosphorus_g_p *
        (1.0 - fractions.mineral_phosphorus_fraction);
    const mineral_nitrogen = inputs.combusted_nitrogen_g_n *
        fractions.mineral_nitrogen_fraction;
    const mineral_phosphorus = inputs.combusted_phosphorus_g_p *
        fractions.mineral_phosphorus_fraction;

    const next: State = .{
        .gaseous_nitrogen_oxide_g_n = state.gaseous_nitrogen_oxide_g_n +
            gaseous_nitrogen,
        .gaseous_phosphorus_oxide_g_p = state.gaseous_phosphorus_oxide_g_p + gaseous_phosphorus,
        .mineral_ammonium_g_n = state.mineral_ammonium_g_n +
            mineral_nitrogen,
        .mineral_dihydrogen_phosphate_g_p = state.mineral_dihydrogen_phosphate_g_p + mineral_phosphorus,
    };
    inline for (std.meta.fields(State)) |field|
        if (!std.math.isFinite(@field(next, field.name)))
            return error.NonFiniteFireNutrientPartitionResult;
    state.* = next;
}

test "fire nutrient partition preserves EXTRACT gaseous and mineral splits" {
    var state = std.mem.zeroes(State);
    try publishStep(&state, .{
        .combusted_nitrogen_g_n = 10,
        .combusted_phosphorus_g_p = 6,
    }, .{
        .mineral_nitrogen_fraction = 0.2,
        .mineral_phosphorus_fraction = 0.25,
    });
    try std.testing.expectEqual(@as(f64, 8), state.gaseous_nitrogen_oxide_g_n);
    try std.testing.expectEqual(@as(f64, 4.5), state.gaseous_phosphorus_oxide_g_p);
    try std.testing.expectEqual(@as(f64, 2), state.mineral_ammonium_g_n);
    try std.testing.expectEqual(@as(f64, 1.5), state.mineral_dihydrogen_phosphate_g_p);
}

test "fire nutrient partition accumulates and is atomic on invalid input" {
    var state = std.mem.zeroes(State);
    try publishStep(&state, .{
        .combusted_nitrogen_g_n = 1,
        .combusted_phosphorus_g_p = 2,
    }, .{
        .mineral_nitrogen_fraction = 0.5,
        .mineral_phosphorus_fraction = 0.5,
    });
    const before = state;
    try std.testing.expectError(
        error.InvalidFireNutrientPartitionFraction,
        publishStep(&state, .{
            .combusted_nitrogen_g_n = 1,
            .combusted_phosphorus_g_p = 2,
        }, .{
            .mineral_nitrogen_fraction = 2,
            .mineral_phosphorus_fraction = 0.5,
        }),
    );
    try std.testing.expectEqual(before, state);
}

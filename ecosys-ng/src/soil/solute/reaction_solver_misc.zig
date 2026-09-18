//! `reaction_solver` declarations: misc.
//!
//! Split out of `reaction_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const group_types = @import("reaction_solver_types.zig");

pub fn coupledExtentReactionEnabled(
    reaction: group_types.CoupledExtentReaction,
    _: usize,
) bool {
    if (@intFromEnum(reaction) < 16) return true;
    return switch (reaction) {
        .aqueous_calcium_hydroxide_pairing,
        .aqueous_calcium_carbonate_pairing,
        .aqueous_calcium_bicarbonate_pairing,
        .aqueous_calcium_sulfate_pairing,
        => true,
        else => unreachable,
    };
}

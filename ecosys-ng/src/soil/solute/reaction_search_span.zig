//! Invertible phosphate search coordinates. Mineral equations are priced
//! from PO4/HPO4 but source ledgers spend H2PO4; combine their acid-chain
//! coordinates so an exhausted intermediate does not exclude a feasible
//! coupled mineral direction. Native rates and stoichiometry are unchanged.
const native = @import("conservative_reaction_span.zig");
const chemistry = @import("chemistry_state.zig");

pub const addGaponSwapExtent = native.addGaponSwapExtent;
pub const carboxyl_reaction_index = native.carboxyl_reaction_index;
pub const gaponBasisSiteChargeWeight = native.gaponBasisSiteChargeWeight;
pub const gapon_reaction_count = native.gapon_reaction_count;
pub const gapon_reaction_offset = native.gapon_reaction_offset;
pub const reactionStructurallyEnabled = native.reactionStructurallyEnabled;
pub const reaction_count = native.reaction_count;
pub const zeroTransformations = native.zeroTransformations;

fn mineralCoordinate(column: usize) ?struct { zone: usize, mineral: usize } {
    for ([_]usize{ native.non_band_phosphate_mineral_offset, native.band_phosphate_mineral_offset }, 0..) |offset, zone| {
        if (column >= offset and column < offset + 4) return .{ .zone = zone, .mineral = column - offset };
    }
    return null;
}

fn acidOffset(zone: usize) usize {
    return if (zone == 0) native.non_band_phosphate_aqueous_offset else native.band_phosphate_aqueous_offset;
}

fn weights(parameters: chemistry.ReactionParameters, column: usize) [2]f64 {
    const coordinate = mineralCoordinate(column) orelse return .{ 0, 0 };
    if (!native.reactionStructurallyEnabled(parameters, column)) return .{ 0, 0 };
    const acid = acidOffset(coordinate.zone);
    if (!native.reactionStructurallyEnabled(parameters, acid + 1)) return .{ 0, 0 };
    if (coordinate.mineral == 2) return .{ 0, 1 };
    if (!native.reactionStructurallyEnabled(parameters, acid)) return .{ 0, 0 };
    const amount: f64 = if (coordinate.mineral == 3) 3 else 1;
    return .{ amount, amount };
}

pub fn evaluateRates(state: *const chemistry.State, cell_index: usize, parameters: chemistry.ReactionParameters, output: []f64) !void {
    try native.evaluateRates(state, cell_index, parameters, output);
    for ([_]usize{ native.non_band_phosphate_mineral_offset, native.band_phosphate_mineral_offset }, 0..) |offset, zone| {
        for (0..4) |mineral| {
            const coupled = weights(parameters, offset + mineral);
            for (coupled, 0..) |amount, acid| output[acidOffset(zone) + acid] -= amount * output[offset + mineral];
        }
    }
}

pub fn addReactionExtent(target: *chemistry.CellTransformations, column: usize, extent: f64, reference: chemistry.CellTransformations, parameters: chemistry.ReactionParameters) !void {
    try native.addReactionExtent(target, column, extent, reference, parameters);
    const coordinate = mineralCoordinate(column) orelse return;
    for (weights(parameters, column), 0..) |amount, acid| {
        if (amount == 0 or extent == 0) continue;
        try native.addReactionExtent(target, acidOffset(coordinate.zone) + acid, amount * extent, reference, parameters);
    }
}

pub fn reactionSpanExtentIsClosedFormEligible(column: usize) bool {
    return native.reactionSpanExtentIsClosedFormEligible(column);
}

pub fn reactionIdentity(column: usize) ?native.ReactionIdentity {
    var identity = native.reactionIdentity(column) orelse return null;
    if (mineralCoordinate(column)) |coordinate| identity.name = switch (coordinate.mineral) {
        0 => "aluminum_phosphate_with_po4_association",
        1 => "iron_phosphate_with_po4_association",
        2 => "dicalcium_phosphate_with_hpo4_association",
        3 => "hydroxyapatite_with_po4_association",
        else => unreachable,
    };
    return identity;
}

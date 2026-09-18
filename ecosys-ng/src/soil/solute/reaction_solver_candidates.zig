//! `reaction_solver` declarations: candidates.
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

// Moved to reaction_try.zig; re-exported so call sites are unchanged.
pub const __try = @import("reaction_try.zig");
pub const tryAcceptAndersonCandidate = __try.tryAcceptAndersonCandidate;
pub const tryAcceptExactReactionExtentCandidate = __try.tryAcceptExactReactionExtentCandidate;
pub const tryAcceptReactionExtentLineSearch = __try.tryAcceptReactionExtentLineSearch;
pub const scaledRmsNorm = __try.scaledRmsNorm;
pub const meaningfulRmsMeritDecrease = __try.meaningfulRmsMeritDecrease;
pub const rmsArmijoDecrease = __try.rmsArmijoDecrease;
pub const maximumNormGrowthSafeguard = __try.maximumNormGrowthSafeguard;
pub const newtonCandidateAcceptable = __try.newtonCandidateAcceptable;
pub const tryAcceptNewtonTargetLineSearch = __try.tryAcceptNewtonTargetLineSearch;
pub const tryFullNetworkReactionCandidate = __try.tryFullNetworkReactionCandidate;
pub const tryCurrentSignCoordinateAndersonCandidate = __try.tryCurrentSignCoordinateAndersonCandidate;
pub const tryAnalyticCoordinateNewtonCandidate = __try.tryAnalyticCoordinateNewtonCandidate;
pub const tryActiveRowNewtonCandidate = __try.tryActiveRowNewtonCandidate;
pub const tryTernaryCorrectionFaceNewtonCandidate = __try.tryTernaryCorrectionFaceNewtonCandidate;
pub const ActiveBoundaryRecoveryKind = __try.ActiveBoundaryRecoveryKind;
pub const ActiveBoundaryRecoveryFilter = __try.ActiveBoundaryRecoveryFilter;
pub const tryGlobalInventoryBoundaryRecoveryCandidate = __try.tryGlobalInventoryBoundaryRecoveryCandidate;
pub const tryActiveBoundarySurfaceRecoveryCandidate = __try.tryActiveBoundarySurfaceRecoveryCandidate;
pub const tryActiveBoundarySurfaceRecoveryCandidateFiltered = __try.tryActiveBoundarySurfaceRecoveryCandidateFiltered;
pub const tryProjectWaterPair = __try.tryProjectWaterPair;

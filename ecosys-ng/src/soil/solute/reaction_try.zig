//! Split out of reaction_solver.zig by tools/split_decl_group.py.
//! Pure code motion: every decl below is an exact line slice.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_acceptance = @import("reaction_try_acceptance.zig");
const group_aliases = @import("reaction_try_aliases.zig");
const group_network = @import("reaction_try_network.zig");
const group_phosphate = @import("reaction_try_phosphate.zig");

// acceptance
pub const tryAcceptReactionExtentLineSearch = group_acceptance.tryAcceptReactionExtentLineSearch;
pub const scaledRmsNorm = group_acceptance.scaledRmsNorm;
pub const meaningfulRmsMeritDecrease = group_acceptance.meaningfulRmsMeritDecrease;
pub const rmsArmijoDecrease = group_acceptance.rmsArmijoDecrease;
pub const maximumNormGrowthSafeguard = group_acceptance.maximumNormGrowthSafeguard;
pub const newtonCandidateAcceptable = group_acceptance.newtonCandidateAcceptable;
pub const tryAcceptNewtonTargetLineSearch = group_acceptance.tryAcceptNewtonTargetLineSearch;
pub const tryAcceptExactReactionExtentCandidate = group_acceptance.tryAcceptExactReactionExtentCandidate;
pub const tryProjectWaterPair = group_acceptance.tryProjectWaterPair;
pub const tryAcceptAndersonCandidate = group_acceptance.tryAcceptAndersonCandidate;

// aliases

// network
pub const tryFullNetworkReactionCandidate = group_network.tryFullNetworkReactionCandidate;
pub const tryRetainedComplementarityCandidate = group_network.tryRetainedComplementarityCandidate;
pub const tryFullNetworkComplementarityCandidate = group_network.tryFullNetworkComplementarityCandidate;
pub const tryCurrentSignCoordinateAndersonCandidate = group_network.tryCurrentSignCoordinateAndersonCandidate;
pub const tryAnalyticCoordinateNewtonCandidate = group_network.tryAnalyticCoordinateNewtonCandidate;
pub const tryActiveRowNewtonCandidate = group_network.tryActiveRowNewtonCandidate;
pub const tryTernaryCorrectionFaceNewtonCandidate = group_network.tryTernaryCorrectionFaceNewtonCandidate;
pub const ActiveBoundaryRecoveryKind = group_network.ActiveBoundaryRecoveryKind;
pub const ActiveBoundaryRecoveryFilter = group_network.ActiveBoundaryRecoveryFilter;
pub const tryGlobalInventoryBoundaryRecoveryCandidate = group_network.tryGlobalInventoryBoundaryRecoveryCandidate;
pub const tryActiveBoundarySurfaceRecoveryCandidate = group_network.tryActiveBoundarySurfaceRecoveryCandidate;
pub const tryActiveBoundarySurfaceRecoveryCandidateFiltered = group_network.tryActiveBoundarySurfaceRecoveryCandidateFiltered;

// phosphate
pub const tryPhosphateExtentCandidate = group_phosphate.tryPhosphateExtentCandidate;

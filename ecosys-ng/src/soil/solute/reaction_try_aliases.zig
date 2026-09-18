//! `reaction_try` declarations: aliases.
//!
//! Split out of `reaction_try.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const chemistry = @import("chemistry_state.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("reaction_search_span.zig");
const __parent = @import("reaction_solver.zig");

pub const ComplementaritySearchInputs = __parent.ComplementaritySearchInputs;
pub const CoupledExtentReaction = __parent.CoupledExtentReaction;
pub const IterationDiagnostic = __parent.IterationDiagnostic;
pub const TernaryAmbiguousAxisSource = __parent.TernaryAmbiguousAxisSource;
pub const Options = __parent.Options;
pub const SolverTrace = __parent.SolverTrace;
pub const Workspace = __parent.Workspace;
pub const applyPhosphateExtent = __parent.applyPhosphateExtent;
pub const captureFullNetworkDirectionalComparison = __parent.captureFullNetworkDirectionalComparison;
pub const complementarityColumnDerivative = __parent.complementarityColumnDerivative;
pub const coupledExtentReactionEnabled = __parent.coupledExtentReactionEnabled;
pub const coupled_extent_reaction_count = __parent.coupled_extent_reaction_count;
pub const evaluateAt = __parent.evaluateAt;
pub const evaluateCandidateResidualAtFraction = __parent.evaluateCandidateResidualAtFraction;
pub const evaluateGlobalResidualAt = __parent.evaluateGlobalResidualAt;
pub const evaluatePhosphateExtentResiduals = __parent.evaluatePhosphateExtentResiduals;
pub const evaluateReactionSpanDerivativeColumn = __parent.evaluateReactionSpanDerivativeColumn;
pub const largestPhosphateZoneScaledResidual = __parent.largestPhosphateZoneScaledResidual;
pub const largestScaledResidualIndex = __parent.largestScaledResidualIndex;
pub const matrixColumnNorm = __parent.matrixColumnNorm;
pub const maximumDifference = __parent.maximumDifference;
pub const maximumMagnitude = __parent.maximumMagnitude;
pub const maximumPhosphateExtent = __parent.maximumPhosphateExtent;
pub const phosphateExtentCharacteristic = __parent.phosphateExtentCharacteristic;
pub const phosphateExtentControlsPackedIndex = __parent.phosphateExtentControlsPackedIndex;
pub const phosphateTrustRegionFraction = __parent.phosphateTrustRegionFraction;
pub const phosphateZoneExtentControlsPackedIndex = __parent.phosphateZoneExtentControlsPackedIndex;
pub const reactionSpanExtentBounds = __parent.reactionSpanExtentBounds;
pub const reactionSpanExtentIsSignificant = __parent.reactionSpanExtentIsSignificant;
pub const reactionSpanPredictedNorm = __parent.reactionSpanPredictedNorm;
pub const reactionSpanRowWeight = __parent.reactionSpanRowWeight;
pub const refineComplementarityDirectionalJacobian = __parent.refineComplementarityDirectionalJacobian;
pub const residualScale = __parent.residualScale;
pub const scaledNorm = __parent.scaledNorm;
pub const solveBoundedPhosphateExtents = __parent.solveBoundedPhosphateExtents;
pub const solveBoundedReactionSpan = __parent.solveBoundedReactionSpan;
pub const solveProjectedReactionSpanLeastSquares = __parent.solveProjectedReactionSpanLeastSquares;
pub const transformedVector = __parent.transformedVector;
pub const transformedVectorAdmissible = __parent.transformedVectorAdmissible;

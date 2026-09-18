//! `reaction_solver`.
//!
//! The declarations live in the `_<group>.zig` files beside this one and
//! are re-exported here, so `module.name` still resolves for every caller
//! and the grouping is a file layout choice rather than an API change.

const group_apply = @import("reaction_solver_apply.zig");
const group_candidates = @import("reaction_solver_candidates.zig");
const group_complementarity = @import("reaction_solver_complementarity.zig");
const group_diagnostics = @import("reaction_solver_diagnostics.zig");
const group_evaluate = @import("reaction_solver_evaluate.zig");
const group_misc = @import("reaction_solver_misc.zig");
const group_numerics = @import("reaction_solver_numerics.zig");
const group_numerics2 = @import("reaction_solver_numerics2.zig");
const group_phosphate = @import("reaction_solver_phosphate.zig");
const group_reaction_span = @import("reaction_solver_reaction_span.zig");
const group_solve = @import("reaction_solver_solve.zig");
const group_tests = @import("reaction_solver_tests.zig");
const group_types = @import("reaction_solver_types.zig");
const diagnostic_control = @import("reaction_diagnostic_control.zig");

pub const DiagnosticSuppressionGuard = diagnostic_control.SuppressionGuard;
pub const suppressDiagnostics = diagnostic_control.suppress;
pub const diagnosticsEnabled = diagnostic_control.isEnabled;
pub const diagnosticRuntimeProfilingEnabled = diagnostic_control.runtime_profiling_enabled;
pub const DiagnosticEvaluationCounts = diagnostic_control.EvaluationCounts;
pub const resetDiagnosticEvaluationCounts = diagnostic_control.resetEvaluationCounts;
pub const diagnosticEvaluationCounts = diagnostic_control.evaluationCounts;
pub const DiagnosticReactionSpanBoundsSite = diagnostic_control.ReactionSpanBoundsSite;
pub const DiagnosticReactionSpanBoundsSiteStats = diagnostic_control.ReactionSpanBoundsSiteStats;
pub const resetDiagnosticReactionSpanBoundsSiteStats = diagnostic_control.resetReactionSpanBoundsSiteStats;
pub const diagnosticReactionSpanBoundsSiteStats = diagnostic_control.reactionSpanBoundsSiteStats;
pub const DiagnosticStrategy = diagnostic_control.Strategy;
pub const resetDiagnosticStrategyCallCounts = diagnostic_control.resetStrategyCallCounts;
pub const diagnosticStrategyCallCount = diagnostic_control.strategyCallCount;
pub const diagnosticStrategyEvaluationCounts = diagnostic_control.strategyEvaluationCounts;
pub const DiagnosticSelectedCandidate = diagnostic_control.SelectedCandidate;
pub const resetDiagnosticSelectedCandidateCounts = diagnostic_control.resetSelectedCandidateCounts;
pub const diagnosticSelectedCandidateCount = diagnostic_control.selectedCandidateCount;
pub const DiagnosticAdmissibilityBacktrackStats = diagnostic_control.AdmissibilityBacktrackStats;
pub const resetDiagnosticAdmissibilityBacktrackStats = diagnostic_control.resetAdmissibilityBacktrackStats;
pub const diagnosticAdmissibilityBacktrackStats = diagnostic_control.admissibilityBacktrackStats;

// apply
pub const applyKineticGeochemistryStep = group_apply.applyKineticGeochemistryStep;

// candidates
pub const tryAcceptAndersonCandidate = group_candidates.tryAcceptAndersonCandidate;
pub const tryAcceptExactReactionExtentCandidate = group_candidates.tryAcceptExactReactionExtentCandidate;
pub const tryAcceptReactionExtentLineSearch = group_candidates.tryAcceptReactionExtentLineSearch;
pub const scaledRmsNorm = group_candidates.scaledRmsNorm;
pub const meaningfulRmsMeritDecrease = group_candidates.meaningfulRmsMeritDecrease;
pub const rmsArmijoDecrease = group_candidates.rmsArmijoDecrease;
pub const maximumNormGrowthSafeguard = group_candidates.maximumNormGrowthSafeguard;
pub const newtonCandidateAcceptable = group_candidates.newtonCandidateAcceptable;
pub const tryAcceptNewtonTargetLineSearch = group_candidates.tryAcceptNewtonTargetLineSearch;
pub const tryFullNetworkReactionCandidate = group_candidates.tryFullNetworkReactionCandidate;
pub const tryCurrentSignCoordinateAndersonCandidate = group_candidates.tryCurrentSignCoordinateAndersonCandidate;
pub const tryAnalyticCoordinateNewtonCandidate = group_candidates.tryAnalyticCoordinateNewtonCandidate;
pub const tryActiveRowNewtonCandidate = group_candidates.tryActiveRowNewtonCandidate;
pub const tryTernaryCorrectionFaceNewtonCandidate = group_candidates.tryTernaryCorrectionFaceNewtonCandidate;
pub const ActiveBoundaryRecoveryKind = group_candidates.ActiveBoundaryRecoveryKind;
pub const ActiveBoundaryRecoveryFilter = group_candidates.ActiveBoundaryRecoveryFilter;
pub const tryGlobalInventoryBoundaryRecoveryCandidate = group_candidates.tryGlobalInventoryBoundaryRecoveryCandidate;
pub const tryActiveBoundarySurfaceRecoveryCandidate = group_candidates.tryActiveBoundarySurfaceRecoveryCandidate;
pub const tryActiveBoundarySurfaceRecoveryCandidateFiltered = group_candidates.tryActiveBoundarySurfaceRecoveryCandidateFiltered;
pub const tryProjectWaterPair = group_candidates.tryProjectWaterPair;

// complementarity
pub const complementarityColumnDerivative = group_complementarity.complementarityColumnDerivative;
pub const refineComplementarityDirectionalJacobian = group_complementarity.refineComplementarityDirectionalJacobian;
pub const ComplementaritySearchInputs = group_complementarity.ComplementaritySearchInputs;
pub const tryFullNetworkComplementarityCandidate = group_complementarity.tryFullNetworkComplementarityCandidate;
pub const tryRetainedComplementarityCandidate = group_complementarity.tryRetainedComplementarityCandidate;
pub const solveComplementarityBlend = group_complementarity.solveComplementarityBlend;

// diagnostics
pub const IterationDiagnostic = group_diagnostics.IterationDiagnostic;
pub const TernaryAmbiguousAxisSource = group_diagnostics.TernaryAmbiguousAxisSource;
pub const FullNetworkReactionDiagnostic = group_diagnostics.FullNetworkReactionDiagnostic;
pub const DiagnosticDecomposition = group_diagnostics.DiagnosticDecomposition;
pub const Hpo4Diagnostic = group_diagnostics.Hpo4Diagnostic;
pub const SecondClosureDiagnostic = group_diagnostics.SecondClosureDiagnostic;
pub const diagnoseSecondClosureStart = group_diagnostics.diagnoseSecondClosureStart;
pub const diagnoseNonBandHpo4 = group_diagnostics.diagnoseNonBandHpo4;
pub const diagnoseCell = group_diagnostics.diagnoseCell;
pub const logTerminalReactionDecomposition = group_diagnostics.logTerminalReactionDecomposition;
pub const exhaustsLargestResidual = group_diagnostics.exhaustsLargestResidual;
pub const logTerminalStagnationComponent = group_diagnostics.logTerminalStagnationComponent;
pub const logLargestResidual = group_diagnostics.logLargestResidual;

// evaluate
pub const evaluateCellResidual = group_evaluate.evaluateCellResidual;
pub const captureFullNetworkDirectionalComparison = group_evaluate.captureFullNetworkDirectionalComparison;
pub const evaluateGlobalResidualAt = group_evaluate.evaluateGlobalResidualAt;
pub const evaluateCandidateResidualAtFraction = group_evaluate.evaluateCandidateResidualAtFraction;
pub const evaluateAt = group_evaluate.evaluateAt;
pub const evaluateAtLoaded = group_evaluate.evaluateAtLoaded;
pub const LoadedCarrier = group_evaluate.LoadedCarrier;

// misc
pub const coupledExtentReactionEnabled = group_misc.coupledExtentReactionEnabled;

// numerics
pub const validateAqueousMolarity = group_numerics.validateAqueousMolarity;
pub const largestScaledResidualIndex = group_numerics.largestScaledResidualIndex;
pub const matrixColumnNorm = group_numerics.matrixColumnNorm;
pub const transformedVector = group_numerics.transformedVector;
pub const transformedVectorAdmissible = group_numerics.transformedVectorAdmissible;
pub const scaledNorm = group_numerics.scaledNorm;
pub const residualScale = group_numerics.residualScale;
pub const scaledAndersonDepthOneCandidate = group_numerics.scaledAndersonDepthOneCandidate;
pub const maximumDifference = group_numerics.maximumDifference;
pub const maximumMagnitude = group_numerics.maximumMagnitude;

// numerics2
pub const hasKineticGeochemistry = group_numerics2.hasKineticGeochemistry;

// phosphate
pub const phosphateExtentBounds = group_phosphate.phosphateExtentBounds;
pub const evaluatePhosphateExtentResiduals = group_phosphate.evaluatePhosphateExtentResiduals;
pub const applyPhosphateExtent = group_phosphate.applyPhosphateExtent;
pub const maximumPhosphateExtent = group_phosphate.maximumPhosphateExtent;
pub const phosphateExtentCharacteristic = group_phosphate.phosphateExtentCharacteristic;
pub const phosphateExtentControlsPackedIndex = group_phosphate.phosphateExtentControlsPackedIndex;
pub const phosphateZoneExtentControlsPackedIndex = group_phosphate.phosphateZoneExtentControlsPackedIndex;
pub const largestPhosphateZoneScaledResidual = group_phosphate.largestPhosphateZoneScaledResidual;
pub const phosphateTrustRegionFraction = group_phosphate.phosphateTrustRegionFraction;
pub const tryPhosphateExtentCandidate = group_phosphate.tryPhosphateExtentCandidate;
pub const solveBoundedPhosphateExtents = group_phosphate.solveBoundedPhosphateExtents;

// reaction span
pub const reactionSpanRowWeight = group_reaction_span.reactionSpanRowWeight;
pub const reactionSpanPredictedNorm = group_reaction_span.reactionSpanPredictedNorm;
pub const evaluateReactionSpanDerivativeColumn = group_reaction_span.evaluateReactionSpanDerivativeColumn;
pub const reactionSpanExtentIsSignificant = group_reaction_span.reactionSpanExtentIsSignificant;
pub const reactionSpanExtentBounds = group_reaction_span.reactionSpanExtentBounds;
pub const solveBoundedReactionSpan = group_reaction_span.solveBoundedReactionSpan;
pub const solveProjectedReactionSpanLeastSquares = group_reaction_span.solveProjectedReactionSpanLeastSquares;
pub const reactionSpanProjectedKktSatisfied = group_reaction_span.reactionSpanProjectedKktSatisfied;

// solve
pub const selectTraceCandidate = group_solve.selectTraceCandidate;
pub const retainBetterCandidate = group_solve.retainBetterCandidate;
pub const retainMeaningfulCandidate = group_solve.retainMeaningfulCandidate;
pub const retainMeaningfulNewtonCandidate = group_solve.retainMeaningfulNewtonCandidate;
pub const candidateCountsAsPicard = group_solve.candidateCountsAsPicard;
pub const andersonTierEnabled = group_solve.andersonTierEnabled;
pub const equilibriumClosureParameters = group_solve.equilibriumClosureParameters;
pub const combineResults = group_solve.combineResults;
pub const rememberHistory = group_solve.rememberHistory;
pub const validateOptions = group_solve.validateOptions;
pub const solveCell = group_solve.solveCell;
pub const solveCellWithTrace = group_solve.solveCellWithTrace;
pub const solveCellWithWorkspace = group_solve.solveCellWithWorkspace;
pub const solveCellWithWorkspaceAndTrace = group_solve.solveCellWithWorkspaceAndTrace;
pub const solveEquilibriumWithWorkspace = group_solve.solveEquilibriumWithWorkspace;
pub const solvePivotedHouseholder = group_solve.solvePivotedHouseholder;

// tests

// types
pub const Options = group_types.Options;
pub const Result = group_types.Result;
pub const CandidateKind = group_types.CandidateKind;
pub const FullNetworkCandidateStatus = group_types.FullNetworkCandidateStatus;
pub const CoupledExtentReaction = group_types.CoupledExtentReaction;
pub const coupled_extent_reaction_count = group_types.coupled_extent_reaction_count;
pub const Workspace = group_types.Workspace;
pub const SolverTrace = group_types.SolverTrace;

test {
    // A bare reference is what makes `zig build test` reach a file.
    _ = @import("reaction_solver_tests.zig");
    _ = group_evaluate;
    _ = @import("phosphate_local_speciation.zig");
    _ = @import("phosphate_surface_stationarity.zig");
    _ = diagnostic_control;
}

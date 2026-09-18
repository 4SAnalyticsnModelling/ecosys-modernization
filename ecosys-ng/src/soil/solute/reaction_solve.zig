//! Split out of reaction_solver.zig by tools/split_decl_group.py.
//! Pure code motion: every decl below is an exact line slice.

const std = @import("std");
const diagnostic_control = @import("reaction_diagnostic_control.zig");
const numerics = @import("../../core/numerics.zig");
const scoped_conservation = @import("../../validation/scoped_conservation.zig");
const chemistry = @import("chemistry_state.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const geochemistry = @import("geochemistry_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const reaction_span = @import("reaction_search_span.zig");
const reaction_progress = @import("reaction_progress.zig");
const reaction_charge = @import("reaction_charge.zig");
const __parent = @import("reaction_solver.zig");
const ComplementaritySearchInputs = __parent.ComplementaritySearchInputs;
const CoupledExtentReaction = __parent.CoupledExtentReaction;
const CandidateKind = __parent.CandidateKind;
const FullNetworkReactionDiagnostic = __parent.FullNetworkReactionDiagnostic;
const IterationDiagnostic = __parent.IterationDiagnostic;
const Options = __parent.Options;
const Result = __parent.Result;
const Workspace = __parent.Workspace;
const applyKineticGeochemistryStep = __parent.applyKineticGeochemistryStep;
const combineResults = __parent.combineResults;
const coupledExtentReactionEnabled = __parent.coupledExtentReactionEnabled;
const coupled_extent_reaction_count = __parent.coupled_extent_reaction_count;
const equilibriumClosureParameters = __parent.equilibriumClosureParameters;
const evaluateAt = __parent.evaluateAt;
const evaluateAtLoaded = __parent.evaluateAtLoaded;
const evaluateGlobalResidualAt = __parent.evaluateGlobalResidualAt;
const exhaustsLargestResidual = __parent.exhaustsLargestResidual;
const hasKineticGeochemistry = __parent.hasKineticGeochemistry;
const largestScaledResidualIndex = __parent.largestScaledResidualIndex;
const logLargestResidual = __parent.logLargestResidual;
const logTerminalReactionDecomposition = __parent.logTerminalReactionDecomposition;
const logTerminalStagnationComponent = __parent.logTerminalStagnationComponent;
const matrixColumnNorm = __parent.matrixColumnNorm;
const maximumDifference = __parent.maximumDifference;
const maximumMagnitude = __parent.maximumMagnitude;
const phosphateExtentBounds = __parent.phosphateExtentBounds;
const rememberHistory = __parent.rememberHistory;
const retainBetterCandidate = __parent.retainBetterCandidate;
const meaningfulNewtonMeritDecrease =
    @import("reaction_try_network.zig").meaningfulNewtonMeritDecrease;
const scaledRmsNorm = __parent.scaledRmsNorm;
const newtonCandidateAcceptable = __parent.newtonCandidateAcceptable;
const residualScale = __parent.residualScale;
const scaledAndersonDepthOneCandidate = __parent.scaledAndersonDepthOneCandidate;
const scaledNorm = __parent.scaledNorm;
const selectTraceCandidate = __parent.selectTraceCandidate;
const transformedVectorAdmissible = __parent.transformedVectorAdmissible;
const tryAcceptAndersonCandidate = __parent.tryAcceptAndersonCandidate;
const tryAnalyticCoordinateNewtonCandidate = __parent.tryAnalyticCoordinateNewtonCandidate;
const tryActiveRowNewtonCandidate = __parent.tryActiveRowNewtonCandidate;
const tryTernaryCorrectionFaceNewtonCandidate = __parent.tryTernaryCorrectionFaceNewtonCandidate;
const ActiveBoundaryRecoveryKind = __parent.ActiveBoundaryRecoveryKind;
const ActiveBoundaryRecoveryFilter = __parent.ActiveBoundaryRecoveryFilter;
const tryGlobalInventoryBoundaryRecoveryCandidate =
    __parent.tryGlobalInventoryBoundaryRecoveryCandidate;
const tryActiveBoundarySurfaceRecoveryCandidateFiltered =
    __parent.tryActiveBoundarySurfaceRecoveryCandidateFiltered;
const tryCurrentSignCoordinateAndersonCandidate = __parent.tryCurrentSignCoordinateAndersonCandidate;
const tryFullNetworkReactionCandidate = __parent.tryFullNetworkReactionCandidate;
const tryPhosphateExtentCandidate = __parent.tryPhosphateExtentCandidate;
const tryRetainedComplementarityCandidate = __parent.tryRetainedComplementarityCandidate;
const validateAqueousMolarity = __parent.validateAqueousMolarity;
const validateOptions = __parent.validateOptions;

/// Replays the source's final RHHX reset once on the terminal accepted
/// nonlinear candidate. Trial projections stay confined to scratch/vector
/// buffers and are never accumulated into the returned balance metadata.
fn commitAcceptedWaterEquilibriumProjection(
    scratch: *chemistry.State,
    state: *chemistry.State,
    cell_index: usize,
    current: []f64,
    parameters: chemistry.ReactionParameters,
) !f64 {
    try scratch.unpackCell(0, current);
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    const water = try water_equilibrium.solve(.{
        .hydrogen_concentration_mol_per_m3 = scratch.aqueous[0].hydrogen,
        .hydroxide_concentration_mol_per_m3 = scratch.aqueous[0].hydroxide,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = parameters.water_activity_product_mol2_per_m6,
        .negligible_concentration_mol_per_m3 = parameters.negligible_water_ion_concentration_mol_per_m3,
    });
    scratch.aqueous[0].hydrogen = water.hydrogen_concentration_mol_per_m3;
    scratch.aqueous[0].hydroxide = water.hydroxide_concentration_mol_per_m3;
    try scratch.packCell(0, current);
    try state.unpackCell(cell_index, current);
    return water.equal_reaction_extent_mol_per_m3;
}
pub fn retainMeaningfulCandidate(
    current_norm: f64,
    best_state: []f64,
    best_residual: []f64,
    best_norm: *f64,
    best_kind: *CandidateKind,
    best_is_picard: *bool,
    candidate_state: []const f64,
    candidate_residual: []const f64,
    candidate_norm: f64,
    candidate_kind: CandidateKind,
    candidate_is_picard: bool,
) bool {
    if (!meaningfulNewtonMeritDecrease(current_norm, candidate_norm))
        return false;
    return retainBetterCandidate(
        best_state,
        best_residual,
        best_norm,
        best_kind,
        best_is_picard,
        candidate_state,
        candidate_residual,
        candidate_norm,
        candidate_kind,
        candidate_is_picard,
    );
}

/// Retains an eligible Newton candidate by the governing scaled maximum
/// residual, using smooth scaled RMS merit only to order equal-maximum
/// descents and bounded ridge-crossing candidates.
pub fn retainMeaningfulNewtonCandidate(
    current_maximum_norm: f64,
    current_merit: f64,
    options: Options,
    best_state: []f64,
    best_residual: []f64,
    best_maximum_norm: *f64,
    best_merit: *f64,
    best_kind: *CandidateKind,
    best_is_picard: *bool,
    candidate_state: []const f64,
    candidate_residual: []const f64,
    candidate_maximum_norm: f64,
    candidate_kind: CandidateKind,
) !bool {
    if (best_state.len != candidate_state.len or
        best_residual.len != candidate_residual.len or
        best_state.len != best_residual.len)
    {
        return false;
    }
    const candidate_merit = try scaledRmsNorm(
        candidate_state,
        candidate_residual,
        options,
    );
    if (!newtonCandidateAcceptable(
        current_maximum_norm,
        current_merit,
        candidate_maximum_norm,
        candidate_merit,
    )) {
        return false;
    }
    // Prefer a Newton direction that decreases the actual L-infinity
    // convergence norm over one that merely crosses a bounded ridge while
    // decreasing the smooth RMS globalization merit. Ridge crossing remains
    // available when no maximum-norm descent exists, but it must not displace
    // a direction that is already moving the terminal criterion downward.
    const candidate_descends_maximum = meaningfulNewtonMeritDecrease(
        current_maximum_norm,
        candidate_maximum_norm,
    );
    const best_descends_maximum = best_kind.* != .none and
        meaningfulNewtonMeritDecrease(
            current_maximum_norm,
            best_maximum_norm.*,
        );
    if (best_descends_maximum and !candidate_descends_maximum) return false;
    if (best_descends_maximum and candidate_descends_maximum) {
        if (candidate_maximum_norm > best_maximum_norm.*) return false;
        if (candidate_maximum_norm == best_maximum_norm.* and
            candidate_merit >= best_merit.*) return false;
    } else if (best_descends_maximum == candidate_descends_maximum and
        candidate_merit >= best_merit.*)
    {
        return false;
    }
    @memcpy(best_state, candidate_state);
    @memcpy(best_residual, candidate_residual);
    best_maximum_norm.* = candidate_maximum_norm;
    best_merit.* = candidate_merit;
    best_kind.* = candidate_kind;
    best_is_picard.* = false;
    return true;
}

fn retainMeaningfulAndersonCandidate(
    current_norm: f64,
    best_state: []f64,
    best_residual: []f64,
    best_norm: *f64,
    best_merit: *f64,
    best_kind: *CandidateKind,
    best_is_picard: *bool,
    candidate_state: []const f64,
    candidate_residual: []const f64,
    candidate_norm: f64,
    candidate_kind: CandidateKind,
) bool {
    if (!numerics.andersonImprovesAcceptedMerit(candidate_norm, current_norm))
        return false;
    const retained = retainMeaningfulCandidate(
        current_norm,
        best_state,
        best_residual,
        best_norm,
        best_kind,
        best_is_picard,
        candidate_state,
        candidate_residual,
        candidate_norm,
        candidate_kind,
        true,
    );
    if (retained) best_merit.* = std.math.inf(f64);
    return retained;
}

pub fn andersonTierEnabled(
    best_newton_kind: CandidateKind,
    current_norm: f64,
    best_newton_norm: f64,
    remaining_iterations: u16,
) bool {
    if (best_newton_kind == .none) return true;
    if (current_norm - best_newton_norm <
        1.0e-6 * @max(1.0, current_norm)) return true;
    if (remaining_iterations == 0 or current_norm <= 1 or
        best_newton_norm <= 1) return false;
    // A hard iteration ceiling must not turn a mathematically descending but
    // asymptotically inadequate Newton step into the only priced direction.
    // Compare logarithmic contraction rates so extreme scaled norms neither
    // overflow nor underflow. Anderson still has to beat the retained Newton
    // candidate on exact global maximum norm before it can be published.
    const available: f64 = @floatFromInt(remaining_iterations);
    const required_log_decrease = @log(current_norm) / available;
    const candidate_log_decrease =
        @log(current_norm) - @log(best_newton_norm);
    return candidate_log_decrease < required_log_decrease;
}

/// Rank-truncated recovery may replace a healthy ordinary Newton candidate
/// only when it wins by at least one binary line-search level. If the ordinary
/// set cannot meet the remaining hard iteration budget, any strict exact
/// descent may enter the normal arbitration.
fn rankRecoveryCandidateEligible(
    ordinary_kind: CandidateKind,
    current_norm: f64,
    ordinary_norm: f64,
    recovery_norm: f64,
    remaining_iterations: u16,
) bool {
    if (!std.math.isFinite(recovery_norm) or recovery_norm >= current_norm)
        return false;
    return andersonTierEnabled(
        ordinary_kind,
        current_norm,
        ordinary_norm,
        remaining_iterations,
    ) or recovery_norm <= 0.5 * ordinary_norm;
}

/// Heap-owned replay diagnostics. Production solvers pass no trace and incur
/// no allocation or logging dependency.
pub const SolverTrace = struct {
    allocator: std.mem.Allocator,
    entries: []IterationDiagnostic,
    count: usize = 0,
    full_network_comparison_valid: bool = false,
    full_network_comparison_closure: u8 = 0,
    full_network_comparison_iteration: u16 = 0,
    full_network_directional_fraction: f64 = 0,
    full_network_comparison_inventory_fraction: f64 = 0,
    full_network_first_trial_fraction: f64 = 0,
    full_network_first_trial_maximum_scaled_residual: f64 =
        std.math.inf(f64),
    full_network_limiting_component_index: usize = 0,
    full_network_reaction_count: usize = 0,
    full_network_reactions: []FullNetworkReactionDiagnostic,
    full_network_complementarity_search_attempted: bool = false,
    full_network_complementarity_ambiguous_count: usize = 0,
    full_network_complementarity_ambiguous_columns: []usize,
    full_network_complementarity_combination_count: usize = 0,
    full_network_complementarity_consistent_count: usize = 0,
    full_network_complementarity_exact_descent_count: usize = 0,
    full_network_complementarity_minimum_mismatch_count: usize =
        std.math.maxInt(usize),
    full_network_complementarity_minimum_mismatch_mask: u64 = 0,
    full_network_complementarity_mismatch_columns: []usize,
    full_network_complementarity_best_mask: u64 = 0,
    full_network_complementarity_best_predicted_merit: f64 =
        std.math.inf(f64),
    full_network_complementarity_best_exact_merit: f64 =
        std.math.inf(f64),
    full_network_complementarity_blend_attempted: bool = false,
    full_network_complementarity_blend_column: usize = 0,
    full_network_complementarity_blend_fraction: f64 =
        std.math.nan(f64),
    full_network_complementarity_blend_solution: f64 =
        std.math.nan(f64),
    full_network_complementarity_blend_predicted_merit: f64 =
        std.math.inf(f64),
    full_network_complementarity_blend_exact_merit: f64 =
        std.math.inf(f64),
    full_network_current_rates: []f64,
    full_network_directional_rates: []f64,
    full_network_base_residual: []f64,
    full_network_predicted_residual: []f64,
    full_network_realized_residual: []f64,

    pub fn init(
        allocator: std.mem.Allocator,
        maximum_entries: usize,
    ) !SolverTrace {
        if (maximum_entries == 0) return error.ZeroSoluteTraceCapacity;
        const entries = try allocator.alloc(
            IterationDiagnostic,
            maximum_entries,
        );
        errdefer allocator.free(entries);
        const component_count = chemistry.State.packedComponentCount();
        const base_residual = try allocator.alloc(f64, component_count);
        errdefer allocator.free(base_residual);
        const predicted_residual =
            try allocator.alloc(f64, component_count);
        errdefer allocator.free(predicted_residual);
        const realized_residual =
            try allocator.alloc(f64, component_count);
        errdefer allocator.free(realized_residual);
        const reactions = try allocator.alloc(
            FullNetworkReactionDiagnostic,
            reaction_span.reaction_count,
        );
        errdefer allocator.free(reactions);
        const ambiguous_columns = try allocator.alloc(
            usize,
            reaction_span.reaction_count,
        );
        errdefer allocator.free(ambiguous_columns);
        const mismatch_columns = try allocator.alloc(
            usize,
            reaction_span.reaction_count,
        );
        errdefer allocator.free(mismatch_columns);
        const current_rates = try allocator.alloc(
            f64,
            reaction_span.reaction_count,
        );
        errdefer allocator.free(current_rates);
        const directional_rates = try allocator.alloc(
            f64,
            reaction_span.reaction_count,
        );
        return .{
            .allocator = allocator,
            .entries = entries,
            .full_network_reactions = reactions,
            .full_network_complementarity_ambiguous_columns = ambiguous_columns,
            .full_network_complementarity_mismatch_columns = mismatch_columns,
            .full_network_current_rates = current_rates,
            .full_network_directional_rates = directional_rates,
            .full_network_base_residual = base_residual,
            .full_network_predicted_residual = predicted_residual,
            .full_network_realized_residual = realized_residual,
        };
    }

    pub fn deinit(self: *SolverTrace) void {
        self.allocator.free(self.full_network_directional_rates);
        self.allocator.free(self.full_network_current_rates);
        self.allocator.free(
            self.full_network_complementarity_ambiguous_columns,
        );
        self.allocator.free(
            self.full_network_complementarity_mismatch_columns,
        );
        self.allocator.free(self.full_network_reactions);
        self.allocator.free(self.full_network_realized_residual);
        self.allocator.free(self.full_network_predicted_residual);
        self.allocator.free(self.full_network_base_residual);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn recorded(self: *const SolverTrace) []const IterationDiagnostic {
        return self.entries[0..self.count];
    }

    fn append(
        self: *SolverTrace,
        diagnostic: IterationDiagnostic,
    ) !*IterationDiagnostic {
        if (self.count == self.entries.len)
            return error.SoluteTraceCapacityExceeded;
        self.entries[self.count] = diagnostic;
        self.count += 1;
        return &self.entries[self.count - 1];
    }
};

/// Element and exchanger invariants of one reaction cell, expressed per
/// whole-layer water volume except for the three explicitly mass-specific
/// exchanger/site coordinates. The nonlinear solve has separate residual
/// tolerances; these values are reconstructed only for accepted-state
/// conservation.
const AcceptedStateInventory = struct {
    carbon_mol_per_m3: f64,
    nitrogen_mol_per_m3: f64,
    phosphorus_mol_per_m3: f64,
    aluminum_mol_per_m3: f64,
    iron_mol_per_m3: f64,
    calcium_mol_per_m3: f64,
    magnesium_mol_per_m3: f64,
    sodium_mol_per_m3: f64,
    potassium_mol_per_m3: f64,
    sulfur_mol_per_m3: f64,
    chloride_mol_per_m3: f64,
    silicon_mol_per_m3: f64,
    cation_exchange_charge_mol_per_megagram: f64,
    non_band_phosphate_sites_mol_per_megagram: f64,
    band_phosphate_sites_mol_per_megagram: f64,
};

const PhosphateZoneInventory = struct {
    phosphorus_mol_per_m3: f64,
    aluminum_mol_per_m3: f64,
    iron_mol_per_m3: f64,
    calcium_mol_per_m3: f64,
    magnesium_mol_per_m3: f64,
    sites_mol_per_megagram: f64,
};

fn phosphateZoneInventory(
    zone: anytype,
    soil_mass_per_water_volume_megagrams_per_m3: f64,
) !PhosphateZoneInventory {
    if (!std.math.isFinite(soil_mass_per_water_volume_megagrams_per_m3) or
        soil_mass_per_water_volume_megagrams_per_m3 < 0)
        return error.InvalidSoluteReactionConservationBasis;
    inline for (std.meta.fields(@TypeOf(zone))) |field| {
        const value = @field(zone, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSoluteReactionConservationInventory;
    }
    const adsorbed_phosphorus =
        soil_mass_per_water_volume_megagrams_per_m3 *
        (zone.adsorbed_hpo4_mol_p_per_megagram +
            zone.adsorbed_h2po4_mol_p_per_megagram);
    const phosphorus = zone.dissolved_po4_mol_p_per_m3 +
        zone.dissolved_hpo4_mol_p_per_m3 +
        zone.dissolved_h2po4_mol_p_per_m3 +
        zone.dissolved_h3po4_mol_p_per_m3 +
        adsorbed_phosphorus +
        zone.aluminum_phosphate_solid_mol_per_m3 +
        zone.iron_phosphate_solid_mol_per_m3 +
        zone.dicalcium_phosphate_solid_mol_per_m3 +
        3 * zone.hydroxyapatite_solid_mol_per_m3 +
        2 * zone.monocalcium_phosphate_solid_mol_per_m3 +
        zone.iron_hpo4_pair_mol_per_m3 +
        zone.iron_h2po4_pair_mol_per_m3 +
        zone.calcium_po4_pair_mol_per_m3 +
        zone.calcium_hpo4_pair_mol_per_m3 +
        zone.calcium_h2po4_pair_mol_per_m3 +
        zone.magnesium_hpo4_pair_mol_per_m3;
    const sites = zone.deprotonated_site_mol_per_megagram +
        zone.hydroxyl_site_mol_per_megagram +
        zone.protonated_site_mol_per_megagram +
        zone.adsorbed_hpo4_mol_p_per_megagram +
        zone.adsorbed_h2po4_mol_p_per_megagram;
    const result: PhosphateZoneInventory = .{
        .phosphorus_mol_per_m3 = phosphorus,
        .aluminum_mol_per_m3 = zone.aluminum_phosphate_solid_mol_per_m3,
        .iron_mol_per_m3 = zone.iron_phosphate_solid_mol_per_m3 +
            zone.iron_hpo4_pair_mol_per_m3 +
            zone.iron_h2po4_pair_mol_per_m3,
        .calcium_mol_per_m3 = zone.dicalcium_phosphate_solid_mol_per_m3 +
            5 * zone.hydroxyapatite_solid_mol_per_m3 +
            zone.monocalcium_phosphate_solid_mol_per_m3 +
            zone.calcium_po4_pair_mol_per_m3 +
            zone.calcium_hpo4_pair_mol_per_m3 +
            zone.calcium_h2po4_pair_mol_per_m3,
        .magnesium_mol_per_m3 = zone.magnesium_hpo4_pair_mol_per_m3,
        .sites_mol_per_megagram = sites,
    };
    inline for (std.meta.fields(PhosphateZoneInventory)) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSoluteReactionConservationInventory;
    }
    return result;
}

fn inventoryPhosphateZone(zone: phosphate_network.State, comptime include_immobile: bool) phosphate_network.State {
    @setEvalBranchQuota(20000);
    var result = zone;
    if (!include_immobile) inline for (std.meta.fields(phosphate_network.State)) |field| {
        if (comptime std.mem.indexOf(u8, field.name, "solid") != null or std.mem.endsWith(u8, field.name, "megagram")) @field(result, field.name) = 0;
    };
    return result;
}

pub fn acceptedStateInventory(state: *const chemistry.State, cell_index: usize, parameters: chemistry.ReactionParameters) !AcceptedStateInventory {
    return stateInventory(state, cell_index, parameters, true, true);
}

/// Dissolved elemental census, excluding solid and exchange reservoirs.
pub fn mobileStateInventory(state: *const chemistry.State, cell_index: usize, parameters: chemistry.ReactionParameters) !AcceptedStateInventory {
    return stateInventory(state, cell_index, parameters, false, false);
}
fn stateInventory(
    state: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    comptime include_immobile: bool,
    comptime include_geochemistry: bool,
) !AcceptedStateInventory {
    if (cell_index >= state.cell_count)
        return error.ChemistryCellIndexOutOfBounds;
    const fractions = parameters.fractions;
    inline for (std.meta.fields(@TypeOf(fractions))) |field| {
        const value = @field(fractions, field.name);
        if (!std.math.isFinite(value) or value < 0 or value > 1)
            return error.InvalidSoluteReactionConservationBasis;
    }
    const ratios = parameters.cation_exchange_water_ratios;
    inline for (std.meta.fields(@TypeOf(ratios))) |field| {
        const value = @field(ratios, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSoluteReactionConservationBasis;
    }

    const aqueous = state.aqueous[cell_index];
    const exchange = if (include_immobile) state.cation_exchange_mol_per_megagram[cell_index] else std.mem.zeroes(cation_exchange.Cations);
    const solids = if (include_geochemistry) state.geochemistry_solids[cell_index] else std.mem.zeroes(geochemistry.SolidState);
    inline for (.{ aqueous, exchange, solids }) |value| {
        inline for (std.meta.fields(@TypeOf(value))) |field| {
            const component = @field(value, field.name);
            if (!std.math.isFinite(component) or component < 0)
                return error.InvalidSoluteReactionConservationInventory;
        }
    }
    const non_band = try phosphateZoneInventory(
        inventoryPhosphateZone(state.non_band_phosphate[cell_index], include_immobile),
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
    );
    const band = try phosphateZoneInventory(
        inventoryPhosphateZone(state.band_phosphate[cell_index], include_immobile),
        parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
    );

    const aluminum_silicate =
        solids.aluminum_natural_silicate_mol_per_m3 +
        solids.aluminum_ground_silicate_mol_per_m3;
    const iron_silicate = solids.iron_natural_silicate_mol_per_m3 +
        solids.iron_ground_silicate_mol_per_m3;
    const calcium_silicate = solids.calcium_natural_silicate_mol_per_m3 +
        solids.calcium_ground_silicate_mol_per_m3;
    const magnesium_silicate =
        solids.magnesium_natural_silicate_mol_per_m3 +
        solids.magnesium_ground_silicate_mol_per_m3;
    const sodium_silicate = solids.sodium_natural_silicate_mol_per_m3 +
        solids.sodium_ground_silicate_mol_per_m3;
    const potassium_silicate =
        solids.potassium_natural_silicate_mol_per_m3 +
        solids.potassium_ground_silicate_mol_per_m3;

    const result: AcceptedStateInventory = .{
        .carbon_mol_per_m3 = aqueous.carbon_dioxide + aqueous.carbonate +
            aqueous.bicarbonate + aqueous.calcium_carbonate +
            aqueous.calcium_bicarbonate + aqueous.magnesium_carbonate +
            aqueous.magnesium_bicarbonate + aqueous.sodium_carbonate +
            solids.calcite_solid_mol_per_m3,
        .nitrogen_mol_per_m3 = fractions.ammonium_non_band *
            (aqueous.ammonium_non_band + aqueous.ammonia_non_band +
                ratios.ammonium_non_band_megagrams_per_m3 *
                    exchange.ammonium_non_band) +
            fractions.ammonium_band *
                (aqueous.ammonium_band + aqueous.ammonia_band +
                    ratios.ammonium_band_megagrams_per_m3 *
                        exchange.ammonium_band) +
            fractions.nitrate_non_band * aqueous.nitrate_non_band +
            fractions.nitrate_band * aqueous.nitrate_band,
        .phosphorus_mol_per_m3 = fractions.phosphate_non_band *
            non_band.phosphorus_mol_per_m3 +
            fractions.phosphate_band * band.phosphorus_mol_per_m3,
        .aluminum_mol_per_m3 = aqueous.aluminum +
            aqueous.aluminum_hydroxide_1 + aqueous.aluminum_hydroxide_2 +
            aqueous.aluminum_hydroxide_3 + aqueous.aluminum_hydroxide_4 +
            aqueous.aluminum_sulfate + ratios.shared_megagrams_per_m3 *
            exchange.aluminum + solids.gibbsite_solid_mol_per_m3 +
            aluminum_silicate + fractions.phosphate_non_band *
            non_band.aluminum_mol_per_m3 + fractions.phosphate_band *
            band.aluminum_mol_per_m3,
        .iron_mol_per_m3 = aqueous.iron + aqueous.iron_hydroxide_1 +
            aqueous.iron_hydroxide_2 + aqueous.iron_hydroxide_3 +
            aqueous.iron_hydroxide_4 + aqueous.iron_sulfate +
            ratios.shared_megagrams_per_m3 * exchange.iron +
            solids.iron_hydroxide_solid_mol_per_m3 + iron_silicate +
            fractions.phosphate_non_band * non_band.iron_mol_per_m3 +
            fractions.phosphate_band * band.iron_mol_per_m3,
        .calcium_mol_per_m3 = aqueous.calcium + aqueous.calcium_hydroxide +
            aqueous.calcium_carbonate + aqueous.calcium_bicarbonate +
            aqueous.calcium_sulfate + ratios.shared_megagrams_per_m3 *
            exchange.calcium + solids.calcite_solid_mol_per_m3 +
            solids.gypsum_solid_mol_per_m3 + calcium_silicate +
            fractions.phosphate_non_band * non_band.calcium_mol_per_m3 +
            fractions.phosphate_band * band.calcium_mol_per_m3,
        .magnesium_mol_per_m3 = aqueous.magnesium +
            aqueous.magnesium_hydroxide + aqueous.magnesium_carbonate +
            aqueous.magnesium_bicarbonate + aqueous.magnesium_sulfate +
            ratios.shared_megagrams_per_m3 * exchange.magnesium +
            magnesium_silicate + fractions.phosphate_non_band *
            non_band.magnesium_mol_per_m3 + fractions.phosphate_band *
            band.magnesium_mol_per_m3,
        .sodium_mol_per_m3 = aqueous.sodium + aqueous.sodium_carbonate +
            aqueous.sodium_sulfate + ratios.shared_megagrams_per_m3 *
            exchange.sodium + sodium_silicate,
        .potassium_mol_per_m3 = aqueous.potassium +
            aqueous.potassium_sulfate + ratios.shared_megagrams_per_m3 *
            exchange.potassium + potassium_silicate,
        .sulfur_mol_per_m3 = aqueous.sulfate + aqueous.aluminum_sulfate +
            aqueous.iron_sulfate + aqueous.calcium_sulfate +
            aqueous.magnesium_sulfate + aqueous.sodium_sulfate +
            aqueous.potassium_sulfate + solids.gypsum_solid_mol_per_m3,
        .chloride_mol_per_m3 = aqueous.chloride,
        .silicon_mol_per_m3 = aqueous.hydrogen_silicate +
            0.75 * (aluminum_silicate + iron_silicate) +
            0.5 * (calcium_silicate + magnesium_silicate) +
            0.25 * (sodium_silicate + potassium_silicate),
        .cation_exchange_charge_mol_per_megagram = fractions.ammonium_non_band *
            exchange.ammonium_non_band + fractions.ammonium_band * exchange.ammonium_band +
            exchange.hydrogen + 3 * (exchange.aluminum + exchange.iron) +
            2 * (exchange.calcium + exchange.magnesium) + exchange.sodium +
            exchange.potassium,
        .non_band_phosphate_sites_mol_per_megagram = non_band.sites_mol_per_megagram,
        .band_phosphate_sites_mol_per_megagram = band.sites_mol_per_megagram,
    };
    inline for (std.meta.fields(AcceptedStateInventory)) |field| {
        const value = @field(result, field.name);
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidSoluteReactionConservationInventory;
    }
    return result;
}

fn acceptedStateConservationTolerance(before: f64, after: f64) scoped_conservation.Tolerance {
    // The longest census above contains fewer than 32 nonnegative additions.
    // 2048 ulps of the standing inventory covers both censuses plus the
    // stoichiometric update chain without becoming a physical-unit threshold.
    const scale = @max(@abs(before), @abs(after));
    return .{
        .absolute = 2048 * std.math.floatEps(f64) *
            @max(std.math.floatMin(f64), scale),
        .relative = 64 * std.math.floatEps(f64),
    };
}

pub fn requireConservedInventories(before: AcceptedStateInventory, after: AcceptedStateInventory) !void {
    inline for (std.meta.fields(AcceptedStateInventory)) |field| {
        const before_value = @field(before, field.name);
        const after_value = @field(after, field.name);
        const closure = scoped_conservation.evaluate(.{
            .storage_before = before_value,
            .storage_after = after_value,
        }, acceptedStateConservationTolerance(before_value, after_value)) catch
            return error.SoluteReactionAcceptedStateConservationFailure;
        if (!closure.accepted) {
            if (diagnostic_control.isEnabled()) std.log.warn("SOLUTE retained-state inventory failure: inventory={s} before={e} after={e} residual={e} limit={e}", .{ field.name, before_value, after_value, closure.residual, closure.effective_acceptance_limit });
            return error.SoluteReactionAcceptedStateConservationFailure;
        }
    }
}

/// Keeps the best chemical-quality score only after validating bounds and the same
/// entry inventories used by the terminal conservation check. Search probes
/// never call this function and cannot overwrite the retained iterate.
pub fn retainBestBoundedIterate(
    workspace: *Workspace,
    entry: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    quality_norm: f64,
    iteration: u16,
) !bool {
    if (!std.math.isFinite(quality_norm) or quality_norm >= workspace.best_bounded_maximum) return false;
    const projected_hydrogen = workspace.scratch.aqueous[0].hydrogen;
    const projected_hydroxide = workspace.scratch.aqueous[0].hydroxide;
    defer {
        workspace.scratch.aqueous[0].hydrogen = projected_hydrogen;
        workspace.scratch.aqueous[0].hydroxide = projected_hydroxide;
    }
    try workspace.scratch.unpackCell(0, workspace.current);
    try validateAqueousMolarity(&workspace.scratch, 0);
    const before = try acceptedStateInventory(entry, cell_index, parameters);
    const after = try acceptedStateInventory(&workspace.scratch, 0, parameters);
    try requireConservedInventories(before, after);
    reaction_charge.requireConservedStates(entry, cell_index, &workspace.scratch, 0, parameters) catch |err| {
        if (diagnostic_control.isEnabled()) std.log.warn("SOLUTE retained-state charge rejection: iteration={d} candidate={s}", .{ iteration, @tagName(workspace.last_selected_candidate) });
        return err;
    };
    const capacity = parameters.total_carboxyl_sites_mol_per_megagram;
    const occupied = workspace.scratch.carboxyl_bound_hydrogen_mol_per_megagram[0];
    if (occupied > capacity + acceptedStateConservationTolerance(capacity, occupied).absolute)
        return error.SoluteReactionAcceptedStateConservationFailure;
    @memcpy(workspace.best_bounded_state, workspace.current);
    @memcpy(workspace.best_bounded_residual, workspace.residual);
    workspace.best_bounded_maximum = quality_norm;
    workspace.best_bounded_iteration = iteration;
    workspace.best_bounded_kind = workspace.last_selected_candidate;
    return true;
}

fn restoreBestBoundedIterate(workspace: *Workspace, options: Options) void {
    if (workspace.best_bounded_iteration == null) return;
    @memcpy(workspace.current, workspace.best_bounded_state);
    @memcpy(workspace.residual, workspace.best_bounded_residual);
    workspace.last_selected_candidate = workspace.best_bounded_kind;
    workspace.last_search_metric = .{
        .component = largestScaledResidualIndex(workspace.current, workspace.residual, options),
        .maximum = scaledNorm(workspace.current, workspace.residual, options) catch std.math.inf(f64),
        .rms = scaledRmsNorm(workspace.current, workspace.residual, options) catch std.math.inf(f64),
    };
}

/// Independently verifies the final accepted chemistry state against the
/// entry snapshot. This is deliberately outside nonlinear convergence: a
/// small residual cannot authorize an elemental or exchanger leak.
pub fn requireAcceptedStateConservation(
    scratch: *chemistry.State,
    state: *const chemistry.State,
    cell_index: usize,
    original_state: []const f64,
    parameters: chemistry.ReactionParameters,
) !void {
    if (scratch.cell_count != 1)
        return error.InvalidSoluteReactionConservationScratch;
    try scratch.unpackCell(0, original_state);
    const before = acceptedStateInventory(scratch, 0, parameters) catch
        return error.SoluteReactionAcceptedStateConservationFailure;
    const after = acceptedStateInventory(state, cell_index, parameters) catch
        return error.SoluteReactionAcceptedStateConservationFailure;
    try reaction_charge.requireConservedStates(scratch, 0, state, cell_index, parameters);
    inline for (std.meta.fields(AcceptedStateInventory)) |field| {
        const before_value = @field(before, field.name);
        const after_value = @field(after, field.name);
        const closure = scoped_conservation.evaluate(.{
            .storage_before = before_value,
            .storage_after = after_value,
        }, acceptedStateConservationTolerance(before_value, after_value)) catch
            return error.SoluteReactionAcceptedStateConservationFailure;
        if (!closure.accepted) {
            if (diagnostic_control.isEnabled()) std.log.warn(
                "SOLUTE accepted-state conservation failure: inventory={s} before={e} after={e} residual={e} acceptance_limit={e} arithmetic_roundoff_allowance={e} effective_limit={e}",
                .{
                    field.name,
                    before_value,
                    after_value,
                    closure.residual,
                    closure.acceptance_limit,
                    closure.arithmetic_roundoff_allowance,
                    closure.effective_acceptance_limit,
                },
            );
            return error.SoluteReactionAcceptedStateConservationFailure;
        }
    }
    const carboxyl_bound_before =
        scratch.carboxyl_bound_hydrogen_mol_per_megagram[0];
    const carboxyl_bound_after =
        state.carboxyl_bound_hydrogen_mol_per_megagram[cell_index];
    const carboxyl_capacity = parameters.total_carboxyl_sites_mol_per_megagram;
    if (!std.math.isFinite(carboxyl_capacity) or carboxyl_capacity < 0)
        return error.SoluteReactionAcceptedStateConservationFailure;
    const capacity_tolerance = acceptedStateConservationTolerance(
        carboxyl_capacity,
        @max(carboxyl_bound_before, carboxyl_bound_after),
    ).absolute;
    // Capacity is derived from live organic carbon and can decrease between
    // calls.  An over-capacity entry is therefore a condition this solve must
    // repair, not grounds for rejecting a physically valid repaired endpoint.
    if (carboxyl_bound_after > carboxyl_capacity + capacity_tolerance) {
        if (diagnostic_control.isEnabled()) std.log.warn(
            "SOLUTE accepted-state carboxyl capacity failure: before={e} after={e} capacity={e} tolerance={e}",
            .{ carboxyl_bound_before, carboxyl_bound_after, carboxyl_capacity, capacity_tolerance },
        );
        return error.SoluteReactionAcceptedStateConservationFailure;
    }
}

/// Coupled conservative Newton-Raphson/Picard solve for one runtime cell.
/// Newton acceleration changes only conservative stoichiometric reaction
/// extents, so elemental and exchange-site inventories cannot be broken by
/// independent concentration corrections.
pub fn solveCell(allocator: std.mem.Allocator, state: *chemistry.State, cell_index: usize, parameters: chemistry.ReactionParameters, options: Options) !Result {
    var workspace = try Workspace.init(allocator);
    defer workspace.deinit();
    return solveCellWithWorkspace(&workspace, state, cell_index, parameters, options);
}

/// Allocation-free solve for hourly kernels. A workspace is exclusively owned
/// by one worker and can be reused for any number of runtime soil layers.
pub fn solveCellWithWorkspace(workspace: *Workspace, state: *chemistry.State, cell_index: usize, parameters: chemistry.ReactionParameters, options: Options) !Result {
    return solveCellWithWorkspaceAndTrace(
        workspace,
        state,
        cell_index,
        parameters,
        options,
        null,
    );
}

/// Diagnostic solve with the same transactional production path and a
/// caller-owned heap trace. Intended for deterministic failure replay.
pub fn solveCellWithTrace(
    allocator: std.mem.Allocator,
    state: *chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    options: Options,
    trace: *SolverTrace,
) !Result {
    var workspace = try Workspace.init(allocator);
    defer workspace.deinit();
    trace.count = 0;
    trace.full_network_comparison_valid = false;
    trace.full_network_reaction_count = 0;
    trace.full_network_complementarity_search_attempted = false;
    trace.full_network_complementarity_ambiguous_count = 0;
    trace.full_network_complementarity_combination_count = 0;
    trace.full_network_complementarity_consistent_count = 0;
    trace.full_network_complementarity_exact_descent_count = 0;
    trace.full_network_complementarity_minimum_mismatch_count =
        std.math.maxInt(usize);
    trace.full_network_complementarity_minimum_mismatch_mask = 0;
    trace.full_network_complementarity_best_mask = 0;
    trace.full_network_complementarity_best_predicted_merit =
        std.math.inf(f64);
    trace.full_network_complementarity_best_exact_merit =
        std.math.inf(f64);
    trace.full_network_complementarity_blend_attempted = false;
    trace.full_network_complementarity_blend_column = 0;
    trace.full_network_complementarity_blend_fraction =
        std.math.nan(f64);
    trace.full_network_complementarity_blend_solution =
        std.math.nan(f64);
    trace.full_network_complementarity_blend_predicted_merit =
        std.math.inf(f64);
    trace.full_network_complementarity_blend_exact_merit =
        std.math.inf(f64);
    return solveCellWithWorkspaceAndTrace(
        &workspace,
        state,
        cell_index,
        parameters,
        options,
        trace,
    );
}

/// Restores the physical carboxyl-site domain after live organic-carbon
/// turnover lowers capacity between chemistry calls.  The released bound H+
/// is transferred through the same atomic stoichiometric update used by the
/// nonlinear solver; the caller's entry snapshot remains the rollback and
/// accepted-state conservation reference.
pub fn rebaseEntryCarboxylCapacity(
    state: *chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
) !void {
    if (cell_index >= state.cell_count)
        return error.ChemistryCellIndexOutOfBounds;
    const capacity = parameters.total_carboxyl_sites_mol_per_megagram;
    if (!std.math.isFinite(capacity) or capacity < 0)
        return error.InvalidCarboxylExchangeInput;
    const occupied =
        state.carboxyl_bound_hydrogen_mol_per_megagram[cell_index];
    if (!std.math.isFinite(occupied) or occupied < 0)
        return error.InvalidCarboxylExchangeInput;
    if (occupied <= capacity) return;
    const density =
        parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
    if (!std.math.isFinite(density) or density <= 0)
        return error.ZeroCarboxylExchangeSoilWaterRatio;

    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    transformations.carboxyl_hydrogen_change_mol_per_megagram =
        capacity - occupied;
    transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3 =
        density;
    transformations.cation_exchange_water_ratios =
        parameters.cation_exchange_water_ratios;
    try state.state_updateCell(cell_index, transformations);
    try validateAqueousMolarity(state, cell_index);
}

pub fn solveCellWithWorkspaceAndTrace(
    workspace: *Workspace,
    state: *chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    options: Options,
    trace: ?*SolverTrace,
) !Result {
    diagnostic_control.resetPhaseProfile();
    const profile_started = diagnostic_control.tick();
    defer {
        diagnostic_control.recordSolveTotalCycles(profile_started);
        diagnostic_control.reportPhaseProfile(cell_index);
    }
    // A rejected entry must not expose a retained iterate from another cell.
    workspace.best_bounded_maximum = std.math.inf(f64);
    workspace.best_bounded_iteration = null;
    workspace.best_bounded_kind = .none;
    workspace.last_iteration = 0;
    workspace.last_search_metric = null;
    workspace.last_selected_candidate = .none;
    try validateOptions(options);
    if (cell_index >= state.cell_count)
        return error.ChemistryCellIndexOutOfBounds;
    try validateAqueousMolarity(state, cell_index);
    try state.packCell(cell_index, workspace.rollback_state);
    const original_state = workspace.rollback_state;
    errdefer state.unpackCell(cell_index, original_state) catch
        @panic("validated SOLUTE rollback state could not be restored");
    try rebaseEntryCarboxylCapacity(state, cell_index, parameters);

    const equilibrium_parameters = equilibriumClosureParameters(parameters);
    const first = try solveEquilibriumWithWorkspace(
        workspace,
        state,
        cell_index,
        equilibrium_parameters,
        options,
        trace,
        0,
    );
    if (!hasKineticGeochemistry(parameters)) {
        try requireAcceptedStateConservation(
            &workspace.scratch,
            state,
            cell_index,
            original_state,
            parameters,
        );
        return first;
    }

    if (first.iterations >= options.max_iterations) {
        if (diagnostic_control.isEnabled()) std.log.warn(
            "SOLUTE geochemistry split exhausted its shared iteration ceiling before post-kinetic equilibrium: cell={d} max_iterations={d}",
            .{ cell_index, options.max_iterations },
        );
        return error.SoluteReactionSolverDidNotConverge;
    }
    try applyKineticGeochemistryStep(
        &workspace.scratch,
        state,
        cell_index,
        parameters,
        workspace.current,
    );
    var second_options = options;
    second_options.max_iterations -= first.iterations;
    const second = try solveEquilibriumWithWorkspace(
        workspace,
        state,
        cell_index,
        equilibrium_parameters,
        second_options,
        trace,
        1,
    );
    try requireAcceptedStateConservation(
        &workspace.scratch,
        state,
        cell_index,
        original_state,
        parameters,
    );
    return combineResults(first, second);
}

fn elementSearchReference(name: []const u8, inventory: AcceptedStateInventory, fallback: f64) f64 {
    if (std.mem.indexOf(u8, name, "ammon") != null or std.mem.indexOf(u8, name, "nitrate") != null) return inventory.nitrogen_mol_per_m3;
    if (std.mem.startsWith(u8, name, "aluminum") or std.mem.startsWith(u8, name, "gibbsite")) return inventory.aluminum_mol_per_m3;
    if (std.mem.startsWith(u8, name, "iron")) return inventory.iron_mol_per_m3;
    if (std.mem.startsWith(u8, name, "calcium") or std.mem.startsWith(u8, name, "calcite") or std.mem.startsWith(u8, name, "gypsum")) return inventory.calcium_mol_per_m3;
    if (std.mem.startsWith(u8, name, "magnesium")) return inventory.magnesium_mol_per_m3;
    if (std.mem.startsWith(u8, name, "sodium")) return inventory.sodium_mol_per_m3;
    if (std.mem.startsWith(u8, name, "potassium")) return inventory.potassium_mol_per_m3;
    if (std.mem.indexOf(u8, name, "carbon") != null) return inventory.carbon_mol_per_m3;
    if (std.mem.eql(u8, name, "sulfate")) return inventory.sulfur_mol_per_m3;
    if (std.mem.eql(u8, name, "chloride")) return inventory.chloride_mol_per_m3;
    if (std.mem.eql(u8, name, "hydrogen_silicate")) return inventory.silicon_mol_per_m3;
    return fallback;
}

fn initializeSearchReferences(state: *const chemistry.State, cell_index: usize, parameters: chemistry.ReactionParameters, inventory: AcceptedStateInventory, water_ion_reference: f64, output: []f64) !void {
    try state.packCell(cell_index, output);
    var cursor: usize = 0;
    inline for (std.meta.fields(@TypeOf(state.aqueous[cell_index]))) |field| {
        const reference = if (comptime std.mem.eql(u8, field.name, "hydrogen") or std.mem.eql(u8, field.name, "hydroxide")) water_ion_reference else elementSearchReference(field.name, inventory, output[cursor]);
        output[cursor] = @max(output[cursor], reference);
        cursor += 1;
    }
    for ([_]@TypeOf(state.non_band_phosphate[cell_index]){ state.non_band_phosphate[cell_index], state.band_phosphate[cell_index] }, 0..) |zone, zone_index| {
        const density = if (zone_index == 0) parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 else parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
        const totals = try phosphateZoneInventory(zone, density);
        inline for (std.meta.fields(@TypeOf(zone))) |field| {
            const reference = if (comptime std.mem.endsWith(u8, field.name, "megagram")) totals.sites_mol_per_megagram else totals.phosphorus_mol_per_m3;
            output[cursor] = @max(output[cursor], reference);
            cursor += 1;
        }
    }
    inline for (std.meta.fields(@TypeOf(state.cation_exchange_mol_per_megagram[cell_index]))) |_| {
        output[cursor] = @max(output[cursor], inventory.cation_exchange_charge_mol_per_megagram);
        cursor += 1;
    }
    output[cursor] = @max(output[cursor], parameters.total_carboxyl_sites_mol_per_megagram);
    cursor += 1;
    inline for (std.meta.fields(@TypeOf(state.geochemistry_solids[cell_index]))) |field| {
        output[cursor] = @max(output[cursor], elementSearchReference(field.name, inventory, output[cursor]));
        cursor += 1;
    }
    std.debug.assert(cursor + 1 == output.len);
}

const EquilibriumAttemptCounts = struct {
    newton_steps: u16 = 0,
    anderson_steps: u16 = 0,
};

fn equilibriumSearchInventory(state: *const chemistry.State, cell_index: usize, parameters: chemistry.ReactionParameters, full_inventory: AcceptedStateInventory) !AcceptedStateInventory {
    // Public equilibrium diagnostics may supply enabled kinetic reactions.
    // Exclude these stocks only when all geochemistry rates are disabled.
    if (hasKineticGeochemistry(parameters)) return full_inventory;
    return stateInventory(state, cell_index, parameters, true, false);
}

test "reaction solver excludes only inactive geochemistry from search inventory" {
    var captured = try retryTestCapture(@embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64"));
    defer captured.deinit();
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var parameters = equilibriumClosureParameters(captured.parameters);
    parameters.fractions.phosphate_non_band = 1;
    parameters.fractions.phosphate_band = 0;
    parameters.cation_exchange_water_ratios.shared_megagrams_per_m3 = 2;
    state.aqueous[0].iron = 2;
    state.non_band_phosphate[0].iron_phosphate_solid_mol_per_m3 = 3;
    state.cation_exchange_mol_per_megagram[0].iron = 5;
    state.geochemistry_solids[0].iron_hydroxide_solid_mol_per_m3 = 7;
    state.geochemistry_solids[0].iron_natural_silicate_mol_per_m3 = 13;
    state.geochemistry_solids[0].iron_ground_silicate_mol_per_m3 = 17;
    var before: [chemistry.State.packedComponentCount()]f64 = undefined;
    var after: @TypeOf(before) = undefined;
    try state.packCell(0, &before);
    const full = try acceptedStateInventory(&state, 0, parameters);
    const search = try equilibriumSearchInventory(&state, 0, parameters, full);
    try std.testing.expectEqual(@as(f64, 52), full.iron_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 15), search.iron_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 3), search.phosphorus_mol_per_m3);
    try std.testing.expectEqual(@as(f64, 15), search.cation_exchange_charge_mol_per_megagram);
    try std.testing.expectEqual(@as(f64, 2), (try mobileStateInventory(&state, 0, parameters)).iron_mol_per_m3);
    try state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &before, &after);

    state.geochemistry_solids[0].iron_natural_silicate_mol_per_m3 = 13000;
    const enlarged_full = try acceptedStateInventory(&state, 0, parameters);
    const enlarged_search = try equilibriumSearchInventory(&state, 0, parameters, enlarged_full);
    try std.testing.expect(std.meta.eql(search, enlarged_search));
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    try std.testing.expectError(error.SoluteReactionAcceptedStateConservationFailure, requireConservedInventories(full, enlarged_full));
    parameters.geochemistry_kinetics.maximum_hydroxide_mineral_mol_per_m3_step = 1;
    try std.testing.expect(std.meta.eql(enlarged_full, try equilibriumSearchInventory(&state, 0, parameters, enlarged_full)));
}

fn retryTestCapture(comptime encoded: []const u8) !@import("failure_snapshot.zig").ReplayCase {
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    return @import("failure_snapshot.zig").read(std.testing.allocator, &reader);
}

// Scripted attempts test only the coordinator protocol. Native chemistry,
// accepted-state invariants and rollback are exercised separately below.
const RetryContractPlan = struct {
    budget: u16,
    cold_iterations: u16,
    cold_counts: EquilibriumAttemptCounts = .{ .newton_steps = 1, .anderson_steps = 1 },
    cold_error: anyerror = error.SoluteReactionSolverStagnated,
    retry_iterations: u16 = 2,
    retry_counts: EquilibriumAttemptCounts = .{ .newton_steps = 1 },
    retry_error: ?anyerror = null,
};

fn ScriptedRetryAttempt(comptime plan: RetryContractPlan) type {
    return struct {
        fn run(workspace: *Workspace, _: *chemistry.State, _: usize, _: chemistry.ReactionParameters, options: Options, trace: ?*SolverTrace, closure: u8, comptime continuation: bool, offset: u16, counts: *EquilibriumAttemptCounts) !Result {
            try std.testing.expectEqual(if (continuation) plan.budget - plan.cold_iterations else plan.budget, options.max_iterations);
            try std.testing.expectEqual(if (continuation) plan.cold_iterations else @as(u16, 0), offset);
            const iterations = if (continuation) plan.retry_iterations else plan.cold_iterations;
            if (iterations == 0) return error.UnexpectedEquilibriumRetry;
            counts.* = if (continuation) plan.retry_counts else plan.cold_counts;
            for (0..iterations) |index| {
                workspace.last_iteration = @intCast(index);
                if (trace) |record| {
                    const kind: CandidateKind = if (index + 1 == iterations)
                        (if (continuation) .converged else .stagnated)
                    else if (index < counts.newton_steps) .full_network_newton else .anderson_depth_one;
                    _ = try record.append(.{
                        .closure_index = closure,
                        .iteration = offset + @as(u16, @intCast(index)),
                        .limiting_component_index = 0,
                        .limiting_state_value = 1,
                        .limiting_residual = 0,
                        .current_maximum_scaled_residual = 0.25,
                        .selected_candidate = kind,
                    });
                }
            }
            if (!continuation) return plan.cold_error;
            if (plan.retry_error) |err| return err;
            return .{ .iterations = iterations, .newton_raphson_steps = counts.newton_steps, .picard_steps = counts.anderson_steps, .anderson_steps = counts.anderson_steps, .maximum_scaled_residual = 0.25, .converged = true };
        }
    };
}

test "reaction solver entry retry counts failed work and preserves the cold prefix" {
    var captured = try retryTestCapture(@embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64"));
    defer captured.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var trace = try SolverTrace.init(std.testing.allocator, 8);
    defer trace.deinit();
    var options = captured.options;
    options.max_iterations = 8;
    const Attempt = ScriptedRetryAttempt(.{ .budget = 8, .cold_iterations = 3 });
    const result = try solveEquilibriumWithAttempt(Attempt.run, &workspace, &captured.state, 0, captured.parameters, options, &trace, 0);
    try std.testing.expectEqual(@as(u16, 5), result.iterations);
    try std.testing.expectEqual(@as(u16, 2), result.newton_raphson_steps);
    try std.testing.expectEqual(@as(u16, 1), result.anderson_steps);
    try std.testing.expectEqual(result.anderson_steps, result.picard_steps);
    try std.testing.expectEqual(@as(usize, 4), workspace.last_iteration);
    try std.testing.expectEqual(@as(usize, 5), trace.count);
    for (trace.recorded(), 0..) |entry, index| try std.testing.expectEqual(index, entry.iteration);
    try std.testing.expectEqual(CandidateKind.stagnated, trace.recorded()[2].selected_candidate);
    try std.testing.expectEqual(CandidateKind.full_network_newton, trace.recorded()[3].selected_candidate);
}

test "reaction solver entry retry leaves successful cold paths bit identical" {
    var captured = try retryTestCapture(@embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64"));
    defer captured.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var cold_trace = try SolverTrace.init(std.testing.allocator, 62);
    defer cold_trace.deinit();
    var actual_trace = try SolverTrace.init(std.testing.allocator, 62);
    defer actual_trace.deinit();
    var initial: [chemistry.State.packedComponentCount()]f64 = undefined;
    var cold_after: @TypeOf(initial) = undefined;
    var actual_after: @TypeOf(initial) = undefined;
    try captured.state.packCell(0, &initial);
    const parameters = equilibriumClosureParameters(captured.parameters);
    var counts: EquilibriumAttemptCounts = .{};
    const cold = try solveEquilibriumWithInitialization(&workspace, &captured.state, 0, parameters, captured.options, &cold_trace, 0, false, 0, &counts);
    try captured.state.packCell(0, &cold_after);
    try captured.state.unpackCell(0, &initial);
    const actual = try solveEquilibriumWithWorkspace(&workspace, &captured.state, 0, parameters, captured.options, &actual_trace, 0);
    try captured.state.packCell(0, &actual_after);
    try std.testing.expect(std.meta.eql(cold, actual));
    try std.testing.expectEqualSlices(f64, &cold_after, &actual_after);
    try std.testing.expectEqual(cold_trace.count, actual_trace.count);
    for (cold_trace.recorded(), actual_trace.recorded()) |expected, observed|
        try std.testing.expect(std.meta.eql(expected, observed));
}

test "SOLUTE-HYDROGEN-ROW-RECURRING-NONCONVERGENCE-001: hour 2561/day108-hour3 phosphate-site crawl (parent: fails)" {
    // Captured from a real production_acceptance run at commit a55e92e
    // (ecosys-ng-solute-failure-ex1-scenario1-repeat1-scene1-year1998-day108-
    // hour3.bin), the same lime-driven pH~9.7 transient diagnosed in
    // docs/discrepancy_register.md's SOLUTE-HYDROGEN-ROW-RECURRING-
    // NONCONVERGENCE-001 entry. Two mechanisms were measured and refuted
    // there (rank deficiency, over-conservative damping); this fixture
    // pins the parent (unfixed) failure so a Phase-1 fix has a two-way
    // regression test: this test must flip from error to converged=true
    // when the fix lands, with no other test in this file regressing.
    var captured = try retryTestCapture(@embedFile("testdata/ottawa_day108_hour3_layer0_20260916.b64"));
    defer captured.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const parameters = equilibriumClosureParameters(captured.parameters);
    try std.testing.expectError(
        error.SoluteReactionSolverDidNotConverge,
        solveEquilibriumWithWorkspace(&workspace, &captured.state, 0, parameters, captured.options, null, 0),
    );
}

test "reaction solver entry retry cannot reset an exhausted or one iteration budget" {
    var captured = try retryTestCapture(@embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64"));
    defer captured.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    inline for (.{ @as(u16, 1), @as(u16, 3) }) |budget| {
        var options = captured.options;
        options.max_iterations = budget;
        const Attempt = ScriptedRetryAttempt(.{ .budget = budget, .cold_iterations = budget, .cold_counts = .{}, .retry_iterations = 0 });
        try std.testing.expectError(error.SoluteReactionSolverStagnated, solveEquilibriumWithAttempt(Attempt.run, &workspace, &captured.state, 0, captured.parameters, options, null, 0));
        try std.testing.expectEqual(@as(usize, budget - 1), workspace.last_iteration);
    }
    var options = captured.options;
    options.max_iterations = 4;
    const OneRemaining = ScriptedRetryAttempt(.{ .budget = 4, .cold_iterations = 3, .retry_iterations = 1, .retry_counts = .{}, .retry_error = error.SoluteReactionSolverDidNotConverge });
    try std.testing.expectError(error.SoluteReactionSolverDidNotConverge, solveEquilibriumWithAttempt(OneRemaining.run, &workspace, &captured.state, 0, captured.parameters, options, null, 0));
    try std.testing.expectEqual(@as(usize, 3), workspace.last_iteration);
}

test "reaction solver entry retry propagates cold and retry errors without another attempt" {
    var captured = try retryTestCapture(@embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64"));
    defer captured.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var options = captured.options;
    options.max_iterations = 8;
    const ColdError = ScriptedRetryAttempt(.{ .budget = 8, .cold_iterations = 3, .cold_error = error.SoluteTraceCapacityExceeded, .retry_iterations = 0 });
    try std.testing.expectError(error.SoluteTraceCapacityExceeded, solveEquilibriumWithAttempt(ColdError.run, &workspace, &captured.state, 0, captured.parameters, options, null, 0));
    try std.testing.expectEqual(@as(usize, 2), workspace.last_iteration);
    const RetryError = ScriptedRetryAttempt(.{ .budget = 8, .cold_iterations = 3, .retry_error = error.SoluteTraceCapacityExceeded });
    try std.testing.expectError(error.SoluteTraceCapacityExceeded, solveEquilibriumWithAttempt(RetryError.run, &workspace, &captured.state, 0, captured.parameters, options, null, 0));
    try std.testing.expectEqual(@as(usize, 4), workspace.last_iteration);
}

test "reaction solver entry retry retains conservative inspection state after real exhausted attempts" {
    var captured = try retryTestCapture(@embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64"));
    defer captured.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var retained = try chemistry.State.init(std.testing.allocator, 1);
    defer retained.deinit();
    var initial: [chemistry.State.packedComponentCount()]f64 = undefined;
    var after: @TypeOf(initial) = undefined;
    var first_best: @TypeOf(initial) = undefined;
    try captured.state.packCell(0, &initial);
    const parameters = equilibriumClosureParameters(captured.parameters);
    var options = captured.options;
    options.max_iterations = 1;
    var counts: EquilibriumAttemptCounts = .{};
    // Two actual one-iteration attempts use a total allowance of two. This
    // tests continuation's retention/rollback, not the scripted coordinator.
    try std.testing.expectError(error.SoluteReactionSolverDidNotConverge, solveEquilibriumWithInitialization(&workspace, &captured.state, 0, parameters, options, null, 0, false, 0, &counts));
    try std.testing.expect(counts.newton_steps + counts.anderson_steps <= 1);
    const first_quality = workspace.best_bounded_maximum;
    try std.testing.expect(std.math.isFinite(first_quality));
    @memcpy(&first_best, workspace.best_bounded_state);
    try std.testing.expectError(error.SoluteReactionSolverDidNotConverge, solveEquilibriumWithInitialization(&workspace, &captured.state, 0, parameters, options, null, 0, true, 1, &counts));
    try std.testing.expect(counts.newton_steps + counts.anderson_steps <= 1);
    try std.testing.expect(workspace.best_bounded_maximum <= first_quality);
    if (workspace.best_bounded_maximum == first_quality)
        try std.testing.expectEqualSlices(f64, &first_best, workspace.best_bounded_state);
    try std.testing.expectEqualSlices(f64, workspace.best_bounded_state, workspace.current);
    try captured.state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &initial, &after);
    try retained.unpackCell(0, workspace.best_bounded_state);
    try requireAcceptedStateConservation(&workspace.scratch, &retained, 0, &initial, parameters);
    try reaction_charge.requireConservedStates(&captured.state, 0, &retained, 0, parameters);
}

test "reaction solver entry retry propagates trace errors and rolls back both closures" {
    var captured = try retryTestCapture(@embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64"));
    defer captured.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var initial: [chemistry.State.packedComponentCount()]f64 = undefined;
    var after: @TypeOf(initial) = undefined;
    try captured.state.packCell(0, &initial);
    var complete = try SolverTrace.init(std.testing.allocator, 62);
    defer complete.deinit();
    _ = try solveCellWithWorkspaceAndTrace(&workspace, &captured.state, 0, captured.parameters, captured.options, &complete);
    var second_start: usize = 0;
    while (second_start < complete.count and complete.recorded()[second_start].closure_index == 0) : (second_start += 1) {}
    try std.testing.expect(second_start > 1 and second_start + 1 < complete.count);
    // Cut before the first closure commits and after a real post-kinetic
    // iteration. Capacity, not a pinned search trajectory, injects the error.
    for ([_]usize{ 1, second_start - 1, second_start + 1 }) |capacity| {
        try captured.state.unpackCell(0, &initial);
        var trace = try SolverTrace.init(std.testing.allocator, capacity);
        defer trace.deinit();
        try std.testing.expectError(error.SoluteTraceCapacityExceeded, solveCellWithWorkspaceAndTrace(&workspace, &captured.state, 0, captured.parameters, captured.options, &trace));
        try captured.state.packCell(0, &after);
        try std.testing.expectEqualSlices(f64, &initial, &after);
        try std.testing.expectEqual(capacity, trace.count);
        for (trace.recorded(), complete.recorded()[0..capacity]) |observed, expected| try std.testing.expect(std.meta.eql(expected, observed));
        if (capacity > second_start) {
            try std.testing.expectEqual(@as(u8, 1), trace.recorded()[second_start].closure_index);
            try std.testing.expectEqual(@as(u16, 0), trace.recorded()[second_start].iteration);
            try std.testing.expectEqual(@as(usize, 1), workspace.last_iteration);
        }
    }
}

test "reaction solver entry retry shares its original ceiling with post kinetic equilibrium" {
    var captured = try retryTestCapture(@embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64"));
    defer captured.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var trace = try SolverTrace.init(std.testing.allocator, 62);
    defer trace.deinit();
    try std.testing.expect(hasKineticGeochemistry(captured.parameters));
    const actual = try solveCellWithWorkspaceAndTrace(&workspace, &captured.state, 0, captured.parameters, captured.options, &trace);
    try std.testing.expect(actual.converged);
    try std.testing.expect(actual.maximum_scaled_residual <= 1);
    try std.testing.expect(actual.iterations <= captured.options.max_iterations);
    try std.testing.expectEqual(actual.anderson_steps, actual.picard_steps);
    var closure_counts = [_]u16{ 0, 0 };
    var newton: u16 = 0;
    var anderson: u16 = 0;
    var terminal: u16 = 0;
    for (trace.recorded()) |entry| {
        try std.testing.expect(entry.closure_index < 2);
        try std.testing.expectEqual(closure_counts[entry.closure_index], entry.iteration);
        closure_counts[entry.closure_index] += 1;
        switch (entry.selected_candidate) {
            .converged => terminal += 1,
            .anderson_depth_one, .anderson_depth_two, .coordinate_anderson => anderson += 1,
            else => newton += 1,
        }
    }
    try std.testing.expect(closure_counts[0] > 0 and closure_counts[1] > 0);
    try std.testing.expectEqual(@as(u16, 2), terminal);
    try std.testing.expectEqual(closure_counts[0] + closure_counts[1], actual.iterations);
    try std.testing.expect(closure_counts[1] <= captured.options.max_iterations - closure_counts[0]);
    try std.testing.expectEqual(newton, actual.newton_raphson_steps);
    try std.testing.expectEqual(anderson, actual.anderson_steps);
}

pub fn solveEquilibriumWithWorkspace(
    workspace: *Workspace,
    state: *chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    input_options: Options,
    trace: ?*SolverTrace,
    closure_index: u8,
) !Result {
    return solveEquilibriumWithAttempt(solveEquilibriumWithInitialization, workspace, state, cell_index, parameters, input_options, trace, closure_index);
}

fn solveEquilibriumWithAttempt(
    comptime attempt: anytype,
    workspace: *Workspace,
    state: *chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    input_options: Options,
    trace: ?*SolverTrace,
    closure_index: u8,
) !Result {
    var cold_counts: EquilibriumAttemptCounts = .{};
    return attempt(workspace, state, cell_index, parameters, input_options, trace, closure_index, false, 0, &cold_counts) catch |err| {
        if (err != error.SoluteReactionSolverStagnated or workspace.last_iteration >= input_options.max_iterations) return err;
        const spent_iterations = workspace.last_iteration + 1;
        if (spent_iterations >= input_options.max_iterations) return err;
        var remaining_options = input_options;
        remaining_options.max_iterations -= spent_iterations;
        if (trace != null or diagnostic_control.isEnabled()) std.log.info(
            "SOLUTE bounded entry-state retry: spent={d} remaining={d}",
            .{ spent_iterations, remaining_options.max_iterations },
        );
        // A failed equilibrium attempt only changes workspace; native state
        // remains the entry inventory. Retry it once, never the failed iterate.
        var retry_counts: EquilibriumAttemptCounts = .{};
        var result = attempt(workspace, state, cell_index, parameters, remaining_options, trace, closure_index, true, spent_iterations, &retry_counts) catch |retry_error| {
            workspace.last_iteration += spent_iterations;
            return retry_error;
        };
        result.iterations += spent_iterations;
        result.newton_raphson_steps += cold_counts.newton_steps;
        result.picard_steps += cold_counts.anderson_steps;
        result.anderson_steps += cold_counts.anderson_steps;
        workspace.last_iteration += spent_iterations;
        return result;
    };
}

fn solveEquilibriumWithInitialization(
    workspace: *Workspace,
    state: *chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    input_options: Options,
    trace: ?*SolverTrace,
    closure_index: u8,
    comptime continuation_enabled: bool,
    iteration_offset: u16,
    attempt_counts: *EquilibriumAttemptCounts,
) !Result {
    var profile_scope = diagnostic_control.beginPhase(.solve_root);
    defer profile_scope.end();
    var options = input_options;
    var surface_mineral_seed: ?@import("reaction_surface_minerals.zig").CandidateSeed = null;
    var surface_mineral_seed_consumed = false;
    workspace.last_search_metric = null;
    workspace.last_selected_candidate = .none;
    // Both attempts share the same entry inventories and inspection record.
    // This retained iterate never initializes the retry or authorizes success.
    if (!continuation_enabled) {
        workspace.best_bounded_maximum = std.math.inf(f64);
        workspace.best_bounded_iteration = null;
        workspace.best_bounded_kind = .none;
    }
    workspace.last_iteration = 0;
    var diagnostic_options = input_options;
    diagnostic_options.search_reference_concentrations = null;
    try validateOptions(options);
    if (cell_index >= state.cell_count) return error.ChemistryCellIndexOutOfBounds;
    const current = workspace.current;
    const residual = workspace.residual;
    const probe_state = workspace.probe_state;
    const probe_residual = workspace.probe_residual;
    const candidate_state = workspace.candidate_state;
    const candidate_residual = workspace.candidate_residual;
    const previous_state = workspace.previous_state;
    const previous_residual = workspace.previous_residual;
    const previous_previous_state = workspace.previous_previous_state;
    const previous_previous_residual = workspace.previous_previous_residual;
    const scratch = &workspace.scratch;
    try state.packCell(cell_index, current);
    const inventory = try acceptedStateInventory(state, cell_index, parameters);
    // Geochemical stocks cannot participate in this equilibrium closure:
    // their kinetic extents are applied once between the two closures. They
    // remain in the full conservation inventory, but must not dilute aqueous
    // search residuals. Phosphate minerals and exchange remain participating.
    const search_inventory = try equilibriumSearchInventory(state, cell_index, parameters, inventory);
    const density = parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
    const water_ion_reference =
        state.aqueous[cell_index].hydrogen + state.aqueous[cell_index].hydroxide +
        3 * (search_inventory.aluminum_mol_per_m3 + search_inventory.iron_mol_per_m3 + search_inventory.phosphorus_mol_per_m3) +
        2 * (search_inventory.calcium_mol_per_m3 + search_inventory.magnesium_mol_per_m3 + search_inventory.carbon_mol_per_m3 + search_inventory.sulfur_mol_per_m3) +
        search_inventory.nitrogen_mol_per_m3 + search_inventory.sodium_mol_per_m3 + search_inventory.potassium_mol_per_m3 +
        density * (search_inventory.cation_exchange_charge_mol_per_megagram + parameters.total_carboxyl_sites_mol_per_megagram) +
        parameters.fractions.phosphate_non_band * parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 * search_inventory.non_band_phosphate_sites_mol_per_megagram +
        parameters.fractions.phosphate_band * parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 * search_inventory.band_phosphate_sites_mol_per_megagram;
    var search_references: [chemistry.State.packedComponentCount()]f64 = undefined;
    try initializeSearchReferences(state, cell_index, parameters, search_inventory, water_ion_reference, &search_references);
    options.search_reference_concentrations = &search_references;
    try validateOptions(options);
    errdefer restoreBestBoundedIterate(workspace, options);

    var newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    defer {
        attempt_counts.newton_steps = newton_steps;
        attempt_counts.anderson_steps = picard_steps;
    }
    var history_count: u2 = 0;
    var previous_norm = std.math.inf(f64);
    var best_source_norm = std.math.inf(f64);
    var insufficient_progress_iterations: u16 = 0;
    var physical_progress: reaction_progress.Monitor = .{};
    var mineral_primary_failed = false;
    var mineral_recovery_attempted = false;
    var newton_retry_required = false;
    var ternary_face_recovery_attempted = false;
    var ternary_face_retry_attempted = false;
    // TEMP_DIAGNOSTIC: bounded, failure-only trajectory capture for the
    // Ottawa hour-605 SOLUTE frontier. These values never participate in
    // candidate selection, acceptance, or publication.
    var failure_norm_trace: [64]f64 = undefined;
    var failure_kind_trace: [64]CandidateKind = undefined;
    var failure_norm_trace_len: usize = 0;
    var failure_kind_trace_len: usize = 0;
    var iteration: u16 = 0;
    equilibrium_iterations: while (iteration < options.max_iterations) : (iteration += 1) {
        workspace.last_iteration = iteration;
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        // The carrier and its activity coefficient stay together: pricing the
        // balance from a coefficient rederived after the water projection
        // overwrote the pair is SOLUTE-DUAL-ACTIVITY-COEFFICIENT-MERIT-FLOOR-001.
        const loaded_carrier = try evaluateAtLoaded(scratch, current, parameters);
        const transformations = loaded_carrier.transformations;
        _ = try @import("reaction_solver_evaluate.zig").evaluateLoadedReactionBalance(scratch, loaded_carrier, parameters, residual);
        const current_norm = try scaledNorm(current, residual, options);
        const current_merit = try scaledRmsNorm(current, residual, options);
        if (failure_norm_trace_len < failure_norm_trace.len) {
            failure_norm_trace[failure_norm_trace_len] = current_norm;
            failure_norm_trace_len += 1;
        }
        const limiting_index =
            largestScaledResidualIndex(current, residual, options);
        workspace.last_search_metric = .{ .component = limiting_index, .maximum = current_norm, .rms = current_merit };
        const physical_quality = try @import("reaction_physical_quality.zig").measure(scratch, parameters, residual, .{});
        const physical_norm = physical_quality.maximum;
        _ = try retainBestBoundedIterate(workspace, state, cell_index, parameters, physical_norm, iteration_offset + iteration);
        var trace_entry: ?*IterationDiagnostic = null;
        if (trace) |solver_trace| {
            trace_entry = try solver_trace.append(.{
                .closure_index = closure_index,
                .iteration = iteration_offset + iteration,
                .limiting_component_index = limiting_index,
                .limiting_state_value = current[limiting_index],
                .limiting_residual = residual[limiting_index],
                .current_maximum_scaled_residual = current_norm,
            });
        }
        // Search scaling and a pending Newton retry guide unfinished work;
        // neither may veto a physically acceptable Anderson endpoint.
        if (physical_norm <= 1) {
            const accepted_norm = try @import("reaction_solver_evaluate.zig").requirePhysicalReactionBalance(scratch, current, parameters, options, residual);
            selectTraceCandidate(
                trace_entry,
                .converged,
                accepted_norm,
            );
            const accepted_water_extent = try commitAcceptedWaterEquilibriumProjection(
                scratch,
                state,
                cell_index,
                current,
                parameters,
            );
            return .{ .iterations = iteration + 1, .newton_raphson_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = picard_steps, .maximum_scaled_residual = accepted_norm, .converged = true, .accepted_water_equilibrium_extent_mol_per_m3 = accepted_water_extent };
        }
        const balance_quality = try reaction_progress.balanceQuality(residual, &search_references);
        best_source_norm = @min(best_source_norm, balance_quality.maximum);
        if (balance_quality.maximum > options.divergence_growth_factor * best_source_norm)
            return error.SoluteReactionSolverDiverged;
        const physical_decision = physical_progress.observe(
            balance_quality.maximum,
            balance_quality.rms,
            __parent.candidateCountsAsPicard(workspace.last_selected_candidate),
        );
        const repeated_state = (history_count >= 1 and reaction_progress.repeatsState(current, previous_state)) or
            (history_count >= 2 and reaction_progress.repeatsState(current, previous_previous_state));
        const terminal_stagnation = physical_decision == .stop or repeated_state;
        if (terminal_stagnation or (mineral_primary_failed and !mineral_recovery_attempted)) {
            // After the primary mineral solve fails, give its alternate merit
            // one bounded attempt from the entry inventory. Waiting for outer
            // stagnation can waste the entire budget on tiny search improvements
            // while the physical endpoint worsens. Successful primary mineral
            // solves never trigger this recovery.
            // No partially improved recovery state is published.
            if (!mineral_recovery_attempted and iteration + 1 < options.max_iterations) recovery: {
                mineral_recovery_attempted = true;
                try state.packCell(cell_index, probe_state);
                const recovery_result = if (continuation_enabled) @import("reaction_surface_minerals.zig").euclideanRecoveryCandidateWithSeed(
                    scratch,
                    probe_state,
                    parameters,
                    @min(@as(u16, 40), options.max_iterations - iteration - 1),
                    candidate_state,
                    &surface_mineral_seed,
                ) else @import("reaction_surface_minerals.zig").euclideanRecoveryCandidate(
                    scratch,
                    probe_state,
                    parameters,
                    @min(@as(u16, 40), options.max_iterations - iteration - 1),
                    candidate_state,
                );
                _ = recovery_result catch break :recovery;
                const recovered_changes = try evaluateAtLoaded(scratch, candidate_state, parameters);
                _ = try @import("reaction_solver_evaluate.zig").evaluateLoadedReactionBalance(scratch, recovered_changes, parameters, candidate_residual);
                const recovered_quality = try @import("reaction_physical_quality.zig").measure(scratch, parameters, candidate_residual, .{});
                if (recovered_quality.maximum > 1) break :recovery;
                try requireConservedInventories(inventory, try acceptedStateInventory(scratch, 0, parameters));
                try reaction_charge.requireConservedStates(state, cell_index, scratch, 0, parameters);
                const accepted_norm = try @import("reaction_solver_evaluate.zig").requirePhysicalReactionBalance(scratch, candidate_state, parameters, options, candidate_residual);
                @memcpy(current, candidate_state);
                @memcpy(residual, candidate_residual);
                workspace.last_selected_candidate = .surface_mineral_newton;
                diagnostic_control.recordSelectedCandidate(.surface_mineral_newton);
                selectTraceCandidate(trace_entry, .surface_mineral_newton, accepted_norm);
                const water_extent = try commitAcceptedWaterEquilibriumProjection(scratch, state, cell_index, current, parameters);
                return .{ .iterations = iteration + 2, .newton_raphson_steps = newton_steps + 1, .picard_steps = picard_steps, .anderson_steps = picard_steps, .maximum_scaled_residual = accepted_norm, .converged = true, .accepted_water_equilibrium_extent_mol_per_m3 = water_extent };
            }
            if (terminal_stagnation) {
                selectTraceCandidate(trace_entry, .stagnated, physical_norm);
                if (diagnostic_control.isEnabled()) std.log.warn(
                    "SOLUTE inventory-balance progress stopped: cell={d} iteration={d} maximum={e} rms={e} best={e} stale={d} repeated_state={}",
                    .{ cell_index, iteration, balance_quality.maximum, balance_quality.rms, best_source_norm, physical_progress.stale_iterations, repeated_state },
                );
                return error.SoluteReactionSolverStagnated;
            }
            // A rejected alternate must not change the current candidate's
            // scratch state before ordinary Newton/Anderson work resumes.
            _ = try evaluateAt(scratch, current, parameters);
        }
        const prior_norm = previous_norm;
        const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, prior_norm);
        if (std.math.isFinite(prior_norm) and prior_norm - current_norm <= progress_floor)
            insufficient_progress_iterations +|= 1
        else
            insufficient_progress_iterations = 0;
        previous_norm = current_norm;
        const progress_requires_anderson = insufficient_progress_iterations >= 4 or physical_decision == .anderson;
        var best_norm = current_norm;
        var best_merit = current_merit;
        var best_kind: CandidateKind = .none;
        var best_is_picard = false;
        const best_state = workspace.iteration_best_state;
        const best_residual = workspace.iteration_best_residual;
        var boundary_kind: ActiveBoundaryRecoveryKind = .none;
        newton_primary: {
            if (progress_requires_anderson and !retrying_newton_after_anderson)
                break :newton_primary;

            surface_mineral_candidate: {
                // Only the failure retry may continue a private mineral seed.
                // Within that retry, ordinary continuation is available once.
                if (continuation_enabled) @import("reaction_surface_minerals.zig").prepareOrdinarySeed(&surface_mineral_seed, &surface_mineral_seed_consumed);
                const primary_result = if (continuation_enabled)
                    @import("reaction_surface_minerals.zig").candidateWithSeed(scratch, current, parameters, @min(options.max_iterations, 40), candidate_state, &surface_mineral_seed)
                else
                    @import("reaction_surface_minerals.zig").candidate(scratch, current, parameters, @min(options.max_iterations, 40), candidate_state);
                _ = primary_result catch {
                    mineral_primary_failed = true;
                    break :surface_mineral_candidate;
                };
                // A complete physical endpoint does not need numerical merit
                // competition or further candidate generators. The candidate
                // already passes native inventory/charge reconstruction; the
                // next loop (or final-budget audit) applies the unchanged full
                // entry-inventory and physical publication guards.
                const target_changes = try evaluateAtLoaded(scratch, candidate_state, parameters);
                _ = try @import("reaction_solver_evaluate.zig").evaluateLoadedReactionBalance(scratch, target_changes, parameters, candidate_residual);
                const target_quality = try @import("reaction_physical_quality.zig").measure(scratch, parameters, candidate_residual, .{});
                if (target_quality.maximum <= 1) {
                    @memcpy(current, candidate_state);
                    workspace.last_selected_candidate = .surface_mineral_newton;
                    newton_steps += 1;
                    diagnostic_control.recordSelectedCandidate(.surface_mineral_newton);
                    selectTraceCandidate(trace_entry, .surface_mineral_newton, try scaledNorm(candidate_state, candidate_residual, options));
                    continue :equilibrium_iterations;
                }
                if (try @import("reaction_solver_candidates.zig").tryAcceptNewtonTargetLineSearch(scratch, current, residual, candidate_state, probe_state, probe_residual, parameters, options, 1, current_norm)) {
                    const local_norm = try scaledNorm(probe_state, probe_residual, options);
                    _ = try retainMeaningfulNewtonCandidate(current_norm, current_merit, options, best_state, best_residual, &best_norm, &best_merit, &best_kind, &best_is_picard, probe_state, probe_residual, local_norm, .surface_mineral_newton);
                }
            }
            surface_charge_candidate: {
                // Local inventory closure is a candidate, never full-network
                // acceptance. Its short constitutive inversion is capped by
                // the caller's ceiling, and its target competes only after
                // the ordinary conservative full-network line search.
                _ = @import("reaction_surface_charge.zig").candidate(scratch, current, parameters, @min(options.max_iterations, 20), candidate_state) catch break :surface_charge_candidate;
                if (try @import("reaction_solver_candidates.zig").tryAcceptNewtonTargetLineSearch(scratch, current, residual, candidate_state, probe_state, probe_residual, parameters, options, 1, current_norm)) {
                    const local_norm = try scaledNorm(probe_state, probe_residual, options);
                    _ = try retainMeaningfulNewtonCandidate(current_norm, current_merit, options, best_state, best_residual, &best_norm, &best_merit, &best_kind, &best_is_picard, probe_state, probe_residual, local_norm, .surface_charge_newton);
                }
            }

            // Every generator below is transactional: it may mutate scratch and
            // candidate buffers, but `current` is published exactly once after
            // all existing candidates have been exactly priced.
            for (candidate_state, current, residual) |*target, value, change|
                target.* = value + change;
            // Coordinate Newton is the overwhelmingly common warm-start path
            // in hourly SOLUTE. Price it first and stop only when its exact
            // global residual is already acceptable. If it is merely better,
            // retain it while every full-network/complementarity family below
            // still competes exactly as before.
            if (try tryAnalyticCoordinateNewtonCandidate(
                workspace,
                scratch,
                current,
                residual,
                transformations,
                candidate_state,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
            )) {
                const coordinate_newton_norm = try scaledNorm(
                    probe_state,
                    probe_residual,
                    options,
                );
                _ = try retainMeaningfulNewtonCandidate(
                    current_norm,
                    current_merit,
                    options,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    coordinate_newton_norm,
                    .coordinate_newton,
                );
                if (best_kind != .none and best_norm <= 1)
                    break :newton_primary;
            }
            // A cheap conserved predictor may condition the coupled closure
            // better than the raw post-kinetic state. It is not published:
            // only a refined complete physical endpoint can bypass the matrix.
            if (best_kind != .none) {
                refined_target: {
                    if (continuation_enabled) @import("reaction_surface_minerals.zig").prepareOrdinarySeed(&surface_mineral_seed, &surface_mineral_seed_consumed);
                    const refined_result = if (continuation_enabled)
                        @import("reaction_surface_minerals.zig").candidateWithSeed(scratch, best_state, parameters, @min(options.max_iterations, 40), candidate_state, &surface_mineral_seed)
                    else
                        @import("reaction_surface_minerals.zig").candidate(scratch, best_state, parameters, @min(options.max_iterations, 40), candidate_state);
                    _ = refined_result catch break :refined_target;
                    const refined_changes = try evaluateAtLoaded(scratch, candidate_state, parameters);
                    _ = try @import("reaction_solver_evaluate.zig").evaluateLoadedReactionBalance(scratch, refined_changes, parameters, candidate_residual);
                    const refined_quality = try @import("reaction_physical_quality.zig").measure(scratch, parameters, candidate_residual, .{});
                    if (refined_quality.maximum <= 1) {
                        @memcpy(current, candidate_state);
                        workspace.last_selected_candidate = .surface_mineral_newton;
                        newton_steps += 1;
                        diagnostic_control.recordSelectedCandidate(.surface_mineral_newton);
                        selectTraceCandidate(trace_entry, .surface_mineral_newton, try scaledNorm(candidate_state, candidate_residual, options));
                        continue :equilibrium_iterations;
                    }
                }
                _ = try evaluateAt(scratch, current, parameters);
            }
            // The all-coordinate projected bounded solve is always primary.
            // A KKT-certified rank-truncated representative is priced later,
            // only if the complete ordinary Newton set cannot contract fast
            // enough to respect the user's hard iteration ceiling.
            workspace.reaction_span_allow_truncated_qr = false;
            const full_network_accepted = try tryFullNetworkReactionCandidate(
                workspace,
                scratch,
                current,
                residual,
                transformations,
                candidate_state,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
                trace_entry,
                trace,
            );
            var full_network_norm = if (full_network_accepted)
                try scaledNorm(probe_state, probe_residual, options)
            else
                std.math.inf(f64);
            const primary_rank_was_truncated =
                workspace.reaction_span_last_rank <
                workspace.reaction_span_active_count;
            if (full_network_accepted) {
                _ = try retainMeaningfulNewtonCandidate(
                    current_norm,
                    current_merit,
                    options,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    full_network_norm,
                    .full_network_newton,
                );
            }
            var rank_tier_trusted = false;
            if (primary_rank_was_truncated) {
                workspace.reaction_span_allow_truncated_qr = true;
                const trust_probe_accepted =
                    try tryFullNetworkReactionCandidate(
                        workspace,
                        scratch,
                        current,
                        residual,
                        transformations,
                        candidate_state,
                        probe_state,
                        probe_residual,
                        parameters,
                        options,
                        current_norm,
                        trace_entry,
                        trace,
                    );
                const trust_probe_norm = if (trust_probe_accepted)
                    try scaledNorm(probe_state, probe_residual, options)
                else
                    std.math.inf(f64);
                // The always-primary untruncated attempt above can produce no
                // candidate at all when the reaction-span Jacobian is
                // persistently rank-deficient: disallowing truncated QR
                // forces an immediate bailout to the fixed-sweep projected
                // solve, which is not guaranteed to certify a KKT point for a
                // severely rank-deficient system within its sweep budget.
                // When that happens, this already-computed truncated-QR
                // probe is the only full-network direction available this
                // iteration; price it too rather than silently discarding it,
                // so the multi-strategy selection below is not left choosing
                // only among weak single-coordinate fallbacks every iteration
                // a persistently near-singular state keeps failing the
                // primary attempt. `retainMeaningfulNewtonCandidate` applies
                // its own merit/descent acceptability checks, so this can
                // only ever add a candidate, never force one.
                if (!full_network_accepted and trust_probe_accepted) {
                    _ = try retainMeaningfulNewtonCandidate(
                        current_norm,
                        current_merit,
                        options,
                        best_state,
                        best_residual,
                        &best_norm,
                        &best_merit,
                        &best_kind,
                        &best_is_picard,
                        probe_state,
                        probe_residual,
                        trust_probe_norm,
                        .full_network_newton,
                    );
                }
                rank_tier_trusted = history_count == 0 or
                    (trust_probe_accepted and
                        (!workspace.reaction_span_used_truncated_qr or
                            (workspace.reaction_span_last_predicted_norm <
                                current_norm and
                                trust_probe_norm <=
                                    workspace.reaction_span_last_predicted_norm)));
                if (!rank_tier_trusted) {
                    workspace.reaction_span_allow_truncated_qr = false;
                    _ = try tryFullNetworkReactionCandidate(
                        workspace,
                        scratch,
                        current,
                        residual,
                        transformations,
                        candidate_state,
                        probe_state,
                        probe_residual,
                        parameters,
                        options,
                        current_norm,
                        trace_entry,
                        trace,
                    );
                }
            }
            // Rank permission is an explicit secondary Newton tier for this
            // iteration. The projected primary above never sees it; dependent
            // semismooth/boundary families below do, matching their shared
            // reaction-span ledger without leaking policy to another iterate.
            workspace.reaction_span_allow_truncated_qr =
                rank_tier_trusted;
            defer workspace.reaction_span_allow_truncated_qr = false;
            // Price the retained current-ledger semismooth face independently of
            // the primary full-network candidate.
            if (try tryRetainedComplementarityCandidate(
                workspace,
                scratch,
                current,
                residual,
                transformations,
                candidate_state,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
                true,
            )) {
                const retained_norm = try scaledNorm(
                    probe_state,
                    probe_residual,
                    options,
                );
                full_network_norm = @min(full_network_norm, retained_norm);
                _ = try retainMeaningfulNewtonCandidate(
                    current_norm,
                    current_merit,
                    options,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    retained_norm,
                    .full_network_newton,
                );
            }
            const phosphate_extent_accepted = try tryPhosphateExtentCandidate(
                workspace,
                scratch,
                current,
                residual,
                candidate_state,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
            );
            const phosphate_extent_norm = if (phosphate_extent_accepted)
                try scaledNorm(probe_state, probe_residual, options)
            else
                std.math.inf(f64);
            if (phosphate_extent_accepted) {
                _ = try retainMeaningfulNewtonCandidate(
                    current_norm,
                    current_merit,
                    options,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    phosphate_extent_norm,
                    .phosphate_extent_newton,
                );
            }
            if (trace_entry) |entry| {
                entry.full_network_candidate_maximum_scaled_residual =
                    full_network_norm;
                entry.phosphate_candidate_maximum_scaled_residual =
                    phosphate_extent_norm;
            }
            if (transformedVectorAdmissible(scratch, current, transformations, parameters, options.directional_probe_fraction, probe_state)) |_| {
                const probe_transformations = evaluateAt(scratch, probe_state, parameters) catch null;
                if (probe_transformations) |probe_changes| {
                    if (transformedVectorAdmissible(scratch, probe_state, probe_changes, parameters, 1, probe_residual)) |_| {
                        for (probe_residual, probe_state) |*change, value| change.* -= value;
                        var numerator: f64 = 0;
                        var denominator: f64 = 0;
                        var limiting_scaled_residual: f64 = 0;
                        var limiting_residual: f64 = 0;
                        var limiting_derivative: f64 = 0;
                        for (residual, probe_residual, current, 0..) |base, probed, value, packed_component| {
                            const scale = residualScale(value, packed_component, options);
                            const derivative =
                                (probed - base) /
                                options.directional_probe_fraction / scale;
                            const normalized_base = base / scale;
                            numerator += normalized_base * derivative;
                            denominator += derivative * derivative;
                            if (@abs(normalized_base) >
                                limiting_scaled_residual)
                            {
                                limiting_scaled_residual =
                                    @abs(normalized_base);
                                limiting_residual = normalized_base;
                                limiting_derivative = derivative;
                            }
                        }
                        if (std.math.isFinite(denominator) and denominator > std.math.floatEps(f64)) {
                            const least_squares_fraction = -numerator / denominator;
                            const limiting_coordinate_fraction =
                                if (std.math.isFinite(limiting_derivative) and
                                @abs(limiting_derivative) >
                                    std.math.floatEps(f64))
                                    -limiting_residual / limiting_derivative
                                else
                                    least_squares_fraction;
                            // The fixed-point direction is conservative for every
                            // scalar fraction. Target the coordinate that defines
                            // the infinity-norm convergence test; the subsequent
                            // global merit check rejects cross-coordinate harm.
                            const newton_fraction = std.math.clamp(
                                limiting_coordinate_fraction,
                                options.minimum_newton_fraction,
                                options.maximum_newton_fraction,
                            );
                            if (transformedVectorAdmissible(scratch, current, transformations, parameters, newton_fraction, candidate_state)) |_| {
                                if (try __parent.tryAcceptNewtonTargetLineSearch(
                                    scratch,
                                    current,
                                    residual,
                                    candidate_state,
                                    probe_state,
                                    candidate_residual,
                                    parameters,
                                    options,
                                    1,
                                    current_norm,
                                )) {
                                    const candidate_norm = try scaledNorm(
                                        probe_state,
                                        candidate_residual,
                                        options,
                                    );
                                    _ = try retainMeaningfulNewtonCandidate(
                                        current_norm,
                                        current_merit,
                                        options,
                                        best_state,
                                        best_residual,
                                        &best_norm,
                                        &best_merit,
                                        &best_kind,
                                        &best_is_picard,
                                        probe_state,
                                        candidate_residual,
                                        candidate_norm,
                                        .directional_newton,
                                    );
                                }
                            } else |_| {}
                        }
                    } else |_| {}
                }
            } else |_| {}

            // Price the general realized-rate complementarity search as an
            // independent candidate. Its correction sign never defines a kinetic
            // branch; reaction_try_network verifies candidate-state rates.
            if (try tryRetainedComplementarityCandidate(
                workspace,
                scratch,
                current,
                residual,
                transformations,
                candidate_state,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
                false,
            )) {
                const candidate_norm = try scaledNorm(
                    probe_state,
                    probe_residual,
                    options,
                );
                _ = try retainMeaningfulNewtonCandidate(
                    current_norm,
                    current_merit,
                    options,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    candidate_norm,
                    .full_network_newton,
                );
            }
            if (try tryGlobalInventoryBoundaryRecoveryCandidate(
                workspace,
                scratch,
                current,
                transformations,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
            )) {
                try __parent.evaluateGlobalResidualAt(
                    scratch,
                    probe_state,
                    parameters,
                    probe_residual,
                );
                const candidate_norm = try scaledNorm(
                    probe_state,
                    probe_residual,
                    options,
                );
                _ = try retainMeaningfulNewtonCandidate(
                    current_norm,
                    current_merit,
                    options,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    candidate_norm,
                    .inventory_boundary_newton,
                );
            }
            // Boundary recovery exposes its Newton and Anderson constructions
            // independently. The Newton composite participates in the complete
            // first tier even when an earlier Newton direction was admissible.
            boundary_kind = .none;
            if (try tryActiveBoundarySurfaceRecoveryCandidateFiltered(
                workspace,
                scratch,
                current,
                transformations,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
                ActiveBoundaryRecoveryFilter.newton,
                &boundary_kind,
            )) {
                std.debug.assert(boundary_kind == .newton);
                try __parent.evaluateGlobalResidualAt(
                    scratch,
                    probe_state,
                    parameters,
                    probe_residual,
                );
                const candidate_norm = try scaledNorm(
                    probe_state,
                    probe_residual,
                    options,
                );
                _ = try retainMeaningfulNewtonCandidate(
                    current_norm,
                    current_merit,
                    options,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    candidate_norm,
                    .full_network_newton,
                );
            }
            if (rank_tier_trusted) {
                const established_best_kind = best_kind;
                const established_best_norm = best_norm;
                const recovery_accepted = try tryFullNetworkReactionCandidate(
                    workspace,
                    scratch,
                    current,
                    residual,
                    transformations,
                    candidate_state,
                    probe_state,
                    probe_residual,
                    parameters,
                    options,
                    current_norm,
                    trace_entry,
                    trace,
                );
                const recovery_used_truncated =
                    workspace.reaction_span_used_truncated_qr;
                const recovery_predicted_norm =
                    workspace.reaction_span_last_predicted_norm;
                const recovery_norm = if (recovery_accepted)
                    try scaledNorm(probe_state, probe_residual, options)
                else
                    std.math.inf(f64);
                // A truncated representative is secondary Newton recovery,
                // never an unchecked least-squares shortcut. Exact Armijo and
                // strict maximum descent were already enforced; the linear
                // model must also predict descent before this late candidate
                // can displace the established Newton set.
                if (recovery_accepted and
                    (!recovery_used_truncated or
                        recovery_predicted_norm < current_norm) and
                    rankRecoveryCandidateEligible(
                        established_best_kind,
                        current_norm,
                        established_best_norm,
                        recovery_norm,
                        options.max_iterations - iteration,
                    ))
                {
                    _ = try retainMeaningfulNewtonCandidate(
                        current_norm,
                        current_merit,
                        options,
                        best_state,
                        best_residual,
                        &best_norm,
                        &best_merit,
                        &best_kind,
                        &best_is_picard,
                        probe_state,
                        probe_residual,
                        recovery_norm,
                        .full_network_newton,
                    );
                }
            }
            // The exhaustive active-row solve is terminal Newton recovery. A
            // 39-reaction cell can require about 95,000 exact residual probes,
            // so price it only when cheaper Newton families all fail, or on
            // the mandatory Newton retry after Anderson when their best
            // contraction still cannot meet the remaining hard ceiling.
            const active_row_recovery_required = best_kind == .none or
                (retrying_newton_after_anderson and andersonTierEnabled(
                    best_kind,
                    current_norm,
                    best_norm,
                    options.max_iterations - iteration,
                ));
            if (active_row_recovery_required and try tryActiveRowNewtonCandidate(
                workspace,
                scratch,
                current,
                residual,
                transformations,
                candidate_state,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
            )) {
                const active_row_norm = try scaledNorm(
                    probe_state,
                    probe_residual,
                    options,
                );
                _ = try retainMeaningfulNewtonCandidate(
                    current_norm,
                    current_merit,
                    options,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    active_row_norm,
                    .coordinate_newton,
                );
            }
            if (best_kind == .none) {
                const ternary_already_attempted = if (retrying_newton_after_anderson)
                    ternary_face_retry_attempted
                else
                    ternary_face_recovery_attempted;
                if (!ternary_already_attempted) {
                    if (retrying_newton_after_anderson)
                        ternary_face_retry_attempted = true
                    else
                        ternary_face_recovery_attempted = true;
                    if (try tryTernaryCorrectionFaceNewtonCandidate(
                        workspace,
                        scratch,
                        current,
                        residual,
                        transformations,
                        candidate_state,
                        probe_state,
                        probe_residual,
                        parameters,
                        options,
                        current_norm,
                        trace_entry,
                    )) {
                        const ternary_norm = try scaledNorm(
                            probe_state,
                            probe_residual,
                            options,
                        );
                        _ = try retainMeaningfulNewtonCandidate(
                            current_norm,
                            current_merit,
                            options,
                            best_state,
                            best_residual,
                            &best_norm,
                            &best_merit,
                            &best_kind,
                            &best_is_picard,
                            probe_state,
                            probe_residual,
                            ternary_norm,
                            .full_network_newton,
                        );
                    }
                }
            }
        }
        // Newton has had its opportunity even after an Anderson step. If its
        // progress is inadequate, price Anderson within this same iteration,
        // including the last permitted one. The final physical gate owns
        // publication; scheduling never reserves a mandatory future retry.
        if (progress_requires_anderson or andersonTierEnabled(
            best_kind,
            current_norm,
            best_norm,
            options.max_iterations - iteration,
        )) {
            if (trace_entry) |entry| entry.anderson_attempted = true;
            // Every Anderson family competes on exact global merit against
            // the accepted current iterate and other publishable Anderson
            // candidates. Relaxed Picard images remain private history.
            if (history_count >= 2) {
                var gram_00: f64 = 0;
                var gram_01: f64 = 0;
                var gram_11: f64 = 0;
                var rhs_0: f64 = 0;
                var rhs_1: f64 = 0;
                for (
                    residual,
                    previous_residual,
                    previous_previous_residual,
                    current,
                    0..,
                ) |now, before, older, value, packed_component| {
                    const scale = residualScale(value, packed_component, options);
                    const difference_0 = (now - before) / scale;
                    const difference_1 = (before - older) / scale;
                    const normalized_now = now / scale;
                    gram_00 += difference_0 * difference_0;
                    gram_01 += difference_0 * difference_1;
                    gram_11 += difference_1 * difference_1;
                    rhs_0 += difference_0 * normalized_now;
                    rhs_1 += difference_1 * normalized_now;
                }
                const determinant =
                    gram_00 * gram_11 - gram_01 * gram_01;
                if (std.math.isFinite(determinant) and
                    @abs(determinant) > std.math.floatEps(f64) *
                        @max(1.0, gram_00 * gram_11))
                {
                    const gamma_0 =
                        (rhs_0 * gram_11 - rhs_1 * gram_01) / determinant;
                    const gamma_1 =
                        (gram_00 * rhs_1 - gram_01 * rhs_0) / determinant;
                    for (
                        candidate_state,
                        current,
                        residual,
                        previous_state,
                        previous_residual,
                        previous_previous_state,
                        previous_previous_residual,
                    ) |*candidate, now, now_residual, before, before_residual, older, older_residual| {
                        const mapped_now = now + options.picard_relaxation * now_residual;
                        const mapped_before = before + options.picard_relaxation * before_residual;
                        const mapped_older = older + options.picard_relaxation * older_residual;
                        candidate.* = mapped_now -
                            gamma_0 * (mapped_now - mapped_before) -
                            gamma_1 * (mapped_before - mapped_older);
                    }
                    if (try tryAcceptAndersonCandidate(
                        scratch,
                        current,
                        candidate_state,
                        probe_state,
                        probe_residual,
                        parameters,
                        options,
                        current_norm,
                    )) {
                        const candidate_norm = try scaledNorm(
                            probe_state,
                            probe_residual,
                            options,
                        );
                        _ = retainMeaningfulAndersonCandidate(
                            current_norm,
                            best_state,
                            best_residual,
                            &best_norm,
                            &best_merit,
                            &best_kind,
                            &best_is_picard,
                            probe_state,
                            probe_residual,
                            candidate_norm,
                            .anderson_depth_two,
                        );
                    }
                }
            }
            if (history_count >= 1) {
                var numerator: f64 = 0;
                var denominator: f64 = 0;
                for (residual, previous_residual, current, 0..) |now, before, value, packed_component| {
                    const scale = residualScale(value, packed_component, options);
                    const delta = (now - before) / scale;
                    numerator += delta * (now / scale);
                    denominator += delta * delta;
                }
                if (std.math.isFinite(denominator) and
                    denominator > std.math.floatEps(f64))
                {
                    const gamma = numerator / denominator;
                    for (
                        candidate_state,
                        current,
                        residual,
                        previous_state,
                        previous_residual,
                    ) |*candidate, now, now_residual, before, before_residual| {
                        const mapped_now = now + options.picard_relaxation * now_residual;
                        const mapped_before = before + options.picard_relaxation * before_residual;
                        candidate.* =
                            mapped_now - gamma * (mapped_now - mapped_before);
                    }
                    if (try tryAcceptAndersonCandidate(
                        scratch,
                        current,
                        candidate_state,
                        probe_state,
                        probe_residual,
                        parameters,
                        options,
                        current_norm,
                    )) {
                        const candidate_norm = try scaledNorm(
                            probe_state,
                            probe_residual,
                            options,
                        );
                        _ = retainMeaningfulAndersonCandidate(
                            current_norm,
                            best_state,
                            best_residual,
                            &best_norm,
                            &best_merit,
                            &best_kind,
                            &best_is_picard,
                            probe_state,
                            probe_residual,
                            candidate_norm,
                            .anderson_depth_one,
                        );
                    }
                }
            }

            try @import("reaction_feasible_map.zig").evaluate(
                scratch,
                current,
                transformations,
                parameters,
                candidate_state,
            );
            for (candidate_state, current) |*value, initial| value.* = initial + options.picard_relaxation * (value.* - initial);
            try evaluateGlobalResidualAt(
                scratch,
                candidate_state,
                parameters,
                candidate_residual,
            );
            var accepted_anderson = scaledAndersonDepthOneCandidate(
                current,
                residual,
                candidate_state,
                candidate_residual,
                options,
                probe_state,
            );
            if (accepted_anderson) {
                accepted_anderson = try tryAcceptAndersonCandidate(
                    scratch,
                    current,
                    probe_state,
                    candidate_state,
                    probe_residual,
                    parameters,
                    options,
                    current_norm,
                );
            }
            if (accepted_anderson) {
                const candidate_norm = try scaledNorm(
                    candidate_state,
                    probe_residual,
                    options,
                );
                _ = retainMeaningfulAndersonCandidate(
                    current_norm,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    candidate_state,
                    probe_residual,
                    candidate_norm,
                    .anderson_depth_one,
                );
            }

            // The clipped native coordinate is a seed only; raw Picard can
            // never publish. It competes with every other Anderson family.
            if (try tryCurrentSignCoordinateAndersonCandidate(
                workspace,
                scratch,
                current,
                residual,
                transformations,
                candidate_state,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
            )) {
                const candidate_norm = try scaledNorm(
                    probe_state,
                    probe_residual,
                    options,
                );
                _ = retainMeaningfulAndersonCandidate(
                    current_norm,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    candidate_norm,
                    .coordinate_anderson,
                );
            }

            boundary_kind = .none;
            if (try tryActiveBoundarySurfaceRecoveryCandidateFiltered(
                workspace,
                scratch,
                current,
                transformations,
                probe_state,
                probe_residual,
                parameters,
                options,
                current_norm,
                ActiveBoundaryRecoveryFilter.anderson,
                &boundary_kind,
            )) {
                std.debug.assert(boundary_kind == .anderson);
                const candidate_norm = try scaledNorm(
                    probe_state,
                    probe_residual,
                    options,
                );
                _ = retainMeaningfulAndersonCandidate(
                    current_norm,
                    best_state,
                    best_residual,
                    &best_norm,
                    &best_merit,
                    &best_kind,
                    &best_is_picard,
                    probe_state,
                    probe_residual,
                    candidate_norm,
                    .anderson_depth_one,
                );
            }
        }

        if (best_kind != .none) {
            if (best_is_picard) {
                if (!meaningfulNewtonMeritDecrease(current_norm, best_norm))
                    return error.NonDescendingSoluteReactionCandidate;
            } else if (!newtonCandidateAcceptable(
                current_norm,
                current_merit,
                best_norm,
                best_merit,
            )) {
                return error.NonDescendingSoluteReactionCandidate;
            }
            rememberHistory(
                current,
                residual,
                previous_state,
                previous_residual,
                previous_previous_state,
                previous_previous_residual,
                &history_count,
            );
            @memcpy(current, best_state);
            workspace.last_selected_candidate = best_kind;
            if (failure_kind_trace_len < failure_kind_trace.len) {
                failure_kind_trace[failure_kind_trace_len] = best_kind;
                failure_kind_trace_len += 1;
            }
            if (best_is_picard) {
                picard_steps += 1;
                newton_retry_required = true;
            } else {
                newton_steps += 1;
            }
            std.debug.assert(
                best_is_picard == __parent.candidateCountsAsPicard(best_kind),
            );
            diagnostic_control.recordSelectedCandidate(switch (best_kind) {
                .converged => .converged,
                .full_network_newton => .full_network_newton,
                .inventory_boundary_newton => .inventory_boundary_newton,
                .phosphate_extent_newton => .phosphate_extent_newton,
                .anderson_depth_two => .anderson_depth_two,
                .anderson_depth_one => .anderson_depth_one,
                .directional_newton => .directional_newton,
                .coordinate_newton => .coordinate_newton,
                .coordinate_anderson => .coordinate_anderson,
                .surface_charge_newton => .surface_charge_newton,
                .surface_mineral_newton => .surface_mineral_newton,
                .none, .stagnated, .iteration_ceiling => unreachable,
            });
            selectTraceCandidate(trace_entry, best_kind, best_norm);
            continue;
        }
        selectTraceCandidate(trace_entry, .stagnated, current_norm);
        logTerminalReactionDecomposition(
            scratch,
            current,
            parameters,
        );
        logTerminalStagnationComponent(
            current,
            residual,
            options,
            limiting_index,
        );
        std.log.warn(
            "TEMP_DIAGNOSTIC SOLUTE stagnation trajectory: cell_index={d} closure={d} iteration={d} max_iterations={d} scaled_residual={e} rms_merit={e} limiting_component={d} limiting_name={s} limiting_value={e} limiting_residual={e} limiting_scale={e} newton_steps={d} anderson_steps={d} history_count={d} retrying_newton_after_anderson={} progress_requires_anderson={} norm_trace={any} accepted_kind_trace={any}",
            .{
                cell_index,
                closure_index,
                iteration + 1,
                options.max_iterations,
                current_norm,
                current_merit,
                limiting_index,
                chemistry.State.packedComponentName(limiting_index) orelse "unknown",
                current[limiting_index],
                residual[limiting_index],
                residualScale(current[limiting_index], limiting_index, options),
                newton_steps,
                picard_steps,
                history_count,
                retrying_newton_after_anderson,
                progress_requires_anderson,
                failure_norm_trace[0..failure_norm_trace_len],
                failure_kind_trace[0..failure_kind_trace_len],
            },
        );
        return error.SoluteReactionSolverStagnated;
    }
    workspace.last_iteration = options.max_iterations;
    try evaluateGlobalResidualAt(scratch, current, parameters, residual);
    const final_norm = try scaledNorm(current, residual, options);
    workspace.last_search_metric = .{ .component = largestScaledResidualIndex(current, residual, options), .maximum = final_norm, .rms = try scaledRmsNorm(current, residual, options) };
    const final_quality = try @import("reaction_physical_quality.zig").measure(scratch, parameters, residual, .{});
    const final_physical_norm = final_quality.maximum;
    _ = try retainBestBoundedIterate(workspace, state, cell_index, parameters, final_physical_norm, iteration_offset + options.max_iterations);
    const accepted_final_norm = if (final_physical_norm <= 1)
        try @import("reaction_solver_evaluate.zig").requirePhysicalReactionBalance(scratch, current, parameters, options, residual)
    else
        final_physical_norm;
    if (trace) |solver_trace| {
        const limiting_index =
            largestScaledResidualIndex(current, residual, diagnostic_options);
        const entry = try solver_trace.append(.{
            .closure_index = closure_index,
            .iteration = iteration_offset + options.max_iterations,
            .limiting_component_index = limiting_index,
            .limiting_state_value = current[limiting_index],
            .limiting_residual = residual[limiting_index],
            .current_maximum_scaled_residual = accepted_final_norm,
        });
        selectTraceCandidate(
            entry,
            if (accepted_final_norm <= 1)
                .converged
            else
                .iteration_ceiling,
            accepted_final_norm,
        );
    }
    if (accepted_final_norm <= 1) {
        const accepted_water_extent = try commitAcceptedWaterEquilibriumProjection(
            scratch,
            state,
            cell_index,
            current,
            parameters,
        );
        return .{
            .iterations = options.max_iterations,
            .newton_raphson_steps = newton_steps,
            .picard_steps = picard_steps,
            .anderson_steps = picard_steps,
            .maximum_scaled_residual = accepted_final_norm,
            .converged = true,
            .accepted_water_equilibrium_extent_mol_per_m3 = accepted_water_extent,
        };
    }
    // The hard budget cannot authorize an endpoint outside the physical
    // chemistry budgets. Failure preserves the best valid state privately
    // and rolls back the live transaction.
    if (diagnostic_control.isEnabled()) {
        std.log.warn(
            "SOLUTE reaction network did not converge: cell={d} max_iterations={d} maximum_scaled_residual={e} search_scaled_residual={e} newton_steps={d} picard_steps={d}",
            .{
                cell_index,
                options.max_iterations,
                final_physical_norm,
                final_norm,
                newton_steps,
                picard_steps,
            },
        );
        logLargestResidual(current, residual, diagnostic_options);
        logTerminalReactionDecomposition(scratch, current, parameters);
    }
    return error.SoluteReactionSolverDidNotConverge;
}

pub fn solveComplementarityBlend(
    workspace: *Workspace,
    inputs: ComplementaritySearchInputs,
    selected_jacobian: []const f64,
    opposite_jacobian: []const f64,
    ambiguous_columns: []const usize,
    opposite_mask: u64,
    blend_column: usize,
    blend_fraction: f64,
) ?f64 {
    const matrix_count =
        inputs.current.len * inputs.column_count;
    @memcpy(
        workspace.reaction_span_jacobian[0..matrix_count],
        selected_jacobian,
    );
    for (ambiguous_columns, 0..) |column, bit| {
        if (opposite_mask &
            (@as(u64, 1) << @intCast(bit)) == 0)
        {
            continue;
        }
        for (0..inputs.current.len) |row|
            workspace.reaction_span_jacobian[
                row * inputs.column_count + column
            ] = opposite_jacobian[
                row * inputs.column_count + column
            ];
    }
    for (0..inputs.current.len) |row| {
        const index =
            row * inputs.column_count + blend_column;
        workspace.reaction_span_jacobian[index] =
            selected_jacobian[index] +
            blend_fraction *
                (opposite_jacobian[index] -
                    selected_jacobian[index]);
    }
    if (!solveBoundedReactionSpan(
        workspace,
        inputs.current.len,
        inputs.column_count,
    )) return null;
    return workspace.reaction_span_solution[blend_column];
}

/// Unit-invariant gradient test. Normalize before multiplication so small
/// columns neither vanish behind an absolute floor nor underflow in A'*r.
pub fn normalizedKktGradient(matrix: []const f64, residual: []const f64, column_count: usize, column: usize, residual_norm: f64) f64 {
    const column_norm = matrixColumnNorm(matrix, residual.len, column_count, column, 0);
    if (!std.math.isFinite(column_norm) or !std.math.isFinite(residual_norm)) return std.math.nan(f64);
    if (column_norm == 0 or residual_norm == 0) return 0;
    var gradient: f64 = 0;
    for (residual, 0..) |value, row| {
        gradient += (matrix[row * column_count + column] / column_norm) * (value / residual_norm);
    }
    return gradient;
}

pub fn solveBoundedPhosphateExtents(
    workspace: *Workspace,
    current: []const f64,
    parameters: chemistry.ReactionParameters,
    options: Options,
    limiting_index: usize,
) bool {
    const row_count = current.len;
    const column_count = coupled_extent_reaction_count;
    const matrix = workspace.phosphate_extent_jacobian;
    const right_hand_side = workspace.phosphate_extent_rhs;
    const solution = workspace.phosphate_extent_solution;
    const active_bounds = workspace.phosphate_extent_active_bounds;
    @memset(solution, 0);
    for (active_bounds, 0..) |*status, column| {
        const reaction: CoupledExtentReaction = @enumFromInt(column);
        status.* = if (coupledExtentReactionEnabled(
            reaction,
            limiting_index,
        )) 0 else 2;
    }

    var active_set_iteration: usize = 0;
    while (active_set_iteration < 8 * column_count) : (active_set_iteration += 1) {
        var free_count: usize = 0;
        for (active_bounds, 0..) |status, column| {
            if (status != 0) continue;
            workspace.phosphate_extent_free_columns[free_count] = column;
            free_count += 1;
        }
        @memcpy(workspace.phosphate_extent_projected_rhs, right_hand_side);
        for (0..row_count) |row| {
            for (active_bounds, solution, 0..) |status, extent, column| {
                if (status == 0) continue;
                workspace.phosphate_extent_projected_rhs[row] -=
                    matrix[row * column_count + column] * extent;
            }
            for (workspace.phosphate_extent_free_columns[0..free_count], 0..) |
                column,
                free_column,
            | {
                workspace.phosphate_extent_projected_jacobian[
                    row * free_count + free_column
                ] = matrix[row * column_count + column];
            }
        }
        if (free_count > 0) {
            if (!solvePivotedHouseholder(
                workspace.phosphate_extent_projected_jacobian[0 .. row_count * free_count],
                workspace.phosphate_extent_projected_rhs,
                workspace.phosphate_extent_residual[0..free_count],
                workspace.phosphate_extent_pivots[0..free_count],
                workspace.phosphate_extent_probe_residual[0..free_count],
                row_count,
                free_count,
                null,
                null,
            )) return false;
            for (workspace.phosphate_extent_free_columns[0..free_count], 0..) |
                column,
                free_column,
            | solution[column] =
                workspace.phosphate_extent_residual[free_column];
        }

        var violating_column: ?usize = null;
        var violating_status: i8 = 0;
        var largest_violation: f64 = 0;
        for (active_bounds, solution, 0..) |status, extent, column| {
            if (status != 0) continue;
            const bounds = phosphateExtentBounds(
                current,
                @enumFromInt(column),
                parameters,
                options,
            );
            const scale = @max(
                1.0,
                @max(
                    @abs(bounds.lower_mol_per_m3),
                    @abs(bounds.upper_mol_per_m3),
                ),
            );
            const lower_violation =
                (bounds.lower_mol_per_m3 - extent) / scale;
            const upper_violation =
                (extent - bounds.upper_mol_per_m3) / scale;
            if (lower_violation > largest_violation) {
                largest_violation = lower_violation;
                violating_column = column;
                violating_status = -1;
            }
            if (upper_violation > largest_violation) {
                largest_violation = upper_violation;
                violating_column = column;
                violating_status = 1;
            }
        }
        if (violating_column) |column| {
            const bounds = phosphateExtentBounds(
                current,
                @enumFromInt(column),
                parameters,
                options,
            );
            active_bounds[column] = violating_status;
            solution[column] = if (violating_status < 0)
                bounds.lower_mol_per_m3
            else
                bounds.upper_mol_per_m3;
            continue;
        }

        for (0..row_count) |row| {
            var linear_residual = -right_hand_side[row];
            for (solution, 0..) |extent, column|
                linear_residual +=
                    matrix[row * column_count + column] * extent;
            workspace.phosphate_extent_projected_rhs[row] = linear_residual;
        }
        const residual_norm =
            maximumMagnitude(workspace.phosphate_extent_projected_rhs);
        var release_column: ?usize = null;
        var largest_kkt_violation: f64 = 0;
        for (active_bounds, 0..) |status, column| {
            if (status == 0 or status == 2) continue;
            const gradient = normalizedKktGradient(matrix, workspace.phosphate_extent_projected_rhs, column_count, column, residual_norm);
            if (!std.math.isFinite(gradient)) return false;
            const violation = if (status < 0)
                -gradient
            else
                gradient;
            if (violation > @sqrt(std.math.floatEps(f64)) and
                violation > largest_kkt_violation)
            {
                largest_kkt_violation = violation;
                release_column = column;
            }
        }
        if (release_column) |column| {
            active_bounds[column] = 0;
            continue;
        }
        for (solution) |extent|
            if (!std.math.isFinite(extent)) return false;
        return true;
    }
    return false;
}

pub fn solveProjectedReactionSpanLeastSquares(
    workspace: *Workspace,
    row_count: usize,
    column_count: usize,
) bool {
    const matrix =
        workspace.reaction_span_jacobian[0 .. row_count * column_count];
    const right_hand_side =
        workspace.reaction_span_rhs[0..row_count];
    const solution =
        workspace.reaction_span_solution[0..column_count];
    const lower_bounds =
        workspace.reaction_span_lower_bounds[0..column_count];
    const upper_bounds =
        workspace.reaction_span_upper_bounds[0..column_count];
    for (lower_bounds, upper_bounds, solution) |lower, upper, *extent| {
        if (!std.math.isFinite(lower) or
            !std.math.isFinite(upper) or
            lower > upper)
        {
            return false;
        }
        extent.* = std.math.clamp(0, lower, upper);
    }
    for (right_hand_side, 0..) |value, row| {
        workspace.reaction_span_projected_rhs[row] = -value;
        for (solution, 0..) |extent, column| {
            workspace.reaction_span_projected_rhs[row] +=
                matrix[row * column_count + column] * extent;
        }
    }

    var sweep: usize = 0;
    while (sweep < 512) : (sweep += 1) {
        var maximum_scaled_change: f64 = 0;
        for (0..column_count) |column| {
            var column_norm_squared: f64 = 0;
            var gradient: f64 = 0;
            for (
                workspace.reaction_span_projected_rhs[0..row_count],
                0..,
            ) |linear_residual, row| {
                const coefficient =
                    matrix[row * column_count + column];
                column_norm_squared += coefficient * coefficient;
                gradient += coefficient * linear_residual;
            }
            if (!std.math.isFinite(column_norm_squared) or
                !std.math.isFinite(gradient))
            {
                return false;
            }
            if (column_norm_squared == 0) continue;
            const previous = solution[column];
            const next = std.math.clamp(
                previous - gradient / column_norm_squared,
                lower_bounds[column],
                upper_bounds[column],
            );
            const change = next - previous;
            if (change == 0) continue;
            solution[column] = next;
            for (0..row_count) |row| {
                workspace.reaction_span_projected_rhs[row] +=
                    matrix[row * column_count + column] * change;
            }
            maximum_scaled_change = @max(
                maximum_scaled_change,
                @abs(change) / @max(
                    1.0,
                    @max(
                        @abs(lower_bounds[column]),
                        @abs(upper_bounds[column]),
                    ),
                ),
            );
        }
        if (maximum_scaled_change <=
            64 * std.math.floatEps(f64))
        {
            return reactionSpanProjectedKktSatisfied(
                workspace,
                row_count,
                column_count,
            );
        }
    }
    return reactionSpanProjectedKktSatisfied(
        workspace,
        row_count,
        column_count,
    );
}

/// Certifies a feasible stationary point of the convex bounded least-squares
/// problem using the same normalized KKT gate as the primary active-set
/// solver. The projected-coordinate recovery may never publish merely because
/// its fixed sweep budget expired.
pub fn reactionSpanProjectedKktSatisfied(
    workspace: *Workspace,
    row_count: usize,
    column_count: usize,
) bool {
    if (column_count == 0 or
        column_count > reaction_span.reaction_count)
    {
        return false;
    }
    const matrix =
        workspace.reaction_span_jacobian[0 .. row_count * column_count];
    const right_hand_side =
        workspace.reaction_span_rhs[0..row_count];
    const solution =
        workspace.reaction_span_solution[0..column_count];
    const lower_bounds =
        workspace.reaction_span_lower_bounds[0..column_count];
    const upper_bounds =
        workspace.reaction_span_upper_bounds[0..column_count];
    for (0..row_count) |row| {
        var linear_residual = -right_hand_side[row];
        for (solution, 0..) |extent, column| {
            linear_residual +=
                matrix[row * column_count + column] * extent;
        }
        if (!std.math.isFinite(linear_residual)) return false;
        workspace.reaction_span_projected_rhs[row] = linear_residual;
    }
    const residual_norm = matrixColumnNorm(workspace.reaction_span_projected_rhs[0..row_count], row_count, 1, 0, 0);
    if (!std.math.isFinite(residual_norm)) return false;
    const kkt_tolerance = @sqrt(std.math.floatEps(f64));
    for (solution, lower_bounds, upper_bounds, 0..) |
        extent,
        lower,
        upper,
        column,
    | {
        if (!std.math.isFinite(extent) or
            !std.math.isFinite(lower) or
            !std.math.isFinite(upper) or
            lower > upper or
            extent < lower or
            extent > upper)
        {
            return false;
        }
        if (lower == upper) continue;
        const gradient = normalizedKktGradient(matrix, workspace.reaction_span_projected_rhs[0..row_count], column_count, column, residual_norm);
        const violation = if (extent == lower)
            -gradient
        else if (extent == upper)
            gradient
        else
            @abs(gradient);
        if (!std.math.isFinite(violation) or
            violation > kkt_tolerance)
        {
            return false;
        }
    }
    return true;
}

pub fn solveBoundedReactionSpan(
    workspace: *Workspace,
    row_count: usize,
    column_count: usize,
) bool {
    if (column_count == 0 or
        column_count > reaction_span.reaction_count)
    {
        return false;
    }
    const matrix =
        workspace.reaction_span_jacobian[0 .. row_count * column_count];
    const right_hand_side =
        workspace.reaction_span_rhs[0..row_count];
    const solution =
        workspace.reaction_span_solution[0..column_count];
    const active_bounds =
        workspace.reaction_span_active_bounds[0..column_count];
    const lower_bounds =
        workspace.reaction_span_lower_bounds[0..column_count];
    const upper_bounds =
        workspace.reaction_span_upper_bounds[0..column_count];
    @memset(solution, 0);
    @memset(active_bounds, 0);
    workspace.reaction_span_last_rank = 0;
    workspace.reaction_span_used_truncated_qr = false;

    var active_set_iteration: usize = 0;
    var last_released_column: ?usize = null;
    var last_released_status: i8 = 0;
    while (active_set_iteration < 8 * column_count) : (active_set_iteration += 1) {
        var free_count: usize = 0;
        for (active_bounds, 0..) |status, column| {
            if (status != 0) continue;
            workspace.reaction_span_free_columns[free_count] = column;
            free_count += 1;
        }
        @memcpy(
            workspace.reaction_span_projected_rhs[0..row_count],
            right_hand_side,
        );
        for (0..row_count) |row| {
            for (active_bounds, solution, 0..) |status, extent, column| {
                if (status == 0) continue;
                workspace.reaction_span_projected_rhs[row] -=
                    matrix[row * column_count + column] * extent;
            }
            for (workspace.reaction_span_free_columns[0..free_count], 0..) |
                column,
                free_column,
            | {
                workspace.reaction_span_projected_jacobian[
                    row * free_count + free_column
                ] = matrix[row * column_count + column];
            }
        }
        if (free_count > 0) {
            const projected_jacobian =
                workspace.reaction_span_projected_jacobian[0 .. row_count * free_count];
            for (0..free_count) |free_column| {
                const column_norm = matrixColumnNorm(
                    projected_jacobian,
                    row_count,
                    free_count,
                    free_column,
                    0,
                );
                if (!std.math.isFinite(column_norm)) return false;
                if (column_norm == 0) continue;
                for (0..row_count) |row|
                    projected_jacobian[row * free_count + free_column] /=
                        column_norm;
            }
            var pivot_norm_diagnostic_buffer: [reaction_span.reaction_count]f64 = undefined;
            const pivot_norm_diagnostic_output: ?[]f64 = if (diagnostic_control.isEnabled())
                pivot_norm_diagnostic_buffer[0..free_count]
            else
                null;
            const solved = solvePivotedHouseholder(
                projected_jacobian,
                workspace.reaction_span_projected_rhs[0..row_count],
                workspace.reaction_span_residual[0..free_count],
                workspace.reaction_span_pivots[0..free_count],
                workspace.reaction_span_probe_residual[0..free_count],
                row_count,
                free_count,
                &workspace.reaction_span_last_rank,
                pivot_norm_diagnostic_output,
            );
            if (pivot_norm_diagnostic_output) |norms| {
                // The QR breaks out of its column loop as soon as a pivot
                // drops at/below the rank cutoff, so exactly rank+1 entries
                // are written (the last being the sub-cutoff one that broke
                // the loop); anything past that is unwritten stack memory.
                const written = @min(free_count, workspace.reaction_span_last_rank + 1);
                std.log.debug(
                    "SOLUTE full-network QR pivot norms: free_count={d} rank={d} norms={any}",
                    .{ free_count, workspace.reaction_span_last_rank, norms[0..written] },
                );
            }
            if (!solved) {
                if (workspace.reaction_span_last_rank != 0 or
                    maximumMagnitude(projected_jacobian) != 0)
                {
                    return false;
                }
                for (workspace.reaction_span_free_columns[0..free_count]) |column|
                    solution[column] = 0;
            } else {
                for (workspace.reaction_span_free_columns[0..free_count], 0..) |
                    column,
                    free_column,
                | {
                    const column_norm = matrixColumnNorm(
                        matrix,
                        row_count,
                        column_count,
                        column,
                        0,
                    );
                    if (!std.math.isFinite(column_norm)) return false;
                    solution[column] = if (column_norm == 0)
                        0
                    else
                        workspace.reaction_span_residual[free_column] /
                            column_norm;
                }
                if (workspace.reaction_span_last_rank < free_count and
                    !workspace.reaction_span_allow_truncated_qr)
                {
                    return solveProjectedReactionSpanLeastSquares(
                        workspace,
                        row_count,
                        column_count,
                    );
                }
            }
        }

        var violating_column: ?usize = null;
        var violating_status: i8 = 0;
        var largest_violation: f64 = 0;
        for (active_bounds, solution, 0..) |status, extent, column| {
            if (status != 0) continue;
            const scale = @max(
                1.0,
                @max(
                    @abs(lower_bounds[column]),
                    @abs(upper_bounds[column]),
                ),
            );
            const lower_violation =
                (lower_bounds[column] - extent) / scale;
            const upper_violation =
                (extent - upper_bounds[column]) / scale;
            if (lower_violation > largest_violation) {
                largest_violation = lower_violation;
                violating_column = column;
                violating_status = -1;
            }
            if (upper_violation > largest_violation) {
                largest_violation = upper_violation;
                violating_column = column;
                violating_status = 1;
            }
        }
        if (violating_column) |column| {
            const release_reclamp_cycle =
                last_released_column == column and
                last_released_status == violating_status;
            active_bounds[column] = violating_status;
            solution[column] = if (violating_status < 0)
                lower_bounds[column]
            else
                upper_bounds[column];
            if (release_reclamp_cycle) {
                return solveProjectedReactionSpanLeastSquares(
                    workspace,
                    row_count,
                    column_count,
                );
            }
            last_released_column = null;
            continue;
        }

        for (0..row_count) |row| {
            var linear_residual = -right_hand_side[row];
            for (solution, 0..) |extent, column|
                linear_residual +=
                    matrix[row * column_count + column] * extent;
            workspace.reaction_span_projected_rhs[row] = linear_residual;
        }
        const residual_norm = maximumMagnitude(
            workspace.reaction_span_projected_rhs[0..row_count],
        );
        var release_column: ?usize = null;
        var largest_kkt_violation: f64 = 0;
        for (active_bounds, 0..) |status, column| {
            if (status == 0 or status == 2) continue;
            const gradient = normalizedKktGradient(matrix, workspace.reaction_span_projected_rhs[0..row_count], column_count, column, residual_norm);
            if (!std.math.isFinite(gradient)) return false;
            const violation = if (status < 0)
                -gradient
            else
                gradient;
            if (violation > @sqrt(std.math.floatEps(f64)) and
                violation > largest_kkt_violation)
            {
                largest_kkt_violation = violation;
                release_column = column;
            }
        }
        if (release_column) |column| {
            last_released_column = column;
            last_released_status = active_bounds[column];
            active_bounds[column] = 0;
            continue;
        }
        // Pivoted QR deliberately truncates numerically dependent free
        // directions. Such a step is publishable only when those dropped
        // directions also satisfy the full bounded-system KKT certificate;
        // the active-bound release loop above cannot check them because their
        // status is free. A failed certificate enters the existing projected
        // recovery, which either finds a certified point or rejects the
        // direction without changing accepted state.
        if (workspace.reaction_span_last_rank < free_count) {
            if (!reactionSpanProjectedKktSatisfied(
                workspace,
                row_count,
                column_count,
            )) {
                return solveProjectedReactionSpanLeastSquares(
                    workspace,
                    row_count,
                    column_count,
                );
            }
            // Prefer the all-coordinate projected solution when it can reach
            // a KKT-certified point. If its bounded sweep cannot certify,
            // retain the already certified truncated-QR point rather than
            // discarding a valid Newton direction. The probe buffer is no
            // longer live after QR and provides deterministic rollback.
            const saved_solution =
                workspace.reaction_span_probe_residual[0..column_count];
            @memcpy(saved_solution, solution);
            if (solveProjectedReactionSpanLeastSquares(
                workspace,
                row_count,
                column_count,
            )) return true;
            @memcpy(solution, saved_solution);
            workspace.reaction_span_used_truncated_qr = true;
        }
        for (solution) |extent|
            if (!std.math.isFinite(extent)) return false;
        return true;
    }
    return solveProjectedReactionSpanLeastSquares(
        workspace,
        row_count,
        column_count,
    );
}

pub fn solvePivotedHouseholder(
    matrix: []f64,
    right_hand_side: []f64,
    solution: []f64,
    pivots: []usize,
    permutation_work: []f64,
    row_count: usize,
    column_count: usize,
    rank_output: ?*usize,
    pivot_norms_output: ?[]f64,
) bool {
    if (rank_output) |output| output.* = 0;
    if (row_count < column_count or
        matrix.len != row_count * column_count or
        right_hand_side.len != row_count or
        solution.len != column_count or
        pivots.len != column_count or
        permutation_work.len != column_count)
    {
        return false;
    }
    @memset(solution, 0);
    for (pivots, 0..) |*pivot, index| pivot.* = index;
    var leading_norm: f64 = 0;
    var rank: usize = 0;
    for (0..column_count) |column| {
        var pivot_column = column;
        var pivot_norm: f64 = 0;
        for (column..column_count) |candidate| {
            const norm = matrixColumnNorm(
                matrix,
                row_count,
                column_count,
                candidate,
                column,
            );
            if (norm > pivot_norm) {
                pivot_norm = norm;
                pivot_column = candidate;
            }
        }
        if (column == 0) leading_norm = pivot_norm;
        if (pivot_norms_output) |output| output[column] = pivot_norm;
        // Rank is a property of the supplied linear model. A sqrt(epsilon)
        // cutoff can remove resolvable independent balance equations even
        // when their exact solution is bounded. Use dimension-scaled QR
        // roundoff here; candidate pricing and KKT checks separately decide
        // whether this model supplies a useful nonlinear step.
        if (!std.math.isFinite(pivot_norm) or pivot_norm <=
            std.math.floatEps(f64) * @as(f64, @floatFromInt(row_count)) * leading_norm)
        {
            break;
        }
        if (pivot_column != column) {
            for (0..row_count) |row| {
                std.mem.swap(
                    f64,
                    &matrix[row * column_count + column],
                    &matrix[row * column_count + pivot_column],
                );
            }
            std.mem.swap(
                usize,
                &pivots[column],
                &pivots[pivot_column],
            );
        }
        const diagonal_index = column * column_count + column;
        const diagonal = matrix[diagonal_index];
        const reflected_diagonal =
            if (diagonal >= 0) -pivot_norm else pivot_norm;
        const leading_householder = diagonal - reflected_diagonal;
        if (!std.math.isFinite(leading_householder) or
            leading_householder == 0)
        {
            break;
        }
        var squared_tail: f64 = 1;
        for (column + 1..row_count) |row| {
            const index = row * column_count + column;
            matrix[index] /= leading_householder;
            squared_tail += matrix[index] * matrix[index];
        }
        const factor = 2 / squared_tail;
        for (column + 1..column_count) |target_column| {
            var dot = matrix[column * column_count + target_column];
            for (column + 1..row_count) |row| {
                dot += matrix[row * column_count + column] *
                    matrix[row * column_count + target_column];
            }
            dot *= factor;
            matrix[column * column_count + target_column] -= dot;
            for (column + 1..row_count) |row| {
                matrix[row * column_count + target_column] -=
                    matrix[row * column_count + column] * dot;
            }
        }
        var rhs_dot = right_hand_side[column];
        for (column + 1..row_count) |row|
            rhs_dot += matrix[row * column_count + column] *
                right_hand_side[row];
        rhs_dot *= factor;
        right_hand_side[column] -= rhs_dot;
        for (column + 1..row_count) |row|
            right_hand_side[row] -=
                matrix[row * column_count + column] * rhs_dot;
        matrix[diagonal_index] = reflected_diagonal;
        rank += 1;
    }
    if (rank == 0) return false;
    if (rank_output) |output| output.* = rank;
    @memset(permutation_work, 0);
    var reverse_index = rank;
    while (reverse_index > 0) {
        reverse_index -= 1;
        var value = right_hand_side[reverse_index];
        for (reverse_index + 1..rank) |column|
            value -= matrix[reverse_index * column_count + column] *
                permutation_work[column];
        const diagonal =
            matrix[reverse_index * column_count + reverse_index];
        if (!std.math.isFinite(diagonal) or diagonal == 0) return false;
        permutation_work[reverse_index] = value / diagonal;
        if (!std.math.isFinite(permutation_work[reverse_index]))
            return false;
    }
    for (0..rank) |index|
        solution[pivots[index]] = permutation_work[index];
    return true;
}

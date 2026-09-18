//! `reaction_solver` declarations: types.
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
const group_solve = @import("reaction_solver_solve.zig");

pub const Options = struct {
    // These scales guide the numerical search. Physical endpoint acceptance
    // uses reaction_physical_quality independently of these tolerances.
    absolute_tolerance_mol_per_m3: f64 = 1e-11,
    absolute_tolerance_mol_per_megagram: f64 = 1e-11,
    relative_tolerance: f64 = 1e-8,
    /// Ephemeral, caller-owned reference inventories for search merit only.
    /// These references never enter physical endpoint acceptance.
    search_reference_concentrations: ?[]const f64 = null,
    picard_relaxation: f64 = 0.5,
    directional_probe_fraction: f64 = 0.5,
    minimum_newton_fraction: f64 = 0.05,
    maximum_newton_fraction: f64 = 1.0,
    /// Zero-rate axes are normally retained as semismooth complementarity
    /// faces. Carrier-free boundary equilibria may disable them for the
    /// full-network predictor: an omitted axis is reconsidered as soon as its
    /// exact rate becomes nonzero, and all accepted candidates still pass the
    /// complete residual and conservation gates.
    include_zero_rate_full_network_axes: bool = true,
    /// Performance-only gate for the preliminary rate-ordered scalar scan.
    /// The complete Jacobian-ranked coordinate Newton search remains the
    /// fallback above this norm, so this changes neither the nonlinear
    /// acceptance criterion nor the available conservative search space.
    rate_ranked_coordinate_head_maximum_norm: f64 = std.math.inf(f64),
    /// `MRXN=60` in SOLUTE.F; convergence exits before this ceiling.
    max_iterations: u16 = 60,
    /// Retained for durable snapshot/options compatibility. Explosive source
    /// growth now stops immediately instead of consuming a patience counter.
    divergence_patience: u16 = 8,
    /// Maximum growth over the best observed inventory-scaled source norm.
    divergence_growth_factor: f64 = 1.0e3,
    /// Required Anderson-accelerated recovery after Newton failure. A relaxed
    /// fixed-point sample is never accepted directly.
    anderson_recovery: bool = true,

    pub fn absoluteToleranceForPackedComponent(self: Options, index: usize) f64 {
        return if (chemistry.State.packedComponentIsMolPerMegagram(index))
            self.absolute_tolerance_mol_per_megagram
        else
            self.absolute_tolerance_mol_per_m3;
    }
};

pub const Result = struct {
    iterations: u16,
    newton_raphson_steps: u16,
    /// Compatibility counter: every recorded Picard step is a genuine
    /// Anderson recovery, never a relaxed fixed-point publication.
    picard_steps: u16,
    anderson_steps: u16 = 0,
    /// Compatibility field: maximum chemical-quality budget ratio at an
    /// accepted endpoint, not a claim of numerical residual precision.
    maximum_scaled_residual: f64,
    converged: bool,
    /// `RHHX` from the single terminal accepted water-equilibrium replay.
    /// It remains intensive here; the production owner multiplies it by the
    /// authoritative layer water volume exactly once after solve success.
    accepted_water_equilibrium_extent_mol_per_m3: f64 = 0,
};

pub const CandidateKind = enum {
    none,
    converged,
    full_network_newton,
    inventory_boundary_newton,
    phosphate_extent_newton,
    anderson_depth_two,
    anderson_depth_one,
    directional_newton,
    coordinate_newton,
    coordinate_anderson,
    surface_charge_newton,
    surface_mineral_newton,
    stagnated,
    iteration_ceiling,
};

pub const FullNetworkCandidateStatus = enum {
    not_attempted,
    no_active_reactions,
    no_jacobian_columns,
    bounded_solve_failed,
    zero_extent,
    inventory_projection_failed,
    predicted_merit_rejected,
    actual_merit_rejected,
    accepted,
};

pub const CoupledExtentReaction = enum {
    non_band_hpo4_protonation,
    non_band_iron_hpo4_pairing,
    non_band_iron_h2po4_pairing,
    non_band_calcium_hpo4_pairing,
    non_band_calcium_h2po4_pairing,
    non_band_h2po4_protonated_site_exchange,
    non_band_h2po4_hydroxyl_site_exchange,
    non_band_hpo4_hydroxyl_site_exchange,
    band_hpo4_protonation,
    band_iron_hpo4_pairing,
    band_iron_h2po4_pairing,
    band_calcium_hpo4_pairing,
    band_calcium_h2po4_pairing,
    band_h2po4_protonated_site_exchange,
    band_h2po4_hydroxyl_site_exchange,
    band_hpo4_hydroxyl_site_exchange,
    aqueous_calcium_hydroxide_pairing,
    aqueous_calcium_carbonate_pairing,
    aqueous_calcium_bicarbonate_pairing,
    aqueous_calcium_sulfate_pairing,
};

pub const coupled_extent_reaction_count =
    @typeInfo(CoupledExtentReaction).@"enum".fields.len;

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    /// Replay diagnostics survive the closure-local search-reference array.
    last_search_metric: ?struct { component: usize, maximum: f64, rms: f64 } = null,
    last_selected_candidate: CandidateKind = .none,
    /// Best finite, bounded, inventory-conserving iterate across this closure.
    /// This is retained on failure for inspection/recovery, not published as
    /// an equilibrium unless the independent physical source gate passes.
    best_bounded_state: []f64,
    best_bounded_residual: []f64,
    /// Maximum physical chemical-quality ratio; search scores are separate.
    best_bounded_maximum: f64,
    best_bounded_iteration: ?u16,
    best_bounded_kind: CandidateKind,
    last_iteration: u16,
    current: []f64,
    residual: []f64,
    probe_state: []f64,
    probe_residual: []f64,
    candidate_state: []f64,
    candidate_residual: []f64,
    iteration_best_state: []f64,
    iteration_best_residual: []f64,
    previous_state: []f64,
    previous_residual: []f64,
    previous_previous_state: []f64,
    previous_previous_residual: []f64,
    rollback_state: []f64,
    /// Scratch output for `tryAcceptAndersonCandidate` calls made from
    /// `evaluateComplementarityCandidate`'s trace-instrumented search. Must
    /// never alias `rollback_state`: that buffer is the transactional
    /// pre-solve snapshot restored by the outer solve's `errdefer` on
    /// failure, and this candidate evaluation runs (and discards trial
    /// vectors) while that snapshot must remain valid.
    complementarity_candidate_state: []f64,
    phosphate_extent_jacobian: []f64,
    phosphate_extent_rhs: []f64,
    phosphate_extent_projected_jacobian: []f64,
    phosphate_extent_projected_rhs: []f64,
    phosphate_extent_solution: []f64,
    phosphate_extent_residual: []f64,
    phosphate_extent_probe_residual: []f64,
    phosphate_extent_pivots: []usize,
    phosphate_extent_free_columns: []usize,
    phosphate_extent_active_bounds: []i8,
    reaction_span_jacobian: []f64,
    reaction_span_negative_jacobian: []f64,
    reaction_span_positive_jacobian: []f64,
    reaction_span_rhs: []f64,
    reaction_span_projected_jacobian: []f64,
    reaction_span_projected_rhs: []f64,
    reaction_span_solution: []f64,
    reaction_span_best_state: []f64,
    reaction_span_best_residual: []f64,
    reaction_span_residual: []f64,
    reaction_span_probe_residual: []f64,
    reaction_span_pivots: []usize,
    reaction_span_free_columns: []usize,
    reaction_span_active_bounds: []i8,
    reaction_span_active_reactions: []usize,
    reaction_span_lower_bounds: []f64,
    reaction_span_upper_bounds: []f64,
    reaction_span_original_lower_bounds: []f64,
    reaction_span_original_upper_bounds: []f64,
    reaction_span_extent_scales: []f64,
    reaction_span_rates: []f64,
    reaction_span_branch_states: []i8,
    reaction_span_active_row_pair_keys: []usize,
    reaction_span_active_row_pair_order: []usize,
    reaction_span_active_row_pair_predicted_scores: []f64,
    reaction_span_active_count: usize,
    reaction_span_last_rank: usize,
    reaction_span_allow_truncated_qr: bool,
    reaction_span_used_truncated_qr: bool,
    reaction_span_last_predicted_norm: f64,
    scratch: chemistry.State,

    const allocation_count = 51;
    const active_row_face_pair_capacity =
        2 * reaction_span.reaction_count * (reaction_span.reaction_count - 1);

    const TrackedAllocation = union(enum) {
        floats: []f64,
        indices: []usize,
        bounds: []i8,
    };

    noinline fn allocateFloats(
        allocator: std.mem.Allocator,
        allocations: *[allocation_count]TrackedAllocation,
        allocated_count: *usize,
        count: usize,
    ) ![]f64 {
        const values = try allocator.alloc(f64, count);
        std.debug.assert(allocated_count.* < allocations.len);
        allocations[allocated_count.*] = .{ .floats = values };
        allocated_count.* += 1;
        return values;
    }

    noinline fn allocateIndices(
        allocator: std.mem.Allocator,
        allocations: *[allocation_count]TrackedAllocation,
        allocated_count: *usize,
        count: usize,
    ) ![]usize {
        const values = try allocator.alloc(usize, count);
        std.debug.assert(allocated_count.* < allocations.len);
        allocations[allocated_count.*] = .{ .indices = values };
        allocated_count.* += 1;
        return values;
    }

    noinline fn allocateBounds(
        allocator: std.mem.Allocator,
        allocations: *[allocation_count]TrackedAllocation,
        allocated_count: *usize,
        count: usize,
    ) ![]i8 {
        const values = try allocator.alloc(i8, count);
        std.debug.assert(allocated_count.* < allocations.len);
        allocations[allocated_count.*] = .{ .bounds = values };
        allocated_count.* += 1;
        return values;
    }

    /// Releases exactly the successfully allocated prefix in reverse
    /// acquisition order. Keeping the loop out of line prevents each later
    /// allocation error edge in `init` from receiving another fully expanded
    /// copy of every preceding allocator cleanup.
    noinline fn deinitAllocatedPrefix(
        allocator: std.mem.Allocator,
        allocations: *[allocation_count]TrackedAllocation,
        allocated_count: usize,
    ) void {
        var remaining = allocated_count;
        while (remaining != 0) {
            remaining -= 1;
            switch (allocations[remaining]) {
                .floats => |values| allocator.free(values),
                .indices => |values| allocator.free(values),
                .bounds => |values| allocator.free(values),
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator) !Workspace {
        const count = chemistry.State.packedComponentCount();
        var result: Workspace = undefined;
        result.allocator = allocator;
        result.last_search_metric = null;
        result.last_selected_candidate = .none;
        result.best_bounded_maximum = std.math.inf(f64);
        result.best_bounded_iteration = null;
        result.best_bounded_kind = .none;
        result.last_iteration = 0;

        var allocations: [allocation_count]TrackedAllocation = undefined;
        var allocated_count: usize = 0;
        errdefer deinitAllocatedPrefix(allocator, &allocations, allocated_count);

        result.current = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.best_bounded_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.best_bounded_residual = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.residual = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.probe_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.probe_residual = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.candidate_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.candidate_residual = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.iteration_best_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.iteration_best_residual = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.previous_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.previous_residual = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.previous_previous_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.previous_previous_residual = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.rollback_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.complementarity_candidate_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.phosphate_extent_jacobian = try allocateFloats(allocator, &allocations, &allocated_count, count * coupled_extent_reaction_count);
        result.phosphate_extent_rhs = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.phosphate_extent_projected_jacobian = try allocateFloats(allocator, &allocations, &allocated_count, count * coupled_extent_reaction_count);
        result.phosphate_extent_projected_rhs = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.phosphate_extent_solution = try allocateFloats(allocator, &allocations, &allocated_count, coupled_extent_reaction_count);
        result.phosphate_extent_residual = try allocateFloats(allocator, &allocations, &allocated_count, coupled_extent_reaction_count);
        result.phosphate_extent_probe_residual = try allocateFloats(allocator, &allocations, &allocated_count, coupled_extent_reaction_count);
        result.phosphate_extent_pivots = try allocateIndices(allocator, &allocations, &allocated_count, coupled_extent_reaction_count);
        result.phosphate_extent_free_columns = try allocateIndices(allocator, &allocations, &allocated_count, coupled_extent_reaction_count);
        result.phosphate_extent_active_bounds = try allocateBounds(allocator, &allocations, &allocated_count, coupled_extent_reaction_count);
        result.reaction_span_jacobian = try allocateFloats(allocator, &allocations, &allocated_count, count * reaction_span.reaction_count);
        result.reaction_span_negative_jacobian = try allocateFloats(allocator, &allocations, &allocated_count, count * reaction_span.reaction_count);
        result.reaction_span_positive_jacobian = try allocateFloats(allocator, &allocations, &allocated_count, count * reaction_span.reaction_count);
        result.reaction_span_rhs = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.reaction_span_projected_jacobian = try allocateFloats(allocator, &allocations, &allocated_count, count * reaction_span.reaction_count);
        result.reaction_span_projected_rhs = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.reaction_span_solution = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_best_state = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.reaction_span_best_residual = try allocateFloats(allocator, &allocations, &allocated_count, count);
        result.reaction_span_residual = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_probe_residual = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_pivots = try allocateIndices(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_free_columns = try allocateIndices(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_active_bounds = try allocateBounds(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_active_reactions = try allocateIndices(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_lower_bounds = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_upper_bounds = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_original_lower_bounds = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_original_upper_bounds = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_extent_scales = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_rates = try allocateFloats(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_branch_states = try allocateBounds(allocator, &allocations, &allocated_count, reaction_span.reaction_count);
        result.reaction_span_active_row_pair_keys = try allocateIndices(allocator, &allocations, &allocated_count, active_row_face_pair_capacity);
        result.reaction_span_active_row_pair_order = try allocateIndices(allocator, &allocations, &allocated_count, active_row_face_pair_capacity);
        result.reaction_span_active_row_pair_predicted_scores = try allocateFloats(allocator, &allocations, &allocated_count, active_row_face_pair_capacity);
        std.debug.assert(allocated_count == allocation_count);

        result.reaction_span_active_count = 0;
        result.reaction_span_last_rank = 0;
        result.reaction_span_allow_truncated_qr = true;
        result.reaction_span_used_truncated_qr = false;
        result.reaction_span_last_predicted_norm = std.math.inf(f64);
        result.scratch = try chemistry.State.init(allocator, 1);
        return result;
    }

    pub fn deinit(self: *Workspace) void {
        self.scratch.deinit();
        self.allocator.free(self.reaction_span_active_row_pair_predicted_scores);
        self.allocator.free(self.reaction_span_active_row_pair_order);
        self.allocator.free(self.reaction_span_active_row_pair_keys);
        self.allocator.free(self.reaction_span_branch_states);
        self.allocator.free(self.reaction_span_rates);
        self.allocator.free(self.reaction_span_extent_scales);
        self.allocator.free(self.reaction_span_original_upper_bounds);
        self.allocator.free(self.reaction_span_original_lower_bounds);
        self.allocator.free(self.reaction_span_upper_bounds);
        self.allocator.free(self.reaction_span_lower_bounds);
        self.allocator.free(self.reaction_span_active_reactions);
        self.allocator.free(self.reaction_span_active_bounds);
        self.allocator.free(self.reaction_span_free_columns);
        self.allocator.free(self.reaction_span_pivots);
        self.allocator.free(self.reaction_span_probe_residual);
        self.allocator.free(self.reaction_span_residual);
        self.allocator.free(self.reaction_span_best_residual);
        self.allocator.free(self.reaction_span_best_state);
        self.allocator.free(self.reaction_span_solution);
        self.allocator.free(self.reaction_span_projected_rhs);
        self.allocator.free(self.reaction_span_projected_jacobian);
        self.allocator.free(self.reaction_span_rhs);
        self.allocator.free(self.reaction_span_positive_jacobian);
        self.allocator.free(self.reaction_span_negative_jacobian);
        self.allocator.free(self.reaction_span_jacobian);
        self.allocator.free(self.phosphate_extent_active_bounds);
        self.allocator.free(self.phosphate_extent_free_columns);
        self.allocator.free(self.phosphate_extent_pivots);
        self.allocator.free(self.phosphate_extent_probe_residual);
        self.allocator.free(self.phosphate_extent_residual);
        self.allocator.free(self.phosphate_extent_solution);
        self.allocator.free(self.phosphate_extent_projected_rhs);
        self.allocator.free(self.phosphate_extent_projected_jacobian);
        self.allocator.free(self.phosphate_extent_rhs);
        self.allocator.free(self.phosphate_extent_jacobian);
        self.allocator.free(self.complementarity_candidate_state);
        self.allocator.free(self.rollback_state);
        self.allocator.free(self.previous_previous_residual);
        self.allocator.free(self.previous_previous_state);
        self.allocator.free(self.previous_residual);
        self.allocator.free(self.previous_state);
        self.allocator.free(self.candidate_residual);
        self.allocator.free(self.candidate_state);
        self.allocator.free(self.iteration_best_residual);
        self.allocator.free(self.iteration_best_state);
        self.allocator.free(self.probe_residual);
        self.allocator.free(self.probe_state);
        self.allocator.free(self.residual);
        self.allocator.free(self.current);
        self.allocator.free(self.best_bounded_residual);
        self.allocator.free(self.best_bounded_state);
        self.* = undefined;
    }
};

fn initializeWorkspaceForAllocationTest(allocator: std.mem.Allocator) !void {
    var workspace = try Workspace.init(allocator);
    workspace.deinit();
}

test "reaction solver workspace releases every failed allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initializeWorkspaceForAllocationTest,
        .{},
    );
}

test "reaction solver workspace preserves every buffer extent and resets counters" {
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();

    const component_count = chemistry.State.packedComponentCount();
    const phosphate_count = coupled_extent_reaction_count;
    const span_count = reaction_span.reaction_count;

    try std.testing.expectEqual(component_count, workspace.current.len);
    try std.testing.expectEqual(component_count, workspace.residual.len);
    try std.testing.expectEqual(component_count, workspace.probe_state.len);
    try std.testing.expectEqual(component_count, workspace.probe_residual.len);
    try std.testing.expectEqual(component_count, workspace.candidate_state.len);
    try std.testing.expectEqual(component_count, workspace.candidate_residual.len);
    try std.testing.expectEqual(component_count, workspace.iteration_best_state.len);
    try std.testing.expectEqual(component_count, workspace.iteration_best_residual.len);
    try std.testing.expectEqual(component_count, workspace.previous_state.len);
    try std.testing.expectEqual(component_count, workspace.previous_residual.len);
    try std.testing.expectEqual(component_count, workspace.previous_previous_state.len);
    try std.testing.expectEqual(component_count, workspace.previous_previous_residual.len);
    try std.testing.expectEqual(component_count, workspace.rollback_state.len);
    try std.testing.expectEqual(component_count, workspace.complementarity_candidate_state.len);

    try std.testing.expectEqual(component_count * phosphate_count, workspace.phosphate_extent_jacobian.len);
    try std.testing.expectEqual(component_count, workspace.phosphate_extent_rhs.len);
    try std.testing.expectEqual(component_count * phosphate_count, workspace.phosphate_extent_projected_jacobian.len);
    try std.testing.expectEqual(component_count, workspace.phosphate_extent_projected_rhs.len);
    try std.testing.expectEqual(phosphate_count, workspace.phosphate_extent_solution.len);
    try std.testing.expectEqual(phosphate_count, workspace.phosphate_extent_residual.len);
    try std.testing.expectEqual(phosphate_count, workspace.phosphate_extent_probe_residual.len);
    try std.testing.expectEqual(phosphate_count, workspace.phosphate_extent_pivots.len);
    try std.testing.expectEqual(phosphate_count, workspace.phosphate_extent_free_columns.len);
    try std.testing.expectEqual(phosphate_count, workspace.phosphate_extent_active_bounds.len);

    try std.testing.expectEqual(component_count * span_count, workspace.reaction_span_jacobian.len);
    try std.testing.expectEqual(component_count * span_count, workspace.reaction_span_negative_jacobian.len);
    try std.testing.expectEqual(component_count * span_count, workspace.reaction_span_positive_jacobian.len);
    try std.testing.expectEqual(component_count, workspace.reaction_span_rhs.len);
    try std.testing.expectEqual(component_count * span_count, workspace.reaction_span_projected_jacobian.len);
    try std.testing.expectEqual(component_count, workspace.reaction_span_projected_rhs.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_solution.len);
    try std.testing.expectEqual(component_count, workspace.reaction_span_best_state.len);
    try std.testing.expectEqual(component_count, workspace.reaction_span_best_residual.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_residual.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_probe_residual.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_pivots.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_free_columns.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_active_bounds.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_active_reactions.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_lower_bounds.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_upper_bounds.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_original_lower_bounds.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_original_upper_bounds.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_extent_scales.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_rates.len);
    try std.testing.expectEqual(span_count, workspace.reaction_span_branch_states.len);
    const active_row_pair_capacity = 2 * span_count * (span_count - 1);
    try std.testing.expectEqual(active_row_pair_capacity, workspace.reaction_span_active_row_pair_keys.len);
    try std.testing.expectEqual(active_row_pair_capacity, workspace.reaction_span_active_row_pair_order.len);
    try std.testing.expectEqual(active_row_pair_capacity, workspace.reaction_span_active_row_pair_predicted_scores.len);

    try std.testing.expectEqual(@as(usize, 0), workspace.reaction_span_active_count);
    try std.testing.expectEqual(@as(usize, 0), workspace.reaction_span_last_rank);
    try std.testing.expectEqual(@as(usize, 1), workspace.scratch.cell_count);
    inline for (@typeInfo(chemistry.State).@"struct".fields) |field| {
        if (@typeInfo(field.type) == .pointer) {
            try std.testing.expectEqual(@as(usize, 1), @field(workspace.scratch, field.name).len);
        }
    }
}

pub const SolverTrace = group_solve.__solve.SolverTrace;

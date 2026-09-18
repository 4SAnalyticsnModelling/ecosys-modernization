const std = @import("std");
const RootState = @import("plant_root_system.zig").State;
const numerics = @import("../../core/numerics.zig");

pub const species_count: usize = 8;
pub const TransactionMapping = [species_count]f64;

pub fn mapTransactionResult(staged_exchange_mol: []const f64) !TransactionMapping {
    if (staged_exchange_mol.len != species_count) return error.RootSaltSpeciesCountMismatch;
    var mapped: TransactionMapping = undefined;
    for (staged_exchange_mol, 0..) |exchange, species| {
        if (!std.math.isFinite(exchange)) return error.NonFiniteRootSaltCompetition;
        mapped[species] = exchange;
    }
    return mapped;
}

pub const Parameters = struct {
    reference_temperature_k: f64,
    aqueous_diffusivity_m2_per_h_at_reference: [species_count]f64,
    aqueous_diffusivity_temperature_exponent: f64,
    root_concentration_inhibition_mol_per_m3: [species_count]f64,

    pub fn validate(self: Parameters) !void {
        if (!std.math.isFinite(self.reference_temperature_k) or self.reference_temperature_k <= 0 or
            !std.math.isFinite(self.aqueous_diffusivity_temperature_exponent) or self.aqueous_diffusivity_temperature_exponent < 0)
            return error.InvalidRootSaltParameter;
        for (self.aqueous_diffusivity_m2_per_h_at_reference) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidRootSaltParameter;
        for (self.root_concentration_inhibition_mol_per_m3) |value| if (!std.math.isFinite(value) or value <= 0) return error.InvalidRootSaltParameter;
    }

    pub fn diffusivityM2PerH(self: Parameters, species: usize, temperature_k: f64) !f64 {
        try self.validate();
        if (species >= species_count) return error.RootSaltSpeciesOutOfBounds;
        if (!std.math.isFinite(temperature_k) or temperature_k <= 0) return error.InvalidRootSaltTemperature;
        const value = self.aqueous_diffusivity_m2_per_h_at_reference[species] *
            std.math.pow(f64, temperature_k / self.reference_temperature_k, self.aqueous_diffusivity_temperature_exponent);
        if (!std.math.isFinite(value)) return error.NonFiniteRootSaltDiffusivity;
        return value;
    }
};

pub fn compatibilityParameters() Parameters {
    return .{
        .reference_temperature_k = 298.15,
        .aqueous_diffusivity_m2_per_h_at_reference = .{5.0e-6} ** species_count,
        .aqueous_diffusivity_temperature_exponent = 6,
        .root_concentration_inhibition_mol_per_m3 = .{ 1.0e-5, 1.0e-3, 1, 1, 1.0e-3, 1, 1, 1.0e-3 },
    };
}

pub const Input = struct {
    soil_content_mol: f64,
    root_content_mol: f64,
    soil_water_volume_m3: f64,
    root_water_volume_m3: f64,
    water_advection_m3_per_step: f64,
    diffusive_conductance_m3_per_step: f64,
    plant_population_count: f64,
    equilibration_fraction: f64,
    root_concentration_inhibition_mol_per_m3: f64,
};

/// Exact dynamic-salt UPTAKE kernel shared by Al, Fe, Ca, Mg, Na, K, SO4,
/// and Cl. Positive result moves salt from soil to root; negative result is
/// release. The inhibition divisor is applied after the directional source
/// bounds, matching each RUPZ* equation.
pub fn calculateExchangeMol(input: Input) !f64 {
    inline for (@typeInfo(Input).@"struct".fields) |field| if (!std.math.isFinite(@field(input, field.name))) return error.NonFiniteRootSaltExchangeInput;
    if (input.soil_content_mol < 0 or input.root_content_mol < 0 or input.soil_water_volume_m3 <= 0 or input.root_water_volume_m3 <= 0 or input.water_advection_m3_per_step < 0 or input.diffusive_conductance_m3_per_step < 0 or input.plant_population_count <= 0 or input.equilibration_fraction < 0 or input.equilibration_fraction > 1 or input.root_concentration_inhibition_mol_per_m3 <= 0) return error.InvalidRootSaltExchangeInput;
    const soil_concentration = input.soil_content_mol / input.soil_water_volume_m3;
    const root_concentration = input.root_content_mol / input.root_water_volume_m3;
    const candidate = (input.water_advection_m3_per_step * soil_concentration +
        input.diffusive_conductance_m3_per_step * (soil_concentration - root_concentration)) * input.plant_population_count;
    const total_water = input.root_water_volume_m3 + input.soil_water_volume_m3;
    const equilibrium_extent = (input.root_water_volume_m3 * input.soil_content_mol - input.soil_water_volume_m3 * input.root_content_mol) /
        total_water * input.equilibration_fraction;
    const bounded = if (candidate > 0) @min(@max(0.0, equilibrium_extent), candidate) else @max(@min(0.0, equilibrium_extent), candidate);
    const result = bounded / (1.0 + root_concentration / input.root_concentration_inhibition_mol_per_m3);
    if (!std.math.isFinite(result)) return error.NonFiniteRootSaltExchange;
    return result;
}

pub fn state_updateExchangeMol(soil_content_mol: *f64, root_content_mol: *f64, accumulated_root_uptake_mol: *f64, exchange_mol: f64) !void {
    inline for (.{ soil_content_mol.*, root_content_mol.*, accumulated_root_uptake_mol.*, exchange_mol }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootSaltStateUpdateInput;
    if (soil_content_mol.* < 0 or root_content_mol.* < 0) return error.InvalidRootSaltStateUpdateInput;
    const next_soil = soil_content_mol.* - exchange_mol;
    const next_root = root_content_mol.* + exchange_mol;
    const next_uptake = accumulated_root_uptake_mol.* + exchange_mol;
    if (next_soil < 0 or next_root < 0) return error.InsufficientSaltForRootExchange;
    if (!std.math.isFinite(next_soil) or !std.math.isFinite(next_root) or !std.math.isFinite(next_uptake)) return error.NonFiniteRootSaltStateUpdate;
    soil_content_mol.* = next_soil;
    root_content_mol.* = next_root;
    accumulated_root_uptake_mol.* = next_uptake;
}

pub const LayerInputs = struct {
    soil_content_mol: []f64,
    root_content_mol: []f64,
    accumulated_root_uptake_mol: []f64,
    diffusive_conductance_m3_per_step: []const f64,
    root_concentration_inhibition_mol_per_m3: []const f64,
    soil_water_volume_m3: f64,
    root_water_volume_m3: f64,
    water_advection_m3_per_step: f64,
    plant_population_count: f64,
    equilibration_fraction: f64,
};

pub const LayerCompetitor = struct {
    plant: usize,
    domain: usize,
    layer: usize,
    soil_inventory_fraction: f64,
    root_water_volume_m3: f64,
    water_advection_m3_per_step: f64,
    diffusive_geometry_m: f64,
    plant_population_count: f64,
};

pub const SolverOptions = struct {
    absolute_tolerance_mol: f64,
    relative_tolerance: f64,
    picard_relaxation: f64,
    max_iterations: u16,
    /// Depth-one Anderson acceleration of the per-component relaxed Picard
    /// fallback, mirroring `core/numerics.zig`'s scalar Newton-Picard. Each
    /// (species, competitor) component keeps its own one-step history of the
    /// fixed-point defect, since this Gauss-Seidel sweep updates components
    /// independently within one outer iteration. An Anderson candidate is
    /// accepted only when it strictly improves the accepted current iterate;
    /// the plain relaxed Picard sample is private secant history, never an
    /// acceptance incumbent. Production validation rejects false.
    anderson_recovery: bool = true,
    /// Consecutive outer iterations allowed to let the worst-component scaled
    /// residual (`maximum_scaled_residual`, already normalized by
    /// `absolute_tolerance_mol + relative_tolerance * scale`) grow past
    /// `divergence_growth_factor` times the best value seen so far before the
    /// solve is treated as diverging/oscillating and fails fast, mirroring
    /// `core/numerics.zig`'s `newtonPicard` divergence watch. Without this a
    /// diverging Gauss-Seidel sweep silently burns the entire
    /// `max_iterations` budget before returning the generic
    /// `error.RootSaltSolverDidNotConverge`.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
};

pub const SolverReport = struct {
    iterations: u16,
    newton_raphson_steps: usize,
    picard_steps: usize,
    /// Recovery steps taken with the Anderson candidate rather than the plain
    /// relaxed Picard candidate. Counted inside `picard_steps` as well, so the
    /// existing step accounting is unchanged.
    anderson_steps: usize = 0,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    competitor_capacity: usize,
    competitors: []LayerCompetitor,
    admission_index_by_competitor: []usize,
    staged_exchange_mol: []f64,
    candidate_exchange_mol: []f64,
    /// Scratch for the full-vector Newton direction or Anderson seed defect.
    /// The paired defect buffer always holds the residual of the current
    /// iterate. Neither buffer carries history across accepted updates: every
    /// recovery step is a genuine same-iteration depth-one Anderson step, and
    /// the next accepted-update slot restarts with Newton.
    previous_exchange_mol: []f64,
    previous_defect_mol: []f64,

    pub fn init(allocator: std.mem.Allocator, competitor_capacity: usize) !Workspace {
        if (competitor_capacity == 0) return error.ZeroRootSaltCompetitorCapacity;
        const competitors = try allocator.alloc(LayerCompetitor, competitor_capacity);
        errdefer allocator.free(competitors);
        const admission_indices = try allocator.alloc(usize, competitor_capacity);
        errdefer allocator.free(admission_indices);
        const staged = try allocator.alloc(f64, try std.math.mul(usize, competitor_capacity, species_count));
        errdefer allocator.free(staged);
        const candidate = try allocator.alloc(f64, try std.math.mul(usize, competitor_capacity, species_count));
        errdefer allocator.free(candidate);
        const previous_exchange = try allocator.alloc(f64, try std.math.mul(usize, competitor_capacity, species_count));
        errdefer allocator.free(previous_exchange);
        const previous_defect = try allocator.alloc(f64, try std.math.mul(usize, competitor_capacity, species_count));
        @memset(staged, 0);
        @memset(candidate, 0);
        @memset(previous_exchange, 0);
        @memset(previous_defect, std.math.nan(f64));
        return .{ .allocator = allocator, .competitor_capacity = competitor_capacity, .competitors = competitors, .admission_index_by_competitor = admission_indices, .staged_exchange_mol = staged, .candidate_exchange_mol = candidate, .previous_exchange_mol = previous_exchange, .previous_defect_mol = previous_defect };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.previous_defect_mol);
        self.allocator.free(self.previous_exchange_mol);
        self.allocator.free(self.candidate_exchange_mol);
        self.allocator.free(self.staged_exchange_mol);
        self.allocator.free(self.admission_index_by_competitor);
        self.allocator.free(self.competitors);
        self.* = undefined;
    }

    pub fn advance(
        self: *Workspace,
        roots: *RootState,
        soil_content_mol: []f64,
        soil_water_volume_m3: f64,
        temperature_k: f64,
        parameters: Parameters,
        competitor_count: usize,
        options: SolverOptions,
    ) !SolverReport {
        if (competitor_count > self.competitor_capacity) return error.RootSaltCompetitorOutOfBounds;
        const report = try self.stage(
            roots,
            soil_content_mol,
            soil_water_volume_m3,
            temperature_k,
            parameters,
            competitor_count,
            options,
        );
        try self.state_updateStaged(roots, soil_content_mol, competitor_count);
        return report;
    }

    pub fn stage(self: *Workspace, roots: *const RootState, soil_content_mol: []const f64, soil_water_volume_m3: f64, temperature_k: f64, parameters: Parameters, competitor_count: usize, options: SolverOptions) !SolverReport {
        if (competitor_count > self.competitor_capacity) return error.RootSaltCompetitorOutOfBounds;
        return stageCompetingLayer(roots, soil_content_mol, soil_water_volume_m3, temperature_k, parameters, self.competitors[0..competitor_count], self.staged_exchange_mol[0 .. competitor_count * species_count], self.candidate_exchange_mol[0 .. competitor_count * species_count], self.previous_exchange_mol[0 .. competitor_count * species_count], self.previous_defect_mol[0 .. competitor_count * species_count], options);
    }

    pub fn state_updateStaged(self: *Workspace, roots: *RootState, soil_content_mol: []f64, competitor_count: usize) !void {
        if (competitor_count > self.competitor_capacity) return error.RootSaltCompetitorOutOfBounds;
        try state_updateStagedCompetingLayer(roots, soil_content_mol, self.competitors[0..competitor_count], self.staged_exchange_mol[0 .. competitor_count * species_count]);
    }
};

pub const GridWorkspace = struct {
    allocator: std.mem.Allocator,
    per_cell: []Workspace,
    admission_capacity_per_cell: usize,
    transaction_salt_storage: []TransactionMapping,
    transaction_salt_selected: []bool,

    pub fn init(allocator: std.mem.Allocator, cell_count: usize, competitor_capacity_per_cell: usize) !GridWorkspace {
        return initWithAdmissionCapacity(allocator, cell_count, competitor_capacity_per_cell, competitor_capacity_per_cell);
    }

    pub fn initWithAdmissionCapacity(allocator: std.mem.Allocator, cell_count: usize, competitor_capacity_per_cell: usize, admission_capacity_per_cell: usize) !GridWorkspace {
        if (cell_count == 0) return error.ZeroRootSaltGridCells;
        if (admission_capacity_per_cell == 0) return error.ZeroRootSaltAdmissionCapacity;
        const cells = try allocator.alloc(Workspace, cell_count);
        errdefer allocator.free(cells);
        var initialized: usize = 0;
        errdefer for (cells[0..initialized]) |*cell| cell.deinit();
        for (cells) |*cell| {
            cell.* = try Workspace.init(allocator, competitor_capacity_per_cell);
            initialized += 1;
        }
        const admission_count = try std.math.mul(usize, cell_count, admission_capacity_per_cell);
        const transaction_salt_storage = try allocator.alloc(TransactionMapping, admission_count);
        errdefer allocator.free(transaction_salt_storage);
        const transaction_salt_selected = try allocator.alloc(bool, admission_count);
        @memset(transaction_salt_selected, false);
        return .{ .allocator = allocator, .per_cell = cells, .admission_capacity_per_cell = admission_capacity_per_cell, .transaction_salt_storage = transaction_salt_storage, .transaction_salt_selected = transaction_salt_selected };
    }

    pub fn transactionSaltBuffer(self: *GridWorkspace, cell: usize) ![]TransactionMapping {
        if (cell >= self.per_cell.len) return error.RootSaltGridCellOutOfBounds;
        return self.transaction_salt_storage[cell * self.admission_capacity_per_cell ..][0..self.admission_capacity_per_cell];
    }

    pub fn transactionSaltSelection(self: *GridWorkspace, cell: usize) ![]bool {
        if (cell >= self.per_cell.len) return error.RootSaltGridCellOutOfBounds;
        return self.transaction_salt_selected[cell * self.admission_capacity_per_cell ..][0..self.admission_capacity_per_cell];
    }

    pub fn deinit(self: *GridWorkspace) void {
        for (self.per_cell) |*cell| cell.deinit();
        self.allocator.free(self.transaction_salt_selected);
        self.allocator.free(self.transaction_salt_storage);
        self.allocator.free(self.per_cell);
        self.* = undefined;
    }
};

/// Stages every runtime root competitor against one immutable layer snapshot.
/// This is the allocation-free hourly replacement for traversal-ordered RUPZ*
/// state_update in UPTAKE.
pub fn stageCompetingLayer(
    roots: *const RootState,
    soil_content_mol: []const f64,
    soil_water_volume_m3: f64,
    temperature_k: f64,
    parameters: Parameters,
    competitors: []const LayerCompetitor,
    staged_exchange_mol: []f64,
    candidate_exchange_mol: []f64,
    previous_exchange_mol: []f64,
    previous_defect_mol: []f64,
    options: SolverOptions,
) !SolverReport {
    if (soil_content_mol.len != species_count or staged_exchange_mol.len != competitors.len * species_count or candidate_exchange_mol.len != staged_exchange_mol.len or previous_exchange_mol.len != staged_exchange_mol.len or previous_defect_mol.len != staged_exchange_mol.len) return error.RootSaltSpeciesCountMismatch;
    if (!std.math.isFinite(soil_water_volume_m3) or soil_water_volume_m3 <= 0) return error.InvalidRootSaltExchangeInput;
    if (!std.math.isFinite(options.absolute_tolerance_mol) or options.absolute_tolerance_mol <= 0 or
        !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or
        !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or
        options.max_iterations == 0 or !options.anderson_recovery or
        !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1 or
        options.divergence_patience == 0)
        return error.InvalidRootSaltSolverOptions;
    try parameters.validate();
    for (competitors, 0..) |competitor, competitor_index| {
        if (!std.math.isFinite(competitor.soil_inventory_fraction) or competitor.soil_inventory_fraction < 0 or competitor.soil_inventory_fraction > 1 or
            !std.math.isFinite(competitor.diffusive_geometry_m) or competitor.diffusive_geometry_m < 0)
            return error.InvalidRootSaltCompetitor;
        _ = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
        _ = competitor_index;
    }
    @memset(staged_exchange_mol, 0);
    @memset(candidate_exchange_mol, 0);
    var updates: u16 = 0;
    var newton_raphson_steps: usize = 0;
    var picard_steps: usize = 0;
    var anderson_steps: usize = 0;
    // Divergence/oscillation watch over the worst-component scaled residual,
    // mirroring `core/numerics.zig`'s `newtonPicard`.
    var best_scaled_residual = std.math.inf(f64);
    var non_improving_steps: u16 = 0;
    var previous_scaled_residual = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var newton_retry_required = false;
    while (updates < options.max_iterations) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        const maximum_scaled_residual = try evaluateCoupledResidual(
            roots,
            soil_content_mol,
            soil_water_volume_m3,
            temperature_k,
            parameters,
            competitors,
            staged_exchange_mol,
            previous_defect_mol,
            options,
        );
        if (!retrying_newton_after_anderson and maximum_scaled_residual <= 1) return .{
            .iterations = updates,
            .newton_raphson_steps = newton_raphson_steps,
            .picard_steps = picard_steps,
            .anderson_steps = anderson_steps,
        };
        if (maximum_scaled_residual < best_scaled_residual) {
            best_scaled_residual = maximum_scaled_residual;
            non_improving_steps = 0;
        } else if (maximum_scaled_residual > options.divergence_growth_factor * best_scaled_residual) {
            non_improving_steps += 1;
            if (non_improving_steps >= options.divergence_patience) {
                std.log.warn("Root salt exchange solver diverging: update={d} max_scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ updates, maximum_scaled_residual, best_scaled_residual, options.divergence_growth_factor, options.divergence_patience });
                return error.RootSaltSolverDiverged;
            }
        } else {
            non_improving_steps = 0;
        }
        const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, previous_scaled_residual);
        if (std.math.isFinite(previous_scaled_residual) and
            previous_scaled_residual - maximum_scaled_residual <= progress_floor)
            insufficient_progress_steps +|= 1
        else
            insufficient_progress_steps = 0;
        previous_scaled_residual = maximum_scaled_residual;
        const progress_requires_anderson = insufficient_progress_steps >= 4;

        // Primary: construct one full Newton image from the immutable current
        // vector, then damp and assess it with the coupled residual. Component
        // Newton successes are never mixed with Picard coordinates.
        var newton_available = !progress_requires_anderson or retrying_newton_after_anderson;
        newton_components: for (0..species_count) |species| {
            if (!newton_available) break :newton_components;
            var total_exchange: f64 = 0;
            for (0..competitors.len) |competitor_index| total_exchange += staged_exchange_mol[competitor_index * species_count + species];
            for (competitors, 0..) |competitor, competitor_index| {
                const index = competitor_index * species_count + species;
                const residual = previous_defect_mol[index];
                const proposal = staged_exchange_mol[index] + residual;
                const probe = @max(options.absolute_tolerance_mol, 1.0e-6 * @max(1, @abs(staged_exchange_mol[index])));
                const perturbed_proposal = implicitExchangeProposal(roots, soil_content_mol[species], soil_water_volume_m3, temperature_k, parameters, competitor, species, staged_exchange_mol[index] + probe, total_exchange + probe) catch {
                    newton_available = false;
                    break :newton_components;
                };
                const derivative = (perturbed_proposal - proposal) / probe - 1;
                if (!std.math.isFinite(derivative) or @abs(derivative) <= 1.0e-12) {
                    newton_available = false;
                    break :newton_components;
                }
                const newton = staged_exchange_mol[index] - residual / derivative;
                if (!std.math.isFinite(newton)) {
                    newton_available = false;
                    break :newton_components;
                }
                previous_exchange_mol[index] = newton;
            }
        }
        if (newton_available) for (0..species_count) |species|
            constrainSpeciesExchange(roots, soil_content_mol[species], competitors, species, previous_exchange_mol);

        var accepted_scaled_residual: ?f64 = null;
        var accepted_newton = false;
        if (newton_available) {
            var fraction: f64 = 1;
            var line: u8 = 0;
            while (line < 12) : (line += 1) {
                for (candidate_exchange_mol, staged_exchange_mol, previous_exchange_mol) |*candidate, current, newton|
                    candidate.* = current + fraction * (newton - current);
                for (0..species_count) |species|
                    constrainSpeciesExchange(roots, soil_content_mol[species], competitors, species, candidate_exchange_mol);
                const trial_scaled_residual: ?f64 = evaluateCoupledResidual(
                    roots,
                    soil_content_mol,
                    soil_water_volume_m3,
                    temperature_k,
                    parameters,
                    competitors,
                    candidate_exchange_mol,
                    null,
                    options,
                ) catch null;
                if (trial_scaled_residual) |trial| if (trial < maximum_scaled_residual) {
                    accepted_scaled_residual = trial;
                    accepted_newton = true;
                    break;
                };
                fraction *= 0.5;
            }
        }

        if (!accepted_newton) {
            // The slot immediately following Anderson is reserved for Newton.
            // A rejected retry consumes that attempt without allowing a
            // second recovery step to masquerade as Newton.
            if (retrying_newton_after_anderson) {
                updates += 1;
                if (maximum_scaled_residual <= 1) return .{
                    .iterations = updates,
                    .newton_raphson_steps = newton_raphson_steps,
                    .picard_steps = picard_steps,
                    .anderson_steps = anderson_steps,
                };
                if (updates == options.max_iterations)
                    return error.RootSaltSolverDidNotConverge;
                continue;
            }
            if (updates + 1 >= options.max_iterations)
                return error.RootSaltSolverDidNotConverge;
            // Sole fallback: one well-defined relaxed Picard image of the full
            // current vector is evaluated only as Anderson's second sample.
            // It is never copied into accepted state.
            for (candidate_exchange_mol, staged_exchange_mol, previous_defect_mol) |*seed, current, residual|
                seed.* = current + options.picard_relaxation * residual;
            for (0..species_count) |species|
                constrainSpeciesExchange(roots, soil_content_mol[species], competitors, species, candidate_exchange_mol);
            _ = try evaluateCoupledResidual(
                roots,
                soil_content_mol,
                soil_water_volume_m3,
                temperature_k,
                parameters,
                competitors,
                candidate_exchange_mol,
                previous_exchange_mol,
                options,
            );
            if (!numerics.andersonDepthOneCandidate(staged_exchange_mol, previous_defect_mol, candidate_exchange_mol, previous_exchange_mol, candidate_exchange_mol))
                return error.RootSaltSolverStagnated;
            for (0..species_count) |species|
                constrainSpeciesExchange(roots, soil_content_mol[species], competitors, species, candidate_exchange_mol);

            // Backtracking applies only to the genuine Anderson direction.
            // Preserve the accelerated image while candidate is reused for
            // coupled merit probes.
            @memcpy(previous_exchange_mol, candidate_exchange_mol);
            var fraction: f64 = 1;
            var line: u8 = 0;
            while (line < 12) : (line += 1) {
                for (candidate_exchange_mol, staged_exchange_mol, previous_exchange_mol) |*candidate, current, accelerated|
                    candidate.* = current + fraction * (accelerated - current);
                for (0..species_count) |species|
                    constrainSpeciesExchange(roots, soil_content_mol[species], competitors, species, candidate_exchange_mol);
                const trial_scaled_residual: ?f64 = evaluateCoupledResidual(
                    roots,
                    soil_content_mol,
                    soil_water_volume_m3,
                    temperature_k,
                    parameters,
                    competitors,
                    candidate_exchange_mol,
                    null,
                    options,
                ) catch null;
                if (trial_scaled_residual) |trial| if (numerics.andersonImprovesAcceptedMerit(trial, maximum_scaled_residual)) {
                    accepted_scaled_residual = trial;
                    break;
                };
                fraction *= 0.5;
            }
            if (accepted_scaled_residual == null) return error.RootSaltSolverStagnated;
            picard_steps += 1;
            anderson_steps += 1;
            newton_retry_required = true;
        } else {
            newton_raphson_steps += 1;
        }

        // The candidate merit above is a read-only residual evaluation. Only
        // that audited candidate may consume one accepted-update slot. If the
        // final slot is not converged, leave staged output at the last audited
        // iterate and report failure without a hidden post-ceiling update.
        updates += 1;
        if (!newton_retry_required and accepted_scaled_residual.? <= 1) {
            @memcpy(staged_exchange_mol, candidate_exchange_mol);
            return .{
                .iterations = updates,
                .newton_raphson_steps = newton_raphson_steps,
                .picard_steps = picard_steps,
                .anderson_steps = anderson_steps,
            };
        }
        if (updates == options.max_iterations) return error.RootSaltSolverDidNotConverge;
        @memcpy(staged_exchange_mol, candidate_exchange_mol);
    }
    unreachable;
}

fn evaluateCoupledResidual(
    roots: *const RootState,
    soil_content_mol: []const f64,
    soil_water_volume_m3: f64,
    temperature_k: f64,
    parameters: Parameters,
    competitors: []const LayerCompetitor,
    exchange_mol: []const f64,
    residual_out: ?[]f64,
    options: SolverOptions,
) !f64 {
    if (residual_out) |out| if (out.len != exchange_mol.len) return error.RootSaltSpeciesCountMismatch;
    var maximum_scaled_residual: f64 = 0;
    for (0..species_count) |species| {
        var total_exchange: f64 = 0;
        for (0..competitors.len) |competitor_index| total_exchange += exchange_mol[competitor_index * species_count + species];
        for (competitors, 0..) |competitor, competitor_index| {
            const index = competitor_index * species_count + species;
            const proposal = try implicitExchangeProposal(
                roots,
                soil_content_mol[species],
                soil_water_volume_m3,
                temperature_k,
                parameters,
                competitor,
                species,
                exchange_mol[index],
                total_exchange,
            );
            const residual = proposal - exchange_mol[index];
            if (residual_out) |out| out[index] = residual;
            const scale = options.absolute_tolerance_mol + options.relative_tolerance * @max(@abs(proposal), @abs(exchange_mol[index]));
            maximum_scaled_residual = @max(maximum_scaled_residual, @abs(residual) / scale);
        }
    }
    return maximum_scaled_residual;
}

pub fn state_updateStagedCompetingLayer(roots: *RootState, soil_content_mol: []f64, competitors: []const LayerCompetitor, staged_exchange_mol: []const f64) !void {
    if (soil_content_mol.len != species_count or staged_exchange_mol.len != competitors.len * species_count) return error.RootSaltSpeciesCountMismatch;
    var total_exchange = [_]f64{0} ** species_count;
    for (0..species_count) |species| {
        for (0..competitors.len) |competitor_index| total_exchange[species] += staged_exchange_mol[competitor_index * species_count + species];
    }
    for (0..species_count) |species| {
        if (!std.math.isFinite(soil_content_mol[species]) or soil_content_mol[species] < 0 or !std.math.isFinite(total_exchange[species])) return error.InvalidRootSaltStateUpdateInput;
        if (total_exchange[species] > soil_content_mol[species]) return error.RootSaltCompetitionOverdraw;
    }
    for (competitors, 0..) |competitor, competitor_index| {
        const root_layer = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
        for (0..species_count) |species| {
            const salt_index = root_layer * species_count + species;
            const exchange = staged_exchange_mol[competitor_index * species_count + species];
            const next_root = roots.salt_content_mol[salt_index] + exchange;
            const next_uptake = roots.salt_uptake_mol_per_h[salt_index] + exchange;
            if (!std.math.isFinite(next_root) or !std.math.isFinite(next_uptake) or next_root < 0) return error.InsufficientSaltForRootExchange;
        }
    }
    for (0..species_count) |species| soil_content_mol[species] -= total_exchange[species];
    for (competitors, 0..) |competitor, competitor_index| {
        const root_layer = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
        const base = competitor_index * species_count;
        for (0..species_count) |species| {
            const salt_index = root_layer * species_count + species;
            roots.salt_content_mol[salt_index] += staged_exchange_mol[base + species];
            roots.salt_uptake_mol_per_h[salt_index] += staged_exchange_mol[base + species];
        }
    }
}

fn implicitExchangeProposal(
    roots: *const RootState,
    base_soil_content_mol: f64,
    soil_water_volume_m3: f64,
    temperature_k: f64,
    parameters: Parameters,
    competitor: LayerCompetitor,
    species: usize,
    competitor_exchange_mol: f64,
    total_exchange_mol: f64,
) !f64 {
    const root_layer = try roots.layerIndex(competitor.plant, competitor.domain, competitor.layer);
    const root_content = roots.salt_content_mol[root_layer * species_count + species];
    const final_soil = base_soil_content_mol - total_exchange_mol;
    const final_root = root_content + competitor_exchange_mol;
    if (final_soil < 0 or final_root < 0)
        return error.InvalidRootSaltCompetitionCandidate;
    const soil_concentration = final_soil * competitor.soil_inventory_fraction / soil_water_volume_m3;
    const root_concentration = final_root / competitor.root_water_volume_m3;
    const conductance = try parameters.diffusivityM2PerH(species, temperature_k) * competitor.diffusive_geometry_m;
    const candidate = (competitor.water_advection_m3_per_step * soil_concentration +
        conductance * (soil_concentration - root_concentration)) * competitor.plant_population_count;
    const allocated_base_soil = base_soil_content_mol * competitor.soil_inventory_fraction;
    const equilibrium_extent = (competitor.root_water_volume_m3 * allocated_base_soil - soil_water_volume_m3 * root_content) /
        (competitor.root_water_volume_m3 + soil_water_volume_m3);
    const bounded = if (candidate > 0) @min(@max(0, equilibrium_extent), candidate) else @max(@min(0, equilibrium_extent), candidate);
    const proposal = bounded / (1 + root_concentration / parameters.root_concentration_inhibition_mol_per_m3[species]);
    if (!std.math.isFinite(proposal)) return error.NonFiniteRootSaltCompetition;
    return proposal;
}

fn constrainSpeciesExchange(roots: *const RootState, soil_content_mol: f64, competitors: []const LayerCompetitor, species: usize, candidate: []f64) void {
    var positive: f64 = 0;
    var negative: f64 = 0;
    for (competitors, 0..) |competitor, competitor_index| {
        const index = competitor_index * species_count + species;
        const root_layer = roots.layerIndex(competitor.plant, competitor.domain, competitor.layer) catch unreachable;
        candidate[index] = @max(-roots.salt_content_mol[root_layer * species_count + species], candidate[index]);
        if (candidate[index] > 0) positive += candidate[index] else negative += candidate[index];
    }
    const maximum_positive = soil_content_mol - negative;
    if (positive > maximum_positive and positive > 0) {
        const fraction = maximum_positive / positive;
        for (0..competitors.len) |competitor_index| {
            const index = competitor_index * species_count + species;
            if (candidate[index] > 0) candidate[index] *= fraction;
        }
    }
}

/// One rollback-safe UPTAKE transaction for the named eight-salt registry.
pub fn advanceLayer(inputs: LayerInputs) ![8]f64 {
    inline for (.{ inputs.soil_content_mol, inputs.root_content_mol, inputs.accumulated_root_uptake_mol, inputs.diffusive_conductance_m3_per_step, inputs.root_concentration_inhibition_mol_per_m3 }) |values| if (values.len != 8) return error.RootSaltSpeciesCountMismatch;
    var exchange: [8]f64 = undefined;
    for (0..8) |species| exchange[species] = try calculateExchangeMol(.{
        .soil_content_mol = inputs.soil_content_mol[species],
        .root_content_mol = inputs.root_content_mol[species],
        .soil_water_volume_m3 = inputs.soil_water_volume_m3,
        .root_water_volume_m3 = inputs.root_water_volume_m3,
        .water_advection_m3_per_step = inputs.water_advection_m3_per_step,
        .diffusive_conductance_m3_per_step = inputs.diffusive_conductance_m3_per_step[species],
        .plant_population_count = inputs.plant_population_count,
        .equilibration_fraction = inputs.equilibration_fraction,
        .root_concentration_inhibition_mol_per_m3 = inputs.root_concentration_inhibition_mol_per_m3[species],
    });

    var next_soil: [8]f64 = undefined;
    var next_root: [8]f64 = undefined;
    var next_uptake: [8]f64 = undefined;
    for (0..8) |species| {
        next_soil[species] = inputs.soil_content_mol[species] - exchange[species];
        next_root[species] = inputs.root_content_mol[species] + exchange[species];
        next_uptake[species] = inputs.accumulated_root_uptake_mol[species] + exchange[species];
        inline for (.{ next_soil[species], next_root[species], next_uptake[species] }) |value| if (!std.math.isFinite(value)) return error.NonFiniteRootSaltStateUpdate;
        if (next_soil[species] < 0 or next_root[species] < 0) return error.InsufficientSaltForRootExchange;
    }
    for (0..8) |species| {
        inputs.soil_content_mol[species] = next_soil[species];
        inputs.root_content_mol[species] = next_root[species];
        inputs.accumulated_root_uptake_mol[species] = next_uptake[species];
    }
    return exchange;
}

test "UPTAKE dynamic salt exchange preserves source inhibition and bounds" {
    const input = Input{ .soil_content_mol = 8, .root_content_mol = 1, .soil_water_volume_m3 = 2, .root_water_volume_m3 = 1, .water_advection_m3_per_step = 0.1, .diffusive_conductance_m3_per_step = 0.2, .plant_population_count = 2, .equilibration_fraction = 0.5, .root_concentration_inhibition_mol_per_m3 = 2 };
    const candidate = (0.1 * 4.0 + 0.2 * (4.0 - 1.0)) * 2.0;
    const extent = (1.0 * 8.0 - 2.0 * 1.0) / 3.0 * 0.5;
    try std.testing.expectApproxEqAbs(@min(candidate, extent) / 1.5, try calculateExchangeMol(input), 1.0e-12);
}

test "UPTAKE dynamic salt state_update is conservative and atomic" {
    var soil: f64 = 2;
    var root: f64 = 1;
    var uptake: f64 = 0;
    try state_updateExchangeMol(&soil, &root, &uptake, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 3), soil + root, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), uptake, 1.0e-12);
    try std.testing.expectError(error.InsufficientSaltForRootExchange, state_updateExchangeMol(&soil, &root, &uptake, 3));
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), soil, 1.0e-12);
}

test "UPTAKE eight-salt layer transaction conserves every named species" {
    var soil = [_]f64{8} ** 8;
    var root = [_]f64{1} ** 8;
    var uptake = [_]f64{0} ** 8;
    const conductance = [_]f64{0.2} ** 8;
    const inhibition = [_]f64{2} ** 8;
    const exchange = try advanceLayer(.{ .soil_content_mol = &soil, .root_content_mol = &root, .accumulated_root_uptake_mol = &uptake, .diffusive_conductance_m3_per_step = &conductance, .root_concentration_inhibition_mol_per_m3 = &inhibition, .soil_water_volume_m3 = 2, .root_water_volume_m3 = 1, .water_advection_m3_per_step = 0.1, .plant_population_count = 2, .equilibration_fraction = 0.5 });
    for (0..8) |species| {
        try std.testing.expectApproxEqAbs(@as(f64, 9), soil[species] + root[species], 1.0e-12);
        try std.testing.expectApproxEqAbs(exchange[species], uptake[species], 1.0e-12);
    }
}

test "dynamic salt competitors share one snapshot beyond legacy plant capacity" {
    var roots = try RootState.init(std.testing.allocator, 7, 1, 1);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 7);
    defer workspace.deinit();
    var soil = [_]f64{70} ** species_count;
    const before = soil;
    for (0..7) |plant| {
        const root = try roots.layerIndex(plant, 0, 0);
        roots.aqueous_volume_m3[root] = 0.1;
        workspace.competitors[plant] = .{
            .plant = plant,
            .domain = 0,
            .layer = 0,
            .soil_inventory_fraction = 1.0 / 7.0,
            .root_water_volume_m3 = 0.1,
            .water_advection_m3_per_step = 0.01,
            .diffusive_geometry_m = 10,
            .plant_population_count = 1,
        };
    }
    const report = try workspace.advance(&roots, &soil, 1, 298.15, compatibilityParameters(), 7, .{ .absolute_tolerance_mol = 1.0e-12, .relative_tolerance = 1.0e-10, .picard_relaxation = 0.5, .max_iterations = 40 });
    try std.testing.expect(report.iterations < 40);
    try std.testing.expect(report.newton_raphson_steps > 0);
    for (0..species_count) |species| {
        var root_total: f64 = 0;
        for (0..7) |plant| root_total += roots.salt_content_mol[(try roots.layerIndex(plant, 0, 0)) * species_count + species];
        try std.testing.expectApproxEqAbs(before[species], soil[species] + root_total, 1.0e-12);
    }
    const soil_before_failure = soil;
    const root_before_failure = roots.salt_content_mol[0];
    try std.testing.expectError(error.RootSaltSolverDidNotConverge, workspace.advance(&roots, &soil, 1, 298.15, compatibilityParameters(), 7, .{ .absolute_tolerance_mol = 1.0e-30, .relative_tolerance = 1.0e-30, .picard_relaxation = 0.5, .max_iterations = 1 }));
    try std.testing.expectEqualSlices(f64, &soil_before_failure, &soil);
    try std.testing.expectEqual(root_before_failure, roots.salt_content_mol[0]);
}

test "root salt max one counts one full-vector Newton update" {
    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1);
    defer workspace.deinit();
    workspace.competitors[0] = .{
        .plant = 0,
        .domain = 0,
        .layer = 0,
        .soil_inventory_fraction = 1,
        .root_water_volume_m3 = 0.1,
        .water_advection_m3_per_step = 0.01,
        .diffusive_geometry_m = 0,
        .plant_population_count = 1,
    };
    var parameters = compatibilityParameters();
    parameters.root_concentration_inhibition_mol_per_m3 = .{1.0e30} ** species_count;
    var soil = [_]f64{8} ** species_count;
    const report = try workspace.advance(&roots, &soil, 1, 298.15, parameters, 1, .{
        .absolute_tolerance_mol = 1.0e-10,
        .relative_tolerance = 1.0e-10,
        .picard_relaxation = 0.5,
        .max_iterations = 1,
    });
    try std.testing.expectEqual(@as(u16, 1), report.iterations);
    try std.testing.expectEqual(@as(usize, 1), report.newton_raphson_steps);
    try std.testing.expectEqual(@as(usize, 0), report.picard_steps);
    try std.testing.expectEqual(@as(usize, 0), report.anderson_steps);
    try std.testing.expectEqual(report.picard_steps, report.anderson_steps);
    try std.testing.expect(report.newton_raphson_steps + report.anderson_steps <= 1);
}

test "root salt max one failure rolls back every public bit" {
    var roots = try RootState.init(std.testing.allocator, 2, 1, 1);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 2);
    defer workspace.deinit();
    for (0..2) |plant| {
        workspace.competitors[plant] = .{
            .plant = plant,
            .domain = 0,
            .layer = 0,
            .soil_inventory_fraction = 0.5,
            .root_water_volume_m3 = 0.1,
            .water_advection_m3_per_step = 0.01,
            .diffusive_geometry_m = 10,
            .plant_population_count = 1,
        };
        const layer = try roots.layerIndex(plant, 0, 0);
        for (0..species_count) |species| {
            roots.salt_content_mol[layer * species_count + species] = @as(f64, @floatFromInt(plant * species_count + species + 1)) * 0.01;
            roots.salt_uptake_mol_per_h[layer * species_count + species] = -@as(f64, @floatFromInt(plant * species_count + species + 1)) * 0.001;
        }
    }
    var soil = [_]f64{8} ** species_count;
    const soil_before = soil;
    const salt_before = try std.testing.allocator.dupe(f64, roots.salt_content_mol);
    defer std.testing.allocator.free(salt_before);
    const uptake_before = try std.testing.allocator.dupe(f64, roots.salt_uptake_mol_per_h);
    defer std.testing.allocator.free(uptake_before);
    try std.testing.expectError(error.RootSaltSolverDidNotConverge, workspace.advance(&roots, &soil, 1, 298.15, compatibilityParameters(), 2, .{
        .absolute_tolerance_mol = 1.0e-30,
        .relative_tolerance = 1.0e-30,
        .picard_relaxation = 0.5,
        .max_iterations = 1,
    }));
    try std.testing.expectEqualSlices(f64, &soil_before, &soil);
    try std.testing.expectEqualSlices(f64, salt_before, roots.salt_content_mol);
    try std.testing.expectEqualSlices(f64, uptake_before, roots.salt_uptake_mol_per_h);
}

test "dynamic salt advance is bit-identical to stage then state_update for single and shared competitors" {
    const options: SolverOptions = .{ .absolute_tolerance_mol = 1.0e-12, .relative_tolerance = 1.0e-10, .picard_relaxation = 0.5, .max_iterations = 40 };
    for ([_]usize{ 1, 2 }) |competitor_count| {
        var combined_roots = try RootState.init(std.testing.allocator, competitor_count, 1, 1);
        defer combined_roots.deinit();
        var staged_roots = try RootState.init(std.testing.allocator, competitor_count, 1, 1);
        defer staged_roots.deinit();
        var combined = try Workspace.init(std.testing.allocator, competitor_count);
        defer combined.deinit();
        var staged = try Workspace.init(std.testing.allocator, competitor_count);
        defer staged.deinit();
        for (0..competitor_count) |plant| {
            const root = try combined_roots.layerIndex(plant, 0, 0);
            const competitor: LayerCompetitor = .{ .plant = plant, .domain = 0, .layer = 0, .soil_inventory_fraction = 1 / @as(f64, @floatFromInt(competitor_count)), .root_water_volume_m3 = 0.1, .water_advection_m3_per_step = 0.01, .diffusive_geometry_m = 10, .plant_population_count = 1 };
            combined.competitors[plant] = competitor;
            staged.competitors[plant] = competitor;
            for (0..species_count) |species| {
                combined_roots.salt_content_mol[root * species_count + species] = @as(f64, @floatFromInt(species + plant + 1)) * 0.01;
                staged_roots.salt_content_mol[root * species_count + species] = combined_roots.salt_content_mol[root * species_count + species];
            }
        }
        var combined_soil = [_]f64{8} ** species_count;
        var staged_soil = combined_soil;
        const combined_report = try combined.advance(&combined_roots, &combined_soil, 1, 298.15, compatibilityParameters(), competitor_count, options);
        const staged_report = try staged.stage(&staged_roots, &staged_soil, 1, 298.15, compatibilityParameters(), competitor_count, options);
        try staged.state_updateStaged(&staged_roots, &staged_soil, competitor_count);
        try std.testing.expectEqual(combined_report, staged_report);
        try std.testing.expectEqualSlices(f64, &combined_soil, &staged_soil);
        try std.testing.expectEqualSlices(f64, combined_roots.salt_content_mol, staged_roots.salt_content_mol);
        try std.testing.expectEqualSlices(f64, combined_roots.salt_uptake_mol_per_h, staged_roots.salt_uptake_mol_per_h);
        for (0..species_count) |species| {
            var combined_total = combined_soil[species];
            var staged_total = staged_soil[species];
            for (0..competitor_count) |plant| {
                combined_total += combined_roots.salt_content_mol[(try combined_roots.layerIndex(plant, 0, 0)) * species_count + species];
                staged_total += staged_roots.salt_content_mol[(try staged_roots.layerIndex(plant, 0, 0)) * species_count + species];
            }
            try std.testing.expectEqual(combined_total, staged_total);
        }
    }
}

test "root salt solver rejects an unusable divergence watch" {
    var roots = try RootState.init(std.testing.allocator, 1, 1, 1);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 1);
    defer workspace.deinit();
    workspace.competitors[0] = .{ .plant = 0, .domain = 0, .layer = 0, .soil_inventory_fraction = 1, .root_water_volume_m3 = 0.1, .water_advection_m3_per_step = 0.01, .diffusive_geometry_m = 10, .plant_population_count = 1 };
    var soil = [_]f64{8} ** species_count;
    try std.testing.expectError(error.InvalidRootSaltSolverOptions, workspace.advance(&roots, &soil, 1, 298.15, compatibilityParameters(), 1, .{ .absolute_tolerance_mol = 1.0e-12, .relative_tolerance = 1.0e-10, .picard_relaxation = 0.5, .max_iterations = 40, .divergence_patience = 0 }));
    try std.testing.expectError(error.InvalidRootSaltSolverOptions, workspace.advance(&roots, &soil, 1, 298.15, compatibilityParameters(), 1, .{ .absolute_tolerance_mol = 1.0e-12, .relative_tolerance = 1.0e-10, .picard_relaxation = 0.5, .max_iterations = 40, .divergence_growth_factor = 0.5 }));
    try std.testing.expectError(error.InvalidRootSaltSolverOptions, workspace.advance(&roots, &soil, 1, 298.15, compatibilityParameters(), 1, .{ .absolute_tolerance_mol = 1.0e-12, .relative_tolerance = 1.0e-10, .picard_relaxation = 0.5, .max_iterations = 40, .anderson_recovery = false }));
}

test "late staged salt state_update failure rolls back every ion and disabled mappings remain unselected" {
    var roots = try RootState.init(std.testing.allocator, 2, 1, 1);
    defer roots.deinit();
    var workspace = try Workspace.init(std.testing.allocator, 2);
    defer workspace.deinit();
    for (0..2) |plant| workspace.competitors[plant] = .{ .plant = plant, .domain = 0, .layer = 0, .soil_inventory_fraction = 0.5, .root_water_volume_m3 = 0.1, .water_advection_m3_per_step = 0.01, .diffusive_geometry_m = 10, .plant_population_count = 1 };
    var soil = [_]f64{8} ** species_count;
    _ = try workspace.stage(&roots, &soil, 1, 298.15, compatibilityParameters(), 2, .{ .absolute_tolerance_mol = 1.0e-12, .relative_tolerance = 1.0e-10, .picard_relaxation = 0.5, .max_iterations = 40 });
    workspace.staged_exchange_mol[species_count + 7] = soil[7] + 1;
    const soil_before = soil;
    const roots_before = try std.testing.allocator.dupe(f64, roots.salt_content_mol);
    defer std.testing.allocator.free(roots_before);
    const uptake_before = try std.testing.allocator.dupe(f64, roots.salt_uptake_mol_per_h);
    defer std.testing.allocator.free(uptake_before);
    try std.testing.expectError(error.RootSaltCompetitionOverdraw, workspace.state_updateStaged(&roots, &soil, 2));
    try std.testing.expectEqualSlices(f64, &soil_before, &soil);
    try std.testing.expectEqualSlices(f64, roots_before, roots.salt_content_mol);
    try std.testing.expectEqualSlices(f64, uptake_before, roots.salt_uptake_mol_per_h);

    var grid = try GridWorkspace.initWithAdmissionCapacity(std.testing.allocator, 1, 2, 4);
    defer grid.deinit();
    const selected = try grid.transactionSaltSelection(0);
    try std.testing.expectEqualSlices(bool, &[_]bool{false} ** 4, selected);
}

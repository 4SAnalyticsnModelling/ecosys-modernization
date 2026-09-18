//! `reaction_solver` declarations: diagnostics.
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
const group_apply = @import("reaction_solver_apply.zig");
const group_numerics = @import("reaction_solver_numerics.zig");
const group_numerics2 = @import("reaction_solver_numerics2.zig");
const group_solve = @import("reaction_solver_solve.zig");
const group_types = @import("reaction_solver_types.zig");
const diagnostic_control = @import("reaction_diagnostic_control.zig");

pub const TernaryCorrectionFaceStatus = enum {
    not_attempted,
    initializing,
    no_initialized_axes,
    no_derivative_axes,
    base_solve_failed,
    no_ambiguous_axes,
    too_many_ambiguous_axes,
    patterns_exhausted,
    accepted,
};

pub const TernaryAmbiguousAxisSource = enum(u1) {
    sign_mismatch,
    failed_implicit_pin_kkt,
};

pub const TernaryAmbiguousAxisDiagnostic = struct {
    compact_column: usize = 0,
    reaction_index: usize = 0,
    discovery_extent: f64 = 0,
    current_rate: f64 = 0,
    extent_significance_ratio: f64 = 0,
    normalized_pinned_kkt_violation: f64 = 0,
    discovery_branch: i8 = 0,
    current_branch: i8 = 0,
    source: TernaryAmbiguousAxisSource = .sign_mismatch,
};

pub const maximum_ternary_ambiguous_axis_diagnostics: usize = 8;

pub const IterationDiagnostic = struct {
    closure_index: u8,
    iteration: u16,
    limiting_component_index: usize,
    limiting_state_value: f64,
    limiting_residual: f64,
    current_maximum_scaled_residual: f64,
    full_network_candidate_maximum_scaled_residual: f64 =
        std.math.inf(f64),
    phosphate_candidate_maximum_scaled_residual: f64 =
        std.math.inf(f64),
    full_network_status: group_types.FullNetworkCandidateStatus = .not_attempted,
    full_network_active_columns: usize = 0,
    full_network_populated_columns: usize = 0,
    full_network_rank: usize = 0,
    full_network_inventory_fraction: f64 = 0,
    full_network_predicted_maximum_scaled_residual: f64 =
        std.math.inf(f64),
    selected_candidate: group_types.CandidateKind = .none,
    anderson_attempted: bool = false,
    selected_maximum_scaled_residual: f64 = std.math.inf(f64),
    ternary_correction_status: TernaryCorrectionFaceStatus = .not_attempted,
    ternary_correction_initialized_axes: usize = 0,
    ternary_correction_kept_axes: usize = 0,
    ternary_correction_base_certified: bool = false,
    ternary_correction_discovery_rank: usize = 0,
    ternary_correction_ambiguous_axes: usize = 0,
    ternary_correction_axis_diagnostic_count: usize = 0,
    ternary_correction_axis_diagnostics: [maximum_ternary_ambiguous_axis_diagnostics]TernaryAmbiguousAxisDiagnostic =
        @splat(.{}),
    ternary_correction_pattern_count: usize = 0,
    ternary_correction_patterns_considered: usize = 0,
    ternary_correction_patterns_solved: usize = 0,
    ternary_correction_patterns_kkt: usize = 0,
    ternary_correction_patterns_nonzero: usize = 0,
    ternary_correction_patterns_admissible: usize = 0,
    ternary_correction_armijo_attempts: usize = 0,
    ternary_correction_armijo_accepted: usize = 0,
};

pub const FullNetworkReactionDiagnostic = struct {
    reaction_index: usize,
    selection_rate: f64,
    current_rate: f64,
    directional_rate: f64,
    native_extent_scale: f64,
    normalized_lower_bound: f64,
    normalized_upper_bound: f64,
    normalized_solution: f64,
    limiting_normalized_residual_derivative: f64,
    solution_side_limiting_normalized_residual_derivative: f64,
};

pub const DiagnosticDecomposition = struct {
    aqueous_hydrogen_mol_per_m3: f64,
    aqueous_hydroxide_mol_per_m3: f64,
    phosphate_hydrogen_mol_per_m3: f64,
    phosphate_hydroxide_mol_per_m3: f64,
    cation_exchange_hydrogen_mol_per_m3: f64,
    carboxyl_hydrogen_mol_per_m3: f64,
    geochemistry_hydrogen_mol_per_m3: f64,
    geochemistry_hydroxide_mol_per_m3: f64,
    assembled_hydrogen_mol_per_m3: f64,
    assembled_hydroxide_mol_per_m3: f64,
};

pub const Hpo4Diagnostic = struct {
    po4_protonation_mol_p_per_m3: f64,
    hpo4_protonation_mol_p_per_m3: f64,
    metal_pairing_mol_p_per_m3: f64,
    surface_adsorption_mol_p_per_m3: f64,
    assembled_change_mol_p_per_m3: f64,
};

pub const SecondClosureDiagnostic = struct {
    first_closure_iterations: u16,
    hpo4: Hpo4Diagnostic,
};

pub fn diagnoseSecondClosureStart(
    allocator: std.mem.Allocator,
    state: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
    options: group_types.Options,
) !SecondClosureDiagnostic {
    var staged = try chemistry.State.init(allocator, 1);
    defer staged.deinit();
    const packed_state = try allocator.alloc(f64, chemistry.State.packedComponentCount());
    defer allocator.free(packed_state);
    try state.packCell(cell_index, packed_state);
    try staged.unpackCell(0, packed_state);
    var workspace = try group_types.Workspace.init(allocator);
    defer workspace.deinit();
    const first = try group_solve.solveEquilibriumWithWorkspace(
        &workspace,
        &staged,
        0,
        group_solve.equilibriumClosureParameters(parameters),
        options,
        null,
        0,
    );
    try group_apply.applyKineticGeochemistryStep(
        &workspace.scratch,
        &staged,
        0,
        parameters,
        workspace.current,
    );
    return .{
        .first_closure_iterations = first.iterations,
        .hpo4 = try diagnoseNonBandHpo4(
            &staged,
            0,
            group_solve.equilibriumClosureParameters(parameters),
        ),
    };
}

pub fn diagnoseNonBandHpo4(
    state: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
) !Hpo4Diagnostic {
    const coefficients = try state.activityCoefficients(cell_index, parameters.fractions);
    const fluxes = try phosphate_rates.calculate(
        state.aqueous[cell_index],
        state.non_band_phosphate[cell_index],
        coefficients,
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        parameters.phosphate_constants,
        parameters.phosphate_surface,
        parameters.phosphate_minerals,
        parameters.phosphate_kinetics,
    );
    const aqueous = fluxes.aqueous;
    const surface = fluxes.surface.hpo4_with_hydroxyl_site_mol_p_per_megagram *
        fluxes.soil_mass_per_water_volume_megagrams_per_m3;
    const pairing = aqueous.iron_hpo4_pairing_mol_p_per_m3 +
        aqueous.calcium_hpo4_pairing_mol_p_per_m3 +
        aqueous.magnesium_hpo4_pairing_mol_p_per_m3;
    return .{
        .po4_protonation_mol_p_per_m3 = aqueous.po4_hydrogen_association_mol_p_per_m3,
        .hpo4_protonation_mol_p_per_m3 = -aqueous.hpo4_hydrogen_association_mol_p_per_m3,
        .metal_pairing_mol_p_per_m3 = -pairing,
        .surface_adsorption_mol_p_per_m3 = -surface,
        .assembled_change_mol_p_per_m3 = aqueous.po4_hydrogen_association_mol_p_per_m3 -
            aqueous.hpo4_hydrogen_association_mol_p_per_m3 -
            pairing - surface,
    };
}

pub fn diagnoseCell(
    state: *const chemistry.State,
    cell_index: usize,
    parameters: chemistry.ReactionParameters,
) !DiagnosticDecomposition {
    const transformations = try state.evaluateCell(cell_index, parameters);
    const assembled = try chemistry.State.assembledAqueousChanges(
        transformations,
        state.cation_exchange_mol_per_megagram[cell_index],
    );
    const phosphate_hydrogen =
        transformations.non_band_phosphate.dissolved_hydrogen_mol_per_m3 *
        parameters.fractions.phosphate_non_band +
        transformations.band_phosphate.dissolved_hydrogen_mol_per_m3 *
            parameters.fractions.phosphate_band;
    const phosphate_hydroxide =
        transformations.non_band_phosphate.dissolved_hydroxide_mol_per_m3 *
        parameters.fractions.phosphate_non_band +
        transformations.band_phosphate.dissolved_hydroxide_mol_per_m3 *
            parameters.fractions.phosphate_band;
    return .{
        .aqueous_hydrogen_mol_per_m3 = transformations.aqueous.hydrogen,
        .aqueous_hydroxide_mol_per_m3 = transformations.aqueous.hydroxide,
        .phosphate_hydrogen_mol_per_m3 = phosphate_hydrogen,
        .phosphate_hydroxide_mol_per_m3 = phosphate_hydroxide,
        .cation_exchange_hydrogen_mol_per_m3 = -transformations.cation_adsorption_mol_per_megagram.hydrogen *
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
        .carboxyl_hydrogen_mol_per_m3 = -transformations.carboxyl_hydrogen_change_mol_per_megagram *
            parameters.cation_exchange_water_ratios.shared_megagrams_per_m3,
        .geochemistry_hydrogen_mol_per_m3 = transformations.geochemistry.dissolved_hydrogen_mol_per_m3,
        .geochemistry_hydroxide_mol_per_m3 = transformations.geochemistry.dissolved_hydroxide_mol_per_m3,
        .assembled_hydrogen_mol_per_m3 = assembled.hydrogen,
        .assembled_hydroxide_mol_per_m3 = assembled.hydroxide,
    };
}

noinline fn logTerminalAdmissibilityBoundary(
    scratch: *chemistry.State,
    current: []const f64,
    transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    monovalent_activity_coefficient: f64,
) void {
    var trial_vector: [chemistry.State.packedComponentCount()]f64 = undefined;
    var fraction: f64 = 1;
    var rejected_fraction: ?f64 = null;
    var first_rejection: ?anyerror = null;
    var last_rejection: ?anyerror = null;
    var last_rejected_fraction: f64 = 1;
    var attempt: u16 = 0;
    while (attempt < group_numerics2.maximum_admissibility_backtracks) : (attempt += 1) {
        group_numerics.transformedVector(
            scratch,
            current,
            transformations,
            monovalent_activity_coefficient,
            parameters.water_activity_product_mol2_per_m6,
            fraction,
            &trial_vector,
        ) catch |err| {
            if (first_rejection == null) first_rejection = err;
            last_rejection = err;
            last_rejected_fraction = fraction;
            rejected_fraction = fraction;
            fraction *= 0.5;
            continue;
        };
        break;
    }
    const first_error = first_rejection orelse return;
    const initial_rejected = rejected_fraction orelse return;
    if (attempt == group_numerics2.maximum_admissibility_backtracks) {
        std.log.warn(
            "SOLUTE terminal admissibility rejection: first_fraction=1 first_error={s} no_positive_fraction=true last_fraction={e} last_error={s}",
            .{
                @errorName(first_error),
                last_rejected_fraction,
                @errorName(last_rejection orelse first_error),
            },
        );
        return;
    }
    var upper = initial_rejected;
    var lower = fraction;
    while (group_numerics2.admissibilityFractionMidpoint(lower, upper)) |middle| {
        group_numerics.transformedVector(
            scratch,
            current,
            transformations,
            monovalent_activity_coefficient,
            parameters.water_activity_product_mol2_per_m6,
            middle,
            &trial_vector,
        ) catch |err| {
            last_rejection = err;
            last_rejected_fraction = middle;
            upper = middle;
            continue;
        };
        lower = middle;
    }
    if ((last_rejection orelse first_error) == error.NegativeAqueousState) {
        scratch.unpackCell(0, current) catch |err| {
            std.log.warn(
                "SOLUTE terminal rejected aqueous boundary unavailable: stage=unpack error={s}",
                .{@errorName(err)},
            );
            return;
        };
        const rejected_transformations = group_numerics2.scaled(
            transformations,
            last_rejected_fraction,
        );
        const rejection = scratch.diagnoseFirstNegativeProjectedAqueous(
            0,
            rejected_transformations,
        ) catch |err| {
            std.log.warn(
                "SOLUTE terminal rejected aqueous boundary unavailable: stage=exact_staging rejected_fraction={e} error={s}",
                .{ last_rejected_fraction, @errorName(err) },
            );
            return;
        };
        if (rejection) |value| std.log.warn(
            "SOLUTE terminal rejected aqueous boundary: rejected_fraction={e} aqueous_index={d} name={s} current_mol_per_m3={e} applied_change_mol_per_m3={e} candidate_mol_per_m3={e}",
            .{
                last_rejected_fraction,
                value.component_index,
                value.component_name,
                value.current_value_mol_per_m3,
                value.applied_change_mol_per_m3,
                value.candidate_value_mol_per_m3,
            },
        );
    }
    std.log.warn(
        "SOLUTE terminal admissibility rejection: first_fraction=1 first_error={s} accepted_boundary_fraction={e} rejected_boundary_fraction={e} boundary_error={s}",
        .{
            @errorName(first_error),
            lower,
            last_rejected_fraction,
            @errorName(last_rejection orelse first_error),
        },
    );
}

pub noinline fn logTerminalReactionDecomposition(
    scratch: *chemistry.State,
    current: []const f64,
    parameters: chemistry.ReactionParameters,
) void {
    if (!diagnostic_control.isEnabled()) return;
    scratch.unpackCell(0, current) catch |err| {
        std.log.debug(
            "SOLUTE terminal decomposition unavailable: stage=unpack error={s}",
            .{@errorName(err)},
        );
        return;
    };
    const terminal_decomposition =
        diagnoseCell(scratch, 0, parameters) catch |err| {
            std.log.debug(
                "SOLUTE terminal decomposition unavailable: stage=reaction_network error={s}",
                .{@errorName(err)},
            );
            return;
        };
    const transformations = scratch.evaluateCell(0, parameters) catch |err| {
        std.log.debug(
            "SOLUTE terminal decomposition unavailable: stage=inventory_limiter error={s}",
            .{@errorName(err)},
        );
        return;
    };
    const magnesium_aqueous = transformations.aqueous.magnesium;
    const magnesium_exchange =
        -transformations.cation_adsorption_mol_per_megagram.magnesium *
        transformations.cation_exchange_water_ratios.shared_megagrams_per_m3;
    const magnesium_geochemistry =
        transformations.geochemistry.dissolved_magnesium_mol_per_m3;
    const magnesium_non_band =
        transformations.non_band_phosphate.dissolved_magnesium_mol_per_m3 *
        transformations.non_band_phosphate_water_fraction;
    const magnesium_band =
        transformations.band_phosphate.dissolved_magnesium_mol_per_m3 *
        transformations.band_phosphate_water_fraction;
    std.log.warn(
        "SOLUTE terminal magnesium transformation: aqueous={e} exchange={e} geochemistry={e} non_band_phosphate={e} band_phosphate={e} assembled={e}",
        .{
            magnesium_aqueous,
            magnesium_exchange,
            magnesium_geochemistry,
            magnesium_non_band,
            magnesium_band,
            magnesium_aqueous + magnesium_exchange +
                magnesium_geochemistry + magnesium_non_band + magnesium_band,
        },
    );
    const full_step_coefficients = scratch.activityCoefficients(
        0,
        parameters.fractions,
    ) catch |err| {
        std.log.warn(
            "SOLUTE terminal full-step diagnostic unavailable: stage=activity_coefficients error={s}",
            .{@errorName(err)},
        );
        return;
    };
    logTerminalAdmissibilityBoundary(
        scratch,
        current,
        transformations,
        parameters,
        full_step_coefficients.monovalent_activity_coefficient,
    );
    var accepted_vector: [chemistry.State.packedComponentCount()]f64 = undefined;
    const accepted_fraction = group_numerics.transformedVectorAdmissible(
        scratch,
        current,
        transformations,
        parameters,
        1,
        &accepted_vector,
    ) catch |err| {
        std.log.debug(
            "SOLUTE terminal decomposition unavailable: stage=admissibility error={s}",
            .{@errorName(err)},
        );
        return;
    };
    var realized_endpoint_secant_limit = std.math.inf(f64);
    var realized_endpoint_limiting_index: usize = 0;
    if (accepted_fraction > 0) {
        for (current, accepted_vector, 0..) |value, accepted, index| {
            const raw_change = (accepted - value) / accepted_fraction;
            if (raw_change < 0) {
                const secant_limit = value / -raw_change;
                if (secant_limit < realized_endpoint_secant_limit) {
                    realized_endpoint_secant_limit = secant_limit;
                    realized_endpoint_limiting_index = index;
                }
            }
        }
    }
    // A stagnation is terminal for this exact local solve. When reaction
    // diagnostics are enabled, keep the compact limiting coordinate visible
    // at warn level; the larger decomposition remains debug-level and is
    // available from deterministic failure replay.
    std.log.warn(
        "SOLUTE terminal global admissibility: accepted_fraction={e} realized_endpoint_limiting_index={d} realized_endpoint_limiting_name={s} realized_endpoint_secant_limit={e}",
        .{
            accepted_fraction,
            realized_endpoint_limiting_index,
            chemistry.State.packedComponentName(realized_endpoint_limiting_index) orelse
                "unknown",
            realized_endpoint_secant_limit,
        },
    );
    std.log.debug(
        "SOLUTE terminal hydrogen decomposition: aqueous={e} phosphate={e} exchange={e} carboxyl={e} geochemistry={e} assembled={e}",
        .{
            terminal_decomposition.aqueous_hydrogen_mol_per_m3,
            terminal_decomposition.phosphate_hydrogen_mol_per_m3,
            terminal_decomposition.cation_exchange_hydrogen_mol_per_m3,
            terminal_decomposition.carboxyl_hydrogen_mol_per_m3,
            terminal_decomposition.geochemistry_hydrogen_mol_per_m3,
            terminal_decomposition.assembled_hydrogen_mol_per_m3,
        },
    );
    const hpo4 =
        diagnoseNonBandHpo4(scratch, 0, parameters) catch |err| {
            std.log.warn(
                "SOLUTE terminal decomposition unavailable: stage=non_band_hpo4 error={s}",
                .{@errorName(err)},
            );
            return;
        };
    std.log.debug(
        "SOLUTE terminal non-band HPO4 decomposition: PO4_protonation={e} HPO4_protonation={e} metal_pairing={e} surface_adsorption={e} assembled={e}",
        .{
            hpo4.po4_protonation_mol_p_per_m3,
            hpo4.hpo4_protonation_mol_p_per_m3,
            hpo4.metal_pairing_mol_p_per_m3,
            hpo4.surface_adsorption_mol_p_per_m3,
            hpo4.assembled_change_mol_p_per_m3,
        },
    );
    // The admissibility probe above intentionally leaves `scratch` at the
    // realized full-step endpoint. Restore the accepted stagnated iterate
    // before diagnosing its kinetic branch.
    scratch.unpackCell(0, current) catch return;
    const coefficients =
        scratch.activityCoefficients(0, parameters.fractions) catch return;
    const phosphate = phosphate_rates.calculate(
        scratch.aqueous[0],
        scratch.non_band_phosphate[0],
        coefficients,
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        parameters.phosphate_constants,
        parameters.phosphate_surface,
        parameters.phosphate_minerals,
        parameters.phosphate_kinetics,
    ) catch return;
    const hydrogen = scratch.aqueous[0].hydrogen;
    const h2po4 = scratch.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3;
    const h3po4 = scratch.non_band_phosphate[0].dissolved_h3po4_mol_p_per_m3;
    const g1 = coefficients.monovalent_activity_coefficient;
    const h3po4_constant = parameters.phosphate_constants.h3po4;
    const h3po4_equilibrium_target = if (h3po4_constant > 0)
        (h2po4 * g1) * (hydrogen * g1) / h3po4_constant
    else
        std.math.inf(f64);
    const h3po4_uncapped_driving = if (hydrogen * g1 > 0)
        (h2po4 * g1 - h3po4_constant * h3po4 / (hydrogen * g1)) / g1
    else
        -std.math.inf(f64);
    std.log.warn(
        "TEMP_DIAGNOSTIC SOLUTE terminal H3PO4 branch: hydrogen={e} h2po4={e} h3po4={e} monovalent_activity_coefficient={e} dissociation_constant={e} equilibrium_h3po4={e} uncapped_driving={e} bounded_rate={e} dissociation_cap={e}",
        .{
            hydrogen,
            h2po4,
            h3po4,
            g1,
            h3po4_constant,
            h3po4_equilibrium_target,
            h3po4_uncapped_driving,
            phosphate.aqueous.h2po4_hydrogen_association_mol_p_per_m3,
            parameters.phosphate_kinetics.substrate_limit_fraction * h3po4,
        },
    );
    std.log.debug(
        "SOLUTE terminal non-band protonated-site decomposition: protonated_to_hydroxyl={e} h2po4_adsorption={e} assembled={e}",
        .{
            phosphate.surface.protonated_to_hydroxyl_site_mol_per_megagram,
            phosphate.surface.h2po4_with_protonated_site_mol_p_per_megagram,
            phosphate.surface.protonated_to_hydroxyl_site_mol_per_megagram -
                phosphate.surface.h2po4_with_protonated_site_mol_p_per_megagram,
        },
    );
    var acid_site_only = std.mem.zeroes(chemistry.CellTransformations);
    acid_site_only.non_band_phosphate_water_fraction =
        transformations.non_band_phosphate_water_fraction;
    acid_site_only.band_phosphate_water_fraction =
        transformations.band_phosphate_water_fraction;
    acid_site_only.cation_exchange_water_ratios =
        transformations.cation_exchange_water_ratios;
    acid_site_only.carboxyl_soil_mass_per_water_volume_megagrams_per_m3 =
        transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3;
    acid_site_only.non_band_phosphate.deprotonated_site_mol_per_megagram =
        -phosphate.surface.hydroxyl_to_deprotonated_site_mol_per_megagram;
    acid_site_only.non_band_phosphate.hydroxyl_site_mol_per_megagram =
        phosphate.surface.hydroxyl_to_deprotonated_site_mol_per_megagram -
        phosphate.surface.protonated_to_hydroxyl_site_mol_per_megagram;
    acid_site_only.non_band_phosphate.protonated_site_mol_per_megagram =
        phosphate.surface.protonated_to_hydroxyl_site_mol_per_megagram;
    acid_site_only.non_band_phosphate.dissolved_hydrogen_mol_per_m3 =
        -(phosphate.surface.protonated_to_hydroxyl_site_mol_per_megagram +
            phosphate.surface.hydroxyl_to_deprotonated_site_mol_per_megagram) *
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    var acid_site_vector: [chemistry.State.packedComponentCount()]f64 = undefined;
    const acid_site_fraction = group_numerics.transformedVectorAdmissible(
        scratch,
        current,
        acid_site_only,
        parameters,
        1,
        &acid_site_vector,
    ) catch |err| {
        std.log.debug(
            "SOLUTE terminal non-band acid-site admissibility unavailable: error={s}",
            .{@errorName(err)},
        );
        return;
    };
    std.log.debug(
        "SOLUTE terminal non-band acid-site-only admissibility: fraction={e}",
        .{acid_site_fraction},
    );
    const h2po4_minerals =
        -phosphate.minerals.aluminum_phosphate_mol_per_m3 -
        phosphate.minerals.iron_phosphate_mol_per_m3 -
        phosphate.minerals.dicalcium_phosphate_mol_per_m3 -
        3 * phosphate.minerals.hydroxyapatite_mol_per_m3 -
        2 * phosphate.minerals.monocalcium_phosphate_mol_per_m3;
    const h2po4_surface =
        -(phosphate.surface.h2po4_with_protonated_site_mol_p_per_megagram +
            phosphate.surface.h2po4_with_hydroxyl_site_mol_p_per_megagram) *
        parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    const h2po4_aqueous =
        phosphate.aqueous.hpo4_hydrogen_association_mol_p_per_m3 -
        phosphate.aqueous.h2po4_hydrogen_association_mol_p_per_m3 -
        phosphate.aqueous.iron_h2po4_pairing_mol_p_per_m3 -
        phosphate.aqueous.calcium_h2po4_pairing_mol_p_per_m3;
    std.log.debug(
        "SOLUTE terminal non-band H2PO4 decomposition: minerals={e} surface={e} aqueous={e} assembled={e}",
        .{
            h2po4_minerals,
            h2po4_surface,
            h2po4_aqueous,
            h2po4_minerals + h2po4_surface + h2po4_aqueous,
        },
    );
    std.log.debug(
        "SOLUTE terminal non-band mineral decomposition: aluminum_phosphate={e}/{e} iron_phosphate={e}/{e} dicalcium_phosphate={e}/{e} hydroxyapatite={e}/{e} monocalcium_phosphate={e}/{e}",
        .{
            phosphate.minerals.aluminum_phosphate_mol_per_m3,
            scratch.non_band_phosphate[0].aluminum_phosphate_solid_mol_per_m3,
            phosphate.minerals.iron_phosphate_mol_per_m3,
            scratch.non_band_phosphate[0].iron_phosphate_solid_mol_per_m3,
            phosphate.minerals.dicalcium_phosphate_mol_per_m3,
            scratch.non_band_phosphate[0].dicalcium_phosphate_solid_mol_per_m3,
            phosphate.minerals.hydroxyapatite_mol_per_m3,
            scratch.non_band_phosphate[0].hydroxyapatite_solid_mol_per_m3,
            phosphate.minerals.monocalcium_phosphate_mol_per_m3,
            scratch.non_band_phosphate[0].monocalcium_phosphate_solid_mol_per_m3,
        },
    );
}

pub fn exhaustsLargestResidual(
    current: []const f64,
    residual: []const f64,
    candidate: []const f64,
    options: group_types.Options,
) bool {
    var worst_index: usize = 0;
    var worst_scaled: f64 = 0;
    for (current, residual, 0..) |value, change, index| {
        const scaled_residual = @abs(change) / group_numerics.residualScale(value, index, options);
        if (scaled_residual > worst_scaled) {
            worst_scaled = scaled_residual;
            worst_index = index;
        }
    }
    return residual[worst_index] < 0 and
        candidate[worst_index] <= options.absoluteToleranceForPackedComponent(worst_index);
}

/// Names the component that stagnated, on the stagnation path.
///
/// The convergence-failure path has always reported
/// `SOLUTE largest residual: ... name=...`, but the stagnation path emitted only
/// the hydrogen decomposition, so a stagnating cell could not be attributed to a
/// component at all. Lane A9 reported this as an observability gap after it had
/// to describe four stagnating examples without being able to say what stagnated.
/// `limiting_index` is already computed each iteration for the trace, so this
/// only reports a value that was being discarded.
pub fn logTerminalStagnationComponent(
    current: []const f64,
    residual: []const f64,
    options: group_types.Options,
    limiting_index: usize,
) void {
    if (!diagnostic_control.isEnabled()) return;
    if (limiting_index >= current.len or limiting_index >= residual.len) return;
    const value = current[limiting_index];
    const change = residual[limiting_index];
    std.log.debug(
        "SOLUTE stagnated component: packed_component={d} name={s} value={e} change={e} scaled={e}",
        .{
            limiting_index,
            chemistry.State.packedComponentName(limiting_index) orelse "unknown",
            value,
            change,
            @abs(change) / group_numerics.residualScale(value, limiting_index, options),
        },
    );
}

fn logRejectedFullStep(
    scratch: *chemistry.State,
    current: []const f64,
    transformations: chemistry.CellTransformations,
    parameters: chemistry.ReactionParameters,
    diagnostic_output: []f64,
) void {
    if (!diagnostic_control.isEnabled()) return;
    scratch.unpackCell(0, current) catch return;
    const coefficients =
        scratch.activityCoefficients(0, parameters.fractions) catch return;
    group_numerics.transformedVector(
        scratch,
        current,
        transformations,
        coefficients.monovalent_activity_coefficient,
        parameters.water_activity_product_mol2_per_m6,
        1,
        diagnostic_output,
    ) catch |err| {
        std.log.warn("SOLUTE full reaction step rejected by {s}", .{@errorName(err)});
        if (err == error.NegativeAqueousState) {
            const changes =
                chemistry.State.assembledAqueousChanges(
                    transformations,
                    scratch.cation_exchange_mol_per_megagram[0],
                ) catch
                    return;
            const aqueous = scratch.aqueous[0];
            inline for (@typeInfo(aqueous_network.State).@"struct".fields, 0..) |field, index| {
                const value = @field(aqueous, field.name);
                const change = @field(changes, field.name);
                if (value + change < 0)
                    std.log.warn(
                        "SOLUTE rejected aqueous component: index={d} name={s} value={e} change={e} maximum_fraction={e}",
                        .{
                            index,
                            field.name,
                            value,
                            change,
                            value / -change,
                        },
                    );
            }
        }
    };
}

fn logLimitingInventory(
    state_values: []const f64,
    accepted_changes: []const f64,
    accepted_fraction: f64,
) void {
    if (!diagnostic_control.isEnabled()) return;
    if (!std.math.isFinite(accepted_fraction) or accepted_fraction <= 0)
        return;
    var limiting_index: ?usize = null;
    var limiting_fraction = std.math.inf(f64);
    for (state_values, accepted_changes, 0..) |value, accepted_change, index| {
        const raw_change = accepted_change / accepted_fraction;
        if (raw_change >= 0) continue;
        const fraction = value / -raw_change;
        if (fraction < limiting_fraction) {
            limiting_fraction = fraction;
            limiting_index = index;
        }
    }
    if (limiting_index) |index|
        std.log.warn(
            "SOLUTE active-set limit: packed_component={d} value={e} raw_change={e} maximum_fraction={e} accepted_fraction={e}",
            .{
                index,
                state_values[index],
                accepted_changes[index] / accepted_fraction,
                limiting_fraction,
                accepted_fraction,
            },
        );
}

pub fn logLargestResidual(
    state_values: []const f64,
    residual: []const f64,
    options: group_types.Options,
) void {
    if (!diagnostic_control.isEnabled()) return;
    var largest_index: usize = 0;
    var largest_scaled: f64 = 0;
    for (state_values, residual, 0..) |value, change, index| {
        const scale = options.absoluteToleranceForPackedComponent(index) +
            options.relative_tolerance * @abs(value);
        const scaled_value = @abs(change) / scale;
        if (scaled_value > largest_scaled) {
            largest_index = index;
            largest_scaled = scaled_value;
        }
    }
    std.log.debug(
        "SOLUTE largest residual: packed_component={d} name={s} value={e} change={e} scaled={e}",
        .{
            largest_index,
            chemistry.State.packedComponentName(largest_index) orelse
                "unknown",
            state_values[largest_index],
            residual[largest_index],
            largest_scaled,
        },
    );
}

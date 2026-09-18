//! `reaction_solver` declarations: tests.
//!
//! Split out of `reaction_solver.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const numerics = @import("../../core/numerics.zig");
const chemistry = @import("chemistry_state.zig");
const aqueous_network = @import("aqueous_network.zig");
const phosphate_network = @import("phosphate_network.zig");
const cation_exchange = @import("cation_exchange.zig");
const geochemistry = @import("geochemistry_network.zig");
const aqueous_rates = @import("aqueous_reaction_rates.zig");
const phosphate_rates = @import("phosphate_reaction_rates.zig");
const geochemistry_rates = @import("geochemistry_reaction_rates.zig");
const water_equilibrium = @import("water_equilibrium.zig");
const reaction_span = @import("conservative_reaction_span.zig");
const group_apply = @import("reaction_solver_apply.zig");
const group_candidates = @import("reaction_solver_candidates.zig");
const group_complementarity = @import("reaction_solver_complementarity.zig");
const group_diagnostics = @import("reaction_solver_diagnostics.zig");
const group_evaluate = @import("reaction_solver_evaluate.zig");
const group_numerics = @import("reaction_solver_numerics.zig");
const group_numerics2 = @import("reaction_solver_numerics2.zig");
const group_network = @import("reaction_try_network.zig");
const group_phosphate = @import("reaction_solver_phosphate.zig");
const group_reaction_span = @import("reaction_solver_reaction_span.zig");
const group_solve = @import("reaction_solver_solve.zig");
const group_types = @import("reaction_solver_types.zig");
const diagnostic_control = @import("reaction_diagnostic_control.zig");
const failure_snapshot = @import("failure_snapshot.zig");

test {
    _ = @import("reaction_solve.zig");
}

test "reaction Jacobian differentiates concentration dependent residual scaling" {
    const options: group_types.Options = .{ .absolute_tolerance_mol_per_m3 = 0.25, .relative_tolerance = 0.75 };
    // A substrate-capped reaction F(x)=0.5*x has scaled secant derivative
    // 0.5*a / ((a+r*x0)*(a+r*x1)), rather than 0.5/(a+r*x0).
    const actual = group_numerics.scaledResidualDifference(2, 1, 3, 1.5, 0, options);
    const expected = 0.5 * 0.25 / (1.75 * 2.5);
    try std.testing.expectApproxEqAbs(@as(f64, expected), actual, 8 * std.math.floatEps(f64));
    try std.testing.expect(@abs(actual - 0.5 / 1.75) > 0.2);
    try std.testing.expectEqual(-actual, group_numerics.scaledResidualDifference(3, 1.5, 2, 1, 0, options));
    var absolute_only = options;
    absolute_only.relative_tolerance = 0;
    try std.testing.expectEqual(@as(f64, 2), group_numerics.scaledResidualDifference(2, 1, 3, 1.5, 0, absolute_only));
}

test "current-side reaction scaling preserves a trace donor and both physical bounds" {
    const negative: f64 = 1;
    const positive: f64 = 1e-20;
    const scale = group_network.currentSideExtentScale(1, negative, positive);
    const normalized_lower = -negative / scale;
    const normalized_upper = positive / scale;
    try std.testing.expectEqual(@as(f64, 1), normalized_upper);
    try std.testing.expectApproxEqRel(-negative, normalized_lower * scale, 4 * std.math.floatEps(f64));
    try std.testing.expectEqual(positive, normalized_upper * scale);
    const probe = @min(std.math.sqrt(std.math.floatEps(f64)), 0.125 * normalized_upper);
    try std.testing.expect(probe > 64 * std.math.floatEps(f64));
    // The old widest-side scale discarded this representable native probe.
    try std.testing.expect(0.125 * positive / negative < 64 * std.math.floatEps(f64));
    try std.testing.expect(positive - probe * scale < positive);
    // Reversing the direction or using a zero-rate face keeps full boxes.
    try std.testing.expectEqual(negative, group_network.currentSideExtentScale(-1, negative, positive));
    try std.testing.expectEqual(negative, group_network.currentSideExtentScale(0, negative, positive));
    try std.testing.expectEqual(negative, group_network.currentSideExtentScale(1, negative, 0));
    try std.testing.expect(std.math.isFinite(group_network.currentSideExtentScale(1, 1e300, 1e-300)));
}

test "chemical quality rejects pH movement and dissolved errors hidden by solids" {
    const physical = @import("reaction_physical_quality.zig");
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    const parameters = acceptedStateConservationTestParameters();
    state.aqueous[0].hydrogen = 1;
    state.aqueous[0].hydroxide = 1;
    state.aqueous[0].calcium = 1;
    state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 0.001;
    state.water_mol_per_m3[0] = 100;
    var residual = [_]f64{0} ** chemistry.State.packedComponentCount();
    residual[group_numerics2.aqueousPackedIndex("hydrogen")] = 0.1;
    const acidity = try physical.measure(&state, parameters, &residual, .{});
    try std.testing.expectApproxEqAbs(@log(@as(f64, 1.1)) / @log(@as(f64, 10)), acidity.pH_change, 1e-14);
    try std.testing.expect(acidity.maximum > 4);
    @memset(&residual, 0);
    residual[group_numerics2.aqueousPackedIndex("calcium_hydroxide")] = 0.01;
    const mobile_only = try physical.measure(&state, parameters, &residual, .{});
    try std.testing.expect(mobile_only.maximum > 90);
    state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 1e15;
    const with_solid = try physical.measure(&state, parameters, &residual, .{});
    try std.testing.expectEqual(mobile_only.maximum, with_solid.maximum);
    @memset(&residual, 0);
    const phosphate_offset = @typeInfo(aqueous_network.State).@"struct".fields.len;
    residual[phosphate_offset + 1] = 1e-5;
    const dissolved_p = try physical.measure(&state, parameters, &residual, .{});
    try std.testing.expect(dissolved_p.maximum > 90);
    state.non_band_phosphate[0].hydroxyapatite_solid_mol_per_m3 = 1e12;
    state.non_band_phosphate[0].adsorbed_h2po4_mol_p_per_megagram = 1e12;
    try std.testing.expectEqual(dissolved_p.maximum, (try physical.measure(&state, parameters, &residual, .{})).maximum);
    @memset(&residual, 0);
    state.aqueous[0].calcium = 0;
    residual[group_numerics2.aqueousPackedIndex("calcium")] = 1;
    const newly_supplied = try physical.measure(&state, parameters, &residual, .{});
    try std.testing.expect(std.math.isFinite(newly_supplied.maximum));
    try std.testing.expect(newly_supplied.maximum > 1);
}

test "chemical quality accepts a small physical change independently of numerical precision" {
    const encoded = @embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    captured.state.aqueous[0] = std.mem.zeroes(aqueous_network.State);
    captured.state.aqueous[0].ammonium_non_band = 1;
    captured.state.aqueous[0].ammonia_non_band = 1e-5;
    captured.state.aqueous[0].hydrogen = 1e-3;
    captured.state.aqueous[0].hydroxide = 1e-5;
    captured.state.non_band_phosphate[0] = std.mem.zeroes(phosphate_network.State);
    captured.state.band_phosphate[0] = std.mem.zeroes(phosphate_network.State);
    captured.state.cation_exchange_mol_per_megagram[0] = std.mem.zeroes(cation_exchange.Cations);
    captured.state.geochemistry_solids[0] = std.mem.zeroes(geochemistry.SolidState);
    captured.state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 0;
    captured.state.water_mol_per_m3[0] = 100;
    var parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    parameters.aqueous_kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0, .maximum_fast_association_mol_per_m3_step = 1, .maximum_slow_association_mol_per_m3_step = 0 };
    parameters.aqueous_constants.ammonium = 1e-30;
    parameters.phosphate_surface.maximum_exchange_mol_per_megagram_step = 0;
    parameters.phosphate_kinetics.maximum_pairing_mol_per_m3_step = 0;
    parameters.phosphate_minerals = null;
    parameters.cation_exchange_parameters.maximum_adsorption_mol_charge_per_m3_step = 0;
    parameters.carboxyl_exchange_parameters.maximum_exchange_mol_per_m3_per_iteration = 0;
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var original: [chemistry.State.packedComponentCount()]f64 = undefined;
    var accepted: [chemistry.State.packedComponentCount()]f64 = undefined;
    try captured.state.packCell(0, &original);
    const strict: group_types.Options = .{ .absolute_tolerance_mol_per_m3 = 1e-30, .absolute_tolerance_mol_per_megagram = 1e-30, .relative_tolerance = 1e-15, .max_iterations = 1 };
    try group_evaluate.evaluateGlobalResidualAt(&workspace.scratch, &original, parameters, workspace.residual);
    try std.testing.expect(try group_numerics.scaledNorm(&original, workspace.residual, strict) > 1e6);
    const quality = try @import("reaction_physical_quality.zig").measure(&workspace.scratch, parameters, workspace.residual, .{});
    try std.testing.expect(quality.pH_change < 0.01);
    try std.testing.expect(quality.maximum < 1);
    const result = try group_solve.solveCellWithWorkspace(&workspace, &captured.state, 0, parameters, strict);
    try std.testing.expect(result.converged);
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
    try group_solve.requireAcceptedStateConservation(&workspace.scratch, &captured.state, 0, &original, parameters);
    try captured.state.packCell(0, &accepted);
    try captured.state.unpackCell(0, &original);
    var loose = strict;
    loose.absolute_tolerance_mol_per_m3 = 1;
    loose.absolute_tolerance_mol_per_megagram = 1;
    loose.relative_tolerance = 1;
    const loose_result = try group_solve.solveCellWithWorkspace(&workspace, &captured.state, 0, parameters, loose);
    try std.testing.expectEqualDeep(result, loose_result);
    try captured.state.packCell(0, workspace.current);
    try std.testing.expectEqualSlices(f64, &accepted, workspace.current);
}

test "recovery KKT preserves descending faces across equation and coordinate units" {
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    for ([_]f64{ 1e-200, 1, 1e150 }) |residual_scale| {
        for ([_]f64{ 1e-200, 1, 1e150 }) |negative_scale| {
            for ([_]f64{ 1e-200, 1, 1e150 }) |positive_scale| {
                workspace.reaction_span_projected_rhs[0] = residual_scale;
                // Both one-sided derivatives descend away from the pin.
                const negative = [_]f64{negative_scale};
                const positive = [_]f64{-positive_scale};
                try std.testing.expect(!group_network.pinnedCorrectionColumnKktSatisfied(&workspace, &negative, &positive, 1, 1, 0, residual_scale));
                try std.testing.expectApproxEqAbs(@as(f64, 1), group_network.pinnedCorrectionColumnNormalizedViolation(&workspace, &negative, &positive, 1, 1, 0, residual_scale), 8 * std.math.floatEps(f64));
                // Reversing both derivatives gives a true constrained minimum.
                const rising_negative = [_]f64{-negative_scale};
                const rising_positive = [_]f64{positive_scale};
                // A descending side remains available even when the opposite,
                // rising derivative is many orders of magnitude larger.
                try std.testing.expect(!group_network.pinnedCorrectionColumnKktSatisfied(&workspace, &negative, &rising_positive, 1, 1, 0, residual_scale));
                try std.testing.expect(!group_network.pinnedCorrectionColumnKktSatisfied(&workspace, &rising_negative, &positive, 1, 1, 0, residual_scale));
                try std.testing.expect(group_network.pinnedCorrectionColumnKktSatisfied(&workspace, &rising_negative, &rising_positive, 1, 1, 0, residual_scale));
                try std.testing.expectEqual(@as(f64, 0), group_network.pinnedCorrectionColumnNormalizedViolation(&workspace, &rising_negative, &rising_positive, 1, 1, 0, residual_scale));
            }
        }
    }
}

test "coordinate Anderson rebuilds amplified extents without a proton charge leak" {
    const encoded = @embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    const parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    // Little-endian packed f64 anchor captured immediately before the rejected
    // coordinate-Anderson step; controls remain those of the original snapshot.
    const anchor_encoded = @embedFile("testdata/calcium_coordinate_anderson_charge_anchor.b64");
    var anchor_bytes: [chemistry.State.packedComponentCount() * 8]u8 = undefined;
    try std.testing.expectEqual(anchor_bytes.len, try decoder.decode(&anchor_bytes, anchor_encoded));
    var anchor: [chemistry.State.packedComponentCount()]f64 = undefined;
    var target: [chemistry.State.packedComponentCount()]f64 = undefined;
    for (&anchor, 0..) |*value, index| value.* = @bitCast(std.mem.readInt(u64, anchor_bytes[index * 8 ..][0..8], .little));
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var guard = try chemistry.State.init(std.testing.allocator, 1);
    defer guard.deinit();
    const reference = reaction_span.zeroTransformations(parameters);
    const hydrogen = group_numerics2.aqueousPackedIndex("hydrogen");
    const hydroxide = group_numerics2.aqueousPackedIndex("hydroxide");
    const aluminum = group_numerics2.aqueousPackedIndex("aluminum");
    for ([_]f64{ 1e5, 1e12 }) |amplification| {
        for ([_]f64{ -0.8340542851721495, 0.8340542851721495 }) |extent| {
            try std.testing.expect(try group_network.conservativeCoordinateAndersonTarget(&scratch, &anchor, reference, parameters, reaction_span.non_band_phosphate_mineral_offset, extent / amplification, 1 - amplification, &target));
            try group_solve.requireAcceptedStateConservation(&guard, &scratch, 0, &anchor, parameters);
            // This combined Al+PO4 coordinate has zero net H-minus-OH source.
            // Separate concentration extrapolation leaked 8.258e-9 here.
            const roundoff = 128 * std.math.floatEps(f64) * @abs(extent);
            try std.testing.expectApproxEqAbs(anchor[hydrogen] - anchor[hydroxide], target[hydrogen] - target[hydroxide], roundoff);
            try std.testing.expectApproxEqAbs(anchor[aluminum] - extent, target[aluminum], roundoff);
        }
    }
}

test "phosphate source assembly preserves a small transfer through a circulating surface flux" {
    var state = group_numerics2.filled(phosphate_network.State, 1);
    const before = state;
    const transfer: f64 = 1e-5;
    const transformations = try phosphate_network.assemble(.{
        .minerals = std.mem.zeroes(phosphate_network.MineralFluxes),
        .aqueous = std.mem.zeroes(phosphate_network.DissociationAndPairingFluxes),
        .surface = .{
            .protonated_to_hydroxyl_site_mol_per_megagram = 0.1,
            .hydroxyl_to_deprotonated_site_mol_per_megagram = transfer,
            .h2po4_with_protonated_site_mol_p_per_megagram = 0.1,
            .h2po4_with_hydroxyl_site_mol_p_per_megagram = -0.1,
            .hpo4_with_hydroxyl_site_mol_p_per_megagram = 0,
        },
        .soil_mass_per_water_volume_megagrams_per_m3 = 1,
    });
    // The three 0.1 fluxes form a stationary source cycle. The only net
    // site transfer is deprotonated -> hydroxyl; it must survive assembly.
    const realized = try phosphate_network.state_updateRealized(&state, transformations, 1);
    try std.testing.expectApproxEqAbs(transfer, realized.hydroxyl_site_mol_per_megagram, 8 * std.math.floatEps(f64));
    try std.testing.expectEqual(-realized.hydroxyl_site_mol_per_megagram, realized.deprotonated_site_mol_per_megagram);
    try std.testing.expectEqual(before.protonated_site_mol_per_megagram, state.protonated_site_mol_per_megagram);
    try std.testing.expectEqual(before.adsorbed_h2po4_mol_p_per_megagram, state.adsorbed_h2po4_mol_p_per_megagram);
    try std.testing.expectEqual(before.dissolved_h2po4_mol_p_per_m3, state.dissolved_h2po4_mol_p_per_m3);
}

test "reaction extent significance respects its donor side and coordinate units" {
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    for ([_]f64{ 1e-30, 1, 1e30 }) |units| {
        for ([_]f64{ -1, 1 }) |direction| {
            workspace.reaction_span_lower_bounds[0] = -units * (if (direction < 0) @as(f64, 1) else 1e20);
            workspace.reaction_span_upper_bounds[0] = units * (if (direction > 0) @as(f64, 1) else 1e20);
            // Half of the current-side inventory is significant regardless
            // of how much material is available for the reverse reaction.
            try std.testing.expect(group_reaction_span.reactionSpanExtentIsSignificant(&workspace, 0, direction * 0.5 * units));
            try std.testing.expect(!group_reaction_span.reactionSpanExtentIsSignificant(&workspace, 0, 0));
            try std.testing.expect(!group_reaction_span.reactionSpanExtentIsSignificant(&workspace, 0, direction * 32 * std.math.floatEps(f64) * units));
            workspace.reaction_span_active_reactions[0] = 0;
            workspace.reaction_span_rates[0] = -direction;
            workspace.reaction_span_solution[0] = direction * 0.5 * units;
            try std.testing.expectEqual(@as(usize, 1), group_reaction_span.reactionSpanDerivativeSideMismatchCount(&workspace, 1, &.{}, 0, null));
        }
    }
}

test "bounded reaction KKT releases the same face after equation rescaling" {
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    // Unconstrained x=(2,-3). Clamping x0 first temporarily puts it on its
    // upper face; after x1 reaches zero, x0 must be released to x0=0.05.
    // Multiplying every equation by a common unit scale leaves that optimum.
    const b1 = @sqrt(@as(f64, 1) - 0.65 * 0.65);
    for ([_]f64{ 1, 1e-5, 1e-200, 1e150 }) |scale| {
        for ([_]f64{ 1, 1e-10, 1e10 }) |coordinate_scale| {
            @memcpy(workspace.reaction_span_jacobian[0..4], &[_]f64{ scale * coordinate_scale, 0.65 * scale, 0, b1 * scale });
            @memcpy(workspace.reaction_span_rhs[0..2], &[_]f64{ (2 - 3 * @as(f64, 0.65)) * scale, -3 * b1 * scale });
            @memcpy(workspace.reaction_span_lower_bounds[0..2], &[_]f64{ 0, 0 });
            @memcpy(workspace.reaction_span_upper_bounds[0..2], &[_]f64{ 0.1 / coordinate_scale, 10 });
            try std.testing.expect(@import("reaction_solve.zig").solveBoundedReactionSpan(&workspace, 2, 2));
            try std.testing.expectApproxEqAbs(@as(f64, 0.05), workspace.reaction_span_solution[0] * coordinate_scale, 1e-12);
            try std.testing.expectEqual(@as(f64, 0), workspace.reaction_span_solution[1]);
            try std.testing.expect(@import("reaction_solve.zig").reactionSpanProjectedKktSatisfied(&workspace, 2, 2));
            workspace.reaction_span_solution[0] = 0.1 / coordinate_scale;
            try std.testing.expect(!@import("reaction_solve.zig").reactionSpanProjectedKktSatisfied(&workspace, 2, 2));
        }
    }
}

fn acceptedStateConservationTestParameters() chemistry.ReactionParameters {
    var result = std.mem.zeroes(chemistry.ReactionParameters);
    result.fractions = .{
        .ammonium_non_band = 0.75,
        .ammonium_band = 0.25,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.7,
        .phosphate_band = 0.3,
    };
    result.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 2;
    result.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 3;
    result.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1.5,
        .ammonium_non_band_megagrams_per_m3 = 1.5,
        .ammonium_band_megagrams_per_m3 = 1.5,
    };
    result.total_carboxyl_sites_mol_per_megagram = 1;
    return result;
}

test "current-side reaction scaling probes trace ammonia through production Jacobian" {
    const encoded = @embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    var parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    parameters.aqueous_kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0, .maximum_fast_association_mol_per_m3_step = 1, .maximum_slow_association_mol_per_m3_step = 0 };
    parameters.aqueous_constants.ammonium = 1e-30;
    parameters.phosphate_surface.maximum_exchange_mol_per_megagram_step = 0;
    parameters.phosphate_kinetics.maximum_pairing_mol_per_m3_step = 0;
    parameters.phosphate_minerals = null;
    parameters.cation_exchange_parameters.maximum_adsorption_mol_charge_per_m3_step = 0;
    parameters.carboxyl_exchange_parameters.maximum_exchange_mol_per_m3_per_iteration = 0;
    parameters.geochemistry_kinetics.maximum_hydroxide_mineral_mol_per_m3_step = 0;
    parameters.geochemistry_kinetics.maximum_general_mineral_mol_per_m3_step = 0;
    parameters.geochemistry_kinetics.maximum_natural_weathering_mol_per_m3_step = 0;
    parameters.geochemistry_kinetics.maximum_ground_weathering_mol_per_m3_step = 0;
    captured.state.aqueous[0] = std.mem.zeroes(aqueous_network.State);
    captured.state.aqueous[0].hydrogen = 1;
    captured.state.aqueous[0].hydroxide = parameters.water_activity_product_mol2_per_m6;
    captured.state.aqueous[0].ammonium_non_band = 1;
    captured.state.aqueous[0].ammonia_non_band = 1e-20;
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    try captured.state.packCell(0, workspace.current);
    _ = try group_evaluate.evaluateAt(&workspace.scratch, workspace.current, parameters);
    try workspace.scratch.packCell(0, workspace.current);
    const changes_carrier = try group_evaluate.evaluateAtLoaded(&workspace.scratch, workspace.current, parameters);
    const changes = changes_carrier.transformations;
    _ = try group_evaluate.evaluateLoadedReactionBalance(&workspace.scratch, changes_carrier, parameters, workspace.residual);
    const coefficients = try workspace.scratch.activityCoefficients(0, parameters.fractions);
    try @import("reaction_search_span.zig").evaluateRates(&workspace.scratch, 0, parameters, workspace.reaction_span_rates);
    var references: [chemistry.State.packedComponentCount()]f64 = undefined;
    @memcpy(&references, workspace.current);
    const options: group_types.Options = .{ .absolute_tolerance_mol_per_m3 = 1e-30, .search_reference_concentrations = &references };
    const count = try group_network.initializeFullNetworkReactionAxes(&workspace, &workspace.scratch, workspace.current, changes, workspace.candidate_state, parameters, options, coefficients.monovalent_activity_coefficient);
    const reaction = std.meta.fieldIndex(aqueous_network.Fluxes, "ammonium_non_band_association").?;
    const column = std.mem.indexOfScalar(usize, workspace.reaction_span_active_reactions[0..count], reaction).?;
    const norm = try group_numerics.scaledNorm(workspace.current, workspace.residual, options);
    const inputs: group_complementarity.ComplementaritySearchInputs = .{
        .scratch = &workspace.scratch,
        .current = workspace.current,
        .global_residual = workspace.residual,
        .probe_state = workspace.probe_state,
        .probe_residual = workspace.probe_residual,
        .current_transformations = changes,
        .parameters = parameters,
        .options = options,
        .current_norm = norm,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .column_count = count,
    };
    try group_reaction_span.evaluateReactionSpanDerivativeColumn(inputs, &workspace, column, 1, workspace.reaction_span_jacobian);
    const ammonia = group_numerics2.aqueousPackedIndex("ammonia_non_band");
    const expected = 0.2 * workspace.reaction_span_extent_scales[column] / group_numerics.residualScale(workspace.current[ammonia], ammonia, options);
    try std.testing.expectApproxEqRel(expected, workspace.reaction_span_jacobian[ammonia * count + column], 1e-6);
    try std.testing.expect(workspace.probe_state[ammonia] < workspace.current[ammonia]);
    // Recreate the old coordinate scale: the same physical side disappears.
    workspace.reaction_span_extent_scales[column] = 1;
    workspace.reaction_span_upper_bounds[column] = 1e-20;
    try std.testing.expectError(error.NoAdmissibleComplementarityProbe, group_reaction_span.evaluateReactionSpanDerivativeColumn(inputs, &workspace, column, 1, workspace.reaction_span_jacobian));
}

test "best bounded chemistry iterate rejects a better score with an element or charge leak" {
    var entry = try chemistry.State.init(std.testing.allocator, 1);
    defer entry.deinit();
    entry.water_mol_per_m3[0] = 100;
    entry.aqueous[0].aluminum = 2;
    entry.aqueous[0].iron = 2;
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const parameters = acceptedStateConservationTestParameters();
    const retain = @import("reaction_solve.zig").retainBestBoundedIterate;
    try entry.packCell(0, workspace.current);
    @memset(workspace.residual, 0);
    workspace.residual[0] = 10;
    try std.testing.expect(try retain(&workspace, &entry, 0, parameters, 10, 0));
    workspace.residual[0] = 8;
    workspace.last_selected_candidate = .anderson_depth_one;
    try std.testing.expect(try retain(&workspace, &entry, 0, parameters, 8, 1));
    workspace.residual[0] = 9;
    try std.testing.expect(!try retain(&workspace, &entry, 0, parameters, 9, 2));
    try std.testing.expectEqual(@as(f64, 8), workspace.best_bounded_residual[0]);
    const aluminum = group_numerics2.aqueousPackedIndex("aluminum");
    const iron = group_numerics2.aqueousPackedIndex("iron");
    workspace.current[aluminum] += 0.25;
    workspace.current[iron] -= 0.25;
    try std.testing.expectError(error.SoluteReactionAcceptedStateConservationFailure, retain(&workspace, &entry, 0, parameters, 1, 3));
    try std.testing.expectEqual(@as(f64, 2), workspace.best_bounded_state[aluminum]);
    try std.testing.expectEqual(@as(f64, 2), workspace.best_bounded_state[iron]);
    try std.testing.expectEqual(@as(f64, 8), workspace.best_bounded_maximum);
    try std.testing.expectEqual(@as(?u16, 1), workspace.best_bounded_iteration);
    try std.testing.expectEqual(group_types.CandidateKind.anderson_depth_one, workspace.best_bounded_kind);
    // A proton leak preserves every tracked element/site inventory, but must
    // not replace the retained state even when its search score is better.
    try entry.packCell(0, workspace.current);
    workspace.current[group_numerics2.aqueousPackedIndex("hydrogen")] += 0.25;
    {
        var suppression = diagnostic_control.suppress();
        defer suppression.restore();
        try std.testing.expectError(error.SoluteReactionAcceptedStateConservationFailure, retain(&workspace, &entry, 0, parameters, 1, 4));
    }
    try std.testing.expectEqual(@as(f64, 0), workspace.best_bounded_state[group_numerics2.aqueousPackedIndex("hydrogen")]);
    try std.testing.expectEqual(@as(f64, 8), workspace.best_bounded_maximum);
    // A rejected candidate must not touch the authoritative entry either.
    try std.testing.expectEqual(@as(f64, 2), entry.aqueous[0].aluminum);
    try std.testing.expectEqual(@as(f64, 2), entry.aqueous[0].iron);
    entry.aqueous[0].aluminum = 101;
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    try std.testing.expectError(error.SoluteConcentrationExceedsWaterMolarity, group_solve.solveCellWithWorkspace(&workspace, &entry, 0, parameters, .{}));
    try std.testing.expectEqual(@as(?u16, null), workspace.best_bounded_iteration);
}

fn allocateRetainedChemistryWorkspace(allocator: std.mem.Allocator) !void {
    var workspace = try group_types.Workspace.init(allocator);
    defer workspace.deinit();
    try std.testing.expectEqual(chemistry.State.packedComponentCount(), workspace.best_bounded_state.len);
    try std.testing.expectEqual(workspace.best_bounded_state.len, workspace.best_bounded_residual.len);
}

test "best bounded chemistry workspace releases every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateRetainedChemistryWorkspace, .{});
}

test "physical chemistry progress keeps independent records and inventory units" {
    const progress = @import("reaction_progress.zig");
    for ([_]f64{ 1e-200, 1, 1e200 }) |scale| {
        const quality = try progress.balanceQuality(&.{ 0.0001 * scale, -0.0002 * scale, 0 }, &.{ 2 * scale, 4 * scale, 0 });
        try std.testing.expectApproxEqRel(@as(f64, 0.00005), quality.maximum, 8 * std.math.floatEps(f64));
        try std.testing.expectApproxEqRel(@as(f64, 0.00005 * @sqrt(2.0 / 3.0)), quality.rms, 8 * std.math.floatEps(f64));
    }
    try std.testing.expectEqual(std.math.inf(f64), (try progress.balanceQuality(&.{1}, &.{0})).maximum);
    var monitor: progress.Monitor = .{};
    _ = monitor.observe(100, 10, false);
    _ = monitor.observe(90, 12, false);
    try std.testing.expectEqual(@as(f64, 10), monitor.anchor_rms);
    _ = monitor.observe(90, 11, false);
    try std.testing.expectEqual(@as(u8, 1), monitor.stale_iterations);
    // A new aggregate improvement is useful even when the largest defect
    // increases. Neither record may subsequently move backwards.
    _ = monitor.observe(92, 9, true);
    try std.testing.expectEqual(@as(f64, 90), monitor.anchor_maximum);
    try std.testing.expectEqual(@as(f64, 9), monitor.anchor_rms);
    for (0..3) |_| _ = monitor.observe(90, 10, true);
    try std.testing.expectEqual(progress.Decision.stop, monitor.observe(92, 9, true));
    monitor = .{};
    _ = monitor.observe(1e-100, 1e-101, false);
    _ = monitor.observe(0.5e-100, 0.5e-101, false);
    try std.testing.expectEqual(@as(u8, 0), monitor.stale_iterations);
}

test "physical chemistry progress gives Anderson one useful recovery and stops a plateau" {
    const progress = @import("reaction_progress.zig");
    var monitor: progress.Monitor = .{};
    try std.testing.expectEqual(progress.Decision.proceed, monitor.observe(1000, 100, false));
    for (0..3) |_| try std.testing.expectEqual(progress.Decision.proceed, monitor.observe(1000, 100, false));
    try std.testing.expectEqual(progress.Decision.anderson, monitor.observe(1000, 100, false));
    try std.testing.expectEqual(progress.Decision.stop, monitor.observe(999.99999999, 99.999999999, true));
    monitor = .{};
    _ = monitor.observe(1000, 100, false);
    for (0..4) |_| _ = monitor.observe(1000, 100, false);
    // An actual physical improvement from Anderson restores the work budget.
    try std.testing.expectEqual(progress.Decision.proceed, monitor.observe(900, 90, true));
    try std.testing.expectEqual(@as(u8, 0), monitor.stale_iterations);
    // Other species can improve while the limiting component remains flat.
    try std.testing.expectEqual(progress.Decision.proceed, monitor.observe(900, 80, false));
    try std.testing.expect(progress.repeatsState(&.{ 0, 1, 1e-20 }, &.{ 0, 1, 1e-20 }));
    try std.testing.expect(!progress.repeatsState(&.{ 0, 1, 1e-20 }, &.{ 0, 1, 2e-20 }));
    try std.testing.expect(!progress.repeatsState(&.{std.math.nan(f64)}, &.{std.math.nan(f64)}));
}

fn applyAcceptedStateIndexPoisonForTest(
    scratch: *chemistry.State,
    state: *chemistry.State,
    parameters: chemistry.ReactionParameters,
    first_index: usize,
    first_change: f64,
    second_index: usize,
    second_change: f64,
) !void {
    const count = comptime chemistry.State.packedComponentCount();
    var original: [count]f64 = undefined;
    try state.packCell(0, &original);
    errdefer state.unpackCell(0, &original) catch
        @panic("valid accepted-state conservation test rollback failed");
    var poisoned = original;
    poisoned[first_index] += first_change;
    poisoned[second_index] += second_change;
    try state.unpackCell(0, &poisoned);
    try group_solve.requireAcceptedStateConservation(
        scratch,
        state,
        0,
        &original,
        parameters,
    );
}

fn applyAcceptedStateFourIndexPoisonForTest(
    scratch: *chemistry.State,
    state: *chemistry.State,
    parameters: chemistry.ReactionParameters,
    indices: [4]usize,
    changes: [4]f64,
) !void {
    const count = comptime chemistry.State.packedComponentCount();
    var original: [count]f64 = undefined;
    try state.packCell(0, &original);
    errdefer state.unpackCell(0, &original) catch
        @panic("valid accepted-state conservation test rollback failed");
    var poisoned = original;
    for (indices, changes) |index, change| poisoned[index] += change;
    try state.unpackCell(0, &poisoned);
    try group_solve.requireAcceptedStateConservation(
        scratch,
        state,
        0,
        &original,
        parameters,
    );
}

test "accepted-state charge gate rejects a proton leak and rolls back" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.aqueous[0].hydrogen = 1;
    state.aqueous[0].hydroxide = 1;
    try std.testing.expectError(error.SoluteReactionAcceptedStateConservationFailure, applyAcceptedStateIndexPoisonForTest(&scratch, &state, acceptedStateConservationTestParameters(), group_numerics2.aqueousPackedIndex("hydrogen"), 0.25, group_numerics2.aqueousPackedIndex("hydroxide"), 0));
    try std.testing.expectEqual(@as(f64, 1), state.aqueous[0].hydrogen);
    try std.testing.expectEqual(@as(f64, 1), state.aqueous[0].hydroxide);
}

test "accepted-state charge gate closes every native reaction axis" {
    const charge = @import("reaction_charge.zig");
    var entry = try chemistry.State.init(std.testing.allocator, 1);
    defer entry.deinit();
    var candidate = try chemistry.State.init(std.testing.allocator, 1);
    defer candidate.deinit();
    entry.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    entry.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    entry.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    entry.cation_exchange_mol_per_megagram[0] = group_numerics2.filled(cation_exchange.Cations, 1);
    entry.geochemistry_solids[0] = group_numerics2.filled(geochemistry.SolidState, 1);
    entry.carboxyl_bound_hydrogen_mol_per_megagram[0] = 0.5;
    entry.water_mol_per_m3[0] = 55500;
    var parameters = acceptedStateConservationTestParameters();
    parameters.cation_exchange_water_ratios.ammonium_non_band_megagrams_per_m3 = 2.1;
    parameters.cation_exchange_water_ratios.ammonium_band_megagrams_per_m3 = 3.4;
    const before = try charge.inventory(&entry, 0, parameters);
    var original: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output: [chemistry.State.packedComponentCount()]f64 = undefined;
    try entry.packCell(0, &original);
    for (0..reaction_span.reaction_count) |column| {
        for ([_]f64{ -0.001, 0.001 }) |extent| {
            var changes = reaction_span.zeroTransformations(parameters);
            try reaction_span.addReactionExtent(&changes, column, extent, changes, parameters);
            try group_numerics.transformedVector(&candidate, &original, changes, 1, 1, 1, &output);
            const after = try charge.inventory(&candidate, 0, parameters);
            charge.requireConserved(before, after) catch |err| {
                std.debug.print("charge axis failed: {s}, extent={e}\n", .{ reaction_span.reactionIdentity(column).?.name, extent });
                return err;
            };
        }
    }
}

test "accepted-state charge gate detects element-neutral speciation and site leaks" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 0.5;
    const aqueous_count = std.meta.fields(aqueous_network.State).len;
    const phosphate_count = std.meta.fields(phosphate_network.State).len;
    const carboxyl = aqueous_count + 2 * phosphate_count + std.meta.fields(cation_exchange.Cations).len;
    const pairs = [_][2]usize{
        .{ group_numerics2.aqueousPackedIndex("aluminum"), group_numerics2.aqueousPackedIndex("aluminum_hydroxide_2") },
        .{ aqueous_count + std.meta.fieldIndex(phosphate_network.State, "dissolved_hpo4_mol_p_per_m3").?, aqueous_count + std.meta.fieldIndex(phosphate_network.State, "dissolved_h2po4_mol_p_per_m3").? },
        .{ aqueous_count + std.meta.fieldIndex(phosphate_network.State, "protonated_site_mol_per_megagram").?, aqueous_count + std.meta.fieldIndex(phosphate_network.State, "hydroxyl_site_mol_per_megagram").? },
        .{ carboxyl, group_numerics2.aqueousPackedIndex("hydrogen") },
    };
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    for (pairs, 0..) |pair, index| {
        try std.testing.expectError(error.SoluteReactionAcceptedStateConservationFailure, applyAcceptedStateIndexPoisonForTest(&scratch, &state, acceptedStateConservationTestParameters(), pair[0], 0.1, pair[1], if (index == 3) 0 else -0.1));
    }
}

test "accepted-state charge gate uses gross charge for rounding and preserves nonzero background" {
    const charge = @import("reaction_charge.zig");
    const before: charge.Inventory = .{ .positive_mol_charge_per_m3 = 1e6, .negative_mol_charge_per_m3 = 1e6 };
    try charge.requireConserved(before, .{ .positive_mol_charge_per_m3 = 1e6 + 1e-10, .negative_mol_charge_per_m3 = 1e6 });
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    try std.testing.expectError(error.SoluteReactionAcceptedStateConservationFailure, charge.requireConserved(before, .{ .positive_mol_charge_per_m3 = 1e6 + 0.001, .negative_mol_charge_per_m3 = 1e6 }));
    try charge.requireConserved(.{ .positive_mol_charge_per_m3 = 2, .negative_mol_charge_per_m3 = 1 }, .{ .positive_mol_charge_per_m3 = 2.25, .negative_mol_charge_per_m3 = 1.25 });
}

test "accepted-state element gate rejects cross-element cancellation and rolls back" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.aqueous[0].aluminum = 2;
    state.aqueous[0].iron = 2;
    const count = comptime chemistry.State.packedComponentCount();
    var original: [count]f64 = undefined;
    try state.packCell(0, &original);
    const aluminum_index = std.meta.fieldIndex(aqueous_network.State, "aluminum").?;
    const iron_index = std.meta.fieldIndex(aqueous_network.State, "iron").?;
    try std.testing.expectError(
        error.SoluteReactionAcceptedStateConservationFailure,
        applyAcceptedStateIndexPoisonForTest(
            &scratch,
            &state,
            acceptedStateConservationTestParameters(),
            aluminum_index,
            0.25,
            iron_index,
            -0.25,
        ),
    );
    var after: [count]f64 = undefined;
    try state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &original, &after);
}

test "accepted-state site gate rejects opposing phosphate-zone poison and rolls back" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.non_band_phosphate[0].deprotonated_site_mol_per_megagram = 1;
    state.band_phosphate[0].deprotonated_site_mol_per_megagram = 1;
    const count = comptime chemistry.State.packedComponentCount();
    var original: [count]f64 = undefined;
    try state.packCell(0, &original);
    const aqueous_count = @typeInfo(aqueous_network.State).@"struct".fields.len;
    const phosphate_count = @typeInfo(phosphate_network.State).@"struct".fields.len;
    const site_index = std.meta.fieldIndex(
        phosphate_network.State,
        "deprotonated_site_mol_per_megagram",
    ).?;
    try std.testing.expectError(
        error.SoluteReactionAcceptedStateConservationFailure,
        applyAcceptedStateIndexPoisonForTest(
            &scratch,
            &state,
            acceptedStateConservationTestParameters(),
            aqueous_count + site_index,
            0.25,
            aqueous_count + phosphate_count + site_index,
            -0.25,
        ),
    );
    var after: [count]f64 = undefined;
    try state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &original, &after);
}

test "accepted-state exchanger charge gate rejects element-neutral index poison and rolls back" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.aqueous[0].calcium = 2;
    const count = comptime chemistry.State.packedComponentCount();
    var original: [count]f64 = undefined;
    try state.packCell(0, &original);
    const aqueous_count = @typeInfo(aqueous_network.State).@"struct".fields.len;
    const phosphate_count = @typeInfo(phosphate_network.State).@"struct".fields.len;
    const calcium_aqueous_index =
        std.meta.fieldIndex(aqueous_network.State, "calcium").?;
    const calcium_exchange_index = aqueous_count + 2 * phosphate_count +
        std.meta.fieldIndex(cation_exchange.Cations, "calcium").?;
    // 0.25 mol Mg-1 on the exchanger is exactly 0.375 mol m-3 at the
    // configured 1.5 Mg m-3 ratio, so calcium itself remains conservative.
    // Only the exchanger charge/site invariant is poisoned (+0.5 mol charge
    // Mg-1), proving it cannot hide behind an element census.
    try std.testing.expectError(
        error.SoluteReactionAcceptedStateConservationFailure,
        applyAcceptedStateIndexPoisonForTest(
            &scratch,
            &state,
            acceptedStateConservationTestParameters(),
            calcium_aqueous_index,
            -0.375,
            calcium_exchange_index,
            0.25,
        ),
    );
    var after: [count]f64 = undefined;
    try state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &original, &after);
}

test "accepted-state exchanger gate uses fraction-weighted ammonium site charge" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    const parameters = acceptedStateConservationTestParameters();
    state.aqueous[0].ammonium_non_band = 2;
    state.aqueous[0].calcium = 2;
    state.cation_exchange_mol_per_megagram[0].ammonium_non_band = 1;
    state.cation_exchange_mol_per_megagram[0].calcium = 1;
    const count = comptime chemistry.State.packedComponentCount();
    var original: [count]f64 = undefined;
    try state.packCell(0, &original);

    const extent: f64 = 0.25;
    const ratio = parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
    // This is the former unweighted NH-vs-Ca basis. It preserves both
    // elemental inventories and unweighted exchanger charge, but changes the
    // physical CEC by (f_nonband - 1) * extent.
    const aqueous_count = @typeInfo(aqueous_network.State).@"struct".fields.len;
    const phosphate_count = @typeInfo(phosphate_network.State).@"struct".fields.len;
    const exchange_offset = aqueous_count + 2 * phosphate_count;
    try std.testing.expectError(
        error.SoluteReactionAcceptedStateConservationFailure,
        applyAcceptedStateFourIndexPoisonForTest(
            &scratch,
            &state,
            parameters,
            .{
                exchange_offset + std.meta.fieldIndex(cation_exchange.Cations, "ammonium_non_band").?,
                std.meta.fieldIndex(aqueous_network.State, "ammonium_non_band").?,
                exchange_offset + std.meta.fieldIndex(cation_exchange.Cations, "calcium").?,
                std.meta.fieldIndex(aqueous_network.State, "calcium").?,
            },
            .{ extent, -ratio * extent, -0.5 * extent, ratio * 0.5 * extent },
        ),
    );
    var after: [count]f64 = undefined;
    try state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &original, &after);
}

test "accepted-state element gate permits a stoichiometric mineral transfer" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.aqueous[0].aluminum = 1;
    state.aqueous[0].hydroxide = 1;
    state.geochemistry_solids[0].gibbsite_solid_mol_per_m3 = 1;
    const count = comptime chemistry.State.packedComponentCount();
    var original: [count]f64 = undefined;
    try state.packCell(0, &original);
    state.aqueous[0].aluminum -= 0.25;
    state.aqueous[0].hydroxide -= 3 * 0.25;
    state.geochemistry_solids[0].gibbsite_solid_mol_per_m3 += 0.25;
    try group_solve.requireAcceptedStateConservation(
        &scratch,
        &state,
        0,
        &original,
        acceptedStateConservationTestParameters(),
    );
}

test "accepted-state capacity gate permits repair but rejects remaining overflow" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    const parameters = acceptedStateConservationTestParameters();
    const count = comptime chemistry.State.packedComponentCount();
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1.2;
    var original: [count]f64 = undefined;
    try state.packCell(0, &original);

    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.aqueous[0].hydrogen = 0.2 * parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
    try group_solve.requireAcceptedStateConservation(
        &scratch,
        &state,
        0,
        &original,
        parameters,
    );

    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1.1;
    state.aqueous[0].hydrogen = 0.1 * parameters.cation_exchange_water_ratios.shared_megagrams_per_m3;
    var diagnostic_guard = diagnostic_control.suppress();
    defer diagnostic_guard.restore();
    try std.testing.expectError(
        error.SoluteReactionAcceptedStateConservationFailure,
        group_solve.requireAcceptedStateConservation(
            &scratch,
            &state,
            0,
            &original,
            parameters,
        ),
    );
}

test "entry carboxyl capacity rebase conservatively releases aqueous hydrogen" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var parameters = acceptedStateConservationTestParameters();
    parameters.total_carboxyl_sites_mol_per_megagram = 1;
    parameters.cation_exchange_water_ratios.shared_megagrams_per_m3 = 2;
    state.water_mol_per_m3[0] = 100;
    state.aqueous[0].hydrogen = 0.5;
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1.2;

    try group_solve.rebaseEntryCarboxylCapacity(&state, 0, parameters);
    try std.testing.expectEqual(
        @as(f64, 1),
        state.carboxyl_bound_hydrogen_mol_per_megagram[0],
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.9),
        state.aqueous[0].hydrogen,
        4 * std.math.floatEps(f64),
    );

    const packed_after_rebase = state.carboxyl_bound_hydrogen_mol_per_megagram[0];
    try group_solve.rebaseEntryCarboxylCapacity(&state, 0, parameters);
    try std.testing.expectEqual(
        packed_after_rebase,
        state.carboxyl_bound_hydrogen_mol_per_megagram[0],
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.9),
        state.aqueous[0].hydrogen,
        4 * std.math.floatEps(f64),
    );
}

test "accepted-state gate conserves realized sub-ulp and finite geochemistry transfers" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    const parameters = acceptedStateConservationTestParameters();
    const count = comptime chemistry.State.packedComponentCount();
    var original: [count]f64 = undefined;

    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 10);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 0x1p50);
    try state.packCell(0, &original);
    const sub_ulp = try geochemistry.assemble(
        .{
            .gibbsite_precipitation_mol_per_m3 = 0.01,
            .iron_hydroxide_precipitation_mol_per_m3 = 0.02,
            .calcite_precipitation_mol_per_m3 = 0.03,
            .gypsum_precipitation_mol_per_m3 = 0.04,
        },
        .{
            .aluminum_natural_mol_per_m3 = 1.0e-8,
            .aluminum_ground_mol_per_m3 = 0,
            .iron_natural_mol_per_m3 = 1.0e-8,
            .iron_ground_mol_per_m3 = 0,
            .calcium_natural_mol_per_m3 = 1.0e-8,
            .calcium_ground_mol_per_m3 = 0,
            .magnesium_natural_mol_per_m3 = 1.0e-8,
            .magnesium_ground_mol_per_m3 = 0,
            .sodium_natural_mol_per_m3 = 1.0e-8,
            .sodium_ground_mol_per_m3 = 0,
            .potassium_natural_mol_per_m3 = 1.0e-8,
            .potassium_ground_mol_per_m3 = 0,
        },
    );
    var transaction = reaction_span.zeroTransformations(parameters);
    transaction.geochemistry = sub_ulp;
    try state.state_updateCell(0, transaction);
    try group_solve.requireAcceptedStateConservation(
        &scratch,
        &state,
        0,
        &original,
        parameters,
    );

    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 10);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    try state.packCell(0, &original);
    const finite = try geochemistry.assemble(
        .{
            .gibbsite_precipitation_mol_per_m3 = 0.1,
            .iron_hydroxide_precipitation_mol_per_m3 = -0.02,
            .calcite_precipitation_mol_per_m3 = 0.03,
            .gypsum_precipitation_mol_per_m3 = -0.01,
        },
        .{
            .aluminum_natural_mol_per_m3 = 0.001,
            .aluminum_ground_mol_per_m3 = 0.002,
            .iron_natural_mol_per_m3 = 0.003,
            .iron_ground_mol_per_m3 = 0.004,
            .calcium_natural_mol_per_m3 = 0.005,
            .calcium_ground_mol_per_m3 = 0.006,
            .magnesium_natural_mol_per_m3 = 0.007,
            .magnesium_ground_mol_per_m3 = 0.008,
            .sodium_natural_mol_per_m3 = 0.009,
            .sodium_ground_mol_per_m3 = 0.01,
            .potassium_natural_mol_per_m3 = 0.011,
            .potassium_ground_mol_per_m3 = 0.012,
        },
    );
    transaction.geochemistry = finite;
    try state.state_updateCell(0, transaction);
    try group_solve.requireAcceptedStateConservation(
        &scratch,
        &state,
        0,
        &original,
        parameters,
    );
}

test "Newton RMS globalization crosses a bounded maximum-norm ridge without false convergence" {
    const options: group_types.Options = .{
        .absolute_tolerance_mol_per_m3 = 1,
        .absolute_tolerance_mol_per_megagram = 1,
        .relative_tolerance = 1e-16,
    };
    const current_state = [_]f64{ 0, 0 };
    const current_residual = [_]f64{ 2, 1.5 };
    const candidate_state = [_]f64{ 0, 0 };
    const candidate_residual = [_]f64{ 2.1, 0 };
    const current_maximum = try group_numerics.scaledNorm(
        &current_state,
        &current_residual,
        options,
    );
    const candidate_maximum = try group_numerics.scaledNorm(
        &candidate_state,
        &candidate_residual,
        options,
    );
    const current_merit = try group_candidates.scaledRmsNorm(
        &current_state,
        &current_residual,
        options,
    );
    const candidate_merit = try group_candidates.scaledRmsNorm(
        &candidate_state,
        &candidate_residual,
        options,
    );
    try std.testing.expect(candidate_maximum > current_maximum);
    try std.testing.expect(candidate_merit < current_merit);
    try std.testing.expect(group_candidates.rmsArmijoDecrease(
        current_merit,
        candidate_merit,
        1,
    ));

    var best_state = [_]f64{ 0, 0 };
    var best_residual = [_]f64{ 0, 0 };
    var best_maximum = current_maximum;
    var best_merit = current_merit;
    var best_kind: group_types.CandidateKind = .none;
    var best_is_picard = false;
    try std.testing.expect(try group_solve.retainMeaningfulNewtonCandidate(
        current_maximum,
        current_merit,
        options,
        &best_state,
        &best_residual,
        &best_maximum,
        &best_merit,
        &best_kind,
        &best_is_picard,
        &candidate_state,
        &candidate_residual,
        candidate_maximum,
        .full_network_newton,
    ));
    try std.testing.expectEqual(candidate_maximum, best_maximum);
    try std.testing.expectEqual(candidate_merit, best_merit);
    try std.testing.expectEqual(
        group_types.CandidateKind.full_network_newton,
        best_kind,
    );
    try std.testing.expect(!best_is_picard);

    // Candidate publication is not convergence: the maximum scaled residual
    // remains the sole terminal test and is still above one on this ridge.
    try std.testing.expect(best_maximum > 1);
    try std.testing.expect(!group_candidates.maximumNormGrowthSafeguard(
        current_maximum,
        2.000001 * current_maximum,
    ));
    try std.testing.expect(!group_candidates.maximumNormGrowthSafeguard(
        current_maximum,
        std.math.nan(f64),
    ));
}

test "Newton arbitration prefers maximum-norm descent over a lower-RMS ridge" {
    const options: group_types.Options = .{
        .absolute_tolerance_mol_per_m3 = 1,
        .absolute_tolerance_mol_per_megagram = 1,
        .relative_tolerance = 1e-16,
    };
    const current_state = [_]f64{ 0, 0 };
    const current_residual = [_]f64{ 2, 1.5 };
    const ridge_state = [_]f64{ 0, 0 };
    const ridge_residual = [_]f64{ 2.1, 0 };
    const descending_state = [_]f64{ 0, 0 };
    const descending_residual = [_]f64{ 1.9, 1.1 };
    const stronger_maximum_descent_state = [_]f64{ 0, 0 };
    const stronger_maximum_descent_residual = [_]f64{ 1.8, 1.5 };
    const current_maximum = try group_numerics.scaledNorm(
        &current_state,
        &current_residual,
        options,
    );
    const current_merit = try group_candidates.scaledRmsNorm(
        &current_state,
        &current_residual,
        options,
    );
    const ridge_maximum = try group_numerics.scaledNorm(
        &ridge_state,
        &ridge_residual,
        options,
    );
    const descending_maximum = try group_numerics.scaledNorm(
        &descending_state,
        &descending_residual,
        options,
    );
    const stronger_maximum_descent = try group_numerics.scaledNorm(
        &stronger_maximum_descent_state,
        &stronger_maximum_descent_residual,
        options,
    );
    const ridge_merit = try group_candidates.scaledRmsNorm(
        &ridge_state,
        &ridge_residual,
        options,
    );
    const descending_merit = try group_candidates.scaledRmsNorm(
        &descending_state,
        &descending_residual,
        options,
    );
    const stronger_maximum_descent_merit = try group_candidates.scaledRmsNorm(
        &stronger_maximum_descent_state,
        &stronger_maximum_descent_residual,
        options,
    );
    try std.testing.expect(ridge_maximum > current_maximum);
    try std.testing.expect(descending_maximum < current_maximum);
    try std.testing.expect(ridge_merit < descending_merit);
    try std.testing.expect(descending_merit < current_merit);
    try std.testing.expect(stronger_maximum_descent < descending_maximum);
    try std.testing.expect(stronger_maximum_descent_merit > descending_merit);

    var best_state = [_]f64{ 0, 0 };
    var best_residual = [_]f64{ 0, 0 };
    var best_maximum = current_maximum;
    var best_merit = current_merit;
    var best_kind: group_types.CandidateKind = .none;
    var best_is_picard = false;
    try std.testing.expect(try group_solve.retainMeaningfulNewtonCandidate(
        current_maximum,
        current_merit,
        options,
        &best_state,
        &best_residual,
        &best_maximum,
        &best_merit,
        &best_kind,
        &best_is_picard,
        &ridge_state,
        &ridge_residual,
        ridge_maximum,
        .phosphate_extent_newton,
    ));
    try std.testing.expect(try group_solve.retainMeaningfulNewtonCandidate(
        current_maximum,
        current_merit,
        options,
        &best_state,
        &best_residual,
        &best_maximum,
        &best_merit,
        &best_kind,
        &best_is_picard,
        &descending_state,
        &descending_residual,
        descending_maximum,
        .full_network_newton,
    ));
    try std.testing.expectEqual(descending_maximum, best_maximum);
    try std.testing.expectEqual(descending_merit, best_merit);
    try std.testing.expectEqual(
        group_types.CandidateKind.full_network_newton,
        best_kind,
    );
    // Once candidates descend the actual convergence norm, the strongest
    // maximum-norm descent wins even when its smooth RMS merit is worse.
    try std.testing.expect(try group_solve.retainMeaningfulNewtonCandidate(
        current_maximum,
        current_merit,
        options,
        &best_state,
        &best_residual,
        &best_maximum,
        &best_merit,
        &best_kind,
        &best_is_picard,
        &stronger_maximum_descent_state,
        &stronger_maximum_descent_residual,
        stronger_maximum_descent,
        .directional_newton,
    ));
    try std.testing.expectEqual(stronger_maximum_descent, best_maximum);
    try std.testing.expectEqual(stronger_maximum_descent_merit, best_merit);
    try std.testing.expectEqual(
        group_types.CandidateKind.directional_newton,
        best_kind,
    );
    try std.testing.expect(!try group_solve.retainMeaningfulNewtonCandidate(
        current_maximum,
        current_merit,
        options,
        &best_state,
        &best_residual,
        &best_maximum,
        &best_merit,
        &best_kind,
        &best_is_picard,
        &ridge_state,
        &ridge_residual,
        ridge_maximum,
        .phosphate_extent_newton,
    ));
}

test "trace reaction inventories do not inherit a one-unit relative floor" {
    const options: group_types.Options = .{
        .absolute_tolerance_mol_per_m3 = 1e-13,
        .absolute_tolerance_mol_per_megagram = 1e-9,
        .relative_tolerance = 1e-8,
    };
    const trace_state = [_]f64{1e-10};
    const trace_residual = [_]f64{5e-12};
    try std.testing.expect(try group_numerics.scaledNorm(&trace_state, &trace_residual, options) > 1);

    const aqueous_count = @typeInfo(aqueous_network.State).@"struct".fields.len;
    const phosphate_count = @typeInfo(phosphate_network.State).@"struct".fields.len;
    const exchange_index = aqueous_count + 2 * phosphate_count;
    try std.testing.expectEqual(
        options.absolute_tolerance_mol_per_megagram + options.relative_tolerance * 1e-10,
        group_numerics.residualScale(1e-10, exchange_index, options),
    );
}

test "SOLUTE reaction solver rejects degenerate divergence watch options" {
    // A patience of zero would fire on the first non-improving iteration and a
    // growth factor below one would fire on an improving one, mirroring
    // soil/organic/transport.zig, soil/gas/aqueous_extensive_transport.zig and
    // soil/solute/transport_solver.zig.
    var degenerate_patience: group_types.Options = .{};
    degenerate_patience.divergence_patience = 0;
    try std.testing.expectError(
        error.InvalidSoluteReactionSolverOptions,
        group_solve.validateOptions(degenerate_patience),
    );
    var degenerate_growth: group_types.Options = .{};
    degenerate_growth.divergence_growth_factor = 0.5;
    try std.testing.expectError(
        error.InvalidSoluteReactionSolverOptions,
        group_solve.validateOptions(degenerate_growth),
    );
    var disabled_anderson: group_types.Options = .{};
    disabled_anderson.anderson_recovery = false;
    try std.testing.expectError(
        error.InvalidSoluteReactionSolverOptions,
        group_solve.validateOptions(disabled_anderson),
    );
    var over_relaxed_newton: group_types.Options = .{};
    over_relaxed_newton.maximum_newton_fraction = 1.01;
    try std.testing.expectError(
        error.InvalidSoluteReactionSolverOptions,
        group_solve.validateOptions(over_relaxed_newton),
    );
}

test "roundoff-scale complementarity cannot publish or suppress genuine Anderson" {
    const current_merit = 1.0e8;
    const representation_floor =
        64.0 * std.math.floatEps(f64) * current_merit;
    const subthreshold_complementarity_merit =
        current_merit - 0.25 * representation_floor;
    try std.testing.expect(!group_network.meaningfulNewtonMeritDecrease(
        current_merit,
        subthreshold_complementarity_merit,
    ));
    try std.testing.expect(group_network.meaningfulNewtonMeritDecrease(
        current_merit,
        current_merit - 50,
    ));
    try std.testing.expect(group_solve.andersonTierEnabled(
        .full_network_newton,
        current_merit,
        current_merit - 50,
        60,
    ));

    for ([_]group_types.CandidateKind{
        .anderson_depth_two,
        .anderson_depth_one,
        .coordinate_anderson,
    }) |kind| {
        var best_state = [_]f64{0};
        var best_residual = [_]f64{0};
        var best_norm: f64 = current_merit;
        var best_kind: group_types.CandidateKind = .none;
        var best_is_picard = false;
        try std.testing.expect(!group_solve.retainMeaningfulCandidate(
            current_merit,
            &best_state,
            &best_residual,
            &best_norm,
            &best_kind,
            &best_is_picard,
            &.{1},
            &.{1},
            subthreshold_complementarity_merit,
            kind,
            true,
        ));
        try std.testing.expectEqual(group_types.CandidateKind.none, best_kind);
    }

    const current = [_]f64{ 0, 2 };
    const defect = [_]f64{ 0.1, -0.2 };
    const seed = [_]f64{ 0.05, 1.9 };
    const seed_defect = [_]f64{ 0.09, -0.18 };
    var accelerated: [2]f64 = undefined;
    const anderson_attempted = numerics.andersonDepthOneCandidate(
        &current,
        &defect,
        &seed,
        &seed_defect,
        &accelerated,
    );
    try std.testing.expect(anderson_attempted);
    try std.testing.expect(!std.mem.eql(f64, &seed, &accelerated));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), accelerated[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), accelerated[1], 1e-12);
    const scaled_mixing = group_numerics.scaledAndersonDepthOneMixing(&current, &defect, &seed_defect, .{}).?;
    try std.testing.expectApproxEqAbs(@as(f64, -9), scaled_mixing, 128 * std.math.floatEps(f64));
    try std.testing.expect(group_numerics.scaledAndersonDepthOneCandidate(&current, &defect, &seed, &seed_defect, .{}, &accelerated));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), accelerated[0], 128 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 1), accelerated[1], 128 * std.math.floatEps(f64));
}

test "Anderson tier follows the maximum convergence norm rather than RMS merit" {
    const current_maximum: f64 = 100;
    const worsening_maximum: f64 = 101;
    const current_rms: f64 = 50;
    const improving_rms: f64 = 25;
    try std.testing.expect(group_solve.andersonTierEnabled(
        .full_network_newton,
        current_maximum,
        worsening_maximum,
        64,
    ));
    try std.testing.expect(!group_solve.andersonTierEnabled(
        .full_network_newton,
        current_rms,
        improving_rms,
        64,
    ));
}

test "Anderson tier prices fallback when Newton contraction cannot meet the hard ceiling" {
    const current_maximum: f64 = 1.0e8;
    const descending_newton: f64 = 9.0e7;
    try std.testing.expect(group_solve.andersonTierEnabled(
        .full_network_newton,
        current_maximum,
        descending_newton,
        10,
    ));
    try std.testing.expect(!group_solve.andersonTierEnabled(
        .full_network_newton,
        current_maximum,
        descending_newton,
        200,
    ));
    try std.testing.expect(!group_solve.andersonTierEnabled(
        .full_network_newton,
        current_maximum,
        0.5,
        1,
    ));
}

test "undamped balance exposes the captured false chemical equilibrium" {
    const encoded = @embedFile("testdata/ottawa_hour1_false_equilibrium_after.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    const parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    const changes = try captured.state.evaluateCell(0, parameters);
    const coefficients = try captured.state.activityCoefficients(0, parameters.fractions);
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var target: [chemistry.State.packedComponentCount()]f64 = undefined;
    var balance: [chemistry.State.packedComponentCount()]f64 = undefined;
    try captured.state.packCell(0, &current);
    try captured.state.undampedReactionBalance(0, changes, coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, &balance);
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    const fraction = try group_numerics.transformedVectorAdmissible(&scratch, &current, changes, parameters, 1, &target);
    for (&target, current) |*value, original| value.* -= original;
    // This immutable historical endpoint passes the old damped-map norm even
    // though a large NH4 -> NH3 balance remains. Future solver changes must
    // not erase the independent balance defect merely by damping the trial.
    try std.testing.expect(fraction < std.math.floatEps(f64));
    try std.testing.expect(try group_numerics.scaledNorm(&current, &target, captured.options) <= 1);
    const ammonia = group_numerics2.aqueousPackedIndex("ammonia_non_band");
    try std.testing.expectApproxEqAbs(@as(f64, 0.25955751710157066), balance[ammonia], 1e-12);
    try std.testing.expect(try group_numerics.scaledNorm(&current, &balance, captured.options) > 1e6);

    var full_balance: [chemistry.State.packedComponentCount()]f64 = undefined;
    var reused_balance: [chemistry.State.packedComponentCount()]f64 = undefined;
    try group_evaluate.evaluateGlobalResidualAt(&scratch, &current, parameters, &full_balance);
    const evaluations_before = diagnostic_control.evaluationCounts().full_network;
    const loaded_changes_carrier = try group_evaluate.evaluateAtLoaded(&scratch, &current, parameters);
    _ = try group_evaluate.evaluateLoadedReactionBalance(&scratch, loaded_changes_carrier, parameters, &reused_balance);
    try std.testing.expectEqual(evaluations_before + 1, diagnostic_control.evaluationCounts().full_network);
    try std.testing.expectEqualSlices(f64, &full_balance, &reused_balance);

    // The ammonia defect is not an infeasible boundary reaction: its whole
    // independent conservative step is available at the historical endpoint.
    var rates: [reaction_span.reaction_count]f64 = undefined;
    try reaction_span.evaluateRates(&captured.state, 0, parameters, &rates);
    var independent = reaction_span.zeroTransformations(parameters);
    try reaction_span.addReactionExtent(&independent, reaction_span.aqueous_reaction_offset, rates[reaction_span.aqueous_reaction_offset], changes, parameters);
    try std.testing.expectEqual(@as(f64, 1), try group_numerics.transformedVectorAdmissible(&scratch, &current, independent, parameters, 1, &target));
    try std.testing.expectApproxEqAbs(balance[ammonia], target[ammonia] - current[ammonia], 1e-15);
    try @import("reaction_feasible_map.zig").evaluate(&scratch, &current, changes, parameters, &target);
    try std.testing.expect(target[ammonia] - current[ammonia] > 0.01);
    var feasible = try chemistry.State.init(std.testing.allocator, 1);
    defer feasible.deinit();
    try feasible.unpackCell(0, &target);
    try group_solve.requireAcceptedStateConservation(&scratch, &feasible, 0, &current, parameters);

    // Source SOLUTE.F prices dicalcium precipitation from HPO4, but its
    // ledger consumes H2PO4 and releases H. An isolated extent is blocked
    // here; pairing the existing HPO4 + H -> H2PO4 axis removes the transient
    // donor requirement without changing either source reaction. This proves
    // an axis-by-axis inventory box does not describe all feasible coupled
    // directions. It is a search regression, not a changed reaction model.
    const dicalcium_axis = reaction_span.non_band_phosphate_mineral_offset + 2;
    const phosphate_association_axis = reaction_span.non_band_phosphate_aqueous_offset + 1;
    const extent = rates[dicalcium_axis];
    var paired = reaction_span.zeroTransformations(parameters);
    try reaction_span.addReactionExtent(&paired, dicalcium_axis, extent, changes, parameters);
    try std.testing.expect(try group_numerics.transformedVectorAdmissible(&scratch, &current, paired, parameters, 1, &target) < std.math.floatEps(f64));
    try reaction_span.addReactionExtent(&paired, phosphate_association_axis, extent, changes, parameters);
    try std.testing.expectEqual(@as(f64, 1), try group_numerics.transformedVectorAdmissible(&scratch, &current, paired, parameters, 1, &target));
    try scratch.unpackCell(0, &target);
    const phosphate_before = captured.state.non_band_phosphate[0];
    const phosphate_after = scratch.non_band_phosphate[0];
    const roundoff = 128 * std.math.floatEps(f64) * @max(1.0, phosphate_before.dissolved_hpo4_mol_p_per_m3);
    try std.testing.expectApproxEqAbs(phosphate_before.dissolved_hpo4_mol_p_per_m3 - extent, phosphate_after.dissolved_hpo4_mol_p_per_m3, roundoff);
    try std.testing.expectApproxEqAbs(phosphate_before.dissolved_h2po4_mol_p_per_m3, phosphate_after.dissolved_h2po4_mol_p_per_m3, roundoff);
    try std.testing.expectApproxEqAbs(phosphate_before.dicalcium_phosphate_solid_mol_per_m3 + extent, phosphate_after.dicalcium_phosphate_solid_mol_per_m3, roundoff);
    try std.testing.expectApproxEqAbs(captured.state.aqueous[0].calcium - extent * parameters.fractions.phosphate_non_band, scratch.aqueous[0].calcium, roundoff);
    const search_span = @import("reaction_search_span.zig");
    var search_axis = reaction_span.zeroTransformations(parameters);
    try search_span.addReactionExtent(&search_axis, dicalcium_axis, extent, changes, parameters);
    try std.testing.expectEqualDeep(paired, search_axis);
    try std.testing.expectEqual(@as(f64, 1), try group_numerics.transformedVectorAdmissible(&scratch, &current, search_axis, parameters, 1, &target));
    try scratch.unpackCell(0, &current);
    var coordinates: [reaction_span.reaction_count]f64 = undefined;
    try search_span.evaluateRates(&scratch, 0, parameters, &coordinates);
    var reconstructed = reaction_span.zeroTransformations(parameters);
    var native_reconstructed = reaction_span.zeroTransformations(parameters);
    for (coordinates, rates, 0..) |coordinate, native_rate, axis| {
        if (coordinate != 0) try search_span.addReactionExtent(&reconstructed, axis, coordinate, changes, parameters);
        if (native_rate != 0) try reaction_span.addReactionExtent(&native_reconstructed, axis, native_rate, changes, parameters);
    }
    var original_balance: [chemistry.State.packedComponentCount()]f64 = undefined;
    var reconstructed_balance: [chemistry.State.packedComponentCount()]f64 = undefined;
    try scratch.undampedReactionBalance(0, native_reconstructed, coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, &original_balance);
    try scratch.undampedReactionBalance(0, reconstructed, coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, &reconstructed_balance);
    for (original_balance, reconstructed_balance) |original, recomposed| try std.testing.expectApproxEqAbs(original, recomposed, 256 * std.math.floatEps(f64) * @max(1, @abs(original)));
    for ([_]bool{ false, true }) |disable_acid_chain| {
        var two_zone_parameters = parameters;
        two_zone_parameters.fractions.phosphate_non_band = 0.65;
        two_zone_parameters.fractions.phosphate_band = 0.35;
        two_zone_parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
        if (disable_acid_chain) two_zone_parameters.phosphate_kinetics.maximum_pairing_mol_per_m3_step = 0;
        try scratch.unpackCell(0, &current);
        scratch.band_phosphate[0] = scratch.non_band_phosphate[0];
        const reference = try scratch.evaluateCell(0, two_zone_parameters);
        const two_zone_coefficients = try scratch.activityCoefficients(0, two_zone_parameters.fractions);
        try reaction_span.evaluateRates(&scratch, 0, two_zone_parameters, &rates);
        try search_span.evaluateRates(&scratch, 0, two_zone_parameters, &coordinates);
        if (disable_acid_chain) try std.testing.expectEqualSlices(f64, &rates, &coordinates);
        native_reconstructed = reaction_span.zeroTransformations(two_zone_parameters);
        reconstructed = reaction_span.zeroTransformations(two_zone_parameters);
        for (coordinates, rates, 0..) |coordinate, native_rate, axis| {
            if (coordinate != 0) try search_span.addReactionExtent(&reconstructed, axis, coordinate, reference, two_zone_parameters);
            if (native_rate != 0) try reaction_span.addReactionExtent(&native_reconstructed, axis, native_rate, reference, two_zone_parameters);
        }
        try scratch.undampedReactionBalance(0, native_reconstructed, two_zone_coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, &original_balance);
        try scratch.undampedReactionBalance(0, reconstructed, two_zone_coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, &reconstructed_balance);
        for (original_balance, reconstructed_balance) |original, recomposed| try std.testing.expectApproxEqAbs(original, recomposed, 256 * std.math.floatEps(f64) * @max(1, @abs(original)));
    }
    try captured.state.packCell(0, &target);
    try std.testing.expectEqualSlices(f64, &current, &target);
}

test "physical chemical acceptance rejects captured false convergence without publication" {
    const encoded = @embedFile("testdata/ottawa_hour1_false_equilibrium_after.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    var before: [chemistry.State.packedComponentCount()]f64 = undefined;
    var after: [chemistry.State.packedComponentCount()]f64 = undefined;
    try captured.state.packCell(0, &before);
    const original_ledger = captured.state.water_equilibrium_balance_mol[0];
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    // This historical endpoint used to return converged on its first damped
    // map evaluation while a feasible 0.25956 mol/m3 NH3 change remained.
    const closure_parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    try std.testing.expectError(error.SoluteReactionPhysicalBalanceFailure, group_evaluate.requirePhysicalReactionBalance(&workspace.scratch, &before, closure_parameters, captured.options, workspace.residual));
    try captured.state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &before, &after);
    try std.testing.expectEqual(original_ledger, captured.state.water_equilibrium_balance_mol[0]);
    const ammonia = group_numerics2.aqueousPackedIndex("ammonia_non_band");
    try std.testing.expectApproxEqAbs(@as(f64, 0.25955751710157066), workspace.residual[ammonia], 1e-12);
    // A search preconditioner must never relax physical publication. Even
    // references large enough to hide every search defect leave this real
    // false-equilibrium endpoint rejected by the independent source gate.
    const large_references = [_]f64{1e30} ** chemistry.State.packedComponentCount();
    var search_options = captured.options;
    search_options.search_reference_concentrations = &large_references;
    try std.testing.expect(try group_numerics.scaledNorm(&before, workspace.residual, search_options) < 1);
    try std.testing.expectError(error.SoluteReactionPhysicalBalanceFailure, group_evaluate.requirePhysicalReactionBalance(&workspace.scratch, &before, closure_parameters, search_options, workspace.residual));
    // The search may now move away from the historical bad endpoint. Under
    // a one-iteration budget it must either return a physically accepted,
    // conservative state or fail transactionally; a damped false success is
    // never allowed. This does not relax the calcium convergence regression.
    var short_budget = captured.options;
    short_budget.max_iterations = 1;
    if (group_solve.solveCellWithWorkspace(&workspace, &captured.state, 0, captured.parameters, short_budget)) |solved| {
        try std.testing.expect(solved.converged);
        try std.testing.expect(solved.iterations <= 1);
        try captured.state.packCell(0, &after);
        _ = try group_evaluate.requirePhysicalReactionBalance(&workspace.scratch, &after, closure_parameters, captured.options, workspace.residual);
        try group_solve.requireAcceptedStateConservation(&workspace.scratch, &captured.state, 0, &before, captured.parameters);
    } else |err| {
        switch (err) {
            error.SoluteReactionPhysicalBalanceFailure, error.SoluteReactionSolverDidNotConverge, error.SoluteReactionSolverStagnated, error.SoluteReactionSolverDiverged => {},
            else => return err,
        }
        try captured.state.packCell(0, &after);
        try std.testing.expectEqualSlices(f64, &before, &after);
        try std.testing.expect(workspace.best_bounded_iteration != null);
        try std.testing.expectEqualSlices(f64, workspace.best_bounded_state, workspace.current);
        try std.testing.expectEqualSlices(f64, workspace.best_bounded_residual, workspace.residual);
        try group_evaluate.evaluateGlobalResidualAt(&workspace.scratch, workspace.current, closure_parameters, workspace.probe_residual);
        try std.testing.expectEqualSlices(f64, workspace.residual, workspace.probe_residual);
        try std.testing.expect(try group_numerics.scaledNorm(workspace.current, workspace.residual, captured.options) > 1);
    }
    try std.testing.expectEqual(original_ledger, captured.state.water_equilibrium_balance_mol[0]);
    try captured.state.unpackCell(0, &before);
    // An inactive network is a genuine zero-defect control. The new gate
    // must permit it through the same production solve and inventory census.
    var inactive = group_solve.equilibriumClosureParameters(captured.parameters);
    inactive.aqueous_kinetics = std.mem.zeroes(aqueous_rates.Kinetics);
    inactive.phosphate_surface.maximum_exchange_mol_per_megagram_step = 0;
    inactive.phosphate_kinetics.maximum_pairing_mol_per_m3_step = 0;
    inactive.phosphate_minerals = null;
    inactive.cation_exchange_parameters.maximum_adsorption_mol_charge_per_m3_step = 0;
    inactive.carboxyl_exchange_parameters.maximum_exchange_mol_per_m3_per_iteration = 0;
    const result = try group_solve.solveCellWithWorkspace(&workspace, &captured.state, 0, inactive, captured.options);
    try std.testing.expect(result.converged);
    try std.testing.expectEqual(@as(u16, 1), result.iterations);
}

test "conserved hydroxide speciation resolves captured metal chains" {
    const speciation = @import("hydroxide_speciation.zig");
    const encoded = @embedFile("testdata/ottawa_hour1_false_equilibrium_after.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    const coefficients = try captured.state.activityCoefficients(0, captured.parameters.fractions);
    const before = captured.state.aqueous[0];
    const constants = captured.parameters.aqueous_constants;
    const result = try speciation.solve(.{
        .aluminum = .{
            .concentrations_mol_per_m3 = .{ before.aluminum, before.aluminum_hydroxide_1, before.aluminum_hydroxide_2, before.aluminum_hydroxide_3, before.aluminum_hydroxide_4 },
            .dissociation_constants = .{ constants.aluminum_hydroxide_1, constants.aluminum_hydroxide_2, constants.aluminum_hydroxide_3, constants.aluminum_hydroxide_4 },
        },
        .iron = .{
            .concentrations_mol_per_m3 = .{ before.iron, before.iron_hydroxide_1, before.iron_hydroxide_2, before.iron_hydroxide_3, before.iron_hydroxide_4 },
            .dissociation_constants = .{ constants.iron_hydroxide_1, constants.iron_hydroxide_2, constants.iron_hydroxide_3, constants.iron_hydroxide_4 },
        },
        .hydrogen_mol_per_m3 = before.hydrogen,
        .hydroxide_mol_per_m3 = before.hydroxide,
        .monovalent_activity_coefficient = coefficients.monovalent_activity_coefficient,
        .divalent_activity_coefficient = coefficients.divalent_activity_coefficient,
        .trivalent_activity_coefficient = coefficients.trivalent_activity_coefficient,
        .water_activity_product_mol2_per_m6 = captured.parameters.water_activity_product_mol2_per_m6,
        .max_iterations = captured.options.max_iterations,
    });
    var after = before;
    after.hydrogen = result.hydrogen_mol_per_m3;
    after.hydroxide = result.hydroxide_mol_per_m3;
    after.aluminum = result.aluminum_mol_per_m3[0];
    after.iron = result.iron_mol_per_m3[0];
    inline for (1..5) |index| {
        const suffix = .{ "1", "2", "3", "4" }[index - 1];
        @field(after, "aluminum_hydroxide_" ++ suffix) = result.aluminum_mol_per_m3[index];
        @field(after, "iron_hydroxide_" ++ suffix) = result.iron_mol_per_m3[index];
    }
    const rates = try aqueous_rates.calculate(after, coefficients, constants, captured.parameters.aqueous_kinetics);
    var before_charge = before.hydrogen - before.hydroxide + 3 * (before.aluminum + before.iron);
    var after_charge = after.hydrogen - after.hydroxide + 3 * (after.aluminum + after.iron);
    var metal_scale = before.aluminum + before.iron;
    inline for (.{ "aluminum", "iron" }) |metal| {
        var original_total = @field(before, metal);
        var final_total = @field(after, metal);
        inline for (1..5) |index| {
            const name = metal ++ "_hydroxide_" ++ .{ "1", "2", "3", "4" }[index - 1];
            original_total += @field(before, name);
            final_total += @field(after, name);
            const charge = 3 - @as(f64, @floatFromInt(index));
            before_charge += charge * @field(before, name);
            after_charge += charge * @field(after, name);
        }
        metal_scale += original_total;
        try std.testing.expectApproxEqAbs(original_total, final_total, 128 * std.math.floatEps(f64) * original_total);
        inline for (1..5) |index| {
            const rate_name = metal ++ "_hydroxide_" ++ .{ "1", "2", "3", "4" }[index - 1] ++ "_association";
            try std.testing.expect(@abs(@field(rates, rate_name)) <= 128 * std.math.floatEps(f64) * original_total);
        }
    }
    try std.testing.expectApproxEqAbs(before_charge, after_charge, 128 * std.math.floatEps(f64) * (before.hydrogen + before.hydroxide + 4 * metal_scale));
    try std.testing.expectEqualDeep(before, captured.state.aqueous[0]);
    try std.testing.expect(result.iterations < captured.options.max_iterations);

    // Exercise the production-shaped adapter and the complete accepted-state
    // inventory census, not only the local metal totals above.
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var candidate = try chemistry.State.init(std.testing.allocator, 1);
    defer candidate.deinit();
    var original: [chemistry.State.packedComponentCount()]f64 = undefined;
    var target: [chemistry.State.packedComponentCount()]f64 = undefined;
    try captured.state.packCell(0, &original);
    var budget = try numerics.NonlinearBudget.init(captured.options.max_iterations);
    try std.testing.expect(try @import("reaction_local_speciation.zig").hydroxideCandidate(&scratch, &original, captured.parameters, &budget, &target));
    try candidate.unpackCell(0, &target);
    try group_solve.requireAcceptedStateConservation(&scratch, &candidate, 0, &original, captured.parameters);
    try std.testing.expectEqual(result.iterations, budget.attempted_iterations);
    try std.testing.expectEqualDeep(after, candidate.aqueous[0]);
    try std.testing.expectEqualDeep(captured.state.non_band_phosphate[0], candidate.non_band_phosphate[0]);
    try std.testing.expectEqualDeep(captured.state.band_phosphate[0], candidate.band_phosphate[0]);
    var disabled = captured.parameters;
    disabled.aqueous_kinetics.maximum_slow_association_mol_per_m3_step = 0;
    @memset(&target, -1);
    try std.testing.expect(!try @import("reaction_local_speciation.zig").hydroxideCandidate(&scratch, &original, disabled, &budget, &target));
    for (target) |value| try std.testing.expectEqual(@as(f64, -1), value);

    var acid_budget = try numerics.NonlinearBudget.init(captured.options.max_iterations);
    try std.testing.expect(try @import("reaction_local_speciation.zig").acidBaseCandidate(&scratch, &original, captured.parameters, &acid_budget, &target));
    try candidate.unpackCell(0, &target);
    try group_solve.requireAcceptedStateConservation(&scratch, &candidate, 0, &original, captured.parameters);
    const acid_rates = try aqueous_rates.calculate(candidate.aqueous[0], coefficients, constants, captured.parameters.aqueous_kinetics);
    const scale = before.hydroxide + before.calcium + metal_scale + before.ammonium_non_band + before.carbon_dioxide;
    inline for (.{ "ammonium_non_band_association", "carbonate_hydrogen_association", "bicarbonate_hydrogen_association", "calcium_hydroxide_association", "magnesium_hydroxide_association", "aluminum_hydroxide_1_association", "aluminum_hydroxide_2_association", "aluminum_hydroxide_3_association", "aluminum_hydroxide_4_association", "iron_hydroxide_1_association", "iron_hydroxide_2_association", "iron_hydroxide_3_association", "iron_hydroxide_4_association" }) |name|
        try std.testing.expect(@abs(@field(acid_rates, name)) <= 128 * std.math.floatEps(f64) * scale);
    const phosphate_rates_after = try phosphate_rates.calculate(candidate.aqueous[0], candidate.non_band_phosphate[0], coefficients, captured.parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3, captured.parameters.phosphate_constants, captured.parameters.phosphate_surface, captured.parameters.phosphate_minerals, captured.parameters.phosphate_kinetics);
    inline for (.{ "po4_hydrogen_association_mol_p_per_m3", "hpo4_hydrogen_association_mol_p_per_m3", "h2po4_hydrogen_association_mol_p_per_m3" }) |name|
        try std.testing.expect(@abs(@field(phosphate_rates_after.aqueous, name)) <= 128 * std.math.floatEps(f64) * scale);
    const solvent_expected = captured.state.water_mol_per_m3[0] + candidate.aqueous[0].carbon_dioxide - before.carbon_dioxide;
    try std.testing.expectApproxEqAbs(solvent_expected, candidate.water_mol_per_m3[0], 128 * std.math.floatEps(f64) * solvent_expected);
    try std.testing.expectEqualDeep(captured.state.band_phosphate[0], candidate.band_phosphate[0]);
    try std.testing.expectEqual(before.ammonium_band, candidate.aqueous[0].ammonium_band);
    try std.testing.expectEqual(before.ammonia_band, candidate.aqueous[0].ammonia_band);
    var priced: [chemistry.State.packedComponentCount()]f64 = undefined;
    var defect: [chemistry.State.packedComponentCount()]f64 = undefined;
    _ = try group_evaluate.evaluateCandidateResidualAtFraction(&scratch, &original, &target, &priced, &defect, group_solve.equilibriumClosureParameters(captured.parameters), captured.options, 1);
    const aluminum_index = group_numerics2.aqueousPackedIndex("aluminum");
    try std.testing.expect(target[aluminum_index] > 0);
    try std.testing.expectEqual(target[aluminum_index], priced[aluminum_index]);
    var mineral_budget = try numerics.NonlinearBudget.init(captured.options.max_iterations);
    try std.testing.expect(try @import("reaction_local_speciation.zig").phosphateCandidate(&scratch, &original, captured.parameters, &mineral_budget, &target));
    try candidate.unpackCell(0, &target);
    try group_solve.requireAcceptedStateConservation(&scratch, &candidate, 0, &original, captured.parameters);
    const mineral_rates = try phosphate_rates.calculate(candidate.aqueous[0], candidate.non_band_phosphate[0], coefficients, captured.parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3, captured.parameters.phosphate_constants, captured.parameters.phosphate_surface, captured.parameters.phosphate_minerals, captured.parameters.phosphate_kinetics);
    inline for (@typeInfo(@TypeOf(mineral_rates.minerals)).@"struct".fields) |field|
        try std.testing.expect(@abs(@field(mineral_rates.minerals, field.name)) <= 128 * std.math.floatEps(f64) * scale);
    try std.testing.expect(mineral_budget.attempted_iterations < captured.options.max_iterations);
    try std.testing.expectEqualDeep(captured.state.band_phosphate[0], candidate.band_phosphate[0]);
    // This is deliberately NOT a full-network equilibrium test. Retained
    // sorption owners and refreshed activities still require coupled closure.
    const final_coefficients = try candidate.activityCoefficients(0, captured.parameters.fractions);
    const final_changes = try candidate.evaluateCell(0, group_solve.equilibriumClosureParameters(captured.parameters));
    try candidate.undampedReactionBalance(0, final_changes, final_coefficients.monovalent_activity_coefficient, captured.parameters.water_activity_product_mol2_per_m6, &defect);
    try std.testing.expect(try group_numerics.scaledNorm(&target, &defect, captured.options) > 1);
    var exhausted = try numerics.NonlinearBudget.init(1);
    @memset(&target, -1);
    try std.testing.expect(!try @import("reaction_local_speciation.zig").phosphateCandidate(&scratch, &original, captured.parameters, &exhausted, &target));
    try std.testing.expectEqual(@as(u16, 1), exhausted.attempted_iterations);
    for (target) |value| try std.testing.expectEqual(@as(f64, -1), value);
}

fn requireCapturedExamplesNgProdConvergence(
    encoded_text: []const u8,
    compare_trace_path: bool,
) !void {
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(
        u8,
        decoder.calcSizeUpperBound(encoded_text.len),
    );
    defer std.testing.allocator.free(bytes);
    const decoded_len = try decoder.decode(bytes, encoded_text);
    var reader: std.Io.Reader = .fixed(bytes[0..decoded_len]);
    var replay_case = try failure_snapshot.read(
        std.testing.allocator,
        &reader,
    );
    defer replay_case.deinit();

    const packed_count = chemistry.State.packedComponentCount();
    const initial = try std.testing.allocator.alloc(f64, packed_count);
    defer std.testing.allocator.free(initial);
    const first_final = try std.testing.allocator.alloc(f64, packed_count);
    defer std.testing.allocator.free(first_final);
    const repeated_final = try std.testing.allocator.alloc(f64, packed_count);
    defer std.testing.allocator.free(repeated_final);
    try replay_case.state.packCell(0, initial);
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();

    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    const first = group_solve.solveCellWithWorkspace(
        &workspace,
        &replay_case.state,
        0,
        replay_case.parameters,
        replay_case.options,
    ) catch |err| {
        std.debug.print("captured solve failed: {s}\n", .{@errorName(err)});
        std.debug.print("captured best bounded iterate: iteration={any} stopped_at={d} physical_quality_maximum={e}\n", .{ workspace.best_bounded_iteration, workspace.last_iteration, workspace.best_bounded_maximum });
        if (workspace.last_search_metric) |metric| std.debug.print("captured search frontier: component={s} state={e} defect={e} maximum={e} rms={e} last_candidate={s}\n", .{ chemistry.State.packedComponentName(metric.component) orelse "unknown", workspace.current[metric.component], workspace.residual[metric.component], metric.maximum, metric.rms, @tagName(workspace.last_selected_candidate) });
        if (err == error.SoluteReactionPhysicalBalanceFailure or err == error.SoluteReactionSolverDidNotConverge or err == error.SoluteReactionSolverStagnated) {
            const index = group_numerics.largestScaledResidualIndex(workspace.current, workspace.residual, replay_case.options);
            std.debug.print("captured physical rejection: component={s} state={e} undamped_net_balance={e} scaled_balance={e}\n", .{ chemistry.State.packedComponentName(index) orelse "unknown", workspace.current[index], workspace.residual[index], try group_numerics.scaledNorm(workspace.current, workspace.residual, replay_case.options) });
            const parameters = group_solve.equilibriumClosureParameters(replay_case.parameters);
            const changes = try group_evaluate.evaluateAt(&workspace.scratch, workspace.current, parameters);
            const quality = try @import("reaction_physical_quality.zig").measure(&workspace.scratch, parameters, workspace.residual, .{});
            std.debug.print("captured chemical quality: component={s} ratio={e} pH_movement={e}\n", .{ chemistry.State.packedComponentName(quality.component).?, quality.maximum, quality.pH_change });
            const native_span = @import("conservative_reaction_span.zig");
            var rates: [native_span.reaction_count]f64 = undefined;
            try native_span.evaluateRates(&workspace.scratch, 0, parameters, &rates);
            const coefficients = try workspace.scratch.activityCoefficients(0, parameters.fractions);
            var axis_balance: [chemistry.State.packedComponentCount()]f64 = undefined;
            for (rates, 0..) |rate, column| {
                if (rate == 0) continue;
                var axis = native_span.zeroTransformations(parameters);
                try native_span.addReactionExtent(&axis, column, rate, changes, parameters);
                try workspace.scratch.undampedReactionBalance(0, axis, coefficients.monovalent_activity_coefficient, parameters.water_activity_product_mol2_per_m6, &axis_balance);
                if (@abs(axis_balance[index]) > 1e-6) std.debug.print("limiting balance contribution: reaction={s} rate={e} contribution={e}\n", .{ native_span.reactionIdentity(column).?.name, rate, axis_balance[index] });
            }
            inline for (.{ "hydrogen", "hydroxide", "carbonate", "bicarbonate", "carbon_dioxide", "calcium", "calcium_carbonate", "calcium_bicarbonate" }) |name| std.debug.print("captured aqueous {s}={e}\n", .{ name, @field(workspace.scratch.aqueous[0], name) });
            std.debug.print("captured H-minus-OH contributions: aqueous={e} phosphate_non_band={e} phosphate_band={e} carboxyl={e} exchange={e}\n", .{
                changes.aqueous.hydrogen - changes.aqueous.hydroxide,
                (changes.non_band_phosphate.dissolved_hydrogen_mol_per_m3 - changes.non_band_phosphate.dissolved_hydroxide_mol_per_m3) * parameters.fractions.phosphate_non_band,
                (changes.band_phosphate.dissolved_hydrogen_mol_per_m3 - changes.band_phosphate.dissolved_hydroxide_mol_per_m3) * parameters.fractions.phosphate_band,
                -changes.carboxyl_hydrogen_change_mol_per_megagram * changes.carboxyl_soil_mass_per_water_volume_megagrams_per_m3,
                -changes.cation_adsorption_mol_per_megagram.hydrogen * changes.cation_exchange_water_ratios.shared_megagrams_per_m3,
            });
        }
        return err;
    };
    try std.testing.expect(first.iterations <= replay_case.options.max_iterations);
    try std.testing.expect(first.maximum_scaled_residual <= 1);
    try replay_case.state.packCell(0, first_final);

    try replay_case.state.unpackCell(0, initial);
    const repeated: group_types.Result = if (compare_trace_path) repeated: {
        var trace = try group_types.SolverTrace.init(
            std.testing.allocator,
            @as(usize, replay_case.options.max_iterations) + 2,
        );
        defer trace.deinit();
        break :repeated try group_solve.solveCellWithWorkspaceAndTrace(
            &workspace,
            &replay_case.state,
            0,
            replay_case.parameters,
            replay_case.options,
            &trace,
        );
    } else try group_solve.solveCellWithWorkspace(
        &workspace,
        &replay_case.state,
        0,
        replay_case.parameters,
        replay_case.options,
    );
    try replay_case.state.packCell(0, repeated_final);
    try std.testing.expect(std.meta.eql(first, repeated));
    try std.testing.expectEqualSlices(f64, first_final, repeated_final);
}

test "examples-ng-prod day107 hour4 inactive mineral scaling converges within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(@embedFile("testdata/ottawa_day107_hour4_layer0_20260914.b64"), true);
}

test "examples-ng-prod day106 hour12 search scaling preserves neighboring convergence" {
    try requireCapturedExamplesNgProdConvergence(@embedFile("testdata/ottawa_day106_hour12_layer0_20260913.b64"), true);
}

test "captured day107 local mineral seed avoids repeated cold-start stagnation" {
    // Immutable attempted hour2565, cell0/layer0. The original cold-start
    // helper stalled after 27 outer iterations; no tolerance or cap changes.
    try requireCapturedExamplesNgProdConvergence(@embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64"), true);
}

test "ordinary mineral continuation cannot rearm within one equilibrium solve" {
    const mineral = @import("reaction_surface_minerals.zig");
    var seed: ?mineral.CandidateSeed = null;
    var consumed = false;
    mineral.prepareOrdinarySeed(&seed, &consumed);
    try std.testing.expect(!consumed);
    seed = @splat(1);
    mineral.prepareOrdinarySeed(&seed, &consumed);
    try std.testing.expect(consumed);
    for (seed.?) |value| try std.testing.expectEqual(@as(f64, 1), value);
    seed = @splat(2);
    mineral.prepareOrdinarySeed(&seed, &consumed);
    try std.testing.expect(seed == null);
    mineral.prepareOrdinarySeed(&seed, &consumed);
    try std.testing.expect(consumed);
    seed = @splat(3);
    mineral.prepareOrdinarySeed(&seed, &consumed);
    try std.testing.expect(seed == null);
    var next_solve_consumed = false;
    seed = @splat(4);
    mineral.prepareOrdinarySeed(&seed, &next_solve_consumed);
    try std.testing.expect(next_solve_consumed);
    for (seed.?) |value| try std.testing.expectEqual(@as(f64, 4), value);
}

test "coupled mineral seed rejection and failed-attempt isolation" {
    const encoded = @embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var initial: [chemistry.State.packedComponentCount()]f64 = undefined;
    try captured.state.packCell(0, &initial);
    const parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    const mineral = @import("reaction_surface_minerals.zig");
    var cold_seed: ?mineral.CandidateSeed = null;
    var output: @TypeOf(initial) = @splat(-1);
    try std.testing.expectError(error.SurfaceMineralDidNotConverge, mineral.candidateWithSeed(&scratch, &initial, parameters, 1, &output, &cold_seed));
    try std.testing.expect(cold_seed != null);
    for (cold_seed.?) |coordinate| try std.testing.expect(std.math.isFinite(coordinate));
    for (output) |coordinate| try std.testing.expectEqual(@as(f64, -1), coordinate);
    // Invalid and grossly worse guesses must not displace the same cold step.
    for ([_]f64{ std.math.nan(f64), 100 }) |value| {
        var rejected_seed: ?mineral.CandidateSeed = @splat(value);
        try std.testing.expectError(error.SurfaceMineralDidNotConverge, mineral.candidateWithSeed(&scratch, &initial, parameters, 1, &output, &rejected_seed));
        try std.testing.expectEqualSlices(f64, &cold_seed.?, &rejected_seed.?);
        for (output) |coordinate| try std.testing.expectEqual(@as(f64, -1), coordinate);
    }
    var unchanged: @TypeOf(initial) = undefined;
    try captured.state.packCell(0, &unchanged);
    try std.testing.expectEqualSlices(f64, &initial, &unchanged);
}

test "captured day77 primary mineral failure recovers before the outer ceiling" {
    try requireCapturedExamplesNgProdConvergence(@embedFile("testdata/ottawa_day77_hour14_primary_failure_20260909.b64"), true);
}

test "Anderson is priced on the final chemistry iteration without a reserved Newton retry" {
    // This shortened captured trajectory still requires fallback on its final
    // iteration; the failure-only entry retry cannot reset the four-step cap.
    const encoded = @embedFile("testdata/ottawa_day107_hour21_layer0_20260913.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var options = captured.options;
    options.max_iterations = 4;
    var trace = try group_types.SolverTrace.init(std.testing.allocator, 5);
    defer trace.deinit();
    var original: [chemistry.State.packedComponentCount()]f64 = undefined;
    var after: [chemistry.State.packedComponentCount()]f64 = undefined;
    try captured.state.packCell(0, &original);
    var suppression = diagnostic_control.suppress();
    defer suppression.restore();
    // This deliberately shortened budget checks scheduling and rollback;
    // the separate full-source-ceiling regressions still require convergence.
    try std.testing.expectError(error.SoluteReactionSolverDidNotConverge, group_solve.solveCellWithWorkspaceAndTrace(&workspace, &captured.state, 0, captured.parameters, options, &trace));
    // The final endpoint evaluation is marked with the exhausted budget;
    // it generates no additional Newton or Anderson step.
    try std.testing.expectEqual(@as(u16, 4), workspace.last_iteration);
    try std.testing.expect(workspace.best_bounded_iteration != null);
    try std.testing.expect(workspace.best_bounded_iteration.? <= options.max_iterations);
    try std.testing.expectEqual(@as(usize, 5), trace.count);
    try std.testing.expect(trace.recorded()[3].anderson_attempted);
    try captured.state.packCell(0, &after);
    try std.testing.expectEqualSlices(f64, &original, &after);
}

test "surface charge candidate conserves the captured calcium state" {
    const encoded = @embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var audit = try chemistry.State.init(std.testing.allocator, 1);
    defer audit.deinit();
    var initial: [chemistry.State.packedComponentCount()]f64 = undefined;
    var candidate: @TypeOf(initial) = undefined;
    var residual: @TypeOf(initial) = undefined;
    try captured.state.packCell(0, &initial);
    const parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    const initial_changes_carrier = try group_evaluate.evaluateAtLoaded(&scratch, &initial, parameters);
    const initial_changes = initial_changes_carrier.transformations;
    _ = try group_evaluate.evaluateLoadedReactionBalance(&scratch, initial_changes_carrier, parameters, &residual);
    const before = try @import("reaction_physical_quality.zig").measure(&scratch, parameters, &residual, .{});
    const iterations = try @import("reaction_surface_charge.zig").candidate(&scratch, &initial, parameters, captured.options.max_iterations, &candidate);
    try group_solve.requireAcceptedStateConservation(&audit, &scratch, 0, &initial, parameters);
    const candidate_changes_carrier = try group_evaluate.evaluateAtLoaded(&scratch, &candidate, parameters);
    const candidate_changes = candidate_changes_carrier.transformations;
    _ = try group_evaluate.evaluateLoadedReactionBalance(&scratch, candidate_changes_carrier, parameters, &residual);
    const after = try @import("reaction_physical_quality.zig").measure(&scratch, parameters, &residual, .{});
    std.debug.print("surface-charge candidate: iterations={d} quality_before={e} quality_after={e} pH_before={e} pH_after={e}\n", .{ iterations, before.maximum, after.maximum, before.pH_change, after.pH_change });
    std.debug.print("surface-charge sources: H_before={e} H_after={e} phosphate_before={e} phosphate_after={e} carboxyl_before={e} carboxyl_after={e}\n", .{ captured.state.aqueous[0].hydrogen, scratch.aqueous[0].hydrogen, initial_changes.non_band_phosphate.dissolved_hydrogen_mol_per_m3 - initial_changes.non_band_phosphate.dissolved_hydroxide_mol_per_m3, candidate_changes.non_band_phosphate.dissolved_hydrogen_mol_per_m3 - candidate_changes.non_band_phosphate.dissolved_hydroxide_mol_per_m3, initial_changes.carboxyl_hydrogen_change_mol_per_megagram, candidate_changes.carboxyl_hydrogen_change_mol_per_megagram });
    try std.testing.expect(iterations <= captured.options.max_iterations);
    // The local block is not full chemistry: mineral/pair rates can grow
    // when the surface redistributes phosphate. Verify its actual scope
    // against the original rate kernels, then require global rejection.
    try std.testing.expect(after.maximum > 1);
    var local = @import("conservative_reaction_span.zig").zeroTransformations(parameters);
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    for ([_]phosphate_network.State{ scratch.non_band_phosphate[0], scratch.band_phosphate[0] }, 0..) |zone, index| {
        const fraction = if (index == 0) parameters.fractions.phosphate_non_band else parameters.fractions.phosphate_band;
        if (fraction == 0) continue;
        const density = if (index == 0) parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 else parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
        var fluxes = try phosphate_rates.calculate(scratch.aqueous[0], zone, coefficients, density, parameters.phosphate_constants, parameters.phosphate_surface, null, parameters.phosphate_kinetics);
        fluxes.aqueous.iron_hpo4_pairing_mol_p_per_m3 = 0;
        fluxes.aqueous.iron_h2po4_pairing_mol_p_per_m3 = 0;
        fluxes.aqueous.calcium_po4_pairing_mol_p_per_m3 = 0;
        fluxes.aqueous.calcium_hpo4_pairing_mol_p_per_m3 = 0;
        fluxes.aqueous.calcium_h2po4_pairing_mol_p_per_m3 = 0;
        fluxes.aqueous.magnesium_hpo4_pairing_mol_p_per_m3 = 0;
        if (index == 0) local.non_band_phosphate = try phosphate_network.assemble(fluxes) else local.band_phosphate = try phosphate_network.assemble(fluxes);
    }
    local.carboxyl_hydrogen_change_mol_per_megagram = candidate_changes.carboxyl_hydrogen_change_mol_per_megagram;
    // Hand-assembled transformations, so there is no projection to inherit a
    // coefficient from. Deriving it from the current carrier reproduces exactly
    // what the callee used to do internally -- now stated rather than implied.
    const local_coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    _ = try group_evaluate.evaluateLoadedReactionBalance(&scratch, .{ .transformations = local, .monovalent_activity_coefficient = local_coefficients.monovalent_activity_coefficient }, parameters, &residual);
    const local_quality = try @import("reaction_physical_quality.zig").measure(&scratch, parameters, &residual, .{});
    std.debug.print("surface-charge original local source quality={e} pH={e}\n", .{ local_quality.maximum, local_quality.pH_change });
    try std.testing.expect(local_quality.maximum <= 1);
    @memset(&candidate, -1);
    try std.testing.expectError(error.SurfaceChargeDidNotConverge, @import("reaction_surface_charge.zig").candidate(&scratch, &initial, parameters, 1, &candidate));
    for (candidate) |entry| try std.testing.expectEqual(@as(f64, -1), entry);

    // Both zones can have sites but no exchangeable phosphorus. The log-P
    // coordinates must stay inactive without creating trace P from solids.
    var zero_parameters = parameters;
    zero_parameters.fractions.phosphate_non_band = 0.25;
    zero_parameters.fractions.phosphate_band = 0.75;
    zero_parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3;
    var zero_zone = captured.state.non_band_phosphate[0];
    zero_zone.dissolved_po4_mol_p_per_m3 = 0;
    zero_zone.dissolved_hpo4_mol_p_per_m3 = 0;
    zero_zone.dissolved_h2po4_mol_p_per_m3 = 0;
    zero_zone.dissolved_h3po4_mol_p_per_m3 = 0;
    zero_zone.adsorbed_hpo4_mol_p_per_megagram = 0;
    zero_zone.adsorbed_h2po4_mol_p_per_megagram = 0;
    captured.state.non_band_phosphate[0] = zero_zone;
    captured.state.band_phosphate[0] = zero_zone;
    try captured.state.packCell(0, &initial);
    _ = try @import("reaction_surface_charge.zig").candidate(&scratch, &initial, zero_parameters, 20, &candidate);
    try group_solve.requireAcceptedStateConservation(&audit, &scratch, 0, &initial, zero_parameters);
    for ([_]phosphate_network.State{ scratch.non_band_phosphate[0], scratch.band_phosphate[0] }) |zone| {
        try std.testing.expectEqual(@as(f64, 0), zone.dissolved_po4_mol_p_per_m3 + zone.dissolved_hpo4_mol_p_per_m3 + zone.dissolved_h2po4_mol_p_per_m3 + zone.dissolved_h3po4_mol_p_per_m3 + zone.adsorbed_hpo4_mol_p_per_megagram + zone.adsorbed_h2po4_mol_p_per_megagram);
        try std.testing.expectEqual(zero_zone.hydroxyapatite_solid_mol_per_m3, zone.hydroxyapatite_solid_mol_per_m3);
    }
}

test "surface charge candidate with minerals closes captured full source" {
    try requireCapturedCoupledSpeciation(@embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64"));
}

test "surface charge candidate closes captured STARTE layer zero" {
    try requireCapturedCoupledSpeciation(@embedFile("testdata/ottawa_starte_layer0_20260909.b64"));
}

test "surface charge candidate closes captured hourly layer eleven" {
    try requireCapturedCoupledSpeciation(@embedFile("testdata/ottawa_hour1_layer11_20260909.b64"));
}

test "surface charge candidate closes layer eleven after kinetic geochemistry" {
    try requireCapturedCoupledSpeciationStage(@embedFile("testdata/ottawa_hour1_layer11_20260909.b64"), true);
}

test "surface charge candidate preserves actual exchange occupancy in captured hour two" {
    try requireCapturedCoupledSpeciationStage(@embedFile("testdata/ottawa_hour2_layer0_20260909.b64"), false);
}

test "coupled aqueous equilibrium preserves the zero-carrier subspace" {
    const encoded = @embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    captured.state.aqueous[0] = std.mem.zeroes(aqueous_network.State);
    captured.state.aqueous[0].hydrogen = 1;
    captured.state.aqueous[0].hydroxide = 1e-8;
    captured.state.aqueous[0].calcium = 0.01;
    captured.state.aqueous[0].carbon_dioxide = 0.01;
    captured.state.aqueous[0].sulfate = 0.01;
    captured.state.non_band_phosphate[0] = std.mem.zeroes(phosphate_network.State);
    captured.state.band_phosphate[0] = std.mem.zeroes(phosphate_network.State);
    captured.state.cation_exchange_mol_per_megagram[0] = std.mem.zeroes(cation_exchange.Cations);
    captured.state.geochemistry_solids[0] = std.mem.zeroes(geochemistry.SolidState);
    captured.state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 0;
    captured.state.water_mol_per_m3[0] = 1000;
    var parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    parameters.cation_exchange_capacity_mol_charge_per_megagram = 0;
    parameters.cation_exchange_parameters.maximum_adsorption_mol_charge_per_m3_step = 0;
    parameters.phosphate_minerals = null;
    parameters.phosphate_surface.maximum_exchange_mol_per_megagram_step = 0;
    parameters.total_carboxyl_sites_mol_per_megagram = 0;
    parameters.carboxyl_exchange_parameters.maximum_exchange_mol_per_m3_per_iteration = 0;
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var initial: [chemistry.State.packedComponentCount()]f64 = undefined;
    var candidate: @TypeOf(initial) = undefined;
    try captured.state.packCell(0, &initial);
    _ = try @import("reaction_surface_minerals.zig").candidate(&scratch, &initial, parameters, 40, &candidate);
    try std.testing.expect(scratch.aqueous[0].calcium_sulfate > 0);
    try std.testing.expectEqualDeep(captured.state.cation_exchange_mol_per_megagram[0], scratch.cation_exchange_mol_per_megagram[0]);
    try std.testing.expectEqualDeep(captured.state.non_band_phosphate[0], scratch.non_band_phosphate[0]);
    try std.testing.expectEqualDeep(captured.state.band_phosphate[0], scratch.band_phosphate[0]);
    try std.testing.expectEqualDeep(captured.state.geochemistry_solids[0], scratch.geochemistry_solids[0]);
    try std.testing.expectEqual(@as(f64, 0), scratch.carboxyl_bound_hydrogen_mol_per_megagram[0]);
    const ledger = @import("reaction_solve.zig");
    try ledger.requireConservedInventories(
        try ledger.acceptedStateInventory(&captured.state, 0, parameters),
        try ledger.acceptedStateInventory(&scratch, 0, parameters),
    );
    try @import("reaction_charge.zig").requireConservedStates(&captured.state, 0, &scratch, 0, parameters);
    // Disabled exchange with nonzero stored material is not the empty
    // precipitation subspace and must not be silently admitted.
    captured.state.cation_exchange_mol_per_megagram[0].calcium = 0.01;
    try captured.state.packCell(0, &initial);
    try std.testing.expectError(error.UnsupportedSurfaceMineralInput, @import("reaction_surface_minerals.zig").candidate(&scratch, &initial, parameters, 40, &candidate));
    parameters.cation_exchange_capacity_mol_charge_per_megagram = 1;
    try std.testing.expectError(error.UnsupportedSurfaceMineralInput, @import("reaction_surface_minerals.zig").candidate(&scratch, &initial, parameters, 40, &candidate));
}

test "complete physical candidate bypasses tighter numerical search targets" {
    const encoded = @embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64");
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var initial: [chemistry.State.packedComponentCount()]f64 = undefined;
    try captured.state.packCell(0, &initial);
    var options = captured.options;
    options.absolute_tolerance_mol_per_m3 = 1e-30;
    options.absolute_tolerance_mol_per_megagram = 1e-30;
    options.relative_tolerance = 1e-24;
    const parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    const solved = try group_solve.solveEquilibriumWithWorkspace(&workspace, &captured.state, 0, parameters, options, null, 0);
    try std.testing.expect(solved.converged);
    try std.testing.expect(solved.maximum_scaled_residual <= 1);
    try std.testing.expect(solved.iterations <= 2);
    try std.testing.expect(workspace.last_search_metric.?.maximum > 1);
    try group_solve.requireAcceptedStateConservation(&workspace.scratch, &captured.state, 0, &initial, parameters);
}

fn requireCapturedCoupledSpeciation(encoded: []const u8) !void {
    return requireCapturedCoupledSpeciationStage(encoded, false);
}

fn requireCapturedCoupledSpeciationStage(encoded: []const u8, after_kinetics: bool) !void {
    const decoder = std.base64.standard.decoderWithIgnore(" \r\n\t");
    const bytes = try std.testing.allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer std.testing.allocator.free(bytes);
    const length = try decoder.decode(bytes, encoded);
    var reader: std.Io.Reader = .fixed(bytes[0..length]);
    var captured = try failure_snapshot.read(std.testing.allocator, &reader);
    defer captured.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var audit = try chemistry.State.init(std.testing.allocator, 1);
    defer audit.deinit();
    var initial: [chemistry.State.packedComponentCount()]f64 = undefined;
    var candidate: @TypeOf(initial) = undefined;
    var residual: @TypeOf(initial) = undefined;
    try captured.state.packCell(0, &initial);
    const parameters = group_solve.equilibriumClosureParameters(captured.parameters);
    if (after_kinetics) {
        _ = try @import("reaction_surface_minerals.zig").candidate(&scratch, &initial, parameters, captured.options.max_iterations, &candidate);
        try captured.state.unpackCell(0, &candidate);
        try group_apply.applyKineticGeochemistryStep(&scratch, &captured.state, 0, captured.parameters, &initial);
        try captured.state.packCell(0, &initial);
    }
    const iterations = try @import("reaction_surface_minerals.zig").candidate(&scratch, &initial, parameters, captured.options.max_iterations, &candidate);
    try group_solve.requireAcceptedStateConservation(&audit, &scratch, 0, &initial, parameters);
    const changes_carrier = try group_evaluate.evaluateAtLoaded(&scratch, &candidate, parameters);
    _ = try group_evaluate.evaluateLoadedReactionBalance(&scratch, changes_carrier, parameters, &residual);
    const quality = try @import("reaction_physical_quality.zig").measure(&scratch, parameters, &residual, .{});
    std.debug.print("coupled surface mineral candidate: iterations={d} full_quality={e} pH={e}\n", .{ iterations, quality.maximum, quality.pH_change });
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    const fluxes = try phosphate_rates.calculate(scratch.aqueous[0], scratch.non_band_phosphate[0], coefficients, parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3, parameters.phosphate_constants, parameters.phosphate_surface, parameters.phosphate_minerals, parameters.phosphate_kinetics);
    inline for (std.meta.fields(phosphate_network.MineralFluxes)) |field| {
        std.debug.print("coupled mineral source {s}={e}\n", .{ field.name, @field(fluxes.minerals, field.name) });
    }
    try std.testing.expect(quality.maximum <= 1);
    var repeated: @TypeOf(initial) = undefined;
    try std.testing.expectEqual(iterations, try @import("reaction_surface_minerals.zig").candidate(&scratch, &initial, parameters, captured.options.max_iterations, &repeated));
    try std.testing.expectEqualSlices(f64, &candidate, &repeated);
    // Successful candidates must not leave coordinates that change the next
    // cold target. This applies to both the primary and recovery entry points.
    const mineral = @import("reaction_surface_minerals.zig");
    var seed: ?mineral.CandidateSeed = null;
    try std.testing.expectEqual(iterations, try mineral.candidateWithSeed(&scratch, &initial, parameters, captured.options.max_iterations, &repeated, &seed));
    try std.testing.expect(seed == null);
    try std.testing.expectEqualSlices(f64, &candidate, &repeated);
    _ = try mineral.euclideanRecoveryCandidateWithSeed(&scratch, &initial, parameters, captured.options.max_iterations, &repeated, &seed);
    try std.testing.expect(seed == null);
    try group_solve.requireAcceptedStateConservation(&audit, &scratch, 0, &initial, parameters);
    // A failed attempt retains work, but its later successful continuation
    // clears that work. Neither attempt may mutate the caller's native state.
    @memset(&repeated, -1);
    try std.testing.expectError(error.SurfaceMineralDidNotConverge, mineral.candidateWithSeed(&scratch, &initial, parameters, 1, &repeated, &seed));
    try std.testing.expect(seed != null);
    for (repeated) |entry| try std.testing.expectEqual(@as(f64, -1), entry);
    _ = try mineral.candidateWithSeed(&scratch, &initial, parameters, captured.options.max_iterations, &repeated, &seed);
    try std.testing.expect(seed == null);
    try group_solve.requireAcceptedStateConservation(&audit, &scratch, 0, &initial, parameters);
    const continued_carrier = try group_evaluate.evaluateAtLoaded(&scratch, &repeated, parameters);
    _ = try group_evaluate.evaluateLoadedReactionBalance(&scratch, continued_carrier, parameters, &residual);
    try std.testing.expect((try @import("reaction_physical_quality.zig").measure(&scratch, parameters, &residual, .{})).maximum <= 1);
    try captured.state.packCell(0, &repeated);
    try std.testing.expectEqualSlices(f64, &initial, &repeated);
    @memset(&candidate, -1);
    try std.testing.expectError(error.SurfaceMineralDidNotConverge, @import("reaction_surface_minerals.zig").candidate(&scratch, &initial, parameters, 1, &candidate));
    for (candidate) |entry| try std.testing.expectEqual(@as(f64, -1), entry);
}

test "examples-ng-prod day-77 ionic strength ridge converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(@embedFile("testdata/ottawa_day77_hour14_layer1_20260909.b64"), false);
}

test "examples-ng-prod STARTE layer-zero snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(@embedFile("testdata/ottawa_starte_layer0_20260909.b64"), false);
}

test "examples-ng-prod hourly layer-eleven snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(@embedFile("testdata/ottawa_hour1_layer11_20260909.b64"), false);
}

test "examples-ng-prod hour-two topsoil snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(@embedFile("testdata/ottawa_hour2_layer0_20260909.b64"), false);
}

test "examples-ng-prod hour-one calcium snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(
        @embedFile("testdata/examples_ng_prod_hour1_calcium_failure.b64"),
        false,
    );
}

test "examples-ng-prod terminal layer-three snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(
        @embedFile("testdata/examples_ng_prod_hour1_layer3_failure.b64"),
        false,
    );
}

test "examples-ng-prod terminal layer-one snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(
        @embedFile("testdata/examples_ng_prod_hour1_layer1_failure.b64"),
        false,
    );
}

test "examples-ng-prod terminal layer-two 3a51 snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(
        @embedFile("testdata/examples_ng_prod_hour1_layer2_3a51_failure.b64"),
        false,
    );
}

test "examples-ng-prod layer-three 9ee9 ridge snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(
        @embedFile("testdata/examples_ng_prod_hour1_layer3_9ee9_failure.b64"),
        false,
    );
}

test "examples-ng-prod layer-seven 5d50 carbonate ridge converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(
        @embedFile("testdata/examples_ng_prod_hour1_layer7_5d50_failure.b64"),
        false,
    );
}

test "examples-ng-prod terminal layer-six snapshot converges deterministically within source ceiling" {
    try requireCapturedExamplesNgProdConvergence(
        @embedFile("testdata/examples_ng_prod_hour1_layer6_failure.b64"),
        true,
    );
}

test "complete tiers prefer iter0 boundary Newton before normal Anderson" {
    const captured_current_merit = 4.375468808956227e9;
    const captured_normal_anderson_merit = 5.2564471288685757e8;
    const captured_boundary_newton_merit = 1.7628610373890203e8;
    try std.testing.expect(group_network.meaningfulNewtonMeritDecrease(
        captured_current_merit,
        captured_boundary_newton_merit,
    ));
    try std.testing.expect(
        captured_boundary_newton_merit < captured_normal_anderson_merit,
    );

    var best_state = [_]f64{0};
    var best_residual = [_]f64{0};
    var best_norm: f64 = captured_current_merit;
    var best_kind: group_types.CandidateKind = .none;
    var best_is_picard = true;
    try std.testing.expect(group_solve.retainMeaningfulCandidate(
        captured_current_merit,
        &best_state,
        &best_residual,
        &best_norm,
        &best_kind,
        &best_is_picard,
        &.{1},
        &.{1},
        captured_boundary_newton_merit,
        .full_network_newton,
        false,
    ));
    try std.testing.expect(!group_solve.andersonTierEnabled(
        best_kind,
        captured_current_merit,
        best_norm,
        60,
    ));
    try std.testing.expectEqual(
        group_types.CandidateKind.full_network_newton,
        best_kind,
    );
    try std.testing.expect(!best_is_picard);
}

test "Newton tier keeps merit lexicography and candidate accounting" {
    const current_merit = 1.0e6;
    var best_state = [_]f64{0};
    var best_residual = [_]f64{0};
    var best_norm: f64 = current_merit;
    var best_kind: group_types.CandidateKind = .none;
    var best_is_picard = true;
    try std.testing.expect(group_solve.retainMeaningfulCandidate(
        current_merit,
        &best_state,
        &best_residual,
        &best_norm,
        &best_kind,
        &best_is_picard,
        &.{1},
        &.{1},
        5.0e5,
        .full_network_newton,
        false,
    ));
    try std.testing.expect(!group_solve.retainMeaningfulCandidate(
        current_merit,
        &best_state,
        &best_residual,
        &best_norm,
        &best_kind,
        &best_is_picard,
        &.{2},
        &.{2},
        5.0e5,
        .coordinate_newton,
        false,
    ));
    try std.testing.expectEqualSlices(f64, &.{1}, &best_state);
    try std.testing.expectEqual(
        group_types.CandidateKind.full_network_newton,
        best_kind,
    );
    for ([_]group_types.CandidateKind{
        .anderson_depth_two,
        .anderson_depth_one,
        .coordinate_anderson,
    }) |kind| try std.testing.expect(group_solve.candidateCountsAsPicard(kind));
    for ([_]group_types.CandidateKind{
        .full_network_newton,
        .inventory_boundary_newton,
        .phosphate_extent_newton,
        .directional_newton,
        .coordinate_newton,
    }) |kind| try std.testing.expect(!group_solve.candidateCountsAsPicard(kind));
}

test "global candidate pricing selects best merit and preserves source-order ties" {
    var best_state = [_]f64{ 0, 0 };
    var best_residual = [_]f64{ 0, 0 };
    var best_norm: f64 = 100;
    var best_kind: group_types.CandidateKind = .none;
    var best_is_picard = false;
    try std.testing.expect(group_solve.retainBetterCandidate(
        &best_state,
        &best_residual,
        &best_norm,
        &best_kind,
        &best_is_picard,
        &.{ 1, 1 },
        &.{ 9, 9 },
        99,
        .full_network_newton,
        false,
    ));
    try std.testing.expect(group_solve.retainBetterCandidate(
        &best_state,
        &best_residual,
        &best_norm,
        &best_kind,
        &best_is_picard,
        &.{ 2, 2 },
        &.{ 2, 2 },
        20,
        .anderson_depth_one,
        true,
    ));
    try std.testing.expect(!group_solve.retainBetterCandidate(
        &best_state,
        &best_residual,
        &best_norm,
        &best_kind,
        &best_is_picard,
        &.{ 3, 3 },
        &.{ 3, 3 },
        20,
        .coordinate_anderson,
        true,
    ));
    try std.testing.expectEqual(@as(f64, 20), best_norm);
    try std.testing.expectEqual(group_types.CandidateKind.anderson_depth_one, best_kind);
    try std.testing.expect(best_is_picard);
    try std.testing.expectEqualSlices(f64, &.{ 2, 2 }, &best_state);
}

test "current-sign coordinate seed is clipped and only Anderson can escape" {
    try std.testing.expectEqual(
        @as(f64, 0.4),
        group_network.currentSignClippedNativeExtent(3, 2, -0.5, 0.2),
    );
    try std.testing.expectEqual(
        @as(f64, -0.5),
        group_network.currentSignClippedNativeExtent(-3, 2, -0.25, 0.5),
    );
    const current = [_]f64{ 0, 2 };
    const current_defect = [_]f64{ 0.1, -0.2 };
    const coordinate_seed = [_]f64{ 0.05, 1.9 };
    const seed_defect = [_]f64{ 0.09, -0.18 };
    var accelerated: [2]f64 = undefined;
    try std.testing.expect(numerics.andersonDepthOneCandidate(
        &current,
        &current_defect,
        &coordinate_seed,
        &seed_defect,
        &accelerated,
    ));
    try std.testing.expect(!std.mem.eql(f64, &coordinate_seed, &accelerated));
    var selected = [_]f64{ 0, 0 };
    var selected_residual = [_]f64{ 0, 0 };
    var selected_norm: f64 = 10;
    var selected_kind: group_types.CandidateKind = .none;
    var selected_is_picard = false;
    try std.testing.expect(group_solve.retainBetterCandidate(
        &selected,
        &selected_residual,
        &selected_norm,
        &selected_kind,
        &selected_is_picard,
        &accelerated,
        &.{ 0.01, -0.01 },
        1,
        .coordinate_anderson,
        true,
    ));
    try std.testing.expectEqualSlices(f64, &accelerated, &selected);
    try std.testing.expect(!std.mem.eql(f64, &coordinate_seed, &selected));
    try std.testing.expect(group_network.meaningfulNewtonMeritDecrease(
        1.0e8,
        1.0e8 - 50,
    ));
}

test "coordinate Anderson rebuilds current carrier after private boundary poison" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.aqueous[0].hydrogen = 0.25;
    state.aqueous[0].hydroxide = 4;
    state.non_band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 0.5;
    state.water_mol_per_m3[0] = 100;
    const parameters: chemistry.ReactionParameters = .{
        .fractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 },
        .non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1,
        .band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1,
        .cation_exchange_capacity_mol_charge_per_megagram = 10,
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 1, .ammonium_band_megagrams_per_m3 = 1 },
        .total_carboxyl_sites_mol_per_megagram = 1,
        .carboxyl_exchange_parameters = .{ .dissociation_constant_mol_per_m3 = 0.01, .maximum_exchange_mol_per_m3_per_iteration = 0, .substrate_limit_fraction_per_iteration = 0.2 },
        .aqueous_constants = group_numerics2.filled(aqueous_rates.EquilibriumConstants, 1),
        .aqueous_kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_fast_association_mol_per_m3_step = 0, .maximum_slow_association_mol_per_m3_step = 0 },
        .phosphate_constants = group_numerics2.filled(phosphate_rates.EquilibriumConstants, 1),
        .phosphate_surface = .{ .protonated_site_equilibrium_constant = 1, .hydroxyl_site_equilibrium_constant = 1, .h2po4_exchange_equilibrium_constant = 1, .hpo4_exchange_equilibrium_constant = 1, .water_activity_product_mol2_per_m6 = 1, .h2po4_dissociation_constant = 1, .maximum_exchange_mol_per_megagram_step = 0, .substrate_limit_fraction = 0.2 },
        .phosphate_minerals = null,
        .phosphate_kinetics = .{ .substrate_limit_fraction = 0.2, .maximum_pairing_mol_per_m3_step = 0 },
        .cation_exchange_parameters = .{ .selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, .substrate_limit_fraction = 0.2, .maximum_adsorption_mol_charge_per_m3_step = 0 },
        .geochemistry_products = group_numerics2.filled(geochemistry_rates.SolubilityProducts, 1),
        .geochemistry_kinetics = .{ .general_substrate_limit_fraction = 0.2, .hydrogen_coupled_substrate_limit_fraction = 0.2, .maximum_hydroxide_mineral_mol_per_m3_step = 0, .maximum_general_mineral_mol_per_m3_step = 0, .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1, .maximum_natural_weathering_mol_per_m3_step = 0, .maximum_ground_weathering_mol_per_m3_step = 0 },
        .water_activity_product_mol2_per_m6 = 1,
        .negligible_water_ion_concentration_mol_per_m3 = 1e-32,
    };
    const options: group_types.Options = .{};
    const count = comptime chemistry.State.packedComponentCount();
    var current: [count]f64 = undefined;
    try state.packCell(0, &current);
    const original_current = current;
    var scratch_pristine = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch_pristine.deinit();
    var scratch_poisoned = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch_poisoned.deinit();
    const transformations = try group_evaluate.evaluateAt(
        &scratch_pristine,
        &current,
        parameters,
    );
    var scratch_prepared = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch_prepared.deinit();
    try scratch_prepared.unpackCell(0, &current);
    const prepared_coefficients = try scratch_prepared.activityCoefficients(
        0,
        parameters.fractions,
    );
    const prepared_transformations =
        try group_evaluate.evaluateLoadedAtWithMonovalentActivityCoefficient(
            &scratch_prepared,
            parameters,
            prepared_coefficients.monovalent_activity_coefficient,
        );
    try std.testing.expectEqualDeep(
        transformations,
        prepared_transformations,
    );
    var public_loaded_state: [count]f64 = undefined;
    var prepared_loaded_state: [count]f64 = undefined;
    try scratch_pristine.packCell(0, &public_loaded_state);
    try scratch_prepared.packCell(0, &prepared_loaded_state);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&public_loaded_state),
        std.mem.asBytes(&prepared_loaded_state),
    );
    var residual: [count]f64 = undefined;
    try group_evaluate.evaluateGlobalResidualAt(
        &scratch_pristine,
        &current,
        parameters,
        &residual,
    );
    const current_norm = try group_numerics.scaledNorm(
        &current,
        &residual,
        options,
    );

    var pristine = try group_types.Workspace.init(std.testing.allocator);
    defer pristine.deinit();
    var poisoned = try group_types.Workspace.init(std.testing.allocator);
    defer poisoned.deinit();
    // Model a boundary helper's private carrier: different active axes,
    // signs, extent scales, and one-sided boxes than `current`.
    @memset(poisoned.reaction_span_rates, -777);
    poisoned.reaction_span_active_count = 2;
    poisoned.reaction_span_active_reactions[0] =
        reaction_span.non_band_phosphate_surface_offset + 1;
    poisoned.reaction_span_active_reactions[1] =
        reaction_span.non_band_phosphate_surface_offset + 3;
    poisoned.reaction_span_extent_scales[0] = 123;
    poisoned.reaction_span_extent_scales[1] = 456;
    poisoned.reaction_span_lower_bounds[0] = -0.125;
    poisoned.reaction_span_lower_bounds[1] = 0;
    poisoned.reaction_span_upper_bounds[0] = 0;
    poisoned.reaction_span_upper_bounds[1] = 0.25;
    @memset(poisoned.rollback_state, -999999);
    var poisoned_rollback: [count]f64 = undefined;
    @memcpy(&poisoned_rollback, poisoned.rollback_state[0..count]);

    var pristine_seed: [count]f64 = undefined;
    var pristine_candidate = [_]f64{-333} ** count;
    var pristine_candidate_residual = [_]f64{-444} ** count;
    const pristine_result = try group_network.tryCurrentSignCoordinateAndersonCandidate(
        &pristine,
        &scratch_pristine,
        &current,
        &residual,
        transformations,
        &pristine_seed,
        &pristine_candidate,
        &pristine_candidate_residual,
        parameters,
        options,
        current_norm,
    );
    var poisoned_seed: [count]f64 = undefined;
    var poisoned_candidate = [_]f64{-333} ** count;
    var poisoned_candidate_residual = [_]f64{-444} ** count;
    const poisoned_result = try group_network.tryCurrentSignCoordinateAndersonCandidate(
        &poisoned,
        &scratch_poisoned,
        &current,
        &residual,
        transformations,
        &poisoned_seed,
        &poisoned_candidate,
        &poisoned_candidate_residual,
        parameters,
        options,
        current_norm,
    );
    try std.testing.expectEqual(pristine_result, poisoned_result);
    try std.testing.expectEqualSlices(f64, &pristine_candidate, &poisoned_candidate);
    try std.testing.expectEqualSlices(
        f64,
        &pristine_candidate_residual,
        &poisoned_candidate_residual,
    );
    try std.testing.expectEqual(pristine.reaction_span_active_count, poisoned.reaction_span_active_count);
    const active_count = pristine.reaction_span_active_count;
    try std.testing.expectEqualSlices(
        usize,
        pristine.reaction_span_active_reactions[0..active_count],
        poisoned.reaction_span_active_reactions[0..active_count],
    );
    try std.testing.expectEqualSlices(
        f64,
        pristine.reaction_span_extent_scales[0..active_count],
        poisoned.reaction_span_extent_scales[0..active_count],
    );
    try std.testing.expectEqualSlices(f64, &original_current, &current);
    try std.testing.expectEqualSlices(
        f64,
        &poisoned_rollback,
        poisoned.rollback_state[0..count],
    );
    try std.testing.expect(group_solve.candidateCountsAsPicard(.coordinate_anderson));

    if (poisoned_result) {
        var accepted = try chemistry.State.init(std.testing.allocator, 1);
        defer accepted.deinit();
        try accepted.unpackCell(0, &poisoned_candidate);
        try std.testing.expectApproxEqAbs(
            group_numerics2.inorganicCarbonMolPerM3(&state, 0),
            group_numerics2.inorganicCarbonMolPerM3(&accepted, 0),
            64 * std.math.floatEps(f64),
        );
        var charge_before: f64 = 0;
        var charge_after: f64 = 0;
        inline for (std.meta.fields(cation_exchange.Cations)) |field| {
            const valence: f64 = if (comptime std.mem.eql(u8, field.name, "aluminum") or
                std.mem.eql(u8, field.name, "iron"))
                3
            else if (comptime std.mem.eql(u8, field.name, "calcium") or
                std.mem.eql(u8, field.name, "magnesium"))
                2
            else
                1;
            charge_before += valence *
                @field(state.cation_exchange_mol_per_megagram[0], field.name);
            charge_after += valence *
                @field(accepted.cation_exchange_mol_per_megagram[0], field.name);
        }
        try std.testing.expectApproxEqAbs(
            charge_before,
            charge_after,
            64 * std.math.floatEps(f64) * @max(1.0, @abs(charge_before)),
        );
    }
}

test "production Gapon coordinate Newton is bounded globally priced and source ordered" {
    const captured_current_merit = 2.0963454539191803e8;
    const captured_exact_merit = 2.0963074406979015e8;
    const captured_h_rhs = -2.0963454539191803e8;
    const captured_positive_gapon_h_derivative = -2.9763538033183508e7;
    const captured_positive_physical_bound = 4.900286851041021e-2;
    const normalized_extent = group_network.clampedScalarCoordinateNewtonExtent(
        captured_h_rhs,
        captured_positive_gapon_h_derivative,
        0,
        captured_positive_physical_bound,
    );
    try std.testing.expectApproxEqAbs(
        captured_positive_physical_bound,
        normalized_extent,
        1e-15,
    );
    try std.testing.expectEqual(
        @as(f64, 1.0 / 256.0),
        group_network.coordinateNewtonBacktrackingFraction(1, 8),
    );
    try std.testing.expect(@as(u8, 8) <
        group_network.coordinate_newton_backtracking_trials);
    try std.testing.expect(group_network.meaningfulNewtonMeritDecrease(
        captured_current_merit,
        captured_exact_merit,
    ));
    try std.testing.expect(!group_network.coordinateNewtonPricePrecedes(
        captured_exact_merit,
        reaction_span.gapon_reaction_offset,
        captured_exact_merit,
        28,
    ));
    try std.testing.expect(group_network.coordinateNewtonPricePrecedes(
        captured_exact_merit,
        28,
        captured_exact_merit,
        reaction_span.gapon_reaction_offset,
    ));

    var selected = [_]f64{0};
    var selected_residual = [_]f64{0};
    var selected_norm: f64 = captured_current_merit;
    var selected_kind: group_types.CandidateKind = .none;
    var selected_is_picard = true;
    try std.testing.expect(group_solve.retainBetterCandidate(
        &selected,
        &selected_residual,
        &selected_norm,
        &selected_kind,
        &selected_is_picard,
        &.{1},
        &.{1},
        captured_exact_merit,
        .coordinate_newton,
        false,
    ));
    try std.testing.expectEqual(
        group_types.CandidateKind.coordinate_newton,
        selected_kind,
    );
    try std.testing.expect(!selected_is_picard);
}

test "production iter26 bounded two-axis Newton is exact and source ordered" {
    const hydroxyl_to_deprotonated_reaction =
        reaction_span.non_band_phosphate_surface_offset + 1;
    const hydrogen_protonation_reaction = reaction_span.carboxyl_reaction_index;
    try std.testing.expectEqual(@as(usize, 31), hydroxyl_to_deprotonated_reaction);
    try std.testing.expectEqual(@as(usize, 71), hydrogen_protonation_reaction);
    try std.testing.expectEqualStrings(
        "hydroxyl_to_deprotonated_site_mol_per_megagram",
        reaction_span.reactionIdentity(hydroxyl_to_deprotonated_reaction).?.name,
    );
    try std.testing.expectEqualStrings(
        "hydrogen_protonation",
        reaction_span.reactionIdentity(hydrogen_protonation_reaction).?.name,
    );

    const captured_extent_a = -4.1614420850278444e-1;
    const captured_extent_b = 1.5;
    const extents = group_network.boundedTwoAxisLeastSquares(
        1,
        0,
        1,
        captured_extent_a,
        2,
        -1.5,
        0,
        0,
        captured_extent_b,
    );
    try std.testing.expectApproxEqAbs(captured_extent_a, extents[0], 1e-15);
    try std.testing.expectApproxEqAbs(captured_extent_b, extents[1], 1e-15);
    try std.testing.expectEqual(
        @as(f64, 1),
        group_network.coordinateNewtonBacktrackingFraction(1, 0),
    );
    try std.testing.expect(group_network.meaningfulNewtonMeritDecrease(
        2.0849500887407154e8,
        1.36491986946402e8,
    ));
    try std.testing.expectEqual(
        @as(usize, 112),
        group_network.two_axis_newton_max_face_pairs,
    );

    try std.testing.expect(group_network.twoAxisNewtonColumnRankPrecedes(
        10,
        hydroxyl_to_deprotonated_reaction,
        10,
        hydrogen_protonation_reaction,
    ));
    try std.testing.expect(!group_network.twoAxisNewtonColumnRankPrecedes(
        10,
        hydrogen_protonation_reaction,
        10,
        hydroxyl_to_deprotonated_reaction,
    ));
    try std.testing.expect(group_network.twoAxisNewtonPricePrecedes(
        1.36491986946402e8,
        hydroxyl_to_deprotonated_reaction,
        hydrogen_protonation_reaction,
        -1,
        1,
        1.36491986946402e8,
        hydroxyl_to_deprotonated_reaction,
        hydrogen_protonation_reaction + 1,
        -1,
        1,
    ));
    try std.testing.expect(!group_network.twoAxisNewtonPricePrecedes(
        1.36491986946402e8,
        hydroxyl_to_deprotonated_reaction,
        hydrogen_protonation_reaction,
        -1,
        1,
        1.36491986946402e8,
        hydroxyl_to_deprotonated_reaction,
        hydrogen_protonation_reaction,
        -1,
        1,
    ));
}

test "production iter34 active-row Newton is conservative bounded and ceiling-accounted" {
    const h2po4_hydroxyl =
        reaction_span.non_band_phosphate_surface_offset + 3;
    const hpo4_hydroxyl =
        reaction_span.non_band_phosphate_surface_offset + 4;
    try std.testing.expectEqual(@as(usize, 33), h2po4_hydroxyl);
    try std.testing.expectEqual(@as(usize, 34), hpo4_hydroxyl);
    try std.testing.expectEqualStrings(
        "h2po4_with_hydroxyl_site_mol_p_per_megagram",
        reaction_span.reactionIdentity(h2po4_hydroxyl).?.name,
    );
    try std.testing.expectEqualStrings(
        "hpo4_with_hydroxyl_site_mol_p_per_megagram",
        reaction_span.reactionIdentity(hpo4_hydroxyl).?.name,
    );

    const options: group_types.Options = .{};
    var current = [_]f64{1} ** 43;
    var residual = [_]f64{0} ** 43;
    current[5] = 1.093521223583531e1;
    residual[5] = -3.9516422609158957;
    current[42] = 3.613715223162189e-1;
    residual[42] = -3.6137152231598446e-1;
    try std.testing.expectEqualStrings(
        "aqueous.hydroxide",
        chemistry.State.packedComponentName(5).?,
    );
    try std.testing.expectEqualStrings(
        "phosphate_non_band.dissolved_hpo4_mol_p_per_m3",
        chemistry.State.packedComponentName(42).?,
    );
    try std.testing.expect(!chemistry.State.packedComponentIsMolPerMegagram(5));
    try std.testing.expect(!chemistry.State.packedComponentIsMolPerMegagram(42));
    const row_5_scaled = @abs(residual[5]) /
        group_numerics.residualScale(current[5], 5, options);
    const row_42_scaled = @abs(residual[42]) /
        group_numerics.residualScale(current[42], 42, options);
    // SOLUTE.f:822 enters its fixed MRXN source-order iteration. The modern
    // active-row Newton is a safeguarded replacement: normalized magnitude
    // selects the active two-row set, then those rows execute in stable packed
    // source order. With the corrected trace-inventory scale, row 42 is about
    // 2.76 times worse than row 5, proving selection is not based on row order.
    try std.testing.expect(row_42_scaled > row_5_scaled);
    try std.testing.expectEqual(
        [2]usize{ 5, 42 },
        group_network.topTwoScaledResidualRows(
            &current,
            &residual,
            options,
        ).?,
    );
    // Exact ties retain packed/source row order.
    try std.testing.expectEqual(
        [2]usize{ 0, 1 },
        group_network.topTwoScaledResidualRows(
            &.{ 1, 1, 1 },
            &.{ 1, -1, 0.5 },
            .{ .absolute_tolerance_mol_per_m3 = 1, .absolute_tolerance_mol_per_megagram = 1, .relative_tolerance = 0 },
        ).?,
    );

    const normalized_extents = group_network.boundedTwoAxisLeastSquares(
        1,
        0,
        1,
        5.591329194590798e-1,
        7.374537790771363e-2,
        0,
        1.5,
        0,
        1.5,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 5.591329194590798e-1),
        normalized_extents[0],
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 7.374537790771363e-2),
        normalized_extents[1],
        1e-15,
    );
    const captured_fraction = 1.0 / 32768.0;
    try std.testing.expectEqual(
        captured_fraction,
        group_network.coordinateNewtonBacktrackingFraction(1, 15),
    );
    const current_merit = 3.613682626372376e7;
    const captured_exact_merit = 3.613674267480826e7;
    try std.testing.expect(group_network.meaningfulNewtonMeritDecrease(
        current_merit,
        captured_exact_merit,
    ));
    try std.testing.expect(!group_network.twoAxisNewtonPricePrecedes(
        captured_exact_merit,
        h2po4_hydroxyl,
        hpo4_hydroxyl,
        1,
        1,
        captured_exact_merit,
        h2po4_hydroxyl,
        hpo4_hydroxyl,
        1,
        -1,
    ));

    const effective_h2po4_extent = 1.0541930068935173e-6;
    const effective_hpo4_extent = 1.4854095691565595e-6;
    var parameters: chemistry.ReactionParameters = undefined;
    parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1;
    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    const current_transformations = std.mem.zeroes(chemistry.CellTransformations);
    try reaction_span.addReactionExtent(
        &transformations,
        h2po4_hydroxyl,
        effective_h2po4_extent,
        current_transformations,
        parameters,
    );
    try reaction_span.addReactionExtent(
        &transformations,
        hpo4_hydroxyl,
        effective_hpo4_extent,
        current_transformations,
        parameters,
    );
    const phosphate = transformations.non_band_phosphate;
    const phosphorus_delta = phosphate.dissolved_po4_mol_p_per_m3 +
        phosphate.dissolved_hpo4_mol_p_per_m3 +
        phosphate.dissolved_h2po4_mol_p_per_m3 +
        phosphate.dissolved_h3po4_mol_p_per_m3 +
        phosphate.adsorbed_hpo4_mol_p_per_megagram +
        phosphate.adsorbed_h2po4_mol_p_per_megagram;
    const site_delta = phosphate.deprotonated_site_mol_per_megagram +
        phosphate.hydroxyl_site_mol_per_megagram +
        phosphate.protonated_site_mol_per_megagram +
        phosphate.adsorbed_hpo4_mol_p_per_megagram +
        phosphate.adsorbed_h2po4_mol_p_per_megagram;
    try std.testing.expectApproxEqAbs(@as(f64, 0), phosphorus_delta, 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 0), site_delta, 1e-18);
    const captured_inventory_fraction = 6.666666666692436e-1;
    try std.testing.expect(captured_inventory_fraction > 0 and
        captured_inventory_fraction <= 1);

    try std.testing.expectEqual(
        @as(usize, 59582),
        group_network.activeRowNewtonWorstCaseProbeCount(31),
    );
    try std.testing.expectEqual(
        @as(usize, 94926),
        group_network.activeRowNewtonWorstCaseProbeCount(39),
    );
    var best_state = [_]f64{0};
    var best_residual = [_]f64{0};
    var best_norm: f64 = current_merit;
    var best_kind: group_types.CandidateKind = .none;
    var best_is_picard = true;
    const accepted = group_solve.retainMeaningfulCandidate(
        current_merit,
        &best_state,
        &best_residual,
        &best_norm,
        &best_kind,
        &best_is_picard,
        &.{1},
        &.{1},
        captured_exact_merit,
        .coordinate_newton,
        false,
    );
    try std.testing.expect(accepted);
    try std.testing.expectEqual(
        group_types.CandidateKind.coordinate_newton,
        best_kind,
    );
    try std.testing.expect(!best_is_picard);
    const hard_ceiling: u16 = 1;
    const accepted_promotions: u16 = if (accepted) 1 else 0;
    try std.testing.expect(accepted_promotions <= hard_ceiling);
    try std.testing.expect(!group_solve.andersonTierEnabled(
        best_kind,
        current_merit,
        best_norm,
        hard_ceiling - accepted_promotions,
    ));
}

test "active-row Newton stops only at the owning solver acceptance gate" {
    try std.testing.expect(group_network.activeRowCandidateAcceptable(0));
    try std.testing.expect(group_network.activeRowCandidateAcceptable(1));
    try std.testing.expect(!group_network.activeRowCandidateAcceptable(1.0000000000000002));
    try std.testing.expect(!group_network.activeRowCandidateAcceptable(std.math.inf(f64)));
    try std.testing.expect(!group_network.activeRowCandidateAcceptable(std.math.nan(f64)));
}

test "rate-ranked coordinate head norm gate preserves complete-search fallback" {
    const default_options: group_types.Options = .{};
    try std.testing.expect(group_network.shouldTryRateRankedCoordinateNewtonHead(
        default_options,
        1.0e300,
    ));
    const startup_options: group_types.Options = .{
        .rate_ranked_coordinate_head_maximum_norm = 1.0e8,
    };
    try std.testing.expect(group_network.shouldTryRateRankedCoordinateNewtonHead(
        startup_options,
        1.0e8,
    ));
    try std.testing.expect(!group_network.shouldTryRateRankedCoordinateNewtonHead(
        startup_options,
        1.0e8 + 1,
    ));
    try std.testing.expect(!group_network.shouldTryRateRankedCoordinateNewtonHead(
        startup_options,
        std.math.inf(f64),
    ));
}

test "active-row recovery patience ignores floating-point noise" {
    try std.testing.expect(group_network.activeRowSearchMateriallyImproves(std.math.inf(f64), 100));
    try std.testing.expect(group_network.activeRowSearchMateriallyImproves(100, 99.999));
    const floor = std.math.sqrt(std.math.floatEps(f64)) * 100;
    try std.testing.expect(!group_network.activeRowSearchMateriallyImproves(100, 100 - floor));
    try std.testing.expect(!group_network.activeRowSearchMateriallyImproves(100, std.math.inf(f64)));
    try std.testing.expect(!group_network.activeRowSearchMateriallyImproves(100, std.math.nan(f64)));
}

test "line-search publication restores inorganic carbon roundoff" {
    const count = comptime chemistry.State.packedComponentCount();
    var current = [_]f64{0} ** count;
    const carbon_dioxide = group_numerics2.aqueousPackedIndex("carbon_dioxide");
    const carbonate = group_numerics2.aqueousPackedIndex("carbonate");
    const bicarbonate = group_numerics2.aqueousPackedIndex("bicarbonate");
    current[carbon_dioxide] = 2.3244309497602353e-2;
    current[carbonate] = 1e-6;
    current[count - 1] = 5.5555555555555555e4;
    var interpolated = current;
    interpolated[carbon_dioxide] -= 1e-2 + 2.6448981893523182e-12;
    interpolated[bicarbonate] += 1e-2;

    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    try group_evaluate.restoreInterpolatedInorganicCarbon(
        &scratch,
        &current,
        &interpolated,
    );
    try scratch.unpackCell(0, &current);
    const before = group_numerics2.inorganicCarbonMolPerM3(&scratch, 0);
    try scratch.unpackCell(0, &interpolated);
    const after = group_numerics2.inorganicCarbonMolPerM3(&scratch, 0);
    try std.testing.expectApproxEqAbs(
        before,
        after,
        8 * std.math.floatEps(f64) * before,
    );
    try std.testing.expect(interpolated[carbon_dioxide] >= 0);
}

test "line-search publication restores phosphate affine roundoff" {
    var parameters = acceptedStateConservationTestParameters();
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.non_band_phosphate[0].dissolved_hpo4_mol_p_per_m3 = 2.5e-3;
    state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 4.0e-3;
    state.band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 1.0e-3;
    state.water_mol_per_m3[0] = 5.5555555555555555e4;
    parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1;
    parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1;

    const count = comptime chemistry.State.packedComponentCount();
    var current: [count]f64 = undefined;
    try state.packCell(0, &current);
    var interpolated = current;
    const aqueous_count = @typeInfo(aqueous_network.State).@"struct".fields.len;
    const h2po4_index = aqueous_count + std.meta.fieldIndex(
        phosphate_network.State,
        "dissolved_h2po4_mol_p_per_m3",
    ).?;
    interpolated[h2po4_index] -= 3.8071976127262985e-14;

    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    try group_evaluate.restoreInterpolatedPhosphorus(
        &scratch,
        &current,
        &interpolated,
        parameters,
    );
    try scratch.unpackCell(0, &current);
    const before = parameters.fractions.phosphate_non_band *
        try phosphate_network.phosphorusInventory(
            scratch.non_band_phosphate[0],
            parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        ) + parameters.fractions.phosphate_band *
        try phosphate_network.phosphorusInventory(
            scratch.band_phosphate[0],
            parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        );
    try scratch.unpackCell(0, &interpolated);
    const after = parameters.fractions.phosphate_non_band *
        try phosphate_network.phosphorusInventory(
            scratch.non_band_phosphate[0],
            parameters.non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        ) + parameters.fractions.phosphate_band *
        try phosphate_network.phosphorusInventory(
            scratch.band_phosphate[0],
            parameters.band_phosphate_soil_mass_per_water_volume_megagrams_per_m3,
        );
    try std.testing.expectEqual(before, after);
}

test "production iter74 private surface boundary recovers only priced Anderson composite" {
    const hydroxyl_to_deprotonated =
        reaction_span.non_band_phosphate_surface_offset + 1;
    const h2po4_with_hydroxyl =
        reaction_span.non_band_phosphate_surface_offset + 3;
    try std.testing.expectEqual(@as(usize, 31), hydroxyl_to_deprotonated);
    try std.testing.expectEqual(@as(usize, 33), h2po4_with_hydroxyl);
    try std.testing.expectEqualStrings(
        "hydroxyl_to_deprotonated_site_mol_per_megagram",
        reaction_span.reactionIdentity(hydroxyl_to_deprotonated).?.name,
    );
    try std.testing.expectEqualStrings(
        "h2po4_with_hydroxyl_site_mol_p_per_megagram",
        reaction_span.reactionIdentity(h2po4_with_hydroxyl).?.name,
    );

    const r31_extent = group_network.activeBoundarySurfaceNativeExtent(
        1.488518736380827e-5,
        0,
        1.8136721453134122e1,
    );
    const r33_extent = group_network.activeBoundarySurfaceNativeExtent(
        6.355793452855267e-2,
        0,
        6.95164908906045e-2,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.8136721453134122e1),
        r31_extent,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 6.95164908906045e-2),
        r33_extent,
        1e-15,
    );
    try std.testing.expectEqual(
        @as(usize, 5),
        group_network.active_boundary_surface_axis_limit,
    );
    try std.testing.expectEqual(
        @as(usize, 15),
        group_network.active_boundary_surface_combination_limit,
    );

    const current_merit = 7.093465348075375e7;
    const private_boundary_merit = 3.232887912943802e8;
    const recovered_merit = 1.8305767833325703e7;
    try std.testing.expect(private_boundary_merit > current_merit);
    try std.testing.expectEqual(
        @as(f64, 0.5),
        group_network.coordinateNewtonBacktrackingFraction(1, 1),
    );
    try std.testing.expect(group_network.meaningfulNewtonMeritDecrease(
        current_merit,
        recovered_merit,
    ));

    var selected_state = [_]f64{0};
    var selected_residual = [_]f64{0};
    var selected_norm: f64 = current_merit;
    var selected_kind: group_types.CandidateKind = .none;
    var selected_is_picard = false;
    // The worse private boundary has no publication route.
    try std.testing.expect(!group_solve.retainBetterCandidate(
        &selected_state,
        &selected_residual,
        &selected_norm,
        &selected_kind,
        &selected_is_picard,
        &.{1},
        &.{1},
        private_boundary_merit,
        .full_network_newton,
        false,
    ));
    // Only the recovered, exactly repriced Anderson composite may publish.
    try std.testing.expect(group_solve.retainBetterCandidate(
        &selected_state,
        &selected_residual,
        &selected_norm,
        &selected_kind,
        &selected_is_picard,
        &.{2},
        &.{2},
        recovered_merit,
        .anderson_depth_one,
        true,
    ));
    try std.testing.expectEqual(
        group_types.CandidateKind.anderson_depth_one,
        selected_kind,
    );
    try std.testing.expect(selected_is_picard);
    const recovery_kind: group_network.ActiveBoundaryRecoveryKind = .anderson;
    try std.testing.expectEqual(
        group_network.ActiveBoundaryRecoveryKind.anderson,
        recovery_kind,
    );
}

test "primary FePO4 HAp and protonated-site faces cannot use opposite derivatives" {
    const reactions = [_]usize{ 26, 28, 30 };
    const captured_rates = [_]f64{
        -3.982330454092011e-1,
        -1.886,
        1.2121937276411553e-2,
    };
    try std.testing.expectEqualStrings(
        "iron_phosphate_mol_per_m3",
        reaction_span.reactionIdentity(reactions[0]).?.name,
    );
    try std.testing.expectEqualStrings(
        "hydroxyapatite_mol_per_m3",
        reaction_span.reactionIdentity(reactions[1]).?.name,
    );
    try std.testing.expectEqualStrings(
        "protonated_to_hydroxyl_site_mol_per_megagram",
        reaction_span.reactionIdentity(reactions[2]).?.name,
    );
    for (captured_rates) |rate| {
        const primary = group_network.primaryCurrentFaceBounds(
            rate,
            -1.5,
            1.5,
        );
        if (rate < 0) {
            try std.testing.expectEqual(@as(f64, 0), primary.upper);
            try std.testing.expect(primary.lower < 0);
        } else {
            try std.testing.expectEqual(@as(f64, 0), primary.lower);
            try std.testing.expect(primary.upper > 0);
        }
    }
    var priced_state = [_]f64{0};
    var priced_residual = [_]f64{0};
    var priced_norm: f64 = 10;
    var priced_kind: group_types.CandidateKind = .none;
    var priced_is_picard = false;
    try std.testing.expect(group_solve.retainBetterCandidate(
        &priced_state,
        &priced_residual,
        &priced_norm,
        &priced_kind,
        &priced_is_picard,
        &.{1},
        &.{1},
        5,
        .full_network_newton,
        false,
    ));
    try std.testing.expectEqual(group_types.CandidateKind.full_network_newton, priced_kind);
}

test "complementarity probes both physical sides despite primary half-axis bounds" {
    const negative_primary = group_network.primaryCurrentFaceBounds(
        -3.982330454092011e-1,
        -1.5,
        1.5,
    );
    try std.testing.expect(negative_primary.lower < 0);
    try std.testing.expectEqual(@as(f64, 0), negative_primary.upper);
    const negative_physical = group_network.physicalDerivativeSidesAvailable(
        -1.5,
        1.5,
    );
    try std.testing.expect(negative_physical.negative);
    try std.testing.expect(negative_physical.positive);

    const positive_primary = group_network.primaryCurrentFaceBounds(
        1.2121937276411553e-2,
        -1.5,
        1.5,
    );
    try std.testing.expectEqual(@as(f64, 0), positive_primary.lower);
    try std.testing.expect(positive_primary.upper > 0);
    const positive_physical = group_network.physicalDerivativeSidesAvailable(
        -1.5,
        1.5,
    );
    try std.testing.expect(positive_physical.negative);
    try std.testing.expect(positive_physical.positive);

    const zero_primary = group_network.primaryCurrentFaceBounds(
        0,
        -1.5,
        1.5,
    );
    try std.testing.expectEqual(@as(f64, 0), zero_primary.lower);
    try std.testing.expectEqual(@as(f64, 0), zero_primary.upper);
}

test "primary current-side columns match complementarity at captured calcium sign reversals" {
    const captured = [_]struct {
        reaction: usize,
        name: []const u8,
        legacy_primary_calcium_derivative: f64,
        current_side_calcium_derivative: f64,
    }{
        .{
            .reaction = 38,
            .name = "iron_hpo4_pairing_mol_p_per_m3",
            .legacy_primary_calcium_derivative = 1.3785364201448863e9,
            .current_side_calcium_derivative = -2.176802742070083e7,
        },
    };
    for (captured) |entry| {
        try std.testing.expectEqualStrings(
            entry.name,
            reaction_span.reactionIdentity(entry.reaction).?.name,
        );
        try std.testing.expect(
            std.math.signbit(entry.legacy_primary_calcium_derivative) !=
                std.math.signbit(entry.current_side_calcium_derivative),
        );
        try std.testing.expectEqual(
            entry.current_side_calcium_derivative,
            group_network.primaryCurrentSideDerivativeValue(
                entry.legacy_primary_calcium_derivative,
                entry.current_side_calcium_derivative,
                true,
            ),
        );
        try std.testing.expectEqual(
            entry.legacy_primary_calcium_derivative,
            group_network.primaryCurrentSideDerivativeValue(
                entry.legacy_primary_calcium_derivative,
                entry.current_side_calcium_derivative,
                false,
            ),
        );
    }
}

test "active set advances only when the largest scaled residual exhausts its inventory" {
    const options: group_types.Options = .{
        .absolute_tolerance_mol_per_m3 = 1.0e-8,
        .absolute_tolerance_mol_per_megagram = 1.0e-8,
        .relative_tolerance = 0,
    };
    const current = [_]f64{ 1, 0.1, 2 };
    const residual = [_]f64{ -0.01, -0.1, 0.001 };

    try std.testing.expect(group_diagnostics.exhaustsLargestResidual(
        &current,
        &residual,
        &.{ 0.99, 0, 2.001 },
        options,
    ));
    try std.testing.expect(!group_diagnostics.exhaustsLargestResidual(
        &current,
        &residual,
        &.{ 0.99, 0.01, 2.001 },
        options,
    ));
    try std.testing.expect(!group_diagnostics.exhaustsLargestResidual(
        &current,
        &.{ -0.01, 0.1, 0.001 },
        &.{ 0.99, 0, 2.001 },
        options,
    ));
}

test "aqueous calcium extent conserves calcium ligand and charge" {
    const vector = try std.testing.allocator.alloc(
        f64,
        chemistry.State.packedComponentCount(),
    );
    defer std.testing.allocator.free(vector);
    @memset(vector, 1);
    vector[group_numerics2.aqueousPackedIndex("calcium")] = 0.8;
    vector[group_numerics2.aqueousPackedIndex("carbonate")] = 0.6;
    vector[group_numerics2.aqueousPackedIndex("calcium_carbonate")] = 0.2;
    const calcium_before = vector[group_numerics2.aqueousPackedIndex("calcium")] +
        vector[group_numerics2.aqueousPackedIndex("calcium_carbonate")];
    const carbonate_before = vector[group_numerics2.aqueousPackedIndex("carbonate")] +
        vector[group_numerics2.aqueousPackedIndex("calcium_carbonate")];
    const charge_before =
        2 * vector[group_numerics2.aqueousPackedIndex("calcium")] -
        2 * vector[group_numerics2.aqueousPackedIndex("carbonate")];

    try std.testing.expect(group_phosphate.applyPhosphateExtent(
        vector,
        .aqueous_calcium_carbonate_pairing,
        0.25,
        undefined,
    ));
    try std.testing.expectEqual(
        calcium_before,
        vector[group_numerics2.aqueousPackedIndex("calcium")] +
            vector[group_numerics2.aqueousPackedIndex("calcium_carbonate")],
    );
    try std.testing.expectEqual(
        carbonate_before,
        vector[group_numerics2.aqueousPackedIndex("carbonate")] +
            vector[group_numerics2.aqueousPackedIndex("calcium_carbonate")],
    );
    try std.testing.expectEqual(
        charge_before,
        2 * vector[group_numerics2.aqueousPackedIndex("calcium")] -
            2 * vector[group_numerics2.aqueousPackedIndex("carbonate")],
    );
    try std.testing.expectEqual(
        @as(f64, 0.35),
        group_phosphate.maximumPhosphateExtent(
            vector,
            .aqueous_calcium_carbonate_pairing,
            1,
            undefined,
        ),
    );
}

test "zero-extent complementarity uses a generalized derivative" {
    try std.testing.expectEqual(
        @as(f64, -7),
        group_complementarity.complementarityColumnDerivative(-1, -7, 11),
    );
    try std.testing.expectEqual(
        @as(f64, 2),
        group_complementarity.complementarityColumnDerivative(0, -7, 11),
    );
    try std.testing.expectEqual(
        @as(f64, 11),
        group_complementarity.complementarityColumnDerivative(1, -7, 11),
    );
}

test "bounded reaction span rank reveals duplicate conservative directions" {
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const matrix = workspace.reaction_span_jacobian[0 .. 3 * 2];
    matrix[0] = 1;
    matrix[1] = 1;
    matrix[2] = 2;
    matrix[3] = 2;
    matrix[4] = 3;
    matrix[5] = 3;
    workspace.reaction_span_rhs[0] = 2;
    workspace.reaction_span_rhs[1] = 4;
    workspace.reaction_span_rhs[2] = 6;
    workspace.reaction_span_lower_bounds[0] = -1;
    workspace.reaction_span_lower_bounds[1] = -1;
    workspace.reaction_span_upper_bounds[0] = 1;
    workspace.reaction_span_upper_bounds[1] = 1;

    try std.testing.expect(group_reaction_span.solveBoundedReactionSpan(
        &workspace,
        3,
        2,
    ));
    try std.testing.expectApproxEqAbs(
        @as(f64, 2),
        workspace.reaction_span_solution[0] +
            workspace.reaction_span_solution[1],
        1.0e-12,
    );
    for (workspace.reaction_span_solution[0..2]) |extent| {
        try std.testing.expect(extent >= -1 and extent <= 1);
    }
}

test "bounded reaction span accepts zero free columns after useful columns clamp" {
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    workspace.reaction_span_jacobian[0] = 1;
    workspace.reaction_span_jacobian[1] = 0;
    workspace.reaction_span_jacobian[2] = 0;
    workspace.reaction_span_jacobian[3] = 0;
    workspace.reaction_span_rhs[0] = 2;
    workspace.reaction_span_rhs[1] = 0;
    workspace.reaction_span_lower_bounds[0] = 0;
    workspace.reaction_span_lower_bounds[1] = -1;
    workspace.reaction_span_upper_bounds[0] = 1;
    workspace.reaction_span_upper_bounds[1] = 1;

    try std.testing.expect(group_reaction_span.solveBoundedReactionSpan(
        &workspace,
        2,
        2,
    ));
    try std.testing.expectEqual(@as(f64, 1), workspace.reaction_span_solution[0]);
    try std.testing.expectEqual(@as(f64, 0), workspace.reaction_span_solution[1]);
}

test "pivoted reaction solve retains resolvable nearly dependent directions" {
    for ([_]f64{ 1e-100, 1, 1e100 }) |scale| {
        const separation = 1e-10 * scale;
        var matrix = [_]f64{ scale, scale, 0, separation, 0, 0 };
        var rhs = [_]f64{ 0, separation, 0 };
        var solution: [2]f64 = undefined;
        var pivots: [2]usize = undefined;
        var work: [2]f64 = undefined;
        var rank: usize = 0;
        try std.testing.expect(group_solve.solvePivotedHouseholder(&matrix, &rhs, &solution, &pivots, &work, 3, 2, &rank, null));
        try std.testing.expectEqual(@as(usize, 2), rank);
        try std.testing.expectApproxEqAbs(@as(f64, -1), solution[0], 1e-12);
        try std.testing.expectApproxEqAbs(@as(f64, 1), solution[1], 1e-12);
        // Check the independent equation directly: a normwise residual alone
        // could conceal its loss beneath the leading equation's scale.
        try std.testing.expectApproxEqRel(separation, separation * solution[1], 1e-12);
    }
}

test "pivoted reaction solve is scale invariant below unit column norm" {
    var matrix = [_]f64{ 1e-9, 0, 0, 2e-9 };
    var rhs = [_]f64{ 1e-9, 2e-9 };
    var solution: [2]f64 = undefined;
    var pivots: [2]usize = undefined;
    var permutation_work: [2]f64 = undefined;
    var rank: usize = 0;
    try std.testing.expect(group_solve.solvePivotedHouseholder(
        &matrix,
        &rhs,
        &solution,
        &pivots,
        &permutation_work,
        2,
        2,
        &rank,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 2), rank);
    try std.testing.expectApproxEqAbs(@as(f64, 1), solution[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), solution[1], 1e-12);
}

test "reaction span bounds reach exact tiny large and nonbinary inventory faces" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    state.non_band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;

    var parameters = acceptedStateConservationTestParameters();
    parameters.water_activity_product_mol2_per_m6 = 1;
    const reaction = reaction_span.aqueous_reaction_offset +
        std.meta.fieldIndex(
            aqueous_network.Fluxes,
            "calcium_sulfate_association",
        ).?;
    const inventories = [_]f64{
        std.math.floatTrueMin(f64),
        0x1p100,
        1.0 / 3.0,
    };
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output: [chemistry.State.packedComponentCount()]f64 = undefined;

    for (inventories) |inventory| {
        state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
        state.aqueous[0].calcium_sulfate = inventory;
        try state.packCell(0, &current);
        const bounds = try group_reaction_span.reactionSpanExtentBounds(
            &scratch,
            &current,
            reaction,
            reaction_span.zeroTransformations(parameters),
            parameters,
            1,
            1,
            &output,
        );
        try std.testing.expectEqual(
            @as(u64, @bitCast(inventory)),
            @as(u64, @bitCast(bounds.negative_native_extent)),
        );

        var endpoint = reaction_span.zeroTransformations(parameters);
        try reaction_span.addReactionExtent(
            &endpoint,
            reaction,
            -bounds.negative_native_extent,
            reaction_span.zeroTransformations(parameters),
            parameters,
        );
        try group_numerics.transformedVector(
            &scratch,
            &current,
            endpoint,
            1,
            parameters.water_activity_product_mol2_per_m6,
            1,
            &output,
        );
        const successor = std.math.nextAfter(
            f64,
            bounds.negative_native_extent,
            std.math.inf(f64),
        );
        var rejected = reaction_span.zeroTransformations(parameters);
        try reaction_span.addReactionExtent(
            &rejected,
            reaction,
            -successor,
            reaction_span.zeroTransformations(parameters),
            parameters,
        );
        try std.testing.expectError(
            error.NegativeAqueousState,
            group_numerics.transformedVector(
                &scratch,
                &current,
                rejected,
                1,
                parameters.water_activity_product_mol2_per_m6,
                1,
                &output,
            ),
        );
    }

    parameters.fractions.ammonium_non_band = std.math.nan(f64);
    try std.testing.expectError(
        error.InvalidAmmoniumWaterFraction,
        group_reaction_span.reactionSpanExtentBounds(
            &scratch,
            &current,
            reaction,
            reaction_span.zeroTransformations(parameters),
            parameters,
            1,
            1,
            &output,
        ),
    );
}

test "closed-form reaction-span extent matches the bisection reference for every eligible reaction, both directions" {
    // PERF-REACTION-SPAN-CLOSED-FORM-001: mandatory equivalence guard. Any
    // eligible reaction whose closed-form answer disagrees with the
    // trusted bisection reference (beyond floating-point roundoff) must
    // fail this test loudly, not be silently shipped.
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch_a = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch_a.deinit();
    var scratch_b = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch_b.deinit();

    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] = group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;

    var parameters = acceptedStateConservationTestParameters();
    parameters.water_activity_product_mol2_per_m6 = 1;

    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);

    var output_a: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output_b: [chemistry.State.packedComponentCount()]f64 = undefined;

    var eligible_count: usize = 0;
    var matched_count: usize = 0;
    var reaction: usize = 0;
    while (reaction < reaction_span.reaction_count) : (reaction += 1) {
        if (!reaction_span.reactionSpanExtentIsClosedFormEligible(reaction)) continue;
        if (reaction == reaction_span.carboxyl_reaction_index) continue;
        eligible_count += 1;
        const directions = [_]f64{ -1, 1 };
        for (directions) |direction| {
            const closed_form = try group_reaction_span.testOnlyClosedFormReactionSpanExtentMagnitude(
                &scratch_a,
                &current,
                reaction,
                direction,
                reaction_span.zeroTransformations(parameters),
                parameters,
                1,
                1,
                &output_a,
            );
            const bisection = try group_reaction_span.testOnlyBisectionReactionSpanExtent(
                &scratch_b,
                &current,
                reaction,
                direction,
                reaction_span.zeroTransformations(parameters),
                parameters,
                1,
                1,
                &output_b,
            );
            const closed_form_value = closed_form orelse continue;
            matched_count += 1;
            const scale = @max(1.0, @abs(bisection));
            try std.testing.expectApproxEqAbs(bisection, closed_form_value, 1024 * std.math.floatEps(f64) * scale);
        }
    }
    try std.testing.expectEqual(@as(usize, 37), eligible_count);
    // At least the large majority of (reaction, direction) pairs on this
    // fully-populated fixture must actually exercise the closed-form path
    // (not just fall through to `null` every time) -- otherwise this test
    // would pass vacuously without ever comparing anything.
    try std.testing.expect(matched_count >= eligible_count);
}

test "advanceUlps matches chained nextAfter for a moderate step count" {
    // The entire fix for PERF-REACTION-SPAN-CLOSED-FORM-001's reverted
    // regression rests on this equivalence: `advanceUlps(x, n)` must be
    // bit-for-bit identical to calling `std.math.nextAfter(x, +inf)` `n`
    // times in a row, but computed in O(1) instead of O(n). A moderate `n`
    // (10,000) is enough to prove the bit-pattern arithmetic is correct;
    // the whole point of doing it this way is that correctness does not
    // degrade for larger `n`, only the (untested-here, structurally
    // guaranteed) cost of the O(n) alternative would.
    const starting_points = [_]f64{ 0, 1e-300, 1e-6, 1, 1e6, 1e300, std.math.floatMax(f64) / 2 };
    for (starting_points) |start| {
        var reference = start;
        var steps: u64 = 0;
        while (steps < 10_000) : (steps += 1) reference = std.math.nextAfter(f64, reference, std.math.inf(f64));
        const fast = group_reaction_span.testOnlyAdvanceUlps(start, 10_000) orelse
            return error.UnexpectedNonFiniteAdvance;
        try std.testing.expectEqual(reference, fast);
    }
}

test "advanceUlps returns null instead of a non-finite result at the top of the f64 range" {
    // Walking past the largest finite double must fall back cleanly (the
    // caller falls back to full bisection), never silently hand back
    // infinity as if it were a real candidate boundary.
    try std.testing.expectEqual(@as(?f64, null), group_reaction_span.testOnlyAdvanceUlps(std.math.floatMax(f64), 1000));
}

test "closed-form reaction-span extent succeeds and matches bisection on a realistic non-uniform fixture" {
    // PERF-REACTION-SPAN-CLOSED-FORM-001: the mandatory-equivalence test
    // above uses an all-1 uniform fixture, which is fine for proving the
    // affine math is correct but doesn't exercise real magnitude
    // disparities (water molarity ~1e4 vs. solute species ~1e-3 to 1e-5).
    // On a realistic fixture, demanding bit-exact agreement with wherever
    // the reference bisection happens to terminate failed almost every
    // time -- the affine estimate was always correct in value but a
    // handful of ULPs short of the bisection's own exact-boundary
    // definition. This locks in the fix (a short local bracket-and-bisect
    // refinement seeded from the affine estimate, using an O(1) ULP jump
    // per doubling round -- see `advanceUlps`): the closed-form path must
    // now actually succeed for the large majority of eligible reactions,
    // and whenever it does, its answer must match the trusted bisection
    // reference within tight floating-point tolerance.
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    var scratch_a = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch_a.deinit();
    var scratch_b = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch_b.deinit();

    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 3.7e-3);
    state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 4.1e-4);
    state.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 2.9e-4);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1.3e-2);
    state.geochemistry_solids[0] = group_numerics2.filled(geochemistry.SolidState, 6.6e-5);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 8.2e-3;
    state.water_mol_per_m3[0] = 5.56e4;

    var parameters = acceptedStateConservationTestParameters();
    parameters.water_activity_product_mol2_per_m6 = 1;

    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);

    var output_a: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output_b: [chemistry.State.packedComponentCount()]f64 = undefined;

    var eligible_pairs: usize = 0;
    var succeeded_pairs: usize = 0;
    var reaction: usize = 0;
    while (reaction < reaction_span.reaction_count) : (reaction += 1) {
        if (!reaction_span.reactionSpanExtentIsClosedFormEligible(reaction)) continue;
        if (reaction == reaction_span.carboxyl_reaction_index) continue;
        const directions = [_]f64{ -1, 1 };
        for (directions) |direction| {
            eligible_pairs += 1;
            const closed_form = try group_reaction_span.testOnlyClosedFormReactionSpanExtentMagnitude(
                &scratch_a,
                &current,
                reaction,
                direction,
                reaction_span.zeroTransformations(parameters),
                parameters,
                1e-6,
                1,
                &output_a,
            ) orelse continue;
            const bisection = group_reaction_span.testOnlyBisectionReactionSpanExtent(
                &scratch_b,
                &current,
                reaction,
                direction,
                reaction_span.zeroTransformations(parameters),
                parameters,
                1e-6,
                1,
                &output_b,
            ) catch continue;
            succeeded_pairs += 1;
            const scale = @max(1.0, @abs(bisection));
            try std.testing.expectApproxEqAbs(bisection, closed_form, 1024 * std.math.floatEps(f64) * scale);
        }
    }
    // Before the refinement fix, this was 0/N (every single pair fell
    // through to bisection despite the affine math being correct).
    try std.testing.expect(succeeded_pairs * 10 >= eligible_pairs * 9);
}

test "bounded reaction span retains independent columns across sensitivity scales" {
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const count = 5;
    @memset(workspace.reaction_span_jacobian[0 .. count * count], 0);
    for (0..count) |index| {
        const coefficient: f64 = if (index == 0) 1e12 else 1;
        workspace.reaction_span_jacobian[index * count + index] = coefficient;
        workspace.reaction_span_rhs[index] = 0.5 * coefficient;
        workspace.reaction_span_lower_bounds[index] = -1;
        workspace.reaction_span_upper_bounds[index] = 1;
    }

    try std.testing.expect(group_reaction_span.solveBoundedReactionSpan(
        &workspace,
        count,
        count,
    ));
    try std.testing.expectEqual(count, workspace.reaction_span_last_rank);
    for (workspace.reaction_span_solution[0..count]) |extent|
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), extent, 1e-12);
}

test "nearly dependent bounded solve preserves its independent balance" {
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const near_dependence = 1.1e-8;
    const inverse_sqrt_two = 1.0 / @sqrt(2.0);
    const coefficients = [_]f64{
        1, 1,
        0, near_dependence * inverse_sqrt_two,
        0, near_dependence * inverse_sqrt_two,
    };
    const right_hand_side = [_]f64{ 1, @sqrt(2.0), @sqrt(2.0) };
    @memcpy(workspace.reaction_span_jacobian[0..coefficients.len], &coefficients);
    @memcpy(workspace.reaction_span_rhs[0..right_hand_side.len], &right_hand_side);
    @memset(workspace.reaction_span_lower_bounds[0..2], -2.0e8);
    @memset(workspace.reaction_span_upper_bounds[0..2], 2.0e8);

    const solved = group_reaction_span.solveBoundedReactionSpan(
        &workspace,
        3,
        2,
    );
    try std.testing.expectEqual(@as(usize, 2), workspace.reaction_span_last_rank);
    try std.testing.expect(solved);
    try std.testing.expectApproxEqAbs(@as(f64, 2), near_dependence * workspace.reaction_span_solution[1], 1e-12);
    try std.testing.expect(group_reaction_span.reactionSpanProjectedKktSatisfied(
        &workspace,
        3,
        2,
    ));
}

test "rank-deficient bounded recovery publishes only a KKT-certified point" {
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const matrix = workspace.reaction_span_jacobian[0 .. 3 * 3];
    const coefficients = [_]f64{
        1, 0, 1,
        0, 1, 1,
        0, 0, 0,
    };
    const right_hand_side = [_]f64{ 2, 2, 0 };
    const lower_bounds = [_]f64{ 0, 0, 0 };
    const upper_bounds = [_]f64{ 1, 1, 0.5 };
    @memcpy(matrix, &coefficients);
    @memcpy(workspace.reaction_span_rhs[0..3], &right_hand_side);
    @memcpy(workspace.reaction_span_lower_bounds[0..3], &lower_bounds);
    @memcpy(workspace.reaction_span_upper_bounds[0..3], &upper_bounds);

    @memset(workspace.reaction_span_solution[0..3], 0);
    try std.testing.expect(!group_reaction_span.reactionSpanProjectedKktSatisfied(
        &workspace,
        3,
        3,
    ));
    try std.testing.expect(group_reaction_span.solveProjectedReactionSpanLeastSquares(
        &workspace,
        3,
        3,
    ));
    try std.testing.expect(group_reaction_span.reactionSpanProjectedKktSatisfied(
        &workspace,
        3,
        3,
    ));
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        workspace.reaction_span_solution[0],
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 1),
        workspace.reaction_span_solution[1],
        1.0e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5),
        workspace.reaction_span_solution[2],
        1.0e-12,
    );
}

test "genuine Anderson target is damped before admissible merit publication" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.aqueous[0].hydrogen = 10;
    state.aqueous[0].hydroxide = 10;
    state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 100;
    const parameters: chemistry.ReactionParameters = .{
        .fractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 },
        .non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1,
        .band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1,
        .cation_exchange_capacity_mol_charge_per_megagram = 10,
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 1, .ammonium_band_megagrams_per_m3 = 1 },
        .total_carboxyl_sites_mol_per_megagram = 1,
        .carboxyl_exchange_parameters = .{ .dissociation_constant_mol_per_m3 = 1, .maximum_exchange_mol_per_m3_per_iteration = 0, .substrate_limit_fraction_per_iteration = 0.2 },
        .aqueous_constants = group_numerics2.filled(aqueous_rates.EquilibriumConstants, 1),
        // maximum_fast_association_mol_per_m3_step is 1 here, not 0. With every
        // association capped at zero -- and carboxyl and cation exchange likewise --
        // this fixture had NO active chemistry, so its only residual source was the
        // water-pair reprojection gap of
        // SOLUTE-DUAL-ACTIVITY-COEFFICIENT-MERIT-FLOOR-001, which the comment below
        // identified. With that defect fixed the fixture had no residual at all,
        // current_norm went to ~0, and 'beat the current norm' became
        // unsatisfiable. No displacement of the carrier can rescue it while the
        // rates are capped at zero -- which is why three attempts to perturb the
        // state all failed. One enabled association gives the network genuine work:
        // constants are filled to 1 and hydrogen is 10 against unit concentrations,
        // so the association quotient is 10 against a constant of 1.
        .aqueous_kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_fast_association_mol_per_m3_step = 1, .maximum_slow_association_mol_per_m3_step = 0 },
        .phosphate_constants = group_numerics2.filled(phosphate_rates.EquilibriumConstants, 1),
        .phosphate_surface = .{ .protonated_site_equilibrium_constant = 1, .hydroxyl_site_equilibrium_constant = 1, .h2po4_exchange_equilibrium_constant = 1, .hpo4_exchange_equilibrium_constant = 1, .water_activity_product_mol2_per_m6 = 1, .h2po4_dissociation_constant = 1, .maximum_exchange_mol_per_megagram_step = 0, .substrate_limit_fraction = 0.2 },
        .phosphate_minerals = null,
        .phosphate_kinetics = .{ .substrate_limit_fraction = 0.2, .maximum_pairing_mol_per_m3_step = 0 },
        .cation_exchange_parameters = .{ .selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, .substrate_limit_fraction = 0.2, .maximum_adsorption_mol_charge_per_m3_step = 0 },
        .geochemistry_products = group_numerics2.filled(geochemistry_rates.SolubilityProducts, 1),
        .geochemistry_kinetics = .{ .general_substrate_limit_fraction = 0.2, .hydrogen_coupled_substrate_limit_fraction = 0.2, .maximum_hydroxide_mineral_mol_per_m3_step = 0, .maximum_general_mineral_mol_per_m3_step = 0, .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1, .maximum_natural_weathering_mol_per_m3_step = 0, .maximum_ground_weathering_mol_per_m3_step = 0 },
        .water_activity_product_mol2_per_m6 = 1,
        .negligible_water_ion_concentration_mol_per_m3 = 1e-32,
    };
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var current_residual: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);
    try group_evaluate.evaluateGlobalResidualAt(
        &scratch,
        &current,
        parameters,
        &current_residual,
    );
    const options: group_types.Options = .{};
    const current_norm = try group_numerics.scaledNorm(
        &current,
        &current_residual,
        options,
    );
    // A genuine Anderson target is one that overshoots. The depth-one secant
    // formed below mixes at 0.5, so the synthetic relaxed-Picard seed has to
    // displace far enough that half of that displacement still crosses a
    // nonnegativity boundary -- otherwise `tryAcceptAndersonCandidate` accepts
    // at fraction 1 and the damping ladder is never exercised at all.
    //
    // Scale the seed along the residual direction by the inventory-to-defect
    // ratio, so the target lands at -2x the limiting inventory and the undamped
    // target is inadmissible by construction.
    //
    // This reads the residual, which is only legitimate because the fixture now
    // HAS one: `maximum_fast_association_mol_per_m3_step` is enabled above. The
    // previous version of this fixture read a residual that was purely the
    // water-pair reprojection gap of
    // SOLUTE-DUAL-ACTIVITY-COEFFICIENT-MERIT-FLOOR-001, so the direction it
    // scaled along was an artifact of a defect and the assertion below held for
    // the wrong reason.
    var seed_scale: f64 = 0;
    for (current, current_residual) |initial, defect| {
        if (defect >= 0) continue;
        seed_scale = @max(seed_scale, 6 * initial / -defect);
    }
    try std.testing.expect(seed_scale > 0 and std.math.isFinite(seed_scale));
    var seed: [chemistry.State.packedComponentCount()]f64 = undefined;
    for (&seed, current, current_residual) |*value, initial, defect|
        value.* = initial + seed_scale * defect;
    var first_defect = [_]f64{0} ** chemistry.State.packedComponentCount();
    var second_defect = [_]f64{0} ** chemistry.State.packedComponentCount();
    first_defect[0] = -1;
    second_defect[0] = 1;
    var raw_anderson: [chemistry.State.packedComponentCount()]f64 = undefined;
    try std.testing.expect(numerics.andersonDepthOneCandidate(
        &current,
        &first_defect,
        &seed,
        &second_defect,
        &raw_anderson,
    ));
    try std.testing.expect(!std.mem.eql(f64, &seed, &raw_anderson));
    var full_trial = raw_anderson;
    try std.testing.expect(!group_candidates.tryProjectWaterPair(
        &scratch,
        &full_trial,
        parameters,
    ));
    var accepted: [chemistry.State.packedComponentCount()]f64 = undefined;
    var accepted_residual: [chemistry.State.packedComponentCount()]f64 = undefined;
    try std.testing.expect(try group_candidates.tryAcceptAndersonCandidate(
        &scratch,
        &current,
        &raw_anderson,
        &accepted,
        &accepted_residual,
        parameters,
        options,
        current_norm,
    ));
    try std.testing.expect(!std.mem.eql(f64, &accepted, &raw_anderson));
    try std.testing.expect(
        try group_numerics.scaledNorm(&accepted, &accepted_residual, options) <
            current_norm,
    );
    // The undamped target failed the same admissibility gate above, so the
    // damping is what produced a publishable state, not the water projection.
    var published = accepted;
    try std.testing.expect(group_candidates.tryProjectWaterPair(
        &scratch,
        &published,
        parameters,
    ));
}

test "active-row face projection preserves original arithmetic bits" {
    const jacobian = [_]f64{
        0.125,  -3.75, 2.5,
        9.0,    -0.75, 6.125,
        -11.25, 8.5,   0.0625,
    };
    const row_weights = [2]f64{ 0.37, 2.9 };
    const row_rhs = [2]f64{ -7.125, 0.8125 };
    const projection = group_network.activeRowFaceProjection(
        &jacobian,
        3,
        1,
        .{ 0, 2 },
        row_weights,
        row_rhs,
    );
    const row0 = jacobian[1] / row_weights[0];
    const row1 = jacobian[7] / row_weights[1];
    const expected = [_]f64{
        row0,
        row1,
        row0 * row0 + row1 * row1,
        row0 * row_rhs[0] + row1 * row_rhs[1],
    };
    const actual = [_]f64{
        projection.rows[0],
        projection.rows[1],
        projection.self_dot,
        projection.rhs_dot,
    };
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&expected),
        std.mem.asBytes(&actual),
    );
}

test "phosphate trust region uses runtime Picard relaxation and limits only HPO4" {
    const count = chemistry.State.packedComponentCount();
    const current = try std.testing.allocator.alloc(f64, count);
    defer std.testing.allocator.free(current);
    const target = try std.testing.allocator.alloc(f64, count);
    defer std.testing.allocator.free(target);
    @memset(current, 1);
    @memset(target, 1);
    const aqueous_count = @typeInfo(aqueous_network.State).@"struct".fields.len;
    const phosphate_count = @typeInfo(phosphate_network.State).@"struct".fields.len;
    target[aqueous_count + 1] = 3;
    target[aqueous_count + phosphate_count] = 1.0e12;
    const fraction = group_phosphate.phosphateTrustRegionFraction(
        current,
        target,
        .{},
        0.2,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), fraction, 1e-15);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.5),
        current[aqueous_count + 1] +
            fraction * (target[aqueous_count + 1] - current[aqueous_count + 1]),
        1e-15,
    );
    const smaller_runtime_fraction = group_phosphate.phosphateTrustRegionFraction(
        current,
        target,
        .{ .picard_relaxation = 0.3 },
        0.2,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.15),
        smaller_runtime_fraction,
        1e-15,
    );
}

test "dependent water ions do not limit a conservative chemistry step" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] = group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);
    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    transformations.aqueous.hydroxide = -0.3;
    transformations.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    var test_parameters: chemistry.ReactionParameters = undefined;
    test_parameters.fractions = .{
        .ammonium_non_band = 0.8,
        .ammonium_band = 0.2,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.7,
        .phosphate_band = 0.3,
    };
    test_parameters.water_activity_product_mol2_per_m6 = 1;
    const fraction = try group_numerics.transformedVectorAdmissible(
        &scratch,
        &current,
        transformations,
        test_parameters,
        4,
        &output,
    );
    try std.testing.expectEqual(@as(f64, 4), fraction);
    try std.testing.expect(output[4] > 0);
    try std.testing.expect(output[5] > 0);
    for (output) |value| try std.testing.expect(value >= 0);
}

test "admissibility search reaches sub-2^-47 inventory boundary" {
    diagnostic_control.resetAdmissibilityBacktrackStats();
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.aqueous[0].calcium = 4.0e-15;
    state.non_band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);
    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    transformations.aqueous.calcium = -1;
    transformations.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    var parameters: chemistry.ReactionParameters = undefined;
    parameters.fractions = .{
        .ammonium_non_band = 0.8,
        .ammonium_band = 0.2,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.7,
        .phosphate_band = 0.3,
    };
    parameters.water_activity_product_mol2_per_m6 = 1;
    const fraction = try group_numerics.transformedVectorAdmissible(
        &scratch,
        &current,
        transformations,
        parameters,
        1,
        &output,
    );
    try std.testing.expect(fraction < std.math.scalbn(@as(f64, 1), -47));
    try std.testing.expect(fraction > 0);
    try std.testing.expect(output[group_numerics2.aqueousPackedIndex("calcium")] >= 0);
    const successor = std.math.nextAfter(
        f64,
        fraction,
        std.math.inf(f64),
    );
    try std.testing.expectError(
        error.NegativeAqueousState,
        group_numerics.transformedVector(
            &scratch,
            &current,
            transformations,
            1,
            parameters.water_activity_product_mol2_per_m6,
            successor,
            &output,
        ),
    );
    const search = diagnostic_control.admissibilityBacktrackStats();
    try std.testing.expectEqual(@as(u64, 1), search.calls);
    // This aqueous boundary deliberately retains source-order halving because
    // coupled realized changes are not a raw-owner proof. It must nevertheless
    // remain bounded by the initial exponent walk plus the 63-call exact
    // f64-lattice refinement.
    try std.testing.expect(search.total_attempts < 128);
}

test "raw mineral owner skips only fractions proven negative" {
    diagnostic_control.resetAdmissibilityBacktrackStats();
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.non_band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.geochemistry_solids[0].gibbsite_solid_mol_per_m3 = 4.0e-300;
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;

    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);
    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    transformations.geochemistry.gibbsite_solid_mol_per_m3 = -1;
    transformations.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    var parameters = std.mem.zeroes(chemistry.ReactionParameters);
    parameters.fractions = .{
        .ammonium_non_band = 0.8,
        .ammonium_band = 0.2,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.7,
        .phosphate_band = 0.3,
    };
    parameters.water_activity_product_mol2_per_m6 = 1;

    const fraction = try group_numerics.transformedVectorAdmissible(
        &scratch,
        &current,
        transformations,
        parameters,
        1,
        &output,
    );
    try std.testing.expect(fraction > 0);
    const successor = std.math.nextAfter(
        f64,
        fraction,
        std.math.inf(f64),
    );
    try std.testing.expectError(
        error.NegativeGeochemistrySolidState,
        group_numerics.transformedVector(
            &scratch,
            &current,
            transformations,
            1,
            parameters.water_activity_product_mol2_per_m6,
            successor,
            &output,
        ),
    );
    const search = diagnostic_control.admissibilityBacktrackStats();
    try std.testing.expectEqual(@as(u64, 1), search.calls);
    // The raw affine owner proposes its zero and the adjacent f64; the exact
    // successor rejection closes the same boundary without a 52-step lattice
    // bisection across an exponent-wide interval.
    try std.testing.expect(search.total_attempts < 8);
}

test "zero aqueous donor reaches its complementarity face without underflow backtracking" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.aqueous[0].calcium = 0;
    state.non_band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);

    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    transformations.aqueous.calcium = -1;
    transformations.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    var parameters = std.mem.zeroes(chemistry.ReactionParameters);
    parameters.fractions = .{
        .ammonium_non_band = 0.8,
        .ammonium_band = 0.2,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.7,
        .phosphate_band = 0.3,
    };
    parameters.water_activity_product_mol2_per_m6 = 1;

    diagnostic_control.resetEvaluationCounts();
    diagnostic_control.resetAdmissibilityBacktrackStats();
    const fraction = try group_numerics.transformedVectorAdmissible(
        &scratch,
        &current,
        transformations,
        parameters,
        1,
        &output,
    );
    try std.testing.expectEqual(@as(f64, 0), fraction);
    try std.testing.expectEqual(
        @as(f64, 0),
        output[group_numerics2.aqueousPackedIndex("calcium")],
    );
    const evaluations = diagnostic_control.evaluationCounts();
    try std.testing.expectEqual(@as(u64, 2), evaluations.reaction_span);
    const backtracks = diagnostic_control.admissibilityBacktrackStats();
    try std.testing.expectEqual(@as(u64, 1), backtracks.calls);
    try std.testing.expectEqual(@as(u64, 1), backtracks.total_attempts);
    try std.testing.expectEqual(@as(u64, 1), backtracks.max_attempts);
}

test "admissibility search lands on the limiting aqueous complementarity face" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.non_band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var output: [chemistry.State.packedComponentCount()]f64 = undefined;
    var rejected_output: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);

    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    // Two independently assembled reaction families draw from the same
    // aqueous Ca/CO3 donors: aqueous pairing transfers one mole to CaCO3(aq)
    // while mineral precipitation transfers two moles to calcite(s).
    transformations.aqueous.calcium = -1;
    transformations.aqueous.carbonate = -1;
    transformations.aqueous.calcium_carbonate = 1;
    transformations.geochemistry.dissolved_calcium_mol_per_m3 = -2;
    transformations.geochemistry.dissolved_carbonate_mol_per_m3 = -2;
    transformations.geochemistry.calcite_solid_mol_per_m3 = 2;
    transformations.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    var parameters: chemistry.ReactionParameters = undefined;
    parameters.fractions = .{
        .ammonium_non_band = 0.8,
        .ammonium_band = 0.2,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.7,
        .phosphate_band = 0.3,
    };
    parameters.water_activity_product_mol2_per_m6 = 1;

    const fraction = try group_numerics.transformedVectorAdmissible(
        &scratch,
        &current,
        transformations,
        parameters,
        1,
        &output,
    );
    const calcium = group_numerics2.aqueousPackedIndex("calcium");
    const carbonate = group_numerics2.aqueousPackedIndex("carbonate");
    try std.testing.expectEqual(@as(f64, 0), output[calcium]);
    try std.testing.expectEqual(@as(f64, 0), output[carbonate]);
    try std.testing.expectEqual(
        @as(f64, 3),
        scratch.aqueous[0].calcium +
            scratch.aqueous[0].calcium_carbonate +
            scratch.geochemistry_solids[0].calcite_solid_mol_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 3),
        scratch.aqueous[0].carbonate +
            scratch.aqueous[0].calcium_carbonate +
            scratch.geochemistry_solids[0].calcite_solid_mol_per_m3,
    );

    const successor = std.math.nextAfter(f64, fraction, std.math.inf(f64));
    try std.testing.expectError(
        error.NegativeAqueousState,
        group_numerics.transformedVector(
            &scratch,
            &current,
            transformations,
            1,
            parameters.water_activity_product_mol2_per_m6,
            successor,
            &rejected_output,
        ),
    );
}

test "prepared admissibility coefficient is bitwise identical to public path" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.aqueous[0].calcium = 4.0e-15;
    state.non_band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    var public_output: [chemistry.State.packedComponentCount()]f64 = undefined;
    var prepared_output: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);
    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    transformations.aqueous.calcium = -1;
    transformations.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    var parameters: chemistry.ReactionParameters = undefined;
    parameters.fractions = .{
        .ammonium_non_band = 0.8,
        .ammonium_band = 0.2,
        .nitrate_non_band = 0.6,
        .nitrate_band = 0.4,
        .phosphate_non_band = 0.7,
        .phosphate_band = 0.3,
    };
    parameters.water_activity_product_mol2_per_m6 = 1;
    try scratch.unpackCell(0, &current);
    const coefficients = try scratch.activityCoefficients(0, parameters.fractions);
    const public_fraction = try group_numerics.transformedVectorAdmissible(
        &scratch,
        &current,
        transformations,
        parameters,
        1,
        &public_output,
    );
    const prepared_fraction = try group_numerics.transformedVectorAdmissibleWithMonovalentActivityCoefficient(
        &scratch,
        &current,
        transformations,
        parameters,
        coefficients.monovalent_activity_coefficient,
        1,
        &prepared_output,
    );
    try std.testing.expectEqual(
        @as(u64, @bitCast(public_fraction)),
        @as(u64, @bitCast(prepared_fraction)),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&public_output),
        std.mem.asBytes(&prepared_output),
    );
}

test "kinetic geochemistry transaction is limited by shared aqueous inventory" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.non_band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] =
        group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] =
        group_numerics2.filled(geochemistry.SolidState, 1);
    state.carboxyl_bound_hydrogen_mol_per_megagram[0] = 1;
    state.water_mol_per_m3[0] = 1;
    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);

    var transformations = std.mem.zeroes(chemistry.CellTransformations);
    // The non-binary 1/3 boundary exercises the exact representable search
    // in the terminal kinetic-application path as well as in solver trials.
    transformations.geochemistry.dissolved_calcium_mol_per_m3 = -3;
    transformations.geochemistry.calcite_solid_mol_per_m3 = 3;
    transformations.non_band_phosphate_water_fraction = 1;
    transformations.band_phosphate_water_fraction = 1;
    transformations.cation_exchange_water_ratios = .{
        .shared_megagrams_per_m3 = 1,
        .ammonium_non_band_megagrams_per_m3 = 1,
        .ammonium_band_megagrams_per_m3 = 1,
    };
    transformations.carboxyl_soil_mass_per_water_volume_megagrams_per_m3 = 1;

    try group_apply.applyAdmissibleKineticTransformations(
        &scratch,
        &state,
        0,
        transformations,
        &current,
    );
    try std.testing.expectEqual(@as(f64, 0), state.aqueous[0].calcium);
    try std.testing.expectEqual(
        @as(f64, 2),
        state.geochemistry_solids[0].calcite_solid_mol_per_m3,
    );
}

test "packed residual diagnostics identify scientific components" {
    try std.testing.expectEqualStrings(
        "aqueous.ammonium_non_band",
        chemistry.State.packedComponentName(0).?,
    );
    try std.testing.expectEqualStrings(
        "water_mol_per_m3",
        chemistry.State.packedComponentName(
            chemistry.State.packedComponentCount() - 1,
        ).?,
    );
    try std.testing.expect(
        chemistry.State.packedComponentName(
            chemistry.State.packedComponentCount(),
        ) == null,
    );
}

test "day 12 snapshot rejects ammonium above water molarity" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.water_mol_per_m3[0] = 55555.906256719943;
    state.aqueous[0].ammonium_non_band = 1353591.0109655228;
    try std.testing.expectError(
        error.SoluteConcentrationExceedsWaterMolarity,
        group_numerics.validateAqueousMolarity(&state, 0),
    );
    state.aqueous[0].ammonium_non_band = 0.6232257391219167;
    try group_numerics.validateAqueousMolarity(&state, 0);
}

test "diagnostic suppression preserves solver error and rollback bytes" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.water_mol_per_m3[0] = 1;
    state.aqueous[0].ammonium_non_band = 2;
    const parameters = std.mem.zeroes(chemistry.ReactionParameters);
    var before: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &before);

    try std.testing.expectError(
        error.SoluteConcentrationExceedsWaterMolarity,
        group_solve.solveCell(
            std.testing.allocator,
            &state,
            0,
            parameters,
            .{ .max_iterations = 1 },
        ),
    );
    var after_enabled: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &after_enabled);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after_enabled));

    {
        var suppression = diagnostic_control.suppress();
        defer suppression.restore();
        try std.testing.expectError(
            error.SoluteConcentrationExceedsWaterMolarity,
            group_solve.solveCell(
                std.testing.allocator,
                &state,
                0,
                parameters,
                .{ .max_iterations = 1 },
            ),
        );
    }
    var after_suppressed: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &after_suppressed);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after_suppressed));
}

test "Ottawa phosphate stays accelerated and weathering applies once" {
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] = group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] = group_numerics2.filled(geochemistry.SolidState, 1);
    // Keep the synthetic chemistry within its declared physical domain.
    // Water is otherwise inert in this focused reaction-network fixture.
    state.water_mol_per_m3[0] = 100;
    const parameters: chemistry.ReactionParameters = .{
        .fractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 },
        .non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1,
        .band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1,
        .cation_exchange_capacity_mol_charge_per_megagram = 10,
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 1, .ammonium_band_megagrams_per_m3 = 1 },
        .total_carboxyl_sites_mol_per_megagram = 0,
        .carboxyl_exchange_parameters = .{ .dissociation_constant_mol_per_m3 = 0.01, .maximum_exchange_mol_per_m3_per_iteration = 0.01, .substrate_limit_fraction_per_iteration = 0.2 },
        .aqueous_constants = group_numerics2.filled(aqueous_rates.EquilibriumConstants, 1),
        .aqueous_kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_fast_association_mol_per_m3_step = 0, .maximum_slow_association_mol_per_m3_step = 0 },
        .phosphate_constants = group_numerics2.filled(phosphate_rates.EquilibriumConstants, 1),
        .phosphate_surface = .{ .protonated_site_equilibrium_constant = 1, .hydroxyl_site_equilibrium_constant = 1, .h2po4_exchange_equilibrium_constant = 1, .hpo4_exchange_equilibrium_constant = 1, .water_activity_product_mol2_per_m6 = 1, .h2po4_dissociation_constant = 1, .maximum_exchange_mol_per_megagram_step = 0, .substrate_limit_fraction = 0.2 },
        .phosphate_minerals = null,
        .phosphate_kinetics = .{ .substrate_limit_fraction = 0.2, .maximum_pairing_mol_per_m3_step = 0 },
        .cation_exchange_parameters = .{ .selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, .substrate_limit_fraction = 0.2, .maximum_adsorption_mol_charge_per_m3_step = 0 },
        .geochemistry_products = group_numerics2.filled(geochemistry_rates.SolubilityProducts, 1),
        .geochemistry_kinetics = .{ .general_substrate_limit_fraction = 0.2, .hydrogen_coupled_substrate_limit_fraction = 0.2, .maximum_hydroxide_mineral_mol_per_m3_step = 0, .maximum_general_mineral_mol_per_m3_step = 0, .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1, .maximum_natural_weathering_mol_per_m3_step = 0, .maximum_ground_weathering_mol_per_m3_step = 0 },
        .water_activity_product_mol2_per_m6 = 1,
        .negligible_water_ion_concentration_mol_per_m3 = 1e-32,
    };
    // Accepted equilibrium and kinetic-calcite steps must only repartition
    // inorganic carbon among aqueous carriers and solid calcite.
    var carbon_state = try chemistry.State.init(std.testing.allocator, 1);
    defer carbon_state.deinit();
    carbon_state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    carbon_state.aqueous[0].calcium = 2;
    carbon_state.aqueous[0].carbonate = 2;
    carbon_state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    carbon_state.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    carbon_state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    carbon_state.geochemistry_solids[0] = group_numerics2.filled(geochemistry.SolidState, 1);
    carbon_state.geochemistry_solids[0].calcite_solid_mol_per_m3 = 0.1;
    carbon_state.water_mol_per_m3[0] = 100;
    var carbon_parameters = parameters;
    carbon_parameters.geochemistry_kinetics
        .maximum_hydroxide_mineral_mol_per_m3_step = 0.01;
    const carbon_before = group_numerics2.inorganicCarbonMolPerM3(&carbon_state, 0);
    const calcite_before =
        carbon_state.geochemistry_solids[0].calcite_solid_mol_per_m3;
    const carbon_result = try group_solve.solveCell(
        std.testing.allocator,
        &carbon_state,
        0,
        carbon_parameters,
        .{ .max_iterations = 60 },
    );
    try std.testing.expect(carbon_result.converged);
    try std.testing.expect(
        carbon_state.geochemistry_solids[0].calcite_solid_mol_per_m3 !=
            calcite_before,
    );
    try std.testing.expectApproxEqAbs(
        carbon_before,
        group_numerics2.inorganicCarbonMolPerM3(&carbon_state, 0),
        2.0e-14,
    );
    // Exact standalone reproduction of the first hourly Ottawa limiting
    // coordinate. The 0.025 and 0.00125 values are legacy fixed-cycle
    // relaxation ceilings for aqueous association and cation exchange, not
    // kinetic sources to be integrated once per model hour.
    var hourly_state = try chemistry.State.init(std.testing.allocator, 1);
    defer hourly_state.deinit();
    hourly_state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    hourly_state.aqueous[0].ammonium_non_band = 0.6025043003707329;
    hourly_state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    hourly_state.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    hourly_state.cation_exchange_mol_per_megagram[0] =
        group_numerics2.filled(cation_exchange.Cations, 1);
    hourly_state.geochemistry_solids[0] = group_numerics2.filled(geochemistry.SolidState, 1);
    // The synthetic carriers are O(1) mol/m3 and reactions spend solvent.
    // Keep them within the same water-molarity domain as the parent fixture.
    hourly_state.water_mol_per_m3[0] = 100;
    var hourly_parameters = parameters;
    hourly_parameters.aqueous_kinetics
        .maximum_fast_association_mol_per_m3_step = 0.025;
    hourly_parameters.cation_exchange_parameters
        .maximum_adsorption_mol_charge_per_m3_step = 0.00125;
    const non_band_phosphate_before = hourly_state.non_band_phosphate[0];
    const band_phosphate_before = hourly_state.band_phosphate[0];
    const hourly_result = try group_solve.solveCell(
        std.testing.allocator,
        &hourly_state,
        0,
        hourly_parameters,
        .{ .max_iterations = 60 },
    );
    try std.testing.expect(hourly_result.converged);
    try std.testing.expect(hourly_result.iterations <= 60);
    try std.testing.expect(hourly_result.newton_raphson_steps > 0);
    try std.testing.expect(hourly_result.maximum_scaled_residual <= 1);
    try std.testing.expectEqual(
        non_band_phosphate_before,
        hourly_state.non_band_phosphate[0],
    );
    try std.testing.expectEqual(
        band_phosphate_before,
        hourly_state.band_phosphate[0],
    );

    var ottawa_ceiling_parameters = parameters;
    ottawa_ceiling_parameters.aqueous_kinetics
        .maximum_slow_association_mol_per_m3_step = 0.025;
    ottawa_ceiling_parameters.phosphate_surface
        .maximum_exchange_mol_per_megagram_step = 0.0025;
    ottawa_ceiling_parameters.geochemistry_kinetics
        .maximum_hydroxide_mineral_mol_per_m3_step = 0.0025;
    const closure_parameters = group_solve.equilibriumClosureParameters(
        ottawa_ceiling_parameters,
    );
    try std.testing.expectEqual(
        @as(f64, 1.0e100),
        closure_parameters.aqueous_kinetics
            .maximum_slow_association_mol_per_m3_step,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        closure_parameters.geochemistry_kinetics
            .maximum_hydroxide_mineral_mol_per_m3_step,
    );
    try std.testing.expectEqual(
        @as(f64, 1.0e100),
        closure_parameters.phosphate_surface
            .maximum_exchange_mol_per_megagram_step,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        closure_parameters.phosphate_kinetics
            .maximum_pairing_mol_per_m3_step,
    );
    try std.testing.expectEqual(
        @as(f64, 0),
        closure_parameters.aqueous_kinetics
            .maximum_fast_association_mol_per_m3_step,
    );
    try std.testing.expectEqual(
        ottawa_ceiling_parameters.phosphate_surface
            .substrate_limit_fraction,
        closure_parameters.phosphate_surface
            .substrate_limit_fraction,
    );
    try std.testing.expectEqual(
        ottawa_ceiling_parameters.phosphate_constants.h2po4,
        closure_parameters.phosphate_constants.h2po4,
    );
    var before: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &before);
    // This endpoint is already physically acceptable after one Newton step.
    // Check the endpoint itself instead of assuming a short budget must fail.
    var acceptance_workspace = try group_types.Workspace.init(std.testing.allocator);
    defer acceptance_workspace.deinit();
    const one_step = try group_solve.solveCellWithWorkspace(
        &acceptance_workspace,
        &state,
        0,
        parameters,
        .{ .max_iterations = 1 },
    );
    try std.testing.expect(one_step.converged);
    try std.testing.expectEqual(@as(u16, 1), one_step.iterations);
    try std.testing.expect(one_step.maximum_scaled_residual <= 1);
    try state.packCell(0, acceptance_workspace.current);
    _ = try group_evaluate.requirePhysicalReactionBalance(
        &acceptance_workspace.scratch,
        acceptance_workspace.current,
        group_solve.equilibriumClosureParameters(parameters),
        .{},
        acceptance_workspace.residual,
    );
    try group_solve.requireAcceptedStateConservation(
        &acceptance_workspace.scratch,
        &state,
        0,
        &before,
        parameters,
    );
    try state.unpackCell(0, &before);

    // NOTE: `newton_raphson_steps + picard_steps > 0` below currently FAILS,
    // and it is not a regression in acceleration. This fixture caps EVERY
    // reaction rate at zero -- aqueous fast and slow association, phosphate
    // `maximum_pairing_mol_per_m3_step`, geochemistry hydroxide and general
    // minerals, carboxyl exchange, cation exchange -- with all concentrations
    // and equilibrium constants at 1. The carrier therefore sits exactly at
    // equilibrium and the solver's only residual was the water-pair
    // reprojection gap of SOLUTE-DUAL-ACTIVITY-COEFFICIENT-MERIT-FLOOR-001.
    // With that defect fixed there is nothing for the solver to do, so it takes
    // zero accelerated steps and an assertion that it took some cannot hold.
    //
    // Displacing a coordinate does NOT rescue it: a displacement produces no
    // residual when every rate that would respond is capped at zero. That was
    // measured -- a 4x displacement with the rates still capped left the
    // failure bit-identical, because a displacement produces no residual when
    // every rate that would respond is zero.
    //
    // So this solve gets the SAME physically coherent recipe the phosphate
    // solve at the end of this test already uses and is validated to converge
    // on: the realistic Ottawa H2PO4 concentration with pairing and
    // surface-exchange caps at their Ottawa magnitudes. Reusing a proven
    // combination rather than inventing one matters -- a first attempt with
    // `maximum_pairing_mol_per_m3_step = 1`, forty times the Ottawa value,
    // made the solver return `SoluteReactionSolverStagnated`, because
    // everything-at-1 with an aggressively enabled reaction is not a coherent
    // chemistry.
    //
    // The parameters are a local COPY. Bare `parameters` is shared with
    // `one_step` above, whose `iterations == 1` assertion depends on the
    // all-capped fixture, and with the physical-balance and conservation checks
    // between them; enabling a rate in place would silently change all three.
    state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 =
        0.050459466982896495;
    var accelerated_parameters = parameters;
    accelerated_parameters.phosphate_kinetics
        .maximum_pairing_mol_per_m3_step = 0.025;
    accelerated_parameters.phosphate_surface
        .maximum_exchange_mol_per_megagram_step = 0.0025;
    const result = try group_solve.solveCell(
        std.testing.allocator,
        &state,
        0,
        accelerated_parameters,
        .{ .max_iterations = 1000 },
    );
    try std.testing.expect(result.iterations < 1000);
    try std.testing.expect(result.converged);
    try std.testing.expect(result.newton_raphson_steps + result.picard_steps > 0);
    try std.testing.expectEqual(result.picard_steps, result.anderson_steps);
    try std.testing.expect(result.maximum_scaled_residual <= 1);

    // Standalone reproduction of the Ottawa limiting coordinate. Coupled
    // H2PO4 protonation, pairing, and surface exchange must retain access to
    // Newton/multisecant acceleration after the former 12-step cutoff.
    state.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 =
        0.050459466982896495;
    var phosphate_parameters = parameters;
    phosphate_parameters.phosphate_kinetics
        .maximum_pairing_mol_per_m3_step = 0.025;
    phosphate_parameters.phosphate_surface
        .maximum_exchange_mol_per_megagram_step = 0.0025;
    const phosphate_result = try group_solve.solveCell(
        std.testing.allocator,
        &state,
        0,
        phosphate_parameters,
        .{ .max_iterations = 1000 },
    );
    try std.testing.expect(phosphate_result.converged);
    try std.testing.expect(phosphate_result.maximum_scaled_residual <= 1);

    // A weathering rate is a once-per-timestep kinetic source, not an
    // equilibrium residual to be driven to zero or multiplied by MRXN.
    state.aqueous[0].hydrogen = 10;
    state.aqueous[0].aluminum = 0;
    state.aqueous[0].hydrogen_silicate = 0;
    state.aqueous[0].hydroxide = 0.00041020695203390634;
    state.geochemistry_solids[0]
        .aluminum_natural_silicate_mol_per_m3 = 1;
    state.geochemistry_solids[0].gibbsite_solid_mol_per_m3 =
        1691.7202939682704;
    var kinetic_parameters = parameters;
    kinetic_parameters.geochemistry_kinetics
        .maximum_natural_weathering_mol_per_m3_step = 5.0e-5;
    kinetic_parameters.geochemistry_kinetics
        .maximum_hydroxide_mineral_mol_per_m3_step = 0.0025;
    const family_preview = try state.evaluateGeochemistryTransformations(
        0,
        kinetic_parameters.fractions,
        kinetic_parameters.geochemistry_products,
        kinetic_parameters.geochemistry_kinetics,
    );
    try std.testing.expect(
        @abs(family_preview.gibbsite_solid_mol_per_m3) <= 0.0025,
    );
    try std.testing.expect(
        @abs(family_preview.aluminum_natural_silicate_mol_per_m3) <=
            5.0e-5,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0),
        family_preview.dissolved_aluminum_mol_per_m3 +
            family_preview.gibbsite_solid_mol_per_m3 +
            family_preview.aluminum_natural_silicate_mol_per_m3 +
            family_preview.aluminum_ground_silicate_mol_per_m3,
        1e-15,
    );
    const rock_before = state.geochemistry_solids[0]
        .aluminum_natural_silicate_mol_per_m3;
    const gibbsite_before =
        state.geochemistry_solids[0].gibbsite_solid_mol_per_m3;
    const kinetic_result = try group_solve.solveCell(
        std.testing.allocator,
        &state,
        0,
        kinetic_parameters,
        .{ .max_iterations = 1000 },
    );
    const weathered = rock_before - state.geochemistry_solids[0]
        .aluminum_natural_silicate_mol_per_m3;
    const gibbsite_change = @abs(
        gibbsite_before -
            state.geochemistry_solids[0].gibbsite_solid_mol_per_m3,
    );
    try std.testing.expect(kinetic_result.converged);
    try std.testing.expect(kinetic_result.iterations <= 1000);
    try std.testing.expect(weathered > 0);
    try std.testing.expect(weathered <= 5.0e-5 + 1e-14);
    // The authoritative solid is near 1.7e3 mol m-3, so subtracting its
    // before/after values loses several decimal ulps. Test the family extent
    // above directly; this observed-state check permits only that storage
    // roundoff, not an additional kinetic extent.
    const gibbsite_storage_roundoff =
        16 * std.math.floatEps(f64) * gibbsite_before;
    try std.testing.expect(
        gibbsite_change <= 0.0025 + gibbsite_storage_roundoff,
    );
}

test "complementarity candidate evaluation never clobbers the transactional rollback snapshot" {
    // Regression guard for the aliasing bug where evaluateComplementarityCandidate
    // passed workspace.rollback_state as tryAcceptAndersonCandidate's scratch
    // output parameter, which evaluateCandidateResidualAtFraction overwrites
    // unconditionally on every backtracking attempt -- corrupting the
    // pre-solve snapshot the outer solve's errdefer relies on to roll back a
    // failed cell. The fix gives the complementarity search its own
    // dedicated scratch buffer (workspace.complementarity_candidate_state)
    // instead of reusing rollback_state.
    var state = try chemistry.State.init(std.testing.allocator, 1);
    defer state.deinit();
    state.aqueous[0] = group_numerics2.filled(aqueous_network.State, 1);
    state.non_band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.band_phosphate[0] = group_numerics2.filled(phosphate_network.State, 1);
    state.cation_exchange_mol_per_megagram[0] = group_numerics2.filled(cation_exchange.Cations, 1);
    state.geochemistry_solids[0] = group_numerics2.filled(geochemistry.SolidState, 1);
    state.water_mol_per_m3[0] = 100;
    const parameters: chemistry.ReactionParameters = .{
        .fractions = .{ .ammonium_non_band = 0.8, .ammonium_band = 0.2, .nitrate_non_band = 0.6, .nitrate_band = 0.4, .phosphate_non_band = 0.7, .phosphate_band = 0.3 },
        .non_band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1,
        .band_phosphate_soil_mass_per_water_volume_megagrams_per_m3 = 1,
        .cation_exchange_capacity_mol_charge_per_megagram = 10,
        .cation_exchange_water_ratios = .{ .shared_megagrams_per_m3 = 1, .ammonium_non_band_megagrams_per_m3 = 1, .ammonium_band_megagrams_per_m3 = 1 },
        .total_carboxyl_sites_mol_per_megagram = 0,
        .carboxyl_exchange_parameters = .{ .dissociation_constant_mol_per_m3 = 0.01, .maximum_exchange_mol_per_m3_per_iteration = 0.01, .substrate_limit_fraction_per_iteration = 0.2 },
        .aqueous_constants = group_numerics2.filled(aqueous_rates.EquilibriumConstants, 1),
        .aqueous_kinetics = .{ .ammonium_substrate_limit_fraction = 0.2, .general_substrate_limit_fraction = 0.2, .maximum_fast_association_mol_per_m3_step = 0, .maximum_slow_association_mol_per_m3_step = 0 },
        .phosphate_constants = group_numerics2.filled(phosphate_rates.EquilibriumConstants, 1),
        .phosphate_surface = .{ .protonated_site_equilibrium_constant = 1, .hydroxyl_site_equilibrium_constant = 1, .h2po4_exchange_equilibrium_constant = 1, .hpo4_exchange_equilibrium_constant = 1, .water_activity_product_mol2_per_m6 = 1, .h2po4_dissociation_constant = 1, .maximum_exchange_mol_per_megagram_step = 0, .substrate_limit_fraction = 0.2 },
        .phosphate_minerals = null,
        .phosphate_kinetics = .{ .substrate_limit_fraction = 0.2, .maximum_pairing_mol_per_m3_step = 0 },
        .cation_exchange_parameters = .{ .selectivity = .{ .calcium_ammonium = 1, .calcium_hydrogen = 1, .calcium_aluminum_and_iron = 1, .calcium_magnesium = 1, .calcium_sodium = 1, .calcium_potassium = 1 }, .substrate_limit_fraction = 0.2, .maximum_adsorption_mol_charge_per_m3_step = 0 },
        .geochemistry_products = group_numerics2.filled(geochemistry_rates.SolubilityProducts, 1),
        .geochemistry_kinetics = .{ .general_substrate_limit_fraction = 0.2, .hydrogen_coupled_substrate_limit_fraction = 0.2, .maximum_hydroxide_mineral_mol_per_m3_step = 0, .maximum_general_mineral_mol_per_m3_step = 0, .calcite_hydroxide_inhibition_constant_mol_per_m3 = 1, .maximum_natural_weathering_mol_per_m3_step = 0, .maximum_ground_weathering_mol_per_m3_step = 0 },
        .water_activity_product_mol2_per_m6 = 1,
        .negligible_water_ion_concentration_mol_per_m3 = 1e-32,
    };

    var current: [chemistry.State.packedComponentCount()]f64 = undefined;
    try state.packCell(0, &current);

    var scratch = try chemistry.State.init(std.testing.allocator, 1);
    defer scratch.deinit();
    var workspace = try group_types.Workspace.init(std.testing.allocator);
    defer workspace.deinit();

    const sentinel = -999999.0;
    @memset(workspace.rollback_state, sentinel);
    var rollback_snapshot: [chemistry.State.packedComponentCount()]f64 = undefined;
    @memcpy(&rollback_snapshot, workspace.rollback_state);

    var residual_work: [chemistry.State.packedComponentCount()]f64 = undefined;

    // Mirror exactly what evaluateComplementarityCandidate now does: pass
    // complementarity_candidate_state (never rollback_state) as the
    // accepted_state scratch output. target == current is a degenerate but
    // fully valid candidate (the already-packed, already-validated cell),
    // so every internal unpack/repack step stays inside the physical domain
    // regardless of how many backtracking attempts occur.
    _ = try group_candidates.tryAcceptAndersonCandidate(
        &scratch,
        &current,
        &current,
        workspace.complementarity_candidate_state,
        &residual_work,
        parameters,
        .{},
        std.math.inf(f64),
    );

    try std.testing.expectEqualSlices(f64, &rollback_snapshot, workspace.rollback_state);
    try std.testing.expect(!std.mem.eql(f64, &rollback_snapshot, workspace.complementarity_candidate_state));
}

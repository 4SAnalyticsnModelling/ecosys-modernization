const std = @import("std");
const builtin = @import("builtin");
const grid_module = @import("../../state/grid.zig");
const hydrology_module = @import("../../transport/hydrology.zig");
const organic = @import("initialization.zig");
const face_parameters = @import("face_parameters.zig");
const numerics = @import("../../core/numerics.zig");
const scoped_conservation = @import("../../validation/scoped_conservation.zig");
const solute_transport = @import("../solute/transport.zig");

const maximum_dense_newton_components: usize = 256;

pub const component_count: usize = face_parameters.component_count;
pub const components_per_substrate: usize = face_parameters.components_per_substrate;
pub const Component = face_parameters.Component;

pub const State = struct {
    allocator: std.mem.Allocator,
    layer_count: usize,
    micropore_amount_g: []f64,
    macropore_amount_g: []f64,
    boundary_net_flux_g: []f64,

    pub fn init(allocator: std.mem.Allocator, layer_count: usize) !State {
        if (layer_count == 0) return error.ZeroSoilOrganicTransportLayers;
        const count = try std.math.mul(usize, layer_count, component_count);
        const micropore = try allocateZero(allocator, count);
        errdefer allocator.free(micropore);
        const macropore = try allocateZero(allocator, count);
        errdefer allocator.free(macropore);
        const boundary = try allocateZero(allocator, count);
        return .{ .allocator = allocator, .layer_count = layer_count, .micropore_amount_g = micropore, .macropore_amount_g = macropore, .boundary_net_flux_g = boundary };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.boundary_net_flux_g);
        self.allocator.free(self.macropore_amount_g);
        self.allocator.free(self.micropore_amount_g);
        self.* = undefined;
    }

    /// STARTS initializes dissolved organic matter in the matrix domain.
    pub fn initializeFromProfile(self: *State, profile: *const organic.State) !void {
        try validateProfileDimensions(self, profile);
        @memset(self.macropore_amount_g, 0);
        @memset(self.boundary_net_flux_g, 0);
        try self.exportMicroporeFromProfile(profile);
    }

    /// Exports the process-owned matrix pools immediately before TRNSFR.
    pub fn exportMicroporeFromProfile(self: *State, profile: *const organic.State) !void {
        try validateProfileDimensions(self, profile);
        for (0..self.layer_count) |layer| for (0..organic.substrate_count) |substrate| {
            const pool = profile.dissolved[layer * organic.substrate_count + substrate];
            const acetate = profile.dissolved_acetate_carbon_g_c[layer * organic.substrate_count + substrate];
            try validatePool(pool, acetate);
            const base = substrateBase(layer, substrate);
            self.micropore_amount_g[base + @intFromEnum(Component.dissolved_organic_carbon)] = pool.carbon_g_c;
            self.micropore_amount_g[base + @intFromEnum(Component.dissolved_organic_nitrogen)] = pool.nitrogen_g_n;
            self.micropore_amount_g[base + @intFromEnum(Component.dissolved_organic_phosphorus)] = pool.phosphorus_g_p;
            self.micropore_amount_g[base + @intFromEnum(Component.dissolved_acetate_carbon)] = acetate;
        };
    }

    /// Imports accepted TRNSFR matrix inventories for subsequent NITRO use.
    pub fn importMicroporeIntoProfile(self: *const State, profile: *organic.State) !void {
        try validateProfileDimensions(self, profile);
        for (0..self.layer_count) |layer| for (0..organic.substrate_count) |substrate| {
            const base = substrateBase(layer, substrate);
            profile.dissolved[layer * organic.substrate_count + substrate] = .{
                .carbon_g_c = self.micropore_amount_g[base + @intFromEnum(Component.dissolved_organic_carbon)],
                .nitrogen_g_n = self.micropore_amount_g[base + @intFromEnum(Component.dissolved_organic_nitrogen)],
                .phosphorus_g_p = self.micropore_amount_g[base + @intFromEnum(Component.dissolved_organic_phosphorus)],
            };
            profile.dissolved_acetate_carbon_g_c[layer * organic.substrate_count + substrate] = self.micropore_amount_g[base + @intFromEnum(Component.dissolved_acetate_carbon)];
        };
    }
};

pub const Options = struct {
    /// Component-specific nonlinear residual floors in C/N/P/C gram units.
    absolute_tolerance_g_by_component: [components_per_substrate]f64 = @splat(1e-12),
    /// Deprecated homogeneous override retained for focused legacy callers.
    /// Production mixed-element transport leaves this unset.
    absolute_tolerance_g: f64 = std.math.nan(f64),
    relative_tolerance: f64,
    picard_relaxation: f64,
    max_iterations: u16,
    maximum_convective_fraction: f64 = 1,
    /// Legacy `ZERO2`/`ZEROS2` aqueous minimum, per square metre of cell area
    /// (`ecosys_f77/starts.f:94` `ZERO2=1.0E-06`, area-scaled at
    /// `starts.f:270`; the comment at `starts.f:89` reads "minimum values used
    /// for all calculations").  Legacy TRNSFR guards every concentration and
    /// donor-fraction division with `IF(VOLW... .GT. ZEROS2(NY,NX))` and does
    /// no aqueous transport at all below it.
    ///
    /// A bare positivity test instead divides by denormal water: a real
    /// captured Ottawa column held `1.43e-35 m3` in its top layer, giving a
    /// diffusive fixed-point derivative of `conductance/water = 1.75e12`.  No
    /// nonlinear solver can close that map, so the solve burned its full
    /// 100-iteration budget and forced the hour into substep recovery.
    minimum_aqueous_water_m3_per_m2: f64 = 1e-6,
    pore_exchange_fraction: f64 = 1,
    /// Divergence/oscillation watch, mirroring `core/numerics.zig`. This
    /// solver is vector-valued over layers and components, so it cannot
    /// delegate to the shared scalar solver and carries its own detector.
    /// Consecutive iterations whose scaled norm exceeds
    /// `divergence_growth_factor` times the best norm seen are counted, and
    /// past `divergence_patience` of them the solve is diverging or
    /// oscillating.
    divergence_patience: u16 = 8,
    divergence_growth_factor: f64 = 1.0e3,
    /// Required depth-one Anderson recovery. The relaxed fixed-point sample
    /// seeds acceleration but is never accepted directly; false is rejected.
    anderson_recovery: bool = true,
    conservation_absolute_tolerance_g_per_m2_by_component: [components_per_substrate]f64 = @splat(0),
    conservation_relative_tolerance: f64 = 512 * std.math.floatEps(f64),
    soil_layer_capacity: usize = 0,
    horizontal_cell_area_m2: []const f64 = &.{},
    /// Maximum layer count for the per-component dense Newton Jacobian.
    /// Larger domains retain the O(n) directional Newton path. Zero disables
    /// dense transport Jacobians. Values above the internal 256-component
    /// safety cap are clamped.
    dense_newton_max_components: usize = 256,
};

pub const Inputs = struct {
    micropore_conductance_m3_per_step: []const f64,
    macropore_conductance_m3_per_step: []const f64,
    matrix_water_m3: []const f64,
    macropore_water_m3: []const f64,
    layer_bulk_volume_m3: []const f64,
    micropore_external_water_flux_m3_per_step: []const f64,
    macropore_external_water_flux_m3_per_step: []const f64,
    macropore_to_matrix_water_flux_m3_per_step: []const f64 = &.{},
    recharge_concentration_g_per_m3: []const f64,
    /// Accepted signed face fluxes in component grams. Positive is
    /// first_cell -> second_cell. Both pore-domain outputs are optional as a
    /// pair and publish only after the complete transport transaction.
    micropore_face_flux_g_by_component: ?[]f64 = null,
    macropore_face_flux_g_by_component: ?[]f64 = null,
    test_conservation_perturbation_g_by_component: ?[]const f64 = null,
};

pub const Result = struct {
    micropore_iterations: u16,
    macropore_iterations: u16,
    newton_raphson_steps: u16,
    picard_steps: u16,
    /// Recovery steps taken with the Anderson candidate rather than the plain
    /// relaxed Picard candidate. Counted inside `picard_steps` as well, so the
    /// existing step accounting is unchanged.
    anderson_steps: u16 = 0,
};

/// Atomic TRNSFR organic-solute step. The profile, both pore inventories, and
/// boundary ledger are published only after every solve and sufficiency check.
pub fn advance(
    allocator: std.mem.Allocator,
    state: *State,
    profile: *organic.State,
    faces: *const hydrology_module.SoilFaces,
    inputs: Inputs,
    options: Options,
) !Result {
    try validateAdvance(state, profile, faces, inputs, options);
    const profile_dissolved_before = try allocator.dupe(organic.ElementPool, profile.dissolved);
    defer allocator.free(profile_dissolved_before);
    const profile_acetate_before = try allocator.dupe(f64, profile.dissolved_acetate_carbon_g_c);
    defer allocator.free(profile_acetate_before);
    const micropore_before = try allocator.dupe(f64, state.micropore_amount_g);
    defer allocator.free(micropore_before);
    const macropore_before = try allocator.dupe(f64, state.macropore_amount_g);
    defer allocator.free(macropore_before);
    const boundary_before = try allocator.dupe(f64, state.boundary_net_flux_g);
    defer allocator.free(boundary_before);
    const face_component_count = try std.math.mul(usize, faces.micropore_faces.len, component_count);
    const micropore_face_candidate = try allocator.alloc(f64, face_component_count);
    defer allocator.free(micropore_face_candidate);
    const macropore_face_candidate = try allocator.alloc(f64, face_component_count);
    defer allocator.free(macropore_face_candidate);
    var state_updateted = false;
    defer if (!state_updateted) {
        @memcpy(profile.dissolved, profile_dissolved_before);
        @memcpy(profile.dissolved_acetate_carbon_g_c, profile_acetate_before);
        @memcpy(state.micropore_amount_g, micropore_before);
        @memcpy(state.macropore_amount_g, macropore_before);
        @memcpy(state.boundary_net_flux_g, boundary_before);
    };

    try state.exportMicroporeFromProfile(profile);
    const accepted_micropore_before = try allocator.dupe(f64, state.micropore_amount_g);
    defer allocator.free(accepted_micropore_before);
    const micropore_result = try solveDomain(allocator, state.micropore_amount_g, inputs.matrix_water_m3, faces.micropore_faces, inputs.micropore_conductance_m3_per_step, options, micropore_face_candidate);
    const macropore_result = try solveDomain(allocator, state.macropore_amount_g, inputs.macropore_water_m3, faces.macropore_faces, inputs.macropore_conductance_m3_per_step, options, macropore_face_candidate);
    @memset(state.boundary_net_flux_g, 0);
    for (0..state.layer_count) |layer| {
        if (!faces.active_by_layer[layer]) continue;
        try state_updateBoundary(state.micropore_amount_g[layer * component_count ..][0..component_count], inputs.matrix_water_m3[layer], inputs.micropore_external_water_flux_m3_per_step[layer], inputs.recharge_concentration_g_per_m3[layer * component_count ..][0..component_count], options.maximum_convective_fraction, state.boundary_net_flux_g[layer * component_count ..][0..component_count]);
        try state_updateBoundary(state.macropore_amount_g[layer * component_count ..][0..component_count], inputs.macropore_water_m3[layer], inputs.macropore_external_water_flux_m3_per_step[layer], inputs.recharge_concentration_g_per_m3[layer * component_count ..][0..component_count], options.maximum_convective_fraction, state.boundary_net_flux_g[layer * component_count ..][0..component_count]);
        for (0..component_count) |component| {
            const index = layer * component_count + component;
            const convective_exchange_g = try solute_transport.calculateConvectivePoreExchangeFlux(
                state.micropore_amount_g[index],
                state.macropore_amount_g[index],
                inputs.matrix_water_m3[layer],
                inputs.macropore_water_m3[layer],
                if (inputs.macropore_to_matrix_water_flux_m3_per_step.len == 0) 0 else inputs.macropore_to_matrix_water_flux_m3_per_step[layer],
                options.maximum_convective_fraction,
            );
            try solute_transport.state_updatePoreExchange(
                &state.micropore_amount_g[index],
                &state.macropore_amount_g[index],
                convective_exchange_g,
            );
            const exchange_g = try poreExchange(
                state.micropore_amount_g[index],
                state.macropore_amount_g[index],
                inputs.matrix_water_m3[layer],
                inputs.macropore_water_m3[layer],
                inputs.layer_bulk_volume_m3[layer],
                options.pore_exchange_fraction,
            );
            state.micropore_amount_g[index] += exchange_g;
            state.macropore_amount_g[index] -= exchange_g;
        }
    }
    if (inputs.test_conservation_perturbation_g_by_component) |perturbation|
        for (state.micropore_amount_g, perturbation) |*amount, change| {
            amount.* += change;
            if (!std.math.isFinite(amount.*) or amount.* < 0)
                return error.InvalidSoilOrganicConservationTestControl;
        };
    try requireLocalConservation(
        allocator,
        state,
        faces,
        accepted_micropore_before,
        macropore_before,
        micropore_face_candidate,
        macropore_face_candidate,
        options,
    );
    try state.importMicroporeIntoProfile(profile);
    if (inputs.micropore_face_flux_g_by_component) |output|
        @memcpy(output, micropore_face_candidate);
    if (inputs.macropore_face_flux_g_by_component) |output|
        @memcpy(output, macropore_face_candidate);
    state_updateted = true;
    return .{
        .micropore_iterations = micropore_result.iterations,
        .macropore_iterations = macropore_result.iterations,
        .newton_raphson_steps = micropore_result.newton_steps + macropore_result.newton_steps,
        .picard_steps = micropore_result.picard_steps + macropore_result.picard_steps,
        .anderson_steps = micropore_result.anderson_steps + macropore_result.anderson_steps,
    };
}

fn requireLocalConservation(
    allocator: std.mem.Allocator,
    state: *const State,
    faces: *const hydrology_module.SoilFaces,
    micropore_before: []const f64,
    macropore_before: []const f64,
    micropore_face_flux_g: []const f64,
    macropore_face_flux_g: []const f64,
    options: Options,
) !void {
    const signed_activity = try allocator.dupe(f64, state.boundary_net_flux_g);
    defer allocator.free(signed_activity);
    for (faces.micropore_faces, faces.macropore_faces, 0..) |micro_face, macro_face, face| {
        if (!faces.active_by_face[face]) continue;
        for (0..component_count) |component| {
            const face_component = face * component_count + component;
            const micro_flux = micropore_face_flux_g[face_component];
            signed_activity[micro_face.first_cell * component_count + component] -= micro_flux;
            signed_activity[micro_face.second_cell * component_count + component] += micro_flux;
            const macro_flux = macropore_face_flux_g[face_component];
            signed_activity[macro_face.first_cell * component_count + component] -= macro_flux;
            signed_activity[macro_face.second_cell * component_count + component] += macro_flux;
        }
    }
    for (0..state.layer_count) |layer| {
        if (!faces.active_by_layer[layer]) continue;
        const horizontal_cell = if (options.horizontal_cell_area_m2.len == 0)
            0
        else
            layer / options.soil_layer_capacity;
        for (0..component_count) |component| {
            const index = layer * component_count + component;
            const storage_before = micropore_before[index] + macropore_before[index];
            const storage_after = state.micropore_amount_g[index] + state.macropore_amount_g[index];
            const representation_floor = 64 * std.math.floatEps(f64) *
                @max(1, @max(@abs(storage_before), @abs(storage_after)));
            const configured_absolute = if (options.horizontal_cell_area_m2.len == 0)
                0
            else
                options.conservation_absolute_tolerance_g_per_m2_by_component[component % components_per_substrate] *
                    options.horizontal_cell_area_m2[horizontal_cell];
            const closure = try scoped_conservation.evaluate(.{
                .storage_before = storage_before,
                .storage_after = storage_after,
                .external_inputs = if (signed_activity[index] >= 0) signed_activity[index] else 0,
                .external_outputs = if (signed_activity[index] < 0) -signed_activity[index] else 0,
            }, .{
                .absolute = @max(configured_absolute, representation_floor),
                .relative = options.conservation_relative_tolerance,
            });
            if (!closure.accepted) {
                if (!builtin.is_test) std.log.err(
                    "soil organic local conservation failure: layer={d} component={d} residual_g={e} absolute_g={e} normalized_relative={e} limit_g={e}",
                    .{ layer, component, closure.residual, closure.absolute, closure.normalized_relative, closure.acceptance_limit },
                );
                return error.SoilOrganicLocalConservationFailure;
            }
        }
    }
}

const SolverResult = struct { iterations: u16, newton_steps: u16, picard_steps: u16, anderson_steps: u16 = 0 };

/// Failure-only, self-contained input for a local organic transport replay.
/// Omit the deprecated NaN override after folding it into the native-unit
/// component floors, so the capture is portable strict JSON.
const DomainFailureCapture = struct {
    base_g: []const f64,
    final_g: []const f64,
    water_m3: []const f64,
    faces: []const @import("../solute/transport.zig").Face,
    conductance: []const f64,
    options: Options,

    pub fn jsonStringify(self: @This(), stream: *std.json.Stringify) !void {
        try stream.beginObject();
        inline for (std.meta.fields(@This())) |field| {
            try stream.objectField(field.name);
            if (comptime std.mem.eql(u8, field.name, "options")) {
                try stream.beginObject();
                inline for (std.meta.fields(Options)) |option| {
                    if (comptime std.mem.eql(u8, option.name, "absolute_tolerance_g")) continue;
                    try stream.objectField(option.name);
                    if (comptime std.mem.eql(u8, option.name, "absolute_tolerance_g_by_component")) {
                        var floors: [components_per_substrate]f64 = undefined;
                        for (&floors, 0..) |*floor, component|
                            floor.* = absoluteToleranceForComponent(self.options, component);
                        try stream.write(floors);
                    } else try stream.write(@field(self.options, option.name));
                }
                try stream.endObject();
            } else try stream.write(@field(self, field.name));
        }
        try stream.endObject();
    }
};

fn solveDomain(allocator: std.mem.Allocator, amounts_g: []f64, water_m3: []const f64, faces: []const @import("../solute/transport.zig").Face, conductance: []const f64, options: Options, accepted_face_flux: ?[]f64) !SolverResult {
    const base = try allocator.dupe(f64, amounts_g);
    defer allocator.free(base);
    const current = try allocator.dupe(f64, base);
    defer allocator.free(current);
    const residual = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(residual);
    const probe = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(probe);
    const probe_residual = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(probe_residual);
    const candidate = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(candidate);
    const candidate_residual = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(candidate_residual);
    const dense_direction = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(dense_direction);
    const layer_count = amounts_g.len / component_count;
    const dense_matrix_elements = try denseMatrixElements(
        layer_count,
        options.dense_newton_max_components,
    );
    const dense_matrix = try allocator.alloc(f64, dense_matrix_elements);
    defer allocator.free(dense_matrix);
    const dense_rhs = try allocator.alloc(f64, layer_count);
    defer allocator.free(dense_rhs);
    const fixed_point = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(fixed_point);
    const publication_candidate = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(publication_candidate);
    const publication_residual = try allocator.alloc(f64, amounts_g.len);
    defer allocator.free(publication_residual);
    var newton_steps: u16 = 0;
    var picard_steps: u16 = 0;
    var anderson_steps: u16 = 0;
    // Divergence/oscillation watch state.
    var best_norm = std.math.inf(f64);
    var non_improving_steps: u16 = 0;
    var previous_norm = std.math.inf(f64);
    var insufficient_progress_steps: u16 = 0;
    var newton_retry_required = false;
    var iteration: u16 = 0;
    while (iteration < options.max_iterations) : (iteration += 1) {
        const retrying_newton_after_anderson = newton_retry_required;
        newton_retry_required = false;
        try residualAt(base, current, water_m3, faces, conductance, options, fixed_point, residual);
        const norm = try scaledNorm(current, residual, options);
        if (!retrying_newton_after_anderson and norm <= 1) {
            // F(current) is exactly conservative, but committing it without
            // evaluating its own residual is an unverified vanilla Picard
            // publication.  Only publish the conservative image after it too
            // satisfies the nonlinear tolerance; otherwise continue through
            // the normal Newton/Anderson recovery path from `current`.
            @memcpy(publication_candidate, fixed_point);
            try residualAt(base, publication_candidate, water_m3, faces, conductance, options, fixed_point, publication_residual);
            if (try scaledNorm(publication_candidate, publication_residual, options) <= 1) {
                if (accepted_face_flux) |output|
                    try captureAcceptedFaceFlux(base, current, water_m3, faces, conductance, options, residual, output);
                @memcpy(amounts_g, publication_candidate);
                return .{ .iterations = iteration + 1, .newton_steps = newton_steps, .picard_steps = picard_steps, .anderson_steps = anderson_steps };
            }
        }
        if (norm < best_norm) {
            best_norm = norm;
            non_improving_steps = 0;
        } else if (norm > options.divergence_growth_factor * best_norm) {
            non_improving_steps += 1;
            if (non_improving_steps >= options.divergence_patience) {
                std.log.warn("soil organic transport solver diverging: iteration={d} scaled_residual={e} best_scaled_residual={e} growth_factor={e} patience={d}", .{ iteration + 1, norm, best_norm, options.divergence_growth_factor, options.divergence_patience });
                return error.SoilOrganicTransportSolverDiverged;
            }
        } else {
            non_improving_steps = 0;
        }
        const progress_floor = std.math.sqrt(std.math.floatEps(f64)) * @max(1.0, previous_norm);
        if (std.math.isFinite(previous_norm) and previous_norm - norm <= progress_floor)
            insufficient_progress_steps +|= 1
        else
            insufficient_progress_steps = 0;
        previous_norm = norm;
        const progress_requires_anderson = insufficient_progress_steps >= 4;
        var accepted_newton = false;
        const limiting_index =
            try worstResidualIndex(current, residual, options);
        const limiting_component = limiting_index % component_count;
        if (layer_count <= @min(options.dense_newton_max_components, maximum_dense_newton_components) and
            (!progress_requires_anderson or retrying_newton_after_anderson))
        {
            // Try the exactly assembled inactive-clamp branch first. A dry
            // donor's saturated flux gives the local clamped Jacobian a flat
            // branch; repeatedly halving toward its narrow interior root can
            // consume the ceiling. This is only a Newton direction: the
            // original clamped residual, line search and publication gate
            // below remain authoritative. Reuse the existing dense scratch.
            for ([_]bool{ true, false }) |inactive_clamp_branch| {
                const have_direction = if (inactive_clamp_branch)
                    try inactiveClampComponentNewtonDirection(base, current, water_m3, faces, conductance, options, limiting_component, dense_matrix, dense_rhs, dense_direction)
                else
                    try denseComponentNewtonDirection(
                        base,
                        current,
                        residual,
                        water_m3,
                        faces,
                        conductance,
                        options,
                        limiting_component,
                        fixed_point,
                        probe,
                        probe_residual,
                        dense_matrix,
                        dense_rhs,
                        dense_direction,
                    );
                if (!have_direction) continue;
                var fraction: f64 = 1;
                var search: u8 = 0;
                while (search < 20) : (search += 1) {
                    if (addDirection(
                        current,
                        dense_direction,
                        fraction,
                        candidate,
                    )) |_| {
                        if (residualAt(
                            base,
                            candidate,
                            water_m3,
                            faces,
                            conductance,
                            options,
                            fixed_point,
                            candidate_residual,
                        )) |_| {
                            if (try scaledNorm(
                                candidate,
                                candidate_residual,
                                options,
                            ) < norm) {
                                @memcpy(current, candidate);
                                newton_steps += 1;
                                accepted_newton = true;
                                break;
                            }
                        } else |_| {}
                    } else |_| {}
                    fraction *= 0.5;
                }
                if (accepted_newton) break;
            }
        }
        if (accepted_newton) continue;
        if (!progress_requires_anderson or retrying_newton_after_anderson) {
            try addDirection(current, residual, 0.5, probe);
            try residualAt(base, probe, water_m3, faces, conductance, options, fixed_point, probe_residual);
            var numerator: f64 = 0;
            var denominator: f64 = 0;
            for (residual, probe_residual) |value, sampled| {
                const derivative = (sampled - value) / 0.5;
                numerator += value * derivative;
                denominator += derivative * derivative;
            }
            if (std.math.isFinite(denominator) and denominator > std.math.floatEps(f64)) {
                const fraction = std.math.clamp(-numerator / denominator, 0.05, 1.0);
                if (addDirection(current, residual, fraction, candidate)) |_| {
                    if (residualAt(base, candidate, water_m3, faces, conductance, options, fixed_point, candidate_residual)) |_| {
                        if (try scaledNorm(candidate, candidate_residual, options) < norm) {
                            @memcpy(current, candidate);
                            newton_steps += 1;
                            accepted_newton = true;
                        }
                    } else |_| {}
                } else |_| {}
            }
        }
        if (accepted_newton) continue;
        if (retrying_newton_after_anderson) continue;
        if (iteration + 1 >= options.max_iterations)
            return error.SoilOrganicTransportDidNotConverge;
        // Sole fallback: seed depth-one Anderson with a same-iteration relaxed
        // fixed-point evaluation; never commit the relaxed point itself.
        try addDirection(current, residual, options.picard_relaxation, candidate);
        try residualAt(base, candidate, water_m3, faces, conductance, options, fixed_point, candidate_residual);
        if (!numerics.andersonDepthOneCandidate(current, residual, candidate, candidate_residual, probe)) return error.SoilOrganicTransportSolverStagnated;
        for (probe) |*value| {
            if (!std.math.isFinite(value.*) or value.* < 0) return error.SoilOrganicTransportSolverStagnated;
        }
        try residualAt(base, probe, water_m3, faces, conductance, options, fixed_point, probe_residual);
        const anderson_norm = try scaledNorm(probe, probe_residual, options);
        if (!numerics.andersonImprovesAcceptedMerit(anderson_norm, norm)) return error.SoilOrganicTransportSolverStagnated;
        @memcpy(current, probe);
        anderson_steps += 1;
        picard_steps += 1;
        newton_retry_required = true;
    }
    try residualAt(
        base,
        current,
        water_m3,
        faces,
        conductance,
        options,
        fixed_point,
        residual,
    );
    const final_norm = try scaledNorm(current, residual, options);
    // `newton_retry_required` exists to stop the LOOP from publishing straight
    // off an Anderson extrapolation without a following Newton verification.
    // It must not gate this post-loop branch: the residual above is a fresh,
    // independent evaluation at `current`, the publication image is evaluated
    // again below, and the Anderson iterate that produced `current` was itself
    // residual-evaluated, merit-improving and checked finite/nonnegative before
    // it was committed.  Gating here only discards a fully verified converged
    // endpoint and forces the caller into an hourly substep recovery.
    if (final_norm <= 1) {
        @memcpy(publication_candidate, fixed_point);
        try residualAt(base, publication_candidate, water_m3, faces, conductance, options, fixed_point, publication_residual);
        if (try scaledNorm(publication_candidate, publication_residual, options) <= 1) {
            if (accepted_face_flux) |output|
                try captureAcceptedFaceFlux(base, current, water_m3, faces, conductance, options, residual, output);
            @memcpy(amounts_g, publication_candidate);
            return .{
                .iterations = options.max_iterations,
                .newton_steps = newton_steps,
                .picard_steps = picard_steps,
                .anderson_steps = anderson_steps,
            };
        }
    }
    const limiting_index =
        try worstResidualIndex(current, residual, options);
    const limiting_layer = limiting_index / component_count;
    const limiting_component = limiting_index % component_count;
    std.log.err(
        "soil organic transport Newton-Picard exhausted runtime ceiling: max_iterations={d} scaled_residual={e} layer={d} substrate={d} component={d} amount_g={e} residual_g={e} newton_steps={d} picard_steps={d}",
        .{
            options.max_iterations,
            final_norm,
            limiting_layer,
            limiting_component / components_per_substrate,
            limiting_component % components_per_substrate,
            current[limiting_index],
            residual[limiting_index],
            newton_steps,
            picard_steps,
        },
    );
    if (!builtin.is_test) {
        const capture = std.json.Stringify.valueAlloc(allocator, DomainFailureCapture{
            .base_g = base,
            .final_g = current,
            .water_m3 = water_m3,
            .faces = faces,
            .conductance = conductance,
            .options = options,
        }, .{}) catch return error.SoilOrganicTransportDidNotConverge;
        defer allocator.free(capture);
        std.log.err("ORGANIC_FAILURE_INPUT {s}", .{capture});
    }
    return error.SoilOrganicTransportDidNotConverge;
}

/// Internal TRNSFR faces only redistribute each organic component. Newton or
/// Picard convergence controls the local equations, but a tolerance-sized sum
/// of residuals must not become a landscape source. Correct the roundoff-sized
/// closure remainder in the largest receiving pool before accepting the solve.
fn enforceInternalConservation(base: []const f64, current: []f64) !void {
    if (base.len == 0 or base.len != current.len or
        base.len % component_count != 0)
        return error.SoilOrganicTransportDimensionMismatch;
    const layer_count = base.len / component_count;
    for (0..component_count) |component| {
        var base_total: f64 = 0;
        var current_total: f64 = 0;
        var largest_index = component;
        for (0..layer_count) |layer| {
            const index = layer * component_count + component;
            const before = base[index];
            const after = current[index];
            if (!std.math.isFinite(before) or before < 0 or
                !std.math.isFinite(after) or after < 0)
                return error.NonFiniteSoilOrganicTransport;
            base_total += before;
            current_total += after;
            if (after > current[largest_index]) largest_index = index;
        }
        const correction = base_total - current_total;
        const corrected = current[largest_index] + correction;
        if (!std.math.isFinite(corrected) or corrected < 0)
            return error.SoilOrganicTransportConservationFailure;
        current[largest_index] = corrected;
    }
}

/// Newton solve of the affine constitutive branch where no face availability
/// cap binds. All coefficients retain the production donor fraction and dry
/// water convention. A non-binding solution is the exact implicit transport
/// root; otherwise it is merely a candidate direction checked against the
/// unchanged, source-ordered capped residual by the caller.
fn inactiveClampComponentNewtonDirection(
    base: []const f64,
    current: []const f64,
    water_m3: []const f64,
    faces: []const @import("../solute/transport.zig").Face,
    conductance: []const f64,
    options: Options,
    component: usize,
    matrix: []f64,
    rhs: []f64,
    direction: []f64,
) !bool {
    const layers = water_m3.len;
    if (component >= component_count or base.len != layers * component_count or
        current.len != base.len or direction.len != base.len or
        matrix.len != layers * layers or rhs.len != layers or
        conductance.len != faces.len * component_count)
        return error.SoilOrganicTransportDimensionMismatch;
    @memset(matrix, 0);
    @memset(direction, 0);
    for (0..layers) |layer| {
        matrix[layer * layers + layer] = 1;
        rhs[layer] = base[layer * component_count + component];
    }
    const minimum_water_m3 = try minimumAqueousWaterM3(options);
    for (faces, 0..) |face, face_index| {
        if (!face.active) continue;
        const first = face.first_cell;
        const second = face.second_cell;
        // Keep the linearization consistent with `residualAt`: a term that is
        // gated off there must contribute no Jacobian coupling here, otherwise
        // the Newton direction is built from a flux that never flows.
        const donor_fraction =
            convectiveDonorFraction(water_m3, face, options.maximum_convective_fraction, minimum_water_m3);
        const diffuses = diffusiveFace(water_m3, face, minimum_water_m3);
        const diffusion = if (diffuses) conductance[face_index * component_count + component] else 0;
        const first_coefficient = (if (diffuses) diffusion / water_m3[first] else 0) +
            (if (face.water_flux_m3_per_step >= 0) donor_fraction else 0);
        const second_coefficient = (if (diffuses) diffusion / water_m3[second] else 0) +
            (if (face.water_flux_m3_per_step < 0) donor_fraction else 0);
        if (!std.math.isFinite(first_coefficient) or !std.math.isFinite(second_coefficient)) return false;
        matrix[first * layers + first] += first_coefficient;
        matrix[first * layers + second] -= second_coefficient;
        matrix[second * layers + first] -= first_coefficient;
        matrix[second * layers + second] += second_coefficient;
    }
    for (matrix) |value| if (!std.math.isFinite(value)) return false;
    if (!numerics.solveDenseLinearSystem(matrix, rhs, layers)) return false;
    for (rhs, 0..) |value, layer| {
        if (!std.math.isFinite(value) or value < 0) return false;
        const index = layer * component_count + component;
        direction[index] = value - current[index];
        if (!std.math.isFinite(direction[index])) return false;
    }
    return true;
}

fn denseComponentNewtonDirection(
    base: []const f64,
    current: []const f64,
    residual: []const f64,
    water_m3: []const f64,
    faces: []const @import("../solute/transport.zig").Face,
    conductance: []const f64,
    options: Options,
    component: usize,
    fixed_point: []f64,
    sampled_state: []f64,
    sampled_residual: []f64,
    matrix: []f64,
    rhs: []f64,
    direction: []f64,
) !bool {
    const layer_count = current.len / component_count;
    if (component >= component_count or
        current.len % component_count != 0 or
        matrix.len != layer_count * layer_count or
        rhs.len != layer_count or
        direction.len != current.len)
        return error.SoilOrganicTransportDimensionMismatch;
    @memset(direction, 0);
    for (0..layer_count) |row|
        rhs[row] = -residual[row * component_count + component];
    for (0..layer_count) |column| {
        const state_index = column * component_count + component;
        const probe_delta = denseProbeDelta(
            current[state_index],
            residual[state_index],
            component,
            options,
        );
        if (probe_delta == 0) return false;
        @memcpy(sampled_state, current);
        sampled_state[state_index] += probe_delta;
        if (!std.math.isFinite(sampled_state[state_index]) or
            sampled_state[state_index] < 0 or
            sampled_state[state_index] == current[state_index]) return false;
        residualAt(
            base,
            sampled_state,
            water_m3,
            faces,
            conductance,
            options,
            fixed_point,
            sampled_residual,
        ) catch return false;
        for (0..layer_count) |row| {
            const residual_index =
                row * component_count + component;
            matrix[row * layer_count + column] =
                (sampled_residual[residual_index] -
                    residual[residual_index]) /
                probe_delta;
        }
    }
    if (!numerics.solveDenseLinearSystem(
        matrix,
        rhs,
        layer_count,
    )) return false;
    for (rhs, 0..) |value, layer|
        direction[layer * component_count + component] = value;
    return true;
}

fn denseProbeDelta(
    amount_g: f64,
    residual_g: f64,
    component: usize,
    options: Options,
) f64 {
    const coordinate_scale = @max(
        absoluteToleranceForComponent(options, component),
        @abs(amount_g),
    );
    const nominal_magnitude =
        @sqrt(std.math.floatEps(f64)) * coordinate_scale;
    if (residual_g < 0 and amount_g > 0) {
        const sampled_amount_g = amount_g -
            @min(nominal_magnitude, 0.5 * amount_g);
        if (sampled_amount_g != amount_g)
            return sampled_amount_g - amount_g;
        return std.math.nextAfter(f64, amount_g, 0) - amount_g;
    }
    const sampled_amount_g = amount_g + nominal_magnitude;
    if (std.math.isFinite(sampled_amount_g) and sampled_amount_g != amount_g)
        return sampled_amount_g - amount_g;
    return std.math.nextAfter(f64, amount_g, std.math.inf(f64)) - amount_g;
}

/// Legacy `ZEROS2(NY,NX) = ZERO2*DH*DV` (`ecosys_f77/starts.f:270`). The solve
/// covers one vertical column, so every layer shares that column's area.
fn minimumAqueousWaterM3(options: Options) !f64 {
    if (!std.math.isFinite(options.minimum_aqueous_water_m3_per_m2) or
        options.minimum_aqueous_water_m3_per_m2 < 0)
        return error.InvalidSoilOrganicAqueousWaterMinimum;
    if (options.horizontal_cell_area_m2.len == 0)
        return options.minimum_aqueous_water_m3_per_m2;
    const area_m2 = options.horizontal_cell_area_m2[0];
    if (!std.math.isFinite(area_m2) or area_m2 <= 0)
        return error.InvalidSoilOrganicAqueousWaterMinimum;
    return options.minimum_aqueous_water_m3_per_m2 * area_m2;
}

/// Legacy TRNSFR guards its two transport terms DIFFERENTLY, and conflating
/// them suppresses real leaching.
///
/// Convection (`ecosys_f77/trnsfr.f:4052-4058`, whose `DO 9820 K=0,4` loop
/// carries exactly these `OQC/OQN/OQP/OQA` components) runs only inside
/// `IF(FLWM.GT.0.0)`, and when the donor's carrier volume is at or below
/// `ZEROS2` the transported fraction SATURATES at `VFLWX` rather than
/// vanishing -- the carrier volume is unresolvable, not absent:
///
///     IF(VOLWM(M,N3,N2,N1).GT.ZEROS2(N2,N1))THEN
///     VFLW=AMAX1(0.0,AMIN1(VFLWX,FLWM(...)/VOLWM(M,N3,N2,N1)))
///     ELSE
///     VFLW=VFLWX
///
/// Diffusion (`trnsfr.f:4126-4129`) is skipped entirely unless BOTH cells hold
/// more than `ZEROS2`, because a concentration difference is undefined without
/// an aqueous phase on both sides. That guard is what this module was missing.
fn diffusiveFace(water: []const f64, face: @import("../solute/transport.zig").Face, minimum_water_m3: f64) bool {
    return water[face.first_cell] > minimum_water_m3 and
        water[face.second_cell] > minimum_water_m3;
}

/// The `VFLW` of `trnsfr.f:4052-4058`. Zero water flux carries nothing; the
/// legacy outer `IF(FLWM.GT.0.0)` skips the convective block entirely, so a
/// bare `else maximum_fraction` on an unresolvable donor would convect a whole
/// pool across a face with no water movement at all.
fn convectiveDonorFraction(
    water: []const f64,
    face: @import("../solute/transport.zig").Face,
    maximum_fraction: f64,
    minimum_water_m3: f64,
) f64 {
    if (face.water_flux_m3_per_step == 0) return 0;
    const donor = if (face.water_flux_m3_per_step > 0) face.first_cell else face.second_cell;
    const donor_water_m3 = water[donor];
    if (donor_water_m3 <= minimum_water_m3) return maximum_fraction;
    return @min(maximum_fraction, @abs(face.water_flux_m3_per_step) / donor_water_m3);
}

fn residualAt(base: []const f64, trial: []const f64, water: []const f64, faces: []const @import("../solute/transport.zig").Face, conductance: []const f64, options: Options, fixed_point: []f64, residual: []f64) !void {
    const maximum_fraction = options.maximum_convective_fraction;
    const minimum_water_m3 = try minimumAqueousWaterM3(options);
    @memcpy(fixed_point, base);
    for (faces, 0..) |face, face_index| {
        if (!face.active) continue;
        const donor_fraction = convectiveDonorFraction(water, face, maximum_fraction, minimum_water_m3);
        const diffuses = diffusiveFace(water, face, minimum_water_m3);
        for (0..component_count) |component| {
            const first = face.first_cell * component_count + component;
            const second = face.second_cell * component_count + component;
            const convection = if (face.water_flux_m3_per_step >= 0) donor_fraction * trial[first] else -donor_fraction * trial[second];
            const diffusion = if (diffuses)
                conductance[face_index * component_count + component] *
                    (trial[first] / water[face.first_cell] - trial[second] / water[face.second_cell])
            else
                0;
            const flux = std.math.clamp(convection + diffusion, -fixed_point[second], fixed_point[first]);
            fixed_point[first] -= flux;
            fixed_point[second] += flux;
        }
    }
    for (fixed_point, trial, residual) |target, value, *difference| {
        difference.* = target - value;
        if (!std.math.isFinite(difference.*)) return error.NonFiniteSoilOrganicTransport;
    }
}

fn captureAcceptedFaceFlux(
    base: []const f64,
    trial: []const f64,
    water: []const f64,
    faces: []const @import("../solute/transport.zig").Face,
    conductance: []const f64,
    options: Options,
    accumulator: []f64,
    output: []f64,
) !void {
    const maximum_fraction = options.maximum_convective_fraction;
    const minimum_water_m3 = try minimumAqueousWaterM3(options);
    if (accumulator.len != base.len or output.len != faces.len * component_count)
        return error.SoilOrganicFaceFluxOutputDimensionMismatch;
    @memcpy(accumulator, base);
    @memset(output, 0);
    for (faces, 0..) |face, face_index| {
        if (!face.active) continue;
        // Mirrors the two-term gating in `residualAt`; the published ledger
        // must reconstruct exactly the endpoint the solver accepted.
        const donor_fraction = convectiveDonorFraction(water, face, maximum_fraction, minimum_water_m3);
        const diffuses = diffusiveFace(water, face, minimum_water_m3);
        for (0..component_count) |component| {
            const first = face.first_cell * component_count + component;
            const second = face.second_cell * component_count + component;
            const convection = if (face.water_flux_m3_per_step >= 0) donor_fraction * trial[first] else -donor_fraction * trial[second];
            const diffusion = if (diffuses)
                conductance[face_index * component_count + component] *
                    (trial[first] / water[face.first_cell] - trial[second] / water[face.second_cell])
            else
                0;
            const flux = std.math.clamp(convection + diffusion, -accumulator[second], accumulator[first]);
            if (!std.math.isFinite(flux)) return error.NonFiniteSoilOrganicTransport;
            accumulator[first] -= flux;
            accumulator[second] += flux;
            output[face_index * component_count + component] = flux;
        }
    }
}

fn state_updateBoundary(amounts: []f64, water_m3: f64, outward_water_m3: f64, recharge_g_per_m3: []const f64, maximum_fraction: f64, ledger: []f64) !void {
    for (amounts, recharge_g_per_m3, ledger) |*amount, recharge, *net| {
        const change = if (outward_water_m3 >= 0)
            -amount.* * (if (water_m3 > 0) @min(maximum_fraction, outward_water_m3 / water_m3) else maximum_fraction)
        else
            -outward_water_m3 * recharge;
        if (!std.math.isFinite(change) or amount.* + change < 0 or !std.math.isFinite(net.* + change)) return error.InvalidSoilOrganicBoundaryFlux;
        amount.* += change;
        net.* += change;
    }
}

fn poreExchange(micro_g: f64, macro_g: f64, micro_water_m3: f64, macro_water_m3: f64, bulk_volume_m3: f64, fraction: f64) !f64 {
    if (macro_water_m3 == 0) return 0;
    const exchanging_macro_water_m3 = @min(0.05 * bulk_volume_m3, macro_water_m3);
    const combined_water_m3 = micro_water_m3 + exchanging_macro_water_m3;
    if (combined_water_m3 == 0) return 0;
    const exchange = fraction * (macro_g * micro_water_m3 - micro_g * exchanging_macro_water_m3) / combined_water_m3;
    if (!std.math.isFinite(exchange)) return error.NonFiniteSoilOrganicPoreExchange;
    return std.math.clamp(exchange, -micro_g, macro_g);
}

fn maximumDifference(a: []const f64, b: []const f64) f64 {
    var maximum: f64 = 0;
    for (a, b) |left, right| maximum = @max(maximum, @abs(left - right));
    return maximum;
}

fn maximumMagnitude(values: []const f64) f64 {
    var maximum: f64 = 0;
    for (values) |value| maximum = @max(maximum, @abs(value));
    return maximum;
}

fn absoluteToleranceForComponent(options: Options, component_index: usize) f64 {
    return if (std.math.isFinite(options.absolute_tolerance_g) and options.absolute_tolerance_g > 0)
        options.absolute_tolerance_g
    else
        options.absolute_tolerance_g_by_component[component_index % components_per_substrate];
}

fn componentScale(value: f64, component_index: usize, options: Options) f64 {
    // The component-specific absolute floor controls trace pools; the relative
    // term scales only with this component's represented gram inventory.  Do
    // not add a second, looser relative floor here: doing so silently changes
    // a configured 1e-8 tolerance into per-mille acceptance for large pools.
    return absoluteToleranceForComponent(options, component_index) +
        options.relative_tolerance * @abs(value);
}

fn scaledNorm(state: []const f64, residual: []const f64, options: Options) !f64 {
    var maximum: f64 = 0;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(value) or value < 0 or !std.math.isFinite(difference)) return error.NonFiniteSoilOrganicTransport;
        maximum = @max(maximum, @abs(difference) / componentScale(value, index, options));
    }
    return maximum;
}

fn worstResidualIndex(
    state: []const f64,
    residual: []const f64,
    options: Options,
) !usize {
    if (state.len == 0 or state.len != residual.len)
        return error.NonFiniteSoilOrganicTransport;
    var limiting_index: usize = 0;
    var limiting_norm: f64 = -1;
    for (state, residual, 0..) |value, difference, index| {
        if (!std.math.isFinite(value) or value < 0 or
            !std.math.isFinite(difference))
            return error.NonFiniteSoilOrganicTransport;
        const norm = @abs(difference) / componentScale(value, index, options);
        if (norm > limiting_norm) {
            limiting_norm = norm;
            limiting_index = index;
        }
    }
    return limiting_index;
}

fn addDirection(current: []const f64, direction: []const f64, fraction: f64, output: []f64) !void {
    for (current, direction, output) |value, change, *candidate| {
        candidate.* = value + fraction * change;
        if (!std.math.isFinite(candidate.*) or candidate.* < 0) return error.InvalidSoilOrganicTransportCandidate;
    }
}

fn substrateBase(layer: usize, substrate: usize) usize {
    return layer * component_count + substrate * components_per_substrate;
}

fn validateAdvance(state: *const State, profile: *const organic.State, faces: *const hydrology_module.SoilFaces, inputs: Inputs, options: Options) !void {
    try validateProfileDimensions(state, profile);
    const layers = state.layer_count;
    const amounts = layers * component_count;
    const face_components = faces.micropore_faces.len * component_count;
    if (faces.macropore_faces.len != faces.micropore_faces.len or faces.active_by_face.len != faces.micropore_faces.len or faces.active_by_layer.len != layers or inputs.micropore_conductance_m3_per_step.len != face_components or inputs.macropore_conductance_m3_per_step.len != face_components or inputs.matrix_water_m3.len != layers or inputs.macropore_water_m3.len != layers or inputs.layer_bulk_volume_m3.len != layers or inputs.micropore_external_water_flux_m3_per_step.len != layers or inputs.macropore_external_water_flux_m3_per_step.len != layers or (inputs.macropore_to_matrix_water_flux_m3_per_step.len != 0 and inputs.macropore_to_matrix_water_flux_m3_per_step.len != layers) or inputs.recharge_concentration_g_per_m3.len != amounts) return error.SoilOrganicTransportDimensionMismatch;
    if ((inputs.micropore_face_flux_g_by_component == null) != (inputs.macropore_face_flux_g_by_component == null)) return error.SoilOrganicTransportDimensionMismatch;
    if (inputs.micropore_face_flux_g_by_component) |values|
        if (values.len != face_components or inputs.macropore_face_flux_g_by_component.?.len != face_components)
            return error.SoilOrganicTransportDimensionMismatch;
    if (inputs.test_conservation_perturbation_g_by_component) |perturbation| {
        if (!builtin.is_test) return error.InvalidSoilOrganicConservationTestControl;
        if (perturbation.len != amounts) return error.SoilOrganicTransportDimensionMismatch;
    }
    for (options.absolute_tolerance_g_by_component) |tolerance_g|
        if (!std.math.isFinite(tolerance_g) or tolerance_g <= 0) return error.InvalidSoilOrganicTransportOptions;
    for (options.conservation_absolute_tolerance_g_per_m2_by_component) |tolerance_g|
        if (!std.math.isFinite(tolerance_g) or tolerance_g < 0) return error.InvalidSoilOrganicTransportOptions;
    if ((!std.math.isNan(options.absolute_tolerance_g) and (!std.math.isFinite(options.absolute_tolerance_g) or options.absolute_tolerance_g <= 0)) or
        !std.math.isFinite(options.relative_tolerance) or options.relative_tolerance <= 0 or
        !std.math.isFinite(options.conservation_relative_tolerance) or options.conservation_relative_tolerance < 0 or
        !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or
        !std.math.isFinite(options.maximum_convective_fraction) or options.maximum_convective_fraction < 0 or options.maximum_convective_fraction > 1 or
        !std.math.isFinite(options.pore_exchange_fraction) or options.pore_exchange_fraction < 0 or options.pore_exchange_fraction > 1 or
        options.divergence_patience == 0 or !options.anderson_recovery or !std.math.isFinite(options.divergence_growth_factor) or options.divergence_growth_factor < 1)
        return error.InvalidSoilOrganicTransportOptions;
    if (options.horizontal_cell_area_m2.len != 0) {
        if (options.soil_layer_capacity == 0 or
            state.layer_count != try std.math.mul(usize, options.horizontal_cell_area_m2.len, options.soil_layer_capacity))
            return error.SoilOrganicTransportDimensionMismatch;
        for (options.horizontal_cell_area_m2) |area|
            if (!std.math.isFinite(area) or area <= 0) return error.InvalidSoilOrganicTransportOptions;
    }
    if (options.max_iterations == 0) return error.InvalidSoilOrganicTransportOptions;
    for (inputs.matrix_water_m3, inputs.macropore_water_m3, inputs.layer_bulk_volume_m3, inputs.micropore_external_water_flux_m3_per_step, inputs.macropore_external_water_flux_m3_per_step, faces.active_by_layer) |micro, macro, bulk, micro_boundary, macro_boundary, active| {
        inline for (.{ micro, macro, bulk, micro_boundary, macro_boundary }) |value| if (!std.math.isFinite(value)) return error.InvalidSoilOrganicTransportInput;
        if (micro < 0 or macro < 0 or bulk < 0 or (active and bulk == 0)) return error.InvalidSoilOrganicTransportInput;
    }
    for (inputs.recharge_concentration_g_per_m3) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilOrganicTransportInput;
}

fn validateProfileDimensions(state: *const State, profile: *const organic.State) !void {
    if (profile.layer_count != state.layer_count or profile.dissolved.len != state.layer_count * organic.substrate_count or profile.dissolved_acetate_carbon_g_c.len != profile.dissolved.len) return error.SoilOrganicTransportDimensionMismatch;
}

fn validatePool(pool: organic.ElementPool, acetate: f64) !void {
    inline for (.{ pool.carbon_g_c, pool.nitrogen_g_n, pool.phosphorus_g_p, acetate }) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidSoilOrganicTransportPool;
}

fn allocateZero(allocator: std.mem.Allocator, count: usize) ![]f64 {
    const values = try allocator.alloc(f64, count);
    @memset(values, 0);
    return values;
}

fn denseMatrixElements(layer_count: usize, maximum_dense_components: usize) !usize {
    if (layer_count > @min(maximum_dense_components, maximum_dense_newton_components)) return 0;
    return std.math.mul(usize, layer_count, layer_count);
}

test "organic transport omits the dense Jacobian above its threshold" {
    try std.testing.expectEqual(@as(usize, 100), try denseMatrixElements(10, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(257, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(20_000, 256));
    try std.testing.expectEqual(@as(usize, 0), try denseMatrixElements(20_000, std.math.maxInt(usize)));
}

// All three captured Ottawa organic transport failures share one root cause: the
// DIFFUSIVE concentration difference was guarded by a bare `water > 0` instead
// of legacy `ZEROS2` (`ecosys_f77/starts.f:94,270`; the four-condition gate at
// `trnsfr.f:4126-4129`).  Every one of these columns is frozen dry -- the
// deepest ten layers hold exactly zero water and the top layer ~1e-35 m3
// against a 1e-6 m3 floor -- so legacy computes no diffusive organic flux in
// them.  Dividing by 1e-35 instead gave the fixed-point map a derivative of
// `conductance/water = 1.75e12`, which no nonlinear solver can close: the third
// capture burned all 100 iterations and forced its hour to re-run at 20
// substeps.
//
// Convection is deliberately NOT suppressed: `trnsfr.f:4052-4058` saturates the
// donor fraction at `VFLWX` below `ZEROS2` rather than zeroing it, so leaching
// driven by a real water flux still occurs.  These captures have a nonzero flux
// on face 0, so this test pins that the two terms are gated separately.
test "captured frozen-dry Ottawa columns diffuse no organic matter but still leach" {
    inline for (.{
        @embedFile("ottawa_winter_organic_failure_1.json"),
        @embedFile("ottawa_winter_organic_failure_2.json"),
        @embedFile("ottawa_organic_anderson_discard_20260910.json"),
    }) |source| {
        const parsed = try std.json.parseFromSlice(DomainFailureCapture, std.testing.allocator, source, .{});
        defer parsed.deinit();
        const input = parsed.value;

        const amounts = try std.testing.allocator.dupe(f64, input.base_g);
        defer std.testing.allocator.free(amounts);
        const face_flux = try std.testing.allocator.alloc(f64, input.faces.len * component_count);
        defer std.testing.allocator.free(face_flux);

        const solved = try solveDomain(
            std.testing.allocator,
            amounts,
            input.water_m3,
            input.faces,
            input.conductance,
            input.options,
            face_flux,
        );

        // Establish the premise from the captured data rather than asserting it:
        // every layer really is below the legacy aqueous minimum.
        const minimum_water_m3 = try minimumAqueousWaterM3(input.options);
        try std.testing.expectEqual(@as(f64, 1e-6), minimum_water_m3);
        for (input.water_m3) |water| try std.testing.expect(water <= minimum_water_m3);

        // No layer pair can diffuse, so every diffusive coupling is gone and
        // the map is well conditioned: the solve closes well inside the budget
        // it used to exhaust.
        for (input.faces) |face| try std.testing.expect(!diffusiveFace(input.water_m3, face, minimum_water_m3));
        try std.testing.expect(solved.iterations < input.options.max_iterations);

        // Convective leaching survives the floor. Face 0 carries a real water
        // flux, so its donor fraction saturates at VFLWX exactly as
        // trnsfr.f:4052-4058 prescribes, and organic matter still moves.
        try std.testing.expect(input.faces[0].water_flux_m3_per_step > 0);
        try std.testing.expectEqual(
            input.options.maximum_convective_fraction,
            convectiveDonorFraction(input.water_m3, input.faces[0], input.options.maximum_convective_fraction, minimum_water_m3),
        );
        var published_movement_g: f64 = 0;
        for (amounts, input.base_g) |published, initial|
            published_movement_g = @max(published_movement_g, @abs(published - initial));
        try std.testing.expect(published_movement_g > 0);

        // Faces with no water flux carry nothing, even below the floor: the
        // legacy outer `IF(FLWM.GT.0.0)` skips the convective block entirely.
        for (input.faces, 0..) |face, face_index| {
            if (face.water_flux_m3_per_step != 0) continue;
            for (0..component_count) |component|
                try std.testing.expectEqual(@as(f64, 0), face_flux[face_index * component_count + component]);
        }

        const target = try std.testing.allocator.alloc(f64, amounts.len);
        defer std.testing.allocator.free(target);
        const residual = try std.testing.allocator.alloc(f64, amounts.len);
        defer std.testing.allocator.free(residual);

        // The published endpoint satisfies the module's own nonlinear criterion,
        // and every published amount stays finite and nonnegative.
        try residualAt(input.base_g, amounts, input.water_m3, input.faces, input.conductance, input.options, target, residual);
        try std.testing.expect(try scaledNorm(amounts, residual, input.options) <= 1);
        for (amounts) |amount| {
            try std.testing.expect(std.math.isFinite(amount));
            try std.testing.expect(amount >= 0);
        }

        // The accepted face-flux ledger reconstructs the published state exactly,
        // so publication introduced no organic mass source or sink.
        @memcpy(target, input.base_g);
        for (input.faces, 0..) |face, face_index| {
            if (!face.active) continue;
            for (0..component_count) |component| {
                const flux = face_flux[face_index * component_count + component];
                target[face.first_cell * component_count + component] -= flux;
                target[face.second_cell * component_count + component] += flux;
            }
        }
        try std.testing.expectEqualSlices(f64, target, amounts);

        // The pre-fix endpoint transported material through a dry column, so it
        // is no longer an acceptable solution of the corrected map.
        var moved_g: f64 = 0;
        for (input.final_g, input.base_g) |final, initial| moved_g = @max(moved_g, @abs(final - initial));
        try std.testing.expect(moved_g > 0);
        try residualAt(input.base_g, input.final_g, input.water_m3, input.faces, input.conductance, input.options, target, residual);
        try std.testing.expect(try scaledNorm(input.final_g, residual, input.options) > 1);
    }
}

test "organic transport branch Newton preserves signed flux and dry endpoint equations" {
    const component = @intFromEnum(Component.dissolved_organic_phosphorus);
    var base = [_]f64{0} ** (2 * component_count);
    base[component] = 2;
    base[component_count + component] = 1;
    const options: Options = .{ .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20 };
    var conductance = [_]f64{0} ** component_count;
    conductance[component] = 0.25;
    for ([_][2]f64{ .{ 1, 1 }, .{ 0, 1 }, .{ 1, 0 } }) |water| {
        for ([_]f64{ -0.5, 0, 0.5 }) |water_flux| {
            const faces = [_]@import("../solute/transport.zig").Face{.{ .first_cell = 0, .second_cell = 1, .water_flux_m3_per_step = water_flux }};
            var matrix: [4]f64 = undefined;
            var rhs: [2]f64 = undefined;
            var direction: [2 * component_count]f64 = undefined;
            try std.testing.expect(try inactiveClampComponentNewtonDirection(&base, &base, &water, &faces, &conductance, options, component, &matrix, &rhs, &direction));
            var candidate: [2 * component_count]f64 = undefined;
            try addDirection(&base, &direction, 1, &candidate);
            var target: [2 * component_count]f64 = undefined;
            var residual: [2 * component_count]f64 = undefined;
            try residualAt(&base, &candidate, &water, &faces, &conductance, options, &target, &residual);
            for (residual) |value| try std.testing.expect(@abs(value) <= 64 * std.math.floatEps(f64) * 3);
            try std.testing.expectApproxEqAbs(@as(f64, 3), candidate[component] + candidate[component_count + component], 64 * std.math.floatEps(f64) * 3);
        }
    }
}

test "organic transport failure capture preserves effective component floors" {
    const options: Options = .{
        .absolute_tolerance_g = 0.125,
        .relative_tolerance = 1e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 100,
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, DomainFailureCapture{
        .base_g = &.{ 1, 2 },
        .final_g = &.{ 1.5, 1.5 },
        .water_m3 = &.{ 1, 1 },
        .faces = &.{},
        .conductance = &.{},
        .options = options,
    }, .{});
    defer std.testing.allocator.free(encoded);
    const decoded = try std.json.parseFromSlice(DomainFailureCapture, std.testing.allocator, encoded, .{});
    defer decoded.deinit();
    try std.testing.expect(std.math.isNan(decoded.value.options.absolute_tolerance_g));
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, decoded.value.base_g);
    for (0..components_per_substrate) |component|
        try std.testing.expectEqual(@as(f64, 0.125), absoluteToleranceForComponent(decoded.value.options, component));
}

test "organic transport dense Newton keeps trace-pool probes on the residual branch" {
    const options: Options = .{
        .absolute_tolerance_g_by_component = .{ 1e-10, 1e-11, 1e-12, 1e-10 },
        .relative_tolerance = 1e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 5,
    };
    const amount_g = 1.0335066763646247e-9;
    const residual_g = -8.590195696018932e-10;
    const delta_g = denseProbeDelta(
        amount_g,
        residual_g,
        @intFromEnum(Component.dissolved_organic_carbon),
        options,
    );
    try std.testing.expect(delta_g < 0);
    try std.testing.expect(@abs(delta_g) < 1e-6 * amount_g);
    try std.testing.expect(amount_g + delta_g >= 0);
    try std.testing.expect(amount_g + delta_g != amount_g);
}

test "organic transport trace pool converges through scaled dense Newton" {
    var amounts = [_]f64{0} ** (2 * component_count);
    const component = components_per_substrate * 3 +
        @intFromEnum(Component.dissolved_organic_carbon);
    amounts[component] = 1.0335066763646247e-9;
    const initial_total_g = amounts[component];
    const water = [_]f64{ 1, 1 };
    const faces = [_]@import("../solute/transport.zig").Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    var conductance = [_]f64{0} ** component_count;
    conductance[component] = 0.831_167_660_817_185;
    var accepted_face_flux = [_]f64{0} ** component_count;
    const result = try solveDomain(
        std.testing.allocator,
        &amounts,
        &water,
        &faces,
        &conductance,
        .{
            .absolute_tolerance_g_by_component = .{ 1e-10, 1e-11, 1e-12, 1e-10 },
            .relative_tolerance = 1e-8,
            .picard_relaxation = 0.5,
            .max_iterations = 5,
        },
        &accepted_face_flux,
    );
    try std.testing.expect(result.iterations <= 3);
    try std.testing.expect(result.newton_steps > 0);
    try std.testing.expectEqual(@as(u16, 0), result.picard_steps);
    try std.testing.expectApproxEqAbs(
        initial_total_g,
        amounts[component] + amounts[component_count + component],
        1e-24,
    );
    try std.testing.expect(accepted_face_flux[component] > 0);
}

test "organic transport preserves element-specific nonlinear floors" {
    const options: Options = .{
        .absolute_tolerance_g_by_component = .{ 1e-9, 2e-10, 3e-11, 4e-12 },
        .relative_tolerance = 1e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 20,
    };
    try std.testing.expectEqual(@as(f64, 1e-9), absoluteToleranceForComponent(options, @intFromEnum(Component.dissolved_organic_carbon)));
    try std.testing.expectEqual(@as(f64, 2e-10), absoluteToleranceForComponent(options, @intFromEnum(Component.dissolved_organic_nitrogen)));
    try std.testing.expectEqual(@as(f64, 3e-11), absoluteToleranceForComponent(options, @intFromEnum(Component.dissolved_organic_phosphorus)));
    try std.testing.expectEqual(@as(f64, 4e-12), absoluteToleranceForComponent(options, @intFromEnum(Component.dissolved_acetate_carbon)));
}

test "runtime organic pore transport state_updates exact signed boundary loss" {
    var profile = try organic.State.init(std.testing.allocator, 1);
    defer profile.deinit();
    profile.dissolved[0] = .{ .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 2 };
    profile.dissolved_acetate_carbon_g_c[0] = 6;
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try state.initializeFromProfile(&profile);
    state.macropore_amount_g[@intFromEnum(Component.dissolved_organic_carbon)] = 4;

    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    @memset(model_grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var no_faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &model_grid);
    defer no_faces.deinit();
    const zero_recharge = [_]f64{0} ** component_count;
    const result = try advance(std.testing.allocator, &state, &profile, &no_faces, .{
        .micropore_conductance_m3_per_step = &.{},
        .macropore_conductance_m3_per_step = &.{},
        .matrix_water_m3 = &.{1},
        .macropore_water_m3 = &.{1},
        .layer_bulk_volume_m3 = &.{1},
        .micropore_external_water_flux_m3_per_step = &.{0.25},
        .macropore_external_water_flux_m3_per_step = &.{0},
        .recharge_concentration_g_per_m3 = &zero_recharge,
    }, .{
        .absolute_tolerance_g = 1e-12,
        .relative_tolerance = 1e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 20,
        .pore_exchange_fraction = 0,
    });
    try std.testing.expectEqual(@as(u16, 1), result.micropore_iterations);
    try std.testing.expectEqual(result.picard_steps, result.anderson_steps);
    try std.testing.expectApproxEqAbs(@as(f64, 6), profile.dissolved[0].carbon_g_c, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), profile.dissolved[0].nitrogen_g_n, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), profile.dissolved[0].phosphorus_g_p, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), profile.dissolved_acetate_carbon_g_c[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, -2), state.boundary_net_flux_g[@intFromEnum(Component.dissolved_organic_carbon)], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 4), state.macropore_amount_g[@intFromEnum(Component.dissolved_organic_carbon)], 1e-15);
}

test "soil organic local gate rejects domain cancellation and rolls back all publications" {
    var profile = try organic.State.init(std.testing.allocator, 2);
    defer profile.deinit();
    profile.dissolved[0].carbon_g_c = 2;
    profile.dissolved[organic.substrate_count].carbon_g_c = 2;
    var state = try State.init(std.testing.allocator, 2);
    defer state.deinit();
    try state.initializeFromProfile(&profile);

    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    @memset(model_grid.active_soil_layer_count, 2);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &model_grid);
    defer faces.deinit();

    const face_components = faces.micropore_faces.len * component_count;
    const zero_conductance = try std.testing.allocator.alloc(f64, face_components);
    defer std.testing.allocator.free(zero_conductance);
    @memset(zero_conductance, 0);
    const micro_face_output = try std.testing.allocator.alloc(f64, face_components);
    defer std.testing.allocator.free(micro_face_output);
    @memset(micro_face_output, 7);
    const macro_face_output = try std.testing.allocator.alloc(f64, face_components);
    defer std.testing.allocator.free(macro_face_output);
    @memset(macro_face_output, 7);
    const zero_recharge = [_]f64{0} ** (2 * component_count);
    var perturbation = [_]f64{0} ** (2 * component_count);
    const doc = @intFromEnum(Component.dissolved_organic_carbon);
    perturbation[doc] = 0.1;
    perturbation[component_count + doc] = -0.1;
    const micropore_before = state.micropore_amount_g[doc];
    const lower_micropore_before = state.micropore_amount_g[component_count + doc];

    try std.testing.expectError(error.SoilOrganicLocalConservationFailure, advance(std.testing.allocator, &state, &profile, &faces, .{
        .micropore_conductance_m3_per_step = zero_conductance,
        .macropore_conductance_m3_per_step = zero_conductance,
        .matrix_water_m3 = &.{ 1, 1 },
        .macropore_water_m3 = &.{ 0, 0 },
        .layer_bulk_volume_m3 = &.{ 1, 1 },
        .micropore_external_water_flux_m3_per_step = &.{ 0, 0 },
        .macropore_external_water_flux_m3_per_step = &.{ 0, 0 },
        .recharge_concentration_g_per_m3 = &zero_recharge,
        .micropore_face_flux_g_by_component = micro_face_output,
        .macropore_face_flux_g_by_component = macro_face_output,
        .test_conservation_perturbation_g_by_component = &perturbation,
    }, .{
        .absolute_tolerance_g = 1e-12,
        .relative_tolerance = 1e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 20,
        .soil_layer_capacity = 2,
        .horizontal_cell_area_m2 = &.{1},
    }));
    try std.testing.expectEqual(micropore_before, state.micropore_amount_g[doc]);
    try std.testing.expectEqual(lower_micropore_before, state.micropore_amount_g[component_count + doc]);
    try std.testing.expectEqual(micropore_before, profile.dissolved[0].carbon_g_c);
    try std.testing.expectEqual(lower_micropore_before, profile.dissolved[organic.substrate_count].carbon_g_c);
    for (state.boundary_net_flux_g) |value| try std.testing.expectEqual(@as(f64, 0), value);
    for (micro_face_output) |value| try std.testing.expectEqual(@as(f64, 7), value);
    for (macro_face_output) |value| try std.testing.expectEqual(@as(f64, 7), value);
}

test "soil organic transport rejects degenerate divergence watch options" {
    // A patience of zero would fire on the first non-improving iteration and a
    // growth factor below one would fire on an improving one. Both are
    // option faults, mirroring `soil/gas/vapor_solver.zig` and
    // `soil/water/snow_transport_solver.zig`.
    var profile = try organic.State.init(std.testing.allocator, 1);
    defer profile.deinit();
    profile.dissolved[0] = .{ .carbon_g_c = 8, .nitrogen_g_n = 4, .phosphorus_g_p = 2 };
    var state = try State.init(std.testing.allocator, 1);
    defer state.deinit();
    try state.initializeFromProfile(&profile);
    const config = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var model_grid = try grid_module.GridState.init(std.testing.allocator, config);
    defer model_grid.deinit();
    @memset(model_grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var no_faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &model_grid);
    defer no_faces.deinit();
    const zero_recharge = [_]f64{0} ** component_count;
    const inputs: Inputs = .{
        .micropore_conductance_m3_per_step = &.{},
        .macropore_conductance_m3_per_step = &.{},
        .matrix_water_m3 = &.{1},
        .macropore_water_m3 = &.{1},
        .layer_bulk_volume_m3 = &.{1},
        .micropore_external_water_flux_m3_per_step = &.{0},
        .macropore_external_water_flux_m3_per_step = &.{0},
        .recharge_concentration_g_per_m3 = &zero_recharge,
    };
    try std.testing.expectError(error.InvalidSoilOrganicTransportOptions, advance(std.testing.allocator, &state, &profile, &no_faces, inputs, .{ .absolute_tolerance_g = 1e-12, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20, .divergence_patience = 0 }));
    try std.testing.expectError(error.InvalidSoilOrganicTransportOptions, advance(std.testing.allocator, &state, &profile, &no_faces, inputs, .{ .absolute_tolerance_g = 1e-12, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20, .divergence_growth_factor = 0.5 }));
    try std.testing.expectError(error.InvalidSoilOrganicTransportOptions, advance(std.testing.allocator, &state, &profile, &no_faces, inputs, .{ .absolute_tolerance_g = 1e-12, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20, .anderson_recovery = false }));
    // CONTROL: the same inputs with the default watch still converge, so the
    // rejections above are proving option validation rather than that these
    // inputs cannot be solved at all.
    _ = try advance(std.testing.allocator, &state, &profile, &no_faces, inputs, .{ .absolute_tolerance_g = 1e-12, .relative_tolerance = 1e-8, .picard_relaxation = 0.5, .max_iterations = 20 });
}

test "organic transport verifies conservative publication before commit" {
    var amounts = [_]f64{0} ** (2 * component_count);
    const doc = @intFromEnum(Component.dissolved_organic_carbon);
    amounts[doc] = 2;
    amounts[component_count + doc] = 1;
    const base = amounts;
    const water = [_]f64{ 1, 1 };
    const faces = [_]@import("../solute/transport.zig").Face{.{
        .first_cell = 0,
        .second_cell = 1,
        .water_flux_m3_per_step = 0,
    }};
    const conductance = [_]f64{0.75} ** component_count;
    var accepted_face_flux = [_]f64{0} ** component_count;
    const options: Options = .{
        .absolute_tolerance_g = 0.8,
        .relative_tolerance = 1e-12,
        .picard_relaxation = 0.5,
        .max_iterations = 5,
    };
    const result = try solveDomain(
        std.testing.allocator,
        &amounts,
        &water,
        &faces,
        &conductance,
        options,
        &accepted_face_flux,
    );
    // As in the mineral transport regression, the initial iterate meets its
    // own loose scaled tolerance but its conservative F(x) image does not.
    // The publication gate must force real Newton work.
    try std.testing.expect(result.iterations > 1);
    try std.testing.expect(result.newton_steps > 0);

    var target = [_]f64{0} ** (2 * component_count);
    var residual = [_]f64{0} ** (2 * component_count);
    try residualAt(&base, &amounts, &water, &faces, &conductance, options, &target, &residual);
    try std.testing.expect(try scaledNorm(&amounts, &residual, options) <= 1);
    try std.testing.expectApproxEqAbs(amounts[component_count + doc] - base[component_count + doc], accepted_face_flux[doc], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 3), amounts[doc] + amounts[component_count + doc], 1e-14);
}

test "XFRS pore exchange conserves organic mass" {
    const exchange = try poreExchange(2, 6, 4, 3, 20, 0.25);
    try std.testing.expectApproxEqAbs(@as(f64, 8), (2 + exchange) + (6 - exchange), 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), exchange, 1e-15);
}

test "accepted internal solve removes tolerance-sized component mass drift" {
    var base = [_]f64{0} ** (2 * component_count);
    var current = [_]f64{0} ** (2 * component_count);
    const doc = @intFromEnum(Component.dissolved_organic_carbon);
    const humus_doc = components_per_substrate * 4 + doc;
    base[doc] = 8;
    base[component_count + doc] = 2;
    current[doc] = 6.000_004;
    current[component_count + doc] = 4.000_003;
    base[humus_doc] = 5;
    current[humus_doc] = 4.999_996;

    try enforceInternalConservation(&base, &current);

    try std.testing.expectEqual(@as(f64, 10), current[doc] + current[component_count + doc]);
    try std.testing.expectEqual(@as(f64, 5), current[humus_doc] + current[component_count + humus_doc]);
}

test "organic transport scaled norm rejects per-mille residuals" {
    const options: Options = .{
        .relative_tolerance = 1.0e-8,
        .picard_relaxation = 0.5,
        .max_iterations = 20,
    };
    const doc = @intFromEnum(Component.dissolved_organic_carbon);
    const state = [_]f64{1.0};
    const residual = [_]f64{1.0e-3};

    try std.testing.expectApproxEqAbs(
        @as(f64, 1.0e-12 + 1.0e-8),
        componentScale(state[0], doc, options),
        1.0e-20,
    );
    // The removed 1e5 relative multiplier made this norm exactly one and let
    // a 0.1% nonlinear defect pass as converged.
    try std.testing.expect(try scaledNorm(&state, &residual, options) > 1.0e4);
}

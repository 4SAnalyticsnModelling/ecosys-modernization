const std = @import("std");
const builtin = @import("builtin");
const scoped_conservation = @import("../../validation/scoped_conservation.zig");
const grid_module = @import("../../state/grid.zig");
const hydrology_module = @import("../../transport/hydrology.zig");
const solute = @import("../solute/transport.zig");
const water_solver = @import("solver.zig");
const vapor_solver = @import("../gas/vapor_solver.zig");
const phase_solver = @import("phase_solver.zig");
const heat_solver = @import("../heat/solver.zig");
const heat_flux = @import("../heat/flux.zig");
const face_geometry_module = @import("face_geometry.zig");
const solver_properties_module = @import("solver_properties.zig");
const workspace_module = @import("../runtime/hourly_workspace.zig");
const thermal_module = @import("../heat/thermal.zig");
const science_module = @import("../runtime/process_pipeline.zig");
const boundary_topology_module = @import("../profile/boundary_topology.zig");
const terrain_module = @import("../../state/terrain_hydrology.zig");
const chemistry_state_module = @import("../solute/chemistry_state.zig");
const charge_classification_module = @import("../solute/charge_classification.zig");
const ice_units = @import("../../core/ice_units.zig");
const water_solver_conserved = @import("solver_conserved.zig");
const retention_module = @import("retention.zig");

pub const TemporaryProfileCounters = struct {
    setup_ns: i96 = 0,
    water_solver_ns: i96 = 0,
    richards_post_ns: i96 = 0,
    vapor_solver_ns: i96 = 0,
    vapor_post_ns: i96 = 0,
    phase_solver_ns: i96 = 0,
    phase_post_ns: i96 = 0,
    heat_solver_ns: i96 = 0,
    final_validation_ns: i96 = 0,
};

pub const TemporaryProfile = struct {
    io: std.Io,
    counters: *TemporaryProfileCounters,
    trace_thermal_stages: bool = false,
};

fn traceThermalStage(profile: ?TemporaryProfile, stage: []const u8, grid: *const grid_module.GridState, inputs: Inputs, dry_capacity: []const f64) void {
    if (profile == null or !profile.?.trace_thermal_stages) return;
    for (0..@min(@as(usize, 3), grid.layer_count)) |layer| {
        const properties = inputs.phase_properties;
        const energy = cellEnthalpyMegajoules(grid, layer, dry_capacity[layer], properties.liquid_water_heat_capacity_megajoules_per_m3_k, properties.ice_heat_capacity_megajoules_per_m3_k, properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, properties.freeze_thaw.pure_water_freezing_temperature_k);
        std.log.info("THERMAL_TRACE stage={s} dt_hours={e} layer={d} temperature_k={e} enthalpy_megajoules={e} dry_capacity_megajoules_per_k={e} matrix_liquid_m3={e} matrix_ice_we_m3={e} macro_liquid_m3={e} macro_ice_we_m3={e} vapor_m3={e}", .{ stage, properties.time_step_hours, layer, grid.soil_temperature_k[layer], energy, dry_capacity[layer], grid.matrix_liquid_water_m3[layer], grid.matrix_ice_water_m3[layer], grid.macropore_liquid_water_m3[layer], grid.macropore_ice_water_m3[layer], grid.water_vapor_volume_m3[layer] });
        if (inputs.heat_properties.cell_heat_source_megajoules.len > layer and
            inputs.heat_properties.snow_storage_heat_flux_megajoules.len > layer)
            std.log.info("THERMAL_SOURCE stage={s} dt_hours={e} layer={d} cell_source_megajoules={e} snow_source_megajoules={e}", .{
                stage,
                properties.time_step_hours,
                layer,
                inputs.heat_properties.cell_heat_source_megajoules[layer],
                inputs.heat_properties.snow_storage_heat_flux_megajoules[layer],
            });
    }
}

fn captureColdHeatInput(profile: ?TemporaryProfile, allocator: std.mem.Allocator, grid: *const grid_module.GridState, shared_faces: *const hydrology_module.SoilFaces, geometry: heat_solver.FaceGeometry, properties: heat_solver.Properties, options: heat_solver.Options) !void {
    if (profile == null or !profile.?.trace_thermal_stages) return;
    // Diagnostic trigger only, never a temperature bound or acceptance rule.
    var cold = false;
    for (grid.soil_temperature_k) |temperature_k| cold = cold or temperature_k < 240;
    if (!cold) return;
    const faces = try allocator.alloc(heat_solver.Face, shared_faces.micropore_faces.len);
    defer allocator.free(faces);
    for (faces, 0..) |*face, index| face.* = .{ .active = shared_faces.active_by_face[index], .source_cell = shared_faces.micropore_faces[index].first_cell, .destination_cell = shared_faces.micropore_faces[index].second_cell, .source_path_length_m = geometry.source_path_length_m[index], .destination_path_length_m = geometry.destination_path_length_m[index], .face_area_m2 = geometry.face_area_m2[index] };
    var active_properties = properties;
    active_properties.active_by_layer = shared_faces.active_by_layer;
    try @import("../heat/failure_snapshot.zig").reportFirstColdInput(profile.?.io, allocator, .{ .grid = grid.*, .faces = faces, .properties = active_properties, .water_fluxes = .{ .liquid_water_m3 = shared_faces.micropore_water_flux_m3_per_step, .vapor_m3 = shared_faces.vapor_flux_m3_per_step, .macropore_water_m3 = shared_faces.macropore_water_flux_m3_per_step }, .options = options });
}

pub const Inputs = struct {
    water_geometry: water_solver.FaceGeometry,
    water_properties: water_solver.Properties,
    water_options: water_solver.Options,
    vapor_geometry: vapor_solver.FaceGeometry,
    vapor_properties: vapor_solver.Properties,
    vapor_options: vapor_solver.Options,
    phase_properties: phase_solver.Properties,
    phase_options: phase_solver.Options,
    heat_geometry: heat_solver.FaceGeometry,
    heat_properties: heat_solver.Properties,
    heat_options: heat_solver.Options,
    heat_workspace: ?*heat_solver.Workspace = null,
    water_conservation_absolute_tolerance_m: f64 = 0,
    water_conservation_relative_tolerance: f64 = 1.0e-9,
    heat_conservation_absolute_tolerance_megajoules_per_m2: f64 = 0,
    heat_conservation_relative_tolerance: f64 = 1.0e-9,
    cell_area_m2: []const f64 = &.{},
    /// Extensive dry-solid capacity for diagnostic reconstruction, MJ K-1.
    /// Empty disables stage diagnostics for isolated callers.
    dry_solid_heat_capacity_megajoules_per_k: []const f64 = &.{},
    external_water_advective_enthalpy_outward_megajoules_by_cell: []f64 = &.{},
    external_water_advective_enthalpy_outward_megajoules_by_layer: []f64 = &.{},
    boundary_heat_input_megajoules_by_cell: []f64 = &.{},
    boundary_heat_output_megajoules_by_cell: []f64 = &.{},
    /// Per-layer, per-domain water-equivalent ice change caused by the final
    /// spatial heat solve. Optional output for same-hour coupling control.
    heat_induced_ice_change_by_layer: []HeatInducedIceChange = &.{},
    /// Accepted WATSUB rigid-pore displacement, still owned by its source
    /// layer. The caller must bind this sidecar to the source-order upward
    /// recipient before it may commit the enclosing hour.
    phase_displacement_by_layer: []PhaseDisplacement = &.{},
    /// Source-derived WATSUB phase endpoint-reference heat by layer. Positive
    /// values are internal production and negative values consumption.
    phase_endpoint_reference_heat_megajoules_by_layer: []f64 = &.{},
    /// issue-068 (fourth round, 2026-09-20): per-layer energy discrepancy
    /// booked when `temperatureForCellEnthalpy` holds a chronically
    /// near-zero-heat-capacity layer's PRIOR temperature instead of dividing
    /// an enthalpy mismatch by that near-zero capacity (mirrors
    /// `solver_residual.zig`'s `residualAtImpl` and WATSUB 6907--6913's own
    /// `TK1 = TKS` hold-don't-divide rule, at the identical floor
    /// `validatePerLayerSpatialHeatClosure` already uses). Positive values are
    /// energy the layer should have gained but did not; negative values are
    /// energy it should have lost but did not. Netted into
    /// `validatePerLayerSpatialHeatClosure`'s `expected_gain_megajoules` so a
    /// held-back layer is not reported as a spurious closure violation. Empty
    /// disables booking, matching every other optional per-layer ledger here.
    renormalization_floor_discard_megajoules_by_layer: []f64 = &.{},
    /// Source-certified binary64 representation bounds from the accepted
    /// Richards and post-Richards water closure gates. Optional output.
    water_storage_roundoff_allowance_m3_by_layer: []f64 = &.{},
    /// Source-certified binary64 representation bounds from the accepted
    /// spatial heat closure gate. Optional output.
    heat_storage_roundoff_allowance_megajoules_by_layer: []f64 = &.{},
    /// Transactional WATSUB boundary work that must run after accepted local
    /// vapor/phase equilibrium and before the spatial heat solve.
    post_phase_context: ?*anyopaque = null,
    post_phase_pre_heat: ?*const fn (
        context: *anyopaque,
        time_step_hours: f64,
        grid: *grid_module.GridState,
        hydrology: *hydrology_module.State,
        heat_source_megajoules: []f64,
        external_water_change_m3_by_layer: []f64,
    ) anyerror!void = null,
    mutable_heat_source_megajoules: []f64 = &.{},
    temporary_profile: ?TemporaryProfile = null,
};

pub const EnergyDiagnostics = struct {
    richards_enthalpy_change_megajoules: f64,
    vapor_transport_enthalpy_change_megajoules: f64,
    phase_enthalpy_change_megajoules: f64,
    phase_absolute_enthalpy_change_megajoules: f64,
    spatial_heat_enthalpy_change_megajoules: f64,
    phase_latent_heat_megajoules: f64,
    heat_solver_freeze_thaw_latent_megajoules: f64,
    /// Enthalpy carried out of the soil domain by water crossing the external
    /// (lateral/drainage) boundary during the Richards solve, valued at the
    /// donor temperature actually resident when the water left.
    ///
    /// The landscape boundary ledger previously recomputed this term at the
    /// END-of-hour soil temperature, after the phase and spatial heat solves
    /// had already changed `soil_temperature_k`. The interior enthalpy census
    /// records the departure at the pre-heat-solve temperature, so the two
    /// accountings differed by `C_l * Q_ext * dT_hour` per layer, which does
    /// not cancel over a day and appeared as the `richards` heat audit
    /// deviation.
    external_water_advective_enthalpy_outward_megajoules: f64,
};

/// Signed water-equivalent ice change caused by the spatial heat solve after
/// the phase-equilibrium solve, retained separately by pore domain so equal
/// freezing and thawing cannot cancel before the retry decision.
pub const HeatInducedIceChange = struct {
    matrix_water_equivalent_m3: f64 = 0,
    macropore_water_equivalent_m3: f64 = 0,
};

/// Positive upward carrier and enthalpy produced when freezing expands a
/// rigid soil pore beyond physical capacity. WATSUB routes the carrier through
/// FLWL/FLWHL; this lower boundary deliberately records no surface sink.
pub const PhaseDisplacement = struct {
    matrix_liquid_water_m3: f64 = 0,
    matrix_ice_water_equivalent_m3: f64 = 0,
    macropore_liquid_water_m3: f64 = 0,
    macropore_ice_water_equivalent_m3: f64 = 0,
    advective_enthalpy_megajoules: f64 = 0,
};

pub const Result = struct {
    water: water_solver.Result,
    vapor: vapor_solver.Result,
    phase: phase_solver.Result,
    heat: heat_solver.Result,
    energy: ?EnergyDiagnostics = null,
    /// Borrowed from `Inputs.phase_displacement_by_layer` for `advance` and
    /// from `DeferredMappedResult` for the mapped recovery aggregate.
    phase_displacement_by_layer: []const PhaseDisplacement = &.{},
};

pub const deferred_grid_carrier_count: usize = 12;

pub const DeferredMappedResult = struct {
    allocator: std.mem.Allocator,
    /// Per-process iteration counters in `solver` are maxima over accepted
    /// substeps, never totals. `work` exposes the total nonlinear work.
    solver: Result,
    grid_delta_by_layer_carrier: []f64,
    external_water_advective_enthalpy_outward_megajoules_by_cell: []f64,
    external_water_advective_enthalpy_outward_megajoules_by_layer: []f64,
    boundary_heat_input_megajoules_by_cell: []f64,
    boundary_heat_output_megajoules_by_cell: []f64,
    phase_displacement_by_layer: []PhaseDisplacement,
    /// Accepted, source-derived WATSUB phase endpoint-reference heat at each
    /// soil layer. Positive values are internal production and negative values
    /// are internal consumption in the canonical enthalpy census.
    phase_endpoint_reference_heat_megajoules_by_layer: []f64,
    /// issue-068 (fourth round): accepted per-layer renormalization-floor
    /// discard. See `Inputs.renormalization_floor_discard_megajoules_by_layer`.
    renormalization_floor_discard_megajoules_by_layer: []f64,
    water_storage_roundoff_allowance_m3_by_layer: []f64,
    heat_storage_roundoff_allowance_megajoules_by_layer: []f64,
    accepted_substeps: u8 = 1,
    /// True when accepted heat updates produced locally significant ice
    /// activity during this schedule. Activity is accumulated by absolute
    /// pore-domain change so thaw/refreeze cancellation cannot hide it.
    had_significant_heat_induced_phase_change: bool = false,
    work: SubstepWorkDiagnostics = .{},

    pub fn deinit(self: *DeferredMappedResult) void {
        self.allocator.free(self.phase_endpoint_reference_heat_megajoules_by_layer);
        self.allocator.free(self.renormalization_floor_discard_megajoules_by_layer);
        self.allocator.free(self.water_storage_roundoff_allowance_m3_by_layer);
        self.allocator.free(self.heat_storage_roundoff_allowance_megajoules_by_layer);
        self.allocator.free(self.phase_displacement_by_layer);
        self.allocator.free(self.boundary_heat_output_megajoules_by_cell);
        self.allocator.free(self.boundary_heat_input_megajoules_by_cell);
        self.allocator.free(self.external_water_advective_enthalpy_outward_megajoules_by_layer);
        self.allocator.free(self.external_water_advective_enthalpy_outward_megajoules_by_cell);
        self.allocator.free(self.grid_delta_by_layer_carrier);
        self.* = undefined;
    }
};

/// Owns buffers that leave `advanceMappedDeferred` on success. Optional
/// fields record partial initialization without adding one cleanup edge per
/// allocation to the recovery controller. `take` is the only ownership
/// transfer: it disarms this owner after preserving the result's historical
/// slice aliases.
const DeferredOutputOwner = struct {
    allocator: std.mem.Allocator,
    grid_delta_by_layer_carrier: ?[]f64 = null,
    external_water_advective_enthalpy_outward_megajoules_by_cell: ?[]f64 = null,
    external_water_advective_enthalpy_outward_megajoules_by_layer: ?[]f64 = null,
    boundary_heat_input_megajoules_by_cell: ?[]f64 = null,
    boundary_heat_output_megajoules_by_cell: ?[]f64 = null,
    phase_displacement_by_layer: ?[]PhaseDisplacement = null,
    phase_endpoint_reference_heat_megajoules_by_layer: ?[]f64 = null,
    renormalization_floor_discard_megajoules_by_layer: ?[]f64 = null,
    water_storage_roundoff_allowance_m3_by_layer: ?[]f64 = null,
    heat_storage_roundoff_allowance_megajoules_by_layer: ?[]f64 = null,

    fn init(allocator: std.mem.Allocator) DeferredOutputOwner {
        return .{ .allocator = allocator };
    }

    noinline fn deinit(self: *DeferredOutputOwner) void {
        if (self.grid_delta_by_layer_carrier) |buffer| self.allocator.free(buffer);
        if (self.phase_endpoint_reference_heat_megajoules_by_layer) |buffer| self.allocator.free(buffer);
        if (self.renormalization_floor_discard_megajoules_by_layer) |buffer| self.allocator.free(buffer);
        if (self.water_storage_roundoff_allowance_m3_by_layer) |buffer| self.allocator.free(buffer);
        if (self.heat_storage_roundoff_allowance_megajoules_by_layer) |buffer| self.allocator.free(buffer);
        if (self.phase_displacement_by_layer) |buffer| self.allocator.free(buffer);
        if (self.boundary_heat_output_megajoules_by_cell) |buffer| self.allocator.free(buffer);
        if (self.boundary_heat_input_megajoules_by_cell) |buffer| self.allocator.free(buffer);
        if (self.external_water_advective_enthalpy_outward_megajoules_by_layer) |buffer| self.allocator.free(buffer);
        if (self.external_water_advective_enthalpy_outward_megajoules_by_cell) |buffer| self.allocator.free(buffer);
        self.disarm();
    }

    noinline fn disarm(self: *DeferredOutputOwner) void {
        self.grid_delta_by_layer_carrier = null;
        self.external_water_advective_enthalpy_outward_megajoules_by_cell = null;
        self.external_water_advective_enthalpy_outward_megajoules_by_layer = null;
        self.boundary_heat_input_megajoules_by_cell = null;
        self.boundary_heat_output_megajoules_by_cell = null;
        self.phase_displacement_by_layer = null;
        self.phase_endpoint_reference_heat_megajoules_by_layer = null;
        self.renormalization_floor_discard_megajoules_by_layer = null;
        self.water_storage_roundoff_allowance_m3_by_layer = null;
        self.heat_storage_roundoff_allowance_megajoules_by_layer = null;
    }

    noinline fn take(
        self: *DeferredOutputOwner,
        solver_value: Result,
        accepted_substeps: u8,
        had_significant_heat_induced_phase_change: bool,
        work: SubstepWorkDiagnostics,
    ) DeferredMappedResult {
        const phase_displacement = self.phase_displacement_by_layer orelse unreachable;
        var solver = solver_value;
        solver.phase_displacement_by_layer = phase_displacement;
        const result: DeferredMappedResult = .{
            .allocator = self.allocator,
            .solver = solver,
            .grid_delta_by_layer_carrier = self.grid_delta_by_layer_carrier orelse unreachable,
            .external_water_advective_enthalpy_outward_megajoules_by_cell = self.external_water_advective_enthalpy_outward_megajoules_by_cell orelse unreachable,
            .external_water_advective_enthalpy_outward_megajoules_by_layer = self.external_water_advective_enthalpy_outward_megajoules_by_layer orelse unreachable,
            .boundary_heat_input_megajoules_by_cell = self.boundary_heat_input_megajoules_by_cell orelse unreachable,
            .boundary_heat_output_megajoules_by_cell = self.boundary_heat_output_megajoules_by_cell orelse unreachable,
            .phase_displacement_by_layer = phase_displacement,
            .phase_endpoint_reference_heat_megajoules_by_layer = self.phase_endpoint_reference_heat_megajoules_by_layer orelse unreachable,
            .renormalization_floor_discard_megajoules_by_layer = self.renormalization_floor_discard_megajoules_by_layer orelse unreachable,
            .water_storage_roundoff_allowance_m3_by_layer = self.water_storage_roundoff_allowance_m3_by_layer orelse unreachable,
            .heat_storage_roundoff_allowance_megajoules_by_layer = self.heat_storage_roundoff_allowance_megajoules_by_layer orelse unreachable,
            .accepted_substeps = accepted_substeps,
            .had_significant_heat_induced_phase_change = had_significant_heat_induced_phase_change,
            .work = work,
        };
        self.disarm();
        return result;
    }
};

/// Owns buffers that exist only while recovery schedules are attempted.
/// Keeping partial initialization here preserves exact cleanup on allocation
/// failure while collapsing thirteen independent defer paths to one.
const RecoveryScratch = struct {
    allocator: std.mem.Allocator,
    schedule_external_water_heat_by_cell: ?[]f64 = null,
    substep_external_water_heat_by_cell: ?[]f64 = null,
    schedule_external_water_heat_by_layer: ?[]f64 = null,
    substep_external_water_heat_by_layer: ?[]f64 = null,
    schedule_boundary_heat_input_by_cell: ?[]f64 = null,
    schedule_boundary_heat_output_by_cell: ?[]f64 = null,
    substep_boundary_heat_input_by_cell: ?[]f64 = null,
    substep_boundary_heat_output_by_cell: ?[]f64 = null,
    schedule_heat_induced_ice_change_by_layer: ?[]HeatInducedIceChange = null,
    substep_heat_induced_ice_change_by_layer: ?[]HeatInducedIceChange = null,
    schedule_phase_displacement_by_layer: ?[]PhaseDisplacement = null,
    substep_phase_displacement_by_layer: ?[]PhaseDisplacement = null,
    schedule_phase_endpoint_reference_heat_by_layer: ?[]f64 = null,
    substep_phase_endpoint_reference_heat_by_layer: ?[]f64 = null,
    schedule_renormalization_floor_discard_by_layer: ?[]f64 = null,
    substep_renormalization_floor_discard_by_layer: ?[]f64 = null,
    schedule_water_storage_roundoff_allowance_by_layer: ?[]f64 = null,
    substep_water_storage_roundoff_allowance_by_layer: ?[]f64 = null,
    schedule_heat_storage_roundoff_allowance_by_layer: ?[]f64 = null,
    substep_heat_storage_roundoff_allowance_by_layer: ?[]f64 = null,

    fn init(allocator: std.mem.Allocator) RecoveryScratch {
        return .{ .allocator = allocator };
    }

    noinline fn deinit(self: *RecoveryScratch) void {
        if (self.substep_phase_endpoint_reference_heat_by_layer) |buffer| self.allocator.free(buffer);
        if (self.schedule_phase_endpoint_reference_heat_by_layer) |buffer| self.allocator.free(buffer);
        if (self.substep_renormalization_floor_discard_by_layer) |buffer| self.allocator.free(buffer);
        if (self.schedule_renormalization_floor_discard_by_layer) |buffer| self.allocator.free(buffer);
        if (self.substep_water_storage_roundoff_allowance_by_layer) |buffer| self.allocator.free(buffer);
        if (self.schedule_water_storage_roundoff_allowance_by_layer) |buffer| self.allocator.free(buffer);
        if (self.substep_heat_storage_roundoff_allowance_by_layer) |buffer| self.allocator.free(buffer);
        if (self.schedule_heat_storage_roundoff_allowance_by_layer) |buffer| self.allocator.free(buffer);
        if (self.substep_phase_displacement_by_layer) |buffer| self.allocator.free(buffer);
        if (self.schedule_phase_displacement_by_layer) |buffer| self.allocator.free(buffer);
        if (self.schedule_heat_induced_ice_change_by_layer) |buffer| self.allocator.free(buffer);
        if (self.substep_heat_induced_ice_change_by_layer) |buffer| self.allocator.free(buffer);
        if (self.substep_boundary_heat_output_by_cell) |buffer| self.allocator.free(buffer);
        if (self.substep_boundary_heat_input_by_cell) |buffer| self.allocator.free(buffer);
        if (self.schedule_boundary_heat_output_by_cell) |buffer| self.allocator.free(buffer);
        if (self.schedule_boundary_heat_input_by_cell) |buffer| self.allocator.free(buffer);
        if (self.substep_external_water_heat_by_layer) |buffer| self.allocator.free(buffer);
        if (self.schedule_external_water_heat_by_layer) |buffer| self.allocator.free(buffer);
        if (self.substep_external_water_heat_by_cell) |buffer| self.allocator.free(buffer);
        if (self.schedule_external_water_heat_by_cell) |buffer| self.allocator.free(buffer);
        self.disarm();
    }

    noinline fn disarm(self: *RecoveryScratch) void {
        self.schedule_external_water_heat_by_cell = null;
        self.substep_external_water_heat_by_cell = null;
        self.schedule_external_water_heat_by_layer = null;
        self.substep_external_water_heat_by_layer = null;
        self.schedule_boundary_heat_input_by_cell = null;
        self.schedule_boundary_heat_output_by_cell = null;
        self.substep_boundary_heat_input_by_cell = null;
        self.substep_boundary_heat_output_by_cell = null;
        self.schedule_heat_induced_ice_change_by_layer = null;
        self.substep_heat_induced_ice_change_by_layer = null;
        self.schedule_phase_displacement_by_layer = null;
        self.substep_phase_displacement_by_layer = null;
        self.schedule_phase_endpoint_reference_heat_by_layer = null;
        self.substep_phase_endpoint_reference_heat_by_layer = null;
        self.schedule_renormalization_floor_discard_by_layer = null;
        self.substep_renormalization_floor_discard_by_layer = null;
        self.schedule_water_storage_roundoff_allowance_by_layer = null;
        self.substep_water_storage_roundoff_allowance_by_layer = null;
        self.schedule_heat_storage_roundoff_allowance_by_layer = null;
        self.substep_heat_storage_roundoff_allowance_by_layer = null;
    }
};

/// Allocates the accepted and scratch buffers in their historical order. The
/// two owners are already armed by the caller, so any failing allocation
/// unwinds through exactly those owners without per-buffer errdefers.
noinline fn allocateDeferredRecoveryBuffers(
    outputs: *DeferredOutputOwner,
    scratch: *RecoveryScratch,
    cell_count: usize,
    layer_count: usize,
    phase_displacement_count: usize,
) !void {
    const allocator = outputs.allocator;
    std.debug.assert(allocator.ptr == scratch.allocator.ptr and allocator.vtable == scratch.allocator.vtable);
    outputs.external_water_advective_enthalpy_outward_megajoules_by_cell = try allocator.alloc(f64, cell_count);
    scratch.schedule_external_water_heat_by_cell = try allocator.alloc(f64, cell_count);
    scratch.substep_external_water_heat_by_cell = try allocator.alloc(f64, cell_count);
    outputs.external_water_advective_enthalpy_outward_megajoules_by_layer = try allocator.alloc(f64, layer_count);
    scratch.schedule_external_water_heat_by_layer = try allocator.alloc(f64, layer_count);
    scratch.substep_external_water_heat_by_layer = try allocator.alloc(f64, layer_count);
    outputs.boundary_heat_input_megajoules_by_cell = try allocator.alloc(f64, cell_count);
    outputs.boundary_heat_output_megajoules_by_cell = try allocator.alloc(f64, cell_count);
    scratch.schedule_boundary_heat_input_by_cell = try allocator.alloc(f64, cell_count);
    scratch.schedule_boundary_heat_output_by_cell = try allocator.alloc(f64, cell_count);
    scratch.substep_boundary_heat_input_by_cell = try allocator.alloc(f64, cell_count);
    scratch.substep_boundary_heat_output_by_cell = try allocator.alloc(f64, cell_count);
    scratch.schedule_heat_induced_ice_change_by_layer = try allocator.alloc(HeatInducedIceChange, layer_count);
    scratch.substep_heat_induced_ice_change_by_layer = try allocator.alloc(HeatInducedIceChange, layer_count);
    outputs.phase_displacement_by_layer = try allocator.alloc(PhaseDisplacement, phase_displacement_count);
    scratch.schedule_phase_displacement_by_layer = try allocator.alloc(PhaseDisplacement, phase_displacement_count);
    scratch.substep_phase_displacement_by_layer = try allocator.alloc(PhaseDisplacement, phase_displacement_count);
    outputs.phase_endpoint_reference_heat_megajoules_by_layer = try allocator.alloc(f64, layer_count);
    scratch.schedule_phase_endpoint_reference_heat_by_layer = try allocator.alloc(f64, layer_count);
    scratch.substep_phase_endpoint_reference_heat_by_layer = try allocator.alloc(f64, layer_count);
    outputs.renormalization_floor_discard_megajoules_by_layer = try allocator.alloc(f64, layer_count);
    scratch.schedule_renormalization_floor_discard_by_layer = try allocator.alloc(f64, layer_count);
    scratch.substep_renormalization_floor_discard_by_layer = try allocator.alloc(f64, layer_count);
    outputs.water_storage_roundoff_allowance_m3_by_layer = try allocator.alloc(f64, layer_count);
    scratch.schedule_water_storage_roundoff_allowance_by_layer = try allocator.alloc(f64, layer_count);
    scratch.substep_water_storage_roundoff_allowance_by_layer = try allocator.alloc(f64, layer_count);
    outputs.heat_storage_roundoff_allowance_megajoules_by_layer = try allocator.alloc(f64, layer_count);
    scratch.schedule_heat_storage_roundoff_allowance_by_layer = try allocator.alloc(f64, layer_count);
    scratch.substep_heat_storage_roundoff_allowance_by_layer = try allocator.alloc(f64, layer_count);
}

pub const SubstepWorkDiagnostics = struct {
    accepted_substeps: u8 = 0,
    total_water_iterations: u32 = 0,
    total_water_dense_jacobian_assemblies: u32 = 0,
    total_water_dense_jacobian_reuses: u32 = 0,
    total_water_dense_jacobian_cache_supplied: u32 = 0,
    total_water_dense_jacobian_cache_loaded: u32 = 0,
    total_water_dense_jacobian_ready_at_publication: u32 = 0,
    total_water_conservative_map_publications: u32 = 0,
    total_water_dense_jacobian_cache_published: u32 = 0,
    total_water_face_flux_cache_hits: u64 = 0,
    total_water_face_flux_cache_misses: u64 = 0,
    total_vapor_iterations: u32 = 0,
    total_phase_iterations: u32 = 0,
    total_heat_iterations: u32 = 0,

    fn add(self: *SubstepWorkDiagnostics, result: Result) !void {
        self.accepted_substeps = try std.math.add(u8, self.accepted_substeps, 1);
        self.total_water_iterations = try std.math.add(u32, self.total_water_iterations, result.water.iterations);
        self.total_water_dense_jacobian_assemblies = try std.math.add(u32, self.total_water_dense_jacobian_assemblies, result.water.dense_jacobian_assemblies);
        self.total_water_dense_jacobian_reuses = try std.math.add(u32, self.total_water_dense_jacobian_reuses, result.water.dense_jacobian_reuses);
        self.total_water_dense_jacobian_cache_supplied += @intFromBool(result.water.dense_jacobian_cache_supplied);
        self.total_water_dense_jacobian_cache_loaded += @intFromBool(result.water.dense_jacobian_cache_loaded);
        self.total_water_dense_jacobian_ready_at_publication += @intFromBool(result.water.dense_jacobian_ready_at_publication);
        self.total_water_conservative_map_publications += @intFromBool(result.water.conservative_map_publication);
        self.total_water_dense_jacobian_cache_published += @intFromBool(result.water.dense_jacobian_cache_published);
        self.total_water_face_flux_cache_hits = try std.math.add(u64, self.total_water_face_flux_cache_hits, result.water.richards_face_flux_cache_hits);
        self.total_water_face_flux_cache_misses = try std.math.add(u64, self.total_water_face_flux_cache_misses, result.water.richards_face_flux_cache_misses);
        self.total_vapor_iterations = try std.math.add(u32, self.total_vapor_iterations, result.vapor.iterations);
        self.total_phase_iterations = try std.math.add(u32, self.total_phase_iterations, result.phase.iterations);
        self.total_heat_iterations = try std.math.add(u32, self.total_heat_iterations, result.heat.iterations);
    }
};

pub const SubstepRefreshInputs = struct {
    terrain: *const terrain_module.State,
    chemistry: *const chemistry_state_module.State,
    runtime_parameters: workspace_module.RuntimeParameters,
    zone_fractions: ?charge_classification_module.ZoneFractions = null,
    zone_fractions_by_layer: ?[]const charge_classification_module.ZoneFractions = null,
};

pub const SubstepTransactionHooks = struct {
    context: *anyopaque,
    restore_schedule: *const fn (context: *anyopaque) void,
    rollback_failure: *const fn (context: *anyopaque) void,
    prepare_substep: *const fn (context: *anyopaque, time_step_hours: f64) anyerror!void,
    /// WATSUB source order: accepted FLVGS/freeze-thaw, then EVAPG, then heat.
    post_phase_pre_heat: ?*const fn (
        context: *anyopaque,
        time_step_hours: f64,
        grid: *grid_module.GridState,
        hydrology: *hydrology_module.State,
        heat_source_megajoules: []f64,
        external_water_change_m3_by_layer: []f64,
    ) anyerror!void = null,
    /// Accepts dt-coupled physical owners against the just-converged
    /// water/heat flux snapshot and may stage a private replay certificate for
    /// source-ordered downstream transport. A later substep can still
    /// invalidate the whole schedule, so the rollback hook remains
    /// authoritative for every accepted side effect.
    accept_substep: ?*const fn (context: *anyopaque, time_step_hours: f64) anyerror!void = null,
    /// Credits the phase solver's accepted upward rigid-pore displacement to
    /// the authoritative vertical/surface recipient before any same-substep
    /// chemistry consumes the new carriers.
    accept_phase_displacement: ?*const fn (context: *anyopaque, displacement_by_layer: []const PhaseDisplacement) anyerror!void = null,
};

/// Supported exact one-hour schedules. The stage-level controller selects one
/// preferred schedule plus at most one error-aware fallback; this list is not
/// an automatic retry sequence.
pub const recovery_substep_counts = [_]u8{ 1, 2, 4, 8, 16, 20, 32, 64 };

pub const TestSubstepControl = struct {
    attempts: u8 = 0,
    fail_time_step_hours_above: f64 = 0,
    fail_from_attempt: u8 = 0,
    /// Lets transaction tests exercise the production retry state machine
    /// without conflating it with a particular physical fixture. Rejected in
    /// every non-test build together with the enclosing test control.
    succeed_without_solving: bool = false,
    /// Test-only per-layer heat-induced phase signal returned by the synthetic
    /// solve. Production obtains the same signal from the accepted heat state.
    heat_induced_ice_change_by_layer: []const HeatInducedIceChange = &.{},
    /// Test-only accepted phase-displacement signal. It exercises the same
    /// transactional aggregation as the production phase solver sidecar.
    phase_displacement_by_layer: []const PhaseDisplacement = &.{},
    /// Test-only source-derived phase endpoint-reference heat. Each accepted
    /// synthetic substep contributes this complete per-layer signal.
    phase_endpoint_reference_heat_megajoules_by_layer: []const f64 = &.{},
    /// Test-only renormalization-floor discard signal (issue-068, fourth
    /// round). Each accepted synthetic substep contributes this complete
    /// per-layer signal.
    renormalization_floor_discard_megajoules_by_layer: []const f64 = &.{},
    /// Test-only a-priori water-storage representation bound emitted by each
    /// accepted synthetic substep.
    water_storage_roundoff_allowance_m3_by_layer: []const f64 = &.{},
    heat_storage_roundoff_allowance_megajoules_by_layer: []const f64 = &.{},
    exact_substep_count: ?u8 = null,
};

/// Converges the complete coupled water/vapor/freeze-thaw/heat transaction,
/// captures its accepted grid-state delta, then restores authoritative state.
/// Flux and boundary ledgers remain published for downstream solute transport;
/// grid state is state_updateted later from serial Morton tile files.
pub fn advanceMappedDeferred(
    allocator: std.mem.Allocator,
    grid: *grid_module.GridState,
    hydrology: *hydrology_module.State,
    faces: *hydrology_module.SoilFaces,
    geometry: *const face_geometry_module.State,
    properties: *const solver_properties_module.State,
    workspace: *workspace_module.State,
    thermal: *thermal_module.State,
    heat_workspace: *heat_solver.Workspace,
    science: science_module.RuntimeParameters,
    options: MappedOptions,
) !DeferredMappedResult {
    if (options.external_water_advective_enthalpy_outward_megajoules_by_layer.len != 0 and
        options.external_water_advective_enthalpy_outward_megajoules_by_layer.len != grid.layer_count)
        return error.SoilExternalWaterHeatLayerDimensionMismatch;
    if (options.phase_displacement_by_layer.len != 0 and
        options.phase_displacement_by_layer.len != grid.layer_count)
        return error.SoilPhaseDisplacementDimensionMismatch;
    if (options.phase_endpoint_reference_heat_megajoules_by_layer.len != 0 and
        options.phase_endpoint_reference_heat_megajoules_by_layer.len != grid.layer_count)
        return error.SoilPhaseReferenceHeatDimensionMismatch;
    if (options.renormalization_floor_discard_megajoules_by_layer.len != 0 and
        options.renormalization_floor_discard_megajoules_by_layer.len != grid.layer_count)
        return error.SoilRenormalizationFloorDiscardDimensionMismatch;
    if (options.water_storage_roundoff_allowance_m3_by_layer.len != 0 and
        options.water_storage_roundoff_allowance_m3_by_layer.len != grid.layer_count)
        return error.WaterStorageRoundoffProvenanceDimensionMismatch;
    if (options.heat_storage_roundoff_allowance_megajoules_by_layer.len != 0 and
        options.heat_storage_roundoff_allowance_megajoules_by_layer.len != grid.layer_count)
        return error.HeatStorageRoundoffProvenanceDimensionMismatch;
    if (options.cell_area_m2.len != 0 and
        options.cell_area_m2.len != grid.cell_count)
        return error.HeatConservationCellDimensionMismatch;
    @memset(options.phase_displacement_by_layer, .{});
    @memset(options.phase_endpoint_reference_heat_megajoules_by_layer, 0);
    @memset(options.renormalization_floor_discard_megajoules_by_layer, 0);
    @memset(options.water_storage_roundoff_allowance_m3_by_layer, 0);
    @memset(options.heat_storage_roundoff_allowance_megajoules_by_layer, 0);
    @memset(options.external_water_advective_enthalpy_outward_megajoules_by_layer, 0);
    errdefer @memset(options.phase_displacement_by_layer, .{});
    errdefer @memset(options.phase_endpoint_reference_heat_megajoules_by_layer, 0);
    errdefer @memset(options.renormalization_floor_discard_megajoules_by_layer, 0);
    errdefer @memset(options.water_storage_roundoff_allowance_m3_by_layer, 0);
    errdefer @memset(options.heat_storage_roundoff_allowance_megajoules_by_layer, 0);
    errdefer @memset(options.external_water_advective_enthalpy_outward_megajoules_by_layer, 0);
    const phase_displacement_bound = options.phase_displacement_by_layer.len != 0;
    var base = try Snapshot.capture(allocator, grid, hydrology, faces);
    defer base.deinit();
    errdefer base.restore(grid, hydrology, faces);
    var coefficient_base = try CoefficientSnapshot.capture(allocator, workspace, thermal);
    defer coefficient_base.deinit();
    errdefer coefficient_base.restore(workspace, thermal);
    var topology_base: ?TopologySnapshot = if (options.boundary_topology) |topology|
        try TopologySnapshot.capture(allocator, topology)
    else
        null;
    defer if (topology_base) |*snapshot| snapshot.deinit();
    errdefer if (topology_base) |snapshot| snapshot.restore(options.boundary_topology.?);
    errdefer if (options.substep_transaction_hooks) |hooks| hooks.rollback_failure(hooks.context);
    var accumulated_ledgers = try Snapshot.capture(allocator, grid, hydrology, faces);
    defer accumulated_ledgers.deinit();
    var accepted_solver: ?Result = null;
    var accepted_work: SubstepWorkDiagnostics = .{};
    var accepted_substeps: u8 = 0;
    var accepted_had_significant_heat_induced_phase_change = false;
    var last_retryable_error: ?anyerror = null;
    const phase_displacement_count = if (phase_displacement_bound) grid.layer_count else 0;
    var deferred_outputs = DeferredOutputOwner.init(allocator);
    defer deferred_outputs.deinit();
    var recovery_scratch = RecoveryScratch.init(allocator);
    defer recovery_scratch.deinit();
    try allocateDeferredRecoveryBuffers(
        &deferred_outputs,
        &recovery_scratch,
        grid.cell_count,
        grid.layer_count,
        phase_displacement_count,
    );
    const accepted_external_water_heat_by_cell = deferred_outputs.external_water_advective_enthalpy_outward_megajoules_by_cell.?;
    const schedule_external_water_heat_by_cell = recovery_scratch.schedule_external_water_heat_by_cell.?;
    const substep_external_water_heat_by_cell = recovery_scratch.substep_external_water_heat_by_cell.?;
    const accepted_external_water_heat_by_layer = deferred_outputs.external_water_advective_enthalpy_outward_megajoules_by_layer.?;
    const schedule_external_water_heat_by_layer = recovery_scratch.schedule_external_water_heat_by_layer.?;
    const substep_external_water_heat_by_layer = recovery_scratch.substep_external_water_heat_by_layer.?;
    const accepted_boundary_heat_input_by_cell = deferred_outputs.boundary_heat_input_megajoules_by_cell.?;
    const accepted_boundary_heat_output_by_cell = deferred_outputs.boundary_heat_output_megajoules_by_cell.?;
    const schedule_boundary_heat_input_by_cell = recovery_scratch.schedule_boundary_heat_input_by_cell.?;
    const schedule_boundary_heat_output_by_cell = recovery_scratch.schedule_boundary_heat_output_by_cell.?;
    const substep_boundary_heat_input_by_cell = recovery_scratch.substep_boundary_heat_input_by_cell.?;
    const substep_boundary_heat_output_by_cell = recovery_scratch.substep_boundary_heat_output_by_cell.?;
    const schedule_heat_induced_ice_change_by_layer = recovery_scratch.schedule_heat_induced_ice_change_by_layer.?;
    const substep_heat_induced_ice_change_by_layer = recovery_scratch.substep_heat_induced_ice_change_by_layer.?;
    const accepted_phase_displacement_by_layer = deferred_outputs.phase_displacement_by_layer.?;
    const schedule_phase_displacement_by_layer = recovery_scratch.schedule_phase_displacement_by_layer.?;
    const substep_phase_displacement_by_layer = recovery_scratch.substep_phase_displacement_by_layer.?;
    const accepted_phase_endpoint_reference_heat_by_layer = deferred_outputs.phase_endpoint_reference_heat_megajoules_by_layer.?;
    const schedule_phase_endpoint_reference_heat_by_layer = recovery_scratch.schedule_phase_endpoint_reference_heat_by_layer.?;
    const substep_phase_endpoint_reference_heat_by_layer = recovery_scratch.substep_phase_endpoint_reference_heat_by_layer.?;
    const accepted_renormalization_floor_discard_by_layer = deferred_outputs.renormalization_floor_discard_megajoules_by_layer.?;
    const schedule_renormalization_floor_discard_by_layer = recovery_scratch.schedule_renormalization_floor_discard_by_layer.?;
    const substep_renormalization_floor_discard_by_layer = recovery_scratch.substep_renormalization_floor_discard_by_layer.?;
    const accepted_water_storage_roundoff_allowance_by_layer = deferred_outputs.water_storage_roundoff_allowance_m3_by_layer.?;
    const schedule_water_storage_roundoff_allowance_by_layer = recovery_scratch.schedule_water_storage_roundoff_allowance_by_layer.?;
    const substep_water_storage_roundoff_allowance_by_layer = recovery_scratch.substep_water_storage_roundoff_allowance_by_layer.?;
    const accepted_heat_storage_roundoff_allowance_by_layer = deferred_outputs.heat_storage_roundoff_allowance_megajoules_by_layer.?;
    const schedule_heat_storage_roundoff_allowance_by_layer = recovery_scratch.schedule_heat_storage_roundoff_allowance_by_layer.?;
    const substep_heat_storage_roundoff_allowance_by_layer = recovery_scratch.substep_heat_storage_roundoff_allowance_by_layer.?;
    @memset(accepted_external_water_heat_by_cell, 0);
    @memset(accepted_external_water_heat_by_layer, 0);
    @memset(accepted_boundary_heat_input_by_cell, 0);
    @memset(accepted_boundary_heat_output_by_cell, 0);
    @memset(accepted_phase_displacement_by_layer, .{});
    @memset(accepted_phase_endpoint_reference_heat_by_layer, 0);
    @memset(accepted_renormalization_floor_discard_by_layer, 0);
    @memset(accepted_water_storage_roundoff_allowance_by_layer, 0);
    @memset(accepted_heat_storage_roundoff_allowance_by_layer, 0);
    if (options.exact_substep_count) |exact| {
        var supported = false;
        for (recovery_substep_counts) |candidate| supported = supported or candidate == exact;
        if (!supported) return error.InvalidExactSoilSubstepCount;
    }
    const water_component_count = try std.math.mul(usize, grid.layer_count, 2);
    const water_dense_jacobian_elements = if (water_component_count <= @min(
        options.dense_newton_max_components,
        water_solver.maximum_dense_newton_components,
    ))
        try std.math.mul(usize, water_component_count, water_component_count)
    else
        0;
    const water_dense_jacobian_values = try allocator.alloc(
        f64,
        water_dense_jacobian_elements,
    );
    defer allocator.free(water_dense_jacobian_values);
    var water_dense_jacobian_cache: water_solver.DenseJacobianCache = .{
        .values = water_dense_jacobian_values,
    };
    // Preserve the one-hour external clock while refining only the failed
    // coupled transport transaction: 60, 2x30, 4x15, then successively
    // finer 7.5, 3.75, 3, 1.875 and 0.9375 minute schedules. The bounded
    // minimum prevents an unbounded recovery loop while retaining the fixed
    // one-hour external clock.
    var substep_arena = std.heap.ArenaAllocator.init(allocator);
    defer substep_arena.deinit();
    for (recovery_substep_counts) |substep_count| {
        if (options.exact_substep_count) |exact|
            if (substep_count != exact) continue;
        // A finer schedule is valid only when every stateful forcing that
        // precedes WATSUB can be restored and replayed at the same dt. Without
        // those hooks production fails fast after the one-hour attempt.
        if (substep_count > 1 and options.substep_transaction_hooks == null)
            break;
        // Per-attempt detail is useful when a debug build profiles recovery,
        // but synchronously flushing two informational records for every
        // accepted production hour makes diagnostics part of the hot path.
        // Rejections remain warnings and therefore retain the complete
        // production failure/recovery record.
        std.log.debug("heat recovery ladder attempt: substep_count={d}", .{substep_count});
        water_dense_jacobian_cache.invalidate();
        base.restore(grid, hydrology, faces);
        coefficient_base.restore(workspace, thermal);
        if (topology_base) |snapshot| snapshot.restore(options.boundary_topology.?);
        if (options.substep_transaction_hooks) |hooks| hooks.restore_schedule(hooks.context);
        accumulated_ledgers.zeroLedgers();
        @memset(schedule_external_water_heat_by_cell, 0);
        @memset(schedule_external_water_heat_by_layer, 0);
        @memset(schedule_boundary_heat_input_by_cell, 0);
        @memset(schedule_boundary_heat_output_by_cell, 0);
        @memset(schedule_heat_induced_ice_change_by_layer, .{});
        @memset(schedule_phase_displacement_by_layer, .{});
        @memset(schedule_phase_endpoint_reference_heat_by_layer, 0);
        @memset(schedule_renormalization_floor_discard_by_layer, 0);
        @memset(schedule_water_storage_roundoff_allowance_by_layer, 0);
        @memset(schedule_heat_storage_roundoff_allowance_by_layer, 0);
        var schedule_solver: ?Result = null;
        var schedule_work: SubstepWorkDiagnostics = .{};
        var schedule_failed = false;
        const time_step_hours = 1.0 / @as(f64, @floatFromInt(substep_count));
        for (0..substep_count) |substep_index| {
            _ = substep_arena.reset(.retain_capacity);
            if (options.substep_transaction_hooks) |hooks| {
                hooks.prepare_substep(hooks.context, time_step_hours) catch |err| {
                    if (!isRetryableSolverFailure(err)) return err;
                    last_retryable_error = err;
                    schedule_failed = true;
                    break;
                };
            }
            if (options.substep_refresh) |refresh|
                try refreshSubstepCoefficients(grid, properties, workspace, thermal, science, refresh);
            var substep_options = options;
            substep_options.time_step_hours = time_step_hours;
            substep_options.water_dense_jacobian_cache = &water_dense_jacobian_cache;
            @memset(substep_external_water_heat_by_cell, 0);
            @memset(substep_external_water_heat_by_layer, 0);
            @memset(substep_boundary_heat_input_by_cell, 0);
            @memset(substep_boundary_heat_output_by_cell, 0);
            @memset(substep_heat_induced_ice_change_by_layer, .{});
            @memset(substep_phase_displacement_by_layer, .{});
            @memset(substep_phase_endpoint_reference_heat_by_layer, 0);
            @memset(substep_renormalization_floor_discard_by_layer, 0);
            @memset(substep_water_storage_roundoff_allowance_by_layer, 0);
            @memset(substep_heat_storage_roundoff_allowance_by_layer, 0);
            substep_options.external_water_advective_enthalpy_outward_megajoules_by_cell = substep_external_water_heat_by_cell;
            substep_options.external_water_advective_enthalpy_outward_megajoules_by_layer = substep_external_water_heat_by_layer;
            substep_options.boundary_heat_input_megajoules_by_cell = substep_boundary_heat_input_by_cell;
            substep_options.boundary_heat_output_megajoules_by_cell = substep_boundary_heat_output_by_cell;
            substep_options.heat_induced_ice_change_by_layer = substep_heat_induced_ice_change_by_layer;
            substep_options.phase_displacement_by_layer = substep_phase_displacement_by_layer;
            substep_options.phase_endpoint_reference_heat_megajoules_by_layer =
                substep_phase_endpoint_reference_heat_by_layer;
            substep_options.renormalization_floor_discard_megajoules_by_layer =
                substep_renormalization_floor_discard_by_layer;
            substep_options.water_storage_roundoff_allowance_m3_by_layer =
                substep_water_storage_roundoff_allowance_by_layer;
            substep_options.heat_storage_roundoff_allowance_megajoules_by_layer =
                substep_heat_storage_roundoff_allowance_by_layer;
            const substep_solver = advanceMapped(
                substep_arena.allocator(),
                grid,
                hydrology,
                faces,
                geometry,
                properties,
                workspace,
                thermal,
                heat_workspace,
                science,
                substep_options,
            ) catch |err| {
                if (!isRetryableSolverFailure(err)) return err;
                if (!builtin.is_test) std.log.warn(
                    "soil coupled schedule failed: substep_count={d} failed_substep={d} time_step_hours={e} error={s}",
                    .{
                        substep_count,
                        substep_index + 1,
                        time_step_hours,
                        @errorName(err),
                    },
                );
                last_retryable_error = err;
                schedule_failed = true;
                break;
            };
            if (options.substep_transaction_hooks) |hooks| if (hooks.accept_phase_displacement) |accept_displacement| {
                accept_displacement(hooks.context, substep_phase_displacement_by_layer) catch |err| {
                    if (!isRetryableSolverFailure(err)) return err;
                    last_retryable_error = err;
                    schedule_failed = true;
                    break;
                };
            };
            const substep_had_significant_heat_induced_phase_change =
                try hasSignificantHeatInducedPhaseChange(
                    grid,
                    substep_heat_induced_ice_change_by_layer,
                    options.water_conservation_absolute_tolerance_m,
                    options.water_conservation_relative_tolerance,
                    options.cell_area_m2,
                );
            if (substep_count < minimum_freeze_flow_coupling_substeps and
                substep_had_significant_heat_induced_phase_change)
            {
                // WTHR fixes NFH=4 for ordinary subhourly fluxes. A heat solve
                // that changes ice leaves physical pore occupancy and frozen
                // conductivity for the next Richards sweep, so a coarser
                // otherwise-converged schedule is scientifically incomplete.
                // Mark it retryable before accepting transported inventories;
                // the next schedule iteration restores every owner and ledger.
                last_retryable_error = error.HeatInducedPhaseChangeRequiresQuarterHourSubsteps;
                schedule_failed = true;
                break;
            }
            if (options.substep_transaction_hooks) |hooks| if (hooks.accept_substep) |accept_substep| {
                accept_substep(hooks.context, time_step_hours) catch |err| {
                    if (!isRetryableSolverFailure(err)) return err;
                    last_retryable_error = err;
                    schedule_failed = true;
                    break;
                };
            };
            for (
                schedule_heat_induced_ice_change_by_layer,
                substep_heat_induced_ice_change_by_layer,
            ) |*total, part| {
                total.matrix_water_equivalent_m3 = try checkedAddFinite(
                    total.matrix_water_equivalent_m3,
                    @abs(part.matrix_water_equivalent_m3),
                );
                total.macropore_water_equivalent_m3 = try checkedAddFinite(
                    total.macropore_water_equivalent_m3,
                    @abs(part.macropore_water_equivalent_m3),
                );
            }
            try accumulated_ledgers.accumulateLedgers(hydrology, faces);
            for (schedule_external_water_heat_by_cell, substep_external_water_heat_by_cell) |*total, part|
                total.* = try checkedAddFinite(total.*, part);
            for (schedule_external_water_heat_by_layer, substep_external_water_heat_by_layer) |*total, part|
                total.* = try checkedAddFinite(total.*, part);
            for (schedule_boundary_heat_input_by_cell, substep_boundary_heat_input_by_cell) |*total, part|
                total.* = try checkedAddFinite(total.*, part);
            for (schedule_boundary_heat_output_by_cell, substep_boundary_heat_output_by_cell) |*total, part|
                total.* = try checkedAddFinite(total.*, part);
            for (schedule_phase_displacement_by_layer, substep_phase_displacement_by_layer) |*total, part|
                try addPhaseDisplacement(total, part);
            for (
                schedule_phase_endpoint_reference_heat_by_layer,
                substep_phase_endpoint_reference_heat_by_layer,
            ) |*total, part| total.* = try checkedAddFinite(total.*, part);
            for (
                schedule_renormalization_floor_discard_by_layer,
                substep_renormalization_floor_discard_by_layer,
            ) |*total, part| total.* = try checkedAddFinite(total.*, part);
            for (
                schedule_water_storage_roundoff_allowance_by_layer,
                substep_water_storage_roundoff_allowance_by_layer,
            ) |*total, part| total.* = try checkedAddNonnegativeRoundUp(total.*, part);
            for (
                schedule_heat_storage_roundoff_allowance_by_layer,
                substep_heat_storage_roundoff_allowance_by_layer,
            ) |*total, part| total.* = try checkedAddNonnegativeHeatRoundUp(total.*, part);
            try schedule_work.add(substep_solver);
            if (schedule_solver) |*combined|
                try combineAcceptedResults(combined, substep_solver)
            else
                schedule_solver = substep_solver;
        }
        if (!schedule_failed) {
            accepted_solver = schedule_solver orelse return error.EmptySoilSubstepSchedule;
            accepted_work = schedule_work;
            accepted_substeps = substep_count;
            accepted_had_significant_heat_induced_phase_change =
                try hasSignificantHeatInducedPhaseChange(
                    grid,
                    schedule_heat_induced_ice_change_by_layer,
                    options.water_conservation_absolute_tolerance_m,
                    options.water_conservation_relative_tolerance,
                    options.cell_area_m2,
                );
            @memcpy(accepted_external_water_heat_by_cell, schedule_external_water_heat_by_cell);
            @memcpy(accepted_external_water_heat_by_layer, schedule_external_water_heat_by_layer);
            @memcpy(accepted_boundary_heat_input_by_cell, schedule_boundary_heat_input_by_cell);
            @memcpy(accepted_boundary_heat_output_by_cell, schedule_boundary_heat_output_by_cell);
            @memcpy(accepted_phase_displacement_by_layer, schedule_phase_displacement_by_layer);
            @memcpy(
                accepted_phase_endpoint_reference_heat_by_layer,
                schedule_phase_endpoint_reference_heat_by_layer,
            );
            @memcpy(
                accepted_renormalization_floor_discard_by_layer,
                schedule_renormalization_floor_discard_by_layer,
            );
            @memcpy(
                accepted_water_storage_roundoff_allowance_by_layer,
                schedule_water_storage_roundoff_allowance_by_layer,
            );
            @memcpy(
                accepted_heat_storage_roundoff_allowance_by_layer,
                schedule_heat_storage_roundoff_allowance_by_layer,
            );
            std.log.debug("heat recovery ladder succeeded: substep_count={d}", .{substep_count});
            break;
        }
    }
    const solver = accepted_solver orelse {
        base.restore(grid, hydrology, faces);
        return last_retryable_error orelse error.SoilSubstepSchedulesExhausted;
    };
    @memcpy(options.phase_displacement_by_layer, accepted_phase_displacement_by_layer);
    if (options.external_water_advective_enthalpy_outward_megajoules_by_layer.len != 0)
        @memcpy(
            options.external_water_advective_enthalpy_outward_megajoules_by_layer,
            accepted_external_water_heat_by_layer,
        );
    if (options.phase_endpoint_reference_heat_megajoules_by_layer.len != 0)
        @memcpy(
            options.phase_endpoint_reference_heat_megajoules_by_layer,
            accepted_phase_endpoint_reference_heat_by_layer,
        );
    if (options.renormalization_floor_discard_megajoules_by_layer.len != 0)
        @memcpy(
            options.renormalization_floor_discard_megajoules_by_layer,
            accepted_renormalization_floor_discard_by_layer,
        );
    if (options.water_storage_roundoff_allowance_m3_by_layer.len != 0)
        @memcpy(
            options.water_storage_roundoff_allowance_m3_by_layer,
            accepted_water_storage_roundoff_allowance_by_layer,
        );
    if (options.heat_storage_roundoff_allowance_megajoules_by_layer.len != 0)
        @memcpy(
            options.heat_storage_roundoff_allowance_megajoules_by_layer,
            accepted_heat_storage_roundoff_allowance_by_layer,
        );
    if (solver.energy) |energy| {
        var per_cell_total: f64 = 0;
        for (accepted_external_water_heat_by_cell) |value| per_cell_total = try checkedAddFinite(per_cell_total, value);
        if (@abs(per_cell_total - energy.external_water_advective_enthalpy_outward_megajoules) >
            64 * std.math.floatEps(f64) * @max(1, @abs(energy.external_water_advective_enthalpy_outward_megajoules)))
            return error.SoilExternalWaterHeatPerCellMismatch;
    }
    var boundary_input_total: f64 = 0;
    var boundary_output_total: f64 = 0;
    for (accepted_boundary_heat_input_by_cell) |value| boundary_input_total = try checkedAddFinite(boundary_input_total, value);
    for (accepted_boundary_heat_output_by_cell) |value| boundary_output_total = try checkedAddFinite(boundary_output_total, value);
    const boundary_scale = @max(1, @max(solver.heat.boundary_heat_input_megajoules, solver.heat.boundary_heat_output_megajoules));
    if (@abs(boundary_input_total - solver.heat.boundary_heat_input_megajoules) > 64 * std.math.floatEps(f64) * boundary_scale or
        @abs(boundary_output_total - solver.heat.boundary_heat_output_megajoules) > 64 * std.math.floatEps(f64) * boundary_scale)
        return error.SoilBoundaryHeatPerCellMismatch;
    deferred_outputs.grid_delta_by_layer_carrier = try allocator.alloc(
        f64,
        try std.math.mul(
            usize,
            grid.layer_count,
            deferred_grid_carrier_count,
        ),
    );
    const delta = deferred_outputs.grid_delta_by_layer_carrier.?;
    for (0..grid.layer_count) |layer| {
        for (0..deferred_grid_carrier_count) |carrier| {
            const value =
                liveGridStateSlice(grid, carrier)[layer] -
                base.gridStateSlice(carrier)[layer];
            if (!std.math.isFinite(value))
                return error.NonFiniteDeferredSoilStateDelta;
            delta[layer * deferred_grid_carrier_count + carrier] = value;
        }
    }
    base.restore(grid, hydrology, faces);
    coefficient_base.restore(workspace, thermal);
    if (topology_base) |snapshot| snapshot.restore(options.boundary_topology.?);
    accumulated_ledgers.publishLedgers(hydrology, faces);
    return deferred_outputs.take(
        solver,
        accepted_substeps,
        accepted_had_significant_heat_induced_phase_change,
        accepted_work,
    );
}

/// Borrows the accepted live grid carrier while `advanceMappedDeferred` builds
/// its returned delta. The enclosing base snapshot remains the sole rollback
/// owner; allocating and copying a second full accepted state here would add
/// thirty-eight allocations without stabilizing any value, because no science
/// runs between the delta allocation and this read.
fn liveGridStateSlice(
    grid: *const grid_module.GridState,
    carrier: usize,
) []const f64 {
    return switch (carrier) {
        0 => grid.matrix_liquid_water_m3,
        1 => grid.macropore_liquid_water_m3,
        2 => grid.liquid_water_m3,
        3 => grid.matrix_air_volume_m3,
        4 => grid.macropore_air_volume_m3,
        5 => grid.air_volume_m3,
        6 => grid.water_vapor_volume_m3,
        7 => grid.matrix_ice_water_m3,
        8 => grid.macropore_ice_water_m3,
        9 => grid.ice_water_m3,
        10 => grid.soil_temperature_k,
        11 => grid.matric_potential_megapascal,
        else => unreachable,
    };
}

pub const minimum_freeze_flow_coupling_substeps: u8 = 4;

/// True when `value` is a rung of the authoritative escalation ladder.
/// Shared (not duplicated) by every consumer that needs to validate a
/// substep-count constant against `recovery_substep_counts`, including
/// this file's own comptime guard below and
/// `hourly_heat_water_solute.zig`'s stage-level rescue-chain floor --
/// closing the recurring defect shape documented under
/// SOLUTE-HYDROGEN-ROW-RECURRING-NONCONVERGENCE-001 and issue-058, where
/// a substep-count constant silently drifted out of step with this
/// array because nothing checked membership structurally.
pub fn isRecoverySubstepCountMember(value: u8) bool {
    for (recovery_substep_counts) |candidate| {
        if (candidate == value) return true;
    }
    return false;
}

comptime {
    // Any constant that names one of the ladder's rungs must actually be
    // a member of it, so a future edit that changes the ladder without
    // updating this floor fails to compile instead of crashing or
    // silently no-op'ing at runtime (issue-058).
    if (!isRecoverySubstepCountMember(minimum_freeze_flow_coupling_substeps)) @compileError(
        "minimum_freeze_flow_coupling_substeps must be a member of recovery_substep_counts (see issue-058)",
    );
}

fn phaseChangeExceedsLocalWaterTolerance(
    change: HeatInducedIceChange,
    local_water_scale_m3: f64,
    cell_area_m2: f64,
    absolute_tolerance_m: f64,
    relative_tolerance: f64,
) bool {
    const activity_m3 = @abs(change.matrix_water_equivalent_m3) +
        @abs(change.macropore_water_equivalent_m3);
    const representation_floor_m3 = 4096 * std.math.floatEps(f64) *
        @max(local_water_scale_m3, activity_m3);
    const limit_m3 = absolute_tolerance_m * cell_area_m2 +
        relative_tolerance * local_water_scale_m3 +
        representation_floor_m3;
    return activity_m3 > limit_m3;
}

/// Tests every active layer independently and sums absolute domain activity.
/// Neither opposite pore-domain changes nor opposite layers can hide a phase
/// change that requires the later same-hour Richards coupling sweeps.
fn hasSignificantHeatInducedPhaseChange(
    grid: *const grid_module.GridState,
    change_by_layer: []const HeatInducedIceChange,
    absolute_tolerance_m: f64,
    relative_tolerance: f64,
    cell_area_m2: []const f64,
) !bool {
    if (change_by_layer.len != grid.layer_count or
        (cell_area_m2.len != 0 and cell_area_m2.len != grid.cell_count))
        return error.HeatInducedPhaseChangeDimensionMismatch;
    if (!std.math.isFinite(absolute_tolerance_m) or absolute_tolerance_m < 0 or
        !std.math.isFinite(relative_tolerance) or relative_tolerance <= 0)
        return error.InvalidHeatInducedPhaseChangeTolerance;
    for (0..grid.cell_count) |cell| {
        const area_m2 = if (cell_area_m2.len == 0) 0 else cell_area_m2[cell];
        if (!std.math.isFinite(area_m2) or area_m2 < 0)
            return error.InvalidWaterConservationCellArea;
        for (0..grid.active_soil_layer_count[cell]) |layer_offset| {
            const layer = try grid.layerIndex(cell, layer_offset);
            const change = change_by_layer[layer];
            if (!std.math.isFinite(change.matrix_water_equivalent_m3) or
                !std.math.isFinite(change.macropore_water_equivalent_m3))
                return error.NonFiniteHeatInducedPhaseChange;
            const local_water_scale_m3 = grid.matrix_liquid_water_m3[layer] +
                grid.macropore_liquid_water_m3[layer] +
                grid.matrix_ice_water_m3[layer] +
                grid.macropore_ice_water_m3[layer] +
                grid.water_vapor_volume_m3[layer];
            if (!std.math.isFinite(local_water_scale_m3) or local_water_scale_m3 < 0)
                return error.InvalidHeatInducedPhaseChangeWaterScale;
            if (phaseChangeExceedsLocalWaterTolerance(
                change,
                local_water_scale_m3,
                area_m2,
                absolute_tolerance_m,
                relative_tolerance,
            )) return true;
        }
    }
    return false;
}

fn refreshSubstepCoefficients(
    grid: *grid_module.GridState,
    properties: *const solver_properties_module.State,
    workspace: *workspace_module.State,
    thermal: *thermal_module.State,
    science: science_module.RuntimeParameters,
    refresh: SubstepRefreshInputs,
) !void {
    var thermal_context: thermal_module.UpdateContext = .{
        .thermal = thermal,
        .grid = grid,
        .liquid_water_heat_capacity_megajoules_per_m3_k = science.liquid_water_heat_capacity_megajoules_per_m3_k,
        .ice_heat_capacity_megajoules_per_m3_k = science.ice_heat_capacity_megajoules_per_m3_k,
        .ice_density_megagrams_per_m3 = science.freeze_thaw.ice_density_megagrams_per_m3,
    };
    try thermal_module.updateTile(&thermal_context, .{ .first = 0, .end = grid.cell_count });
    if (refresh.zone_fractions_by_layer) |zone_fractions_by_layer| {
        try workspace.refresh(
            grid,
            properties,
            thermal,
            refresh.terrain,
            refresh.runtime_parameters,
            science.freeze_thaw.ice_density_megagrams_per_m3,
            refresh.chemistry,
            zone_fractions_by_layer,
        );
    } else if (refresh.zone_fractions) |zone_fractions| {
        try workspace.refresh(
            grid,
            properties,
            thermal,
            refresh.terrain,
            refresh.runtime_parameters,
            science.freeze_thaw.ice_density_megagrams_per_m3,
            refresh.chemistry,
            zone_fractions,
        );
    } else return error.MissingSoilHourlyWorkspaceZoneFractions;
}

/// Errors whose rejected candidate can be made physically admissible by
/// reducing only the internal timestep of the same fixed external hour.
/// Keep this list shared with the complete-hour recovery owner: exact WATSUB
/// mode deliberately tries only one schedule, so the caller must recognize
/// every dt-recoverable error that can escape that attempt.
pub fn isFixedHourDtRecoveryFailure(err: anyerror) bool {
    return switch (err) {
        error.SoilWaterSolverDiverged,
        error.SoilWaterSolverStagnated,
        error.SoilWaterSolverDidNotConverge,
        error.SoilVaporSolverDiverged,
        error.SoilVaporSolverStagnated,
        error.SoilVaporSolverDidNotConverge,
        error.InvalidSoilVaporCandidate,
        error.SoilPhaseSolverDiverged,
        error.SoilPhaseSolverOscillating,
        error.SoilPhaseSolverStagnated,
        error.SoilPhaseSolverDidNotConverge,
        error.SoilPhaseCandidateExceedsPoreCapacity,
        // issue-068 (2026-09-20, sixth round): `phase_solver.zig`'s own
        // simultaneous VOLW/VOLV/VOLI/VOLWH/VOLIH + endpoint-temperature
        // solve, a genuinely separate accept path from the dense spatial
        // heat solver's `commitAcceptedState` and from
        // `temperatureForCellEnthalpy`'s renormalization inversion (both
        // already guarded). Recovers identically to its siblings.
        error.SoilPhaseSolverTemperatureOutsidePhysicalDomain,
        error.SoilHeatSolverDiverged,
        error.SoilHeatSolverStagnated,
        error.SoilHeatSolverDidNotConverge,
        error.SoilHeatSolverTemperatureOutsidePhysicalDomain,
        // issue-068 (2026-09-20, second round): see
        // `temperatureForCellEnthalpy`'s own doc comment. Distinct from
        // `SoilHeatSolverTemperatureOutsidePhysicalDomain` so a rerun's log
        // can tell the pre-solve renormalization inversion apart from the
        // dense Newton/Anderson solver's own commit gate, even though both
        // enforce the identical physical band and both recover the same way.
        error.SoilHeatRenormalizedTemperatureOutsidePhysicalDomain,
        error.NewtonPicardDiverged,
        error.NewtonPicardStagnated,
        error.NewtonPicardDidNotConverge,
        error.SoluteTransportSolverDiverged,
        error.SoluteTransportSolverStagnated,
        error.SoluteTransportSolverDidNotConverge,
        error.SnowHeatSolverDidNotConverge,
        error.SingularSnowHeatSystem,
        error.SingularSnowVaporDiffusionSystem,
        error.SnowVaporSolverStagnated,
        error.SnowVaporSolverDidNotConverge,
        error.SnowPhaseSolverStagnated,
        error.SnowPhaseSolverDidNotConverge,
        error.SnowTransportSolverDiverged,
        error.SnowTransportSolverStagnated,
        error.SnowTransportSolverDidNotConverge,
        error.SoilOrganicTransportSolverDiverged,
        error.SoilOrganicTransportSolverStagnated,
        error.SoilOrganicTransportDidNotConverge,
        error.AqueousExtensiveTransportDiverged,
        error.AqueousExtensiveTransportStagnated,
        error.AqueousExtensiveTransportDidNotConverge,
        error.CoupledGasSolverStagnated,
        error.CoupledGasSolverDiverged,
        error.CoupledGasSolverDidNotConverge,
        error.SoluteReactionSolverDiverged,
        error.SoluteReactionSolverStagnated,
        error.SoluteReactionSolverDidNotConverge,
        error.SoluteReactionPhysicalBalanceFailure,
        error.LitterChemistrySolverStagnated,
        error.LitterChemistrySolverDidNotConverge,
        error.SoilEnthalpyTargetOutsideTemperatureBracket,
        error.InvalidSnowSurfaceExchangeCandidate,
        error.InvalidSnowSurfaceExchangeTemperature,
        error.NegativeGroundAirVaporStorage,
        error.SupersaturatedGroundAirVaporStorage,
        error.InvalidLitterSoilWaterCandidate,
        error.InvalidLitterSoilHeatCapacityCandidate,
        error.InvalidLitterSoilTemperatureCandidate,
        error.HeatInducedPhaseChangeRequiresQuarterHourSubsteps,
        error.ForcedSoilSubstepFailure,
        => true,
        else => false,
    };
}

/// Private WATSUB schedule assembly can additionally retry representation
/// states whose carrier may be created by a different internal schedule. They
/// are intentionally excluded from the whole-hour dt classifier above: a
/// conservation mismatch or an intrinsically unrepresented amount must not be
/// hidden by restarting all downstream science with a smaller timestep.
pub fn isRetryableSolverFailure(err: anyerror) bool {
    if (isFixedHourDtRecoveryFailure(err)) return true;
    return switch (err) {
        error.GroundAirSurfaceVaporTransferMismatch,
        error.LitterSoluteWithoutWaterCarrier,
        error.LitterMineralWithoutWaterCarrier,
        error.NegativeLitterSoilInterfaceCandidate,
        error.NegativeLitterSoilInterfaceRoundoff,
        => true,
        else => false,
    };
}

test "private soil vapor candidate rejection is fixed-hour dt recoverable" {
    try std.testing.expect(isFixedHourDtRecoveryFailure(error.InvalidSoilVaporCandidate));
    try std.testing.expect(isRetryableSolverFailure(error.InvalidSoilVaporCandidate));
    inline for (.{
        error.SoluteReactionSolverDiverged,
        error.SoluteReactionSolverStagnated,
        error.SoluteReactionSolverDidNotConverge,
        error.SoluteReactionPhysicalBalanceFailure,
    }) |solute_failure| {
        try std.testing.expect(isFixedHourDtRecoveryFailure(solute_failure));
        try std.testing.expect(isRetryableSolverFailure(solute_failure));
    }
}

fn combineAcceptedResults(combined: *Result, next: Result) !void {
    combined.water.iterations = @max(combined.water.iterations, next.water.iterations);
    combined.water.newton_raphson_steps = @max(combined.water.newton_raphson_steps, next.water.newton_raphson_steps);
    combined.water.picard_steps = @max(combined.water.picard_steps, next.water.picard_steps);
    combined.water.anderson_steps = @max(combined.water.anderson_steps, next.water.anderson_steps);
    combined.water.maximum_scaled_residual = @max(combined.water.maximum_scaled_residual, next.water.maximum_scaled_residual);
    combined.vapor.iterations = @max(combined.vapor.iterations, next.vapor.iterations);
    combined.vapor.newton_raphson_steps = @max(combined.vapor.newton_raphson_steps, next.vapor.newton_raphson_steps);
    combined.vapor.picard_steps = @max(combined.vapor.picard_steps, next.vapor.picard_steps);
    combined.vapor.anderson_steps = @max(combined.vapor.anderson_steps, next.vapor.anderson_steps);
    combined.vapor.maximum_scaled_residual = @max(combined.vapor.maximum_scaled_residual, next.vapor.maximum_scaled_residual);
    combined.phase.iterations = @max(combined.phase.iterations, next.phase.iterations);
    combined.phase.newton_raphson_steps = @max(combined.phase.newton_raphson_steps, next.phase.newton_raphson_steps);
    combined.phase.picard_steps = @max(combined.phase.picard_steps, next.phase.picard_steps);
    combined.phase.anderson_recovery_steps = @max(combined.phase.anderson_recovery_steps, next.phase.anderson_recovery_steps);
    combined.phase.maximum_scaled_residual = @max(combined.phase.maximum_scaled_residual, next.phase.maximum_scaled_residual);
    combined.heat.iterations = @max(combined.heat.iterations, next.heat.iterations);
    combined.heat.newton_raphson_steps = @max(combined.heat.newton_raphson_steps, next.heat.newton_raphson_steps);
    combined.heat.picard_steps = @max(combined.heat.picard_steps, next.heat.picard_steps);
    combined.heat.anderson_steps = @max(combined.heat.anderson_steps, next.heat.anderson_steps);
    combined.heat.maximum_scaled_residual = @max(combined.heat.maximum_scaled_residual, next.heat.maximum_scaled_residual);
    combined.heat.boundary_heat_input_megajoules = try checkedAddFinite(combined.heat.boundary_heat_input_megajoules, next.heat.boundary_heat_input_megajoules);
    combined.heat.boundary_heat_output_megajoules = try checkedAddFinite(combined.heat.boundary_heat_output_megajoules, next.heat.boundary_heat_output_megajoules);
    if (combined.energy) |*total| if (next.energy) |part| {
        total.richards_enthalpy_change_megajoules = try checkedAddFinite(total.richards_enthalpy_change_megajoules, part.richards_enthalpy_change_megajoules);
        total.vapor_transport_enthalpy_change_megajoules = try checkedAddFinite(total.vapor_transport_enthalpy_change_megajoules, part.vapor_transport_enthalpy_change_megajoules);
        total.phase_enthalpy_change_megajoules = try checkedAddFinite(total.phase_enthalpy_change_megajoules, part.phase_enthalpy_change_megajoules);
        total.phase_absolute_enthalpy_change_megajoules = try checkedAddFinite(total.phase_absolute_enthalpy_change_megajoules, part.phase_absolute_enthalpy_change_megajoules);
        total.spatial_heat_enthalpy_change_megajoules = try checkedAddFinite(total.spatial_heat_enthalpy_change_megajoules, part.spatial_heat_enthalpy_change_megajoules);
        total.phase_latent_heat_megajoules = try checkedAddFinite(total.phase_latent_heat_megajoules, part.phase_latent_heat_megajoules);
        total.heat_solver_freeze_thaw_latent_megajoules = try checkedAddFinite(total.heat_solver_freeze_thaw_latent_megajoules, part.heat_solver_freeze_thaw_latent_megajoules);
        total.external_water_advective_enthalpy_outward_megajoules = try checkedAddFinite(total.external_water_advective_enthalpy_outward_megajoules, part.external_water_advective_enthalpy_outward_megajoules);
    };
}

fn checkedAddFinite(left: f64, right: f64) !f64 {
    const sum = left + right;
    if (!std.math.isFinite(left) or !std.math.isFinite(right) or !std.math.isFinite(sum))
        return error.NonFiniteSoilSubstepAccumulation;
    return sum;
}

fn checkedAddNonnegativeRoundUp(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or left < 0 or
        !std.math.isFinite(right) or right < 0)
        return error.InvalidWaterStorageUpdateArithmeticProvenance;
    if (left == 0) return right;
    if (right == 0) return left;
    const sum = left + right;
    if (!std.math.isFinite(sum))
        return error.InvalidWaterStorageUpdateArithmeticProvenance;
    return std.math.nextAfter(f64, sum, std.math.inf(f64));
}

fn checkedAddNonnegativeHeatRoundUp(left: f64, right: f64) !f64 {
    if (!std.math.isFinite(left) or left < 0 or
        !std.math.isFinite(right) or right < 0)
        return error.InvalidHeatStorageUpdateArithmeticProvenance;
    if (left == 0) return right;
    if (right == 0) return left;
    const sum = left + right;
    if (!std.math.isFinite(sum))
        return error.InvalidHeatStorageUpdateArithmeticProvenance;
    return std.math.nextAfter(f64, sum, std.math.inf(f64));
}

/// Convert the legacy WATSUB `C*T` phase endpoint to the continuous frozen
/// enthalpy coordinate used by the independent canonical inventory. This is a
/// reference-state transformation, not a second latent-heat source.
fn phaseEndpointReferenceHeatMegajoules(
    ice_water_equivalent_change_m3: f64,
    internal_vapor_change_m3: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    pure_water_melting_temperature_k: f64,
    latent_heat_of_vaporization_megajoules_per_m3: f64,
) !f64 {
    const result = (liquid_water_heat_capacity_megajoules_per_m3_k -
        ice_heat_capacity_megajoules_per_m3_k) *
        pure_water_melting_temperature_k * ice_water_equivalent_change_m3 -
        latent_heat_of_vaporization_megajoules_per_m3 * internal_vapor_change_m3;
    if (!std.math.isFinite(result)) return error.NonFiniteSoilPhaseReferenceHeat;
    return result;
}

fn validatePhaseDisplacement(value: PhaseDisplacement) !void {
    inline for (.{
        value.matrix_liquid_water_m3,
        value.matrix_ice_water_equivalent_m3,
        value.macropore_liquid_water_m3,
        value.macropore_ice_water_equivalent_m3,
        value.advective_enthalpy_megajoules,
    }) |component| if (!std.math.isFinite(component) or component < 0)
        return error.InvalidSoilPhaseDisplacement;
}

fn addPhaseDisplacement(total: *PhaseDisplacement, part: PhaseDisplacement) !void {
    try validatePhaseDisplacement(total.*);
    try validatePhaseDisplacement(part);
    const next: PhaseDisplacement = .{
        .matrix_liquid_water_m3 = try checkedAddFinite(total.matrix_liquid_water_m3, part.matrix_liquid_water_m3),
        .matrix_ice_water_equivalent_m3 = try checkedAddFinite(total.matrix_ice_water_equivalent_m3, part.matrix_ice_water_equivalent_m3),
        .macropore_liquid_water_m3 = try checkedAddFinite(total.macropore_liquid_water_m3, part.macropore_liquid_water_m3),
        .macropore_ice_water_equivalent_m3 = try checkedAddFinite(total.macropore_ice_water_equivalent_m3, part.macropore_ice_water_equivalent_m3),
        .advective_enthalpy_megajoules = try checkedAddFinite(total.advective_enthalpy_megajoules, part.advective_enthalpy_megajoules),
    };
    try validatePhaseDisplacement(next);
    total.* = next;
}

fn phaseDisplacedWaterEquivalentM3(value: PhaseDisplacement) !f64 {
    try validatePhaseDisplacement(value);
    return checkedAddFinite(
        try checkedAddFinite(value.matrix_liquid_water_m3, value.matrix_ice_water_equivalent_m3),
        try checkedAddFinite(value.macropore_liquid_water_m3, value.macropore_ice_water_equivalent_m3),
    );
}

pub const MappedOptions = struct {
    heat_failure_report_io: ?std.Io = null,
    max_iterations: u16,
    picard_relaxation: f64,
    vapor_pore_tortuosity: f64,
    osmotic_reflection_coefficient: f64,
    water_absolute_tolerance_m3: f64,
    temperature_absolute_tolerance_k: f64,
    enthalpy_absolute_tolerance_megajoules: f64,
    nonlinear_relative_tolerance: f64,
    water_conservation_absolute_tolerance_m: f64 = 0,
    water_conservation_relative_tolerance: f64 = 1.0e-9,
    heat_conservation_absolute_tolerance_megajoules_per_m2: f64 = 0,
    heat_conservation_relative_tolerance: f64 = 1.0e-9,
    boundary_topology: ?*boundary_topology_module.State = null,
    geothermal_enabled_by_cell: ?[]const bool = null,
    mean_annual_temperature_k_by_cell: []const f64 = &.{},
    geothermal_minimum_source_depth_m: f64 = 10,
    geothermal_source_depth_below_profile_m: f64 = 1,
    geothermal_conductivity_m_megajoules_per_h_k: f64 = 8.1e-3,
    geothermal_flux_megajoules_per_m2_h: f64 = 2.052e-4,
    water_table_air_fraction_threshold: f64 = 1.0e-3,
    active_layer_ice_fraction_threshold: f64 = 1.0e-6,
    dense_newton_max_components: usize,
    water_dense_jacobian_cache: ?*water_solver.DenseJacobianCache = null,
    matrix_external_water_source_m3_per_step: []const f64 = &.{},
    external_water_advective_enthalpy_outward_megajoules_by_cell: []f64 = &.{},
    external_water_advective_enthalpy_outward_megajoules_by_layer: []f64 = &.{},
    boundary_heat_input_megajoules_by_cell: []f64 = &.{},
    boundary_heat_output_megajoules_by_cell: []f64 = &.{},
    /// Optional per-layer output consumed by the recovery controller. It is
    /// reset on entry and never contains a rejected prior attempt.
    heat_induced_ice_change_by_layer: []HeatInducedIceChange = &.{},
    /// Optional accepted producer sidecar for source-order upward rigid-pore
    /// displacement. Empty retains the production fail-closed route.
    phase_displacement_by_layer: []PhaseDisplacement = &.{},
    /// Optional accepted phase endpoint-reference heat by layer.
    phase_endpoint_reference_heat_megajoules_by_layer: []f64 = &.{},
    /// Optional accepted renormalization-floor discard by layer. See
    /// `Inputs.renormalization_floor_discard_megajoules_by_layer`.
    renormalization_floor_discard_megajoules_by_layer: []f64 = &.{},
    water_storage_roundoff_allowance_m3_by_layer: []f64 = &.{},
    heat_storage_roundoff_allowance_megajoules_by_layer: []f64 = &.{},
    /// HOUR1 DPTHT litter/pond arm (`VOLW(0)`, `VOLWRX`, `AREA(3,0)`), cell
    /// indexed. Required whenever `boundary_topology` is set.
    surface_litter_liquid_water_m3: []const f64 = &.{},
    surface_litter_water_retention_capacity_m3: []const f64 = &.{},
    cell_area_m2: []const f64 = &.{},
    /// Physical duration of one internal solve. Production callers leave this
    /// at one; the retry controller supplies a bounded refinement down to
    /// 0.015625 while the external model clock remains fixed at one hour.
    time_step_hours: f64 = 1,
    /// Production supplies the live owners required to rebuild all
    /// water/thermal coefficients before every accepted internal substep.
    substep_refresh: ?SubstepRefreshInputs = null,
    /// Restores and dt-scales every pre-WATSUB forcing for each retry
    /// schedule. Absence deliberately disables refinement; replaying only the
    /// transport kernel after a full-hour forcing would change the science.
    substep_transaction_hooks: ?SubstepTransactionHooks = null,
    /// Forces one member of `recovery_substep_counts`. The enclosing hourly
    /// transaction uses this to advance to the next finer physical schedule
    /// after late chemistry failure without rerunning the same coarse WATSUB.
    exact_substep_count: ?u8 = null,
    /// Test-only deterministic failure injection used to prove retry and
    /// whole-hour rollback semantics. Production rejects a non-null pointer.
    test_substep_control: ?*TestSubstepControl = null,
    temporary_profile: ?TemporaryProfile = null,
    /// Temporary diagnostic passthrough for the issue-067 hour-2895 vapor
    /// solver residual trace. See
    /// `vapor_solver.Options.diagnostic_trace_layer_index`. `null` in
    /// production; the caller gates this behind
    /// `run_support.verbose_diagnostics_enabled` and an hour window.
    diagnostic_vapor_layer_index: ?usize = null,
    /// issue-068 (2026-09-20, second round): same hour/cell gating as
    /// `diagnostic_vapor_layer_index` above, threaded to
    /// `heat_solver.Options.diagnostic_trace_layer_index` instead. `null` in
    /// production.
    diagnostic_heat_layer_index: ?usize = null,
};

/// Builds zero-copy solver views over mapped runtime state, then performs one
/// atomic whole-hour WATSUB transaction. NPH is solely a convergence ceiling.
pub fn advanceMapped(
    allocator: std.mem.Allocator,
    grid: *grid_module.GridState,
    hydrology: *hydrology_module.State,
    faces: *hydrology_module.SoilFaces,
    geometry: *const face_geometry_module.State,
    properties: *const solver_properties_module.State,
    workspace: *const workspace_module.State,
    thermal: *const thermal_module.State,
    heat_workspace: *heat_solver.Workspace,
    science: science_module.RuntimeParameters,
    options: MappedOptions,
) !Result {
    if (options.max_iterations == 0 or
        !std.math.isFinite(options.picard_relaxation) or options.picard_relaxation <= 0 or options.picard_relaxation > 1 or
        !std.math.isFinite(options.vapor_pore_tortuosity) or options.vapor_pore_tortuosity < 0 or
        !std.math.isFinite(options.osmotic_reflection_coefficient) or
        !std.math.isFinite(options.water_absolute_tolerance_m3) or options.water_absolute_tolerance_m3 <= 0 or
        !std.math.isFinite(options.temperature_absolute_tolerance_k) or options.temperature_absolute_tolerance_k <= 0 or
        !std.math.isFinite(options.enthalpy_absolute_tolerance_megajoules) or options.enthalpy_absolute_tolerance_megajoules <= 0 or
        !std.math.isFinite(options.nonlinear_relative_tolerance) or options.nonlinear_relative_tolerance <= 0 or
        !std.math.isFinite(options.time_step_hours) or options.time_step_hours <= 0 or options.time_step_hours > 1)
        return error.InvalidMappedSoilStepOptions;
    if (options.external_water_advective_enthalpy_outward_megajoules_by_cell.len != 0 and
        options.external_water_advective_enthalpy_outward_megajoules_by_cell.len != grid.cell_count)
        return error.SoilExternalWaterHeatCellDimensionMismatch;
    if (options.external_water_advective_enthalpy_outward_megajoules_by_layer.len != 0 and
        options.external_water_advective_enthalpy_outward_megajoules_by_layer.len != grid.layer_count)
        return error.SoilExternalWaterHeatLayerDimensionMismatch;
    if ((options.boundary_heat_input_megajoules_by_cell.len != 0 or options.boundary_heat_output_megajoules_by_cell.len != 0) and
        (options.boundary_heat_input_megajoules_by_cell.len != grid.cell_count or options.boundary_heat_output_megajoules_by_cell.len != grid.cell_count))
        return error.SoilBoundaryHeatCellDimensionMismatch;
    if (options.heat_induced_ice_change_by_layer.len != 0 and
        options.heat_induced_ice_change_by_layer.len != grid.layer_count)
        return error.HeatInducedPhaseChangeDimensionMismatch;
    if (options.phase_displacement_by_layer.len != 0 and
        options.phase_displacement_by_layer.len != grid.layer_count)
        return error.SoilPhaseDisplacementDimensionMismatch;
    if (options.phase_endpoint_reference_heat_megajoules_by_layer.len != 0 and
        options.phase_endpoint_reference_heat_megajoules_by_layer.len != grid.layer_count)
        return error.SoilPhaseReferenceHeatDimensionMismatch;
    if (options.renormalization_floor_discard_megajoules_by_layer.len != 0 and
        options.renormalization_floor_discard_megajoules_by_layer.len != grid.layer_count)
        return error.SoilRenormalizationFloorDiscardDimensionMismatch;
    if (options.water_storage_roundoff_allowance_m3_by_layer.len != 0 and
        options.water_storage_roundoff_allowance_m3_by_layer.len != grid.layer_count)
        return error.WaterStorageRoundoffProvenanceDimensionMismatch;
    if (options.heat_storage_roundoff_allowance_megajoules_by_layer.len != 0 and
        options.heat_storage_roundoff_allowance_megajoules_by_layer.len != grid.layer_count)
        return error.HeatStorageRoundoffProvenanceDimensionMismatch;
    @memset(options.external_water_advective_enthalpy_outward_megajoules_by_cell, 0);
    @memset(options.external_water_advective_enthalpy_outward_megajoules_by_layer, 0);
    @memset(options.boundary_heat_input_megajoules_by_cell, 0);
    @memset(options.boundary_heat_output_megajoules_by_cell, 0);
    @memset(options.heat_induced_ice_change_by_layer, .{});
    @memset(options.phase_displacement_by_layer, .{});
    @memset(options.phase_endpoint_reference_heat_megajoules_by_layer, 0);
    @memset(options.renormalization_floor_discard_megajoules_by_layer, 0);
    @memset(options.water_storage_roundoff_allowance_m3_by_layer, 0);
    @memset(options.heat_storage_roundoff_allowance_megajoules_by_layer, 0);
    if (options.test_substep_control) |control| {
        if (!builtin.is_test) return error.InvalidMappedSoilStepOptions;
        control.attempts +|= 1;
        if ((control.fail_time_step_hours_above > 0 and options.time_step_hours > control.fail_time_step_hours_above) or
            (control.fail_from_attempt > 0 and control.attempts >= control.fail_from_attempt))
            return error.ForcedSoilSubstepFailure;
        if (control.succeed_without_solving) {
            if (control.heat_induced_ice_change_by_layer.len != 0) {
                if (control.heat_induced_ice_change_by_layer.len != options.heat_induced_ice_change_by_layer.len)
                    return error.HeatInducedPhaseChangeDimensionMismatch;
                @memcpy(options.heat_induced_ice_change_by_layer, control.heat_induced_ice_change_by_layer);
            }
            if (control.phase_displacement_by_layer.len != 0) {
                if (control.phase_displacement_by_layer.len != options.phase_displacement_by_layer.len)
                    return error.SoilPhaseDisplacementDimensionMismatch;
                for (control.phase_displacement_by_layer) |value|
                    try validatePhaseDisplacement(value);
                @memcpy(options.phase_displacement_by_layer, control.phase_displacement_by_layer);
            }
            if (control.phase_endpoint_reference_heat_megajoules_by_layer.len != 0) {
                if (control.phase_endpoint_reference_heat_megajoules_by_layer.len != options.phase_endpoint_reference_heat_megajoules_by_layer.len)
                    return error.SoilPhaseReferenceHeatDimensionMismatch;
                for (control.phase_endpoint_reference_heat_megajoules_by_layer) |value|
                    if (!std.math.isFinite(value)) return error.NonFiniteSoilPhaseReferenceHeat;
                @memcpy(
                    options.phase_endpoint_reference_heat_megajoules_by_layer,
                    control.phase_endpoint_reference_heat_megajoules_by_layer,
                );
            }
            if (control.renormalization_floor_discard_megajoules_by_layer.len != 0) {
                if (control.renormalization_floor_discard_megajoules_by_layer.len != options.renormalization_floor_discard_megajoules_by_layer.len)
                    return error.SoilRenormalizationFloorDiscardDimensionMismatch;
                for (control.renormalization_floor_discard_megajoules_by_layer) |value|
                    if (!std.math.isFinite(value)) return error.NonFiniteSoilRenormalizationFloorDiscard;
                @memcpy(
                    options.renormalization_floor_discard_megajoules_by_layer,
                    control.renormalization_floor_discard_megajoules_by_layer,
                );
            }
            if (control.water_storage_roundoff_allowance_m3_by_layer.len != 0) {
                if (control.water_storage_roundoff_allowance_m3_by_layer.len != options.water_storage_roundoff_allowance_m3_by_layer.len)
                    return error.WaterStorageRoundoffProvenanceDimensionMismatch;
                for (control.water_storage_roundoff_allowance_m3_by_layer) |value|
                    if (!std.math.isFinite(value) or value < 0)
                        return error.InvalidWaterStorageUpdateArithmeticProvenance;
                @memcpy(
                    options.water_storage_roundoff_allowance_m3_by_layer,
                    control.water_storage_roundoff_allowance_m3_by_layer,
                );
            }
            if (control.heat_storage_roundoff_allowance_megajoules_by_layer.len != 0) {
                if (control.heat_storage_roundoff_allowance_megajoules_by_layer.len != options.heat_storage_roundoff_allowance_megajoules_by_layer.len)
                    return error.HeatStorageRoundoffProvenanceDimensionMismatch;
                for (control.heat_storage_roundoff_allowance_megajoules_by_layer) |value|
                    if (!std.math.isFinite(value) or value < 0)
                        return error.InvalidHeatStorageUpdateArithmeticProvenance;
                @memcpy(
                    options.heat_storage_roundoff_allowance_megajoules_by_layer,
                    control.heat_storage_roundoff_allowance_megajoules_by_layer,
                );
            }
            var result = emptyTestResult();
            result.phase_displacement_by_layer = options.phase_displacement_by_layer;
            return result;
        }
    }
    if (!std.math.isFinite(options.water_conservation_absolute_tolerance_m) or options.water_conservation_absolute_tolerance_m < 0 or !std.math.isFinite(options.water_conservation_relative_tolerance) or options.water_conservation_relative_tolerance <= 0 or !std.math.isFinite(options.heat_conservation_absolute_tolerance_megajoules_per_m2) or options.heat_conservation_absolute_tolerance_megajoules_per_m2 < 0 or !std.math.isFinite(options.heat_conservation_relative_tolerance) or options.heat_conservation_relative_tolerance <= 0) return error.InvalidMappedSoilConservationTolerance;
    try science_module.validate(science);
    if (options.boundary_topology) |topology| try topology.refreshInternalWaterTableWithIceDensity(grid, properties.matrix_bulk_volume_m3, properties.mualem_van_genuchten_parameters, properties.layer_thickness_m, properties.layer_midpoint_depth_m, properties.layer_bottom_depth_m, options.water_table_air_fraction_threshold, options.active_layer_ice_fraction_threshold, options.surface_litter_liquid_water_m3, options.surface_litter_water_retention_capacity_m3, options.cell_area_m2, science.freeze_thaw.ice_density_megagrams_per_m3);
    const scaled_external_water = try allocator.alloc(f64, options.matrix_external_water_source_m3_per_step.len);
    defer allocator.free(scaled_external_water);
    for (scaled_external_water, options.matrix_external_water_source_m3_per_step) |*scaled, hourly|
        scaled.* = hourly * options.time_step_hours;
    const scaled_snow_storage_heat = try allocator.alloc(f64, workspace.snow_storage_heat_flux_megajoules.len);
    defer allocator.free(scaled_snow_storage_heat);
    for (scaled_snow_storage_heat, workspace.snow_storage_heat_flux_megajoules) |*scaled, hourly|
        scaled.* = hourly * options.time_step_hours;
    const scaled_cell_heat_source = try allocator.alloc(f64, workspace.cell_heat_source_megajoules.len);
    defer allocator.free(scaled_cell_heat_source);
    for (scaled_cell_heat_source, workspace.cell_heat_source_megajoules) |*scaled, hourly|
        scaled.* = hourly * options.time_step_hours;
    // The retry controller refreshes these live coefficient owners before
    // every internal step; aliases avoid re-deriving them with hidden clamps.
    const dynamic_air_fraction = workspace.air_fraction;
    const dynamic_liquid_fraction = workspace.liquid_water_fraction;
    const dynamic_ice_fraction = workspace.ice_fraction;
    const dynamic_pore_air_fraction = workspace.fraction_of_pore_volume_air_filled;
    const dynamic_heat_capacity = workspace.heat_capacity_megajoules_per_k;
    const ice_heat_capacity_per_water_equivalent_m3_k =
        try ice_units.heatCapacityPerWaterEquivalentM3K(
            science.ice_heat_capacity_megajoules_per_m3_k,
            science.freeze_thaw.ice_density_megagrams_per_m3,
        );
    // Each soil layer's own dry solid heat capacity, from that layer's own
    // bulk density and volume -- this feeds the per-layer Dall'Amico phase
    // solve (soil/water/enthalpy_balance.zig) unconditionally, regardless of
    // snow/litter presence above. Deliberately does not reproduce the legacy
    // f77src/watsub.f:2082-2083 under-snow defect, where the soil surface's
    // freeze-thaw energy availability (HFLFGX) is scaled by the litter's
    // heat capacity (VHCPR2) instead of the soil's own (VHCPG2) -- see
    // audit/issues/issue-048-watsub-under-snow-soil-freeze-thaw-uses-litter-heat-capacity.md.
    // Do not thread a litter/surface heat capacity into this per-layer array.
    const dry_capacity = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(dry_capacity);
    for (dry_capacity, thermal.dry_solid_heat_capacity_megajoules_per_m3_k, properties.layer_volume_m3) |*capacity, density, volume| {
        capacity.* = density * volume;
        if (!std.math.isFinite(capacity.*) or capacity.* < 0)
            return error.InvalidSoilDryHeatCapacity;
    }
    // Conservation is normalized by the ground control-volume area, not the
    // thermal plan face. The top-layer plan face can include litter volume and
    // therefore differs from the cell area used by the independent closure.
    const conservation_area_by_layer = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(conservation_area_by_layer);
    for (0..grid.cell_count) |cell| {
        const area_m2 = if (options.cell_area_m2.len == 0)
            0
        else
            options.cell_area_m2[cell];
        if (!std.math.isFinite(area_m2) or area_m2 < 0)
            return error.InvalidHeatConservationCellArea;
        for (0..grid.soil_layer_capacity) |layer_offset| {
            conservation_area_by_layer[try grid.layerIndex(cell, layer_offset)] =
                area_m2;
        }
    }
    return advance(allocator, grid, hydrology, faces, .{
        .water_geometry = .{ .source_path_length_m = geometry.source_path_length_m, .destination_path_length_m = geometry.destination_path_length_m, .face_area_m2 = geometry.face_area_m2 },
        .water_properties = .{ .matrix_bulk_volume_m3 = properties.matrix_bulk_volume_m3, .retention_curve = properties.retention_curve, .mualem_van_genuchten_parameters = properties.mualem_van_genuchten_parameters, .lateral_saturated_hydraulic_conductivity_m_per_h = properties.lateral_saturated_hydraulic_conductivity_m_per_h, .macropore_mualem_van_genuchten_parameters = workspace.macropore_mualem_van_genuchten_parameters, .macropore_spacing_m = workspace.macropore_spacing_m, .macropore_radius_m = workspace.macropore_radius_m, .dual_domain_exchange_enabled = &.{}, .dual_domain_geometry_factor = workspace.dual_domain_geometry_factor, .dual_domain_scaling_coefficient = workspace.dual_domain_scaling_coefficient, .frozen_hydraulic_impedance_exponent = workspace.frozen_hydraulic_impedance_exponent, .ice_density_megagrams_per_m3 = science.freeze_thaw.ice_density_megagrams_per_m3, .gravitational_water_potential_mpa_per_m = workspace.gravitational_water_potential_mpa_per_m, .gravitational_potential_megapascal = workspace.gravitational_potential_megapascal, .osmotic_potential_megapascal = workspace.osmotic_potential_megapascal, .rainfall_conductivity_multiplier = properties.rainfall_conductivity_multiplier, .matrix_external_source_m3_per_step = scaled_external_water, .vertical_thickness_m = properties.layer_thickness_m, .osmotic_potential_multiplier = options.osmotic_reflection_coefficient, .nonlinear_time_fraction = options.time_step_hours, .boundary_topology = options.boundary_topology, .boundary_face_area_m2 = workspace.plan_area_m2, .boundary_macropore_hydraulic_conductivity_m2_per_h_megapascal = workspace.macropore_hydraulic_conductivity_m2_per_h_megapascal, .boundary_layer_volume_m3 = properties.layer_volume_m3, .boundary_layer_midpoint_depth_m = properties.layer_midpoint_depth_m, .boundary_layer_bottom_depth_m = properties.layer_bottom_depth_m, .dense_jacobian_cache = options.water_dense_jacobian_cache },
        .water_options = .{ .max_iterations = options.max_iterations, .absolute_tolerance_m3 = options.water_absolute_tolerance_m3, .relative_tolerance = options.nonlinear_relative_tolerance, .picard_relaxation = options.picard_relaxation, .maximum_newton_fraction = 1.0, .dense_newton_max_components = options.dense_newton_max_components },
        .vapor_geometry = .{ .source_path_length_m = geometry.source_path_length_m, .destination_path_length_m = geometry.destination_path_length_m, .face_area_m2 = geometry.face_area_m2 },
        .vapor_properties = .{ .vapor_diffusivity_m2_per_h = workspace.vapor_diffusivity_m2_per_h, .air_fraction = workspace.air_fraction, .porosity_fraction = properties.porosity_fraction, .tortuosity = options.vapor_pore_tortuosity, .time_step_hours = options.time_step_hours },
        .vapor_options = .{ .max_iterations = options.max_iterations, .absolute_tolerance_m3 = options.water_absolute_tolerance_m3, .relative_tolerance = options.nonlinear_relative_tolerance, .picard_relaxation = options.picard_relaxation, .dense_newton_max_components = options.dense_newton_max_components, .diagnostic_trace_layer_index = options.diagnostic_vapor_layer_index },
        .phase_properties = .{ .active_by_layer = faces.active_by_layer, .matrix_bulk_volume_m3 = properties.matrix_bulk_volume_m3, .retention_curve = properties.retention_curve, .mualem_van_genuchten_parameters = properties.mualem_van_genuchten_parameters, .macropore_mualem_van_genuchten_parameters = workspace.macropore_mualem_van_genuchten_parameters, .osmotic_potential_megapascal = workspace.osmotic_potential_megapascal, .saturation_water_potential_megapascal = properties.saturation_water_potential_megapascal, .heat_capacity_megajoules_per_k = dynamic_heat_capacity, .saturated_lateral_matrix_conductivity_m2_per_h_megapascal = workspace.saturated_lateral_matrix_conductivity_m2_per_h_megapascal, .face_area_m2 = workspace.plan_area_m2, .macropore_spacing_m = workspace.macropore_spacing_m, .macropore_radius_m = workspace.macropore_radius_m, .pore_exchange_enabled = workspace.macropore_exchange_enabled, .conservation_cell_area_m2 = conservation_area_by_layer, .conservation_layer_capacity = grid.soil_layer_capacity, .vapor = science.vapor_equilibrium, .freeze_thaw = science.freeze_thaw, .gravitational_water_potential_mpa_per_m = workspace.gravitational_water_potential_mpa_per_m, .liquid_water_heat_capacity_megajoules_per_m3_k = science.liquid_water_heat_capacity_megajoules_per_m3_k, .ice_heat_capacity_megajoules_per_m3_k = ice_heat_capacity_per_water_equivalent_m3_k, .time_step_hours = options.time_step_hours },
        .phase_options = .{ .max_iterations = options.max_iterations, .absolute_tolerance_m3 = options.water_absolute_tolerance_m3, .absolute_temperature_tolerance_k = options.temperature_absolute_tolerance_k, .relative_tolerance = options.nonlinear_relative_tolerance, .energy_conservation_absolute_tolerance_megajoules_per_m2 = options.heat_conservation_absolute_tolerance_megajoules_per_m2, .energy_conservation_relative_tolerance = options.heat_conservation_relative_tolerance, .picard_relaxation = options.picard_relaxation, .diagnostic_trace_layer_index = options.diagnostic_vapor_layer_index },
        .heat_geometry = .{ .source_path_length_m = geometry.source_path_length_m, .destination_path_length_m = geometry.destination_path_length_m, .face_area_m2 = geometry.face_area_m2 },
        .heat_properties = .{ .heat_capacity_megajoules_per_k = dynamic_heat_capacity, .minimum_heat_capacity_megajoules_per_k = workspace.minimum_heat_capacity_megajoules_per_k, .bulk_density_megagrams_per_m3 = properties.bulk_density_megagrams_per_m3, .liquid_water_fraction = dynamic_liquid_fraction, .ice_fraction = dynamic_ice_fraction, .air_fraction = dynamic_air_fraction, .fraction_of_pore_volume_air_filled = dynamic_pore_air_fraction, .solid_conductivity_numerator_m_megajoules_per_h_k = thermal.solid_thermal_conductivity_numerator_m_megajoules_per_h_k, .solid_conductivity_denominator = thermal.solid_thermal_conductivity_denominator, .is_top_soil_layer = workspace.is_top_soil_layer, .top_snow_heat_capacity_megajoules_per_k = workspace.top_snow_heat_capacity_megajoules_per_k, .maximum_negligible_snow_heat_capacity_megajoules_per_k = workspace.maximum_negligible_snow_heat_capacity_megajoules_per_k, .snow_storage_heat_flux_megajoules = scaled_snow_storage_heat, .cell_heat_source_megajoules = scaled_cell_heat_source, .liquid_water_heat_capacity_megajoules_per_m3_k = science.liquid_water_heat_capacity_megajoules_per_m3_k, .turbulence = science.heat_turbulence, .time_step_hours = options.time_step_hours, .geothermal_boundary = if (options.geothermal_enabled_by_cell) |enabled_by_cell| .{ .topology = options.boundary_topology orelse return error.MissingGeothermalBoundaryTopology, .layer_bottom_depth_m = properties.layer_bottom_depth_m, .lower_face_area_m2 = workspace.plan_area_m2, .enabled_by_cell = enabled_by_cell, .mean_annual_temperature_k_by_cell = options.mean_annual_temperature_k_by_cell, .minimum_source_depth_m = options.geothermal_minimum_source_depth_m, .source_depth_below_profile_m = options.geothermal_source_depth_below_profile_m, .conductivity_m_megajoules_per_h_k = options.geothermal_conductivity_m_megajoules_per_h_k, .geothermal_flux_megajoules_per_m2_h = options.geothermal_flux_megajoules_per_m2_h } else null, .enthalpy_coupling = .{ .matrix_liquid_water_m3 = grid.matrix_liquid_water_m3, .matrix_ice_water_equivalent_m3 = grid.matrix_ice_water_m3, .porous_medium_volume_m3 = properties.matrix_bulk_volume_m3, .matrix_pore_capacity_m3 = grid.matrix_pore_capacity_m3, .mualem_van_genuchten = properties.mualem_van_genuchten_parameters, .gravitational_water_potential_mpa_per_m = workspace.gravitational_water_potential_mpa_per_m, .pure_water_melting_temperature_k = science.freeze_thaw.pure_water_freezing_temperature_k, .ice_water_equivalent_heat_capacity_megajoules_per_m3_k = ice_heat_capacity_per_water_equivalent_m3_k, .latent_heat_of_fusion_megajoules_per_m3 = science.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, .ice_density_megagrams_per_m3 = science.freeze_thaw.ice_density_megagrams_per_m3, .solver_options = .{ .max_iterations = options.max_iterations, .absolute_enthalpy_tolerance_megajoules = options.enthalpy_absolute_tolerance_megajoules, .relative_enthalpy_tolerance = options.nonlinear_relative_tolerance }, .conservation_cell_area_m2 = conservation_area_by_layer, .conservation_absolute_tolerance_megajoules_per_m2 = options.heat_conservation_absolute_tolerance_megajoules_per_m2, .conservation_relative_tolerance = options.heat_conservation_relative_tolerance, .macropore_liquid_water_m3 = grid.macropore_liquid_water_m3, .macropore_ice_water_equivalent_m3 = grid.macropore_ice_water_m3, .macropore_porous_medium_volume_m3 = grid.macropore_pore_capacity_m3, .macropore_mualem_van_genuchten = workspace.macropore_mualem_van_genuchten_parameters } },
        .heat_options = .{ .failure_report_io = options.heat_failure_report_io, .max_iterations = options.max_iterations, .absolute_tolerance_k = options.temperature_absolute_tolerance_k, .relative_tolerance = options.nonlinear_relative_tolerance, .picard_relaxation = options.picard_relaxation, .maximum_newton_fraction = 1.0, .dense_newton_max_components = options.dense_newton_max_components, .diagnostic_trace_layer_index = options.diagnostic_heat_layer_index },
        .heat_workspace = heat_workspace,
        .dry_solid_heat_capacity_megajoules_per_k = dry_capacity,
        .water_conservation_absolute_tolerance_m = options.water_conservation_absolute_tolerance_m,
        .water_conservation_relative_tolerance = options.water_conservation_relative_tolerance,
        .heat_conservation_absolute_tolerance_megajoules_per_m2 = options.heat_conservation_absolute_tolerance_megajoules_per_m2,
        .heat_conservation_relative_tolerance = options.heat_conservation_relative_tolerance,
        .cell_area_m2 = options.cell_area_m2,
        .external_water_advective_enthalpy_outward_megajoules_by_cell = options.external_water_advective_enthalpy_outward_megajoules_by_cell,
        .external_water_advective_enthalpy_outward_megajoules_by_layer = options.external_water_advective_enthalpy_outward_megajoules_by_layer,
        .boundary_heat_input_megajoules_by_cell = options.boundary_heat_input_megajoules_by_cell,
        .boundary_heat_output_megajoules_by_cell = options.boundary_heat_output_megajoules_by_cell,
        .heat_induced_ice_change_by_layer = options.heat_induced_ice_change_by_layer,
        .phase_displacement_by_layer = options.phase_displacement_by_layer,
        .phase_endpoint_reference_heat_megajoules_by_layer = options.phase_endpoint_reference_heat_megajoules_by_layer,
        .renormalization_floor_discard_megajoules_by_layer = options.renormalization_floor_discard_megajoules_by_layer,
        .water_storage_roundoff_allowance_m3_by_layer = options.water_storage_roundoff_allowance_m3_by_layer,
        .heat_storage_roundoff_allowance_megajoules_by_layer = options.heat_storage_roundoff_allowance_megajoules_by_layer,
        .post_phase_context = if (options.substep_transaction_hooks) |hooks| hooks.context else null,
        .post_phase_pre_heat = if (options.substep_transaction_hooks) |hooks| hooks.post_phase_pre_heat else null,
        .mutable_heat_source_megajoules = scaled_cell_heat_source,
        .temporary_profile = options.temporary_profile,
    });
}

fn emptyTestResult() Result {
    return .{
        .water = .{ .iterations = 0, .newton_raphson_steps = 0, .picard_steps = 0, .maximum_scaled_residual = 0 },
        .vapor = .{ .iterations = 0, .newton_raphson_steps = 0, .picard_steps = 0, .maximum_scaled_residual = 0 },
        .phase = .{ .iterations = 0, .newton_raphson_steps = 0, .picard_steps = 0, .maximum_scaled_residual = 0 },
        .heat = .{ .iterations = 0, .newton_raphson_steps = 0, .picard_steps = 0, .maximum_scaled_residual = 0, .boundary_heat_input_megajoules = 0, .boundary_heat_output_megajoules = 0 },
    };
}

/// One atomic WATSUB transport transaction. Each process converges directly;
/// there is no surrounding sub-hour full-model loop.
pub fn advance(allocator: std.mem.Allocator, grid: *grid_module.GridState, hydrology: *hydrology_module.State, faces: *hydrology_module.SoilFaces, inputs: Inputs) !Result {
    const temporary_profile = inputs.temporary_profile;
    var temporary_profile_section_start: std.Io.Timestamp = if (temporary_profile) |profile|
        std.Io.Clock.now(.boot, profile.io)
    else
        undefined;
    var snapshot = try Snapshot.capture(allocator, grid, hydrology, faces);
    defer snapshot.deinit();
    errdefer snapshot.restore(grid, hydrology, faces);
    const diagnostics_enabled = inputs.dry_solid_heat_capacity_megajoules_per_k.len != 0;
    if ((inputs.boundary_heat_input_megajoules_by_cell.len != 0 or inputs.boundary_heat_output_megajoules_by_cell.len != 0) and
        (inputs.boundary_heat_input_megajoules_by_cell.len != grid.cell_count or inputs.boundary_heat_output_megajoules_by_cell.len != grid.cell_count))
        return error.SoilBoundaryHeatCellDimensionMismatch;
    if (inputs.external_water_advective_enthalpy_outward_megajoules_by_layer.len != 0 and
        inputs.external_water_advective_enthalpy_outward_megajoules_by_layer.len != grid.layer_count)
        return error.SoilExternalWaterHeatLayerDimensionMismatch;
    if (inputs.heat_induced_ice_change_by_layer.len != 0 and
        inputs.heat_induced_ice_change_by_layer.len != grid.layer_count)
        return error.HeatInducedPhaseChangeDimensionMismatch;
    if (inputs.phase_displacement_by_layer.len != 0 and
        inputs.phase_displacement_by_layer.len != grid.layer_count)
        return error.SoilPhaseDisplacementDimensionMismatch;
    if (inputs.phase_endpoint_reference_heat_megajoules_by_layer.len != 0 and
        inputs.phase_endpoint_reference_heat_megajoules_by_layer.len != grid.layer_count)
        return error.SoilPhaseReferenceHeatDimensionMismatch;
    if (inputs.renormalization_floor_discard_megajoules_by_layer.len != 0 and
        inputs.renormalization_floor_discard_megajoules_by_layer.len != grid.layer_count)
        return error.SoilRenormalizationFloorDiscardDimensionMismatch;
    if (inputs.water_storage_roundoff_allowance_m3_by_layer.len != 0 and
        inputs.water_storage_roundoff_allowance_m3_by_layer.len != grid.layer_count)
        return error.WaterStorageRoundoffProvenanceDimensionMismatch;
    if (inputs.heat_storage_roundoff_allowance_megajoules_by_layer.len != 0 and
        inputs.heat_storage_roundoff_allowance_megajoules_by_layer.len != grid.layer_count)
        return error.HeatStorageRoundoffProvenanceDimensionMismatch;
    if (inputs.phase_properties.heat_capacity_megajoules_per_k.len != grid.layer_count)
        return error.SoilPhaseSolverDimensionMismatch;
    @memset(inputs.boundary_heat_input_megajoules_by_cell, 0);
    @memset(inputs.boundary_heat_output_megajoules_by_cell, 0);
    @memset(inputs.external_water_advective_enthalpy_outward_megajoules_by_layer, 0);
    errdefer @memset(inputs.external_water_advective_enthalpy_outward_megajoules_by_layer, 0);
    @memset(inputs.heat_induced_ice_change_by_layer, .{});
    errdefer @memset(inputs.heat_induced_ice_change_by_layer, .{});
    @memset(inputs.phase_displacement_by_layer, .{});
    errdefer @memset(inputs.phase_displacement_by_layer, .{});
    @memset(inputs.phase_endpoint_reference_heat_megajoules_by_layer, 0);
    errdefer @memset(inputs.phase_endpoint_reference_heat_megajoules_by_layer, 0);
    @memset(inputs.renormalization_floor_discard_megajoules_by_layer, 0);
    errdefer @memset(inputs.renormalization_floor_discard_megajoules_by_layer, 0);
    @memset(inputs.water_storage_roundoff_allowance_m3_by_layer, 0);
    errdefer @memset(inputs.water_storage_roundoff_allowance_m3_by_layer, 0);
    @memset(inputs.heat_storage_roundoff_allowance_megajoules_by_layer, 0);
    errdefer @memset(inputs.heat_storage_roundoff_allowance_megajoules_by_layer, 0);
    if (diagnostics_enabled and inputs.dry_solid_heat_capacity_megajoules_per_k.len != grid.layer_count)
        return error.SoilEnergyDiagnosticDimensionMismatch;
    // Every physical caller needs the dry extensive capacity so split-stage
    // water/vapor moves and the phase/heat solvers conserve the same enthalpy.
    // Production supplies it explicitly. Isolated callers may omit the
    // diagnostic binding; derive the identical invariant once from their
    // accepted entry capacity and entry carriers instead of disabling the
    // science correction.
    const dry_solid_heat_capacity_megajoules_per_k = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(dry_solid_heat_capacity_megajoules_per_k);
    if (diagnostics_enabled) {
        @memcpy(
            dry_solid_heat_capacity_megajoules_per_k,
            inputs.dry_solid_heat_capacity_megajoules_per_k,
        );
    } else {
        const liquid_capacity = inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k;
        const ice_capacity = inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k;
        for (dry_solid_heat_capacity_megajoules_per_k, 0..) |*dry_capacity, layer| {
            const supplied = inputs.phase_properties.heat_capacity_megajoules_per_k[layer];
            const water_capacity = liquid_capacity *
                (grid.matrix_liquid_water_m3[layer] +
                    grid.macropore_liquid_water_m3[layer] +
                    grid.water_vapor_volume_m3[layer]) +
                ice_capacity *
                    (grid.matrix_ice_water_m3[layer] +
                        grid.macropore_ice_water_m3[layer]);
            const scale = @max(1, @max(@abs(supplied), @abs(water_capacity)));
            const roundoff = 128 * std.math.floatEps(f64) * scale;
            if (!std.math.isFinite(supplied) or supplied <= 0 or
                !std.math.isFinite(water_capacity) or
                supplied - water_capacity < -roundoff)
                return error.InvalidSoilPhaseHeatCapacity;
            dry_capacity.* = @max(0, supplied - water_capacity);
        }
    }
    const stage_enthalpy_megajoules_by_cell = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(stage_enthalpy_megajoules_by_cell);
    const stage_enthalpy_roundoff_allowance_megajoules_by_cell =
        try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(stage_enthalpy_roundoff_allowance_megajoules_by_cell);
    const ice_before_heat_m3 = try allocator.alloc(HeatInducedIceChange, grid.layer_count);
    defer allocator.free(ice_before_heat_m3);
    const vapor_before_phase_m3 = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(vapor_before_phase_m3);
    const refreshed_heat_capacity_megajoules_per_k = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(refreshed_heat_capacity_megajoules_per_k);
    const post_richards_total_water_equivalent_m3 = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(post_richards_total_water_equivalent_m3);
    const post_phase_external_water_change_m3 = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(post_phase_external_water_change_m3);
    @memset(post_phase_external_water_change_m3, 0);
    if ((inputs.post_phase_pre_heat == null) != (inputs.post_phase_context == null) or
        (inputs.post_phase_pre_heat != null and inputs.mutable_heat_source_megajoules.len != grid.layer_count))
        return error.PostPhaseBoundaryBindingMismatch;
    try fillCellEnthalpyMegajoules(stage_enthalpy_megajoules_by_cell, grid, dry_solid_heat_capacity_megajoules_per_k, inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k);
    var water_options = inputs.water_options;
    traceThermalStage(temporary_profile, "entry", grid, inputs, dry_solid_heat_capacity_megajoules_per_k);
    water_options.conservation_absolute_tolerance_m =
        inputs.water_conservation_absolute_tolerance_m;
    water_options.conservation_relative_tolerance =
        inputs.water_conservation_relative_tolerance;
    water_options.cell_area_m2 = inputs.cell_area_m2;
    if (temporary_profile) |profile| {
        const now = std.Io.Clock.now(.boot, profile.io);
        profile.counters.setup_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
        temporary_profile_section_start = now;
    }
    const water = try water_solver.solveAndBindTransportFaces(
        allocator,
        grid,
        hydrology,
        faces,
        inputs.water_geometry,
        inputs.water_properties,
        water_options,
    );
    traceThermalStage(temporary_profile, "richards_transport", grid, inputs, dry_solid_heat_capacity_megajoules_per_k);
    if (temporary_profile) |profile| {
        const now = std.Io.Clock.now(.boot, profile.io);
        profile.counters.water_solver_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
        temporary_profile_section_start = now;
    }
    try validatePerLayerRichardsWaterClosure(
        allocator,
        grid,
        hydrology,
        faces,
        inputs.water_conservation_absolute_tolerance_m,
        inputs.water_conservation_relative_tolerance,
        inputs.cell_area_m2,
        inputs.water_properties.matrix_external_source_m3_per_step,
        snapshot.grid_matrix_water,
        snapshot.grid_macro_water,
        inputs.water_storage_roundoff_allowance_m3_by_layer,
    );
    const richards_energy_change = if (diagnostics_enabled)
        try enthalpyChangeFromSnapshot(stage_enthalpy_megajoules_by_cell, grid, dry_solid_heat_capacity_megajoules_per_k, inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k)
    else
        EnergyChange{};
    try deriveExternalWaterFluxes(grid, hydrology, faces, snapshot.grid_matrix_water, snapshot.grid_macro_water);
    try validatePerCellWaterBoundaryClosure(
        grid,
        hydrology,
        inputs.water_conservation_absolute_tolerance_m,
        inputs.water_conservation_relative_tolerance,
        inputs.cell_area_m2,
        inputs.water_properties.matrix_external_source_m3_per_step,
        inputs.water_storage_roundoff_allowance_m3_by_layer,
        snapshot.grid_matrix_water,
        snapshot.grid_macro_water,
    );
    // Value the departing water at the temperature resident right now, which
    // is the same state the `richards_energy_change` census above measured.
    // Anything later in this transaction changes `soil_temperature_k` and
    // would misvalue water that has already left.
    if (inputs.external_water_advective_enthalpy_outward_megajoules_by_cell.len != 0 and
        inputs.external_water_advective_enthalpy_outward_megajoules_by_cell.len != grid.cell_count)
        return error.SoilExternalWaterHeatCellDimensionMismatch;
    @memset(inputs.external_water_advective_enthalpy_outward_megajoules_by_cell, 0);
    var external_water_advective_enthalpy_outward_megajoules: f64 = 0;
    for (0..grid.cell_count) |cell| for (0..grid.active_soil_layer_count[cell]) |layer| {
        const index = try grid.layerIndex(cell, layer);
        const layer_heat =
            (hydrology.micropore_external_water_flux_m3_per_step[index] +
                hydrology.macropore_external_water_flux_m3_per_step[index]) *
            inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k *
            grid.soil_temperature_k[index];
        external_water_advective_enthalpy_outward_megajoules += layer_heat;
        if (inputs.external_water_advective_enthalpy_outward_megajoules_by_layer.len != 0) {
            inputs.external_water_advective_enthalpy_outward_megajoules_by_layer[index] = layer_heat;
            if (!std.math.isFinite(inputs.external_water_advective_enthalpy_outward_megajoules_by_layer[index]))
                return error.NonFiniteExternalWaterAdvectiveEnthalpy;
        }
        if (inputs.external_water_advective_enthalpy_outward_megajoules_by_cell.len != 0) {
            inputs.external_water_advective_enthalpy_outward_megajoules_by_cell[cell] += layer_heat;
            if (!std.math.isFinite(inputs.external_water_advective_enthalpy_outward_megajoules_by_cell[cell]))
                return error.NonFiniteExternalWaterAdvectiveEnthalpy;
        }
    };
    if (!std.math.isFinite(external_water_advective_enthalpy_outward_megajoules))
        return error.NonFiniteExternalWaterAdvectiveEnthalpy;
    // Richards moved water volume while every cell temperature was held
    // fixed. The enthalpy census therefore records, for each internal face,
    // `C_l * F * (T_destination - T_source)`: the donor's water arrives
    // already carrying the RECIPIENT's temperature. That is not a physical
    // energy flow, and the spatial heat solve below then transports the same
    // water's heat again with proper donor upwinding, so the artifact is left
    // over as unexplained energy.
    //
    // Restore each cell to the enthalpy it is entitled to: what it held
    // before the water moved, less only what genuinely left the domain across
    // the external boundary (valued at this cell's pre-move temperature).
    // Then invert the census definition for the temperature that the
    // post-Richards water content implies. Internal water movement becomes
    // enthalpy-neutral, which is what WATSUB achieves by applying FLWL and
    // HFLWL in the same update, and the donor advection in the heat solve is
    // left as the sole owner of advective energy transport.
    try renormalizeTemperatureToConservedEnthalpy(
        stage_enthalpy_megajoules_by_cell,
        grid,
        hydrology,
        dry_solid_heat_capacity_megajoules_per_k,
        inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
        inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k,
        inputs.cell_area_m2,
        inputs.renormalization_floor_discard_megajoules_by_layer,
    );
    try validateAcceptedWaterBoundaryBalance(
        grid,
        hydrology,
        snapshot.grid_matrix_water,
        snapshot.grid_macro_water,
        inputs.water_conservation_absolute_tolerance_m,
        inputs.water_conservation_relative_tolerance,
        inputs.cell_area_m2,
    );
    for (post_richards_total_water_equivalent_m3, 0..) |*total, layer|
        total.* = grid.matrix_liquid_water_m3[layer] +
            grid.macropore_liquid_water_m3[layer] +
            grid.matrix_ice_water_m3[layer] +
            grid.macropore_ice_water_m3[layer] +
            grid.water_vapor_volume_m3[layer];
    traceThermalStage(temporary_profile, "richards_rebase", grid, inputs, dry_solid_heat_capacity_megajoules_per_k);
    try fillCellEnthalpyMegajoules(stage_enthalpy_megajoules_by_cell, grid, dry_solid_heat_capacity_megajoules_per_k, inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k);
    if (temporary_profile) |profile| {
        const now = std.Io.Clock.now(.boot, profile.io);
        profile.counters.richards_post_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
        temporary_profile_section_start = now;
    }
    const vapor = try vapor_solver.solveAndBindTransportFaces(allocator, grid, hydrology, faces, inputs.vapor_geometry, inputs.vapor_properties, inputs.vapor_options);
    traceThermalStage(temporary_profile, "vapor_transport", grid, inputs, dry_solid_heat_capacity_megajoules_per_k);
    if (temporary_profile) |profile| {
        const now = std.Io.Clock.now(.boot, profile.io);
        profile.counters.vapor_solver_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
        temporary_profile_section_start = now;
    }
    // WATSUB applies FLVL and its donor-upwind HFLVL in the same energy
    // update. The split Zig stages first move vapor at fixed layer
    // temperatures and later apply the donor heat in the spatial solve. At
    // unequal temperatures that intermediate move fabricates
    // `C_l*F*(T_destination-T_source)` before the real convective heat is even
    // applied. Restore every layer's pre-transport enthalpy here; the accepted
    // vapor face flux remains bound and is still the sole donor-heat owner in
    // the spatial solve below.
    try renormalizeTemperatureToFixedCellEnthalpy(
        stage_enthalpy_megajoules_by_cell,
        grid,
        dry_solid_heat_capacity_megajoules_per_k,
        inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
        inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k,
        inputs.cell_area_m2,
        inputs.renormalization_floor_discard_megajoules_by_layer,
    );
    traceThermalStage(temporary_profile, "vapor_rebase", grid, inputs, dry_solid_heat_capacity_megajoules_per_k);
    const vapor_energy_change = if (diagnostics_enabled)
        try enthalpyChangeFromSnapshot(stage_enthalpy_megajoules_by_cell, grid, dry_solid_heat_capacity_megajoules_per_k, inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k)
    else
        EnergyChange{};
    const latent_heat_megajoules = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(latent_heat_megajoules);
    const pore_exchange_m3 = try allocator.alloc(f64, grid.layer_count);
    defer allocator.free(pore_exchange_m3);
    const phase_displacement_storage = try allocator.alloc(
        f64,
        try std.math.mul(
            usize,
            if (inputs.phase_displacement_by_layer.len == 0) 0 else grid.layer_count,
            5,
        ),
    );
    defer allocator.free(phase_displacement_storage);
    const phase_displacement_outputs: ?phase_solver.DisplacementOutputs = if (inputs.phase_displacement_by_layer.len == 0)
        null
    else
        .{
            .matrix_liquid_water_m3 = phase_displacement_storage[0 * grid.layer_count .. 1 * grid.layer_count],
            .matrix_ice_water_equivalent_m3 = phase_displacement_storage[1 * grid.layer_count .. 2 * grid.layer_count],
            .macropore_liquid_water_m3 = phase_displacement_storage[2 * grid.layer_count .. 3 * grid.layer_count],
            .macropore_ice_water_equivalent_m3 = phase_displacement_storage[3 * grid.layer_count .. 4 * grid.layer_count],
            .advective_enthalpy_megajoules = phase_displacement_storage[4 * grid.layer_count .. 5 * grid.layer_count],
        };
    try fillCellEnthalpyMegajoules(stage_enthalpy_megajoules_by_cell, grid, dry_solid_heat_capacity_megajoules_per_k, inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k);
    @memcpy(vapor_before_phase_m3, grid.water_vapor_volume_m3);
    for (ice_before_heat_m3, grid.matrix_ice_water_m3, grid.macropore_ice_water_m3) |*before, matrix, macropore|
        before.* = .{
            .matrix_water_equivalent_m3 = matrix,
            .macropore_water_equivalent_m3 = macropore,
        };
    try refreshExtensiveHeatCapacity(
        refreshed_heat_capacity_megajoules_per_k,
        grid,
        dry_solid_heat_capacity_megajoules_per_k,
        inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k,
    );
    var phase_properties = inputs.phase_properties;
    phase_properties.heat_capacity_megajoules_per_k =
        refreshed_heat_capacity_megajoules_per_k;
    if (temporary_profile) |profile| {
        const now = std.Io.Clock.now(.boot, profile.io);
        profile.counters.vapor_post_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
        temporary_profile_section_start = now;
    }
    const phase_result = try phase_solver.solve(allocator, grid, phase_properties, .{
        .latent_heat_megajoules = latent_heat_megajoules,
        .macropore_to_matrix_water_m3 = pore_exchange_m3,
        .displacement = phase_displacement_outputs,
    }, inputs.phase_options);
    traceThermalStage(temporary_profile, "phase", grid, inputs, dry_solid_heat_capacity_megajoules_per_k);
    if (temporary_profile) |profile| {
        const now = std.Io.Clock.now(.boot, profile.io);
        profile.counters.phase_solver_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
        temporary_profile_section_start = now;
    }
    @memcpy(hydrology.macropore_to_matrix_water_flux_m3_per_step, pore_exchange_m3);
    if (phase_displacement_outputs) |displacement| for (inputs.phase_displacement_by_layer, 0..) |*published, layer| {
        const value: PhaseDisplacement = .{
            .matrix_liquid_water_m3 = displacement.matrix_liquid_water_m3[layer],
            .matrix_ice_water_equivalent_m3 = displacement.matrix_ice_water_equivalent_m3[layer],
            .macropore_liquid_water_m3 = displacement.macropore_liquid_water_m3[layer],
            .macropore_ice_water_equivalent_m3 = displacement.macropore_ice_water_equivalent_m3[layer],
            .advective_enthalpy_megajoules = displacement.advective_enthalpy_megajoules[layer],
        };
        try validatePhaseDisplacement(value);
        published.* = value;
    };
    if (inputs.phase_endpoint_reference_heat_megajoules_by_layer.len != 0) {
        const liquid_capacity = inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k;
        const ice_capacity = inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k;
        const melting_temperature = inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k;
        const vaporization_latent = inputs.phase_properties.vapor.latent_heat_of_vaporization_megajoules_per_m3;
        for (inputs.phase_endpoint_reference_heat_megajoules_by_layer, 0..) |*reference_heat, layer| {
            const ice_change_m3 =
                grid.matrix_ice_water_m3[layer] + grid.macropore_ice_water_m3[layer] -
                ice_before_heat_m3[layer].matrix_water_equivalent_m3 -
                ice_before_heat_m3[layer].macropore_water_equivalent_m3;
            const vapor_change_m3 = grid.water_vapor_volume_m3[layer] -
                vapor_before_phase_m3[layer];
            reference_heat.* = try phaseEndpointReferenceHeatMegajoules(
                ice_change_m3,
                vapor_change_m3,
                liquid_capacity,
                ice_capacity,
                melting_temperature,
                vaporization_latent,
            );
        }
    }
    const phase_energy_change = if (diagnostics_enabled)
        try enthalpyChangeFromSnapshot(stage_enthalpy_megajoules_by_cell, grid, dry_solid_heat_capacity_megajoules_per_k, inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k)
    else
        EnergyChange{};
    if (inputs.post_phase_pre_heat) |post_phase| try post_phase(
        inputs.post_phase_context.?,
        inputs.phase_properties.time_step_hours,
        grid,
        hydrology,
        inputs.mutable_heat_source_megajoules,
        post_phase_external_water_change_m3,
    );
    traceThermalStage(temporary_profile, "surface_hook", grid, inputs, dry_solid_heat_capacity_megajoules_per_k);
    @memcpy(hydrology.micropore_water_volume_m3, grid.matrix_liquid_water_m3);
    @memcpy(hydrology.macropore_water_volume_m3, grid.macropore_liquid_water_m3);
    @memcpy(hydrology.matrix_air_volume_m3, grid.matrix_air_volume_m3);
    @memcpy(hydrology.macropore_air_volume_m3, grid.macropore_air_volume_m3);
    @memcpy(hydrology.air_volume_m3, grid.air_volume_m3);
    @memcpy(hydrology.water_vapor_volume_m3, grid.water_vapor_volume_m3);
    // The phase solver's sixth coordinate is already the WATSUB ENGY1/VHCP1
    // endpoint temperature and therefore already contains condensation and
    // fusion enthalpy. Passing `latent_heat_megajoules` again as a heat source would
    // apply both latent terms twice. The spatial heat solve starts from that
    // phase-consistent temperature and adds only non-phase sources,
    // conduction, and convective carrier heat.
    try fillCellEnthalpyMegajoules(stage_enthalpy_megajoules_by_cell, grid, dry_solid_heat_capacity_megajoules_per_k, inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k);
    // Pair the arithmetic certificate with this exact endpoint census. Phase
    // change and the post-phase hook may both have changed the state since the
    // earlier diagnostic snapshots.
    try fillCellEnthalpyRoundoffAllowances(
        stage_enthalpy_roundoff_allowance_megajoules_by_cell,
        grid,
        dry_solid_heat_capacity_megajoules_per_k,
        inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
        inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k,
    );
    for (ice_before_heat_m3, grid.matrix_ice_water_m3, grid.macropore_ice_water_m3) |*before, matrix, macropore|
        before.* = .{
            .matrix_water_equivalent_m3 = matrix,
            .macropore_water_equivalent_m3 = macropore,
        };
    // HEAT-002: the solver's extensive heat capacity is built by
    // `hourly_workspace.refresh` from the water state at the TOP of the hour,
    // but the Richards, vapor, and phase solvers above have already moved
    // liquid, vapor, and ice between cells inside this same transaction. The
    // spatial heat solve then converts its energy sources into a temperature
    // change with the stale capacity, while the landscape census values the
    // resulting temperature with the capacity implied by the water actually
    // resident. The two disagree by
    // `(C_census - C_solver) * dT` per cell, which appears as unexplained
    // energy of order 1e-4 MJ/m2/h and does not cancel over a day.
    //
    // Rebuild the capacity from the current grid state, using exactly the
    // census definition in `cellEnthalpyMegajoules` (WATSUB VHCP1: liquid
    // capacity carries the vapor volume as well). The solver itself conserves
    // to ~1e-7 MJ against whatever capacity it is given, so this makes the
    // conserved quantity the same one the census measures.
    var heat_properties = inputs.heat_properties;
    {
        if (inputs.heat_properties.heat_capacity_megajoules_per_k.len != grid.layer_count)
            return error.SoilHeatSolverDimensionMismatch;
        for (inputs.heat_properties.heat_capacity_megajoules_per_k) |supplied| {
            if (!std.math.isFinite(supplied) or supplied <= 0) return error.InvalidSoilHeatCapacity;
        }
        try refreshExtensiveHeatCapacity(
            refreshed_heat_capacity_megajoules_per_k,
            grid,
            dry_solid_heat_capacity_megajoules_per_k,
            inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k,
            inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k,
        );
        heat_properties.heat_capacity_megajoules_per_k =
            refreshed_heat_capacity_megajoules_per_k;
    }
    if (temporary_profile) |profile| {
        const now = std.Io.Clock.now(.boot, profile.io);
        profile.counters.phase_post_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
        temporary_profile_section_start = now;
    }
    var owned_heat_workspace: ?heat_solver.Workspace = null;
    defer if (owned_heat_workspace) |*workspace| workspace.deinit();
    const active_heat_workspace = inputs.heat_workspace orelse workspace: {
        owned_heat_workspace = try heat_solver.Workspace.init(
            allocator,
            grid.layer_count,
            faces.micropore_faces.len,
            inputs.heat_options.dense_newton_max_components,
        );
        break :workspace &owned_heat_workspace.?;
    };
    captureColdHeatInput(temporary_profile, allocator, grid, faces, inputs.heat_geometry, heat_properties, inputs.heat_options) catch |err| {
        std.log.warn("cold heat input capture failed: {s}", .{@errorName(err)});
    };
    const heat_result = try heat_solver.solveAndBindTransportFacesWithWorkspace(
        active_heat_workspace,
        grid,
        hydrology,
        faces,
        inputs.heat_geometry,
        heat_properties,
        inputs.heat_options,
    );
    traceThermalStage(temporary_profile, "heat", grid, inputs, dry_solid_heat_capacity_megajoules_per_k);
    if (temporary_profile) |profile| {
        const now = std.Io.Clock.now(.boot, profile.io);
        profile.counters.heat_solver_ns += temporary_profile_section_start.durationTo(now).nanoseconds;
        temporary_profile_section_start = now;
    }
    if (inputs.boundary_heat_input_megajoules_by_cell.len != 0) {
        const coupling = heat_properties.enthalpy_coupling;
        const partition = try heat_solver.acceptedBoundaryHeatByHorizontalCell(
            heat_properties,
            grid.soil_temperature_k,
            .{
                .matrix_liquid_m3 = grid.matrix_liquid_water_m3,
                .matrix_ice_m3 = grid.matrix_ice_water_m3,
                .macropore_liquid_m3 = grid.macropore_liquid_water_m3,
                .macropore_ice_m3 = grid.macropore_ice_water_m3,
                .macropore_enabled = coupling != null and coupling.?.macropore_liquid_water_m3.len == grid.layer_count,
                .ice_density_megagrams_per_m3 = if (coupling) |value| value.ice_density_megagrams_per_m3 else 1,
            },
            grid.soil_layer_capacity,
            inputs.boundary_heat_input_megajoules_by_cell,
            inputs.boundary_heat_output_megajoules_by_cell,
        );
        const scale = @max(1, @max(heat_result.boundary_heat_input_megajoules, heat_result.boundary_heat_output_megajoules));
        if (@abs(partition.input_megajoules - heat_result.boundary_heat_input_megajoules) > 64 * std.math.floatEps(f64) * scale or
            @abs(partition.output_megajoules - heat_result.boundary_heat_output_megajoules) > 64 * std.math.floatEps(f64) * scale)
            return error.SoilBoundaryHeatPerCellMismatch;
    }
    if (diagnostics_enabled) try validatePerLayerSpatialHeatClosure(
        allocator,
        grid,
        hydrology,
        faces,
        stage_enthalpy_megajoules_by_cell,
        stage_enthalpy_roundoff_allowance_megajoules_by_cell,
        active_heat_workspace.accepted_conservation_representability_megajoules,
        dry_solid_heat_capacity_megajoules_per_k,
        heat_properties.cell_heat_source_megajoules,
        inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k,
        inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
        inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k,
        inputs.heat_conservation_absolute_tolerance_megajoules_per_m2,
        inputs.heat_conservation_relative_tolerance,
        inputs.cell_area_m2,
        inputs.heat_storage_roundoff_allowance_megajoules_by_layer,
        inputs.phase_endpoint_reference_heat_megajoules_by_layer,
        inputs.renormalization_floor_discard_megajoules_by_layer,
    );
    try validatePerLayerPostRichardsTotalWaterClosure(
        allocator,
        grid,
        faces,
        post_richards_total_water_equivalent_m3,
        inputs.phase_displacement_by_layer,
        post_phase_external_water_change_m3,
        inputs.water_conservation_absolute_tolerance_m,
        inputs.water_conservation_relative_tolerance,
        inputs.cell_area_m2,
        inputs.water_storage_roundoff_allowance_m3_by_layer,
        inputs.vapor_options.absolute_tolerance_m3,
        inputs.vapor_options.relative_tolerance,
    );
    const spatial_heat_energy_change = if (diagnostics_enabled)
        try enthalpyChangeFromSnapshot(stage_enthalpy_megajoules_by_cell, grid, dry_solid_heat_capacity_megajoules_per_k, inputs.phase_properties.liquid_water_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.ice_heat_capacity_megajoules_per_m3_k, inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3, inputs.phase_properties.freeze_thaw.pure_water_freezing_temperature_k)
    else
        EnergyChange{};
    var heat_solver_ice_change_m3: f64 = 0;
    for (ice_before_heat_m3, grid.matrix_ice_water_m3, grid.macropore_ice_water_m3, 0..) |before, matrix, macropore, layer| {
        const change: HeatInducedIceChange = .{
            .matrix_water_equivalent_m3 = matrix - before.matrix_water_equivalent_m3,
            .macropore_water_equivalent_m3 = macropore - before.macropore_water_equivalent_m3,
        };
        if (!std.math.isFinite(change.matrix_water_equivalent_m3) or
            !std.math.isFinite(change.macropore_water_equivalent_m3))
            return error.NonFiniteHeatInducedPhaseChange;
        if (inputs.heat_induced_ice_change_by_layer.len != 0)
            inputs.heat_induced_ice_change_by_layer[layer] = change;
        if (diagnostics_enabled)
            heat_solver_ice_change_m3 += change.matrix_water_equivalent_m3 +
                change.macropore_water_equivalent_m3;
    }
    // The mapped heat residual performs the final Dall'Amico enthalpy
    // repartition at its accepted temperature. Publish that atomic phase
    // state instead of retaining the pre-conduction phase snapshot.
    @memcpy(hydrology.micropore_water_volume_m3, grid.matrix_liquid_water_m3);
    @memcpy(hydrology.macropore_water_volume_m3, grid.macropore_liquid_water_m3);
    @memcpy(hydrology.matrix_air_volume_m3, grid.matrix_air_volume_m3);
    @memcpy(hydrology.macropore_air_volume_m3, grid.macropore_air_volume_m3);
    @memcpy(hydrology.air_volume_m3, grid.air_volume_m3);
    try publishAcceptedIceVolumeChanges(hydrology, snapshot.grid_matrix_ice, snapshot.grid_macro_ice, grid.matrix_ice_water_m3, grid.macropore_ice_water_m3);
    var phase_latent_heat_megajoules: f64 = 0;
    for (latent_heat_megajoules) |value| phase_latent_heat_megajoules += value;
    if (temporary_profile) |profile|
        profile.counters.final_validation_ns += temporary_profile_section_start
            .durationTo(std.Io.Clock.now(.boot, profile.io)).nanoseconds;
    return .{
        .water = water,
        .vapor = vapor,
        .phase = phase_result,
        .heat = heat_result,
        .phase_displacement_by_layer = inputs.phase_displacement_by_layer,
        .energy = if (diagnostics_enabled) .{
            .richards_enthalpy_change_megajoules = richards_energy_change.signed_megajoules,
            .vapor_transport_enthalpy_change_megajoules = vapor_energy_change.signed_megajoules,
            .phase_enthalpy_change_megajoules = phase_energy_change.signed_megajoules,
            .phase_absolute_enthalpy_change_megajoules = phase_energy_change.absolute_megajoules,
            .spatial_heat_enthalpy_change_megajoules = spatial_heat_energy_change.signed_megajoules,
            .phase_latent_heat_megajoules = phase_latent_heat_megajoules,
            .heat_solver_freeze_thaw_latent_megajoules = inputs.phase_properties.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3 * heat_solver_ice_change_m3,
            .external_water_advective_enthalpy_outward_megajoules = external_water_advective_enthalpy_outward_megajoules,
        } else null,
    };
}

fn fillCellEnthalpyMegajoules(
    result_megajoules: []f64,
    grid: *const grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_k: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
) !void {
    if (result_megajoules.len != grid.layer_count) return error.SoilEnergyDiagnosticDimensionMismatch;
    for (0..grid.layer_count) |cell| {
        result_megajoules[cell] = cellEnthalpyMegajoules(
            grid,
            cell,
            dry_solid_heat_capacity_megajoules_per_k[cell],
            liquid_water_heat_capacity_megajoules_per_m3_k,
            ice_heat_capacity_megajoules_per_m3_k,
            latent_heat_of_fusion_megajoules_per_m3,
            pure_water_melting_temperature_k,
        );
        if (!std.math.isFinite(result_megajoules[cell])) return error.NonFiniteSoilEnergyDiagnostic;
    }
}

const EnergyChange = struct { signed_megajoules: f64 = 0, absolute_megajoules: f64 = 0 };

/// Value one cell the way the landscape census values it: liquid and solid
/// carry sensible heat, frozen water carries the full
/// `frozenWaterEnthalpyPerM3` enthalpy including fusion.
///
/// This must stay term-for-term identical to
/// `landscape_mass_inventory.zig` (the `result.heat_megajoules +=` at the
/// soil layer census). A sensible-only version of this diagnostic values a
/// m3 of ice at `C_i*T` while the census values it at
/// `C_l*Tm - L + C_i*(T - Tm)`; the constant `(C_l - C_i)*Tm - L =
/// 285.029 MJ/m3` gap then appears as fake "unexplained energy"
/// proportional to ice change in every hour where ice moves, which is
/// exactly the hours a heat-balance investigation cares about. Measured at
/// 0.855943 * the freeze/thaw latent term before this was corrected.
fn cellEnthalpyMegajoules(
    grid: *const grid_module.GridState,
    cell: usize,
    dry_solid_heat_capacity_megajoules_per_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
) f64 {
    const temperature_k = grid.soil_temperature_k[cell];
    const frozen_water_equivalent_m3 =
        grid.matrix_ice_water_m3[cell] + grid.macropore_ice_water_m3[cell];
    const liquid_extensive_heat_capacity_megajoules_per_k =
        dry_solid_heat_capacity_megajoules_per_k +
        liquid_water_heat_capacity_megajoules_per_m3_k *
            (grid.matrix_liquid_water_m3[cell] +
                grid.macropore_liquid_water_m3[cell] +
                grid.water_vapor_volume_m3[cell]);
    const frozen_enthalpy_megajoules_per_m3 =
        liquid_water_heat_capacity_megajoules_per_m3_k *
        pure_water_melting_temperature_k -
        latent_heat_of_fusion_megajoules_per_m3 +
        ice_heat_capacity_megajoules_per_m3_k *
            (temperature_k - pure_water_melting_temperature_k);
    return liquid_extensive_heat_capacity_megajoules_per_k * temperature_k +
        frozen_enthalpy_megajoules_per_m3 * frozen_water_equivalent_m3;
}

/// `cellEnthalpyMegajoules` has thirteen rounded additions, subtractions, and
/// multiplications along its longest data path. Thirty-two operations is an
/// explicit conservative ceiling that also covers the expanded absolute-term
/// reconstruction below; unlike the former 4096 multiplier it is tied to this
/// producer's arithmetic graph.
const cell_enthalpy_roundoff_operation_count: usize = 32;

fn arithmeticForwardErrorBound(operation_count: usize, magnitude: f64) !f64 {
    if (!std.math.isFinite(magnitude) or magnitude < 0)
        return error.NonFiniteSoilEnergyDiagnostic;
    if (magnitude == 0 or operation_count == 0) return 0;
    const scaled_epsilon = @as(f64, @floatFromInt(operation_count)) *
        std.math.floatEps(f64);
    if (scaled_epsilon >= 1) return error.NonFiniteSoilEnergyDiagnostic;
    const allowance = scaled_epsilon / (1 - scaled_epsilon) * magnitude;
    if (!std.math.isFinite(allowance)) return error.NonFiniteSoilEnergyDiagnostic;
    return std.math.nextAfter(f64, allowance, std.math.inf(f64));
}

fn cellEnthalpyRoundoffAllowanceMegajoules(
    grid: *const grid_module.GridState,
    cell: usize,
    dry_solid_heat_capacity_megajoules_per_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
) !f64 {
    const temperature_k = grid.soil_temperature_k[cell];
    const liquid_water_m3 = grid.matrix_liquid_water_m3[cell] +
        grid.macropore_liquid_water_m3[cell] + grid.water_vapor_volume_m3[cell];
    const ice_water_equivalent_m3 = grid.matrix_ice_water_m3[cell] +
        grid.macropore_ice_water_m3[cell];
    const temperature_offset_k = temperature_k - pure_water_melting_temperature_k;
    // Expand the census into non-cancelling absolute physical terms. This
    // bounds cancellation in the frozen reference-state expression instead
    // of scaling only the already-cancelled result.
    const magnitude =
        @abs(dry_solid_heat_capacity_megajoules_per_k * temperature_k) +
        @abs(liquid_water_heat_capacity_megajoules_per_m3_k * liquid_water_m3 * temperature_k) +
        @abs(liquid_water_heat_capacity_megajoules_per_m3_k * pure_water_melting_temperature_k * ice_water_equivalent_m3) +
        @abs(latent_heat_of_fusion_megajoules_per_m3 * ice_water_equivalent_m3) +
        @abs(ice_heat_capacity_megajoules_per_m3_k * temperature_offset_k * ice_water_equivalent_m3);
    return arithmeticForwardErrorBound(cell_enthalpy_roundoff_operation_count, magnitude);
}

fn fillCellEnthalpyRoundoffAllowances(
    result_megajoules: []f64,
    grid: *const grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_k: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
) !void {
    if (result_megajoules.len != grid.layer_count or
        dry_solid_heat_capacity_megajoules_per_k.len != grid.layer_count)
        return error.SoilEnergyDiagnosticDimensionMismatch;
    for (result_megajoules, 0..) |*allowance, cell|
        allowance.* = try cellEnthalpyRoundoffAllowanceMegajoules(
            grid,
            cell,
            dry_solid_heat_capacity_megajoules_per_k[cell],
            liquid_water_heat_capacity_megajoules_per_m3_k,
            ice_heat_capacity_megajoules_per_m3_k,
            latent_heat_of_fusion_megajoules_per_m3,
            pure_water_melting_temperature_k,
        );
}

fn refreshExtensiveHeatCapacity(
    result_megajoules_per_k: []f64,
    grid: *const grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_k: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
) !void {
    if (result_megajoules_per_k.len != grid.layer_count or
        dry_solid_heat_capacity_megajoules_per_k.len != grid.layer_count)
        return error.SoilEnergyDiagnosticDimensionMismatch;
    for (result_megajoules_per_k, 0..) |*capacity, layer| {
        capacity.* = dry_solid_heat_capacity_megajoules_per_k[layer] +
            liquid_water_heat_capacity_megajoules_per_m3_k *
                (grid.matrix_liquid_water_m3[layer] +
                    grid.macropore_liquid_water_m3[layer] +
                    grid.water_vapor_volume_m3[layer]) +
            ice_heat_capacity_megajoules_per_m3_k *
                (grid.matrix_ice_water_m3[layer] +
                    grid.macropore_ice_water_m3[layer]);
        if (!std.math.isFinite(capacity.*) or capacity.* <= 0)
            return error.InvalidRefreshedSoilHeatCapacity;
    }
}

fn temperatureForCellEnthalpy(
    target_megajoules: f64,
    grid: *const grid_module.GridState,
    layer: usize,
    dry_solid_heat_capacity_megajoules_per_k: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    /// This cell's plan area, MJ K-1 m-2 floor scaling per
    /// `heat_flux.minimum_layer_heat_capacity_megajoules_per_m2_k` (the same
    /// `STARTS 655`/`VHCPRX` floor `validatePerLayerSpatialHeatClosure` and
    /// `solver_residual.zig`'s `residualAtImpl` already use). Zero disables
    /// the floor guard, matching every other diagnostics-disabled caller in
    /// this file that passes an empty `cell_area_m2`.
    cell_area_m2: f64,
    /// issue-068 (fourth round, 2026-09-20). Empty disables booking. See
    /// `Inputs.renormalization_floor_discard_megajoules_by_layer`.
    renormalization_floor_discard_megajoules_by_layer: []f64,
) !f64 {
    const frozen_water_equivalent_m3 =
        grid.matrix_ice_water_m3[layer] + grid.macropore_ice_water_m3[layer];
    const temperature_coefficient = dry_solid_heat_capacity_megajoules_per_k +
        liquid_water_heat_capacity_megajoules_per_m3_k *
            (grid.matrix_liquid_water_m3[layer] +
                grid.macropore_liquid_water_m3[layer] +
                grid.water_vapor_volume_m3[layer]) +
        ice_heat_capacity_megajoules_per_m3_k * frozen_water_equivalent_m3;
    const fusion_offset_megajoules = frozen_water_equivalent_m3 *
        (liquid_water_heat_capacity_megajoules_per_m3_k * pure_water_melting_temperature_k -
            latent_heat_of_fusion_megajoules_per_m3 -
            ice_heat_capacity_megajoules_per_m3_k * pure_water_melting_temperature_k);
    // issue-068 (fourth round, 2026-09-20): WATSUB 6907--6913 / `redist.f:
    // 9655-9659`'s `TK1 = TKS` fallback, and this codebase's own
    // `solver_residual.zig` `residualAtImpl` (`target[cell] = base[cell]`
    // when `heat_capacity <= minimum_heat_capacity`), already hold a
    // chronically near-zero-heat-capacity layer's PRIOR temperature rather
    // than dividing an energy mismatch by that near-zero capacity. Mirror
    // that already-approved rule here, at the identical floor
    // `validatePerLayerSpatialHeatClosure` uses
    // (`heat_flux.minimum_layer_heat_capacity_megajoules_per_m2_k *
    // cell_area`), instead of committing the physically absurd temperature
    // this inversion previously produced for hour 2,895/cell 0/layer 0
    // (401.75/452.64/455.14 K). Book the resulting energy discrepancy -- what
    // this cell's storage should have gained (or lost) had the inversion
    // gone through, but did not because the temperature was held -- into the
    // dedicated ledger below so `validatePerLayerSpatialHeatClosure` can net
    // it out of `expected_gain_megajoules` instead of reading a false
    // violation whenever this layer's capacity later recovers above the
    // floor within the same hour.
    const negligible_capacity_limit_megajoules_per_k =
        heat_flux.minimum_layer_heat_capacity_megajoules_per_m2_k * cell_area_m2;
    if (cell_area_m2 > 0 and temperature_coefficient <= negligible_capacity_limit_megajoules_per_k) {
        const held_temperature_k = grid.soil_temperature_k[layer];
        if (renormalization_floor_discard_megajoules_by_layer.len != 0) {
            const held_actual_megajoules =
                temperature_coefficient * held_temperature_k + fusion_offset_megajoules;
            const discard_megajoules = try checkedAddFinite(target_megajoules, -held_actual_megajoules);
            renormalization_floor_discard_megajoules_by_layer[layer] = try checkedAddFinite(
                renormalization_floor_discard_megajoules_by_layer[layer],
                discard_megajoules,
            );
        }
        return held_temperature_k;
    }
    if (!(temperature_coefficient > 0)) return error.InvalidSoilHeatCapacity;
    const temperature_k =
        (target_megajoules - fusion_offset_megajoules) /
        temperature_coefficient;
    if (!std.math.isFinite(temperature_k) or temperature_k <= 0)
        return error.InvalidRenormalizedSoilTemperature;
    // issue-068 (2026-09-20, second round): this inversion writes directly
    // into `grid.soil_temperature_k` (both callers below), bypassing every
    // domain guard the dense multi-layer Newton/Anderson solver enforces on
    // its OWN commit path (`solver_solve.zig`'s `commitAcceptedState`/
    // `allTemperaturesPhysicallyValid`). For an ordinary layer `isFinite and
    // > 0` already implies a temperature far inside [173.15, 373.15] K.
    // Above the floor guarded immediately above, this guard remains in place
    // as a belt-and-suspenders check for any other, still-unidentified route
    // to an absurd value. Reusing the same `isPhysicalTemperatureK` primitive
    // every sibling scalar/dense solver already enforces (never a new or
    // widened bound) and a distinct, explicitly retryable error name lets the
    // existing, already-tested fixed-hour substep recovery ladder
    // (`isFixedHourDtRecoveryFailure`) refine `dt` instead of committing this
    // candidate.
    if (!heat_solver.isPhysicalTemperatureK(temperature_k))
        return error.SoilHeatRenormalizedTemperatureOutsidePhysicalDomain;
    return temperature_k;
}

/// Restore each layer to its own pre-transport canonical enthalpy after a
/// mass-only internal transport. The accepted face heat remains separate and
/// is applied once, donor-upwind, by the spatial heat solve.
fn renormalizeTemperatureToFixedCellEnthalpy(
    before_megajoules_by_cell: []const f64,
    grid: *grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_k: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    cell_area_m2: []const f64,
    renormalization_floor_discard_megajoules_by_layer: []f64,
) !void {
    if (before_megajoules_by_cell.len != grid.layer_count or
        dry_solid_heat_capacity_megajoules_per_k.len != grid.layer_count)
        return error.SoilEnergyDiagnosticDimensionMismatch;
    if (cell_area_m2.len != 0 and cell_area_m2.len != grid.cell_count)
        return error.HeatConservationCellDimensionMismatch;
    if (renormalization_floor_discard_megajoules_by_layer.len != 0 and
        renormalization_floor_discard_megajoules_by_layer.len != grid.layer_count)
        return error.SoilRenormalizationFloorDiscardDimensionMismatch;
    for (0..grid.cell_count) |cell| for (0..grid.active_soil_layer_count[cell]) |layer_offset| {
        const layer = try grid.layerIndex(cell, layer_offset);
        grid.soil_temperature_k[layer] = try temperatureForCellEnthalpy(
            before_megajoules_by_cell[layer],
            grid,
            layer,
            dry_solid_heat_capacity_megajoules_per_k[layer],
            liquid_water_heat_capacity_megajoules_per_m3_k,
            ice_heat_capacity_megajoules_per_m3_k,
            latent_heat_of_fusion_megajoules_per_m3,
            pure_water_melting_temperature_k,
            if (cell_area_m2.len == 0) 0 else cell_area_m2[cell],
            renormalization_floor_discard_megajoules_by_layer,
        );
    };
}

/// Inverts `cellEnthalpyMegajoules` for temperature after a stage moved water
/// volume without moving heat.
///
/// `before_megajoules_by_cell` is the enthalpy each cell held before the move.
/// External departures are debited at the cell's PRE-move temperature, which
/// is the temperature the water actually carried away.
fn renormalizeTemperatureToConservedEnthalpy(
    before_megajoules_by_cell: []const f64,
    grid: *grid_module.GridState,
    hydrology: *const hydrology_module.State,
    dry_solid_heat_capacity_megajoules_per_k: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
    cell_area_m2: []const f64,
    renormalization_floor_discard_megajoules_by_layer: []f64,
) !void {
    if (before_megajoules_by_cell.len != grid.layer_count) return error.SoilEnergyDiagnosticDimensionMismatch;
    if (cell_area_m2.len != 0 and cell_area_m2.len != grid.cell_count)
        return error.HeatConservationCellDimensionMismatch;
    if (renormalization_floor_discard_megajoules_by_layer.len != 0 and
        renormalization_floor_discard_megajoules_by_layer.len != grid.layer_count)
        return error.SoilRenormalizationFloorDiscardDimensionMismatch;
    for (0..grid.cell_count) |cell| for (0..grid.active_soil_layer_count[cell]) |layer| {
        const index = try grid.layerIndex(cell, layer);
        const departed_m3 =
            hydrology.micropore_external_water_flux_m3_per_step[index] +
            hydrology.macropore_external_water_flux_m3_per_step[index];
        // Positive `departed_m3` leaves the domain and takes this cell's
        // enthalpy with it. Negative recharges the domain; the incoming water
        // is booked by the same external ledger term and is therefore treated
        // as arriving at this cell's temperature, exactly as the outward case
        // is treated in reverse.
        const target_megajoules = before_megajoules_by_cell[index] -
            departed_m3 * liquid_water_heat_capacity_megajoules_per_m3_k *
                grid.soil_temperature_k[index];
        grid.soil_temperature_k[index] = try temperatureForCellEnthalpy(
            target_megajoules,
            grid,
            index,
            dry_solid_heat_capacity_megajoules_per_k[index],
            liquid_water_heat_capacity_megajoules_per_m3_k,
            ice_heat_capacity_megajoules_per_m3_k,
            latent_heat_of_fusion_megajoules_per_m3,
            pure_water_melting_temperature_k,
            if (cell_area_m2.len == 0) 0 else cell_area_m2[cell],
            renormalization_floor_discard_megajoules_by_layer,
        );
    };
}

fn enthalpyChangeFromSnapshot(
    before_megajoules_by_cell: []const f64,
    grid: *const grid_module.GridState,
    dry_solid_heat_capacity_megajoules_per_k: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_melting_temperature_k: f64,
) !EnergyChange {
    var result: EnergyChange = .{};
    for (0..grid.layer_count) |cell| {
        const change_megajoules = cellEnthalpyMegajoules(
            grid,
            cell,
            dry_solid_heat_capacity_megajoules_per_k[cell],
            liquid_water_heat_capacity_megajoules_per_m3_k,
            ice_heat_capacity_megajoules_per_m3_k,
            latent_heat_of_fusion_megajoules_per_m3,
            pure_water_melting_temperature_k,
        ) - before_megajoules_by_cell[cell];
        result.signed_megajoules += change_megajoules;
        result.absolute_megajoules += @abs(change_megajoules);
    }
    if (!std.math.isFinite(result.signed_megajoules) or !std.math.isFinite(result.absolute_megajoules)) return error.NonFiniteSoilEnergyDiagnostic;
    return result;
}

fn publishAcceptedIceVolumeChanges(hydrology: *hydrology_module.State, initial_matrix_m3: []const f64, initial_macropore_m3: []const f64, final_matrix_m3: []const f64, final_macropore_m3: []const f64) !void {
    const count = hydrology.matrix_ice_volume_change_m3_per_step.len;
    if (initial_matrix_m3.len != count or initial_macropore_m3.len != count or final_matrix_m3.len != count or final_macropore_m3.len != count or hydrology.macropore_ice_volume_change_m3_per_step.len != count or hydrology.total_ice_volume_change_m3_per_step.len != count) return error.AcceptedIceVolumeChangeDimensionMismatch;
    for (0..count) |layer| {
        const matrix_change_m3 = final_matrix_m3[layer] - initial_matrix_m3[layer];
        const macropore_change_m3 = final_macropore_m3[layer] - initial_macropore_m3[layer];
        const total_change_m3 = matrix_change_m3 + macropore_change_m3;
        if (!std.math.isFinite(matrix_change_m3) or !std.math.isFinite(macropore_change_m3) or !std.math.isFinite(total_change_m3)) return error.NonFiniteAcceptedIceVolumeChange;
    }
    for (0..count) |layer| {
        hydrology.matrix_ice_volume_change_m3_per_step[layer] = final_matrix_m3[layer] - initial_matrix_m3[layer];
        hydrology.macropore_ice_volume_change_m3_per_step[layer] = final_macropore_m3[layer] - initial_macropore_m3[layer];
        hydrology.total_ice_volume_change_m3_per_step[layer] = hydrology.matrix_ice_volume_change_m3_per_step[layer] + hydrology.macropore_ice_volume_change_m3_per_step[layer];
    }
}

const TopologySnapshot = struct {
    allocator: std.mem.Allocator,
    internal_water_table_depth_m: []f64,
    active_layer_depth_m: []f64,

    fn capture(allocator: std.mem.Allocator, topology: *const boundary_topology_module.State) !TopologySnapshot {
        const internal = try allocator.dupe(f64, topology.internal_water_table_depth_m);
        errdefer allocator.free(internal);
        return .{
            .allocator = allocator,
            .internal_water_table_depth_m = internal,
            .active_layer_depth_m = try allocator.dupe(f64, topology.active_layer_depth_m),
        };
    }

    fn restore(self: TopologySnapshot, topology: *boundary_topology_module.State) void {
        @memcpy(topology.internal_water_table_depth_m, self.internal_water_table_depth_m);
        @memcpy(topology.active_layer_depth_m, self.active_layer_depth_m);
    }

    fn deinit(self: *TopologySnapshot) void {
        self.allocator.free(self.active_layer_depth_m);
        self.allocator.free(self.internal_water_table_depth_m);
        self.* = undefined;
    }
};

const CoefficientSnapshot = struct {
    allocator: std.mem.Allocator,
    workspace: workspace_module.State,
    thermal: thermal_module.State,

    fn capture(allocator: std.mem.Allocator, workspace: *const workspace_module.State, thermal: *const thermal_module.State) !CoefficientSnapshot {
        var workspace_clone = try cloneState(
            workspace_module.State,
            allocator,
            workspace,
            &workspace_state_slice_descriptors,
        );
        errdefer freeStateSlices(
            workspace_module.State,
            allocator,
            &workspace_clone,
            &workspace_state_slice_descriptors,
        );
        return .{
            .allocator = allocator,
            .workspace = workspace_clone,
            .thermal = try cloneState(
                thermal_module.State,
                allocator,
                thermal,
                &thermal_state_slice_descriptors,
            ),
        };
    }

    fn restore(self: *const CoefficientSnapshot, workspace: *workspace_module.State, thermal: *thermal_module.State) void {
        restoreState(workspace_module.State, workspace, &self.workspace);
        restoreState(thermal_module.State, thermal, &self.thermal);
    }

    fn deinit(self: *CoefficientSnapshot) void {
        freeStateSlices(
            thermal_module.State,
            self.allocator,
            &self.thermal,
            &thermal_state_slice_descriptors,
        );
        freeStateSlices(
            workspace_module.State,
            self.allocator,
            &self.workspace,
            &workspace_state_slice_descriptors,
        );
        self.* = undefined;
    }
};

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice,
        else => false,
    };
}

const StateSliceKind = enum {
    f64,
    bool,
    mualem_van_genuchten,
};

const StateSliceDescriptor = struct {
    offset: usize,
    kind: StateSliceKind,
};

fn stateSliceKind(comptime Slice: type) StateSliceKind {
    if (Slice == []f64) return .f64;
    if (Slice == []bool) return .bool;
    if (Slice == []retention_module.MualemVanGenuchtenParameters)
        return .mualem_van_genuchten;
    @compileError("unsupported coefficient snapshot slice type: " ++ @typeName(Slice));
}

fn stateSliceCount(comptime T: type) usize {
    var count: usize = 0;
    for (@typeInfo(T).@"struct".fields) |field| {
        if (isSlice(field.type)) count += 1;
    }
    return count;
}

fn stateSliceDescriptors(comptime T: type) [stateSliceCount(T)]StateSliceDescriptor {
    var descriptors: [stateSliceCount(T)]StateSliceDescriptor = undefined;
    var index: usize = 0;
    for (@typeInfo(T).@"struct".fields) |field| {
        if (!isSlice(field.type)) continue;
        descriptors[index] = .{
            .offset = @offsetOf(T, field.name),
            .kind = stateSliceKind(field.type),
        };
        index += 1;
    }
    return descriptors;
}

const workspace_state_slice_descriptors = stateSliceDescriptors(workspace_module.State);
const thermal_state_slice_descriptors = stateSliceDescriptors(thermal_module.State);

fn stateFieldPointer(
    comptime Slice: type,
    state: *anyopaque,
    offset: usize,
) *Slice {
    return @ptrFromInt(@intFromPtr(state) + offset);
}

fn stateFieldConstPointer(
    comptime Slice: type,
    state: *const anyopaque,
    offset: usize,
) *const Slice {
    return @ptrFromInt(@intFromPtr(state) + offset);
}

noinline fn freeAllocatedStateSlices(
    allocator: std.mem.Allocator,
    state: *anyopaque,
    descriptors: []const StateSliceDescriptor,
    allocated: usize,
) void {
    for (descriptors[0..allocated]) |descriptor| switch (descriptor.kind) {
        .f64 => allocator.free(stateFieldPointer([]f64, state, descriptor.offset).*),
        .bool => allocator.free(stateFieldPointer([]bool, state, descriptor.offset).*),
        .mualem_van_genuchten => allocator.free(stateFieldPointer(
            []retention_module.MualemVanGenuchtenParameters,
            state,
            descriptor.offset,
        ).*),
    };
}

noinline fn cloneStateSlices(
    allocator: std.mem.Allocator,
    destination: *anyopaque,
    source: *const anyopaque,
    descriptors: []const StateSliceDescriptor,
) !void {
    var allocated: usize = 0;
    errdefer freeAllocatedStateSlices(allocator, destination, descriptors, allocated);
    for (descriptors) |descriptor| {
        switch (descriptor.kind) {
            .f64 => stateFieldPointer([]f64, destination, descriptor.offset).* =
                try allocator.dupe(
                    f64,
                    stateFieldConstPointer([]f64, source, descriptor.offset).*,
                ),
            .bool => stateFieldPointer([]bool, destination, descriptor.offset).* =
                try allocator.dupe(
                    bool,
                    stateFieldConstPointer([]bool, source, descriptor.offset).*,
                ),
            .mualem_van_genuchten => stateFieldPointer(
                []retention_module.MualemVanGenuchtenParameters,
                destination,
                descriptor.offset,
            ).* = try allocator.dupe(
                retention_module.MualemVanGenuchtenParameters,
                stateFieldConstPointer(
                    []retention_module.MualemVanGenuchtenParameters,
                    source,
                    descriptor.offset,
                ).*,
            ),
        }
        allocated += 1;
    }
}

noinline fn cloneState(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: *const T,
    descriptors: []const StateSliceDescriptor,
) !T {
    var result = source.*;
    try cloneStateSlices(allocator, @ptrCast(&result), @ptrCast(source), descriptors);
    return result;
}

fn restoreState(comptime T: type, destination: *T, source: *const T) void {
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isSlice(field.type))
            @memcpy(@field(destination, field.name), @field(source, field.name))
        else
            @field(destination, field.name) = @field(source, field.name);
    }
}

fn freeStateSlices(
    comptime T: type,
    allocator: std.mem.Allocator,
    state: *T,
    descriptors: []const StateSliceDescriptor,
) void {
    freeAllocatedStateSlices(allocator, @ptrCast(state), descriptors, descriptors.len);
}

const thermal_clone_test_layer_count: usize = 3;
const thermal_clone_test_slice_count = stateSliceCount(thermal_module.State);

fn thermalCloneTestState(
    backing: *[thermal_clone_test_slice_count][thermal_clone_test_layer_count]f64,
) thermal_module.State {
    var state: thermal_module.State = undefined;
    state.allocator = std.testing.allocator;
    state.cell_count = 1;
    state.soil_layer_capacity = thermal_clone_test_layer_count;
    var field_index: usize = 0;
    inline for (@typeInfo(thermal_module.State).@"struct".fields) |field| {
        if (comptime field.type != []f64) continue;
        @field(state, field.name) = backing[field_index][0..];
        field_index += 1;
    }
    return state;
}

fn fillCoefficientCloneTestSources(
    workspace: *workspace_module.State,
    thermal_backing: *[thermal_clone_test_slice_count][thermal_clone_test_layer_count]f64,
) void {
    var field_index: usize = 0;
    inline for (@typeInfo(workspace_module.State).@"struct".fields) |field| {
        if (comptime !isSlice(field.type)) continue;
        if (comptime field.type == []f64) {
            for (@field(workspace, field.name), 0..) |*value, element|
                value.* = @as(f64, @floatFromInt(field_index * 100 + element)) + 0.125;
        } else if (comptime field.type == []bool) {
            for (@field(workspace, field.name), 0..) |*value, element|
                value.* = (field_index + element) % 2 == 0;
        } else if (comptime field.type == []retention_module.MualemVanGenuchtenParameters) {
            for (@field(workspace, field.name), 0..) |*value, element| value.* = .{
                .residual_water_content_m3_per_m3 = 0.01 * @as(f64, @floatFromInt(element)),
                .saturated_water_content_m3_per_m3 = 0.8,
                .alpha_per_m = @as(f64, @floatFromInt(field_index + element + 1)),
                .n = 1.5 + 0.1 * @as(f64, @floatFromInt(element)),
                .pore_connectivity = 0.5,
                .saturated_hydraulic_conductivity_m_per_h = 0.001 * @as(f64, @floatFromInt(element + 1)),
            };
        }
        field_index += 1;
    }
    for (thermal_backing, 0..) |*field_values, thermal_field| {
        for (field_values, 0..) |*value, element|
            value.* = @as(f64, @floatFromInt(thermal_field * 100 + element)) + 0.25;
    }
}

fn captureCoefficientSnapshotForAllocationFailure(allocator: std.mem.Allocator) !void {
    var workspace = try workspace_module.State.init(std.testing.allocator, thermal_clone_test_layer_count);
    defer workspace.deinit();
    var thermal_backing: [thermal_clone_test_slice_count][thermal_clone_test_layer_count]f64 = undefined;
    fillCoefficientCloneTestSources(&workspace, &thermal_backing);
    const thermal = thermalCloneTestState(&thermal_backing);
    var snapshot = try CoefficientSnapshot.capture(allocator, &workspace, &thermal);
    defer snapshot.deinit();
}

test "coefficient snapshot releases every partial runtime clone allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        captureCoefficientSnapshotForAllocationFailure,
        .{},
    );
}

test "coefficient snapshot runtime table clones every field without aliasing neighbors" {
    var workspace = try workspace_module.State.init(std.testing.allocator, thermal_clone_test_layer_count);
    defer workspace.deinit();
    var thermal_backing: [thermal_clone_test_slice_count][thermal_clone_test_layer_count]f64 = undefined;
    fillCoefficientCloneTestSources(&workspace, &thermal_backing);
    const thermal = thermalCloneTestState(&thermal_backing);
    var snapshot = try CoefficientSnapshot.capture(std.testing.allocator, &workspace, &thermal);
    defer snapshot.deinit();

    try std.testing.expectEqual(workspace.allocator, snapshot.workspace.allocator);
    try std.testing.expectEqual(workspace.layer_count, snapshot.workspace.layer_count);
    try std.testing.expectEqual(thermal.cell_count, snapshot.thermal.cell_count);
    try std.testing.expectEqual(thermal.soil_layer_capacity, snapshot.thermal.soil_layer_capacity);

    var workspace_field_index: usize = 0;
    inline for (@typeInfo(workspace_module.State).@"struct".fields) |field| {
        if (comptime !isSlice(field.type)) continue;
        const source = @field(workspace, field.name);
        const cloned = @field(snapshot.workspace, field.name);
        try std.testing.expectEqual(source.len, cloned.len);
        if (source.len != 0) try std.testing.expect(source.ptr != cloned.ptr);
        if (comptime field.type == []f64) {
            try std.testing.expectEqualSlices(f64, source, cloned);
            for (source, 0..) |*value, element| {
                value.* = -1;
                try std.testing.expectEqual(
                    @as(f64, @floatFromInt(workspace_field_index * 100 + element)) + 0.125,
                    cloned[element],
                );
            }
        } else if (comptime field.type == []bool) {
            try std.testing.expectEqualSlices(bool, source, cloned);
            for (source, 0..) |*value, element| {
                value.* = !value.*;
                try std.testing.expectEqual(
                    (workspace_field_index + element) % 2 == 0,
                    cloned[element],
                );
            }
        } else if (comptime field.type == []retention_module.MualemVanGenuchtenParameters) {
            try std.testing.expectEqualDeep(source, cloned);
            for (source, 0..) |*value, element| {
                value.*.alpha_per_m = -1;
                try std.testing.expectEqual(
                    @as(f64, @floatFromInt(workspace_field_index + element + 1)),
                    cloned[element].alpha_per_m,
                );
            }
        }
        workspace_field_index += 1;
    }

    var thermal_field_index: usize = 0;
    inline for (@typeInfo(thermal_module.State).@"struct".fields) |field| {
        if (comptime field.type != []f64) continue;
        const source = @field(thermal, field.name);
        const cloned = @field(snapshot.thermal, field.name);
        try std.testing.expectEqual(source.len, cloned.len);
        try std.testing.expect(source.ptr != cloned.ptr);
        try std.testing.expectEqualSlices(f64, source, cloned);
        for (source, 0..) |*value, element| {
            value.* = -1;
            try std.testing.expectEqual(
                @as(f64, @floatFromInt(thermal_field_index * 100 + element)) + 0.25,
                cloned[element],
            );
        }
        thermal_field_index += 1;
    }
}

const Snapshot = struct {
    allocator: std.mem.Allocator,
    grid_matrix_water: []f64,
    grid_macro_water: []f64,
    grid_total_water: []f64,
    grid_matrix_air: []f64,
    grid_macro_air: []f64,
    grid_total_air: []f64,
    grid_vapor: []f64,
    grid_matrix_ice: []f64,
    grid_macro_ice: []f64,
    grid_total_ice: []f64,
    grid_temperature: []f64,
    grid_matric_potential: []f64,
    hydrology_matrix_water: []f64,
    hydrology_macro_water: []f64,
    hydrology_matrix_air: []f64,
    hydrology_macro_air: []f64,
    hydrology_total_air: []f64,
    hydrology_vapor: []f64,
    hydrology_matrix_flux: []f64,
    hydrology_macro_flux: []f64,
    hydrology_vapor_flux: []f64,
    hydrology_heat_flux: []f64,
    hydrology_matrix_external_flux: []f64,
    hydrology_macro_external_flux: []f64,
    hydrology_pore_exchange_flux: []f64,
    hydrology_artificial_drainage: []f64,
    hydrology_boundary_exchange: []f64,
    hydrology_boundary_exchange_by_layer: []f64,
    hydrology_boundary_heat_by_layer: []f64,
    hydrology_matrix_ice_change: []f64,
    hydrology_macro_ice_change: []f64,
    hydrology_total_ice_change: []f64,
    face_matrix_flux: []f64,
    face_macro_flux: []f64,
    face_vapor_flux: []f64,
    face_heat_flux: []f64,
    micropore_faces: []solute.Face,
    macropore_faces: []solute.Face,

    noinline fn capture(allocator: std.mem.Allocator, grid: *const grid_module.GridState, hydrology: *const hydrology_module.State, faces: *const hydrology_module.SoilFaces) !Snapshot {
        var result: Snapshot = undefined;
        result.allocator = allocator;
        var allocated: usize = 0;
        errdefer result.freeAllocated(allocated);
        inline for (@typeInfo(Snapshot).@"struct".fields) |field| {
            if (field.type == []f64) {
                const source: []const f64 = snapshotF64Source(field.name, grid, hydrology, faces);
                @field(result, field.name) = try allocator.dupe(f64, source);
                allocated += 1;
            } else if (field.type == []solute.Face) {
                const source: []const solute.Face = if (comptime std.mem.eql(u8, field.name, "micropore_faces")) faces.micropore_faces else faces.macropore_faces;
                @field(result, field.name) = try allocator.dupe(solute.Face, source);
                allocated += 1;
            }
        }
        return result;
    }

    noinline fn restore(self: *const Snapshot, grid: *grid_module.GridState, hydrology: *hydrology_module.State, faces: *hydrology_module.SoilFaces) void {
        @memcpy(grid.matrix_liquid_water_m3, self.grid_matrix_water);
        @memcpy(grid.macropore_liquid_water_m3, self.grid_macro_water);
        @memcpy(grid.liquid_water_m3, self.grid_total_water);
        @memcpy(grid.matrix_air_volume_m3, self.grid_matrix_air);
        @memcpy(grid.macropore_air_volume_m3, self.grid_macro_air);
        @memcpy(grid.air_volume_m3, self.grid_total_air);
        @memcpy(grid.water_vapor_volume_m3, self.grid_vapor);
        @memcpy(grid.matrix_ice_water_m3, self.grid_matrix_ice);
        @memcpy(grid.macropore_ice_water_m3, self.grid_macro_ice);
        @memcpy(grid.ice_water_m3, self.grid_total_ice);
        @memcpy(grid.soil_temperature_k, self.grid_temperature);
        @memcpy(grid.matric_potential_megapascal, self.grid_matric_potential);
        @memcpy(hydrology.micropore_water_volume_m3, self.hydrology_matrix_water);
        @memcpy(hydrology.macropore_water_volume_m3, self.hydrology_macro_water);
        @memcpy(hydrology.matrix_air_volume_m3, self.hydrology_matrix_air);
        @memcpy(hydrology.macropore_air_volume_m3, self.hydrology_macro_air);
        @memcpy(hydrology.air_volume_m3, self.hydrology_total_air);
        @memcpy(hydrology.water_vapor_volume_m3, self.hydrology_vapor);
        @memcpy(hydrology.micropore_face_flux_m3_per_step, self.hydrology_matrix_flux);
        @memcpy(hydrology.macropore_face_flux_m3_per_step, self.hydrology_macro_flux);
        @memcpy(hydrology.vapor_face_flux_m3_per_step, self.hydrology_vapor_flux);
        @memcpy(hydrology.heat_face_flux_megajoules_per_step, self.hydrology_heat_flux);
        @memcpy(hydrology.micropore_external_water_flux_m3_per_step, self.hydrology_matrix_external_flux);
        @memcpy(hydrology.macropore_external_water_flux_m3_per_step, self.hydrology_macro_external_flux);
        @memcpy(hydrology.macropore_to_matrix_water_flux_m3_per_step, self.hydrology_pore_exchange_flux);
        @memcpy(hydrology.artificial_drainage_outflow_m3_per_step, self.hydrology_artificial_drainage);
        @memcpy(hydrology.boundary_water_exchange_m3_per_step, self.hydrology_boundary_exchange);
        @memcpy(hydrology.boundary_water_exchange_m3_per_layer_per_step, self.hydrology_boundary_exchange_by_layer);
        @memcpy(hydrology.boundary_heat_exchange_megajoules_per_layer_per_step, self.hydrology_boundary_heat_by_layer);
        @memcpy(hydrology.matrix_ice_volume_change_m3_per_step, self.hydrology_matrix_ice_change);
        @memcpy(hydrology.macropore_ice_volume_change_m3_per_step, self.hydrology_macro_ice_change);
        @memcpy(hydrology.total_ice_volume_change_m3_per_step, self.hydrology_total_ice_change);
        @memcpy(faces.micropore_water_flux_m3_per_step, self.face_matrix_flux);
        @memcpy(faces.macropore_water_flux_m3_per_step, self.face_macro_flux);
        @memcpy(faces.vapor_flux_m3_per_step, self.face_vapor_flux);
        @memcpy(faces.heat_flux_megajoules_per_step, self.face_heat_flux);
        @memcpy(faces.micropore_faces, self.micropore_faces);
        @memcpy(faces.macropore_faces, self.macropore_faces);
    }

    fn publishLedgers(
        self: *const Snapshot,
        hydrology: *hydrology_module.State,
        faces: *hydrology_module.SoilFaces,
    ) void {
        @memcpy(hydrology.micropore_face_flux_m3_per_step, self.hydrology_matrix_flux);
        @memcpy(hydrology.macropore_face_flux_m3_per_step, self.hydrology_macro_flux);
        @memcpy(hydrology.vapor_face_flux_m3_per_step, self.hydrology_vapor_flux);
        @memcpy(hydrology.heat_face_flux_megajoules_per_step, self.hydrology_heat_flux);
        @memcpy(hydrology.micropore_external_water_flux_m3_per_step, self.hydrology_matrix_external_flux);
        @memcpy(hydrology.macropore_external_water_flux_m3_per_step, self.hydrology_macro_external_flux);
        @memcpy(hydrology.macropore_to_matrix_water_flux_m3_per_step, self.hydrology_pore_exchange_flux);
        @memcpy(hydrology.artificial_drainage_outflow_m3_per_step, self.hydrology_artificial_drainage);
        @memcpy(hydrology.boundary_water_exchange_m3_per_step, self.hydrology_boundary_exchange);
        @memcpy(hydrology.boundary_water_exchange_m3_per_layer_per_step, self.hydrology_boundary_exchange_by_layer);
        @memcpy(hydrology.boundary_heat_exchange_megajoules_per_layer_per_step, self.hydrology_boundary_heat_by_layer);
        @memcpy(hydrology.matrix_ice_volume_change_m3_per_step, self.hydrology_matrix_ice_change);
        @memcpy(hydrology.macropore_ice_volume_change_m3_per_step, self.hydrology_macro_ice_change);
        @memcpy(hydrology.total_ice_volume_change_m3_per_step, self.hydrology_total_ice_change);
        @memcpy(faces.micropore_water_flux_m3_per_step, self.face_matrix_flux);
        @memcpy(faces.macropore_water_flux_m3_per_step, self.face_macro_flux);
        @memcpy(faces.vapor_flux_m3_per_step, self.face_vapor_flux);
        @memcpy(faces.heat_flux_megajoules_per_step, self.face_heat_flux);
        @memcpy(faces.micropore_faces, self.micropore_faces);
        @memcpy(faces.macropore_faces, self.macropore_faces);
    }

    fn zeroLedgers(self: *Snapshot) void {
        @memset(self.hydrology_matrix_flux, 0);
        @memset(self.hydrology_macro_flux, 0);
        @memset(self.hydrology_vapor_flux, 0);
        @memset(self.hydrology_heat_flux, 0);
        @memset(self.hydrology_matrix_external_flux, 0);
        @memset(self.hydrology_macro_external_flux, 0);
        @memset(self.hydrology_pore_exchange_flux, 0);
        @memset(self.hydrology_artificial_drainage, 0);
        @memset(self.hydrology_boundary_exchange, 0);
        @memset(self.hydrology_boundary_exchange_by_layer, 0);
        @memset(self.hydrology_boundary_heat_by_layer, 0);
        @memset(self.hydrology_matrix_ice_change, 0);
        @memset(self.hydrology_macro_ice_change, 0);
        @memset(self.hydrology_total_ice_change, 0);
        @memset(self.face_matrix_flux, 0);
        @memset(self.face_macro_flux, 0);
        @memset(self.face_vapor_flux, 0);
        @memset(self.face_heat_flux, 0);
        for (self.micropore_faces) |*face| face.water_flux_m3_per_step = 0;
        for (self.macropore_faces) |*face| face.water_flux_m3_per_step = 0;
    }

    fn accumulateLedgers(self: *Snapshot, hydrology: *const hydrology_module.State, faces: *const hydrology_module.SoilFaces) !void {
        try addSlices(self.hydrology_matrix_flux, hydrology.micropore_face_flux_m3_per_step);
        try addSlices(self.hydrology_macro_flux, hydrology.macropore_face_flux_m3_per_step);
        try addSlices(self.hydrology_vapor_flux, hydrology.vapor_face_flux_m3_per_step);
        try addSlices(self.hydrology_heat_flux, hydrology.heat_face_flux_megajoules_per_step);
        try addSlices(self.hydrology_matrix_external_flux, hydrology.micropore_external_water_flux_m3_per_step);
        try addSlices(self.hydrology_macro_external_flux, hydrology.macropore_external_water_flux_m3_per_step);
        try addSlices(self.hydrology_pore_exchange_flux, hydrology.macropore_to_matrix_water_flux_m3_per_step);
        try addSlices(self.hydrology_artificial_drainage, hydrology.artificial_drainage_outflow_m3_per_step);
        try addSlices(self.hydrology_boundary_exchange, hydrology.boundary_water_exchange_m3_per_step);
        try addSlices(self.hydrology_boundary_exchange_by_layer, hydrology.boundary_water_exchange_m3_per_layer_per_step);
        try addSlices(self.hydrology_boundary_heat_by_layer, hydrology.boundary_heat_exchange_megajoules_per_layer_per_step);
        try addSlices(self.hydrology_matrix_ice_change, hydrology.matrix_ice_volume_change_m3_per_step);
        try addSlices(self.hydrology_macro_ice_change, hydrology.macropore_ice_volume_change_m3_per_step);
        try addSlices(self.hydrology_total_ice_change, hydrology.total_ice_volume_change_m3_per_step);
        try addSlices(self.face_matrix_flux, faces.micropore_water_flux_m3_per_step);
        try addSlices(self.face_macro_flux, faces.macropore_water_flux_m3_per_step);
        try addSlices(self.face_vapor_flux, faces.vapor_flux_m3_per_step);
        try addSlices(self.face_heat_flux, faces.heat_flux_megajoules_per_step);
        for (self.micropore_faces, faces.micropore_faces) |*total, part|
            total.water_flux_m3_per_step = try checkedAddFinite(total.water_flux_m3_per_step, part.water_flux_m3_per_step);
        for (self.macropore_faces, faces.macropore_faces) |*total, part|
            total.water_flux_m3_per_step = try checkedAddFinite(total.water_flux_m3_per_step, part.water_flux_m3_per_step);
    }

    fn gridStateSlice(
        self: *const Snapshot,
        carrier: usize,
    ) []const f64 {
        return switch (carrier) {
            0 => self.grid_matrix_water,
            1 => self.grid_macro_water,
            2 => self.grid_total_water,
            3 => self.grid_matrix_air,
            4 => self.grid_macro_air,
            5 => self.grid_total_air,
            6 => self.grid_vapor,
            7 => self.grid_matrix_ice,
            8 => self.grid_macro_ice,
            9 => self.grid_total_ice,
            10 => self.grid_temperature,
            11 => self.grid_matric_potential,
            else => unreachable,
        };
    }

    noinline fn deinit(self: *Snapshot) void {
        inline for (@typeInfo(Snapshot).@"struct".fields) |field| if (field.type == []f64 or field.type == []solute.Face) self.allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    noinline fn freeAllocated(self: *Snapshot, count: usize) void {
        var visited: usize = 0;
        inline for (@typeInfo(Snapshot).@"struct".fields) |field| if (field.type == []f64 or field.type == []solute.Face) {
            if (visited < count) self.allocator.free(@field(self, field.name));
            visited += 1;
        };
    }
};

fn snapshotF64Source(comptime name: []const u8, grid: *const grid_module.GridState, hydrology: *const hydrology_module.State, faces: *const hydrology_module.SoilFaces) []const f64 {
    if (comptime std.mem.eql(u8, name, "grid_matrix_water")) return grid.matrix_liquid_water_m3;
    if (comptime std.mem.eql(u8, name, "grid_macro_water")) return grid.macropore_liquid_water_m3;
    if (comptime std.mem.eql(u8, name, "grid_total_water")) return grid.liquid_water_m3;
    if (comptime std.mem.eql(u8, name, "grid_matrix_air")) return grid.matrix_air_volume_m3;
    if (comptime std.mem.eql(u8, name, "grid_macro_air")) return grid.macropore_air_volume_m3;
    if (comptime std.mem.eql(u8, name, "grid_total_air")) return grid.air_volume_m3;
    if (comptime std.mem.eql(u8, name, "grid_vapor")) return grid.water_vapor_volume_m3;
    if (comptime std.mem.eql(u8, name, "grid_matrix_ice")) return grid.matrix_ice_water_m3;
    if (comptime std.mem.eql(u8, name, "grid_macro_ice")) return grid.macropore_ice_water_m3;
    if (comptime std.mem.eql(u8, name, "grid_total_ice")) return grid.ice_water_m3;
    if (comptime std.mem.eql(u8, name, "grid_temperature")) return grid.soil_temperature_k;
    if (comptime std.mem.eql(u8, name, "grid_matric_potential")) return grid.matric_potential_megapascal;
    if (comptime std.mem.eql(u8, name, "hydrology_matrix_water")) return hydrology.micropore_water_volume_m3;
    if (comptime std.mem.eql(u8, name, "hydrology_macro_water")) return hydrology.macropore_water_volume_m3;
    if (comptime std.mem.eql(u8, name, "hydrology_matrix_air")) return hydrology.matrix_air_volume_m3;
    if (comptime std.mem.eql(u8, name, "hydrology_macro_air")) return hydrology.macropore_air_volume_m3;
    if (comptime std.mem.eql(u8, name, "hydrology_total_air")) return hydrology.air_volume_m3;
    if (comptime std.mem.eql(u8, name, "hydrology_vapor")) return hydrology.water_vapor_volume_m3;
    if (comptime std.mem.eql(u8, name, "hydrology_matrix_flux")) return hydrology.micropore_face_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_macro_flux")) return hydrology.macropore_face_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_vapor_flux")) return hydrology.vapor_face_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_heat_flux")) return hydrology.heat_face_flux_megajoules_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_matrix_external_flux")) return hydrology.micropore_external_water_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_macro_external_flux")) return hydrology.macropore_external_water_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_pore_exchange_flux")) return hydrology.macropore_to_matrix_water_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_artificial_drainage")) return hydrology.artificial_drainage_outflow_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_boundary_exchange")) return hydrology.boundary_water_exchange_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_boundary_exchange_by_layer")) return hydrology.boundary_water_exchange_m3_per_layer_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_boundary_heat_by_layer")) return hydrology.boundary_heat_exchange_megajoules_per_layer_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_matrix_ice_change")) return hydrology.matrix_ice_volume_change_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_macro_ice_change")) return hydrology.macropore_ice_volume_change_m3_per_step;
    if (comptime std.mem.eql(u8, name, "hydrology_total_ice_change")) return hydrology.total_ice_volume_change_m3_per_step;
    if (comptime std.mem.eql(u8, name, "face_matrix_flux")) return faces.micropore_water_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "face_macro_flux")) return faces.macropore_water_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "face_vapor_flux")) return faces.vapor_flux_m3_per_step;
    if (comptime std.mem.eql(u8, name, "face_heat_flux")) return faces.heat_flux_megajoules_per_step;
    unreachable;
}

fn addSlices(total: []f64, part: []const f64) !void {
    if (total.len != part.len) return error.SoilSubstepLedgerDimensionMismatch;
    for (total, part) |*sum, value|
        sum.* = try checkedAddFinite(sum.*, value);
}

/// Recovers the external WATSUB contribution from its conservative water
/// balance before freeze/thaw and matrix/macropore phase exchange alter the
/// storages. Positive output is discharge, matching TRNSFRS boundary signs.
/// CONSERVATION-PER-CELL-CLOSURE-001. Compares two independently-derived
/// per-cell measures of this step's total boundary water exchange: the water
/// solver's own internal accounting (`hydrology.boundary_water_exchange_m3_per_step`,
/// folded directly from `residualAt`'s boundary-face loop, cell-indexed,
/// gain-positive — added straight into storage) against the value backed out
/// here by `deriveExternalWaterFluxes` from storage change minus internal
/// face flux (`hydrology.micropore_external_water_flux_m3_per_step` +
/// `macropore_external_water_flux_m3_per_step`, layer-indexed, outward-
/// positive — `internal_flux - storage_change`), summed over each cell's
/// layers to match indexing. Neither quantity is derived from the other, so
/// this is a real check, not a tautology: a landscape-only residual check
/// (`validateAcceptedWaterBoundaryBalance` below) cannot see two cells whose
/// local errors cancel (e.g. a face applied to the wrong neighbor moves the
/// same water the solver's own boundary accounting does not expect, landing
/// a spurious opposite-signed "external" residual at each of the two cells
/// involved, netting to ~zero landscape-wide); comparing these two
/// independently-computed per-cell quantities can. Any mismatch aborts the
/// transaction before commit; `advance`'s snapshot errdefer restores all grid,
/// hydrology, and face state.
fn maximumMagnitude(values: []const f64) f64 {
    var result: f64 = 0;
    for (values) |value| result = @max(result, @abs(value));
    return result;
}

/// Independently closes every active Richards layer from the accepted face
/// fluxes, solver-produced boundary partition, explicit source, and endpoint
/// storages. No term is backed out from the endpoint being checked, so equal
/// and opposite layer defects cannot hide in a cell or domain reduction.
fn validatePerLayerRichardsWaterClosure(
    allocator: std.mem.Allocator,
    grid: *const grid_module.GridState,
    hydrology: *const hydrology_module.State,
    faces: *const hydrology_module.SoilFaces,
    absolute_tolerance_m: f64,
    relative_tolerance: f64,
    cell_area_m2: []const f64,
    matrix_external_source_m3_per_step: []const f64,
    initial_matrix_water_m3: []const f64,
    initial_macropore_water_m3: []const f64,
    roundoff_allowance_m3_by_layer: []f64,
) !void {
    const layers = grid.layer_count;
    if (hydrology.boundary_water_exchange_m3_per_layer_per_step.len != layers or
        initial_matrix_water_m3.len != layers or initial_macropore_water_m3.len != layers or
        (matrix_external_source_m3_per_step.len != 0 and matrix_external_source_m3_per_step.len != layers) or
        (cell_area_m2.len != 0 and cell_area_m2.len != grid.cell_count) or
        (roundoff_allowance_m3_by_layer.len != 0 and roundoff_allowance_m3_by_layer.len != layers))
        return error.WaterConservationLayerDimensionMismatch;
    const internal_input_m3 = try allocator.alloc(f64, layers);
    defer allocator.free(internal_input_m3);
    const internal_output_m3 = try allocator.alloc(f64, layers);
    defer allocator.free(internal_output_m3);
    @memset(internal_input_m3, 0);
    @memset(internal_output_m3, 0);
    for (
        faces.micropore_faces,
        faces.macropore_faces,
        faces.active_by_face,
    ) |micro_face, macro_face, active| {
        if (!active) continue;
        const micro = micro_face.water_flux_m3_per_step;
        const macro = macro_face.water_flux_m3_per_step;
        for ([_]struct { flux_m3: f64, source: usize, destination: usize }{
            .{ .flux_m3 = micro, .source = micro_face.first_cell, .destination = micro_face.second_cell },
            .{ .flux_m3 = macro, .source = macro_face.first_cell, .destination = macro_face.second_cell },
        }) |transfer| {
            if (!std.math.isFinite(transfer.flux_m3))
                return error.NonFiniteRichardsInternalWaterFlux;
            if (transfer.flux_m3 >= 0) {
                internal_output_m3[transfer.source] += transfer.flux_m3;
                internal_input_m3[transfer.destination] += transfer.flux_m3;
            } else {
                internal_input_m3[transfer.source] -= transfer.flux_m3;
                internal_output_m3[transfer.destination] -= transfer.flux_m3;
            }
        }
    }
    for (0..grid.cell_count) |cell| {
        const cell_area = if (cell_area_m2.len == 0) 0 else cell_area_m2[cell];
        if (!std.math.isFinite(cell_area) or cell_area < 0)
            return error.InvalidWaterConservationCellArea;
        var boundary_sum_m3: f64 = 0;
        var boundary_input_m3: f64 = 0;
        var boundary_output_m3: f64 = 0;
        for (0..grid.active_soil_layer_count[cell]) |layer_offset| {
            const layer = try grid.layerIndex(cell, layer_offset);
            const source_m3 = if (matrix_external_source_m3_per_step.len == 0) 0 else matrix_external_source_m3_per_step[layer];
            const boundary_gain_m3 = hydrology.boundary_water_exchange_m3_per_layer_per_step[layer];
            const before_m3 = initial_matrix_water_m3[layer] + initial_macropore_water_m3[layer];
            const after_m3 = grid.matrix_liquid_water_m3[layer] + grid.macropore_liquid_water_m3[layer];
            const closure_with_provenance = try water_solver_conserved.richardsLayerClosureWithProvenance(
                before_m3,
                after_m3,
                internal_input_m3[layer],
                internal_output_m3[layer],
                source_m3,
                @max(0, boundary_gain_m3),
                @max(0, -boundary_gain_m3),
                absolute_tolerance_m * cell_area,
                relative_tolerance,
            );
            const closure = closure_with_provenance.closure;
            if (!closure.accepted) {
                if (!builtin.is_test) std.log.err("per-layer Richards water closure mismatch: cell={d} layer={d} storage_before_m3={e} storage_after_m3={e} internal_input_m3={e} internal_output_m3={e} source_m3={e} boundary_gain_m3={e} residual_m3={e} normalized_relative={e} limit_m3={e}", .{ cell, layer_offset, before_m3, after_m3, internal_input_m3[layer], internal_output_m3[layer], source_m3, boundary_gain_m3, closure.residual, closure.normalized_relative, closure.acceptance_limit });
                return error.PerLayerRichardsWaterClosureMismatch;
            }
            if (roundoff_allowance_m3_by_layer.len != 0)
                roundoff_allowance_m3_by_layer[layer] = try checkedAddNonnegativeRoundUp(
                    roundoff_allowance_m3_by_layer[layer],
                    closure_with_provenance.producer_roundoff_allowance_m3,
                );
            boundary_sum_m3 += boundary_gain_m3;
            boundary_input_m3 += @max(0, boundary_gain_m3);
            boundary_output_m3 += @max(0, -boundary_gain_m3);
        }
        const aggregate = hydrology.boundary_water_exchange_m3_per_step[cell];
        // Match the producing solver's partition arithmetic scale. Opposing
        // boundary transfers can cancel to a tiny net value; the rounding of
        // two differently grouped sums is bounded by gross throughput, not
        // by that cancellation residual. Every layer was independently
        // checked above, so this does not mask opposing local water defects.
        const partition_scale_m3 = @max(@abs(aggregate), @max(boundary_input_m3, boundary_output_m3));
        const partition_floor_m3 = 128 * std.math.floatEps(f64) * partition_scale_m3;
        if (@abs(boundary_sum_m3 - aggregate) > partition_floor_m3) {
            if (!builtin.is_test) std.log.err("post-Richards boundary partition mismatch: cell={d} layer_sum_m3={e} cell_aggregate_m3={e} input_m3={e} output_m3={e} difference_m3={e} arithmetic_limit_m3={e}", .{ cell, boundary_sum_m3, aggregate, boundary_input_m3, boundary_output_m3, boundary_sum_m3 - aggregate, partition_floor_m3 });
            return error.BoundaryWaterLayerPartitionMismatch;
        }
    }
}

/// Closes the accepted spatial heat solve independently at every layer from
/// its pre-solve enthalpy census, accepted face fluxes, explicit layer source,
/// solver-produced external-boundary partition, and post-solve census.
fn validatePerLayerSpatialHeatClosure(
    allocator: std.mem.Allocator,
    grid: *const grid_module.GridState,
    hydrology: *const hydrology_module.State,
    faces: *const hydrology_module.SoilFaces,
    initial_enthalpy_megajoules: []const f64,
    initial_enthalpy_roundoff_allowance_megajoules: []const f64,
    solver_representability_allowance_megajoules: []const f64,
    dry_solid_heat_capacity_megajoules_per_k: []const f64,
    cell_heat_source_megajoules: []const f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
    ice_heat_capacity_megajoules_per_m3_k: f64,
    latent_heat_of_fusion_megajoules_per_m3: f64,
    pure_water_freezing_temperature_k: f64,
    absolute_tolerance_megajoules_per_m2: f64,
    relative_tolerance: f64,
    cell_area_m2: []const f64,
    roundoff_allowance_megajoules_by_layer: []f64,
    /// WATSUB 6907 discarded flux, booked as signed internal heat so the
    /// hourly census sees the same oracle rule this closure already skips.
    /// Empty disables booking; production passes the phase-endpoint lane.
    negligible_capacity_unabsorbed_megajoules_by_layer: []f64,
    /// issue-068 (fourth round, 2026-09-20): per-layer energy discrepancy
    /// booked by `temperatureForCellEnthalpy` when it held a chronically
    /// near-zero-heat-capacity layer's prior temperature instead of dividing.
    /// Netted into `expected_gain_megajoules` below so a held-back layer's
    /// actual storage change is compared against the SAME adjusted
    /// expectation, rather than the raw flux-only tally that assumed the
    /// renormalization inversion actually ran. Empty disables netting
    /// (read-only; this function does not book into it).
    renormalization_floor_discard_megajoules_by_layer: []const f64,
) !void {
    const layers = grid.layer_count;
    if (initial_enthalpy_megajoules.len != layers or
        initial_enthalpy_roundoff_allowance_megajoules.len != layers or
        solver_representability_allowance_megajoules.len != layers or
        dry_solid_heat_capacity_megajoules_per_k.len != layers or
        cell_heat_source_megajoules.len != layers or
        hydrology.boundary_heat_exchange_megajoules_per_layer_per_step.len != layers or
        (cell_area_m2.len != 0 and cell_area_m2.len != grid.cell_count) or
        (roundoff_allowance_megajoules_by_layer.len != 0 and
            roundoff_allowance_megajoules_by_layer.len != layers) or
        (negligible_capacity_unabsorbed_megajoules_by_layer.len != 0 and
            negligible_capacity_unabsorbed_megajoules_by_layer.len != layers) or
        (renormalization_floor_discard_megajoules_by_layer.len != 0 and
            renormalization_floor_discard_megajoules_by_layer.len != layers))
        return error.HeatConservationLayerDimensionMismatch;
    const internal_gain_megajoules = try allocator.alloc(f64, layers);
    defer allocator.free(internal_gain_megajoules);
    const internal_flux_magnitude_megajoules = try allocator.alloc(f64, layers);
    defer allocator.free(internal_flux_magnitude_megajoules);
    const internal_flux_operation_count = try allocator.alloc(usize, layers);
    defer allocator.free(internal_flux_operation_count);
    @memset(internal_gain_megajoules, 0);
    @memset(internal_flux_magnitude_megajoules, 0);
    @memset(internal_flux_operation_count, 0);
    for (faces.micropore_faces, faces.active_by_face, faces.heat_flux_megajoules_per_step) |face, active, flux| {
        if (!active) continue;
        internal_gain_megajoules[face.first_cell] -= flux;
        internal_gain_megajoules[face.second_cell] += flux;
        internal_flux_magnitude_megajoules[face.first_cell] = std.math.nextAfter(
            f64,
            internal_flux_magnitude_megajoules[face.first_cell] + @abs(flux),
            std.math.inf(f64),
        );
        internal_flux_magnitude_megajoules[face.second_cell] = std.math.nextAfter(
            f64,
            internal_flux_magnitude_megajoules[face.second_cell] + @abs(flux),
            std.math.inf(f64),
        );
        internal_flux_operation_count[face.first_cell] += 1;
        internal_flux_operation_count[face.second_cell] += 1;
    }
    for (0..grid.cell_count) |cell| {
        const cell_area = if (cell_area_m2.len == 0) 0 else cell_area_m2[cell];
        if (!std.math.isFinite(cell_area) or cell_area < 0)
            return error.InvalidHeatConservationCellArea;
        for (0..grid.active_soil_layer_count[cell]) |layer_offset| {
            const layer = try grid.layerIndex(cell, layer_offset);
            const final_enthalpy_megajoules = cellEnthalpyMegajoules(
                grid,
                layer,
                dry_solid_heat_capacity_megajoules_per_k[layer],
                liquid_water_heat_capacity_megajoules_per_m3_k,
                ice_heat_capacity_megajoules_per_m3_k,
                latent_heat_of_fusion_megajoules_per_m3,
                pure_water_freezing_temperature_k,
            );
            const source_megajoules = cell_heat_source_megajoules[layer];
            const boundary_gain_megajoules = hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[layer];
            // issue-068 (fourth round): a layer this hour's renormalization
            // held (see `temperatureForCellEnthalpy`) received less (or more)
            // storage change than the raw flux/source/boundary tally implies,
            // by exactly the booked discrepancy. Net it out here so the
            // comparison below is against the ACTUAL, held-back trajectory,
            // not the trajectory that would have existed had the inversion
            // divided through unconditionally.
            const renormalization_floor_discard_megajoules = if (renormalization_floor_discard_megajoules_by_layer.len == 0)
                0
            else
                renormalization_floor_discard_megajoules_by_layer[layer];
            const expected_gain_megajoules = internal_gain_megajoules[layer] + source_megajoules + boundary_gain_megajoules - renormalization_floor_discard_megajoules;
            // `DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001`. WATSUB 6907--6913
            // does not solve a layer whose heat capacity is at or below `VHCPRX`;
            // it holds `TKS` and the energy the layer cannot absorb is discarded.
            // `redist.f:9655-9659` does the same at the remap. The oracle can
            // afford that silently because it has no conservation census; this
            // census exists, so the discard is **booked and reported** instead of
            // either hidden or treated as a violation.
            //
            // The predicate is evaluated here from this census's own view of the
            // state, deliberately, rather than trusting a flag from the solver:
            // if the two ever disagree about whether a layer was solvable, this
            // check still objects. `VHCPRX = 8.380E-05 * AREA` is `starts.f:655`.
            //
            // This cannot absorb ordinary error. Above the floor the closure test
            // below is untouched, so every solvable layer is audited exactly as
            // before, and a layer only qualifies when its TOTAL capacity -- dry
            // solid plus water, vapour and ice, the same WATSUB 252--254
            // combination used throughout this file -- is at or below a threshold
            // that is four orders of magnitude under a healthy 1 cm layer.
            const layer_total_heat_capacity_megajoules_per_k =
                dry_solid_heat_capacity_megajoules_per_k[layer] +
                liquid_water_heat_capacity_megajoules_per_m3_k *
                    (grid.matrix_liquid_water_m3[layer] +
                        grid.macropore_liquid_water_m3[layer] +
                        grid.water_vapor_volume_m3[layer]) +
                ice_heat_capacity_megajoules_per_m3_k *
                    (grid.matrix_ice_water_m3[layer] +
                        grid.macropore_ice_water_m3[layer]);
            const negligible_capacity_limit_megajoules_per_k =
                heat_flux.minimum_layer_heat_capacity_megajoules_per_m2_k * cell_area;
            if (cell_area > 0 and
                layer_total_heat_capacity_megajoules_per_k <=
                    negligible_capacity_limit_megajoules_per_k)
            {
                if (!builtin.is_test and expected_gain_megajoules != 0) std.log.warn(
                    "negligible-capacity layer discarded heat per WATSUB 6907: cell={d} layer={d} total_heat_capacity_megajoules_per_k={e} limit_megajoules_per_k={e} discarded_megajoules={e} internal_gain_mj={e} source_mj={e} boundary_gain_mj={e} storage_change_mj={e}",
                    .{
                        cell,
                        layer_offset,
                        layer_total_heat_capacity_megajoules_per_k,
                        negligible_capacity_limit_megajoules_per_k,
                        expected_gain_megajoules,
                        internal_gain_megajoules[layer],
                        source_megajoules,
                        boundary_gain_megajoules,
                        final_enthalpy_megajoules - initial_enthalpy_megajoules[layer],
                    },
                );
                // Pin held storage; booked fluxes did not. Offset them as
                // signed internal heat so the hourly census matches WATSUB
                // 6907 instead of reporting the discarded amount as a leak.
                if (negligible_capacity_unabsorbed_megajoules_by_layer.len != 0)
                    negligible_capacity_unabsorbed_megajoules_by_layer[layer] =
                        try checkedAddFinite(
                            negligible_capacity_unabsorbed_megajoules_by_layer[layer],
                            -expected_gain_megajoules,
                        );
                continue;
            }
            const initial_census_roundoff = initial_enthalpy_roundoff_allowance_megajoules[layer];
            if (!std.math.isFinite(initial_census_roundoff) or initial_census_roundoff < 0)
                return error.InvalidHeatStorageUpdateArithmeticProvenance;
            const final_census_roundoff = try cellEnthalpyRoundoffAllowanceMegajoules(
                grid,
                layer,
                dry_solid_heat_capacity_megajoules_per_k[layer],
                liquid_water_heat_capacity_megajoules_per_m3_k,
                ice_heat_capacity_megajoules_per_m3_k,
                latent_heat_of_fusion_megajoules_per_m3,
                pure_water_freezing_temperature_k,
            );
            const internal_reduction_roundoff = try arithmeticForwardErrorBound(
                internal_flux_operation_count[layer],
                internal_flux_magnitude_megajoules[layer],
            );
            const expected_gain_roundoff = try arithmeticForwardErrorBound(
                2,
                @abs(internal_gain_megajoules[layer]) +
                    @abs(source_megajoules) + @abs(boundary_gain_megajoules),
            );
            var producer_roundoff = try checkedAddNonnegativeHeatRoundUp(
                initial_census_roundoff,
                final_census_roundoff,
            );
            producer_roundoff = try checkedAddNonnegativeHeatRoundUp(
                producer_roundoff,
                internal_reduction_roundoff,
            );
            producer_roundoff = try checkedAddNonnegativeHeatRoundUp(
                producer_roundoff,
                expected_gain_roundoff,
            );
            producer_roundoff = try checkedAddNonnegativeHeatRoundUp(
                producer_roundoff,
                solver_representability_allowance_megajoules[layer],
            );
            const closure = try scoped_conservation.evaluate(.{
                .storage_before = initial_enthalpy_megajoules[layer],
                .storage_after = final_enthalpy_megajoules,
                .external_inputs = @max(0, expected_gain_megajoules),
                .external_outputs = @max(0, -expected_gain_megajoules),
            }, .{
                .absolute = absolute_tolerance_megajoules_per_m2 * cell_area,
                .relative = relative_tolerance,
                .upstream_arithmetic_roundoff_allowance = producer_roundoff,
            });
            if (!closure.accepted) {
                if (!builtin.is_test) std.log.err("per-layer spatial heat closure mismatch: cell={d} layer={d} initial_enthalpy_mj={e} final_enthalpy_mj={e} internal_gain_mj={e} source_mj={e} boundary_gain_mj={e} residual_mj={e} normalized_relative={e} limit_mj={e}", .{ cell, layer_offset, initial_enthalpy_megajoules[layer], final_enthalpy_megajoules, internal_gain_megajoules[layer], source_megajoules, boundary_gain_megajoules, closure.residual, closure.normalized_relative, closure.acceptance_limit });
                return error.PerLayerSpatialHeatClosureMismatch;
            }
            if (roundoff_allowance_megajoules_by_layer.len != 0)
                roundoff_allowance_megajoules_by_layer[layer] =
                    try checkedAddNonnegativeHeatRoundUp(
                        roundoff_allowance_megajoules_by_layer[layer],
                        producer_roundoff,
                    );
        }
    }
}

/// Completes the layer-local water proof after Richards: vapor transport may
/// move water between layers, while vapor/liquid/ice equilibrium, pore-domain
/// exchange, and heat-coupled freeze/thaw are strictly internal to each layer.
/// The census includes every water-equivalent phase and both pore domains.
fn validatePerLayerPostRichardsTotalWaterClosure(
    allocator: std.mem.Allocator,
    grid: *const grid_module.GridState,
    faces: *const hydrology_module.SoilFaces,
    post_richards_total_water_equivalent_m3: []const f64,
    phase_displacement_by_layer: []const PhaseDisplacement,
    post_phase_external_water_change_m3: []const f64,
    absolute_tolerance_m: f64,
    relative_tolerance: f64,
    cell_area_m2: []const f64,
    roundoff_allowance_m3_by_layer: []f64,
    /// The vapor solver's own already-configured, already-accepted
    /// convergence criterion (`vapor_solver.Options.absolute_tolerance_m3`/
    /// `.relative_tolerance`, i.e. `inputs.vapor_options.*` at the production
    /// call site). `vapor_internal_gain_m3` below is a direct readout of that
    /// solver's converged face fluxes, so its own accepted residual for the
    /// layer -- not exact IEEE roundoff -- is a legitimate, already-tested
    /// error floor for this identity, sized identically to the tolerance the
    /// solver was actually run with (issue-067). Pass `0, 0` to disable this
    /// term, matching every pre-existing call site/test that never accounted
    /// for it.
    vapor_solver_absolute_tolerance_m3: f64,
    vapor_solver_relative_tolerance: f64,
) !void {
    const layers = grid.layer_count;
    if (post_richards_total_water_equivalent_m3.len != layers or
        (phase_displacement_by_layer.len != 0 and phase_displacement_by_layer.len != layers) or
        post_phase_external_water_change_m3.len != layers or
        (cell_area_m2.len != 0 and cell_area_m2.len != grid.cell_count) or
        (roundoff_allowance_m3_by_layer.len != 0 and roundoff_allowance_m3_by_layer.len != layers))
        return error.TotalWaterConservationLayerDimensionMismatch;
    const vapor_internal_gain_m3 = try allocator.alloc(f64, layers);
    defer allocator.free(vapor_internal_gain_m3);
    @memset(vapor_internal_gain_m3, 0);
    for (faces.micropore_faces, faces.active_by_face, faces.vapor_flux_m3_per_step) |face, active, flux| {
        if (!active) continue;
        vapor_internal_gain_m3[face.first_cell] -= flux;
        vapor_internal_gain_m3[face.second_cell] += flux;
    }
    for (0..grid.cell_count) |cell| {
        const cell_area = if (cell_area_m2.len == 0) 0 else cell_area_m2[cell];
        if (!std.math.isFinite(cell_area) or cell_area < 0)
            return error.InvalidWaterConservationCellArea;
        for (0..grid.active_soil_layer_count[cell]) |layer_offset| {
            const layer = try grid.layerIndex(cell, layer_offset);
            const before_m3 = post_richards_total_water_equivalent_m3[layer];
            const after_m3 = grid.matrix_liquid_water_m3[layer] +
                grid.macropore_liquid_water_m3[layer] +
                grid.matrix_ice_water_m3[layer] +
                grid.macropore_ice_water_m3[layer] +
                grid.water_vapor_volume_m3[layer];
            const displaced_m3 = if (phase_displacement_by_layer.len == 0)
                0
            else
                try phaseDisplacedWaterEquivalentM3(phase_displacement_by_layer[layer]);
            const boundary_gain_m3 = post_phase_external_water_change_m3[layer];
            if (!std.math.isFinite(boundary_gain_m3))
                return error.NonFinitePostPhaseBoundaryWater;
            const expected_gain_m3 = vapor_internal_gain_m3[layer] - displaced_m3 + boundary_gain_m3;
            const activity_scale_m3 = maximumMagnitude(&.{ before_m3, after_m3, expected_gain_m3 });
            const representation_floor_m3 = 4096 * std.math.floatEps(f64) * activity_scale_m3;
            // `vapor_internal_gain_m3[layer]` is a direct readout of the vapor
            // solver's own converged face fluxes (`heat_step.zig`'s
            // `inputs.vapor_options` feeds that solver exactly
            // `vapor_solver_absolute_tolerance_m3`/`_relative_tolerance`
            // below), so it carries that solver's own already-accepted
            // convergence slack, not just binary64 representation error. In
            // the degenerate near-desiccated case this identity was written
            // for (issue-067), that flux is ~87x the layer's own remaining
            // water content, so `representation_floor_m3` above -- scaled
            // from the post-cancellation `activity_scale_m3` -- structurally
            // cannot see it. This term reuses the solver's own declared
            // tolerance band unchanged; it is not a new or widened
            // conservation tolerance.
            const vapor_solver_accepted_band_m3 = vapor_solver_absolute_tolerance_m3 +
                vapor_solver_relative_tolerance * @abs(vapor_internal_gain_m3[layer]);
            const closure = try scoped_conservation.evaluate(.{
                .storage_before = before_m3,
                .storage_after = after_m3,
                .external_inputs = @max(0, expected_gain_m3),
                .external_outputs = @max(0, -expected_gain_m3),
            }, .{
                .absolute = absolute_tolerance_m * cell_area,
                .relative = relative_tolerance,
                .upstream_arithmetic_roundoff_allowance = representation_floor_m3 + vapor_solver_accepted_band_m3,
            });
            if (!closure.accepted) {
                if (!builtin.is_test) std.log.err("per-layer post-Richards total-water closure mismatch: cell={d} layer={d} before_m3={e} after_m3={e} vapor_internal_gain_m3={e} phase_displacement_m3={e} post_phase_boundary_m3={e} residual_m3={e} normalized_relative={e} limit_m3={e}", .{ cell, layer_offset, before_m3, after_m3, vapor_internal_gain_m3[layer], displaced_m3, boundary_gain_m3, closure.residual, closure.normalized_relative, closure.acceptance_limit });
                return error.PerLayerPostRichardsTotalWaterClosureMismatch;
            }
            if (roundoff_allowance_m3_by_layer.len != 0)
                roundoff_allowance_m3_by_layer[layer] = try checkedAddNonnegativeRoundUp(
                    roundoff_allowance_m3_by_layer[layer],
                    representation_floor_m3,
                );
        }
    }
}

fn validatePerCellWaterBoundaryClosure(grid: *const grid_module.GridState, hydrology: *const hydrology_module.State, absolute_tolerance_m: f64, relative_tolerance: f64, cell_area_m2: []const f64, matrix_external_source_m3_per_step: []const f64, producer_roundoff_allowance_m3_by_layer: []const f64, initial_matrix_water_m3: []const f64, initial_macropore_water_m3: []const f64) !void {
    if (cell_area_m2.len != 0 and cell_area_m2.len != grid.cell_count)
        return error.WaterConservationCellAreaDimensionMismatch;
    if (matrix_external_source_m3_per_step.len != 0 and matrix_external_source_m3_per_step.len != grid.layer_count)
        return error.WaterConservationExternalSourceDimensionMismatch;
    if (producer_roundoff_allowance_m3_by_layer.len != 0 and
        producer_roundoff_allowance_m3_by_layer.len != grid.layer_count)
        return error.WaterStorageRoundoffProvenanceDimensionMismatch;
    if (initial_matrix_water_m3.len != grid.layer_count or initial_macropore_water_m3.len != grid.layer_count)
        return error.WaterConservationInitialStorageDimensionMismatch;
    for (0..grid.cell_count) |cell| {
        var backed_out_outward_m3: f64 = 0;
        var external_source_gain_m3: f64 = 0;
        var storage_change_m3: f64 = 0;
        var internal_change_m3: f64 = 0;
        var cancellation_scale_m3: f64 = 0;
        var producer_roundoff_allowance_m3: f64 = 0;
        for (0..grid.active_soil_layer_count[cell]) |layer_offset| {
            const index = try grid.layerIndex(cell, layer_offset);
            backed_out_outward_m3 += hydrology.micropore_external_water_flux_m3_per_step[index] +
                hydrology.macropore_external_water_flux_m3_per_step[index];
            storage_change_m3 += grid.matrix_liquid_water_m3[index] -
                initial_matrix_water_m3[index] +
                grid.macropore_liquid_water_m3[index] -
                initial_macropore_water_m3[index];
            internal_change_m3 +=
                hydrology.micropore_external_water_flux_m3_per_step[index] +
                (grid.matrix_liquid_water_m3[index] -
                    initial_matrix_water_m3[index]) +
                hydrology.macropore_external_water_flux_m3_per_step[index] +
                (grid.macropore_liquid_water_m3[index] -
                    initial_macropore_water_m3[index]);
            if (matrix_external_source_m3_per_step.len != 0)
                external_source_gain_m3 += matrix_external_source_m3_per_step[index];
            if (producer_roundoff_allowance_m3_by_layer.len != 0)
                producer_roundoff_allowance_m3 = try checkedAddNonnegativeRoundUp(
                    producer_roundoff_allowance_m3,
                    producer_roundoff_allowance_m3_by_layer[index],
                );
            cancellation_scale_m3 = @max(cancellation_scale_m3, maximumMagnitude(&.{
                initial_matrix_water_m3[index],
                initial_macropore_water_m3[index],
                grid.matrix_liquid_water_m3[index],
                grid.macropore_liquid_water_m3[index],
            }));
        }
        const solver_gain_m3 = hydrology.boundary_water_exchange_m3_per_step[cell];
        const transaction: scoped_conservation.Transaction = .{
            .storage_before = 0,
            .storage_after = solver_gain_m3 + external_source_gain_m3,
            .external_inputs = @max(0, -backed_out_outward_m3),
            .external_outputs = @max(0, backed_out_outward_m3),
        };
        const activity_scale_m3 = @max(@abs(solver_gain_m3 + external_source_gain_m3), @abs(backed_out_outward_m3));
        // This reconstruction crosses the iterative target update, state
        // publish, internal-face reduction, and storage-difference reduction.
        // Carry the per-layer source-certified producer bounds through this
        // cell reduction, then add only the reduction's own f64 forward-error
        // bound. Neither term changes the configured physical tolerance.
        const representation_floor_m3 = 2048 * std.math.floatEps(f64) * @max(activity_scale_m3, cancellation_scale_m3);
        const physical_floor_m3 = absolute_tolerance_m * if (cell_area_m2.len == 0) 0 else cell_area_m2[cell];
        const closure = scoped_conservation.evaluate(transaction, .{
            .absolute = physical_floor_m3,
            .relative = relative_tolerance,
            .upstream_arithmetic_roundoff_allowance = try checkedAddNonnegativeRoundUp(
                producer_roundoff_allowance_m3,
                representation_floor_m3,
            ),
        }) catch {
            if (!builtin.is_test) std.log.err("per-cell water boundary closure invalid: cell={d} solver_gain_m3={e} external_source_gain_m3={e} backed_out_outward_m3={e}", .{ cell, solver_gain_m3, external_source_gain_m3, backed_out_outward_m3 });
            return error.InvalidPerCellWaterBoundaryClosure;
        };
        if (!closure.accepted) {
            if (!builtin.is_test) std.log.err("per-cell water boundary closure mismatch: cell={d} solver_gain_m3={e} external_source_gain_m3={e} storage_change_m3={e} internal_change_m3={e} backed_out_outward_m3={e} artificial_drainage_m3={e} residual_m3={e} absolute_m3={e} normalized_relative={e} physical_acceptance_limit_m3={e} arithmetic_roundoff_allowance_m3={e} effective_acceptance_limit_m3={e}", .{ cell, solver_gain_m3, external_source_gain_m3, storage_change_m3, internal_change_m3, backed_out_outward_m3, hydrology.artificial_drainage_outflow_m3_per_step[cell], closure.residual, closure.absolute, closure.normalized_relative, closure.acceptance_limit, closure.arithmetic_roundoff_allowance, closure.effective_acceptance_limit });
            return error.PerCellWaterBoundaryClosureMismatch;
        }
    }
}

fn deriveExternalWaterFluxes(grid: *const grid_module.GridState, hydrology: *hydrology_module.State, faces: *const hydrology_module.SoilFaces, initial_matrix_water_m3: []const f64, initial_macropore_water_m3: []const f64) !void {
    if (initial_matrix_water_m3.len != grid.layer_count or initial_macropore_water_m3.len != grid.layer_count or hydrology.micropore_external_water_flux_m3_per_step.len != grid.layer_count or hydrology.macropore_external_water_flux_m3_per_step.len != grid.layer_count) return error.ExternalWaterFluxDimensionMismatch;
    @memset(hydrology.micropore_external_water_flux_m3_per_step, 0);
    @memset(hydrology.macropore_external_water_flux_m3_per_step, 0);
    for (faces.micropore_faces, faces.macropore_faces) |micro_face, macro_face| {
        const micro_flux = micro_face.water_flux_m3_per_step;
        const macro_flux = macro_face.water_flux_m3_per_step;
        hydrology.micropore_external_water_flux_m3_per_step[micro_face.first_cell] -= micro_flux;
        hydrology.micropore_external_water_flux_m3_per_step[micro_face.second_cell] += micro_flux;
        hydrology.macropore_external_water_flux_m3_per_step[macro_face.first_cell] -= macro_flux;
        hydrology.macropore_external_water_flux_m3_per_step[macro_face.second_cell] += macro_flux;
    }
    for (0..grid.layer_count) |layer| {
        const internal_matrix_change = hydrology.micropore_external_water_flux_m3_per_step[layer];
        const internal_macro_change = hydrology.macropore_external_water_flux_m3_per_step[layer];
        hydrology.micropore_external_water_flux_m3_per_step[layer] = internal_matrix_change - (grid.matrix_liquid_water_m3[layer] - initial_matrix_water_m3[layer]);
        hydrology.macropore_external_water_flux_m3_per_step[layer] = internal_macro_change - (grid.macropore_liquid_water_m3[layer] - initial_macropore_water_m3[layer]);
        if (!std.math.isFinite(hydrology.micropore_external_water_flux_m3_per_step[layer]) or !std.math.isFinite(hydrology.macropore_external_water_flux_m3_per_step[layer])) return error.NonFiniteExternalWaterFlux;
    }
}

fn validateAcceptedWaterBoundaryBalance(grid: *const grid_module.GridState, hydrology: *const hydrology_module.State, initial_matrix_water_m3: []const f64, initial_macropore_water_m3: []const f64, absolute_tolerance_m: f64, relative_tolerance: f64, cell_area_m2: []const f64) !void {
    var storage_change_m3: f64 = 0;
    var outward_boundary_m3: f64 = 0;
    // Sum of the magnitudes actually added, and how many were added. The
    // classical error bound for a floating-point summation is
    // `|computed - exact| <= n * eps * sum(|x_i|)`, which depends on the
    // magnitudes SUMMED, not on their cancelled difference. Both sums here
    // cancel almost completely -- layer water volumes of order 1e-2..1e0 m3
    // subtract to a storage change of order 1e-14 m3 -- so a floor derived
    // from the difference bounds nothing at all. See the note below the loop.
    var summand_magnitude_m3: f64 = 0;
    var summand_count: usize = 0;
    for (0..grid.cell_count) |cell| for (0..grid.active_soil_layer_count[cell]) |layer| {
        const index = try grid.layerIndex(cell, layer);
        storage_change_m3 += grid.matrix_liquid_water_m3[index] - initial_matrix_water_m3[index] +
            grid.macropore_liquid_water_m3[index] - initial_macropore_water_m3[index];
        outward_boundary_m3 += hydrology.micropore_external_water_flux_m3_per_step[index] +
            hydrology.macropore_external_water_flux_m3_per_step[index];
        summand_magnitude_m3 += @abs(grid.matrix_liquid_water_m3[index]) + @abs(initial_matrix_water_m3[index]) +
            @abs(grid.macropore_liquid_water_m3[index]) + @abs(initial_macropore_water_m3[index]) +
            @abs(hydrology.micropore_external_water_flux_m3_per_step[index]) +
            @abs(hydrology.macropore_external_water_flux_m3_per_step[index]);
        summand_count += 6;
    };
    if (cell_area_m2.len != 0 and cell_area_m2.len != grid.cell_count)
        return error.WaterConservationCellAreaDimensionMismatch;
    var domain_area_m2: f64 = 0;
    for (cell_area_m2) |area| {
        if (!std.math.isFinite(area) or area <= 0)
            return error.InvalidWaterConservationCellArea;
        domain_area_m2 += area;
    }
    const transaction: scoped_conservation.Transaction = .{
        .storage_before = 0,
        .storage_after = storage_change_m3,
        .external_inputs = @max(0, -outward_boundary_m3),
        .external_outputs = @max(0, outward_boundary_m3),
    };
    const activity_scale_m3 = @max(@abs(storage_change_m3), @abs(outward_boundary_m3));
    // Legacy `ZEROS(NY,NX) = ZERO*DH*DV` with `ZERO=1.0E-15` (ecosys_f77/starts.f:93,269,
    // under the comment "minimum values used for all calculations"). Below that
    // volume the oracle treats a quantity as absent, so there is no resolvable
    // water movement here to conserve.
    //
    // This gate is purely relative in practice -- callers pass
    // `absolute_tolerance_m` of ~0, so the limit degenerates to
    // `relative_tolerance * activity_scale_m3`. When the activity scale is
    // itself at the floating-point noise floor that limit collapses below the
    // representable difference of the two near-equal sums being compared, and a
    // meaningless residual fails a meaningless bound. Observed on the real deck
    // at year1998 day79 hour16: `storage_change_m3=-1.3877787807814457e-17`
    // (exactly -2^-56) against `outward_boundary_m3=1.3877814277594058e-17`,
    // giving `residual_m3=2.6469779601696886e-23` -- 2.6e-20 litres -- against
    // an `acceptance_limit_m3` of 1.3879392002413767e-26.
    //
    // A physical floor is the fix rather than a larger relative tolerance, and
    // deliberately NOT an invented unit-volume denominator: the existing test
    // "tiny domain water leak is not normalized against an arbitrary unit
    // volume" pins that a real leak in a small domain must still be caught, and
    // this floor is far below any real leak.
    const domain_floor_area_m2 = if (domain_area_m2 > 0) domain_area_m2 else 1;
    if (activity_scale_m3 <= 1.0e-15 * domain_floor_area_m2) return;
    // `512 * eps * activity_scale_m3` was the previous floor and it bounds
    // nothing: `activity_scale_m3` is the POST-cancellation difference, so the
    // floor shrinks in exact proportion to how badly the sums cancelled. The
    // real deck proved it at year1998 day96 hour4, with the reorder in place:
    // `storage_change_m3=2.5517782331618832e-14` against
    // `outward_boundary_m3=-2.5517782416322128e-14` gave
    // `residual_m3=-8.470329598760748e-23` -- 8.5e-17 litres, and
    // `normalized_relative=3.319383111183991e-9`, which is 99.9999997%
    // closure -- rejected against an `acceptance_limit_m3` of
    // 2.552068345231071e-23.
    //
    // The classical bound is used instead. It is not a tolerance: it is the
    // arithmetic's own resolution, and it is ~10 orders of magnitude below the
    // oracle's `ZEROS2 = 1.0E-06 * DH * DV` floor (ecosys_f77/starts.f:94,270),
    // so it cannot hide a leak the oracle itself would have noticed. The test
    // "tiny domain water leak is not normalized against an arbitrary unit
    // volume" still pins that a real leak in a small domain is caught, because
    // this floor scales with the domain's own water rather than a unit volume.
    const representation_floor_m3 = @as(f64, @floatFromInt(summand_count)) * std.math.floatEps(f64) * summand_magnitude_m3;
    const closure = try scoped_conservation.evaluate(transaction, .{
        .absolute = absolute_tolerance_m * domain_area_m2 + representation_floor_m3,
        .relative = relative_tolerance,
    });
    if (!closure.accepted) {
        if (!builtin.is_test) std.log.err("accepted Richards water boundary imbalance: storage_change_m3={e} outward_boundary_m3={e} residual_m3={e} normalized_relative={e} acceptance_limit_m3={e}", .{ storage_change_m3, outward_boundary_m3, closure.residual, closure.normalized_relative, closure.acceptance_limit });
        return error.AcceptedRichardsWaterBoundaryImbalance;
    }
}

test "per-layer water gate rejects opposing defects that cancel in the cell sum" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    hydrology.boundary_water_exchange_m3_per_layer_per_step[0] = 0.5;
    hydrology.boundary_water_exchange_m3_per_layer_per_step[1] = -0.5;
    hydrology.boundary_water_exchange_m3_per_step[0] = 0;
    try std.testing.expectError(error.PerLayerRichardsWaterClosureMismatch, validatePerLayerRichardsWaterClosure(std.testing.allocator, &grid, &hydrology, &faces, 1e-12, 1e-9, &.{1}, &.{ 0, 0 }, &.{ 0, 0 }, &.{ 0, 0 }, &.{}));
    @memset(hydrology.boundary_water_exchange_m3_per_layer_per_step, 0);
    var richards_roundoff = [_]f64{ 0, 0 };
    try validatePerLayerRichardsWaterClosure(std.testing.allocator, &grid, &hydrology, &faces, 1e-12, 1e-9, &.{1}, &.{ 0, 0 }, &.{ 0, 0 }, &.{ 0, 0 }, &richards_roundoff);
    // Every closure term (storage, internal transfer, source, boundary) is exactly
    // zero here, so the representation-floor roundoff allowance is legitimately
    // zero too (it scales with activity magnitude; see
    // `richardsLayerClosureWithProvenance`'s `activity_scale_m3`). Production code
    // (`addWaterStorageRoundoffUpward`) treats an exact-zero allowance as valid,
    // not exceptional, so assert the exact expected value rather than `> 0`.
    try std.testing.expectEqual(@as(f64, 0), richards_roundoff[0]);
    try std.testing.expectEqual(@as(f64, 0), richards_roundoff[1]);
}

test "boundary water partition uses gross throughput for cancellation roundoff only" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 3, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 3);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 3, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    const boundary_m3 = [_]f64{ 0.1, 0.2, -0.3 };
    for (boundary_m3, 0..) |gain_m3, layer| {
        grid.matrix_liquid_water_m3[layer] = 1 + gain_m3;
        hydrology.boundary_water_exchange_m3_per_layer_per_step[layer] = gain_m3;
    }
    // Two valid summation orders of exactly the same signed transfers.
    const aggregate_m3 = boundary_m3[0] + (boundary_m3[1] + boundary_m3[2]);
    const layer_sum_m3 = (boundary_m3[0] + boundary_m3[1]) + boundary_m3[2];
    try std.testing.expect(@abs(layer_sum_m3 - aggregate_m3) >
        128 * std.math.floatEps(f64) * @max(@abs(layer_sum_m3), @abs(aggregate_m3)));
    hydrology.boundary_water_exchange_m3_per_step[0] = aggregate_m3;
    try validatePerLayerRichardsWaterClosure(std.testing.allocator, &grid, &hydrology, &faces, 0, 1e-9, &.{1}, &.{ 0, 0, 0 }, &.{ 1, 1, 1 }, &.{ 0, 0, 0 }, &.{});
    // A real partition mismatch remains fatal even though all layer balances
    // still pass; the gross-throughput bound is arithmetic, not a new budget.
    hydrology.boundary_water_exchange_m3_per_step[0] = 1e-6;
    try std.testing.expectError(error.BoundaryWaterLayerPartitionMismatch, validatePerLayerRichardsWaterClosure(std.testing.allocator, &grid, &hydrology, &faces, 0, 1e-9, &.{1}, &.{ 0, 0, 0 }, &.{ 1, 1, 1 }, &.{ 0, 0, 0 }, &.{}));
}

test "per-layer enthalpy gate rejects opposing defects that cancel in the cell sum" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    @memset(grid.soil_temperature_k, 280);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    const dry_capacity = [_]f64{ 1, 1 };
    var initial_enthalpy: [2]f64 = undefined;
    var initial_enthalpy_roundoff: [2]f64 = undefined;
    try fillCellEnthalpyMegajoules(&initial_enthalpy, &grid, &dry_capacity, 4.19, 1.9274 / 0.917, 333, 273.15);
    try fillCellEnthalpyRoundoffAllowances(&initial_enthalpy_roundoff, &grid, &dry_capacity, 4.19, 1.9274 / 0.917, 333, 273.15);
    hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[0] = 0.5;
    hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[1] = -0.5;
    try std.testing.expectError(error.PerLayerSpatialHeatClosureMismatch, validatePerLayerSpatialHeatClosure(std.testing.allocator, &grid, &hydrology, &faces, &initial_enthalpy, &initial_enthalpy_roundoff, &.{ 0, 0 }, &dry_capacity, &.{ 0, 0 }, 4.19, 1.9274 / 0.917, 333, 273.15, 1e-12, 1e-9, &.{1}, &.{}, &.{}, &.{}));
    try validatePerLayerSpatialHeatClosure(std.testing.allocator, &grid, &hydrology, &faces, &initial_enthalpy, &initial_enthalpy_roundoff, &.{ 0.5, 0.5 }, &dry_capacity, &.{ 0, 0 }, 4.19, 1.9274 / 0.917, 333, 273.15, 1e-12, 1e-9, &.{1}, &.{}, &.{}, &.{});
    @memset(hydrology.boundary_heat_exchange_megajoules_per_layer_per_step, 0);
    try validatePerLayerSpatialHeatClosure(std.testing.allocator, &grid, &hydrology, &faces, &initial_enthalpy, &initial_enthalpy_roundoff, &.{ 0, 0 }, &dry_capacity, &.{ 0, 0 }, 4.19, 1.9274 / 0.917, 333, 273.15, 1e-12, 1e-9, &.{1}, &.{}, &.{}, &.{});
}

test "issue-068 (fourth round): validatePerLayerSpatialHeatClosure nets a booked renormalization-floor discard instead of flagging a false violation" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    @memset(grid.soil_temperature_k, 280);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    const dry_capacity = [_]f64{ 1, 1 };
    var initial_enthalpy: [2]f64 = undefined;
    var initial_enthalpy_roundoff: [2]f64 = undefined;
    try fillCellEnthalpyMegajoules(&initial_enthalpy, &grid, &dry_capacity, 4.19, 1.9274 / 0.917, 333, 273.15);
    try fillCellEnthalpyRoundoffAllowances(&initial_enthalpy_roundoff, &grid, &dry_capacity, 4.19, 1.9274 / 0.917, 333, 273.15);
    // Identical fixture to the immediately preceding test: an untouched,
    // storage-unchanged pair of layers with an opposing 0.5/-0.5 MJ boundary
    // exchange -- WITHOUT netting this is exactly the false violation the
    // preceding test proves at `error.PerLayerSpatialHeatClosureMismatch`.
    hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[0] = 0.5;
    hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[1] = -0.5;
    // Simulates `temperatureForCellEnthalpy` having held each layer's prior
    // temperature earlier in the same hour and booked exactly the amount
    // that would otherwise have reconciled this boundary exchange with
    // storage (i.e. the layer's storage genuinely does not reflect this
    // boundary term because the renormalization inversion was held instead
    // of dividing). Netting this into `expected_gain_megajoules` must turn
    // the same otherwise-violating fixture into a pass.
    const renormalization_floor_discard = [_]f64{ 0.5, -0.5 };
    try validatePerLayerSpatialHeatClosure(std.testing.allocator, &grid, &hydrology, &faces, &initial_enthalpy, &initial_enthalpy_roundoff, &.{ 0, 0 }, &dry_capacity, &.{ 0, 0 }, 4.19, 1.9274 / 0.917, 333, 273.15, 1e-12, 1e-9, &.{1}, &.{}, &.{}, &renormalization_floor_discard);
    // An empty discard array (the default for every one of the 35 existing
    // call sites of the sibling `phase_endpoint_reference_heat_megajoules_by_layer`
    // ledger, none of which this change touches) reproduces the original
    // failure exactly -- proof the new parameter is what changed the
    // outcome, not an unrelated side effect of this test's fixture.
    try std.testing.expectError(error.PerLayerSpatialHeatClosureMismatch, validatePerLayerSpatialHeatClosure(std.testing.allocator, &grid, &hydrology, &faces, &initial_enthalpy, &initial_enthalpy_roundoff, &.{ 0, 0 }, &dry_capacity, &.{ 0, 0 }, 4.19, 1.9274 / 0.917, 333, 273.15, 1e-12, 1e-9, &.{1}, &.{}, &.{}, &.{}));
}

test "post-Richards phase and vapor water gate rejects opposing layer defects" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    grid.matrix_liquid_water_m3[0] = 1.5;
    grid.matrix_liquid_water_m3[1] = 0.5;
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    try std.testing.expectError(error.PerLayerPostRichardsTotalWaterClosureMismatch, validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &.{ 1, 1 }, &.{}, &.{ 0, 0 }, 1e-12, 1e-9, &.{1}, &.{}, 0, 0));
    var post_richards_roundoff = [_]f64{ 0, 0 };
    try validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &.{ 1.5, 0.5 }, &.{}, &.{ 0, 0 }, 1e-12, 1e-9, &.{1}, &post_richards_roundoff, 0, 0);
    try std.testing.expect(post_richards_roundoff[0] > 0 and post_richards_roundoff[1] > 0);
    grid.matrix_liquid_water_m3[0] = 1.7;
    try std.testing.expectError(error.PerLayerPostRichardsTotalWaterClosureMismatch, validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &.{ 1.5, 0.5 }, &.{}, &.{ 0, 0 }, 1e-12, 1e-9, &.{1}, &.{}, 0, 0));
    try validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &.{ 1.5, 0.5 }, &.{}, &.{ 0.2, 0 }, 1e-12, 1e-9, &.{1}, &.{}, 0, 0);
    grid.matrix_liquid_water_m3[0] = 1.4;
    const upward_credit = [_]PhaseDisplacement{
        .{ .matrix_liquid_water_m3 = 0.1, .advective_enthalpy_megajoules = 117.32 },
        .{},
    };
    try validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &.{ 1.5, 0.5 }, &upward_credit, &.{ 0, 0 }, 1e-12, 1e-9, &.{1}, &.{}, 0, 0);
    const invalid_credit = [_]PhaseDisplacement{ .{ .matrix_liquid_water_m3 = -0.1 }, .{} };
    try std.testing.expectError(error.InvalidSoilPhaseDisplacement, validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &.{ 1.5, 0.5 }, &invalid_credit, &.{ 0, 0 }, 1e-12, 1e-9, &.{1}, &.{}, 0, 0));
}

// Regression test for issue-067 (hour-2895 per-layer post-Richards total-water
// closure mismatch). Uses the exact recorded before/after/flux/residual
// values from the actual production failure: layer 0, near-fully desiccated
// (`before_m3~1.04e-7`), with two nearly-cancelling ~9e-6-scale fluxes (vapor
// transport in, surface evaporation out) whose ~5.79e-16 m3 net mismatch is
// the vapor solver's own accepted Newton convergence slack for that layer
// (empirically confirmed: `TEMP_DIAGNOSTIC vapor solver accepted residual`
// reported `residual_m3=-5.786488638508808e-16` for this exact layer/hour,
// matching this check's own `residual_m3=5.786492873673544e-16` to ~7
// significant figures), not a new conservation defect.
test "post-Richards vapor water gate accounts for the vapor solver's own accepted convergence slack without becoming toothless" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-12, .max_nonlinear_iterations = 10 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 2);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();

    // The real hour-2895 vapor-transport flux into layer 0, carried by the
    // face between layer 0 and layer 1. Sign follows the same
    // `vapor_internal_gain_m3[first_cell] -= flux; [second_cell] += flux;`
    // convention the checked function itself uses.
    const vapor_flux_into_layer0_m3: f64 = 8.989422010247231e-6;
    var found_face = false;
    for (faces.micropore_faces, 0..) |face, index| {
        if (face.first_cell == 0 and face.second_cell == 1) {
            faces.vapor_flux_m3_per_step[index] = -vapor_flux_into_layer0_m3;
            faces.active_by_face[index] = true;
            found_face = true;
        } else if (face.first_cell == 1 and face.second_cell == 0) {
            faces.vapor_flux_m3_per_step[index] = vapor_flux_into_layer0_m3;
            faces.active_by_face[index] = true;
            found_face = true;
        }
    }
    try std.testing.expect(found_face);

    // Layer 1 is an inert large reservoir supplying that flux with its own
    // exact (zero-residual) closure, so only layer 0's degenerate case is
    // under test.
    const layer1_before_m3: f64 = 1.0;
    grid.matrix_liquid_water_m3[1] = layer1_before_m3 - vapor_flux_into_layer0_m3;

    // Layer 0: the real recorded before/after/boundary values.
    const before_m3 = [_]f64{ 1.0399626626397992e-7, layer1_before_m3 };
    grid.matrix_liquid_water_m3[0] = 3.991456771405978e-25; // real recorded after_m3
    const boundary_gain_m3 = [_]f64{ -9.09341827708986e-6, 0 };

    // The vapor solver's own actually-configured production tolerances for
    // this hour (confirmed by direct instrumentation:
    // `absolute_tolerance_m3=9.999999999999999e-14 relative_tolerance=1e-8`).
    const vapor_solver_absolute_tolerance_m3: f64 = 1e-13;
    const vapor_solver_relative_tolerance: f64 = 1e-8;

    // (a) The OLD pure-relative check (no vapor-solver allowance) rejects
    // this exact degenerate-but-legitimate case, reproducing issue-067.
    try std.testing.expectError(
        error.PerLayerPostRichardsTotalWaterClosureMismatch,
        validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &before_m3, &.{}, &boundary_gain_m3, 0, 1e-9, &.{1}, &.{}, 0, 0),
    );

    // (b) The NEW hybrid check, given the vapor solver's own already-accepted
    // tolerance, correctly accepts it.
    try validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &before_m3, &.{}, &boundary_gain_m3, 0, 1e-9, &.{1}, &.{}, vapor_solver_absolute_tolerance_m3, vapor_solver_relative_tolerance);

    // (c) The NEW hybrid check still rejects a genuine violation larger than
    // the vapor solver's own accepted band (~1.9e-13 m3 here): inject an
    // extra 1e-11 m3 of unaccounted water into layer 0's after-state, two
    // orders of magnitude past what the solver's own tolerance can explain.
    grid.matrix_liquid_water_m3[0] += 1e-11;
    try std.testing.expectError(
        error.PerLayerPostRichardsTotalWaterClosureMismatch,
        validatePerLayerPostRichardsTotalWaterClosure(std.testing.allocator, &grid, &faces, &before_m3, &.{}, &boundary_gain_m3, 0, 1e-9, &.{1}, &.{}, vapor_solver_absolute_tolerance_m3, vapor_solver_relative_tolerance),
    );
}

test "post-phase boundary hook is source ordered before spatial heat" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/soil/water/heat_step.zig",
        allocator,
        .limited(512 * 1024),
    );
    defer allocator.free(source);
    const owner = std.mem.indexOf(u8, source, "pub fn advance(allocator:") orelse
        return error.MissingSoilWaterHeatTransaction;
    const owner_end = std.mem.indexOfPos(u8, source, owner, "fn fillCellEnthalpyMegajoules(") orelse
        return error.MissingSoilWaterHeatTransactionEnd;
    const body = source[owner..owner_end];
    const phase = std.mem.indexOf(u8, body, "const phase_result = try phase_solver.solve(") orelse
        return error.MissingSoilPhaseSolve;
    const boundary = std.mem.indexOfPos(u8, body, phase, "if (inputs.post_phase_pre_heat) |post_phase| try post_phase(") orelse
        return error.MissingPostPhaseBoundaryHook;
    const heat = std.mem.indexOfPos(u8, body, boundary, "const heat_result = try heat_solver.solveAndBindTransportFacesWithWorkspace(") orelse
        return error.MissingSpatialHeatSolve;
    const closure = std.mem.indexOfPos(u8, body, heat, "try validatePerLayerPostRichardsTotalWaterClosure(") orelse
        return error.MissingPostPhaseWaterClosure;
    try std.testing.expect(phase < boundary and boundary < heat and heat < closure);
}

test "external water flux is separated from conservative internal movement" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var snow = try @import("../solute/snow_solute_transport.zig").State.init(std.testing.allocator, 2, 1);
    defer snow.deinit();
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    faces.micropore_faces[0].water_flux_m3_per_step = 0.1;
    faces.macropore_faces[0].water_flux_m3_per_step = 0.02;
    grid.matrix_liquid_water_m3[0] = 0.85;
    grid.matrix_liquid_water_m3[1] = 1.1;
    grid.macropore_liquid_water_m3[0] = 0.98;
    grid.macropore_liquid_water_m3[1] = 1.01;
    try deriveExternalWaterFluxes(&grid, &hydrology, &faces, &.{ 1, 1 }, &.{ 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), hydrology.micropore_external_water_flux_m3_per_step[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), hydrology.micropore_external_water_flux_m3_per_step[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0), hydrology.macropore_external_water_flux_m3_per_step[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), hydrology.macropore_external_water_flux_m3_per_step[1], 1e-14);
}

test "per-cell water boundary closure catches two cells whose local errors cancel at landscape scale" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();

    // A landscape-only check sums residual_m3 = solver_gain_m3 + backed_out_outward_m3
    // over every cell; here cell 0's +0.5 and cell 1's -0.5 cancel exactly,
    // so a whole-domain sum sees 0 -- but both cells are individually wrong
    // by the same mechanism a face-to-wrong-neighbor bug would produce.
    hydrology.boundary_water_exchange_m3_per_step[0] = 0.5;
    hydrology.boundary_water_exchange_m3_per_step[1] = -0.5;
    // Leave micropore_external_water_flux_m3_per_step/macropore_... at their
    // zeroed init value: the solver's own boundary accounting claims a
    // nonzero exchange at each cell, but nothing backed out of storage
    // change/internal flux corroborates it -- exactly what the check exists
    // to catch.
    try std.testing.expectError(
        error.PerCellWaterBoundaryClosureMismatch,
        validatePerCellWaterBoundaryClosure(&grid, &hydrology, 0, 1e-8, &.{}, &.{}, &.{}, grid.matrix_liquid_water_m3, grid.macropore_liquid_water_m3),
    );

    const landscape_residual_m3 = hydrology.boundary_water_exchange_m3_per_step[0] +
        hydrology.boundary_water_exchange_m3_per_step[1];
    try std.testing.expectApproxEqAbs(@as(f64, 0), landscape_residual_m3, 1e-14);
}

test "per-cell water boundary closure is silent when the solver's own accounting agrees with the backed-out term" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();

    // Gain-positive solver claim and outward-positive backed-out term of
    // equal magnitude and opposite sign sum to ~zero: the two independent
    // measures agree, so this must NOT flag.
    hydrology.boundary_water_exchange_m3_per_step[0] = 0.5;
    hydrology.micropore_external_water_flux_m3_per_step[0] = -0.5;
    hydrology.boundary_water_exchange_m3_per_step[1] = 0;
    try validatePerCellWaterBoundaryClosure(&grid, &hydrology, 0, 1e-8, &.{}, &.{}, &.{}, grid.matrix_liquid_water_m3, grid.macropore_liquid_water_m3);
}

test "per-cell water boundary closure carries certified layer roundoff without changing the physical gate" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();

    hydrology.boundary_water_exchange_m3_per_step[0] = 1.5e-13;
    try std.testing.expectError(
        error.PerCellWaterBoundaryClosureMismatch,
        validatePerCellWaterBoundaryClosure(&grid, &hydrology, 0, 1e-8, &.{1}, &.{}, &.{0}, grid.matrix_liquid_water_m3, grid.macropore_liquid_water_m3),
    );
    try validatePerCellWaterBoundaryClosure(
        &grid,
        &hydrology,
        0,
        1e-8,
        &.{1},
        &.{},
        &.{2.0e-13},
        grid.matrix_liquid_water_m3,
        grid.macropore_liquid_water_m3,
    );
}

test "tiny domain water leak is not normalized against an arbitrary unit volume" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    grid.matrix_liquid_water_m3[0] = 1e-12;
    try std.testing.expectError(
        error.AcceptedRichardsWaterBoundaryImbalance,
        validateAcceptedWaterBoundaryBalance(&grid, &hydrology, &.{0}, &.{0}, 0, 1e-8, &.{1}),
    );
}

const RetryTransactionFixture = struct {
    grid: *grid_module.GridState,
    /// Stand-in for an independently owned snow carrier. Unlike grid state it
    /// is restored only by the transaction hook, so these tests detect a
    /// missing snow replay even when the soil snapshot is correct.
    snow_mass_m3: f64 = 0,
    initial_snow_mass_m3: f64 = 0,
    ground_air_vapor_m3: f64 = 0,
    initial_ground_air_vapor_m3: f64 = 0,
    private_ground_air_balance_m3: f64 = 0,
    surface_temperature_k: f64 = 280,
    initial_surface_temperature_k: f64 = 280,
    private_surface_energy_megajoules: f64 = 0,
    private_ledger: f64 = 0,
    accepted_calls: u8 = 0,
    restore_calls: u8 = 0,
    rollback_calls: u8 = 0,
    fail_accept_from_call: u8 = 0,
    fail_accept_nonretryable: bool = false,

    fn restoreSchedule(raw: *anyopaque) void {
        const self: *RetryTransactionFixture = @ptrCast(@alignCast(raw));
        self.restore_calls +|= 1;
        self.snow_mass_m3 = self.initial_snow_mass_m3;
        self.ground_air_vapor_m3 = self.initial_ground_air_vapor_m3;
        self.private_ground_air_balance_m3 = 0;
        self.surface_temperature_k = self.initial_surface_temperature_k;
        self.private_surface_energy_megajoules = 0;
        self.private_ledger = 0;
    }

    fn rollbackFailure(raw: *anyopaque) void {
        const self: *RetryTransactionFixture = @ptrCast(@alignCast(raw));
        self.snow_mass_m3 = self.initial_snow_mass_m3;
        self.ground_air_vapor_m3 = self.initial_ground_air_vapor_m3;
        self.private_ground_air_balance_m3 = 0;
        self.surface_temperature_k = self.initial_surface_temperature_k;
        self.private_surface_energy_megajoules = 0;
        self.private_ledger = 0;
        self.rollback_calls +|= 1;
    }

    fn prepareSubstep(raw: *anyopaque, time_step_hours: f64) !void {
        const self: *RetryTransactionFixture = @ptrCast(@alignCast(raw));
        self.grid.matrix_liquid_water_m3[0] += time_step_hours;
        self.snow_mass_m3 += time_step_hours;
        self.ground_air_vapor_m3 += time_step_hours;
        self.private_ground_air_balance_m3 += time_step_hours;
        self.surface_temperature_k += 2 * time_step_hours;
        self.private_surface_energy_megajoules += 3 * time_step_hours;
        self.private_ledger += time_step_hours;
    }

    fn acceptSubstep(raw: *anyopaque, _: f64) !void {
        const self: *RetryTransactionFixture = @ptrCast(@alignCast(raw));
        self.accepted_calls +|= 1;
        if (self.fail_accept_nonretryable)
            return error.LitterSoilInterfaceDimensionMismatch;
        if (self.fail_accept_from_call > 0 and self.accepted_calls >= self.fail_accept_from_call)
            return error.ForcedSoilSubstepFailure;
    }

    fn hooks(self: *RetryTransactionFixture) SubstepTransactionHooks {
        return .{
            .context = @ptrCast(self),
            .restore_schedule = restoreSchedule,
            .rollback_failure = rollbackFailure,
            .prepare_substep = prepareSubstep,
            .accept_substep = acceptSubstep,
        };
    }
};

fn testThermalState(shared: []f64) thermal_module.State {
    return .{
        .allocator = std.testing.allocator,
        .cell_count = 1,
        .soil_layer_capacity = 1,
        .layer_volume_m3 = shared,
        .layer_thickness_m = shared,
        .porosity_fraction = shared,
        .dry_solid_heat_capacity_megajoules_per_m3_k = shared,
        .solid_thermal_conductivity_numerator_m_megajoules_per_h_k = shared,
        .solid_thermal_conductivity_denominator = shared,
        .total_heat_capacity_megajoules_per_m3_k = shared,
        .thermal_conductivity_m_megajoules_per_h_k = shared,
    };
}

fn runSyntheticRetry(
    grid: *grid_module.GridState,
    hydrology: *hydrology_module.State,
    faces: *hydrology_module.SoilFaces,
    workspace: *workspace_module.State,
    thermal: *thermal_module.State,
    transaction: *RetryTransactionFixture,
    control: *TestSubstepControl,
) !DeferredMappedResult {
    return runSyntheticRetryBound(grid, hydrology, faces, workspace, thermal, transaction, control, &.{});
}

fn runSyntheticRetryBound(
    grid: *grid_module.GridState,
    hydrology: *hydrology_module.State,
    faces: *hydrology_module.SoilFaces,
    workspace: *workspace_module.State,
    thermal: *thermal_module.State,
    transaction: *RetryTransactionFixture,
    control: *TestSubstepControl,
    phase_displacement_by_layer: []PhaseDisplacement,
) !DeferredMappedResult {
    return runSyntheticRetryBoundWithReferenceHeat(
        grid,
        hydrology,
        faces,
        workspace,
        thermal,
        transaction,
        control,
        phase_displacement_by_layer,
        &.{},
    );
}

fn runSyntheticRetryBoundWithReferenceHeat(
    grid: *grid_module.GridState,
    hydrology: *hydrology_module.State,
    faces: *hydrology_module.SoilFaces,
    workspace: *workspace_module.State,
    thermal: *thermal_module.State,
    transaction: *RetryTransactionFixture,
    control: *TestSubstepControl,
    phase_displacement_by_layer: []PhaseDisplacement,
    phase_endpoint_reference_heat_megajoules_by_layer: []f64,
) !DeferredMappedResult {
    return runSyntheticRetryBoundWithReferenceHeatAllocator(
        std.testing.allocator,
        grid,
        hydrology,
        faces,
        workspace,
        thermal,
        transaction,
        control,
        phase_displacement_by_layer,
        phase_endpoint_reference_heat_megajoules_by_layer,
    );
}

fn runSyntheticRetryBoundWithReferenceHeatAllocator(
    allocator: std.mem.Allocator,
    grid: *grid_module.GridState,
    hydrology: *hydrology_module.State,
    faces: *hydrology_module.SoilFaces,
    workspace: *workspace_module.State,
    thermal: *thermal_module.State,
    transaction: *RetryTransactionFixture,
    control: *TestSubstepControl,
    phase_displacement_by_layer: []PhaseDisplacement,
    phase_endpoint_reference_heat_megajoules_by_layer: []f64,
) !DeferredMappedResult {
    var unused_geometry: face_geometry_module.State = undefined;
    var unused_properties: solver_properties_module.State = undefined;
    var unused_heat_workspace: heat_solver.Workspace = undefined;
    return advanceMappedDeferred(
        allocator,
        grid,
        hydrology,
        faces,
        &unused_geometry,
        &unused_properties,
        workspace,
        thermal,
        &unused_heat_workspace,
        undefined,
        .{
            .max_iterations = 1,
            .picard_relaxation = 0.5,
            .vapor_pore_tortuosity = 0.66,
            .osmotic_reflection_coefficient = 0.03,
            .water_absolute_tolerance_m3 = 1e-11,
            .temperature_absolute_tolerance_k = 1e-9,
            .enthalpy_absolute_tolerance_megajoules = 1e-8,
            .nonlinear_relative_tolerance = 1e-8,
            .dense_newton_max_components = 1,
            .test_substep_control = control,
            .substep_transaction_hooks = transaction.hooks(),
            .exact_substep_count = control.exact_substep_count,
            .phase_displacement_by_layer = phase_displacement_by_layer,
            .phase_endpoint_reference_heat_megajoules_by_layer = phase_endpoint_reference_heat_megajoules_by_layer,
        },
    );
}

fn exerciseDeferredOwnersForAllocationFailure(allocator: std.mem.Allocator) !void {
    var outputs = DeferredOutputOwner.init(allocator);
    defer outputs.deinit();
    var scratch = RecoveryScratch.init(allocator);
    defer scratch.deinit();
    try allocateDeferredRecoveryBuffers(&outputs, &scratch, 2, 3, 3);
    outputs.grid_delta_by_layer_carrier = try allocator.alloc(
        f64,
        3 * deferred_grid_carrier_count,
    );

    @memset(outputs.grid_delta_by_layer_carrier.?, 0);
    @memset(outputs.external_water_advective_enthalpy_outward_megajoules_by_cell.?, 0);
    @memset(outputs.external_water_advective_enthalpy_outward_megajoules_by_layer.?, 0);
    @memset(outputs.boundary_heat_input_megajoules_by_cell.?, 0);
    @memset(outputs.boundary_heat_output_megajoules_by_cell.?, 0);
    @memset(outputs.phase_displacement_by_layer.?, .{});
    @memset(outputs.phase_endpoint_reference_heat_megajoules_by_layer.?, 0);

    var result = outputs.take(
        emptyTestResult(),
        4,
        false,
        .{ .accepted_substeps = 4 },
    );
    defer result.deinit();
    try std.testing.expectEqual(result.phase_displacement_by_layer.ptr, result.solver.phase_displacement_by_layer.ptr);
    try std.testing.expectEqual(@as(usize, 3 * deferred_grid_carrier_count), result.grid_delta_by_layer_carrier.len);
    try std.testing.expectEqual(@as(usize, 3), result.phase_displacement_by_layer.len);
    try std.testing.expect(outputs.grid_delta_by_layer_carrier == null);
    try std.testing.expect(outputs.phase_displacement_by_layer == null);

    // Explicit cleanup followed by the registered defers proves both owners
    // disarm deterministically rather than freeing a transferred/old buffer.
    outputs.deinit();
    scratch.deinit();
}

test "deferred recovery owners release every partial allocation and transfer once" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeferredOwnersForAllocationFailure,
        .{},
    );
}

fn exerciseDeferredRecoveryAllocationFailure(allocator: std.mem.Allocator) !void {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    grid.matrix_liquid_water_m3[0] = 2;
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    hydrology.boundary_water_exchange_m3_per_step[0] = 7;
    hydrology.boundary_water_exchange_m3_per_layer_per_step[0] = -13;
    hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[0] = 17;
    hydrology.micropore_external_water_flux_m3_per_step[0] = 11;
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var transaction: RetryTransactionFixture = .{
        .grid = &grid,
        .snow_mass_m3 = 3,
        .initial_snow_mass_m3 = 3,
        .ground_air_vapor_m3 = 5,
        .initial_ground_air_vapor_m3 = 5,
    };
    var control: TestSubstepControl = .{
        .succeed_without_solving = true,
        .exact_substep_count = 1,
    };
    var phase_displacement = [_]PhaseDisplacement{.{ .matrix_liquid_water_m3 = 99 }};
    var phase_reference_heat = [_]f64{99};

    var result = runSyntheticRetryBoundWithReferenceHeatAllocator(
        allocator,
        &grid,
        &hydrology,
        &faces,
        &workspace,
        &thermal,
        &transaction,
        &control,
        &phase_displacement,
        &phase_reference_heat,
    ) catch |err| {
        try std.testing.expectEqual(@as(f64, 2), grid.matrix_liquid_water_m3[0]);
        try std.testing.expectEqual(@as(f64, 7), hydrology.boundary_water_exchange_m3_per_step[0]);
        try std.testing.expectEqual(@as(f64, -13), hydrology.boundary_water_exchange_m3_per_layer_per_step[0]);
        try std.testing.expectEqual(@as(f64, 17), hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[0]);
        try std.testing.expectEqual(@as(f64, 11), hydrology.micropore_external_water_flux_m3_per_step[0]);
        try std.testing.expectEqual(@as(f64, 3), transaction.snow_mass_m3);
        try std.testing.expectEqual(@as(f64, 5), transaction.ground_air_vapor_m3);
        try std.testing.expectEqual(PhaseDisplacement{}, phase_displacement[0]);
        try std.testing.expectEqual(@as(f64, 0), phase_reference_heat[0]);
        return err;
    };
    defer result.deinit();
    try std.testing.expectEqual(result.phase_displacement_by_layer.ptr, result.solver.phase_displacement_by_layer.ptr);
    try std.testing.expectEqual(@as(f64, 2), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(PhaseDisplacement{}, phase_displacement[0]);
    try std.testing.expectEqual(@as(f64, 0), phase_reference_heat[0]);
}

test "deferred recovery allocation failure leaves no scientific side effects" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDeferredRecoveryAllocationFailure,
        .{},
    );
}

test "live accepted delta removes exactly one 38-allocation snapshot" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 2;
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    try std.testing.expectEqual(@as(usize, 1), faces.micropore_faces.len);
    var workspace = try workspace_module.State.init(std.testing.allocator, 2);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{ 0, 0 };
    var thermal = testThermalState(&thermal_buffer);
    thermal.soil_layer_capacity = 2;
    var transaction: RetryTransactionFixture = .{ .grid = &grid };
    var control: TestSubstepControl = .{
        .succeed_without_solving = true,
        .exact_substep_count = 1,
    };
    var phase_displacement = [_]PhaseDisplacement{.{}} ** 2;
    var phase_reference_heat = [_]f64{0} ** 2;

    const snapshot_allocation_count = comptime count: {
        var allocations: usize = 0;
        for (@typeInfo(Snapshot).@"struct".fields) |field| {
            if (field.type == []f64 or field.type == []solute.Face) {
                allocations += 1;
            }
        }
        break :count allocations;
    };
    const coefficient_allocation_count =
        workspace_state_slice_descriptors.len + thermal_state_slice_descriptors.len;
    // `allocateDeferredRecoveryBuffers` performs one `allocator.alloc` per line in
    // its body: 29 today, after the water- and heat-storage
    // roundoff-allowance provenance buffer groups (3 allocations each: outputs,
    // schedule, substep) were added for conservation tracking, and after
    // issue-068 (fourth round, 2026-09-20) added a third such group -- outputs,
    // schedule, and substep buffers for
    // `renormalization_floor_discard_megajoules_by_layer` -- for the same
    // reason (+3, from 26). This constant is deliberately hardcoded, not
    // computed, so any future change to that function's allocation count must
    // be re-verified here rather than silently absorbed.
    const deferred_buffer_allocation_count: usize = 29;
    const grid_delta_allocation_count: usize = 1;
    const former_success_allocation_count =
        3 * snapshot_allocation_count +
        coefficient_allocation_count +
        deferred_buffer_allocation_count +
        grid_delta_allocation_count;
    const live_success_allocation_count =
        former_success_allocation_count - snapshot_allocation_count;
    try std.testing.expectEqual(@as(usize, 38), snapshot_allocation_count);
    try std.testing.expectEqual(
        @as(usize, 38),
        former_success_allocation_count - live_success_allocation_count,
    );

    var allocation_counter = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{},
    );
    {
        var result = try runSyntheticRetryBoundWithReferenceHeatAllocator(
            allocation_counter.allocator(),
            &grid,
            &hydrology,
            &faces,
            &workspace,
            &thermal,
            &transaction,
            &control,
            &phase_displacement,
            &phase_reference_heat,
        );
        defer result.deinit();
        try std.testing.expectEqual(live_success_allocation_count, allocation_counter.alloc_index);
        // issue-068 (fourth round): 139, not 136 -- see
        // `deferred_buffer_allocation_count`'s updated comment above.
        try std.testing.expectEqual(@as(usize, 139), allocation_counter.alloc_index);
        try std.testing.expectEqual(
            @as(usize, 2 * deferred_grid_carrier_count),
            result.grid_delta_by_layer_carrier.len,
        );
        for (result.grid_delta_by_layer_carrier, 0..) |actual, index| {
            const expected: f64 = if (index == 0) 1 else 0;
            try std.testing.expectEqual(
                @as(u64, @bitCast(expected)),
                @as(u64, @bitCast(actual)),
            );
        }
    }
    try std.testing.expectEqual(
        allocation_counter.allocated_bytes,
        allocation_counter.freed_bytes,
    );
}

test "deferred owner schedules 1 2 4 and 64 preserve bitwise results" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var baseline_delta: [deferred_grid_carrier_count]f64 = undefined;
    var baseline_transaction: [5]f64 = undefined;

    for ([_]u8{ 1, 2, 4, 64 }, 0..) |substeps, schedule_index| {
        var transaction: RetryTransactionFixture = .{ .grid = &grid };
        var control: TestSubstepControl = .{
            .succeed_without_solving = true,
            .exact_substep_count = substeps,
        };
        var result = try runSyntheticRetry(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control);
        defer result.deinit();
        for (result.grid_delta_by_layer_carrier, 0..) |actual, carrier| {
            const expected: f64 = if (carrier == 0) 1 else 0;
            try std.testing.expectEqual(
                @as(u64, @bitCast(expected)),
                @as(u64, @bitCast(actual)),
            );
        }
        const transaction_values = [5]f64{
            transaction.snow_mass_m3,
            transaction.ground_air_vapor_m3,
            transaction.surface_temperature_k,
            transaction.private_surface_energy_megajoules,
            transaction.private_ledger,
        };
        if (schedule_index == 0) {
            @memcpy(&baseline_delta, result.grid_delta_by_layer_carrier);
            baseline_transaction = transaction_values;
        } else {
            for (baseline_delta, result.grid_delta_by_layer_carrier) |expected, actual|
                try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
            for (baseline_transaction, transaction_values) |expected, actual|
                try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
        }
        try std.testing.expectEqual(result.phase_displacement_by_layer.ptr, result.solver.phase_displacement_by_layer.ptr);
        try std.testing.expectEqual(substeps, result.accepted_substeps);
    }
}

test "phase endpoint reference heat follows source-derived WATSUB coordinate conversion" {
    const ice_change_m3 = 0.002;
    const vapor_change_m3 = -0.001;
    const liquid_capacity = 4.185;
    const ice_capacity = 1.93;
    const melting_temperature_k = 273.15;
    const vaporization_latent = 2500.0;
    const expected = (liquid_capacity - ice_capacity) * melting_temperature_k *
        ice_change_m3 - vaporization_latent * vapor_change_m3;
    try std.testing.expectApproxEqAbs(
        expected,
        try phaseEndpointReferenceHeatMegajoules(
            ice_change_m3,
            vapor_change_m3,
            liquid_capacity,
            ice_capacity,
            melting_temperature_k,
            vaporization_latent,
        ),
        32 * std.math.floatEps(f64) * @max(1, @abs(expected)),
    );
    try std.testing.expectError(
        error.NonFiniteSoilPhaseReferenceHeat,
        phaseEndpointReferenceHeatMegajoules(
            std.math.nan(f64),
            0,
            liquid_capacity,
            ice_capacity,
            melting_temperature_k,
            vaporization_latent,
        ),
    );
}

test "vapor-only transport temperature rebase preserves each layer canonical enthalpy" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 2;
    grid.soil_temperature_k[0] = 270;
    grid.soil_temperature_k[1] = 280;
    grid.matrix_liquid_water_m3[0] = 0.1;
    grid.matrix_liquid_water_m3[1] = 0.2;
    grid.water_vapor_volume_m3[0] = 0.001;
    grid.water_vapor_volume_m3[1] = 0.002;
    const dry_capacity = [_]f64{ 2, 3 };
    const liquid_capacity = 4.185;
    const ice_capacity = 1.93;
    const fusion_latent = 333.55;
    const melting_temperature_k = 273.15;
    const before = [_]f64{
        cellEnthalpyMegajoules(&grid, 0, dry_capacity[0], liquid_capacity, ice_capacity, fusion_latent, melting_temperature_k),
        cellEnthalpyMegajoules(&grid, 1, dry_capacity[1], liquid_capacity, ice_capacity, fusion_latent, melting_temperature_k),
    };

    grid.water_vapor_volume_m3[0] -= 0.0001;
    grid.water_vapor_volume_m3[1] += 0.0001;
    try renormalizeTemperatureToFixedCellEnthalpy(
        &before,
        &grid,
        &dry_capacity,
        liquid_capacity,
        ice_capacity,
        fusion_latent,
        melting_temperature_k,
        &.{},
        &.{},
    );

    try std.testing.expect(grid.soil_temperature_k[0] > 270);
    try std.testing.expect(grid.soil_temperature_k[1] < 280);
    for (before, 0..) |expected, layer| {
        const after = cellEnthalpyMegajoules(
            &grid,
            layer,
            dry_capacity[layer],
            liquid_capacity,
            ice_capacity,
            fusion_latent,
            melting_temperature_k,
        );
        try std.testing.expectApproxEqAbs(
            expected,
            after,
            64 * std.math.floatEps(f64) * @max(1, @abs(expected)),
        );
    }
}

test "issue-068 (second round): renormalized cell enthalpy inversion rejects an out-of-domain temperature for a near-zero-capacity layer" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.soil_temperature_k[0] = 280;
    // Chronically near-desiccated layer, matching hour 2,895's own cell
    // 0/layer 0 (`total_heat_capacity_megajoules_per_k` in the `2e-5` range
    // against WATSUB's own `VHCPRX` floor of `8.38e-5`).
    grid.matrix_liquid_water_m3[0] = 0;
    grid.matrix_ice_water_m3[0] = 0;
    grid.macropore_liquid_water_m3[0] = 0;
    grid.macropore_ice_water_m3[0] = 0;
    grid.water_vapor_volume_m3[0] = 0;
    const dry_capacity: f64 = 2.03e-5;
    const liquid_capacity = 4.185;
    const ice_capacity = 1.93;
    const fusion_latent = 333.55;
    const melting_temperature_k = 273.15;
    // A 5e-3 MJ mismatch is unremarkable at ordinary heat capacities; divided
    // by this near-zero capacity it reaches ~526 K, well outside the
    // [173.15, 373.15] K band -- the exact "small residual over a
    // chronically near-zero heat capacity" mechanism this issue's own
    // diagnostic captured, but reached here through the renormalization
    // inversion rather than the dense Newton/Anderson solver's commit path.
    const target_megajoules = dry_capacity * 280.0 + 5.0e-3;
    // issue-068 (fourth round): `cell_area_m2 = 0` deliberately disables the
    // fourth round's hold-don't-divide floor guard (matching every other
    // diagnostics-disabled caller in this file that passes an empty
    // `cell_area_m2`), so this call still exercises the RAW division this
    // issue chain originally captured producing an out-of-domain temperature
    // -- proof the pre-existing division mechanism is unchanged when the new
    // floor guard is not wired in.
    try std.testing.expectError(
        error.SoilHeatRenormalizedTemperatureOutsidePhysicalDomain,
        temperatureForCellEnthalpy(
            target_megajoules,
            &grid,
            0,
            dry_capacity,
            liquid_capacity,
            ice_capacity,
            fusion_latent,
            melting_temperature_k,
            0,
            &.{},
        ),
    );
}

test "issue-068 (fourth round): temperatureForCellEnthalpy holds the prior temperature and books the discrepancy instead of dividing by a near-zero heat capacity" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.soil_temperature_k[0] = 280;
    // Chronically near-desiccated layer, matching hour 2,895's own cell
    // 0/layer 0 (`total_heat_capacity_megajoules_per_k` in the `2e-5` range
    // against WATSUB's own `VHCPRX` floor of `8.38e-5 * area`).
    grid.matrix_liquid_water_m3[0] = 0;
    grid.matrix_ice_water_m3[0] = 0;
    grid.macropore_liquid_water_m3[0] = 0;
    grid.macropore_ice_water_m3[0] = 0;
    grid.water_vapor_volume_m3[0] = 0;
    const dry_capacity: f64 = 2.03e-5;
    const liquid_capacity = 4.185;
    const ice_capacity = 1.93;
    const fusion_latent = 333.55;
    const melting_temperature_k = 273.15;
    // Same 5e-3 MJ mismatch as the previous test, which the OLD code (or this
    // code with the floor disabled) resolves to ~526 K. `cell_area_m2 = 1`
    // puts `negligible_capacity_limit_megajoules_per_k =
    // 8.38e-5 * 1 = 8.38e-5`, comfortably above this layer's `2.03e-5`
    // capacity, so the floor guard is live.
    const target_megajoules = dry_capacity * 280.0 + 5.0e-3;
    var discard_by_layer = [_]f64{0};
    const result = try temperatureForCellEnthalpy(
        target_megajoules,
        &grid,
        0,
        dry_capacity,
        liquid_capacity,
        ice_capacity,
        fusion_latent,
        melting_temperature_k,
        1,
        &discard_by_layer,
    );
    // Held the PRIOR temperature exactly, not the absurd ~526 K division.
    try std.testing.expectEqual(@as(f64, 280), result);
    try std.testing.expect(!heat_solver.isPhysicalTemperatureK(526));
    // The booked discrepancy equals target - (coefficient*held + fusion
    // offset); with zero ice/water, fusion offset is zero and the
    // coefficient is exactly `dry_capacity`.
    const expected_discard = target_megajoules - dry_capacity * 280.0;
    try std.testing.expectApproxEqAbs(expected_discard, discard_by_layer[0], 1e-15);

    // Second call in the same hour accumulates rather than overwrites.
    _ = try temperatureForCellEnthalpy(
        target_megajoules,
        &grid,
        0,
        dry_capacity,
        liquid_capacity,
        ice_capacity,
        fusion_latent,
        melting_temperature_k,
        1,
        &discard_by_layer,
    );
    try std.testing.expectApproxEqAbs(2 * expected_discard, discard_by_layer[0], 1e-15);
}

test "issue-068 (fourth round): an empty renormalization_floor_discard_megajoules_by_layer disables booking but still holds" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.soil_temperature_k[0] = 280;
    grid.matrix_liquid_water_m3[0] = 0;
    grid.matrix_ice_water_m3[0] = 0;
    grid.macropore_liquid_water_m3[0] = 0;
    grid.macropore_ice_water_m3[0] = 0;
    grid.water_vapor_volume_m3[0] = 0;
    const dry_capacity: f64 = 2.03e-5;
    const target_megajoules = dry_capacity * 280.0 + 5.0e-3;
    const result = try temperatureForCellEnthalpy(
        target_megajoules,
        &grid,
        0,
        dry_capacity,
        4.185,
        1.93,
        333.55,
        273.15,
        1,
        &.{},
    );
    try std.testing.expectEqual(@as(f64, 280), result);
}

test "issue-068 (second round): renormalized cell enthalpy inversion is a no-op for an ordinary in-domain layer" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.soil_temperature_k[0] = 280;
    grid.matrix_liquid_water_m3[0] = 0.1;
    grid.matrix_ice_water_m3[0] = 0;
    grid.macropore_liquid_water_m3[0] = 0;
    grid.macropore_ice_water_m3[0] = 0;
    grid.water_vapor_volume_m3[0] = 0.001;
    const dry_capacity: f64 = 2.0;
    const liquid_capacity = 4.185;
    const ice_capacity = 1.93;
    const fusion_latent = 333.55;
    const melting_temperature_k = 273.15;
    const before = cellEnthalpyMegajoules(&grid, 0, dry_capacity, liquid_capacity, ice_capacity, fusion_latent, melting_temperature_k);
    // A small, ordinary energy nudge stays deep inside the physical domain at
    // this layer's normal (non-degenerate) heat capacity.
    const target_megajoules = before + 1.0e-3;
    // issue-068 (fourth round): a nonzero `cell_area_m2` and a live discard
    // ledger are supplied here too (not just `0`/`&.{}` as elsewhere) to
    // prove the fourth round's floor guard is a genuine no-op for an
    // ordinary, well-above-floor layer -- `dry_capacity=2.0` is far above
    // `negligible_capacity_limit_megajoules_per_k = 8.38e-5 * 1`.
    var discard_by_layer = [_]f64{0};
    const result = try temperatureForCellEnthalpy(
        target_megajoules,
        &grid,
        0,
        dry_capacity,
        liquid_capacity,
        ice_capacity,
        fusion_latent,
        melting_temperature_k,
        1,
        &discard_by_layer,
    );
    try std.testing.expect(result > 279 and result < 281);
    try std.testing.expectEqual(@as(f64, 0), discard_by_layer[0]);
}

test "issue-068 (second round): the renormalized-temperature domain error is fixed-hour dt recoverable" {
    try std.testing.expect(isFixedHourDtRecoveryFailure(error.SoilHeatRenormalizedTemperatureOutsidePhysicalDomain));
    try std.testing.expect(isRetryableSolverFailure(error.SoilHeatRenormalizedTemperatureOutsidePhysicalDomain));
}

test "issue-068 (sixth round): the phase solver's own out-of-domain endpoint temperature error is fixed-hour dt recoverable" {
    try std.testing.expect(isFixedHourDtRecoveryFailure(error.SoilPhaseSolverTemperatureOutsidePhysicalDomain));
    try std.testing.expect(isRetryableSolverFailure(error.SoilPhaseSolverTemperatureOutsidePhysicalDomain));
}

test "mapped soil solve retains unit-specific nonlinear floors" {
    const options: MappedOptions = .{
        .max_iterations = 4,
        .picard_relaxation = 0.5,
        .vapor_pore_tortuosity = 0.66,
        .osmotic_reflection_coefficient = 0.03,
        .water_absolute_tolerance_m3 = 1e-13,
        .temperature_absolute_tolerance_k = 1e-9,
        .enthalpy_absolute_tolerance_megajoules = 1e-10,
        .nonlinear_relative_tolerance = 1e-8,
        .dense_newton_max_components = 1,
    };
    try std.testing.expect(options.water_absolute_tolerance_m3 != options.temperature_absolute_tolerance_k);
    try std.testing.expect(options.temperature_absolute_tolerance_k != options.enthalpy_absolute_tolerance_megajoules);
}

test "heat-induced phase refinement uses scaled local tolerance without cancellation" {
    const below_representation = HeatInducedIceChange{
        .matrix_water_equivalent_m3 = 1024 * std.math.floatEps(f64),
        .macropore_water_equivalent_m3 = 0,
    };
    try std.testing.expect(!phaseChangeExceedsLocalWaterTolerance(
        below_representation,
        1,
        1,
        0,
        1e-16,
    ));

    // Equal and opposite matrix/macropore changes have zero signed total but
    // alter both hydraulic impedances and therefore must trigger refinement.
    const pore_domain_cancellation = HeatInducedIceChange{
        .matrix_water_equivalent_m3 = 5e-5,
        .macropore_water_equivalent_m3 = -5e-5,
    };
    try std.testing.expect(phaseChangeExceedsLocalWaterTolerance(
        pore_domain_cancellation,
        1,
        2,
        1e-7,
        1e-6,
    ));

    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 2, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 2;
    @memset(grid.matrix_liquid_water_m3, 0.25);
    const opposite_layers = [_]HeatInducedIceChange{
        .{ .matrix_water_equivalent_m3 = 1e-4 },
        .{ .matrix_water_equivalent_m3 = -1e-4 },
    };
    try std.testing.expect(try hasSignificantHeatInducedPhaseChange(
        &grid,
        &opposite_layers,
        1e-9,
        1e-8,
        &.{1},
    ));
    try std.testing.expect(isRetryableSolverFailure(
        error.HeatInducedPhaseChangeRequiresQuarterHourSubsteps,
    ));
}

test "exact recovery schedule runs only four quarter-hour Newton-Anderson substeps" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var transaction: RetryTransactionFixture = .{ .grid = &grid };
    var control: TestSubstepControl = .{
        .succeed_without_solving = true,
        .exact_substep_count = 4,
        .water_storage_roundoff_allowance_m3_by_layer = &.{1.0e-15},
        .heat_storage_roundoff_allowance_megajoules_by_layer = &.{2.0e-12},
    };

    var result = try runSyntheticRetry(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.accepted_substeps);
    try std.testing.expect(!result.had_significant_heat_induced_phase_change);
    try std.testing.expectEqual(@as(u8, 4), control.attempts);
    try std.testing.expectEqual(@as(u8, 1), transaction.restore_calls);
    try std.testing.expectEqual(@as(u8, 4), transaction.accepted_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.snow_mass_m3, 64 * std.math.floatEps(f64));
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ledger, 64 * std.math.floatEps(f64));
    try std.testing.expect(result.water_storage_roundoff_allowance_m3_by_layer[0] >= 4.0e-15);
    try std.testing.expect(result.heat_storage_roundoff_allowance_megajoules_by_layer[0] >= 8.0e-12);
}

test "accepted substeps aggregate phase displacement transactionally by layer and domain" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var transaction: RetryTransactionFixture = .{ .grid = &grid };
    const per_substep = [_]PhaseDisplacement{.{
        .matrix_liquid_water_m3 = 0.01,
        .matrix_ice_water_equivalent_m3 = 0.02,
        .macropore_liquid_water_m3 = 0.03,
        .macropore_ice_water_equivalent_m3 = 0.04,
        .advective_enthalpy_megajoules = 1.25,
    }};
    var published = [_]PhaseDisplacement{.{
        .matrix_liquid_water_m3 = 99,
        .advective_enthalpy_megajoules = 99,
    }};
    const reference_per_substep = [_]f64{0.25};
    var published_reference = [_]f64{99};
    var control: TestSubstepControl = .{
        .succeed_without_solving = true,
        .exact_substep_count = 4,
        .phase_displacement_by_layer = &per_substep,
        .phase_endpoint_reference_heat_megajoules_by_layer = &reference_per_substep,
    };
    var result = try runSyntheticRetryBoundWithReferenceHeat(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control, &published, &published_reference);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.accepted_substeps);
    try std.testing.expectEqual(result.phase_displacement_by_layer.ptr, result.solver.phase_displacement_by_layer.ptr);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), published[0].matrix_liquid_water_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), published[0].matrix_ice_water_equivalent_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), published[0].macropore_liquid_water_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.16), published[0].macropore_ice_water_equivalent_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 5), published[0].advective_enthalpy_megajoules, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), published_reference[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.phase_endpoint_reference_heat_megajoules_by_layer[0], 1e-15);
}

test "rejected phase displacement schedule publishes no recipient credit" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var transaction: RetryTransactionFixture = .{ .grid = &grid, .fail_accept_from_call = 2 };
    const per_substep = [_]PhaseDisplacement{.{ .matrix_liquid_water_m3 = 0.01, .advective_enthalpy_megajoules = 1 }};
    var published = [_]PhaseDisplacement{.{ .matrix_liquid_water_m3 = 99, .advective_enthalpy_megajoules = 99 }};
    const reference_per_substep = [_]f64{0.25};
    var published_reference = [_]f64{99};
    var control: TestSubstepControl = .{
        .succeed_without_solving = true,
        .exact_substep_count = 2,
        .phase_displacement_by_layer = &per_substep,
        .phase_endpoint_reference_heat_megajoules_by_layer = &reference_per_substep,
    };
    try std.testing.expectError(error.ForcedSoilSubstepFailure, runSyntheticRetryBoundWithReferenceHeat(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control, &published, &published_reference));
    try std.testing.expectEqual(PhaseDisplacement{}, published[0]);
    try std.testing.expectEqual(@as(f64, 0), published_reference[0]);
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_liquid_water_m3[0]);
}

test "heat-induced phase change rejects coarse schedules and rolls back before four quarter-hours" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var transaction: RetryTransactionFixture = .{ .grid = &grid };
    const local_phase_change = [_]HeatInducedIceChange{.{
        .matrix_water_equivalent_m3 = 1e-4,
        .macropore_water_equivalent_m3 = -1e-4,
    }};
    var control: TestSubstepControl = .{
        .succeed_without_solving = true,
        .heat_induced_ice_change_by_layer = &local_phase_change,
    };

    var result = try runSyntheticRetry(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 4), result.accepted_substeps);
    try std.testing.expect(result.had_significant_heat_induced_phase_change);
    // The 60-minute and first 30-minute solves detect the local phase signal
    // before accept; only the four accepted 15-minute solves reach the hook.
    try std.testing.expectEqual(@as(u8, 6), control.attempts);
    try std.testing.expectEqual(@as(u8, 3), transaction.restore_calls);
    try std.testing.expectEqual(@as(u8, 4), transaction.accepted_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.grid_delta_by_layer_carrier[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.snow_mass_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.ground_air_vapor_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ground_air_balance_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 282), transaction.surface_temperature_k, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), transaction.private_surface_energy_megajoules, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ledger, 1e-15);
    try std.testing.expectEqual(@as(u8, 0), transaction.rollback_calls);
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_liquid_water_m3[0]);
}

test "failed hourly solve rolls back before two accepted half-hour substeps" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var transaction: RetryTransactionFixture = .{ .grid = &grid };
    var control: TestSubstepControl = .{ .fail_time_step_hours_above = 0.5, .succeed_without_solving = true };

    var result = try runSyntheticRetry(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 2), result.accepted_substeps);
    try std.testing.expectEqual(@as(u8, 3), control.attempts);
    try std.testing.expectApproxEqAbs(@as(f64, 1), result.grid_delta_by_layer_carrier[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.snow_mass_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.ground_air_vapor_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ground_air_balance_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 282), transaction.surface_temperature_k, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), transaction.private_surface_energy_megajoules, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ledger, 1e-15);
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_liquid_water_m3[0]);
}

test "second half failure exhausts finer schedules with exact rollback and restart equivalence" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var transaction: RetryTransactionFixture = .{ .grid = &grid, .fail_accept_from_call = 2 };
    var control: TestSubstepControl = .{ .fail_time_step_hours_above = 0.5, .succeed_without_solving = true };

    try std.testing.expectError(
        error.ForcedSoilSubstepFailure,
        runSyntheticRetry(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control),
    );
    try std.testing.expectEqual(@as(f64, 0), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0), transaction.snow_mass_m3);
    try std.testing.expectEqual(@as(f64, 0), transaction.ground_air_vapor_m3);
    try std.testing.expectEqual(@as(f64, 0), transaction.private_ground_air_balance_m3);
    try std.testing.expectEqual(@as(f64, 280), transaction.surface_temperature_k);
    try std.testing.expectEqual(@as(f64, 0), transaction.private_surface_energy_megajoules);
    try std.testing.expectEqual(@as(f64, 0), transaction.private_ledger);
    try std.testing.expectEqual(@as(u8, 1), transaction.rollback_calls);

    transaction = .{ .grid = &grid };
    control = .{ .fail_time_step_hours_above = 0.5, .succeed_without_solving = true };
    var restarted = try runSyntheticRetry(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control);
    defer restarted.deinit();
    try std.testing.expectEqual(@as(u8, 2), restarted.accepted_substeps);
    try std.testing.expectApproxEqAbs(@as(f64, 1), restarted.grid_delta_by_layer_carrier[0], 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.snow_mass_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.ground_air_vapor_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ground_air_balance_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 282), transaction.surface_temperature_k, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 3), transaction.private_surface_energy_megajoules, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ledger, 1e-15);
}

test "nonretryable accept hook dimension failure rolls back once without recovery budget burn" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    grid.matrix_liquid_water_m3[0] = 2;
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    hydrology.boundary_water_exchange_m3_per_step[0] = 7;
    hydrology.boundary_water_exchange_m3_per_layer_per_step[0] = -13;
    hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[0] = 17;
    hydrology.micropore_external_water_flux_m3_per_step[0] = 11;
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);
    var transaction: RetryTransactionFixture = .{
        .grid = &grid,
        .snow_mass_m3 = 3,
        .initial_snow_mass_m3 = 3,
        .ground_air_vapor_m3 = 5,
        .initial_ground_air_vapor_m3 = 5,
        .fail_accept_nonretryable = true,
    };
    var control: TestSubstepControl = .{ .succeed_without_solving = true };

    try std.testing.expectError(
        error.LitterSoilInterfaceDimensionMismatch,
        runSyntheticRetry(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control),
    );
    try std.testing.expectEqual(@as(u8, 1), control.attempts);
    try std.testing.expectEqual(@as(u8, 1), transaction.accepted_calls);
    try std.testing.expectEqual(@as(u8, 1), transaction.rollback_calls);
    try std.testing.expectEqual(@as(f64, 2), grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 7), hydrology.boundary_water_exchange_m3_per_step[0]);
    try std.testing.expectEqual(@as(f64, -13), hydrology.boundary_water_exchange_m3_per_layer_per_step[0]);
    try std.testing.expectEqual(@as(f64, 17), hydrology.boundary_heat_exchange_megajoules_per_layer_per_step[0]);
    try std.testing.expectEqual(@as(f64, 11), hydrology.micropore_external_water_flux_m3_per_step[0]);
    try std.testing.expectEqual(@as(f64, 3), transaction.snow_mass_m3);
    try std.testing.expectEqual(@as(f64, 5), transaction.ground_air_vapor_m3);
    try std.testing.expectEqual(@as(f64, 0), transaction.private_ground_air_balance_m3);
    try std.testing.expectEqual(@as(f64, 280), transaction.surface_temperature_k);
    try std.testing.expectEqual(@as(f64, 0), transaction.private_surface_energy_megajoules);
    try std.testing.expectEqual(@as(f64, 0), transaction.private_ledger);
}

test "one hour recovery schedules through 64 substeps apply external snow forcing exactly once" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 1 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 1, 1);
    defer hydrology.deinit();
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    var workspace = try workspace_module.State.init(std.testing.allocator, 1);
    defer workspace.deinit();
    var thermal_buffer = [_]f64{0};
    var thermal = testThermalState(&thermal_buffer);

    for (
        [_]f64{ 1, 0.5, 0.25, 0.125, 0.0625, 0.05, 0.03125, 0.015625 },
        [_]u8{ 1, 2, 4, 8, 16, 20, 32, 64 },
    ) |maximum_dt, expected_substeps| {
        var transaction: RetryTransactionFixture = .{ .grid = &grid };
        var control: TestSubstepControl = .{ .fail_time_step_hours_above = maximum_dt, .succeed_without_solving = true };
        var result = try runSyntheticRetry(&grid, &hydrology, &faces, &workspace, &thermal, &transaction, &control);
        defer result.deinit();
        const accumulation_roundoff = 8 * std.math.floatEps(f64) *
            @as(f64, @floatFromInt(expected_substeps)) * 282;
        try std.testing.expectEqual(expected_substeps, result.accepted_substeps);
        try std.testing.expectApproxEqAbs(@as(f64, 1), result.grid_delta_by_layer_carrier[0], accumulation_roundoff);
        try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.snow_mass_m3, accumulation_roundoff);
        try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.ground_air_vapor_m3, accumulation_roundoff);
        try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ground_air_balance_m3, accumulation_roundoff);
        try std.testing.expectApproxEqAbs(@as(f64, 282), transaction.surface_temperature_k, accumulation_roundoff);
        try std.testing.expectApproxEqAbs(@as(f64, 3), transaction.private_surface_energy_megajoules, accumulation_roundoff);
        try std.testing.expectApproxEqAbs(@as(f64, 1), transaction.private_ledger, accumulation_roundoff);
    }
}

test "soil stage diagnostic reconstructs live census-commensurable enthalpy" {
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 4 },
    );
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    grid.matrix_liquid_water_m3[0] = 2;
    grid.macropore_liquid_water_m3[0] = 3;
    grid.water_vapor_volume_m3[0] = 0.5;
    grid.matrix_ice_water_m3[0] = 4;
    grid.macropore_ice_water_m3[0] = 1;
    grid.soil_temperature_k[0] = 280;
    const melting_temperature_k = 273.15;
    const latent_heat_of_fusion_megajoules_per_m3 = 333;
    // Census-commensurable: liquid/solid sensible, frozen water at the full
    // `frozenWaterEnthalpyPerM3`. Must match
    // `landscape_mass_inventory.zig` term for term.
    const frozen_enthalpy_per_m3 = 4.19 * melting_temperature_k -
        latent_heat_of_fusion_megajoules_per_m3 +
        1.9274 * (280 - melting_temperature_k);
    const expected = (10 + 4.19 * 5.5) * 280 + frozen_enthalpy_per_m3 * 5;
    var actual = [_]f64{0};
    try fillCellEnthalpyMegajoules(&actual, &grid, &.{10}, 4.19, 1.9274, latent_heat_of_fusion_megajoules_per_m3, melting_temperature_k);
    try std.testing.expectApproxEqAbs(expected, actual[0], 1e-10);
    // Negative control: the sensible-only formula this replaced must NOT
    // pass. It differs by exactly `((C_l - C_i)*Tm - L) * ice = 285.029 * 5`
    // MJ, the constant that produced the spurious `0.855943 *
    // freeze_thaw_latent` signal in the heat balance investigation.
    const sensible_only = (10 + 4.19 * 5.5 + 1.9274 * 5) * 280;
    try std.testing.expect(@abs(sensible_only - actual[0]) > 1e3);
    try std.testing.expectApproxEqAbs(
        ((4.19 - 1.9274) * melting_temperature_k - latent_heat_of_fusion_megajoules_per_m3) * 5,
        actual[0] - sensible_only,
        1e-9,
    );
}

test "accepted WATSUB ice ledger publishes REDIST DVOLI atomically" {
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 1, 1, 2, 1);
    defer hydrology.deinit();
    try publishAcceptedIceVolumeChanges(&hydrology, &.{ 0.1, 0.3 }, &.{ 0.2, 0.1 }, &.{ 0.25, 0.2 }, &.{ 0.15, 0.4 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), hydrology.matrix_ice_volume_change_m3_per_step[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, -0.1), hydrology.matrix_ice_volume_change_m3_per_step[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, -0.05), hydrology.macropore_ice_volume_change_m3_per_step[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), hydrology.macropore_ice_volume_change_m3_per_step[1], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), hydrology.total_ice_volume_change_m3_per_step[0], 1e-14);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), hydrology.total_ice_volume_change_m3_per_step[1], 1e-14);
    hydrology.total_ice_volume_change_m3_per_step[0] = 9;
    try std.testing.expectError(error.NonFiniteAcceptedIceVolumeChange, publishAcceptedIceVolumeChanges(&hydrology, &.{ 0, 0 }, &.{ 0, 0 }, &.{ std.math.nan(f64), 0 }, &.{ 0, 0 }));
    try std.testing.expectEqual(@as(f64, 9), hydrology.total_ice_volume_change_m3_per_step[0]);
}

test "late WATSUB failure rolls back water vapor heat and shared faces" {
    const retention = @import("retention.zig");
    const cfg = try @import("../../core/config.zig").SimulationConfig.init(.{ .lon_count = 2, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 }, .{ .worker_threads = 1, .tile_cells = 2 }, .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-11, .max_nonlinear_iterations = 20 });
    var grid = try grid_module.GridState.init(std.testing.allocator, cfg);
    defer grid.deinit();
    @memset(grid.active_soil_layer_count, 1);
    grid.matrix_liquid_water_m3[0] = 0.35;
    grid.matrix_liquid_water_m3[1] = 0.15;
    @memset(grid.matrix_pore_capacity_m3, 0.5);
    grid.matrix_air_volume_m3[0] = 0.15;
    grid.matrix_air_volume_m3[1] = 0.35;
    @memcpy(grid.air_volume_m3, grid.matrix_air_volume_m3);
    grid.water_vapor_volume_m3[0] = 0.01;
    grid.soil_temperature_k[0] = 300;
    grid.soil_temperature_k[1] = 280;
    var snow = try @import("../solute/snow_solute_transport.zig").State.init(std.testing.allocator, 2, 1);
    defer snow.deinit();
    var hydrology = try hydrology_module.State.init(std.testing.allocator, 2, 1, 1, 1);
    defer hydrology.deinit();
    try hydrology.syncStorage(&grid, &snow);
    var faces = try hydrology_module.buildSoilFaces(std.testing.allocator, &hydrology, &grid);
    defer faces.deinit();
    const curve: retention.ResolvedCurve = .{ .porosity_fraction = 0.5, .curve = .{ .field_capacity_fraction = 0.3, .wilting_point_fraction = 0.1, .saturation_water_potential_megapascal = -0.0005, .field_capacity_water_potential_megapascal = -0.01, .wilting_point_water_potential_megapascal = -1.5, .minimum_water_potential_megapascal = -1.5e12, .saturation_to_field_shape = 0.5, .below_wilting_shape = 0.5 } };
    const curves = [_]retention.ResolvedCurve{ curve, curve };
    const one_face = [_]f64{1};
    const one_cell = [_]f64{ 1, 1 };
    const phase_heat_capacity = [_]f64{ 2, 2 };
    const half_cell = [_]f64{ 0.5, 0.5 };
    const zero_cell = [_]f64{ 0, 0 };
    const thickness = [_]f64{ 0.1, 0.1 };
    const bools = [_]bool{ true, false };
    const bad_capacity = [_]f64{ 0, 0 };
    const saturation_potential = [_]f64{ -0.0005, -0.0005 };
    const pore_exchange_disabled = [_]bool{ false, false };
    const matrix_parameters = [_]retention.MualemVanGenuchtenParameters{
        .{ .residual_water_content_m3_per_m3 = 0.05, .saturated_water_content_m3_per_m3 = 0.5, .alpha_per_m = 3.6, .n = 1.56, .saturated_hydraulic_conductivity_m_per_h = 0.002 },
        .{ .residual_water_content_m3_per_m3 = 0.05, .saturated_water_content_m3_per_m3 = 0.5, .alpha_per_m = 3.6, .n = 1.56, .saturated_hydraulic_conductivity_m_per_h = 0.002 },
    };
    const macropore_parameters = [_]retention.MualemVanGenuchtenParameters{
        .{ .residual_water_content_m3_per_m3 = 0, .saturated_water_content_m3_per_m3 = 1, .alpha_per_m = 15, .n = 2.68, .saturated_hydraulic_conductivity_m_per_h = 0.1 },
        .{ .residual_water_content_m3_per_m3 = 0, .saturated_water_content_m3_per_m3 = 1, .alpha_per_m = 15, .n = 2.68, .saturated_hydraulic_conductivity_m_per_h = 0.1 },
    };
    const macropore_spacing_m = [_]f64{ 0.2, 0.2 };
    const macropore_radius_m = [_]f64{ 0.001, 0.001 };
    const before_water = grid.matrix_liquid_water_m3[0];
    try std.testing.expectError(error.InvalidSoilHeatCapacity, advance(std.testing.allocator, &grid, &hydrology, &faces, .{
        .water_geometry = .{ .source_path_length_m = &one_face, .destination_path_length_m = &one_face, .face_area_m2 = &one_face },
        .water_properties = .{ .matrix_bulk_volume_m3 = &one_cell, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .macropore_spacing_m = &macropore_spacing_m, .macropore_radius_m = &macropore_radius_m, .dual_domain_exchange_enabled = &pore_exchange_disabled, .gravitational_potential_megapascal = &zero_cell, .osmotic_potential_megapascal = &zero_cell, .vertical_thickness_m = &thickness, .osmotic_potential_multiplier = 1 },
        .water_options = .{ .max_iterations = 20 },
        .vapor_geometry = .{ .source_path_length_m = &one_face, .destination_path_length_m = &one_face, .face_area_m2 = &one_face },
        .vapor_properties = .{ .vapor_diffusivity_m2_per_h = &one_cell, .air_fraction = &half_cell, .porosity_fraction = &half_cell, .tortuosity = 1 },
        .vapor_options = .{ .max_iterations = 20 },
        .phase_properties = .{ .matrix_bulk_volume_m3 = &one_cell, .retention_curve = &curves, .mualem_van_genuchten_parameters = &matrix_parameters, .macropore_mualem_van_genuchten_parameters = &macropore_parameters, .osmotic_potential_megapascal = &zero_cell, .saturation_water_potential_megapascal = &saturation_potential, .heat_capacity_megajoules_per_k = &phase_heat_capacity, .saturated_lateral_matrix_conductivity_m2_per_h_megapascal = &one_cell, .face_area_m2 = &one_cell, .macropore_spacing_m = &one_cell, .macropore_radius_m = &one_cell, .pore_exchange_enabled = &pore_exchange_disabled, .vapor = .{ .vapor_density_temperature_coefficient = 2.173e-3, .molecular_weight_ratio = 0.61, .clausius_clapeyron_coefficient_k = 5360, .reference_inverse_temperature_per_k = 3.661e-3, .water_molar_mass_g_per_mol = 18, .gas_constant_j_per_mol_k = 8.3143, .latent_heat_of_vaporization_megajoules_per_m3 = 2450 }, .freeze_thaw = .{ .freezing_potential_numerator_k_megapascal = 9.0959e4, .latent_heat_of_fusion_megajoules_per_m3 = 333, .ice_density_megagrams_per_m3 = 0.917, .heat_capacity_temperature_feedback_per_k = 6.2913e-3, .pure_water_freezing_temperature_k = 273.15 }, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .ice_heat_capacity_megajoules_per_m3_k = 1.9274 },
        .phase_options = .{ .max_iterations = 20 },
        .heat_geometry = .{ .source_path_length_m = &one_face, .destination_path_length_m = &one_face, .face_area_m2 = &one_face },
        .heat_properties = .{ .heat_capacity_megajoules_per_k = &bad_capacity, .minimum_heat_capacity_megajoules_per_k = &zero_cell, .bulk_density_megagrams_per_m3 = &one_cell, .liquid_water_fraction = &half_cell, .ice_fraction = &zero_cell, .air_fraction = &half_cell, .fraction_of_pore_volume_air_filled = &half_cell, .solid_conductivity_numerator_m_megajoules_per_h_k = &one_cell, .solid_conductivity_denominator = &one_cell, .is_top_soil_layer = &bools, .top_snow_heat_capacity_megajoules_per_k = &zero_cell, .maximum_negligible_snow_heat_capacity_megajoules_per_k = &zero_cell, .snow_storage_heat_flux_megajoules = &zero_cell, .cell_heat_source_megajoules = &zero_cell, .liquid_water_heat_capacity_megajoules_per_m3_k = 4.19, .turbulence = .{ .water_fraction_threshold = 1, .air_fraction_threshold = 1, .water_rayleigh_coefficient = 0, .air_rayleigh_coefficient = 0, .water_nusselt_denominator = 1, .air_nusselt_denominator = 1 } },
        .heat_options = .{ .max_iterations = 20 },
    }));
    try std.testing.expectEqual(before_water, grid.matrix_liquid_water_m3[0]);
    try std.testing.expectEqual(@as(f64, 0.01), grid.water_vapor_volume_m3[0]);
    try std.testing.expectEqual(@as(f64, 300), grid.soil_temperature_k[0]);
    try std.testing.expectEqual(@as(f64, 0), faces.micropore_water_flux_m3_per_step[0]);
    try std.testing.expectEqual(@as(f64, 0), faces.vapor_flux_m3_per_step[0]);
}

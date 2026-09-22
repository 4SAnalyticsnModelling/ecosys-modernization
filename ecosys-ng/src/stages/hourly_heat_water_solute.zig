//! `hourly_science` declarations: heat water solute.
//!
//! Split out of `hourly_science.zig`, which re-exports these so every call
//! site is unchanged. Sibling groups are imported directly, so this
//! grouping is a file layout choice and carries no ordering meaning.

const std = @import("std");
const builtin = @import("builtin");
const ecosys = @import("ecosys_ng");
const biogeochemistry_batches = @import("biogeochemistry_batches.zig");
const diagnostics = @import("diagnostics.zig");
const plant_daily = @import("plant_daily.zig");
const root_processes = @import("root_processes.zig");
const soil_chemistry_convergence = @import("soil_chemistry_convergence.zig");
const surface_litter_convergence = @import("surface_litter_convergence.zig");
const tile_kernels = @import("tile_kernels.zig");
const group_timestep_finalize = @import("hourly_timestep_finalize.zig");
const group_gas_surface_water = @import("hourly_gas_surface_water.zig");
const group_support = @import("hourly_process_support.zig");
const group_sediment = @import("hourly_sediment.zig");
const group_vegetation = @import("hourly_vegetation.zig");
const run_support = @import("run_support.zig");
const AdaptiveHourSchedule = ecosys.adaptive_hour_schedule.State;

const conservation_trace_point_count = 7;

/// Divisor applied to `mass_balance_relative_tolerance` for the soil heat
/// solver's PER-LAYER energy-closure criterion, and for nothing else.
///
/// This is a TIGHTENING, which is why it is allowed to exist at all: it can
/// only reject states the previous criterion accepted, so it cannot mask a
/// defect and it is not an acceptance escape.
///
/// Why it is needed, measured
/// (`HOUR-346-ROOT-CAUSE-TWO-RELATIVE-CRITERIA-AT-THE-SAME-1e-9-WITH-INCOMMENSURATE-SCALES-007`):
/// the solver and the hourly cell gate used the SAME relative tolerance but
/// normalized by incommensurate scales. The solver normalizes each layer by
/// that layer's own GROSS enthalpy traffic
/// (`soil/heat/solver_residual.zig:920-968`), while the cell gate normalizes
/// by the cell's own booked activity, which necessarily excludes heat moving
/// BETWEEN layers of that cell. On the Ottawa deck at the failing hour the sum
/// of per-layer gross activity was `6.712902e-1` MJ against a cell activity of
/// `1.5682e-2` MJ, so the per-layer criteria collectively permitted 42.8x what
/// the gate auditing their sum allowed. The solver accepted soil layer 11 at
/// 0.932 of its own limit and the accumulated defect, `5.92e-11` MJ, failed a
/// cell limit of `1.568e-11`.
///
/// Why 64 and not 42.8: 42.8 is the ratio observed in ONE hour, and fitting a
/// constant to a single observation is how the apatite-ceiling error happened
/// earlier in this work. 64 is the next power of two above it, giving margin
/// for hours whose deep inter-layer traffic is larger, and it is a round
/// binary factor so the tightened tolerance stays exactly representable.
///
/// The shared `mass_balance_relative_tolerance` is deliberately NOT edited.
/// An A/B run previously proved it is read by seven other call sites and that
/// changing it globally caused a worse regression
/// (`MASS-BALANCE-HEAT-FLOOR-DECK-EDIT-001`). This divides at the single heat
/// call site, matching the existing precedent at `ecosys_ng.zig:5996`, which
/// applies a local floor to the layer gate without touching the shared struct.
///
/// This is an EXPERIMENT with a measured outcome, not a settled design. It
/// asks the solver for roughly 117-ulp per-layer closure on a 451 MJ quantity
/// where it previously retained 4,676 ulps. If it cannot converge there, or
/// the runtime cost is unacceptable, the alternative is to give the cell gate a
/// scale commensurate with what it sums; see the register entry.
const heat_layer_conservation_tolerance_divisor: f64 = 64;

fn diagnosticSoilGasCarbon(context: anytype) !f64 {
    var total_g_c: f64 = 0;
    const co2 = @intFromEnum(ecosys.gas_transport.Species.carbon_dioxide);
    const methane = @intFromEnum(ecosys.gas_transport.Species.methane);
    for (0..context.grid.cell_count) |cell| {
        const first = cell * context.grid.soil_layer_capacity;
        for (0..context.grid.active_soil_layer_count[cell]) |local_layer| {
            const layer = first + local_layer;
            inline for (.{ co2, methane }) |species| {
                const index = layer * ecosys.gas_transport.species_count + species;
                total_g_c += context.gas_transport.gaseous_mass_g[index] +
                    context.gas_transport.dissolved_mass_g[index] +
                    context.gas_transport.macropore_dissolved_mass_g[index] +
                    context.gas_transport.band_dissolved_mass_g[index];
            }
        }
    }
    if (!std.math.isFinite(total_g_c)) return error.NonFiniteHourlyFailureTrace;
    return total_g_c;
}

fn captureFailureConservationTrace(context: anytype, point: usize) !void {
    if (point >= conservation_trace_point_count) return error.HourlyFailureTraceDimensionMismatch;
    const traces = [_][]f64{
        context.diagnostic_residue_carbon_trace_g_c,
        context.diagnostic_organic_carbon_trace_g_c,
        context.diagnostic_inorganic_carbon_trace_g_c,
        context.diagnostic_plant_carbon_trace_g_c,
        context.diagnostic_soil_gas_carbon_trace_g_c,
        context.diagnostic_heat_storage_trace_megajoules,
        context.diagnostic_heat_closed_trace_megajoules,
        context.diagnostic_heat_production_trace_megajoules,
        context.diagnostic_heat_consumption_trace_megajoules,
    };
    for (traces) |trace| if (trace.len != conservation_trace_point_count)
        return error.HourlyFailureTraceDimensionMismatch;
    // These arrays are failure diagnostics only. Start a fresh transactional
    // trace at the first current-hour point so a later closure gate never
    // reports values retained from an earlier accepted hour.
    if (point == 0) for (traces) |trace| @memset(trace, 0);

    const totals = try diagnostics.reconstructLandscapeMassBalance(context);
    context.diagnostic_residue_carbon_trace_g_c[point] = totals.residue_carbon_g;
    context.diagnostic_organic_carbon_trace_g_c[point] = totals.organic_carbon_g;
    context.diagnostic_inorganic_carbon_trace_g_c[point] = totals.carbon_dioxide_carbon_g;
    context.diagnostic_plant_carbon_trace_g_c[point] = totals.plant_carbon_g;
    context.diagnostic_heat_storage_trace_megajoules[point] = totals.heat_storage_megajoules;
    context.diagnostic_heat_closed_trace_megajoules[point] =
        totals.heat_storage_megajoules - totals.cumulative_heat_input_megajoules +
        totals.cumulative_heat_output_megajoules -
        totals.cumulative_internal_heat_production_megajoules +
        totals.cumulative_internal_heat_consumption_megajoules;

    context.diagnostic_soil_gas_carbon_trace_g_c[point] =
        try diagnosticSoilGasCarbon(context);

    var heat_production_megajoules: f64 = 0;
    var heat_consumption_megajoules: f64 = 0;
    for (context.hourly_cell_boundary_ledger.cells) |activity| {
        heat_production_megajoules += activity.heat_internal_production_megajoules;
        heat_consumption_megajoules += activity.heat_internal_consumption_megajoules;
    }
    if (!std.math.isFinite(heat_production_megajoules) or
        !std.math.isFinite(heat_consumption_megajoules))
        return error.NonFiniteHourlyFailureTrace;
    context.diagnostic_heat_production_trace_megajoules[point] = heat_production_megajoules;
    context.diagnostic_heat_consumption_trace_megajoules[point] = heat_consumption_megajoules;
    if (!builtin.is_test and run_support.verbose_diagnostics_enabled and
        context.executed_weather_hours.* < 2 and context.grid.cell_count > 0)
    {
        const capture = std.json.Stringify.valueAlloc(context.allocator, .{
            .hour = context.executed_weather_hours.* + 1,
            .point = point,
            .topsoil_water_m3 = context.grid.matrix_liquid_water_m3[0],
            .topsoil_aqueous = context.soil_chemistry.aqueous[0],
            .topsoil_phosphate = context.soil_chemistry.non_band_phosphate[0],
            .litter_water_m3 = context.surface_precipitation.litter_water_m3[0],
            .litter_chemistry = context.surface_litter_chemistry.cells[0],
        }, .{}) catch |err| {
            std.log.warn("early chemistry trace failed: error={s}", .{@errorName(err)});
            return;
        };
        defer context.allocator.free(capture);
        std.log.info("TEMP_CHEMISTRY_TRACE {s}", .{capture});
    }
}

/// Dense water, vapor, and heat Jacobians are bounded by nonlinear component
/// count (soil-layer states), not by the horizontal tile capacity.  Each
/// solver independently skips the dense path when its actual dimension is
/// above this production safety cap.
pub const production_dense_newton_max_components: usize = 256;

pub const PostWatsubBiologyHook = struct {
    context: *anyopaque,
    /// HFUNC followed by living STOMATE/UPTAKE. The caller owns the typed
    /// context; this stage invokes it only after accepted WATSUB and NITRO.
    advance: *const fn (context: *anyopaque) anyerror!void,
};

pub const FixedHourOwnerRebindHook = struct {
    context: *anyopaque,
    rebind: *const fn (context: *anyopaque) anyerror!void,
};

/// A checkpoint rollback swaps the phenology owner, so every long-lived slice
/// alias into that owner must follow the newly live allocation before another
/// recovery attempt can run.
pub fn rebindPhenologyAliases(
    phenology: anytype,
    development_emerged: *[]bool,
    harvest_emerged: ?*?[]bool,
    metadata_cells: anytype,
    plant_populations: usize,
) !void {
    if (plant_populations == 0 or
        phenology.emerged.len != phenology.active.len or
        phenology.active.len % plant_populations != 0 or
        metadata_cells.len != phenology.active.len / plant_populations)
        return error.PhenologyAliasRebindDimensionMismatch;
    for (metadata_cells) |metadata| {
        if (metadata.species_names.len != metadata.species_alive.len or
            metadata.species_names.len > plant_populations)
            return error.PhenologyAliasRebindDimensionMismatch;
    }

    // Validation is complete before changing any descriptor: a malformed late
    // metadata cell cannot leave earlier aliases rebound into a partial state.
    development_emerged.* = phenology.emerged;
    if (harvest_emerged) |alias| alias.* = phenology.emerged;
    for (metadata_cells, 0..) |*metadata, cell| {
        const active_species = metadata.species_names.len;
        const first = cell * plant_populations;
        metadata.species_alive = phenology.active[first .. first + active_species];
    }
}

/// Retained storage for exact, whole-stage recovery attempts.  Persistent
/// owners use the same checkpoint codecs and validated owner swap as the
/// enclosing external-hour transaction.  The two topology-dependent owners
/// outside that bundle have dedicated retained swaps.
pub const FixedHourRecoveryWorkspace = struct {
    transaction: ecosys.outer_hour_transaction.Workspace,
    canopy_carbon_exchange: ecosys.outer_hour_transaction.OwnerWorkspace(ecosys.canopy_carbon_exchange.State),
    soil_gas_transport: ecosys.outer_hour_transaction.OwnerWorkspace(ecosys.soil_gas_transport_step.State),
    targets: ?ecosys.checkpoint_bundle_reader.LiveTargets = null,
    outer_transaction: ?*ecosys.outer_hour_transaction.Transaction = null,
    owner_rebind: ?FixedHourOwnerRebindHook = null,
    /// Non-scientific timestep hints retained across accepted external hours.
    /// After a coarser schedule is rejected, a short cooldown starts the next
    /// few hours at the accepted resolution before probing that rung again.
    /// This bounds repeated transactional work without assuming that a failed
    /// resolution is permanently inadmissible as weather and phase state move.
    adaptive_hour_schedule: AdaptiveHourSchedule = .{},
    /// Once a coarse solve proves that heat-induced freeze/thaw needs the
    /// source quarter-hour coupling, retain that physical floor while the
    /// accepted profile still contains significant ice or sub-freezing soil.
    /// This avoids replaying a known-inadmissible coarse transaction every
    /// fourth hour. The hint is released from accepted physical state, and a
    /// subsequent coarse probe must still pass the ordinary phase gate.
    pub fn init(allocator: std.mem.Allocator) FixedHourRecoveryWorkspace {
        return .{
            .transaction = .init(allocator),
            .canopy_carbon_exchange = .init(allocator),
            .soil_gas_transport = .init(allocator),
        };
    }

    pub fn deinit(self: *FixedHourRecoveryWorkspace) void {
        std.debug.assert(self.outer_transaction == null);
        std.debug.assert(self.owner_rebind == null);
        self.soil_gas_transport.deinit();
        self.canopy_carbon_exchange.deinit();
        self.transaction.deinit();
        self.* = undefined;
    }

    pub fn configure(
        self: *FixedHourRecoveryWorkspace,
        targets: ecosys.checkpoint_bundle_reader.LiveTargets,
    ) void {
        std.debug.assert(self.outer_transaction == null);
        std.debug.assert(self.owner_rebind == null);
        self.targets = targets;
    }

    pub fn bindOuterTransaction(
        self: *FixedHourRecoveryWorkspace,
        transaction: *ecosys.outer_hour_transaction.Transaction,
        owner_rebind: FixedHourOwnerRebindHook,
    ) void {
        std.debug.assert(self.outer_transaction == null);
        std.debug.assert(self.owner_rebind == null);
        std.debug.assert(transaction.active);
        self.outer_transaction = transaction;
        self.owner_rebind = owner_rebind;
    }

    pub fn unbindOuterTransaction(
        self: *FixedHourRecoveryWorkspace,
        transaction: *ecosys.outer_hour_transaction.Transaction,
    ) void {
        std.debug.assert(self.outer_transaction == transaction);
        self.outer_transaction = null;
        self.owner_rebind = null;
    }

    fn rebindAfterOwnerRollback(self: *FixedHourRecoveryWorkspace) !void {
        const hook = self.owner_rebind orelse
            return error.FixedHourRecoveryOwnerRebindNotBound;
        try hook.rebind(hook.context);
    }
};

/// Folds one hour's carried-over delayed heat source into this hour's
/// per-layer heat-source accumulator. The exact producer remains intact until
/// the accepted solve has booked it to both heat ledgers, then is zeroed.
fn foldDelayedHeatSource(delayed_heat_megajoules: []const f64, cell_heat_source_megajoules: []f64) !void {
    for (delayed_heat_megajoules, cell_heat_source_megajoules) |delayed_heat, *heat_source| {
        heat_source.* += delayed_heat;
        if (!std.math.isFinite(heat_source.*)) return error.NonFiniteDelayedHeatSource;
    }
}

fn validateLitterSoilInterfaceDimensions(
    surface: *const ecosys.surface_solute_routing.State,
    soil: *const ecosys.solute_transport.State,
    cell_count: usize,
    layer_count: usize,
) !void {
    const canonical_species_count = ecosys.solute_transport_species.AqueousSpecies.count;
    const surface_amount_count = std.math.mul(usize, cell_count, canonical_species_count) catch
        return error.LitterSoilInterfaceDimensionMismatch;
    const soil_amount_count = std.math.mul(usize, layer_count, canonical_species_count) catch
        return error.LitterSoilInterfaceDimensionMismatch;
    if (cell_count == 0 or layer_count == 0 or
        surface.species_count != canonical_species_count or
        surface.carrier_volume_m3.len != cell_count or
        surface.amount_mol.len != surface_amount_count or
        soil.cell_count != layer_count or
        soil.species_count != canonical_species_count or
        soil.water_volume_m3.len != layer_count or
        soil.amount_mol.len != soil_amount_count)
        return error.LitterSoilInterfaceDimensionMismatch;
}

fn SliceStateSnapshot(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        state: T,

        fn capture(allocator: std.mem.Allocator, source: *const T) !Self {
            @setEvalBranchQuota(10_000);
            var state = source.*;
            var allocated: usize = 0;
            errdefer {
                var visited: usize = 0;
                inline for (@typeInfo(T).@"struct".fields) |field| if (comptime isSlice(field.type)) {
                    if (visited < allocated) allocator.free(@field(state, field.name));
                    visited += 1;
                };
            }
            inline for (@typeInfo(T).@"struct".fields) |field| if (comptime isSlice(field.type)) {
                const Child = @typeInfo(field.type).pointer.child;
                @field(state, field.name) = try allocator.dupe(Child, @field(source, field.name));
                allocated += 1;
            };
            return .{ .allocator = allocator, .state = state };
        }

        fn restore(self: *const Self, destination: *T) void {
            @setEvalBranchQuota(10_000);
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime isSlice(field.type))
                    @memcpy(@field(destination, field.name), @field(self.state, field.name))
                else
                    @field(destination, field.name) = @field(self.state, field.name);
            }
        }

        fn deinit(self: *Self) void {
            @setEvalBranchQuota(10_000);
            inline for (@typeInfo(T).@"struct".fields) |field| if (comptime isSlice(field.type))
                self.allocator.free(@field(self.state, field.name));
            self.* = undefined;
        }
    };
}

fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice,
        else => false,
    };
}

/// Retains only the water-normalized topsoil chemistry fields that the
/// pre-WATSUB forcing temporarily rebases for the substep coefficient refresh.
/// The accepted carrier owner restores these entry values before applying its
/// single entry-to-exit rebase, so diagnostic preparation cannot scale the
/// same extensive inventory a second time.
const TopsoilChemistryCarrierSnapshot = struct {
    allocator: std.mem.Allocator,
    aqueous: []ecosys.solute_aqueous_network.State,
    non_band_phosphate: []ecosys.solute_phosphate_network.State,
    band_phosphate: []ecosys.solute_phosphate_network.State,
    geochemistry_solids: []ecosys.solute_geochemistry_network.SolidState,
    armed: bool = false,

    fn init(allocator: std.mem.Allocator, cell_count: usize) !TopsoilChemistryCarrierSnapshot {
        if (cell_count == 0) return error.ZeroTopsoilChemistryCarrierSnapshotCells;
        const aqueous = try allocator.alloc(ecosys.solute_aqueous_network.State, cell_count);
        errdefer allocator.free(aqueous);
        const non_band = try allocator.alloc(ecosys.solute_phosphate_network.State, cell_count);
        errdefer allocator.free(non_band);
        const band = try allocator.alloc(ecosys.solute_phosphate_network.State, cell_count);
        errdefer allocator.free(band);
        const solids = try allocator.alloc(ecosys.solute_geochemistry_network.SolidState, cell_count);
        errdefer allocator.free(solids);
        return .{
            .allocator = allocator,
            .aqueous = aqueous,
            .non_band_phosphate = non_band,
            .band_phosphate = band,
            .geochemistry_solids = solids,
        };
    }

    fn validateDimensions(
        self: *const TopsoilChemistryCarrierSnapshot,
        grid: *const ecosys.grid.GridState,
        chemistry: *const ecosys.solute_chemistry_state.State,
    ) !void {
        if (chemistry.cell_count != grid.layer_count or
            self.aqueous.len != grid.cell_count or
            self.non_band_phosphate.len != grid.cell_count or
            self.band_phosphate.len != grid.cell_count or
            self.geochemistry_solids.len != grid.cell_count)
            return error.TopsoilChemistryCarrierSnapshotDimensionMismatch;
    }

    fn capture(
        self: *TopsoilChemistryCarrierSnapshot,
        grid: *const ecosys.grid.GridState,
        chemistry: *const ecosys.solute_chemistry_state.State,
    ) !void {
        try self.validateDimensions(grid, chemistry);
        for (0..grid.cell_count) |cell| {
            const top = try grid.layerIndex(cell, 0);
            self.aqueous[cell] = chemistry.aqueous[top];
            self.non_band_phosphate[cell] = chemistry.non_band_phosphate[top];
            self.band_phosphate[cell] = chemistry.band_phosphate[top];
            self.geochemistry_solids[cell] = chemistry.geochemistry_solids[top];
        }
        self.armed = true;
    }

    fn restoreAndDisarm(
        self: *TopsoilChemistryCarrierSnapshot,
        grid: *const ecosys.grid.GridState,
        chemistry: *ecosys.solute_chemistry_state.State,
    ) !void {
        if (!self.armed) return error.TopsoilChemistryCarrierSnapshotNotArmed;
        try self.validateDimensions(grid, chemistry);
        for (0..grid.cell_count) |cell| {
            const top = try grid.layerIndex(cell, 0);
            chemistry.aqueous[top] = self.aqueous[cell];
            chemistry.non_band_phosphate[top] = self.non_band_phosphate[cell];
            chemistry.band_phosphate[top] = self.band_phosphate[cell];
            chemistry.geochemistry_solids[top] = self.geochemistry_solids[cell];
        }
        self.armed = false;
    }

    fn deinit(self: *TopsoilChemistryCarrierSnapshot) void {
        self.allocator.free(self.geochemistry_solids);
        self.allocator.free(self.band_phosphate);
        self.allocator.free(self.non_band_phosphate);
        self.allocator.free(self.aqueous);
        self.* = undefined;
    }
};

noinline fn surfaceChemistryRebaseInventoryInputs(
    context: anytype,
    cell: usize,
) !ecosys.surface_litter_chemistry_carrier_rebase.InventoryInputs {
    if (cell >= context.grid.cell_count or
        cell >= context.surface_litter_geometry.dry_mass_megagrams.len or
        cell >= context.surface_litter_fertilizer.cells.len or
        cell >= context.surface_denitrification.nitrite_g_n.len)
        return error.ChemistryRebaseProvenanceDimensionMismatch;
    const fertilizer = context.surface_litter_fertilizer.cells[cell];
    return .{
        .dry_mass_megagrams = context.surface_litter_geometry.dry_mass_megagrams[cell],
        .carbon_g_per_mol = 12.0,
        .nitrogen_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
        .phosphorus_g_per_mol = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        .fertilizer_ammonium_mol_n = fertilizer.ammonium_mol_n,
        .fertilizer_ammonia_mol_n = fertilizer.ammonia_mol_n,
        .fertilizer_urea_mol_n = fertilizer.urea_mol_n,
        .fertilizer_nitrate_mol_n = fertilizer.nitrate_mol_n,
        .denitrification_nitrite_g_n = context.surface_denitrification.nitrite_g_n[cell],
    };
}

fn SoilForcingSubstepHooks(
    comptime ContextPointer: type,
    comptime SoilChemistry: type,
    comptime LitterChemistry: type,
) type {
    return struct {
        const Self = @This();
        context: ContextPointer,
        allocator: std.mem.Allocator,
        soil_chemistry: SliceStateSnapshot(SoilChemistry),
        litter_chemistry: SliceStateSnapshot(LitterChemistry),
        litter_water_m3: []f64,
        litter_water_before_ingress_m3: []f64,
        /// Exact topsoil matrix carriers captured immediately before the two
        /// operations that move them, so their chemistry rebases can commit from a
        /// stored entry value instead of reconstructing it as `new - increment`.
        ///
        /// PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. The comment above
        /// the litter rebase states the hazard these two carried: reconstructing
        /// the old carrier by subtraction "loses real inventory when a small
        /// ingress is added to a large carrier and concentrated
        /// carbonate/phosphate pools amplify that subtraction error". The litter
        /// path already commits from `litter_water_before_ingress_m3`; these give
        /// the soil path the same guarantee.
        topsoil_water_before_vapor_m3: []f64,
        topsoil_water_before_ingress_m3: []f64,
        evaporation_original_m3: []f64,
        condensation_original_m3: []f64,
        litter_change_original_m3: []f64,
        topsoil_change_original_m3: []f64,
        evaporation_step_m3: []f64,
        condensation_step_m3: []f64,
        litter_change_step_m3: []f64,
        litter_ingress_step_m3: []f64,
        topsoil_change_step_m3: []f64,
        litter_evaporation_step_m3: []f64,
        topsoil_evaporation_step_m3: []f64,
        litter_condensation_step_m3: []f64,
        topsoil_condensation_step_m3: []f64,
        accepted_litter_vapor_change_m3: []f64,
        accepted_topsoil_vapor_change_m3: []f64,
        accepted_topsoil_liquid_change_m3: []f64,
        litter_evaporation_total_m3: []f64,
        topsoil_evaporation_total_m3: []f64,
        litter_condensation_total_m3: []f64,
        topsoil_condensation_total_m3: []f64,
        topsoil_vapor_heat_total_megajoules: []f64,
        /// Attempt-private destination owned by the enclosing coupled
        /// transaction. Forcing substeps append only source-certified litter
        /// carrier roundoff; schedule restore/rollback clears it centrally.
        surface_chemistry_rebase_roundoff_by_cell: []ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
        dry_branch_executions: u64,

        noinline fn init(
            context: ContextPointer,
            allocator: std.mem.Allocator,
            surface_chemistry_rebase_roundoff_by_cell: []ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
        ) !Self {
            if (surface_chemistry_rebase_roundoff_by_cell.len != context.grid.cell_count)
                return error.ChemistryRebaseProvenanceDimensionMismatch;
            const soil_snapshot = try SliceStateSnapshot(SoilChemistry).capture(allocator, context.soil_chemistry);
            const litter_snapshot = try SliceStateSnapshot(LitterChemistry).capture(allocator, context.surface_litter_chemistry);
            const litter_water = try allocator.dupe(f64, context.surface_precipitation.litter_water_m3);
            const litter_water_before_ingress = try allocator.alloc(f64, context.grid.cell_count);
            const evaporation_original = try allocator.dupe(f64, context.ground_surface_evaporation_m3_per_h);
            const condensation_original = try allocator.dupe(f64, context.ground_surface_condensation_m3_per_h);
            const litter_change_original = try allocator.dupe(f64, context.ground_surface_litter_water_change_m3);
            const topsoil_change_original = try allocator.dupe(f64, context.ground_surface_topsoil_water_change_m3);
            const evaporation_step = try allocator.alloc(f64, context.grid.cell_count);
            const condensation_step = try allocator.alloc(f64, context.grid.cell_count);
            const litter_change_step = try allocator.alloc(f64, context.grid.cell_count);
            const litter_ingress_step = try allocator.alloc(f64, context.grid.cell_count);
            const litter_evaporation_step = try allocator.alloc(f64, context.grid.cell_count);
            const topsoil_evaporation_step = try allocator.alloc(f64, context.grid.cell_count);
            const litter_condensation_step = try allocator.alloc(f64, context.grid.cell_count);
            const topsoil_condensation_step = try allocator.alloc(f64, context.grid.cell_count);
            const accepted_litter_vapor_change = try allocator.alloc(f64, context.grid.cell_count);
            const accepted_topsoil_vapor_change = try allocator.alloc(f64, context.grid.cell_count);
            const accepted_topsoil_liquid_change = try allocator.alloc(f64, context.grid.cell_count);
            const litter_evaporation_total = try allocator.alloc(f64, context.grid.cell_count);
            const topsoil_evaporation_total = try allocator.alloc(f64, context.grid.cell_count);
            const litter_condensation_total = try allocator.alloc(f64, context.grid.cell_count);
            const topsoil_condensation_total = try allocator.alloc(f64, context.grid.cell_count);
            const topsoil_vapor_heat_total = try allocator.alloc(f64, context.grid.cell_count);
            @memset(accepted_litter_vapor_change, 0);
            @memset(accepted_topsoil_vapor_change, 0);
            @memset(accepted_topsoil_liquid_change, 0);
            @memset(litter_evaporation_total, 0);
            @memset(topsoil_evaporation_total, 0);
            @memset(litter_condensation_total, 0);
            @memset(topsoil_condensation_total, 0);
            @memset(topsoil_vapor_heat_total, 0);
            return .{
                .context = context,
                .allocator = allocator,
                .soil_chemistry = soil_snapshot,
                .litter_chemistry = litter_snapshot,
                .litter_water_m3 = litter_water,
                .litter_water_before_ingress_m3 = litter_water_before_ingress,
                .topsoil_water_before_vapor_m3 = try allocator.alloc(f64, context.grid.cell_count),
                .topsoil_water_before_ingress_m3 = try allocator.alloc(f64, context.grid.cell_count),
                .evaporation_original_m3 = evaporation_original,
                .condensation_original_m3 = condensation_original,
                .litter_change_original_m3 = litter_change_original,
                .topsoil_change_original_m3 = topsoil_change_original,
                .evaporation_step_m3 = evaporation_step,
                .condensation_step_m3 = condensation_step,
                .litter_change_step_m3 = litter_change_step,
                .litter_ingress_step_m3 = litter_ingress_step,
                .topsoil_change_step_m3 = try allocator.alloc(f64, context.grid.cell_count),
                .litter_evaporation_step_m3 = litter_evaporation_step,
                .topsoil_evaporation_step_m3 = topsoil_evaporation_step,
                .litter_condensation_step_m3 = litter_condensation_step,
                .topsoil_condensation_step_m3 = topsoil_condensation_step,
                .accepted_litter_vapor_change_m3 = accepted_litter_vapor_change,
                .accepted_topsoil_vapor_change_m3 = accepted_topsoil_vapor_change,
                .accepted_topsoil_liquid_change_m3 = accepted_topsoil_liquid_change,
                .litter_evaporation_total_m3 = litter_evaporation_total,
                .topsoil_evaporation_total_m3 = topsoil_evaporation_total,
                .litter_condensation_total_m3 = litter_condensation_total,
                .topsoil_condensation_total_m3 = topsoil_condensation_total,
                .topsoil_vapor_heat_total_megajoules = topsoil_vapor_heat_total,
                .surface_chemistry_rebase_roundoff_by_cell = surface_chemistry_rebase_roundoff_by_cell,
                .dry_branch_executions = ecosys.surface_litter_chemistry_carrier_rebase.dry_branch_executions,
            };
        }

        fn restoreCommon(self: *Self) void {
            @memcpy(self.context.surface_precipitation.litter_water_m3, self.litter_water_m3);
            self.soil_chemistry.restore(self.context.soil_chemistry);
            self.litter_chemistry.restore(self.context.surface_litter_chemistry);
            ecosys.surface_litter_chemistry_carrier_rebase.dry_branch_executions = self.dry_branch_executions;
        }

        fn restoreSchedule(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.restoreCommon();
            @memset(self.context.ground_surface_evaporation_m3_per_h, 0);
            @memset(self.context.ground_surface_condensation_m3_per_h, 0);
            @memset(self.context.ground_surface_litter_water_change_m3, 0);
            @memset(self.context.ground_surface_topsoil_water_change_m3, 0);
            @memset(self.litter_evaporation_total_m3, 0);
            @memset(self.topsoil_evaporation_total_m3, 0);
            @memset(self.litter_condensation_total_m3, 0);
            @memset(self.topsoil_condensation_total_m3, 0);
            @memset(self.topsoil_vapor_heat_total_megajoules, 0);
            @memset(self.accepted_litter_vapor_change_m3, 0);
            @memset(self.accepted_topsoil_vapor_change_m3, 0);
            @memset(self.accepted_topsoil_liquid_change_m3, 0);
        }

        fn rollbackFailure(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.restoreCommon();
            @memcpy(self.context.ground_surface_evaporation_m3_per_h, self.evaporation_original_m3);
            @memcpy(self.context.ground_surface_condensation_m3_per_h, self.condensation_original_m3);
            @memcpy(self.context.ground_surface_litter_water_change_m3, self.litter_change_original_m3);
            @memcpy(self.context.ground_surface_topsoil_water_change_m3, self.topsoil_change_original_m3);
        }

        fn prepareSubstep(raw: *anyopaque, time_step_hours: f64) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            const context = self.context;
            // The litter owner was atomically updated with vapor plus phase in
            // the surface Newton kernel.  Apply only the still-pending topsoil
            // lane here, then reconstruct disjoint gross diagnostics.
            @memset(self.litter_change_step_m3, 0);
            // Capture the exact topsoil carrier before `state_updateAcceptedLanes`
            // moves it, so the rebase below commits from this value rather than
            // reconstructing it as `new - topsoil_change_step_m3`.
            for (0..context.grid.cell_count) |cell|
                self.topsoil_water_before_vapor_m3[cell] =
                    context.grid.matrix_liquid_water_m3[try context.grid.layerIndex(cell, 0)];
            try ecosys.ground_surface_vapor_water_state_update.state_updateAcceptedLanes(.{
                .time_step_hours = time_step_hours,
                .accepted_litter_liquid_water_change_m3 = self.litter_change_step_m3,
                .accepted_topsoil_liquid_water_change_m3 = self.accepted_topsoil_liquid_change_m3,
                .litter_liquid_water_m3 = context.surface_precipitation.litter_water_m3,
                .soil_matrix_liquid_water_m3 = context.grid.matrix_liquid_water_m3,
                .active_soil_layer_count = context.grid.active_soil_layer_count,
                .soil_layer_capacity = context.grid.soil_layer_capacity,
                .evaporation_m3_per_h = self.evaporation_step_m3,
                .condensation_m3_per_h = self.condensation_step_m3,
                .litter_liquid_water_change_m3 = self.litter_change_step_m3,
                .topsoil_liquid_water_change_m3 = self.topsoil_change_step_m3,
                .litter_evaporation_m3 = self.litter_evaporation_step_m3,
                .topsoil_evaporation_m3 = self.topsoil_evaporation_step_m3,
                .litter_condensation_m3 = self.litter_condensation_step_m3,
                .topsoil_condensation_m3 = self.topsoil_condensation_step_m3,
            });
            for (0..context.grid.cell_count) |cell| {
                const litter_change = self.accepted_litter_vapor_change_m3[cell];
                const topsoil_change = self.accepted_topsoil_vapor_change_m3[cell];
                self.litter_change_step_m3[cell] = litter_change;
                self.litter_evaporation_step_m3[cell] = @max(0, -litter_change);
                self.litter_condensation_step_m3[cell] = @max(0, litter_change);
                self.topsoil_evaporation_step_m3[cell] = @max(0, -topsoil_change);
                self.topsoil_condensation_step_m3[cell] = @max(0, topsoil_change);
                self.evaporation_step_m3[cell] = (self.litter_evaporation_step_m3[cell] +
                    self.topsoil_evaporation_step_m3[cell]) / time_step_hours;
                self.condensation_step_m3[cell] = (self.litter_condensation_step_m3[cell] +
                    self.topsoil_condensation_step_m3[cell]) / time_step_hours;
                inline for (.{ self.evaporation_step_m3[cell], self.condensation_step_m3[cell] }) |value|
                    if (!std.math.isFinite(value)) return error.NonFiniteGroundSurfaceVaporDiagnostic;
            }
            for (self.litter_ingress_step_m3, context.surface_precipitation.water_to_litter_m3_per_h) |*increment, rate|
                increment.* = rate * time_step_hours;
            @memcpy(
                self.litter_water_before_ingress_m3,
                context.surface_precipitation.litter_water_m3,
            );
            try ecosys.surface_precipitation.state_updateLitterIngress(
                context.surface_precipitation,
                time_step_hours,
            );
            for (0..context.grid.cell_count) |cell| {
                const new_water_m3 = context.surface_precipitation.litter_water_m3[cell];
                const allowance = try ecosys.surface_litter_chemistry_carrier_rebase.previewCellWaterRoundoffFromScaleSource(
                    context.surface_litter_chemistry,
                    cell,
                    self.litter_water_before_ingress_m3[cell],
                    self.litter_water_before_ingress_m3[cell],
                    new_water_m3,
                    try surfaceChemistryRebaseInventoryInputs(context, cell),
                );
                try self.surface_chemistry_rebase_roundoff_by_cell[cell].add(allowance);
            }
            // The exact M-entry carrier is already transaction-owned above.
            // Reconstructing it as `new - increment` loses real inventory when
            // a small ingress is added to a large carrier and concentrated
            // carbonate/phosphate pools amplify that subtraction error. Every
            // cell has passed preflight, so commit from the exact entry value.
            for (0..context.grid.cell_count) |cell|
                try ecosys.surface_litter_chemistry_carrier_rebase.rebaseCellForAcceptedWater(
                    context.surface_litter_chemistry,
                    cell,
                    self.litter_water_before_ingress_m3[cell],
                    context.surface_precipitation.litter_water_m3[cell],
                );
            // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001 candidate. These
            // two topsoil rebases are the unbooked, inexact siblings of the surface
            // litter rebase ten lines above, and the comment above states the exact
            // hazard they still exhibit: they reconstruct the old carrier as
            // `new_water_m3 - increment` rather than committing from a stored exact
            // entry value, and they book no roundoff allowance while every other
            // production rebase site pairs `previewLayerRoundoff` with
            // `accumulateChemistryRebaseRoundoff`.
            //
            // Hour 2,658 is the ponded-litter drainage hour -- "a small ingress
            // added to a large carrier" -- and the precipitated phosphate pool is
            // 1.1928436987268824e3 g P, which is the amplifier the comment names.
            const phosphorus_ingress_trace = self.context.executed_weather_hours.* >= 2656 and
                self.context.executed_weather_hours.* < 2659;
            if (phosphorus_ingress_trace) try diagnostics.logPhosphorusRepresentation(context, "ingress_before_topsoil_change_rebase");
            for (0..context.grid.cell_count) |cell| {
                const topsoil = try context.grid.layerIndex(cell, 0);
                // ISSUE-065 DRY_CARRIER_TRACE: bounded, hour-2,894-windowed
                // capture of `dry_reference_water_m3`'s stored value at the
                // point it is read/consumed, per issue-065's addendum
                // (`water_carrier_rebase.zig`'s `rememberDryCarrier` theory).
                // Exploratory scratch instrumentation, not gated permanently.
                const dry_carrier_trace_2894 = context.executed_weather_hours.* >= 2888 and
                    context.executed_weather_hours.* < 2896 and topsoil == 0;
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=topsoil_vapor_rebase hour={d} cell={d} layer={d} old_water_m3={e} new_water_m3={e} negligible_water_volume_m3={e} dry_reference_before={e}",
                    .{
                        context.executed_weather_hours.* + 1,
                        cell,
                        topsoil,
                        self.topsoil_water_before_vapor_m3[cell],
                        context.grid.matrix_liquid_water_m3[topsoil],
                        ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[cell]),
                        context.soil_chemistry.dry_reference_water_m3[topsoil],
                    },
                );
                try ecosys.soil_chemistry_water_carrier_rebase.rebaseLayer(
                    context.soil_chemistry,
                    topsoil,
                    self.topsoil_water_before_vapor_m3[cell],
                    context.grid.matrix_liquid_water_m3[topsoil],
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[cell]),
                );
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=topsoil_vapor_rebase hour={d} cell={d} layer={d} dry_reference_after={e}",
                    .{ context.executed_weather_hours.* + 1, cell, topsoil, context.soil_chemistry.dry_reference_water_m3[topsoil] },
                );
            }
            if (phosphorus_ingress_trace) try diagnostics.logPhosphorusRepresentation(context, "ingress_after_topsoil_change_rebase");
            // Same rule for the ingress carrier: capture it exactly rather than
            // reconstructing it as `new - ingress_m3` afterwards.
            for (0..context.grid.cell_count) |cell|
                self.topsoil_water_before_ingress_m3[cell] =
                    context.grid.matrix_liquid_water_m3[try context.grid.layerIndex(cell, 0)];
            // ISSUE-079 CREEP_TRACE: bounded (hours 100-200, cell 0), one-pass
            // diagnostic to localize the winter multi-layer liquid-water creep
            // (layers 2-6 rising +0.05/1000h while runoff/ET are negligible).
            // Not gated permanently; exploratory scratch instrumentation.
            const issue079_creep_trace = !builtin.is_test and
                self.context.executed_weather_hours.* >= 99 and
                self.context.executed_weather_hours.* < 200;
            if (issue079_creep_trace) {
                const cell = 0;
                var layer_water: [7]f64 = undefined;
                for (0..7) |layer| layer_water[layer] =
                    context.grid.matrix_liquid_water_m3[try context.grid.layerIndex(cell, layer)];
                std.log.info(
                    "ISSUE079_CREEP_TRACE stage=pre_ingress hour={d} dt_hours={e} matrix_rate_m3_per_h={e} macro_rate_m3_per_h={e} l0={e} l1={e} l2={e} l3={e} l4={e} l5={e} l6={e}",
                    .{
                        context.executed_weather_hours.* + 1,
                        time_step_hours,
                        context.surface_precipitation.water_to_matrix_m3_per_h[cell],
                        context.surface_precipitation.water_to_macropore_m3_per_h[cell],
                        layer_water[0], layer_water[1], layer_water[2], layer_water[3],
                        layer_water[4], layer_water[5], layer_water[6],
                    },
                );
            }
            try ecosys.surface_precipitation.state_updateSoilIngress(
                context.surface_precipitation,
                context.grid,
                context.transport_hydrology,
                time_step_hours,
                context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
            );
            if (issue079_creep_trace) {
                const cell = 0;
                var layer_water: [7]f64 = undefined;
                for (0..7) |layer| layer_water[layer] =
                    context.grid.matrix_liquid_water_m3[try context.grid.layerIndex(cell, layer)];
                std.log.info(
                    "ISSUE079_CREEP_TRACE stage=post_ingress hour={d} l0={e} l1={e} l2={e} l3={e} l4={e} l5={e} l6={e}",
                    .{
                        context.executed_weather_hours.* + 1,
                        layer_water[0], layer_water[1], layer_water[2], layer_water[3],
                        layer_water[4], layer_water[5], layer_water[6],
                    },
                );
            }
            if (phosphorus_ingress_trace) try diagnostics.logPhosphorusRepresentation(context, "ingress_before_soil_ingress_rebase");
            for (0..context.grid.cell_count) |cell| {
                const topsoil = try context.grid.layerIndex(cell, 0);
                // ISSUE-065 DRY_CARRIER_TRACE, see the topsoil_vapor_rebase
                // site above for rationale.
                const dry_carrier_trace_2894 = context.executed_weather_hours.* >= 2888 and
                    context.executed_weather_hours.* < 2896 and topsoil == 0;
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=soil_ingress_rebase hour={d} cell={d} layer={d} old_water_m3={e} new_water_m3={e} negligible_water_volume_m3={e} dry_reference_before={e}",
                    .{
                        context.executed_weather_hours.* + 1,
                        cell,
                        topsoil,
                        self.topsoil_water_before_ingress_m3[cell],
                        context.grid.matrix_liquid_water_m3[topsoil],
                        ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[cell]),
                        context.soil_chemistry.dry_reference_water_m3[topsoil],
                    },
                );
                try ecosys.soil_chemistry_water_carrier_rebase.rebaseLayer(
                    context.soil_chemistry,
                    topsoil,
                    self.topsoil_water_before_ingress_m3[cell],
                    context.grid.matrix_liquid_water_m3[topsoil],
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[cell]),
                );
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=soil_ingress_rebase hour={d} cell={d} layer={d} dry_reference_after={e}",
                    .{ context.executed_weather_hours.* + 1, cell, topsoil, context.soil_chemistry.dry_reference_water_m3[topsoil] },
                );
            }
            if (phosphorus_ingress_trace) try diagnostics.logPhosphorusRepresentation(context, "ingress_after_soil_ingress_rebase");
            try addFiniteSlices(context.ground_surface_evaporation_m3_per_h, self.evaporation_step_m3);
            try addFiniteSlices(context.ground_surface_condensation_m3_per_h, self.condensation_step_m3);
            try addFiniteSlices(context.ground_surface_litter_water_change_m3, self.litter_change_step_m3);
            try addFiniteSlices(context.ground_surface_topsoil_water_change_m3, self.accepted_topsoil_vapor_change_m3);
            try addFiniteSlices(self.litter_evaporation_total_m3, self.litter_evaporation_step_m3);
            try addFiniteSlices(self.topsoil_evaporation_total_m3, self.topsoil_evaporation_step_m3);
            try addFiniteSlices(self.litter_condensation_total_m3, self.litter_condensation_step_m3);
            try addFiniteSlices(self.topsoil_condensation_total_m3, self.topsoil_condensation_step_m3);
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.topsoil_vapor_heat_total_megajoules);
            self.allocator.free(self.topsoil_condensation_total_m3);
            self.allocator.free(self.litter_condensation_total_m3);
            self.allocator.free(self.topsoil_evaporation_total_m3);
            self.allocator.free(self.litter_evaporation_total_m3);
            self.allocator.free(self.accepted_topsoil_vapor_change_m3);
            self.allocator.free(self.accepted_topsoil_liquid_change_m3);
            self.allocator.free(self.accepted_litter_vapor_change_m3);
            self.allocator.free(self.topsoil_condensation_step_m3);
            self.allocator.free(self.litter_condensation_step_m3);
            self.allocator.free(self.topsoil_evaporation_step_m3);
            self.allocator.free(self.litter_evaporation_step_m3);
            self.allocator.free(self.topsoil_change_step_m3);
            self.allocator.free(self.litter_ingress_step_m3);
            self.allocator.free(self.litter_change_step_m3);
            self.allocator.free(self.condensation_step_m3);
            self.allocator.free(self.evaporation_step_m3);
            self.allocator.free(self.topsoil_change_original_m3);
            self.allocator.free(self.litter_change_original_m3);
            self.allocator.free(self.condensation_original_m3);
            self.allocator.free(self.evaporation_original_m3);
            self.allocator.free(self.litter_water_m3);
            self.allocator.free(self.topsoil_water_before_ingress_m3);
            self.allocator.free(self.topsoil_water_before_vapor_m3);
            self.allocator.free(self.litter_water_before_ingress_m3);
            self.litter_chemistry.deinit();
            self.soil_chemistry.deinit();
            self.* = undefined;
        }
    };
}

fn addFiniteSlices(total: []f64, part: []const f64) !void {
    if (total.len != part.len) return error.SoilForcingSubstepDimensionMismatch;
    for (total, part) |*sum, value| {
        const next = sum.* + value;
        if (!std.math.isFinite(sum.*) or !std.math.isFinite(value) or !std.math.isFinite(next))
            return error.NonFiniteSoilForcingSubstepAccumulation;
        sum.* = next;
    }
}

/// Retains gross accepted interface traffic in each direction. Hourly net
/// water and donor-temperature carrier heat cannot be paired after vapor
/// reverses direction between substeps: their independent nets may cancel or
/// even have opposite signs. The local conservation ledger therefore consumes
/// these non-negative direction-separated totals instead.
fn addSignedDirectionalSlices(
    downward_total: []f64,
    upward_total: []f64,
    part: []const f64,
) !void {
    if (downward_total.len != part.len or upward_total.len != part.len)
        return error.SoilForcingSubstepDimensionMismatch;
    for (downward_total, upward_total, part) |*downward, *upward, value| {
        if (!std.math.isFinite(value))
            return error.NonFiniteSoilForcingSubstepAccumulation;
        const destination = if (value >= 0) downward else upward;
        const magnitude = @abs(value);
        const next = destination.* + magnitude;
        if (!std.math.isFinite(destination.*) or !std.math.isFinite(next))
            return error.NonFiniteSoilForcingSubstepAccumulation;
        destination.* = next;
    }
}

test "signed interface accumulation retains gross directional activity" {
    var downward = [_]f64{0};
    var upward = [_]f64{0};
    try addSignedDirectionalSlices(&downward, &upward, &.{2});
    try addSignedDirectionalSlices(&downward, &upward, &.{-2});
    try std.testing.expectEqual(@as(f64, 2), downward[0]);
    try std.testing.expectEqual(@as(f64, 2), upward[0]);
    try std.testing.expectEqual(@as(f64, 0), downward[0] - upward[0]);
}

/// Publishes the one-hour gross ground exchange expected by the legacy
/// `_m3_per_h` diagnostic owners.  The coupled schedule's component totals are
/// already integrated substep volumes; summing each `step_volume / dt` rate
/// would multiply litter/topsoil exchange by the accepted substep count.
fn composeAcceptedGroundSurfaceWaterTotals(
    evaporation_m3_per_h: []f64,
    condensation_m3_per_h: []f64,
    litter_evaporation_total_m3: []const f64,
    topsoil_evaporation_total_m3: []const f64,
    snow_evaporation_total_m3: []const f64,
    litter_condensation_total_m3: []const f64,
    topsoil_condensation_total_m3: []const f64,
    snow_condensation_total_m3: []const f64,
) !void {
    const cells = evaporation_m3_per_h.len;
    for ([_][]const f64{
        condensation_m3_per_h,
        litter_evaporation_total_m3,
        topsoil_evaporation_total_m3,
        snow_evaporation_total_m3,
        litter_condensation_total_m3,
        topsoil_condensation_total_m3,
        snow_condensation_total_m3,
    }) |values| if (values.len != cells)
        return error.AcceptedGroundSurfaceWaterDimensionMismatch;
    for (0..cells) |cell| {
        inline for (.{
            litter_evaporation_total_m3[cell],
            topsoil_evaporation_total_m3[cell],
            snow_evaporation_total_m3[cell],
            litter_condensation_total_m3[cell],
            topsoil_condensation_total_m3[cell],
            snow_condensation_total_m3[cell],
        }) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidAcceptedGroundSurfaceWater;
        evaporation_m3_per_h[cell] = try checkedAddFiniteValue(
            try checkedAddFiniteValue(
                litter_evaporation_total_m3[cell],
                topsoil_evaporation_total_m3[cell],
            ),
            snow_evaporation_total_m3[cell],
        );
        condensation_m3_per_h[cell] = try checkedAddFiniteValue(
            try checkedAddFiniteValue(
                litter_condensation_total_m3[cell],
                topsoil_condensation_total_m3[cell],
            ),
            snow_condensation_total_m3[cell],
        );
    }
}

/// The spatial soil solver deliberately excludes its mixed cell heat-source
/// array from external-boundary publication because that array also contains
/// internal surface-to-soil conduction.  Topsoil/ground-air vapor and sensible
/// heat are the disjoint atmospheric part and must therefore be booked from
/// their producer-owned accepted totals, exactly once.
fn accumulateAcceptedTopsoilAtmosphericHeat(
    cell_ledger: *ecosys.hourly_cell_conservation.BoundaryLedger,
    landscape_ledger: *ecosys.landscape_boundary_ledger.State,
    signed_heat_megajoules_by_cell: []const f64,
) !void {
    try cell_ledger.preflightSignedHeat(signed_heat_megajoules_by_cell);
    var signed_landscape_heat_megajoules: f64 = 0;
    for (signed_heat_megajoules_by_cell) |value|
        signed_landscape_heat_megajoules = try checkedAddFiniteValue(
            signed_landscape_heat_megajoules,
            value,
        );
    var landscape_candidate = landscape_ledger.*;
    try landscape_candidate.accumulateAcceptedSignedHeat(
        signed_landscape_heat_megajoules,
    );
    try cell_ledger.accumulateSignedHeat(signed_heat_megajoules_by_cell);
    landscape_ledger.* = landscape_candidate;
}

fn checkedAddFiniteValue(left: f64, right: f64) !f64 {
    const result = left + right;
    if (!std.math.isFinite(left) or !std.math.isFinite(right) or !std.math.isFinite(result))
        return error.NonFiniteCoupledSubstepTotal;
    return result;
}

const AcceptedSurfaceResidualBudget = struct {
    signed_total_megajoules: []const f64,
    absolute_total_megajoules: []const f64,
    net_radiation_megajoules_per_m2: []const f64,
    sensible_heat_megajoules_per_m2: []const f64,
    latent_heat_megajoules_per_m2: []const f64,
    vapor_sensible_heat_megajoules_per_m2: []const f64,
    conductive_heat_megajoules_per_m2: []const f64,
    phase_heat_megajoules_per_m2: []const f64,
    snow_boundary_heat_megajoules: []const f64,
    snow_reference_state_heat_megajoules: []const f64,
    external_heat_megajoules: []const f64,
    cell_area_m2: []const f64,
    absolute_tolerance_megajoules_per_m2: f64,
    relative_tolerance: f64,
    substep_count: u8,
};

fn requireAcceptedSurfaceResidualBudget(budget: AcceptedSurfaceResidualBudget) !void {
    const cell_count = budget.signed_total_megajoules.len;
    if (cell_count == 0 or
        budget.absolute_total_megajoules.len != cell_count or
        budget.net_radiation_megajoules_per_m2.len != cell_count or
        budget.sensible_heat_megajoules_per_m2.len != cell_count or
        budget.latent_heat_megajoules_per_m2.len != cell_count or
        budget.vapor_sensible_heat_megajoules_per_m2.len != cell_count or
        budget.conductive_heat_megajoules_per_m2.len != cell_count or
        budget.phase_heat_megajoules_per_m2.len != cell_count or
        budget.snow_boundary_heat_megajoules.len != cell_count or
        budget.snow_reference_state_heat_megajoules.len != cell_count or
        budget.external_heat_megajoules.len != cell_count or
        budget.cell_area_m2.len != cell_count or
        !std.math.isFinite(budget.absolute_tolerance_megajoules_per_m2) or
        budget.absolute_tolerance_megajoules_per_m2 < 0 or
        !std.math.isFinite(budget.relative_tolerance) or
        budget.relative_tolerance <= 0 or budget.substep_count == 0)
        return error.InvalidSurfaceEnergyResidualBudget;
    // Per accepted substep this covers the residual rate*dt*area reduction,
    // the six integrated surface-flux lanes below, and the direct phase lane.
    // The fixed tail covers the two directional reductions and comparisons.
    const operation_count = 16.0 *
        @as(f64, @floatFromInt(budget.substep_count)) + 16.0;
    const scaled_epsilon = operation_count * std.math.floatEps(f64);
    if (scaled_epsilon >= 1) return error.InvalidSurfaceEnergyResidualBudget;
    const gamma = scaled_epsilon / (1.0 - scaled_epsilon);
    for (0..cell_count) |cell| {
        const signed_total = budget.signed_total_megajoules[cell];
        const absolute_total = budget.absolute_total_megajoules[cell];
        const area_m2 = budget.cell_area_m2[cell];
        const combined_atmospheric_heat_megajoules_per_m2 =
            budget.net_radiation_megajoules_per_m2[cell] +
            budget.sensible_heat_megajoules_per_m2[cell] +
            budget.latent_heat_megajoules_per_m2[cell] +
            budget.vapor_sensible_heat_megajoules_per_m2[cell];
        // The shared diagnostics include snow. Match the surface-scope ledger
        // exactly by removing snow's independently owned represented boundary
        // heat before routing the remaining atmosphere exchange by direction.
        const combined_atmospheric_heat_megajoules =
            combined_atmospheric_heat_megajoules_per_m2 * area_m2;
        const atmospheric_heat_megajoules =
            combined_atmospheric_heat_megajoules -
            (budget.snow_boundary_heat_megajoules[cell] -
                budget.snow_reference_state_heat_megajoules[cell]);
        const conductive_heat_megajoules =
            budget.conductive_heat_megajoules_per_m2[cell] * area_m2;
        const phase_heat_megajoules =
            budget.phase_heat_megajoules_per_m2[cell] * area_m2;
        const hourly_activity_megajoules =
            @abs(atmospheric_heat_megajoules) +
            @abs(budget.external_heat_megajoules[cell]) +
            @abs(conductive_heat_megajoules) +
            @abs(phase_heat_megajoules);
        const physical_limit_megajoules =
            budget.absolute_tolerance_megajoules_per_m2 * area_m2 +
            budget.relative_tolerance * hourly_activity_megajoules;
        const arithmetic_magnitude_megajoules =
            @abs(combined_atmospheric_heat_megajoules) +
            @abs(budget.snow_boundary_heat_megajoules[cell]) +
            @abs(budget.snow_reference_state_heat_megajoules[cell]) +
            @abs(budget.external_heat_megajoules[cell]) +
            @abs(conductive_heat_megajoules) + @abs(phase_heat_megajoules);
        if (!std.math.isFinite(signed_total) or
            !std.math.isFinite(absolute_total) or absolute_total < 0 or
            !std.math.isFinite(area_m2) or area_m2 <= 0 or
            !std.math.isFinite(combined_atmospheric_heat_megajoules_per_m2) or
            !std.math.isFinite(combined_atmospheric_heat_megajoules) or
            !std.math.isFinite(atmospheric_heat_megajoules) or
            !std.math.isFinite(conductive_heat_megajoules) or
            !std.math.isFinite(phase_heat_megajoules) or
            !std.math.isFinite(hourly_activity_megajoules) or
            !std.math.isFinite(arithmetic_magnitude_megajoules) or
            !std.math.isFinite(physical_limit_megajoules) or
            physical_limit_megajoules <= 0)
            return error.InvalidSurfaceEnergyResidualBudget;
        // This certifies only arithmetic in the attempt-private reductions and
        // comparison. It is not a physical tolerance or a ledger adjustment.
        const roundoff_allowance = gamma *
            (@abs(signed_total) + absolute_total + physical_limit_megajoules +
                arithmetic_magnitude_megajoules);
        if (!std.math.isFinite(roundoff_allowance) or
            @abs(signed_total) > absolute_total + roundoff_allowance or
            absolute_total > physical_limit_megajoules + roundoff_allowance)
        {
            if (!builtin.is_test) {
                std.log.err(
                    "accepted surface energy residual budget failed: cell={d} signed_megajoules={e} absolute_megajoules={e} physical_limit_megajoules={e} arithmetic_allowance={e} substep_count={d} hourly_activity_megajoules={e} arithmetic_magnitude_megajoules={e} absolute_tolerance_mj_m2={e} relative_tolerance={e} area_m2={e}",
                    .{
                        cell,
                        signed_total,
                        absolute_total,
                        physical_limit_megajoules,
                        roundoff_allowance,
                        budget.substep_count,
                        hourly_activity_megajoules,
                        arithmetic_magnitude_megajoules,
                        budget.absolute_tolerance_megajoules_per_m2,
                        budget.relative_tolerance,
                        area_m2,
                    },
                );
                // REAL-DECK-HOUR-11-FATAL-STAGNATION-001 (2026-09-04): the
                // aggregation/tolerance design itself is confirmed correct
                // (see "surface residual budget rejects same-sign
                // accumulation and hidden cancellation" above) -- this
                // per-lane breakdown is to isolate which flux term is the
                // actual source of the small genuine accumulated defect.
                std.log.err(
                    "accepted surface energy residual budget failed lanes: cell={d} net_radiation_mj_m2={e} sensible_heat_mj_m2={e} latent_heat_mj_m2={e} vapor_sensible_heat_mj_m2={e} conductive_heat_mj_m2={e} phase_heat_mj_m2={e} snow_boundary_heat_mj={e} snow_reference_state_heat_mj={e} external_heat_mj={e}",
                    .{
                        cell,
                        budget.net_radiation_megajoules_per_m2[cell],
                        budget.sensible_heat_megajoules_per_m2[cell],
                        budget.latent_heat_megajoules_per_m2[cell],
                        budget.vapor_sensible_heat_megajoules_per_m2[cell],
                        budget.conductive_heat_megajoules_per_m2[cell],
                        budget.phase_heat_megajoules_per_m2[cell],
                        budget.snow_boundary_heat_megajoules[cell],
                        budget.snow_reference_state_heat_megajoules[cell],
                        budget.external_heat_megajoules[cell],
                    },
                );
            }
            return error.SurfaceEnergyConservationFailure;
        }
    }
}

test "surface residual budget rejects same-sign accumulation and hidden cancellation" {
    const substeps: u8 = 32;
    var signed_total: f64 = 0;
    var absolute_total: f64 = 0;
    const dt = 1.0 / @as(f64, @floatFromInt(substeps));
    for (0..substeps) |_| {
        const residual_rate: f64 = 2.0e-9;
        signed_total += residual_rate * dt;
        absolute_total += @abs(residual_rate) * dt;
    }
    try std.testing.expectError(
        error.SurfaceEnergyConservationFailure,
        requireAcceptedSurfaceResidualBudget(.{
            .signed_total_megajoules = &.{signed_total},
            .absolute_total_megajoules = &.{absolute_total},
            .net_radiation_megajoules_per_m2 = &.{0},
            .sensible_heat_megajoules_per_m2 = &.{0},
            .latent_heat_megajoules_per_m2 = &.{0},
            .vapor_sensible_heat_megajoules_per_m2 = &.{0},
            .conductive_heat_megajoules_per_m2 = &.{0},
            .phase_heat_megajoules_per_m2 = &.{0},
            .snow_boundary_heat_megajoules = &.{0},
            .snow_reference_state_heat_megajoules = &.{0},
            .external_heat_megajoules = &.{0},
            .cell_area_m2 = &.{1},
            .absolute_tolerance_megajoules_per_m2 = 1.0e-9,
            .relative_tolerance = 1.0e-9,
            .substep_count = substeps,
        }),
    );

    // Equal and opposite substeps may close the signed total, but the local
    // process defect remains material and must still fail on its absolute lane.
    try std.testing.expectError(
        error.SurfaceEnergyConservationFailure,
        requireAcceptedSurfaceResidualBudget(.{
            .signed_total_megajoules = &.{0},
            .absolute_total_megajoules = &.{2.0e-9},
            .net_radiation_megajoules_per_m2 = &.{0},
            .sensible_heat_megajoules_per_m2 = &.{0},
            .latent_heat_megajoules_per_m2 = &.{0},
            .vapor_sensible_heat_megajoules_per_m2 = &.{0},
            .conductive_heat_megajoules_per_m2 = &.{0},
            .phase_heat_megajoules_per_m2 = &.{0},
            .snow_boundary_heat_megajoules = &.{0},
            .snow_reference_state_heat_megajoules = &.{0},
            .external_heat_megajoules = &.{0},
            .cell_area_m2 = &.{1},
            .absolute_tolerance_megajoules_per_m2 = 1.0e-9,
            .relative_tolerance = 1.0e-9,
            .substep_count = substeps,
        }),
    );
    try requireAcceptedSurfaceResidualBudget(.{
        .signed_total_megajoules = &.{0.5e-9},
        .absolute_total_megajoules = &.{0.75e-9},
        .net_radiation_megajoules_per_m2 = &.{0},
        .sensible_heat_megajoules_per_m2 = &.{0},
        .latent_heat_megajoules_per_m2 = &.{0},
        .vapor_sensible_heat_megajoules_per_m2 = &.{0},
        .conductive_heat_megajoules_per_m2 = &.{0},
        .phase_heat_megajoules_per_m2 = &.{0},
        .snow_boundary_heat_megajoules = &.{0},
        .snow_reference_state_heat_megajoules = &.{0},
        .external_heat_megajoules = &.{0},
        .cell_area_m2 = &.{1},
        .absolute_tolerance_megajoules_per_m2 = 1.0e-9,
        .relative_tolerance = 1.0e-9,
        .substep_count = substeps,
    });
}

test "surface residual budget uses hourly net activity after substep reversal" {
    const substeps: u8 = 2;
    const dt: f64 = 0.5;
    const residual_rate: f64 = 5.0e-10;
    const signed_total = 2.0 * residual_rate * dt;
    const absolute_total = 2.0 * @abs(residual_rate) * dt;
    const absolute_tolerance: f64 = 1.0e-12;
    const relative_tolerance: f64 = 1.0e-9;
    const old_summed_substep_limit = 2.0 *
        (absolute_tolerance + relative_tolerance * 1.0) * dt;
    try std.testing.expect(absolute_total < old_summed_substep_limit);
    try std.testing.expectError(
        error.SurfaceEnergyConservationFailure,
        requireAcceptedSurfaceResidualBudget(.{
            .signed_total_megajoules = &.{signed_total},
            .absolute_total_megajoules = &.{absolute_total},
            // The atmospheric lane was +1 then -1 MJ m-2 h-1. Its accepted
            // hourly directional amount is zero, so relative tolerance cannot
            // be retained from activity that cancelled before publication.
            .net_radiation_megajoules_per_m2 = &.{0},
            .sensible_heat_megajoules_per_m2 = &.{0},
            .latent_heat_megajoules_per_m2 = &.{0},
            .vapor_sensible_heat_megajoules_per_m2 = &.{0},
            .conductive_heat_megajoules_per_m2 = &.{0},
            .phase_heat_megajoules_per_m2 = &.{0},
            .snow_boundary_heat_megajoules = &.{0},
            .snow_reference_state_heat_megajoules = &.{0},
            .external_heat_megajoules = &.{0},
            .cell_area_m2 = &.{1},
            .absolute_tolerance_megajoules_per_m2 = absolute_tolerance,
            .relative_tolerance = relative_tolerance,
            .substep_count = substeps,
        }),
    );
}

test "accepted substep water and topsoil atmospheric heat close the first hourly cell" {
    // This is the production-shaped 32-substep first-hour failure.  The old
    // water publisher added the same integrated evaporation as a rate once
    // per substep, leaving exactly 31 excess copies in the hourly output.
    const excess_water_output_m3: f64 = 2.3482262927442244e-3;
    const accepted_ground_evaporation_m3 = excess_water_output_m3 / 31.0;
    const other_water_output_m3: f64 = 8.86719098873987e-4;
    var evaporation = [_]f64{0};
    var condensation = [_]f64{0};
    try composeAcceptedGroundSurfaceWaterTotals(
        &evaporation,
        &condensation,
        &.{accepted_ground_evaporation_m3},
        &.{0},
        &.{0},
        &.{0},
        &.{0},
        &.{0},
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 3.310694626868025e-3),
        other_water_output_m3 + 32.0 * accepted_ground_evaporation_m3,
        1e-18,
    );

    var ledger = try ecosys.hourly_cell_conservation.BoundaryLedger.init(
        std.testing.allocator,
        1,
    );
    defer ledger.deinit();
    try ledger.accumulate(0, .{
        .water_input_m3 = 7.375354773997088e-4,
        .water_output_m3 = other_water_output_m3 + evaporation[0],
        .heat_input_megajoules = 2.664066260587664e-4,
        .heat_output_megajoules = 1.4666672239916345,
        .heat_internal_production_megajoules = 9.288320124972521e-3,
    });
    var landscape: ecosys.landscape_boundary_ledger.State = .{};
    const topsoil_atmospheric_heat_megajoules = [_]f64{-0.8459082696815421};
    try accumulateAcceptedTopsoilAtmosphericHeat(
        &ledger,
        &landscape,
        &topsoil_atmospheric_heat_megajoules,
    );

    const before = [_]ecosys.landscape_mass_inventory.Storage{.{
        .water_m3 = 1.0203181650690767,
        .heat_megajoules = 1911.6746459686665,
    }};
    const after = [_]ecosys.landscape_mass_inventory.Storage{.{
        .water_m3 = 1.0200932322123526,
        .heat_megajoules = 1909.3716252017443,
    }};
    var report = try ecosys.hourly_cell_conservation.evaluate(
        std.testing.allocator,
        &before,
        &after,
        ledger.cells,
        &.{1},
        .{
            .absolute_per_area = .{
                .water_m = 1e-12,
                .heat_megajoules_m2 = 1e-12,
            },
            .relative = 1e-12,
        },
    );
    defer report.deinit(std.testing.allocator);
    for ([_]ecosys.hourly_cell_conservation.Quantity{
        ecosys.hourly_cell_conservation.Quantity.water,
        ecosys.hourly_cell_conservation.Quantity.heat,
    }) |quantity| {
        const closure = report.cells[0].closure[@intFromEnum(quantity)];
        try std.testing.expect(closure.accepted);
        try std.testing.expectApproxEqAbs(@as(f64, 0), closure.residual, 1e-12);
    }
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.8459082696815421),
        ledger.cells[0].heat_output_megajoules - 1.4666672239916345,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.8459082696815421),
        landscape.cumulative.heat_output_megajoules,
        1e-15,
    );
}

fn validateGroundAirGeometryBalance(
    geometry: []const ecosys.ground_air_exchange.GeometryBalance,
    cell_count: usize,
) !void {
    if (geometry.len != cell_count)
        return error.GroundAirGeometryBalanceDimensionMismatch;
    for (geometry) |entry| {
        inline for (.{
            entry.initial_vapor_storage_m3,
            entry.vapor_storage_change_m3,
            entry.atmospheric_vapor_transfer_m3,
            entry.initial_sensible_heat_megajoules,
            entry.sensible_heat_storage_change_megajoules,
            entry.atmospheric_sensible_heat_transfer_megajoules,
        }) |value| if (!std.math.isFinite(value))
            return error.NonFiniteGroundAirGeometryBalance;
        if (entry.initial_vapor_storage_m3 < 0 or
            entry.initial_sensible_heat_megajoules <= 0)
            return error.InvalidGroundAirGeometryBalance;
        if (entry.vapor_storage_change_m3 != entry.atmospheric_vapor_transfer_m3 or
            entry.sensible_heat_storage_change_megajoules != entry.atmospheric_sensible_heat_transfer_megajoules)
            return error.NonConservativeGroundAirGeometryBalance;
    }
}

fn seedGroundAirFullHourBalance(
    totals: []ecosys.ground_air_exchange.VaporBalance,
    geometry: []const ecosys.ground_air_exchange.GeometryBalance,
) void {
    for (totals, geometry) |*total, entry| total.* = .{
        .storage_change_m3 = entry.vapor_storage_change_m3,
        .atmospheric_transfer_m3 = entry.atmospheric_vapor_transfer_m3,
        .sensible_heat_storage_change_megajoules = entry.sensible_heat_storage_change_megajoules,
        .atmospheric_sensible_heat_transfer_megajoules = entry.atmospheric_sensible_heat_transfer_megajoules,
    };
}

fn accumulateGroundAirSubstepBalance(
    total: *ecosys.ground_air_exchange.VaporBalance,
    step: ecosys.ground_air_exchange.VaporBalance,
) !void {
    total.storage_change_m3 = try checkedAddFiniteValue(total.storage_change_m3, step.storage_change_m3);
    total.atmospheric_transfer_m3 = try checkedAddFiniteValue(total.atmospheric_transfer_m3, step.atmospheric_transfer_m3);
    total.zero_vapor_bound_atmospheric_transfer_m3 = try checkedAddFiniteValue(total.zero_vapor_bound_atmospheric_transfer_m3, step.zero_vapor_bound_atmospheric_transfer_m3);
    total.prescribed_non_atmospheric_transfer_m3 = try checkedAddFiniteValue(total.prescribed_non_atmospheric_transfer_m3, step.prescribed_non_atmospheric_transfer_m3);
    total.implicit_surface_transfer_m3 = try checkedAddFiniteValue(total.implicit_surface_transfer_m3, step.implicit_surface_transfer_m3);
    total.condensate_deposition_m3 = try checkedAddFiniteValue(total.condensate_deposition_m3, step.condensate_deposition_m3);
    total.condensate_deposition_latent_heat_megajoules = try checkedAddFiniteValue(total.condensate_deposition_latent_heat_megajoules, step.condensate_deposition_latent_heat_megajoules);
    total.closure_residual_m3 = try checkedAddFiniteValue(total.closure_residual_m3, step.closure_residual_m3);
    total.sensible_heat_storage_change_megajoules = try checkedAddFiniteValue(total.sensible_heat_storage_change_megajoules, step.sensible_heat_storage_change_megajoules);
    total.atmospheric_sensible_heat_transfer_megajoules = try checkedAddFiniteValue(total.atmospheric_sensible_heat_transfer_megajoules, step.atmospheric_sensible_heat_transfer_megajoules);
    total.temperature_bound_atmospheric_transfer_megajoules = try checkedAddFiniteValue(total.temperature_bound_atmospheric_transfer_megajoules, step.temperature_bound_atmospheric_transfer_megajoules);
    total.prescribed_non_atmospheric_sensible_heat_transfer_megajoules = try checkedAddFiniteValue(total.prescribed_non_atmospheric_sensible_heat_transfer_megajoules, step.prescribed_non_atmospheric_sensible_heat_transfer_megajoules);
    total.implicit_non_atmospheric_sensible_heat_transfer_megajoules = try checkedAddFiniteValue(total.implicit_non_atmospheric_sensible_heat_transfer_megajoules, step.implicit_non_atmospheric_sensible_heat_transfer_megajoules);
    total.sensible_heat_closure_residual_megajoules = try checkedAddFiniteValue(total.sensible_heat_closure_residual_megajoules, step.sensible_heat_closure_residual_megajoules);
}

test "ground air full-hour geometry is seeded once across substeps and retry reset" {
    const geometry = [_]ecosys.ground_air_exchange.GeometryBalance{.{
        .initial_vapor_storage_m3 = 0.002,
        .vapor_storage_change_m3 = 0.0004,
        .atmospheric_vapor_transfer_m3 = 0.0004,
        .initial_sensible_heat_megajoules = 21,
        .sensible_heat_storage_change_megajoules = 4,
        .atmospheric_sensible_heat_transfer_megajoules = 4,
    }};
    try validateGroundAirGeometryBalance(&geometry, 1);
    var totals: [1]ecosys.ground_air_exchange.VaporBalance = undefined;
    seedGroundAirFullHourBalance(&totals, &geometry);
    const seeded = totals[0];

    const first_substep: ecosys.ground_air_exchange.VaporBalance = .{
        .storage_change_m3 = 0.0001,
        .atmospheric_transfer_m3 = 0.00002,
        .prescribed_non_atmospheric_transfer_m3 = 0.00008,
        .sensible_heat_storage_change_megajoules = 0.3,
        .atmospheric_sensible_heat_transfer_megajoules = 0.2,
        .prescribed_non_atmospheric_sensible_heat_transfer_megajoules = 0.1,
    };
    const second_substep: ecosys.ground_air_exchange.VaporBalance = .{
        .storage_change_m3 = -0.00005,
        .atmospheric_transfer_m3 = -0.00005,
        .sensible_heat_storage_change_megajoules = -0.1,
        .atmospheric_sensible_heat_transfer_megajoules = -0.1,
    };
    try accumulateGroundAirSubstepBalance(&totals[0], first_substep);
    try accumulateGroundAirSubstepBalance(&totals[0], second_substep);
    try std.testing.expectApproxEqAbs(
        geometry[0].vapor_storage_change_m3 +
            first_substep.storage_change_m3 + second_substep.storage_change_m3,
        totals[0].storage_change_m3,
        1e-18,
    );
    try std.testing.expectApproxEqAbs(
        geometry[0].sensible_heat_storage_change_megajoules +
            first_substep.sensible_heat_storage_change_megajoules +
            second_substep.sensible_heat_storage_change_megajoules,
        totals[0].sensible_heat_storage_change_megajoules,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        totals[0].storage_change_m3,
        totals[0].atmospheric_transfer_m3 +
            totals[0].prescribed_non_atmospheric_transfer_m3 +
            totals[0].implicit_surface_transfer_m3,
        1e-18,
    );
    try std.testing.expectApproxEqAbs(
        totals[0].sensible_heat_storage_change_megajoules,
        totals[0].atmospheric_sensible_heat_transfer_megajoules +
            totals[0].prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
            totals[0].implicit_non_atmospheric_sensible_heat_transfer_megajoules,
        1e-15,
    );

    // A rejected candidate is private. Schedule rollback re-seeds the hourly
    // geometry exactly once before the accepted retry accumulates anything.
    seedGroundAirFullHourBalance(&totals, &geometry);
    try std.testing.expectEqualDeep(seeded, totals[0]);
    try accumulateGroundAirSubstepBalance(&totals[0], second_substep);
    try std.testing.expectApproxEqAbs(
        geometry[0].vapor_storage_change_m3 + second_substep.storage_change_m3,
        totals[0].storage_change_m3,
        1e-18,
    );
    try std.testing.expectApproxEqAbs(
        geometry[0].sensible_heat_storage_change_megajoules +
            second_substep.sensible_heat_storage_change_megajoules,
        totals[0].sensible_heat_storage_change_megajoules,
        1e-15,
    );
    try std.testing.expectApproxEqAbs(
        totals[0].storage_change_m3,
        totals[0].atmospheric_transfer_m3 +
            totals[0].prescribed_non_atmospheric_transfer_m3 +
            totals[0].implicit_surface_transfer_m3,
        1e-18,
    );
    try std.testing.expectApproxEqAbs(
        totals[0].sensible_heat_storage_change_megajoules,
        totals[0].atmospheric_sensible_heat_transfer_megajoules +
            totals[0].prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
            totals[0].implicit_non_atmospheric_sensible_heat_transfer_megajoules,
        1e-15,
    );
}

const PhaseRecipientState = struct {
    matrix_liquid_water_m3: f64,
    matrix_ice_water_equivalent_m3: f64,
    macropore_liquid_water_m3: f64,
    macropore_ice_water_equivalent_m3: f64,
    temperature_k: f64,
    heat_capacity_megajoules_per_k: f64,
};

const RoutedPhaseRecipient = struct {
    state: PhaseRecipientState,
    upward: ecosys.soil_water_heat_step.PhaseDisplacement,
};

fn validatePhaseDisplacement(value: ecosys.soil_water_heat_step.PhaseDisplacement) !void {
    inline for (.{
        value.matrix_liquid_water_m3,
        value.matrix_ice_water_equivalent_m3,
        value.macropore_liquid_water_m3,
        value.macropore_ice_water_equivalent_m3,
        value.advective_enthalpy_megajoules,
    }) |component| if (!std.math.isFinite(component) or component < 0)
        return error.InvalidAcceptedSoilPhaseDisplacement;
    // WATSUB 4898--4902 and 4987--4990 expel liquid only. Carrying ice here
    // would invent a different phase recipient and a different enthalpy law.
    if (value.matrix_ice_water_equivalent_m3 != 0 or
        value.macropore_ice_water_equivalent_m3 != 0)
        return error.UnsupportedAcceptedSoilPhaseIceDisplacement;
}

/// Credits a lower layer's accepted FLWL/FLWHL-equivalent carrier, then
/// propagates any new rigid-pore overfill plus this recipient's own already-
/// debited displacement to the next shallower layer. All terms are positive
/// upward and remain separated by pore domain.
fn routePhaseDisplacementIntoSoilRecipient(
    state: PhaseRecipientState,
    incoming: ecosys.soil_water_heat_step.PhaseDisplacement,
    own_displacement: ecosys.soil_water_heat_step.PhaseDisplacement,
    matrix_pore_capacity_m3: f64,
    macropore_pore_capacity_m3: f64,
    ice_density_megagrams_per_m3: f64,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
) !RoutedPhaseRecipient {
    try validatePhaseDisplacement(incoming);
    try validatePhaseDisplacement(own_displacement);
    inline for (.{
        state.matrix_liquid_water_m3,
        state.matrix_ice_water_equivalent_m3,
        state.macropore_liquid_water_m3,
        state.macropore_ice_water_equivalent_m3,
        state.temperature_k,
        state.heat_capacity_megajoules_per_k,
        matrix_pore_capacity_m3,
        macropore_pore_capacity_m3,
        ice_density_megagrams_per_m3,
        liquid_water_heat_capacity_megajoules_per_m3_k,
    }) |value| if (!std.math.isFinite(value) or value < 0)
        return error.InvalidAcceptedSoilPhaseRecipient;
    if (state.temperature_k <= 0 or state.heat_capacity_megajoules_per_k <= 0 or
        ice_density_megagrams_per_m3 <= 0 or ice_density_megagrams_per_m3 > 1 or
        liquid_water_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidAcceptedSoilPhaseRecipient;

    const matrix_ice_physical_m3 = state.matrix_ice_water_equivalent_m3 / ice_density_megagrams_per_m3;
    const macro_ice_physical_m3 = state.macropore_ice_water_equivalent_m3 / ice_density_megagrams_per_m3;
    // MATRIX-ENTRY-OVERFILL-DOMAIN-001: the accepted ENTRY state may already be
    // overfilled, and that is deliberately not fatal. WATSUB's rigid-pore
    // expulsion is rate-limited by the water available to move in the substep --
    // `watsub.f:4899-4900` is
    //   `FLQL=FLQL+AMIN1(0.0,AMAX1(-VOLW2(N6,N5,N4)*XNPHX,VOLP1Z(N6,N5,N4)))`
    // so when the overfill `VOLP1Z` exceeds `VOLW2*XNPHX` the oracle expels only
    // part of it and the remainder survives into the next substep by
    // construction. `hour1.f:4366`'s `AMAX1(0.0, VOLA-VOLW-VOLI)` clamps rather
    // than rejects, and `soil/water/solver_flux.zig:117-121` states this tree's
    // own policy in its own words: accepted entry overfill may persist
    // transiently, but a nonlinear proposal may not manufacture any additional
    // overfill.
    //
    // The second half of that policy is already structurally enforced below:
    // `matrix_overflow_m3` is bounded by `incoming`, so an already-full
    // recipient retains exactly zero and routes the whole credit upward. No
    // additional overfill can be created here, whatever the entry state.
    const matrix_candidate_m3 = try checkedAddFiniteValue(state.matrix_liquid_water_m3, incoming.matrix_liquid_water_m3);
    const macro_candidate_m3 = try checkedAddFiniteValue(state.macropore_liquid_water_m3, incoming.macropore_liquid_water_m3);
    const matrix_overflow_m3 = @min(
        incoming.matrix_liquid_water_m3,
        @max(0, matrix_candidate_m3 + matrix_ice_physical_m3 - matrix_pore_capacity_m3),
    );
    const macro_overflow_m3 = @min(
        incoming.macropore_liquid_water_m3,
        @max(0, macro_candidate_m3 + macro_ice_physical_m3 - macropore_pore_capacity_m3),
    );
    const retained_matrix_m3 = incoming.matrix_liquid_water_m3 - matrix_overflow_m3;
    const retained_macro_m3 = incoming.macropore_liquid_water_m3 - macro_overflow_m3;
    const retained_total_m3 = try checkedAddFiniteValue(retained_matrix_m3, retained_macro_m3);
    const overflow_total_m3 = try checkedAddFiniteValue(matrix_overflow_m3, macro_overflow_m3);
    const overflow_enthalpy_megajoules = liquid_water_heat_capacity_megajoules_per_m3_k *
        state.temperature_k * overflow_total_m3;
    const new_capacity = state.heat_capacity_megajoules_per_k +
        liquid_water_heat_capacity_megajoules_per_m3_k * retained_total_m3;
    const new_enthalpy = state.heat_capacity_megajoules_per_k * state.temperature_k +
        incoming.advective_enthalpy_megajoules - overflow_enthalpy_megajoules;
    const new_temperature = new_enthalpy / new_capacity;
    inline for (.{ new_capacity, new_enthalpy, new_temperature, overflow_enthalpy_megajoules }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteAcceptedSoilPhaseRecipient;
    if (new_capacity <= 0 or new_temperature <= 0)
        return error.InvalidAcceptedSoilPhaseRecipient;

    return .{
        .state = .{
            .matrix_liquid_water_m3 = state.matrix_liquid_water_m3 + retained_matrix_m3,
            .matrix_ice_water_equivalent_m3 = state.matrix_ice_water_equivalent_m3,
            .macropore_liquid_water_m3 = state.macropore_liquid_water_m3 + retained_macro_m3,
            .macropore_ice_water_equivalent_m3 = state.macropore_ice_water_equivalent_m3,
            .temperature_k = new_temperature,
            .heat_capacity_megajoules_per_k = new_capacity,
        },
        .upward = .{
            .matrix_liquid_water_m3 = try checkedAddFiniteValue(own_displacement.matrix_liquid_water_m3, matrix_overflow_m3),
            .macropore_liquid_water_m3 = try checkedAddFiniteValue(own_displacement.macropore_liquid_water_m3, macro_overflow_m3),
            .advective_enthalpy_megajoules = try checkedAddFiniteValue(own_displacement.advective_enthalpy_megajoules, overflow_enthalpy_megajoules),
        },
    };
}

const PhaseSurfaceRecipient = struct {
    liquid_water_m3: f64,
    ice_water_equivalent_m3: f64,
    temperature_k: f64,
    heat_capacity_megajoules_per_k: f64,
};

fn routePhaseDisplacementIntoSurfaceRecipient(
    state: PhaseSurfaceRecipient,
    incoming: ecosys.soil_water_heat_step.PhaseDisplacement,
    liquid_water_heat_capacity_megajoules_per_m3_k: f64,
) !PhaseSurfaceRecipient {
    try validatePhaseDisplacement(incoming);
    inline for (.{ state.liquid_water_m3, state.ice_water_equivalent_m3, state.temperature_k, state.heat_capacity_megajoules_per_k, liquid_water_heat_capacity_megajoules_per_m3_k }) |value|
        if (!std.math.isFinite(value) or value < 0)
            return error.InvalidAcceptedSoilPhaseSurfaceRecipient;
    if (state.temperature_k <= 0 or state.heat_capacity_megajoules_per_k <= 0 or
        liquid_water_heat_capacity_megajoules_per_m3_k <= 0)
        return error.InvalidAcceptedSoilPhaseSurfaceRecipient;
    const liquid_gain_m3 = try checkedAddFiniteValue(incoming.matrix_liquid_water_m3, incoming.macropore_liquid_water_m3);
    const new_capacity = state.heat_capacity_megajoules_per_k + liquid_water_heat_capacity_megajoules_per_m3_k * liquid_gain_m3;
    const new_temperature = (state.heat_capacity_megajoules_per_k * state.temperature_k +
        incoming.advective_enthalpy_megajoules) / new_capacity;
    if (!std.math.isFinite(new_capacity) or new_capacity <= 0 or
        !std.math.isFinite(new_temperature) or new_temperature <= 0)
        return error.InvalidAcceptedSoilPhaseSurfaceRecipient;
    return .{
        .liquid_water_m3 = try checkedAddFiniteValue(state.liquid_water_m3, liquid_gain_m3),
        .ice_water_equivalent_m3 = state.ice_water_equivalent_m3,
        .temperature_k = new_temperature,
        .heat_capacity_megajoules_per_k = new_capacity,
    };
}

test "WATSUB phase displacement credits an unsaturated recipient with exact water and enthalpy" {
    const incoming: ecosys.soil_water_heat_step.PhaseDisplacement = .{
        .matrix_liquid_water_m3 = 0.1,
        .advective_enthalpy_megajoules = 4.19 * 260 * 0.1,
    };
    const before: PhaseRecipientState = .{
        .matrix_liquid_water_m3 = 0.5,
        .matrix_ice_water_equivalent_m3 = 0,
        .macropore_liquid_water_m3 = 0,
        .macropore_ice_water_equivalent_m3 = 0,
        .temperature_k = 280,
        .heat_capacity_megajoules_per_k = 5,
    };
    const routed = try routePhaseDisplacementIntoSoilRecipient(before, incoming, .{}, 1, 1, 0.917, 4.19);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), routed.state.matrix_liquid_water_m3, 1e-15);
    try std.testing.expectEqual(ecosys.soil_water_heat_step.PhaseDisplacement{}, routed.upward);
    const before_water = before.matrix_liquid_water_m3 + incoming.matrix_liquid_water_m3;
    try std.testing.expectApproxEqAbs(before_water, routed.state.matrix_liquid_water_m3, 1e-15);
    const before_heat = before.heat_capacity_megajoules_per_k * before.temperature_k + incoming.advective_enthalpy_megajoules;
    const after_heat = routed.state.heat_capacity_megajoules_per_k * routed.state.temperature_k;
    try std.testing.expectApproxEqAbs(before_heat, after_heat, 1e-12);
}

test "WATSUB phase displacement cascades through a saturated recipient without loss" {
    const incoming: ecosys.soil_water_heat_step.PhaseDisplacement = .{
        .matrix_liquid_water_m3 = 0.1,
        .advective_enthalpy_megajoules = 4.19 * 260 * 0.1,
    };
    const own: ecosys.soil_water_heat_step.PhaseDisplacement = .{
        .macropore_liquid_water_m3 = 0.02,
        .advective_enthalpy_megajoules = 4.19 * 275 * 0.02,
    };
    const before: PhaseRecipientState = .{
        .matrix_liquid_water_m3 = 1,
        .matrix_ice_water_equivalent_m3 = 0,
        .macropore_liquid_water_m3 = 0,
        .macropore_ice_water_equivalent_m3 = 0,
        .temperature_k = 280,
        .heat_capacity_megajoules_per_k = 5,
    };
    const routed = try routePhaseDisplacementIntoSoilRecipient(before, incoming, own, 1, 1, 0.917, 4.19);
    try std.testing.expectEqual(@as(f64, 1), routed.state.matrix_liquid_water_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), routed.upward.matrix_liquid_water_m3, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), routed.upward.macropore_liquid_water_m3, 1e-15);
    const propagated_heat = routed.upward.advective_enthalpy_megajoules - own.advective_enthalpy_megajoules;
    const before_heat = before.heat_capacity_megajoules_per_k * before.temperature_k + incoming.advective_enthalpy_megajoules;
    const after_heat = routed.state.heat_capacity_megajoules_per_k * routed.state.temperature_k + propagated_heat;
    try std.testing.expectApproxEqAbs(before_heat, after_heat, 1e-12);
}

test "MATRIX-ENTRY-OVERFILL-DOMAIN-001 an already-overfilled recipient retains nothing and cascades the whole credit" {
    // WATSUB expels rigid-pore overfill at a rate limited by the water available
    // to move (`watsub.f:4899-4900`, AMAX1(-VOLW2*XNPHX, VOLP1Z)), so an entry
    // state can legitimately still be overfilled. Here matrix liquid is at
    // capacity and ice pushes it 0.218 m3 past it.
    const incoming: ecosys.soil_water_heat_step.PhaseDisplacement = .{
        .matrix_liquid_water_m3 = 0.1,
        .advective_enthalpy_megajoules = 4.19 * 260 * 0.1,
    };
    const before: PhaseRecipientState = .{
        .matrix_liquid_water_m3 = 1,
        .matrix_ice_water_equivalent_m3 = 0.2,
        .macropore_liquid_water_m3 = 0,
        .macropore_ice_water_equivalent_m3 = 0,
        .temperature_k = 280,
        .heat_capacity_megajoules_per_k = 5,
    };
    const physical_ice_m3 = before.matrix_ice_water_equivalent_m3 / 0.917;
    try std.testing.expect(before.matrix_liquid_water_m3 + physical_ice_m3 > 1);

    const routed = try routePhaseDisplacementIntoSoilRecipient(before, incoming, .{}, 1, 1, 0.917, 4.19);

    // Nothing is retained: a full recipient accepts none of the credit. That is
    // the second half of the policy -- no ADDITIONAL overfill is manufactured,
    // whatever the entry state was.
    try std.testing.expectEqual(@as(f64, 1), routed.state.matrix_liquid_water_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), routed.upward.matrix_liquid_water_m3, 1e-15);
    try std.testing.expectEqual(before.matrix_ice_water_equivalent_m3, routed.state.matrix_ice_water_equivalent_m3);

    // Water and heat both close: the entire credit plus its enthalpy leaves
    // upward, and the recipient's own store is untouched.
    const before_heat = before.heat_capacity_megajoules_per_k * before.temperature_k + incoming.advective_enthalpy_megajoules;
    const after_heat = routed.state.heat_capacity_megajoules_per_k * routed.state.temperature_k + routed.upward.advective_enthalpy_megajoules;
    try std.testing.expectApproxEqAbs(before_heat, after_heat, 1e-12);
}

test "MATRIX-ENTRY-OVERFILL-DOMAIN-001 non-finite and negative recipient state stay fatal" {
    const incoming: ecosys.soil_water_heat_step.PhaseDisplacement = .{ .matrix_liquid_water_m3 = 0.1, .advective_enthalpy_megajoules = 1 };
    const negative: PhaseRecipientState = .{
        .matrix_liquid_water_m3 = -1e-12,
        .matrix_ice_water_equivalent_m3 = 0,
        .macropore_liquid_water_m3 = 0,
        .macropore_ice_water_equivalent_m3 = 0,
        .temperature_k = 280,
        .heat_capacity_megajoules_per_k = 5,
    };
    try std.testing.expectError(error.InvalidAcceptedSoilPhaseRecipient, routePhaseDisplacementIntoSoilRecipient(negative, incoming, .{}, 1, 1, 0.917, 4.19));
    var cold = negative;
    cold.matrix_liquid_water_m3 = 0;
    cold.temperature_k = 0;
    try std.testing.expectError(error.InvalidAcceptedSoilPhaseRecipient, routePhaseDisplacementIntoSoilRecipient(cold, incoming, .{}, 1, 1, 0.917, 4.19));
}

test "WATSUB top phase displacement credits the canonical surface carrier exactly" {
    const incoming: ecosys.soil_water_heat_step.PhaseDisplacement = .{
        .matrix_liquid_water_m3 = 0.03,
        .macropore_liquid_water_m3 = 0.02,
        .advective_enthalpy_megajoules = 4.19 * 270 * 0.05,
    };
    const before: PhaseSurfaceRecipient = .{
        .liquid_water_m3 = 0.1,
        .ice_water_equivalent_m3 = 0.02,
        .temperature_k = 280,
        .heat_capacity_megajoules_per_k = 2,
    };
    const after = try routePhaseDisplacementIntoSurfaceRecipient(before, incoming, 4.19);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), after.liquid_water_m3, 1e-15);
    try std.testing.expectEqual(before.ice_water_equivalent_m3, after.ice_water_equivalent_m3);
    try std.testing.expectApproxEqAbs(
        before.heat_capacity_megajoules_per_k * before.temperature_k + incoming.advective_enthalpy_megajoules,
        after.heat_capacity_megajoules_per_k * after.temperature_k,
        1e-12,
    );
    try std.testing.expectError(
        error.UnsupportedAcceptedSoilPhaseIceDisplacement,
        routePhaseDisplacementIntoSurfaceRecipient(before, .{ .matrix_ice_water_equivalent_m3 = 0.01 }, 4.19),
    );
}

fn addSnowSurfaceDischarge(
    total: []ecosys.snow_solute_transport.SurfaceDischarge,
    part: []const ecosys.snow_solute_transport.SurfaceDischarge,
) !void {
    if (total.len != part.len) return error.SnowSurfaceDischargeDimensionMismatch;
    for (total, part) |*destination, source| {
        destination.litter_dry_reference_carrier_m3 = try checkedAddFiniteValue(
            destination.litter_dry_reference_carrier_m3,
            source.litter_dry_reference_carrier_m3,
        );
        for (&destination.litter_g, source.litter_g) |*value, increment| value.* = try checkedAddFiniteValue(value.*, increment);
        for (&destination.soil_nonband_g, source.soil_nonband_g) |*value, increment| value.* = try checkedAddFiniteValue(value.*, increment);
        for (&destination.soil_band_g, source.soil_band_g) |*value, increment| value.* = try checkedAddFiniteValue(value.*, increment);
        for (&destination.litter_salt_mol, source.litter_salt_mol) |*value, increment| value.* = try checkedAddFiniteValue(value.*, increment);
        for (&destination.soil_nonband_salt_mol, source.soil_nonband_salt_mol) |*value, increment| value.* = try checkedAddFiniteValue(value.*, increment);
        for (&destination.soil_band_salt_mol, source.soil_band_salt_mol) |*value, increment| value.* = try checkedAddFiniteValue(value.*, increment);
    }
}

fn addScaledSnowSurfaceDischarge(
    total: []ecosys.snow_solute_transport.SurfaceDischarge,
    hourly: []const ecosys.snow_solute_transport.SurfaceDischarge,
    fraction: f64,
) !void {
    if (total.len != hourly.len) return error.SnowSurfaceDischargeDimensionMismatch;
    if (!std.math.isFinite(fraction) or fraction < 0 or fraction > 1)
        return error.InvalidSurfaceDischargeSubstep;
    for (total, hourly) |*destination, source| {
        destination.litter_dry_reference_carrier_m3 = try checkedAddFiniteValue(
            destination.litter_dry_reference_carrier_m3,
            source.litter_dry_reference_carrier_m3 * fraction,
        );
        for (&destination.litter_g, source.litter_g) |*value, increment|
            value.* = try checkedAddFiniteValue(value.*, increment * fraction);
        for (&destination.soil_nonband_g, source.soil_nonband_g) |*value, increment|
            value.* = try checkedAddFiniteValue(value.*, increment * fraction);
        for (&destination.soil_band_g, source.soil_band_g) |*value, increment|
            value.* = try checkedAddFiniteValue(value.*, increment * fraction);
        for (&destination.litter_salt_mol, source.litter_salt_mol) |*value, increment|
            value.* = try checkedAddFiniteValue(value.*, increment * fraction);
        for (&destination.soil_nonband_salt_mol, source.soil_nonband_salt_mol) |*value, increment|
            value.* = try checkedAddFiniteValue(value.*, increment * fraction);
        for (&destination.soil_band_salt_mol, source.soil_band_salt_mol) |*value, increment|
            value.* = try checkedAddFiniteValue(value.*, increment * fraction);
    }
}

fn snowSurfaceDischargeHasActivity(
    discharge: []const ecosys.snow_solute_transport.SurfaceDischarge,
) bool {
    for (discharge) |cell| {
        if (cell.litter_dry_reference_carrier_m3 != 0) return true;
        inline for (.{
            cell.litter_g[0..],
            cell.soil_nonband_g[0..],
            cell.soil_band_g[0..],
            cell.litter_salt_mol[0..],
            cell.soil_nonband_salt_mol[0..],
            cell.soil_band_salt_mol[0..],
        }) |values| for (values) |value| if (value != 0) return true;
    }
    return false;
}

fn snowReferenceStateHeatMegajoules(
    boundary_heat_megajoules: f64,
    radiative_heat_megajoules: f64,
    latent_heat_megajoules: f64,
    carrier_sensible_heat_megajoules: f64,
    air_sensible_heat_megajoules: f64,
) !f64 {
    inline for (.{ boundary_heat_megajoules, radiative_heat_megajoules, latent_heat_megajoules, carrier_sensible_heat_megajoules, air_sensible_heat_megajoules }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteSnowReferenceStateHeat;
    const represented = radiative_heat_megajoules + latent_heat_megajoules +
        carrier_sensible_heat_megajoules + air_sensible_heat_megajoules;
    const adjustment = boundary_heat_megajoules - represented;
    if (!std.math.isFinite(represented) or !std.math.isFinite(adjustment))
        return error.NonFiniteSnowReferenceStateHeat;
    return adjustment;
}

/// WATSUB 2895--2896: SFLXG = MIN(PARSGM, VHCPG2) * (TKQG-TK1).
/// PARSGM already includes the flux timestep. The capacity bound prevents
/// explicit surface exchange from overshooting the air temperature; it is
/// source physics, not a temperature clamp or a conservation allowance.
fn acceptedTopsoilSensibleHeatMegajoules(
    conductance_megajoules_per_h_k: f64,
    heat_capacity_megajoules_per_k: f64,
    air_temperature_k: f64,
    soil_temperature_k: f64,
    time_step_hours: f64,
) !f64 {
    inline for (.{ conductance_megajoules_per_h_k, heat_capacity_megajoules_per_k, air_temperature_k, soil_temperature_k, time_step_hours }) |value|
        if (!std.math.isFinite(value)) return error.NonFiniteTopsoilSurfaceSensibleHeat;
    if (conductance_megajoules_per_h_k < 0 or heat_capacity_megajoules_per_k <= 0 or
        air_temperature_k <= 0 or soil_temperature_k <= 0 or time_step_hours <= 0 or time_step_hours > 1)
        return error.InvalidTopsoilSurfaceSensibleHeat;
    const integrated_conductance = conductance_megajoules_per_h_k * time_step_hours;
    if (!std.math.isFinite(integrated_conductance)) return error.NonFiniteTopsoilSurfaceSensibleHeat;
    const heat = @min(integrated_conductance, heat_capacity_megajoules_per_k) *
        (air_temperature_k - soil_temperature_k);
    if (!std.math.isFinite(heat)) return error.NonFiniteTopsoilSurfaceSensibleHeat;
    return heat;
}

test "topsoil sensible exchange preserves WATSUB capacity bound in both directions" {
    const capacity: f64 = 0.018109308192540922;
    const soil_temperature: f64 = 236.3331563445135;
    const air_temperature: f64 = 250.0;
    for ([_]f64{ 0.01, 0.05, 1.0 }) |time_step| {
        for ([_]bool{ false, true }) |reverse| {
            const initial = if (reverse) air_temperature else soil_temperature;
            const air = if (reverse) soil_temperature else air_temperature;
            const heat = try acceptedTopsoilSensibleHeatMegajoules(1.25, capacity, air, initial, time_step);
            const endpoint = initial + heat / capacity;
            try std.testing.expect(endpoint >= @min(initial, air));
            try std.testing.expect(endpoint <= @max(initial, air));
            try std.testing.expectApproxEqAbs(@min(1.25 * time_step, capacity) * (air - initial), heat, 1e-15);
            // Ground air receives the same accepted transfer, opposite sign.
            const air_rate = try groundAirSurfaceSensibleSourceMegajoulesPerHour(0, heat / time_step, 0, time_step);
            try std.testing.expectApproxEqAbs(@as(f64, 0), heat + air_rate * time_step, 1e-15);
        }
    }
    try std.testing.expectEqual(@as(f64, 0), try acceptedTopsoilSensibleHeatMegajoules(0, capacity, air_temperature, soil_temperature, 1));
    try std.testing.expectError(error.InvalidTopsoilSurfaceSensibleHeat, acceptedTopsoilSensibleHeatMegajoules(1, 0, air_temperature, soil_temperature, 1));
}

/// Prescribed direct sensible heat entering the near-ground dry-air control
/// volume. WATSUB 4296 debits SFLXR/SFLXG/SFLXW here, but not the VFLX*
/// sensible enthalpy carried by vapor. Those carrier terms are already owned
/// by the receiving litter, soil, or snow water/energy state.
fn groundAirSurfaceSensibleSourceMegajoulesPerHour(
    litter_air_sensible_megajoules_per_hour: f64,
    topsoil_air_sensible_megajoules_per_hour: f64,
    snow_air_sensible_megajoules: f64,
    time_step_hours: f64,
) !f64 {
    inline for (.{
        litter_air_sensible_megajoules_per_hour,
        topsoil_air_sensible_megajoules_per_hour,
        snow_air_sensible_megajoules,
        time_step_hours,
    }) |value| if (!std.math.isFinite(value))
        return error.NonFiniteGroundAirSurfaceSensibleSource;
    if (time_step_hours <= 0)
        return error.InvalidGroundAirSurfaceSensibleTimeStep;
    const source_megajoules_per_hour =
        -(litter_air_sensible_megajoules_per_hour +
            topsoil_air_sensible_megajoules_per_hour) -
        snow_air_sensible_megajoules / time_step_hours;
    if (!std.math.isFinite(source_megajoules_per_hour))
        return error.NonFiniteGroundAirSurfaceSensibleSource;
    return source_megajoules_per_hour;
}

test "ground air surface source owns direct sensible heat only" {
    // Positive SFLXR/SFLXG/SFLXW enters the receiving surface, so the exact
    // equal-and-opposite source entering ground air is negative. Vapor carrier
    // enthalpy is deliberately absent from this interface.
    try std.testing.expectEqual(
        @as(f64, -16),
        try groundAirSurfaceSensibleSourceMegajoulesPerHour(2, 3, 5.5, 0.5),
    );
    try std.testing.expectEqual(
        @as(f64, 16),
        try groundAirSurfaceSensibleSourceMegajoulesPerHour(-2, -3, -5.5, 0.5),
    );
    try std.testing.expectError(
        error.InvalidGroundAirSurfaceSensibleTimeStep,
        groundAirSurfaceSensibleSourceMegajoulesPerHour(0, 0, 0, 0),
    );
}

test "ground air dry-air source cannot regain water carrier enthalpy" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(source);
    const owner = std.mem.lastIndexOf(u8, source, "        noinline fn advanceGroundAir(") orelse
        return error.MissingAcceptedSubstepGroundAirOwner;
    const owner_end = std.mem.lastIndexOf(
        u8,
        source,
        "        noinline fn advanceSnowSurfaceEquilibrium(",
    ) orelse return error.MissingAcceptedSubstepGroundAirOwnerEnd;
    if (owner_end <= owner) return error.InvalidAcceptedSubstepGroundAirOwnerOrder;
    const body = source[owner..owner_end];
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "self.sensible_pair_conductance_megajoules_per_h_k[cell]",
    ) != null);
    inline for (.{
        "vapor_sensible_heat_flux_megajoules_per_m2",
        "topsoil_carrier_sensible",
        "snow_carrier_sensible_heat_megajoules",
    }) |forbidden| try std.testing.expect(std.mem.indexOf(u8, body, forbidden) == null);
}

/// Pointer-stable arena ownership for the large coupled-stage scratch graph.
/// `std.mem.Allocator` returned by an ArenaAllocator contains a pointer to the
/// arena object, so the arena itself must not move when the transaction is
/// returned by value. Keeping that object in one backing allocation also
/// collapses the transaction initializer's many partial-cleanup edges into a
/// single atomic owner.
const TransactionScratchArena = struct {
    backing_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,

    fn init(backing_allocator: std.mem.Allocator) !TransactionScratchArena {
        const arena = try backing_allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(backing_allocator);
        return .{ .backing_allocator = backing_allocator, .arena = arena };
    }

    fn allocator(self: *const TransactionScratchArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *TransactionScratchArena) void {
        self.arena.deinit();
        self.backing_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

test "transaction scratch arena remains valid after return move and repeated teardown" {
    var first = try TransactionScratchArena.init(std.testing.allocator);
    var moved = first;
    first = undefined;
    const moved_values = try moved.allocator().alloc(u64, 32);
    for (moved_values, 0..) |*value, index| value.* = index;
    try std.testing.expectEqual(@as(u64, 31), moved_values[31]);
    moved.deinit();

    for (0..8) |round| {
        var scratch = try TransactionScratchArena.init(std.testing.allocator);
        const values = try scratch.allocator().alloc(usize, 64 + round);
        @memset(values, round);
        try std.testing.expectEqual(round, values[values.len - 1]);
        scratch.deinit();
    }
}

fn exerciseTransactionScratchAllocation(backing_allocator: std.mem.Allocator) !void {
    var scratch = try TransactionScratchArena.init(backing_allocator);
    errdefer scratch.deinit();
    _ = try scratch.allocator().alloc(u8, 4096);
    scratch.deinit();
}

test "transaction scratch arena cleans up pointer owner after backing allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(
        error.OutOfMemory,
        exerciseTransactionScratchAllocation(failing.allocator()),
    );
}

const SavedMemoryRegion = struct {
    destination: [*]u8,
    bytes: []u8,
};

const SoilGasStepSnapshot = struct {
    destination: *ecosys.soil_gas_transport_step.State,
    state: ecosys.soil_gas_transport_step.State,

    fn capture(
        allocator: std.mem.Allocator,
        destination: *ecosys.soil_gas_transport_step.State,
    ) !SoilGasStepSnapshot {
        return .{
            .destination = destination,
            .state = try destination.clone(allocator),
        };
    }

    fn restore(self: *const SoilGasStepSnapshot) void {
        self.destination.restoreExact(&self.state) catch
            @panic("soil gas step rollback restoration failed");
    }

    fn deinit(self: *SoilGasStepSnapshot) void {
        self.state.deinit();
        self.* = undefined;
    }
};

/// Entry-state transaction for the complete heat/water/solute stage.  The
/// stage reaches several independently atomic solvers, but an error in a later
/// solver must also undo every earlier accepted contribution.  Capture only
/// stage-owned scientific state and scratch, not executor/input infrastructure.
const StageMemorySnapshot = struct {
    allocator: std.mem.Allocator,
    regions: std.ArrayList(SavedMemoryRegion) = .empty,
    dry_branch_executions: u64,
    soil_gas_transport: ?SoilGasStepSnapshot,

    fn capture(allocator: std.mem.Allocator, context: anytype) !StageMemorySnapshot {
        @setEvalBranchQuota(100_000);
        const Context = @TypeOf(context);
        var self: StageMemorySnapshot = .{
            .allocator = allocator,
            .dry_branch_executions = ecosys.surface_litter_chemistry_carrier_rebase.dry_branch_executions,
            .soil_gas_transport = if (comptime @hasField(Context, "soil_gas_transport"))
                try SoilGasStepSnapshot.capture(allocator, context.soil_gas_transport)
            else
                null,
        };
        errdefer self.deinit();
        try captureStageTransactionalFields(&self, context);
        return self;
    }

    fn restore(self: *const StageMemorySnapshot) void {
        for (self.regions.items) |region|
            @memcpy(region.destination[0..region.bytes.len], region.bytes);
        if (self.soil_gas_transport) |*snapshot| snapshot.restore();
        ecosys.surface_litter_chemistry_carrier_rebase.dry_branch_executions = self.dry_branch_executions;
    }

    fn deinit(self: *StageMemorySnapshot) void {
        if (self.soil_gas_transport) |*snapshot| snapshot.deinit();
        for (self.regions.items) |region| self.allocator.free(region.bytes);
        self.regions.deinit(self.allocator);
        self.* = undefined;
    }

    fn saveBytes(self: *StageMemorySnapshot, destination: []u8) !void {
        if (destination.len == 0) return;
        const bytes = try self.allocator.dupe(u8, destination);
        errdefer self.allocator.free(bytes);
        try self.regions.append(self.allocator, .{
            .destination = destination.ptr,
            .bytes = bytes,
        });
    }

    fn captureTopValue(self: *StageMemorySnapshot, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .pointer => |pointer| {
                if (pointer.is_const) return;
                switch (pointer.size) {
                    .slice => try self.captureSlice(T, value),
                    .one => switch (@typeInfo(pointer.child)) {
                        .@"opaque", .@"fn" => {},
                        else => {
                            try self.saveBytes(std.mem.asBytes(value));
                            try self.captureOwnedBuffers(pointer.child, value);
                        },
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn captureSlice(self: *StageMemorySnapshot, comptime Slice: type, values: Slice) !void {
        const pointer = @typeInfo(Slice).pointer;
        if (pointer.is_const) return;
        try self.saveBytes(std.mem.sliceAsBytes(values));
        if (comptime typeMayOwnBuffers(pointer.child))
            for (values) |*value| try self.captureOwnedBuffers(pointer.child, value);
    }

    /// Finds owned slice backing stores nested in a captured object.  One-item
    /// pointers are deliberately not followed: the context owns those states
    /// separately, which avoids cycles and duplicate traversal of allocators.
    fn captureOwnedBuffers(self: *StageMemorySnapshot, comptime T: type, value: *T) !void {
        switch (@typeInfo(T)) {
            .pointer => |pointer| if (pointer.size == .slice and !pointer.is_const)
                try self.captureSlice(T, value.*),
            .@"struct" => |structure| inline for (structure.fields) |field|
                if (comptime typeMayOwnBuffers(field.type))
                    try self.captureOwnedBuffers(field.type, &@field(value.*, field.name)),
            .optional => |optional| if (value.*) |*payload|
                if (comptime typeMayOwnBuffers(optional.child))
                    try self.captureOwnedBuffers(optional.child, payload),
            .array => |array| if (comptime typeMayOwnBuffers(array.child))
                for (value) |*element| try self.captureOwnedBuffers(array.child, element),
            else => {},
        }
    }
};

/// Captures the same fields, in the production context's declaration order,
/// without comparing every context field against every transactional name.
/// The former reflected membership scan performed about 38,700 comptime string
/// comparisons for each concrete hourly context and materially amplified the
/// ReleaseFast ZCU. Reduced test contexts remain supported through `@hasField`.
noinline fn captureStageTransactionalFields(snapshot: *StageMemorySnapshot, context: anytype) !void {
    // Keep these calls in declaration order: restore deliberately replays the
    // same ordered region journal. The noinline subsystem boundaries prevent
    // the full production context from becoming one large generated function.
    try captureStageLedgerAndPhysicalFields(snapshot, context);
    try captureStageTransportFields(snapshot, context);
    try captureStageSoilBiologyAndSurfaceCarrierFields(snapshot, context);
    try captureStageSurfaceBiologyAndInventoryFields(snapshot, context);
}

noinline fn captureStageLedgerAndPhysicalFields(snapshot: *StageMemorySnapshot, context: anytype) !void {
    const Context = @TypeOf(context);
    inline for (.{
        "landscape_boundary_ledger",                                  "hourly_cell_boundary_ledger",                   "hourly_layer_boundary_ledger",
        "grid",                                                       "ground_air",                                    "atmospheric_vapor_fraction",
        "ground_air_canopy_resistance_h_per_m",                       "ground_air_sensible_source_megajoules_per_h",   "delayed_live_canopy_combustion_heat_megajoules",
        "delayed_standing_dead_combustion_heat_megajoules",           "delayed_subsurface_combustion_heat_megajoules", "delayed_root_uptake_heat_megajoules",
        "delayed_surface_combustion_heat_megajoules",                 "surface_combustion_heat_megajoules_per_m2",     "ground_air_vapor_source_m3_per_h",
        "ground_air_surface_sensible_conductance_megajoules_per_h_k", "ground_air_surface_vapor_conductance_m3_per_h", "ground_air_surface_vapor_fraction",
        "ground_surface_evaporation_m3_per_h",                        "ground_surface_condensation_m3_per_h",          "ground_surface_litter_water_change_m3",
        "ground_surface_topsoil_water_change_m3",                     "snow_depth_m",                                  "surface_energy",
        "surface_temperature",                                        "surface_heat_capacity_megajoules_per_k",        "soil_thermal",
        "soil_hourly_workspace",                                      "soil_heat_solver_workspace",                    "soil_solver_properties",
        "soil_geometry",                                              "fertilizer_band",                               "surface_pond_domain_workspace",
        "soil_profile_relayering_workspace",                          "terrain_hydrology",                             "surface_runoff",
    }) |name| {
        if (comptime @hasField(Context, name))
            try snapshot.captureTopValue(@field(context, name));
    }
}

noinline fn captureStageTransportFields(snapshot: *StageMemorySnapshot, context: anytype) !void {
    const Context = @TypeOf(context);
    inline for (.{
        "surface_inorganic_nitrogen_export_g_n_per_h",            "surface_inorganic_phosphorus_export_g_p_per_h", "surface_organic_carbon_export_g_c_per_h",
        "surface_inorganic_carbon_export_g_c_per_h",              "surface_dissolved_oxygen_export_g_o_per_h",     "surface_organic_nitrogen_export_g_n_per_h",
        "surface_organic_phosphorus_export_g_p_per_h",            "surface_erosion",                               "surface_soil_mass_at_erosion_start_megagrams",
        "net_sediment_megagrams_per_h",                           "erosion_organic_carbon_net_change_g_c",         "eroded_mineral_state",
        "soil_transport_faces",                                   "soil_face_geometry",                            "soil_solute_face_parameters",
        "micropore_solute_face_flux_mol",                         "macropore_solute_face_flux_mol",                "soil_organic_face_parameters",
        "soil_organic_transport",                                 "soil_dissolved_gas_face_parameters",            "soil_dissolved_gas_transport",
        "mineral_nitrogen_transport",                             "mineral_nitrogen_face_parameters",              "soil_boundary_topology",
        "transport_hydrology",                                    "snow_transport",                                "snow_accepted_downward_g",
        "snow_accepted_downward_salt_mol",                        "snow_surface_discharge",                        "direct_surface_solute_input",
        "snowpack_internal_solute_flux_by_layer",                 "snowpack_internal_solute_flux_workspace",       "snowpack_internal_salt_flux_mol_by_layer_species",
        "snowpack_internal_salt_flux_workspace_by_layer_species", "micropore_solute_state",                        "macropore_solute_state",
    }) |name| {
        if (comptime @hasField(Context, name))
            try snapshot.captureTopValue(@field(context, name));
    }
}

noinline fn captureStageSoilBiologyAndSurfaceCarrierFields(snapshot: *StageMemorySnapshot, context: anytype) !void {
    const Context = @TypeOf(context);
    inline for (.{
        "surface_solute_transport",                    "soil_solute_boundary_net_flux_mol",   "gas_transport",
        "surface_litter_gas_transport",                "soil_reactive_nitrogen",              "soil_microbial_phosphorus",
        "soil_microbial_turnover",                     "soil_litter_colonization",            "soil_organic_sorption",
        "soil_organic_decomposition",                  "soil_organic_priming",                "soil_respiration_products",
        "daily_heterotrophic_respiration",             "soil_autotrophic_carbon",             "soil_microbial_layer_mixing",
        "soil_methane",                                "soil_microbial_oxygen",               "soil_oxygen_staging",
        "soil_nitrogen_flux_workspace",                "soil_nitrifier_environment",          "soil_microbial",
        "soil_redox_satisfaction_fraction",            "plant_available_nutrients",           "soil_atmospheric_gas_conductance_m3_per_h",
        "litter_atmospheric_gas_conductance_m3_per_h", "snow_layer_gas_diffusivity_m2_per_h", "surface_precipitation",
        "surface_pond_transition",                     "surface_litter_geometry",             "surface_litter_water_environment",
    }) |name| {
        if (comptime @hasField(Context, name))
            try snapshot.captureTopValue(@field(context, name));
    }
}

noinline fn captureStageSurfaceBiologyAndInventoryFields(snapshot: *StageMemorySnapshot, context: anytype) !void {
    const Context = @TypeOf(context);
    inline for (.{
        "surface_microbial_environment",    "surface_microbial_respiration",          "surface_microbial_oxygen",
        "surface_microbial_maintenance",    "surface_nonsymbiotic_nitrogen_fixation", "surface_microbial_substrate_uptake",
        "surface_denitrification",          "surface_microbial_assimilation",         "surface_microbial_mineral_exchange",
        "surface_topsoil_mineral_exchange", "surface_microbial_turnover",             "surface_organic_priming",
        "surface_organic_decomposition",    "surface_organic_sorption",               "surface_litter_colonization",
        "soil_chemistry",                   "eroded_chemistry_workspace",             "soil_organic",
        "surface_litter_fertilizer",        "soil_fertilizer_inventory",              "mineral_fertilizer_inventory",
        "eroded_fertilizer_workspace",      "surface_litter_ice_m3",                  "surface_charcoal_carbon_g_c",
        "litter_gas_transport",             "surface_litter_chemistry",               "surface_organic",
        "eroded_organic_workspace",
    }) |name| {
        if (comptime @hasField(Context, name))
            try snapshot.captureTopValue(@field(context, name));
    }
}

fn typeMayOwnBuffers(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and !pointer.is_const,
        .@"struct" => |structure| blk: {
            inline for (structure.fields) |field|
                if (typeMayOwnBuffers(field.type)) break :blk true;
            break :blk false;
        },
        .optional => |optional| typeMayOwnBuffers(optional.child),
        .array => |array| typeMayOwnBuffers(array.child),
        else => false,
    };
}

fn irrigationChemistryParameters(context: anytype) ecosys.subsurface_irrigation_chemistry.Parameters {
    return .{
        .molar_mass_g_per_mol = .{
            .nitrogen = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            .phosphorus = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
            .aluminum = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.aluminum,
            .iron = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.iron,
            .calcium = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.calcium,
            .magnesium = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.magnesium,
            .sodium = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.sodium,
            .potassium = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.potassium,
            .sulfur = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.sulfur,
            .chloride = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol.chloride,
        },
        .equilibrium = .{
            .aqueous = context.chemistry_reaction_parameters.*.aqueous_constants,
            .phosphate = context.chemistry_reaction_parameters.*.phosphate_constants,
        },
        // Active production additions receive live per-layer fractions at
        // their call sites; these compatibility fields are validation-only.
        .ammonium_band_fraction = 0,
        .nitrate_band_fraction = 0,
        .phosphate_band_fraction = 0,
    };
}

fn snowSurfaceExchangeParameters(context: anytype) ecosys.snow_surface_atmosphere_exchange.Parameters {
    const vapor = context.runscript.snow_vapor_parameters;
    const phase = context.runscript.soil_phase_heat_parameters;
    return .{
        .vapor_volume_prefactor_k = vapor.vapor_volume_prefactor_k,
        .equilibrium_relative_humidity = vapor.equilibrium_relative_humidity,
        .clausius_clapeyron_temperature_k = vapor.clausius_clapeyron_temperature_k,
        .reference_inverse_temperature_per_k = vapor.reference_inverse_temperature_per_k,
        .liquid_evaporation_latent_heat_megajoules_per_m3 = vapor.liquid_evaporation_latent_heat_megajoules_per_m3,
        .snow_sublimation_latent_heat_megajoules_per_m3 = vapor.snow_sublimation_latent_heat_megajoules_per_m3,
        .latent_heat_of_fusion_megajoules_per_m3 = phase.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
        .liquid_water_heat_capacity_megajoules_per_m3_k = phase.liquid_water_heat_capacity_megajoules_per_m3_k,
        .ice_heat_capacity_megajoules_per_m3_k = phase.ice_heat_capacity_megajoules_per_m3_k,
        .ice_density_megagrams_per_m3 = context.runscript.snow_ice_density_megagrams_per_m3,
        .pure_water_melting_temperature_k = phase.freeze_thaw.pure_water_freezing_temperature_k,
    };
}

fn snowDisappearanceConservationTolerances(context: anytype) ecosys.snowpack_litter_heat_water_transfer.LiveConservationTolerances {
    const absolute = context.config.mass_balance_absolute_tolerance;
    const molar_mass = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol;
    const amount_g_per_m2: [ecosys.snow_solute_transport.species_count]f64 = .{
        absolute.carbon_g_m2,
        absolute.carbon_g_m2,
        absolute.oxygen_g_m2,
        absolute.nitrogen_g_m2,
        absolute.nitrogen_g_m2,
        absolute.nitrogen_g_m2,
        absolute.nitrogen_g_m2,
        absolute.nitrogen_g_m2,
        absolute.phosphorus_g_m2,
        absolute.phosphorus_g_m2,
        absolute.ions_mol_m2 * molar_mass.aluminum,
        absolute.ions_mol_m2 * molar_mass.iron,
        absolute.ions_mol_m2 * molar_mass.calcium,
        absolute.ions_mol_m2 * molar_mass.magnesium,
        absolute.ions_mol_m2 * molar_mass.sodium,
        absolute.ions_mol_m2 * molar_mass.potassium,
        absolute.ions_mol_m2 * molar_mass.sulfur,
        absolute.ions_mol_m2 * molar_mass.chloride,
    };
    const salt_absolute_mol_per_m2 = @max(
        absolute.ions_mol_m2,
        @max(
            absolute.carbon_g_m2 / 12,
            absolute.phosphorus_g_m2 / ecosys.snow_solute_transport.phosphorus_g_per_mol,
        ),
    );
    return .{
        .water_depth_m = absolute.water_m,
        .heat_megajoules_per_m2 = absolute.heat_megajoules_m2,
        .amount_g_per_m2 = amount_g_per_m2,
        .salt_mol_per_m2 = @splat(salt_absolute_mol_per_m2),
        .relative = context.config.mass_balance_relative_tolerance,
    };
}

/// Derived from `recovery_substep_counts` (heat_step.zig), not hardcoded, so
/// `AcceptedTransportReplay`'s own fixed-size `time_step_hours` buffer (below)
/// can never be sized smaller than the ladder's true maximum. Fixes the
/// design gap documented in issue-059 -- a sibling of issue-058's
/// `maximum_bounded_recovery_substeps` fix, but in a different, previously
/// unaudited consumer: this constant previously hardcoded `64`
/// independently of the ladder, so extending `recovery_substep_counts` past
/// `64` let `substep_capacity` (a separate runtime field, see
/// `validatedTransportReplaySubstepCapacity` below) legitimately grow past
/// `64` while the fixed `time_step_hours` array stayed at its old size --
/// overflowing it at `hourly_heat_water_solute.zig:2663`'s
/// `self.time_step_hours[self.count] = time_step_hours;` once `count`
/// reached `64`.
const maximum_transport_replay_substeps: usize =
    ecosys.soil_water_heat_step.recovery_substep_counts[
        ecosys.soil_water_heat_step.recovery_substep_counts.len - 1
    ];
const transport_grid_carrier_count: usize = ecosys.soil_water_heat_step.deferred_grid_carrier_count;
const transport_surface_carrier_count: usize = 3;
const transport_surface_geometry_carrier_count: usize = 4;

fn validatedTransportReplaySubstepCapacity(exact_substep_count: u8) !usize {
    for (ecosys.soil_water_heat_step.recovery_substep_counts) |allowed| {
        if (exact_substep_count != allowed) continue;
        const capacity: usize = @intCast(exact_substep_count);
        // Defense in depth (issue-059): `maximum_transport_replay_substeps`
        // is derived from this same array's maximum above, so `capacity`
        // can never actually exceed it while that derivation holds -- but a
        // future refactor that decouples them again (the exact defect shape
        // issue-059 found) now fails loudly here with a real, ReleaseFast-
        // surviving check, instead of silently overflowing
        // `time_step_hours` inside `beginSubstep`.
        if (capacity > maximum_transport_replay_substeps)
            return error.TransportReplaySubstepCapacityExceedsBuffer;
        return capacity;
    }
    return error.InvalidTransportReplaySubstepCapacity;
}

/// Reference TRNSFR loops over WATSUB's per-M `VOLWM/VOLWHM/FLWM` snapshots
/// after NITRO/UPTAKE/SOLUTE (`trnsfr.f:992--996,3985--4056`). This bounded
/// schedule carries the same accepted per-substep carriers while leaving all
/// transported inventories untouched until the source-ordered replay.
fn AcceptedTransportReplay(comptime Context: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        context: Context,
        count: usize = 0,
        final_captured: bool = false,
        restore_captured: bool = false,
        final_surface_geometry_captured: bool = false,
        layer_count: usize,
        cell_count: usize,
        face_count: usize,
        values_per_step: usize,
        substep_capacity: usize,
        time_step_hours: [maximum_transport_replay_substeps]f64 = @splat(0),
        accepted_values: []f64,
        accepted_surface_geometry_values: []f64,
        litter_soil_water_flux_m3: []f64,
        final_values: []f64,
        restore_values: []f64,
        final_surface_geometry_values: []f64,

        fn init(
            allocator: std.mem.Allocator,
            context: Context,
            exact_substep_count: u8,
        ) !Self {
            const substep_capacity = try validatedTransportReplaySubstepCapacity(
                exact_substep_count,
            );
            const layers = context.grid.layer_count;
            // The replay owner is generic over production and focused-test
            // grids. Its horizontal extent is the authoritative WATSUB litter
            // carrier, not an incidental Grid metadata field. Prove every
            // rebound carrier agrees before allocating or copying anything.
            const cells = context.surface_precipitation.litter_water_m3.len;
            const faces = context.soil_transport_faces.micropore_faces.len;
            if (layers == 0 or cells == 0)
                return error.TransportReplayDimensionMismatch;
            inline for (.{
                context.grid.matrix_liquid_water_m3,
                context.grid.macropore_liquid_water_m3,
                context.grid.liquid_water_m3,
                context.grid.matrix_air_volume_m3,
                context.grid.macropore_air_volume_m3,
                context.grid.air_volume_m3,
                context.grid.water_vapor_volume_m3,
                context.grid.matrix_ice_water_m3,
                context.grid.macropore_ice_water_m3,
                context.grid.ice_water_m3,
                context.grid.soil_temperature_k,
                context.grid.matric_potential_megapascal,
                context.transport_hydrology.micropore_external_water_flux_m3_per_step,
                context.transport_hydrology.macropore_external_water_flux_m3_per_step,
            }) |carrier| if (carrier.len != layers)
                return error.TransportReplayDimensionMismatch;
            inline for (.{
                context.grid.surface_temperature_k,
                context.surface_litter_ice_m3,
                context.surface_precipitation.litter_cover_fraction,
                context.surface_litter_geometry.expanded_total_volume_m3,
                context.surface_litter_geometry.pore_volume_m3,
                context.surface_litter_geometry.porosity_m3_per_m3,
            }) |carrier| if (carrier.len != cells)
                return error.TransportReplayDimensionMismatch;
            if (context.soil_transport_faces.macropore_faces.len != faces)
                return error.TransportReplayFaceDimensionMismatch;
            const grid_values = try std.math.mul(usize, transport_grid_carrier_count, layers);
            const two_faces = try std.math.mul(usize, 2, faces);
            const two_layers = try std.math.mul(usize, 2, layers);
            const surface_values = try std.math.mul(usize, transport_surface_carrier_count, cells);
            const step_width = try std.math.add(
                usize,
                grid_values,
                try std.math.add(usize, surface_values, try std.math.add(usize, two_faces, two_layers)),
            );
            const accepted = try allocator.alloc(
                f64,
                try std.math.mul(usize, substep_capacity, step_width),
            );
            errdefer allocator.free(accepted);
            const accepted_surface_geometry = try allocator.alloc(
                f64,
                try std.math.mul(
                    usize,
                    substep_capacity,
                    try std.math.mul(usize, transport_surface_geometry_carrier_count, cells),
                ),
            );
            errdefer allocator.free(accepted_surface_geometry);
            const litter_soil_flux = try allocator.alloc(
                f64,
                try std.math.mul(usize, substep_capacity, cells),
            );
            errdefer allocator.free(litter_soil_flux);
            const final = try allocator.alloc(f64, step_width);
            errdefer allocator.free(final);
            const restore_values = try allocator.alloc(f64, step_width);
            errdefer allocator.free(restore_values);
            const final_surface_geometry = try allocator.alloc(
                f64,
                try std.math.mul(usize, transport_surface_geometry_carrier_count, cells),
            );
            errdefer allocator.free(final_surface_geometry);
            @memset(accepted, 0);
            @memset(accepted_surface_geometry, 0);
            @memset(litter_soil_flux, 0);
            @memset(final, 0);
            @memset(restore_values, 0);
            @memset(final_surface_geometry, 0);
            return .{
                .allocator = allocator,
                .context = context,
                .layer_count = layers,
                .cell_count = cells,
                .face_count = faces,
                .values_per_step = step_width,
                .substep_capacity = substep_capacity,
                .accepted_values = accepted,
                .accepted_surface_geometry_values = accepted_surface_geometry,
                .litter_soil_water_flux_m3 = litter_soil_flux,
                .final_values = final,
                .restore_values = restore_values,
                .final_surface_geometry_values = final_surface_geometry,
            };
        }

        fn surfaceGeometryCarrier(self: *const Self, carrier: usize) []f64 {
            return switch (carrier) {
                0 => self.context.surface_litter_geometry.expanded_total_volume_m3,
                1 => self.context.surface_litter_geometry.pore_volume_m3,
                2 => self.context.surface_litter_geometry.porosity_m3_per_m3,
                3 => self.context.surface_precipitation.litter_cover_fraction,
                else => unreachable,
            };
        }

        fn captureSurfaceGeometryInto(self: *const Self, destination: []f64) !void {
            if (destination.len != transport_surface_geometry_carrier_count * self.cell_count)
                return error.TransportReplayDimensionMismatch;
            var cursor: usize = 0;
            for (0..transport_surface_geometry_carrier_count) |carrier| {
                @memcpy(destination[cursor..][0..self.cell_count], self.surfaceGeometryCarrier(carrier));
                cursor += self.cell_count;
            }
            for (destination) |value| if (!std.math.isFinite(value) or value < 0)
                return error.InvalidTransportReplaySurfaceGeometry;
            for (destination[2 * self.cell_count .. 4 * self.cell_count]) |fraction|
                if (fraction > 1) return error.InvalidTransportReplaySurfaceGeometry;
        }

        fn bindSurfaceGeometryFrom(self: *Self, source: []const f64) !void {
            if (source.len != transport_surface_geometry_carrier_count * self.cell_count)
                return error.TransportReplayDimensionMismatch;
            var cursor: usize = 0;
            for (0..transport_surface_geometry_carrier_count) |carrier| {
                @memcpy(self.surfaceGeometryCarrier(carrier), source[cursor..][0..self.cell_count]);
                cursor += self.cell_count;
            }
        }

        fn gridCarrier(self: *const Self, carrier: usize) []f64 {
            const grid = self.context.grid;
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

        fn gridCarrierFromSnapshot(
            self: *const Self,
            snapshot: []const f64,
            carrier: usize,
        ) ![]const f64 {
            if (snapshot.len != self.values_per_step or carrier >= transport_grid_carrier_count)
                return error.TransportReplayDimensionMismatch;
            const start = carrier * self.layer_count;
            return snapshot[start..][0..self.layer_count];
        }

        fn surfaceWaterFromSnapshot(self: *const Self, snapshot: []const f64) ![]const f64 {
            if (snapshot.len != self.values_per_step)
                return error.TransportReplayDimensionMismatch;
            const start = transport_grid_carrier_count * self.layer_count;
            return snapshot[start..][0..self.cell_count];
        }

        fn acceptedSnapshot(self: *const Self, substep: usize) ![]const f64 {
            if (substep >= self.count) return error.TransportReplaySubstepOutOfBounds;
            const start = substep * self.values_per_step;
            return self.accepted_values[start..][0..self.values_per_step];
        }

        /// The reserved WATSUB entry is not replayable until acceptance, but
        /// its carrier is authoritative for the atomic physical/chemistry
        /// commit performed by the acceptance hook.
        fn pendingSnapshot(self: *const Self) ![]const f64 {
            if (self.count >= self.substep_capacity)
                return error.TransportReplayScheduleOverflow;
            const start = self.count * self.values_per_step;
            return self.accepted_values[start..][0..self.values_per_step];
        }

        fn exitSnapshot(self: *const Self, substep: usize) ![]const f64 {
            if (substep >= self.count) return error.TransportReplaySubstepOutOfBounds;
            if (substep + 1 < self.count) return self.acceptedSnapshot(substep + 1);
            if (!self.final_captured) return error.MissingTransportReplayFinalState;
            return self.final_values;
        }

        fn captureCarriersInto(self: *const Self, destination: []f64) !usize {
            if (destination.len != self.values_per_step)
                return error.TransportReplayDimensionMismatch;
            var cursor: usize = 0;
            for (0..transport_grid_carrier_count) |carrier| {
                const source = self.gridCarrier(carrier);
                @memcpy(destination[cursor..][0..self.layer_count], source);
                cursor += self.layer_count;
            }
            @memcpy(
                destination[cursor..][0..self.cell_count],
                self.context.surface_precipitation.litter_water_m3,
            );
            cursor += self.cell_count;
            // TRNSFR's litter aqueous diffusivity is evaluated with TSL(M),
            // the WATSUB step-entry surface temperature, not the final-hour
            // surface temperature. Carry it beside VOLWS(M).
            @memcpy(
                destination[cursor..][0..self.cell_count],
                self.context.grid.surface_temperature_k,
            );
            cursor += self.cell_count;
            @memcpy(
                destination[cursor..][0..self.cell_count],
                self.context.surface_litter_ice_m3,
            );
            cursor += self.cell_count;
            return cursor;
        }

        fn captureFluxesInto(self: *const Self, destination: []f64, start: usize) !void {
            if (destination.len != self.values_per_step)
                return error.TransportReplayDimensionMismatch;
            var cursor = start;
            for (self.context.soil_transport_faces.micropore_faces) |face| {
                destination[cursor] = face.water_flux_m3_per_step;
                cursor += 1;
            }
            for (self.context.soil_transport_faces.macropore_faces) |face| {
                destination[cursor] = face.water_flux_m3_per_step;
                cursor += 1;
            }
            @memcpy(
                destination[cursor..][0..self.layer_count],
                self.context.transport_hydrology.micropore_external_water_flux_m3_per_step,
            );
            cursor += self.layer_count;
            @memcpy(
                destination[cursor..][0..self.layer_count],
                self.context.transport_hydrology.macropore_external_water_flux_m3_per_step,
            );
            cursor += self.layer_count;
            if (cursor != destination.len) return error.TransportReplayDimensionMismatch;
            for (destination) |value| if (!std.math.isFinite(value))
                return error.NonFiniteTransportReplaySnapshot;
        }

        fn captureInto(self: *const Self, destination: []f64) !void {
            const cursor = try self.captureCarriersInto(destination);
            try self.captureFluxesInto(destination, cursor);
        }

        fn bindFrom(self: *Self, source: []const f64) !void {
            if (source.len != self.values_per_step)
                return error.TransportReplayDimensionMismatch;
            var cursor: usize = 0;
            for (0..transport_grid_carrier_count) |carrier| {
                @memcpy(self.gridCarrier(carrier), source[cursor..][0..self.layer_count]);
                cursor += self.layer_count;
            }
            @memcpy(
                self.context.surface_precipitation.litter_water_m3,
                source[cursor..][0..self.cell_count],
            );
            cursor += self.cell_count;
            @memcpy(
                self.context.grid.surface_temperature_k,
                source[cursor..][0..self.cell_count],
            );
            cursor += self.cell_count;
            @memcpy(
                self.context.surface_litter_ice_m3,
                source[cursor..][0..self.cell_count],
            );
            cursor += self.cell_count;
            for (self.context.soil_transport_faces.micropore_faces) |*face| {
                face.water_flux_m3_per_step = source[cursor];
                cursor += 1;
            }
            for (self.context.soil_transport_faces.macropore_faces) |*face| {
                face.water_flux_m3_per_step = source[cursor];
                cursor += 1;
            }
            @memcpy(
                self.context.transport_hydrology.micropore_external_water_flux_m3_per_step,
                source[cursor..][0..self.layer_count],
            );
            cursor += self.layer_count;
            @memcpy(
                self.context.transport_hydrology.macropore_external_water_flux_m3_per_step,
                source[cursor..][0..self.layer_count],
            );
            cursor += self.layer_count;
            if (cursor != source.len) return error.TransportReplayDimensionMismatch;
            // Extensive amounts remain cumulative across replay entries; only
            // their WATSUB water carriers are rebound.
            try self.context.transport_hydrology.syncStorage(self.context.grid, self.context.snow_transport);
            @memcpy(self.context.micropore_solute_state.water_volume_m3, self.context.grid.matrix_liquid_water_m3);
            @memcpy(self.context.macropore_solute_state.water_volume_m3, self.context.grid.macropore_liquid_water_m3);
            @memcpy(self.context.mineral_nitrogen_transport.matrix.water_volume_m3, self.context.grid.matrix_liquid_water_m3);
            @memcpy(self.context.mineral_nitrogen_transport.macropore.water_volume_m3, self.context.grid.macropore_liquid_water_m3);
            @memcpy(self.context.surface_solute_transport.carrier_volume_m3, self.context.surface_precipitation.litter_water_m3);
            @memcpy(self.context.gas_transport.temperature_k, self.context.grid.soil_temperature_k);
            @memcpy(self.context.gas_transport.air_volume_m3, self.context.grid.air_volume_m3);
        }

        /// Reserves the next accepted slot and captures WATSUB's M-entry
        /// carrier volumes before any forcing or nonlinear state update.
        fn beginSubstep(self: *Self, time_step_hours: f64) !void {
            if (!std.math.isFinite(time_step_hours) or time_step_hours <= 0 or time_step_hours > 1)
                return error.InvalidTransportReplayTimeStep;
            if (self.count >= self.substep_capacity)
                return error.TransportReplayScheduleOverflow;
            const start = self.count * self.values_per_step;
            const flux_start = try self.captureCarriersInto(self.accepted_values[start..][0..self.values_per_step]);
            @memset(self.accepted_values[start + flux_start .. start + self.values_per_step], 0);
            const geometry_width = transport_surface_geometry_carrier_count * self.cell_count;
            const geometry_start = self.count * geometry_width;
            try self.captureSurfaceGeometryInto(
                self.accepted_surface_geometry_values[geometry_start..][0..geometry_width],
            );
            self.time_step_hours[self.count] = time_step_hours;
        }

        /// Preflights the accepted WATSUB face and boundary fluxes before the
        /// physical FLWR commit. This does not make the pending slot replayable.
        fn stageAcceptedFluxes(self: *Self) !void {
            if (self.count >= self.substep_capacity)
                return error.TransportReplayScheduleOverflow;
            const start = self.count * self.values_per_step;
            const flux_start = transport_grid_carrier_count * self.layer_count +
                transport_surface_carrier_count * self.cell_count;
            try self.captureFluxesInto(
                self.accepted_values[start..][0..self.values_per_step],
                flux_start,
            );
        }

        /// Completes the pending slot only after WATSUB has accepted both its
        /// face fluxes and the physical litter-soil FLWR transaction.
        fn acceptSubstep(self: *Self, litter_soil_water_flux_m3: []const f64) void {
            std.debug.assert(self.count < self.substep_capacity);
            std.debug.assert(litter_soil_water_flux_m3.len == self.cell_count);
            const litter_start = self.count * self.cell_count;
            @memcpy(
                self.litter_soil_water_flux_m3[litter_start..][0..self.cell_count],
                litter_soil_water_flux_m3,
            );
            self.count += 1;
        }

        fn reset(self: *Self) void {
            self.count = 0;
            self.final_captured = false;
            self.restore_captured = false;
            self.final_surface_geometry_captured = false;
        }

        fn captureFinal(self: *Self) !void {
            try self.captureInto(self.final_values);
            self.final_captured = true;
        }

        /// Captures the post-NITRO/UPTAKE/SOLUTE physical state which must be
        /// restored after temporary M-entry binding. Root TUPWTR is still a
        /// deferred EXTRACT flux here and is not applied until REDIST.
        /// `final_values` remains the immutable accepted-WATSUB certificate.
        fn captureRestoreState(self: *Self) !void {
            try self.captureInto(self.restore_values);
            self.restore_captured = true;
        }

        fn captureFinalSurfaceGeometry(self: *Self) !void {
            try self.captureSurfaceGeometryInto(self.final_surface_geometry_values);
            self.final_surface_geometry_captured = true;
        }

        fn bindAccepted(self: *Self, substep: usize) !void {
            const snapshot = try self.acceptedSnapshot(substep);
            try self.bindFrom(snapshot);
            const geometry_width = transport_surface_geometry_carrier_count * self.cell_count;
            const geometry_start = substep * geometry_width;
            try self.bindSurfaceGeometryFrom(
                self.accepted_surface_geometry_values[geometry_start..][0..geometry_width],
            );
        }

        fn litterSoilWaterFlux(self: *const Self, substep: usize) ![]const f64 {
            if (substep >= self.count) return error.TransportReplaySubstepOutOfBounds;
            const start = substep * self.cell_count;
            return self.litter_soil_water_flux_m3[start..][0..self.cell_count];
        }

        /// Transport changes extensive inventories only. Restore the exact
        /// accepted-WATSUB physical state after each temporary M-entry replay;
        /// `final_values` separately retains its immutable provenance copy.
        fn restoreFinal(self: *Self) !void {
            if (!self.final_captured or !self.restore_captured or
                !self.final_surface_geometry_captured)
                return error.MissingTransportReplayFinalState;
            try self.bindFrom(self.restore_values);
            try self.bindSurfaceGeometryFrom(self.final_surface_geometry_values);
            // The final replayed gas solve bound vapor at the last M-entry.
            // `bindFrom` has now restored the accepted M-exit water carrier, so
            // refresh its pressure-only molar mirror before REDIST can validate
            // or transfer that destination layer.
            try ecosys.soil_gas_transport_step.synchronizeWaterVaporMolarMirror(
                self.context.gas_transport.water_vapor_mol,
                self.context.grid.water_vapor_volume_m3,
                self.context.runscript.soil_gas_transport_parameters.water_density_g_per_m3,
                self.context.runscript.soil_gas_transport_parameters.water_molar_mass_g_per_mol,
            );
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.final_surface_geometry_values);
            self.allocator.free(self.restore_values);
            self.allocator.free(self.final_values);
            self.allocator.free(self.litter_soil_water_flux_m3);
            self.allocator.free(self.accepted_surface_geometry_values);
            self.allocator.free(self.accepted_values);
            self.* = undefined;
        }
    };
}

const AcceptedGroundAirPublication = struct {
    cell_count: usize,
    ground_air: *ecosys.ground_air_exchange.State,
    geometry_balance: []const ecosys.ground_air_exchange.GeometryBalance,
    vapor_balance_total: []const ecosys.ground_air_exchange.VaporBalance,
    sensible_heat_closure_absolute_total_megajoules: []const f64,
    sensible_heat_storage_activity_total_megajoules: []const f64,
    sensible_heat_transfer_activity_total_megajoules: []const f64,
    sensible_heat_arithmetic_activity_total_megajoules: []const f64,
    iteration_total: []const u32,
    canopy_cell_area_m2: []const f64,
    water_absolute_tolerance_m: f64,
    heat_absolute_tolerance_megajoules_per_m2: f64,
    relative_tolerance: f64,
    accepted_substep_count: u8,
    accepted_duration_hours: f64,
    expected_substep_count: u8,
};

fn isSupportedRecoverySubstepCount(substep_count: u8) bool {
    for (ecosys.soil_water_heat_step.recovery_substep_counts) |supported|
        if (substep_count == supported) return true;
    return false;
}

fn isOneHourAcceptedScheduleDuration(substep_count: u8, duration_hours: f64) bool {
    if (!isSupportedRecoverySubstepCount(substep_count) or
        !std.math.isFinite(duration_hours))
        return false;
    const scaled_epsilon =
        (@as(f64, @floatFromInt(substep_count)) + 1) * std.math.floatEps(f64);
    if (scaled_epsilon >= 1) return false;
    const accumulation_roundoff = scaled_epsilon / (1 - scaled_epsilon);
    return @abs(duration_hours - 1) <= accumulation_roundoff;
}

/// Validate and publish the accepted ground-air schedule through a concrete
/// phase boundary. Keeping this arithmetic outside the generic coupled
/// transaction prevents each transaction context from owning another copy of
/// the conservation-validation body.
noinline fn publishAcceptedGroundAirPhase(publication: AcceptedGroundAirPublication) !void {
    if (publication.sensible_heat_closure_absolute_total_megajoules.len != publication.cell_count or
        publication.sensible_heat_storage_activity_total_megajoules.len != publication.cell_count or
        publication.sensible_heat_transfer_activity_total_megajoules.len != publication.cell_count or
        publication.sensible_heat_arithmetic_activity_total_megajoules.len != publication.cell_count or
        publication.accepted_substep_count != publication.expected_substep_count or
        !isOneHourAcceptedScheduleDuration(
            publication.expected_substep_count,
            publication.accepted_duration_hours,
        ))
        return error.InvalidAcceptedGroundAirSchedule;
    // Local formation error scales with the sum of the endpoint/transfer
    // magnitudes; the final reductions scale only with their accepted totals.
    // Keeping the two gamma terms separate avoids an artificial O(N^2 eps)
    // allowance while certifying the same floating-point operations.
    const local_scaled_epsilon = 16.0 * std.math.floatEps(f64);
    const reduction_operation_count = 4.0 *
        @as(f64, @floatFromInt(publication.accepted_substep_count)) + 32.0;
    const reduction_scaled_epsilon = reduction_operation_count * std.math.floatEps(f64);
    if (!std.math.isFinite(local_scaled_epsilon) or local_scaled_epsilon >= 1 or
        !std.math.isFinite(reduction_scaled_epsilon) or reduction_scaled_epsilon >= 1)
        return error.InvalidAcceptedGroundAirSchedule;
    const local_gamma = local_scaled_epsilon / (1 - local_scaled_epsilon);
    const reduction_gamma = reduction_scaled_epsilon / (1 - reduction_scaled_epsilon);
    for (0..publication.cell_count) |cell| {
        const total = publication.vapor_balance_total[cell];
        const geometry = publication.geometry_balance[cell];
        const final_vapor_storage_m3 = publication.ground_air.vapor_volume_fraction[cell] *
            publication.ground_air.air_volume_m3[cell];
        const storage_change_m3 = final_vapor_storage_m3 - geometry.initial_vapor_storage_m3;
        // GROUND-AIR-VAPOR-CONDENSATION-001: `condensate_deposition_m3` is a
        // real sink out of this control volume (see
        // `src/surface/ground_air_exchange.zig`'s `solve`), not merely a
        // diagnostic; it must be netted out here exactly as it already is
        // in that function's own per-substep closure check.
        const transfer_sum_m3 = total.atmospheric_transfer_m3 +
            total.prescribed_non_atmospheric_transfer_m3 +
            total.implicit_surface_transfer_m3 -
            total.condensate_deposition_m3;
        const closure_residual_m3 = storage_change_m3 - transfer_sum_m3;
        const activity_scale_m3 = @max(
            @max(
                @abs(geometry.initial_vapor_storage_m3),
                @abs(final_vapor_storage_m3),
            ),
            @abs(total.atmospheric_transfer_m3) +
                @abs(total.prescribed_non_atmospheric_transfer_m3) +
                @abs(total.implicit_surface_transfer_m3) +
                @abs(total.condensate_deposition_m3),
        );
        const tolerance_m3 = publication.water_absolute_tolerance_m * publication.canopy_cell_area_m2[cell] +
            publication.relative_tolerance * activity_scale_m3 +
            64 * std.math.floatEps(f64) * activity_scale_m3;
        inline for (.{ storage_change_m3, transfer_sum_m3, closure_residual_m3, tolerance_m3 }) |value|
            if (!std.math.isFinite(value)) return error.NonFiniteAcceptedGroundAirBalance;
        if (@abs(total.storage_change_m3 - storage_change_m3) > tolerance_m3 or
            @abs(total.closure_residual_m3) > tolerance_m3 or
            @abs(closure_residual_m3) > tolerance_m3)
            return error.AcceptedGroundAirVaporConservationFailure;

        const final_sensible_heat_megajoules =
            publication.ground_air.temperature_k[cell] *
            publication.ground_air.heat_capacity_megajoules_per_k[cell];
        const sensible_heat_storage_change_megajoules =
            final_sensible_heat_megajoules - geometry.initial_sensible_heat_megajoules;
        const sensible_heat_transfer_sum_megajoules =
            total.atmospheric_sensible_heat_transfer_megajoules +
            total.prescribed_non_atmospheric_sensible_heat_transfer_megajoules +
            total.implicit_non_atmospheric_sensible_heat_transfer_megajoules;
        const sensible_heat_closure_residual_megajoules =
            sensible_heat_storage_change_megajoules - sensible_heat_transfer_sum_megajoules;
        const sensible_heat_activity_scale_megajoules = @max(
            publication.sensible_heat_storage_activity_total_megajoules[cell],
            publication.sensible_heat_transfer_activity_total_megajoules[cell],
        );
        const sensible_heat_physical_limit_megajoules =
            publication.heat_absolute_tolerance_megajoules_per_m2 *
            publication.canopy_cell_area_m2[cell] +
            publication.relative_tolerance * sensible_heat_activity_scale_megajoules;
        const sensible_heat_roundoff_allowance_megajoules =
            local_gamma * publication.sensible_heat_arithmetic_activity_total_megajoules[cell] +
            reduction_gamma * (publication.sensible_heat_closure_absolute_total_megajoules[cell] +
                publication.sensible_heat_transfer_activity_total_megajoules[cell] +
                @abs(total.sensible_heat_storage_change_megajoules) +
                @abs(sensible_heat_storage_change_megajoules) +
                @abs(total.sensible_heat_closure_residual_megajoules) +
                @abs(sensible_heat_closure_residual_megajoules) +
                sensible_heat_physical_limit_megajoules);
        const sensible_heat_tolerance_megajoules =
            sensible_heat_physical_limit_megajoules +
            sensible_heat_roundoff_allowance_megajoules;
        inline for (.{
            final_sensible_heat_megajoules,
            sensible_heat_storage_change_megajoules,
            sensible_heat_transfer_sum_megajoules,
            sensible_heat_closure_residual_megajoules,
            sensible_heat_physical_limit_megajoules,
            sensible_heat_roundoff_allowance_megajoules,
            sensible_heat_tolerance_megajoules,
        }) |value| if (!std.math.isFinite(value))
            return error.NonFiniteAcceptedGroundAirEnergyBalance;
        if (@abs(total.sensible_heat_storage_change_megajoules -
            sensible_heat_storage_change_megajoules) > sensible_heat_roundoff_allowance_megajoules or
            @abs(total.sensible_heat_closure_residual_megajoules) >
                publication.sensible_heat_closure_absolute_total_megajoules[cell] +
                    sensible_heat_roundoff_allowance_megajoules or
            publication.sensible_heat_closure_absolute_total_megajoules[cell] >
                sensible_heat_tolerance_megajoules or
            @abs(total.sensible_heat_closure_residual_megajoules) > sensible_heat_tolerance_megajoules or
            @abs(sensible_heat_closure_residual_megajoules) > sensible_heat_tolerance_megajoules)
        {
            if (!builtin.is_test) std.log.err(
                "accepted ground-air sensible-energy closure failed: cell={d} accumulated_storage_mj={e} reconstructed_storage_mj={e} storage_delta_mj={e} accumulated_closure_mj={e} absolute_closure_mj={e} reconstructed_closure_mj={e} transfer_sum_mj={e} physical_limit_mj={e} arithmetic_allowance_mj={e} tolerance_mj={e} initial_mj={e} final_mj={e}",
                .{
                    cell,
                    total.sensible_heat_storage_change_megajoules,
                    sensible_heat_storage_change_megajoules,
                    total.sensible_heat_storage_change_megajoules - sensible_heat_storage_change_megajoules,
                    total.sensible_heat_closure_residual_megajoules,
                    publication.sensible_heat_closure_absolute_total_megajoules[cell],
                    sensible_heat_closure_residual_megajoules,
                    sensible_heat_transfer_sum_megajoules,
                    sensible_heat_physical_limit_megajoules,
                    sensible_heat_roundoff_allowance_megajoules,
                    sensible_heat_tolerance_megajoules,
                    geometry.initial_sensible_heat_megajoules,
                    final_sensible_heat_megajoules,
                },
            );
            return error.AcceptedGroundAirEnergyConservationFailure;
        }
        if (publication.iteration_total[cell] > std.math.maxInt(u16))
            return error.GroundAirIterationCountOverflow;
    }
    @memcpy(publication.ground_air.vapor_balance, publication.vapor_balance_total);
    for (publication.ground_air.iteration_count, publication.iteration_total) |*published, total|
        published.* = @intCast(total);
}

test "accepted ground air energy budget rejects accumulated cancellation and storage defects" {
    var temperature_k = [_]f64{100};
    var vapor_volume_fraction = [_]f64{0};
    var heat_capacity_megajoules_per_k = [_]f64{0.1};
    var air_volume_m3 = [_]f64{1};
    var iteration_count = [_]u16{0};
    var published_balance = [_]ecosys.ground_air_exchange.VaporBalance{.{}};
    var condensate_frost_pool_m3 = [_]f64{0};
    var condensate_frost_pool_heat_megajoules = [_]f64{0};
    var ground_air: ecosys.ground_air_exchange.State = .{
        .allocator = std.testing.allocator,
        .cell_count = 1,
        .temperature_k = &temperature_k,
        .vapor_volume_fraction = &vapor_volume_fraction,
        .heat_capacity_megajoules_per_k = &heat_capacity_megajoules_per_k,
        .air_volume_m3 = &air_volume_m3,
        .iteration_count = &iteration_count,
        .vapor_balance = &published_balance,
        .condensate_frost_pool_m3 = &condensate_frost_pool_m3,
        .condensate_frost_pool_heat_megajoules = &condensate_frost_pool_heat_megajoules,
    };
    const geometry = [_]ecosys.ground_air_exchange.GeometryBalance{.{
        .initial_sensible_heat_megajoules = 10,
    }};
    var total = [_]ecosys.ground_air_exchange.VaporBalance{.{}};
    const iterations = [_]u32{1};
    var absolute_closure = [_]f64{0};
    const storage_activity = [_]f64{10};
    const transfer_activity = [_]f64{1.1e-8};
    const arithmetic_activity = [_]f64{320};
    const area = [_]f64{1};
    const base: AcceptedGroundAirPublication = .{
        .cell_count = 1,
        .ground_air = &ground_air,
        .geometry_balance = &geometry,
        .vapor_balance_total = &total,
        .sensible_heat_closure_absolute_total_megajoules = &absolute_closure,
        .sensible_heat_storage_activity_total_megajoules = &storage_activity,
        .sensible_heat_transfer_activity_total_megajoules = &transfer_activity,
        .sensible_heat_arithmetic_activity_total_megajoules = &arithmetic_activity,
        .iteration_total = &iterations,
        .canopy_cell_area_m2 = &area,
        .water_absolute_tolerance_m = 0,
        .heat_absolute_tolerance_megajoules_per_m2 = 0,
        .relative_tolerance = 1e-9,
        .accepted_substep_count = 16,
        .accepted_duration_hours = 1,
        .expected_substep_count = 16,
    };

    // Same-signed local residuals cannot each consume the full hourly band.
    total[0].atmospheric_sensible_heat_transfer_megajoules = -1.1e-8;
    total[0].sensible_heat_closure_residual_megajoules = 1.1e-8;
    absolute_closure[0] = 1.1e-8;
    try std.testing.expectError(
        error.AcceptedGroundAirEnergyConservationFailure,
        publishAcceptedGroundAirPhase(base),
    );

    // Opposite-signed residuals may hide in the signed sum, but not its
    // attempt-private absolute lane.
    total[0] = .{};
    absolute_closure[0] = 1.1e-8;
    try std.testing.expectError(
        error.AcceptedGroundAirEnergyConservationFailure,
        publishAcceptedGroundAirPhase(base),
    );

    // A storage-accounting discrepancy is arithmetic-only; a physical
    // relative tolerance must never excuse it.
    total[0] = .{
        .sensible_heat_storage_change_megajoules = 1e-8,
        .atmospheric_sensible_heat_transfer_megajoules = 1e-8,
    };
    absolute_closure[0] = 0;
    try std.testing.expectError(
        error.AcceptedGroundAirEnergyConservationFailure,
        publishAcceptedGroundAirPhase(base),
    );

    total[0] = .{};
    absolute_closure[0] = 0.9e-8;
    try publishAcceptedGroundAirPhase(base);
}

fn CoupledSubstepTransaction(
    comptime Context: type,
    comptime SoilChemistry: type,
    comptime LitterChemistry: type,
) type {
    return struct {
        const Self = @This();
        const Forcing = SoilForcingSubstepHooks(Context, SoilChemistry, LitterChemistry);
        const LitterSoilPhysicalCandidate = struct {
            cell: usize,
            top: usize,
            water_flux: ecosys.surface_water_flow.LitterSoilFlux,
            new_litter_water_m3: f64,
            new_soil_water_m3: f64,
            new_litter_air_m3: f64,
            new_soil_air_m3: f64,
            new_surface_capacity_megajoules_per_k: f64,
            new_soil_capacity_megajoules_per_k: f64,
            new_surface_temperature_k: f64,
            new_soil_temperature_k: f64,
            chemistry_rebase_roundoff: ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
            surface_chemistry_rebase_roundoff: ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
        };

        context: Context,
        scratch: TransactionScratchArena,
        /// Backing allocator retained for short-lived solver reports and
        /// publication candidates which preserve their prior eager lifetime.
        allocator: std.mem.Allocator,
        forcing: Forcing,
        schedule_snapshot: StageMemorySnapshot,
        transport_replay: AcceptedTransportReplay(Context),
        entry_topsoil_chemistry: TopsoilChemistryCarrierSnapshot,
        litter_soil_physical_candidates: []LitterSoilPhysicalCandidate,
        litter_soil_water_flux_m3: []f64,
        initial_gas_state: ecosys.gas_transport.State,
        surface_temperature_work: ecosys.surface_temperature_solver.State,
        surface_temperature_total: ecosys.surface_temperature_solver.State,
        surface_energy_work: ecosys.surface_energy.State,
        surface_energy_total: ecosys.surface_energy.State,
        surface_air_vapor_pressure_kpa: []f64,
        surface_snow_cover_fraction: []f64,
        surface_dry_litter_albedo: []f64,
        surface_live_litter_cover_fraction: []f64,
        surface_liquid_water_before_temperature_m3: []f64,
        litter_vapor_water_equivalent_m3: []f64,
        litter_vapor_conductance_m3_per_h: []f64,
        litter_sensible_conductance_megajoules_per_h_k: []f64,
        topsoil_vapor_conductance_m3_per_h: []f64,
        topsoil_sensible_conductance_megajoules_per_h_k: []f64,
        topsoil_sensible_heat_step_megajoules: []f64,
        deferred_sensible_conductance: []f64,
        sensible_pair_capacity_megajoules_per_k: [][3]f64,
        sensible_pair_temperature_k: [][3]f64,
        sensible_pair_conductance_megajoules_per_h_k: [][3]f64,
        topsoil_sensible_heat_total_megajoules: []f64,
        surface_iteration_total: []u32,
        surface_newton_total: []u32,
        surface_picard_total: []u32,
        base_cell_heat_source_megajoules: []f64,
        surface_conduction_total_megajoules: []f64,
        surface_phase_sensible_adjustment_total_megajoules_by_cell: []f64,
        surface_internal_vapor_latent_heat_total_megajoules_by_cell: []f64,
        surface_atmospheric_water_thermalization_total_megajoules_by_cell: []f64,
        /// Attempt-private integral of the accepted surface scalar-equation
        /// residual.  The absolute lane prevents opposite-signed substeps
        /// from hiding a local process closure defect.
        surface_energy_residual_signed_total_megajoules_by_cell: []f64,
        surface_energy_residual_absolute_total_megajoules_by_cell: []f64,
        irrigation_parameters: ecosys.subsurface_irrigation_chemistry.Parameters,
        max_iterations: u16,
        exact_substep_count: u8,
        temporary_profile_prepare_ns: i96 = 0,
        temporary_profile_prepare_snow_ns: i96 = 0,
        temporary_profile_prepare_forcing_ns: i96 = 0,
        temporary_profile_post_phase_ns: i96 = 0,
        temporary_profile_accept_ns: i96 = 0,
        temporary_profile_accept_carrier_ns: i96 = 0,
        temporary_profile_accept_snow_ns: i96 = 0,
        temporary_profile_accept_transport_ns: i96 = 0,
        temporary_profile_accept_litter_soil_ns: i96 = 0,
        temporary_profile_accept_compaction_ns: i96 = 0,
        temporary_profile_replay_setup_ns: i96 = 0,
        temporary_profile_replay_bind_ns: i96 = 0,
        temporary_profile_replay_rebase_ns: i96 = 0,
        temporary_profile_replay_interface_ns: i96 = 0,
        temporary_profile_replay_aqueous_ns: i96 = 0,
        temporary_profile_replay_organic_ns: i96 = 0,
        temporary_profile_replay_mineral_ns: i96 = 0,
        temporary_profile_replay_dissolved_gas_ns: i96 = 0,
        temporary_profile_replay_soil_gas_ns: i96 = 0,
        temporary_profile_replay_restore_ns: i96 = 0,
        temporary_profile_soil_gas_step: ecosys.soil_gas_transport_step.TemporaryProfileCounters = .{},
        temporary_profile_soil_gas_stage_post_ns: i96 = 0,
        temporary_profile_aqueous_micropore_iterations: u64 = 0,
        temporary_profile_aqueous_macropore_iterations: u64 = 0,
        temporary_profile_aqueous_micropore_newton_steps: u64 = 0,
        temporary_profile_aqueous_macropore_newton_steps: u64 = 0,
        temporary_profile_soil_gas_iterations: u64 = 0,
        temporary_profile_soil_gas_newton_steps: u64 = 0,
        temporary_profile_soil_gas_anderson_steps: u64 = 0,
        temporary_profile_soil_gas_dense_jacobian_assemblies: u64 = 0,
        temporary_profile_soil_gas_dense_jacobian_reuses: u64 = 0,
        temporary_profile_soil_gas_krylov_direction_calls: u64 = 0,
        temporary_profile_soil_gas_krylov_iterations: u64 = 0,
        gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
        pore_diffusivity_m2_per_h: []f64,
        micropore_face_step_mol: []f64,
        macropore_face_step_mol: []f64,
        boundary_step_mol: []f64,
        micropore_face_total_mol: []f64,
        macropore_face_total_mol: []f64,
        boundary_total_mol: []f64,
        organic_boundary_total_g: []f64,
        mineral_boundary_total_g_n: []f64,
        dissolved_gas_boundary_total_g: []f64,
        litter_soil_organic_heat_rebase_total_megajoules_by_cell: []f64,
        /// HEAT-001: the per-substep CARBON steps, summed. The heat total above
        /// is priced at each substep's own surface temperature, which the census
        /// never sees, so `publishLitterSoilOrganicHeatRebase` reprices this sum
        /// once at the census temperature before publishing.
        litter_soil_organic_carbon_step_total_g_c_by_cell: []f64,
        litter_soil_surface_to_topsoil_total: []ecosys.hourly_cell_conservation.IntercellTransfer,
        litter_soil_topsoil_to_surface_total: []ecosys.hourly_cell_conservation.IntercellTransfer,
        organic_micropore_face_step_g: []f64,
        organic_macropore_face_step_g: []f64,
        organic_micropore_face_total_g: []f64,
        organic_macropore_face_total_g: []f64,
        mineral_micropore_face_step_mol: []f64,
        mineral_macropore_face_step_mol: []f64,
        mineral_micropore_face_total_mol: []f64,
        mineral_macropore_face_total_mol: []f64,
        dissolved_gas_micropore_face_step_g: []f64,
        dissolved_gas_macropore_face_step_g: []f64,
        dissolved_gas_micropore_face_total_g: []f64,
        dissolved_gas_macropore_face_total_g: []f64,
        gas_atmospheric_total_g: []f64,
        gas_subsurface_total_g: []f64,
        gas_face_total_g: []f64,
        gas_bubble_input_total: []ecosys.hourly_cell_conservation.IntercellTransfer,
        gas_bubble_output_total: []ecosys.hourly_cell_conservation.IntercellTransfer,
        ground_air_snow_surface_vapor_fraction: []f64,
        ground_air_snow_surface_temperature_k: []f64,
        ground_air_combined_surface_sensible_conductance: []f64,
        ground_air_combined_surface_vapor_conductance: []f64,
        ground_air_combined_surface_vapor_fraction: []f64,
        ground_air_combined_surface_temperature_k: []f64,
        ground_air_step_entry_sensible_heat_megajoules: []f64,
        ground_air_step_vapor_balance: []ecosys.ground_air_exchange.VaporBalance,
        ground_air_vapor_balance_total: []ecosys.ground_air_exchange.VaporBalance,
        ground_air_sensible_heat_closure_absolute_total_megajoules: []f64,
        ground_air_sensible_heat_storage_activity_total_megajoules: []f64,
        ground_air_sensible_heat_transfer_activity_total_megajoules: []f64,
        ground_air_sensible_heat_arithmetic_activity_total_megajoules: []f64,
        ground_air_iteration_total: []u32,
        ground_air_accepted_substep_count: u8,
        ground_air_accepted_duration_hours: f64,
        ground_air_geometry_balance: []const ecosys.ground_air_exchange.GeometryBalance,
        ground_air_published_vapor_balance: []ecosys.ground_air_exchange.VaporBalance,
        ground_air_published_iterations: []u16,
        snow_vapor_conductance_m3_per_h: []f64,
        snow_sensible_conductance_megajoules_per_h_k: []f64,
        snow_radiative_heat_megajoules_per_h: []f64,
        snow_evaporation_m3: []f64,
        snow_condensation_m3: []f64,
        snow_boundary_heat_megajoules: []f64,
        snow_evaporation_total_m3: []f64,
        snow_condensation_total_m3: []f64,
        snow_boundary_heat_total_megajoules: []f64,
        snow_latent_heat_megajoules: []f64,
        snow_carrier_sensible_heat_megajoules: []f64,
        snow_air_sensible_heat_megajoules: []f64,
        snow_radiative_heat_megajoules: []f64,
        snow_reference_state_heat_megajoules: f64,
        snow_reference_state_heat_megajoules_by_cell: []f64,
        snow_drift_source_carrier_m3: []f64,
        snow_drift_total_m3: []f64,
        snow_drift_east_m3: []f64,
        snow_drift_west_m3: []f64,
        snow_drift_south_m3: []f64,
        snow_drift_north_m3: []f64,
        snow_compaction_snowfall_m3: []f64,
        snow_relayering_step: ecosys.snow_relayering.AcceptedTransfers,
        snow_relayering_total: ecosys.snow_relayering.AcceptedTransfers,
        snow_solid_input_step_m3: []f64,
        snow_liquid_input_step_m3: []f64,
        snow_heat_input_step_megajoules: []f64,
        snow_solid_input_total_m3: []f64,
        snow_liquid_input_total_m3: []f64,
        snow_heat_input_total_megajoules: []f64,
        snow_entry_top_heat_capacity_megajoules_per_k: []f64,
        snow_face_entry_temperature_k: []f64,
        snow_atmospheric_input_step_g: []f64,
        snow_atmospheric_input_step_salt_mol: []f64,
        snow_atmospheric_input_total_g: []f64,
        snow_atmospheric_input_total_salt_mol: []f64,
        base_water_to_litter_m3_per_h: []f64,
        base_water_to_matrix_m3_per_h: []f64,
        base_water_to_macropore_m3_per_h: []f64,
        snow_downward_water_total_m3: []f64,
        snow_to_litter_water_total_m3: []f64,
        snow_to_matrix_water_total_m3: []f64,
        snow_to_macropore_water_total_m3: []f64,
        snow_accepted_downward_total_g: []f64,
        snow_accepted_downward_total_salt_mol: []f64,
        snow_activity_active_by_layer: []bool,
        snow_conduction_heat_step_megajoules_by_layer: []f64,
        snow_conduction_heat_total_megajoules_by_layer: []f64,
        snow_vapor_diffusion_water_step_m3_by_layer: []f64,
        snow_vapor_diffusion_water_total_m3_by_layer: []f64,
        snow_vapor_diffusion_water_downward_total_m3_by_layer: []f64,
        snow_vapor_diffusion_water_upward_total_m3_by_layer: []f64,
        snow_vapor_diffusion_heat_step_megajoules_by_layer: []f64,
        snow_vapor_diffusion_heat_total_megajoules_by_layer: []f64,
        snow_vapor_diffusion_heat_downward_total_megajoules_by_layer: []f64,
        snow_vapor_diffusion_heat_upward_total_megajoules_by_layer: []f64,
        snow_vapor_equilibrium_heat_total_megajoules_by_layer: []f64,
        snow_inactive_reference_heat_step_megajoules_by_layer: []f64,
        snow_inactive_reference_heat_total_megajoules_by_layer: []f64,
        snow_melt_heat_step_megajoules_by_layer: []f64,
        snow_melt_heat_total_megajoules_by_layer: []f64,
        snow_discharge_heat_step_megajoules_by_cell: []f64,
        snow_discharge_heat_total_megajoules_by_cell: []f64,
        snow_surface_transfer_water_total_m3_by_cell: []f64,
        snow_topsoil_transfer_water_total_m3_by_cell: []f64,
        snow_surface_transfer_heat_step_megajoules_by_cell: []f64,
        snow_topsoil_transfer_heat_step_megajoules_by_cell: []f64,
        snow_surface_transfer_heat_total_megajoules_by_cell: []f64,
        snow_topsoil_transfer_heat_total_megajoules_by_cell: []f64,
        /// WATSUB 1793 `HFLWS1` and 2031 `HFLWSRX`: signed continuous
        /// conduction from the lowest active snow layer into the two surface
        /// recipients. Positive leaves the snowpack. No water crosses these
        /// faces, so they are kept apart from the meltwater carrier heat.
        snow_base_litter_conduction_heat_step_megajoules_by_cell: []f64,
        snow_base_topsoil_conduction_heat_step_megajoules_by_cell: []f64,
        snow_base_litter_conduction_heat_total_megajoules_by_source_layer: []f64,
        snow_base_topsoil_conduction_heat_total_megajoules_by_source_layer: []f64,
        snow_discharge_water_total_m3_by_source_layer: []f64,
        snow_discharge_heat_total_megajoules_by_source_layer: []f64,
        snow_discharge_total_g_by_source_layer_species: []f64,
        snow_discharge_total_salt_mol_by_source_layer_species: []f64,
        snow_surface_discharge_total: []ecosys.snow_solute_transport.SurfaceDischarge,
        snow_phase_heat_total_megajoules_by_cell: []f64,
        snow_vapor_heat_total_megajoules_by_cell: []f64,
        snow_inactive_reference_heat_total_megajoules_by_cell: []f64,
        snow_phase_heat_total_megajoules: f64,
        snow_vapor_heat_total_megajoules: f64,
        snow_inactive_reference_heat_total_megajoules: f64,
        snow_drift_cell_ledger: ecosys.hourly_cell_conservation.BoundaryLedger,
        snow_drift_landscape_ledger: ecosys.landscape_boundary_ledger.State,
        snow_water_storage_before_m3: []f64,
        /// Attempt-local producer-commit provenance. It is copied into the
        /// hourly layer ledger only after every coupled stage succeeds.
        water_storage_update_operation_count_by_scope: []u16,
        /// Attempt-private, source-certified arithmetic drift from accepted
        /// soil chemistry water-carrier rebases, indexed by flat soil layer.
        chemistry_rebase_roundoff_by_layer: []ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
        /// Matching source-certified surface litter carrier arithmetic. One
        /// entry belongs to each horizontal grid cell; tile traversal remains
        /// serial and publication occurs only after the full schedule accepts.
        surface_chemistry_rebase_roundoff_by_cell: []ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,

        noinline fn init(
            context: Context,
            max_iterations: u16,
            exact_substep_count: u8,
            ground_air_geometry_balance: []const ecosys.ground_air_exchange.GeometryBalance,
            gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
        ) !Self {
            try validateGroundAirGeometryBalance(
                ground_air_geometry_balance,
                context.grid.cell_count,
            );
            const backing_allocator = context.allocator;
            var scratch = try TransactionScratchArena.init(backing_allocator);
            errdefer scratch.deinit();
            const allocator = scratch.allocator();
            const surface_chemistry_rebase_roundoff_by_cell = try allocator.alloc(
                ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
                context.grid.cell_count,
            );
            @memset(surface_chemistry_rebase_roundoff_by_cell, .{});
            const forcing = try Forcing.init(
                context,
                allocator,
                surface_chemistry_rebase_roundoff_by_cell,
            );
            const schedule_snapshot = try StageMemorySnapshot.capture(allocator, context);
            const transport_replay = try AcceptedTransportReplay(Context).init(
                allocator,
                context,
                exact_substep_count,
            );
            const entry_topsoil_chemistry = try TopsoilChemistryCarrierSnapshot.init(
                allocator,
                context.grid.cell_count,
            );
            const litter_soil_candidates = try allocator.alloc(
                LitterSoilPhysicalCandidate,
                context.grid.cell_count,
            );
            const litter_soil_flux = try allocator.alloc(f64, context.grid.cell_count);
            @memset(litter_soil_flux, 0);
            const initial_gas_state = try context.gas_transport.clone(allocator);
            const surface_temperature_work = try ecosys.surface_temperature_solver.State.init(allocator, context.grid.cell_count);
            const surface_temperature_total = try ecosys.surface_temperature_solver.State.init(allocator, context.grid.cell_count);
            const surface_energy_work = try ecosys.surface_energy.State.init(allocator, context.grid.cell_count);
            const surface_energy_total = try ecosys.surface_energy.State.init(allocator, context.grid.cell_count);
            const surface_air_vapor_pressure = try allocator.alloc(f64, context.grid.cell_count);
            const surface_snow_cover = try allocator.alloc(f64, context.grid.cell_count);
            const surface_dry_litter_albedo = try allocator.alloc(f64, context.grid.cell_count);
            const surface_live_litter_cover_fraction = try allocator.alloc(f64, context.grid.cell_count);
            const surface_liquid_water_before_temperature = try allocator.alloc(f64, context.grid.cell_count);
            const litter_vapor_water_equivalent = try allocator.alloc(f64, context.grid.cell_count);
            const litter_vapor_conductance = try allocator.alloc(f64, context.grid.cell_count);
            const litter_sensible_conductance = try allocator.alloc(f64, context.grid.cell_count);
            const topsoil_vapor_conductance = try allocator.alloc(f64, context.grid.cell_count);
            const topsoil_sensible_conductance = try allocator.alloc(f64, context.grid.cell_count);
            const topsoil_sensible_heat_step = try allocator.alloc(f64, context.grid.cell_count);
            const deferred_sensible_conductance = try allocator.alloc(f64, context.grid.cell_count);
            @memset(deferred_sensible_conductance, 0);
            const sensible_pair_capacity = try allocator.alloc([3]f64, context.grid.cell_count);
            const sensible_pair_temperature = try allocator.alloc([3]f64, context.grid.cell_count);
            const sensible_pair_conductance = try allocator.alloc([3]f64, context.grid.cell_count);
            const topsoil_sensible_heat_total = try allocator.alloc(f64, context.grid.cell_count);
            @memset(litter_vapor_conductance, 0);
            @memset(litter_vapor_water_equivalent, 0);
            @memset(litter_sensible_conductance, 0);
            @memset(topsoil_vapor_conductance, 0);
            @memset(topsoil_sensible_conductance, 0);
            @memset(topsoil_sensible_heat_step, 0);
            @memset(topsoil_sensible_heat_total, 0);
            const surface_iteration_total = try allocator.alloc(u32, context.grid.cell_count);
            const surface_newton_total = try allocator.alloc(u32, context.grid.cell_count);
            const surface_picard_total = try allocator.alloc(u32, context.grid.cell_count);
            const base_cell_heat_source = try allocator.dupe(f64, context.soil_hourly_workspace.cell_heat_source_megajoules);
            const surface_conduction_total = try allocator.alloc(f64, context.grid.layer_count);
            const surface_phase_sensible_adjustment_total = try allocator.alloc(f64, context.grid.cell_count);
            const surface_internal_vapor_latent_heat_total = try allocator.alloc(f64, context.grid.cell_count);
            const surface_atmospheric_water_thermalization_total = try allocator.alloc(f64, context.grid.cell_count);
            const surface_energy_residual_signed_total = try allocator.alloc(f64, context.grid.cell_count);
            const surface_energy_residual_absolute_total = try allocator.alloc(f64, context.grid.cell_count);
            const pore_diffusivity = try allocator.alloc(f64, context.grid.layer_count);
            const micro_step = try allocator.alloc(f64, context.micropore_solute_face_flux_mol.len);
            const macro_step = try allocator.alloc(f64, context.macropore_solute_face_flux_mol.len);
            const boundary_step = try allocator.alloc(f64, context.soil_solute_boundary_net_flux_mol.len);
            const micro_total = try allocator.alloc(f64, micro_step.len);
            const macro_total = try allocator.alloc(f64, macro_step.len);
            const boundary_total = try allocator.alloc(f64, boundary_step.len);
            const organic_total = try allocator.alloc(f64, context.soil_organic_transport.boundary_net_flux_g.len);
            const mineral_total = try allocator.alloc(f64, context.mineral_nitrogen_transport.boundary_export_g_n_per_step.len);
            const dissolved_gas_total = try allocator.alloc(f64, context.soil_dissolved_gas_transport.boundary_net_flux_g.len);
            const litter_soil_organic_heat_rebase_total = try allocator.alloc(f64, context.grid.cell_count);
            const litter_soil_organic_carbon_step_total = try allocator.alloc(f64, context.grid.cell_count);
            const litter_soil_surface_to_topsoil_total = try allocator.alloc(
                ecosys.hourly_cell_conservation.IntercellTransfer,
                context.grid.cell_count,
            );
            const litter_soil_topsoil_to_surface_total = try allocator.alloc(
                ecosys.hourly_cell_conservation.IntercellTransfer,
                context.grid.cell_count,
            );
            const face_count = context.soil_transport_faces.micropore_faces.len;
            const organic_face_count = try std.math.mul(usize, face_count, ecosys.soil_organic_transport.component_count);
            const mineral_face_count = try std.math.mul(usize, face_count, ecosys.mineral_nitrogen_transport.species_count);
            const dissolved_gas_face_count = try std.math.mul(usize, face_count, ecosys.gas_transport.species_count);
            const organic_micro_face_step = try allocator.alloc(f64, organic_face_count);
            const organic_macro_face_step = try allocator.alloc(f64, organic_face_count);
            const organic_micro_face_total = try allocator.alloc(f64, organic_face_count);
            const organic_macro_face_total = try allocator.alloc(f64, organic_face_count);
            const mineral_micro_face_step = try allocator.alloc(f64, mineral_face_count);
            const mineral_macro_face_step = try allocator.alloc(f64, mineral_face_count);
            const mineral_micro_face_total = try allocator.alloc(f64, mineral_face_count);
            const mineral_macro_face_total = try allocator.alloc(f64, mineral_face_count);
            const dissolved_gas_micro_face_step = try allocator.alloc(f64, dissolved_gas_face_count);
            const dissolved_gas_macro_face_step = try allocator.alloc(f64, dissolved_gas_face_count);
            const dissolved_gas_micro_face_total = try allocator.alloc(f64, dissolved_gas_face_count);
            const dissolved_gas_macro_face_total = try allocator.alloc(f64, dissolved_gas_face_count);
            const gas_atmospheric_total = try allocator.alloc(f64, context.soil_gas_transport.atmospheric_flux_g_per_h.len);
            const gas_subsurface_total = try allocator.alloc(f64, context.soil_gas_transport.subsurface_flux_g_per_h.len);
            const gas_face_total = try allocator.alloc(
                f64,
                try std.math.mul(usize, context.soil_transport_faces.micropore_faces.len, ecosys.gas_transport.species_count),
            );
            const gas_bubble_input_total = try allocator.alloc(
                ecosys.hourly_cell_conservation.IntercellTransfer,
                context.grid.layer_count,
            );
            const gas_bubble_output_total = try allocator.alloc(
                ecosys.hourly_cell_conservation.IntercellTransfer,
                context.grid.layer_count,
            );
            const ground_air_snow_vapor = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_snow_temperature = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_combined_sensible = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_combined_vapor = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_combined_vapor_fraction = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_combined_temperature = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_step_entry_sensible_heat = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_step_balance = try allocator.alloc(ecosys.ground_air_exchange.VaporBalance, context.grid.cell_count);
            const ground_air_balance_total = try allocator.alloc(ecosys.ground_air_exchange.VaporBalance, context.grid.cell_count);
            const ground_air_sensible_heat_closure_absolute_total = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_sensible_heat_storage_activity_total = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_sensible_heat_transfer_activity_total = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_sensible_heat_arithmetic_activity_total = try allocator.alloc(f64, context.grid.cell_count);
            const ground_air_iteration_total = try allocator.alloc(u32, context.grid.cell_count);
            const ground_air_published_balance = try allocator.dupe(ecosys.ground_air_exchange.VaporBalance, context.ground_air.vapor_balance);
            const ground_air_published_iterations = try allocator.dupe(u16, context.ground_air.iteration_count);
            const snow_vapor_conductance = try allocator.alloc(f64, context.grid.cell_count);
            const snow_sensible_conductance = try allocator.alloc(f64, context.grid.cell_count);
            const snow_radiation_rate = try allocator.alloc(f64, context.grid.cell_count);
            const snow_evaporation = try allocator.alloc(f64, context.grid.cell_count);
            const snow_condensation = try allocator.alloc(f64, context.grid.cell_count);
            const snow_boundary_heat = try allocator.alloc(f64, context.grid.cell_count);
            const snow_evaporation_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_condensation_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_boundary_heat_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_latent_heat = try allocator.alloc(f64, context.grid.cell_count);
            const snow_carrier_heat = try allocator.alloc(f64, context.grid.cell_count);
            const snow_air_heat = try allocator.alloc(f64, context.grid.cell_count);
            const snow_radiative_heat = try allocator.alloc(f64, context.grid.cell_count);
            const snow_reference_state_heat_by_cell = try allocator.alloc(f64, context.grid.cell_count);
            const drift_source_carrier = try allocator.alloc(f64, context.grid.cell_count);
            const drift_total = try allocator.alloc(f64, context.grid.cell_count);
            const drift_east = try allocator.alloc(f64, context.grid.cell_count);
            const drift_west = try allocator.alloc(f64, context.grid.cell_count);
            const drift_south = try allocator.alloc(f64, context.grid.cell_count);
            const drift_north = try allocator.alloc(f64, context.grid.cell_count);
            const compaction_snowfall = try allocator.alloc(f64, context.grid.cell_count);
            const snow_solid_step = try allocator.alloc(f64, context.grid.cell_count);
            const snow_liquid_step = try allocator.alloc(f64, context.grid.cell_count);
            const snow_heat_step = try allocator.alloc(f64, context.grid.cell_count);
            const snow_solid_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_liquid_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_heat_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_entry_top_heat_capacity = try allocator.alloc(f64, context.grid.cell_count);
            const snow_atmospheric_step_g = try allocator.alloc(f64, context.snow_atmospheric_input_g.len);
            const snow_atmospheric_step_salt = try allocator.alloc(f64, context.snow_atmospheric_input_salt_mol.len);
            const snow_atmospheric_total_g = try allocator.alloc(f64, context.snow_atmospheric_input_g.len);
            const snow_atmospheric_total_salt = try allocator.alloc(f64, context.snow_atmospheric_input_salt_mol.len);
            const base_water_to_litter = try allocator.dupe(f64, context.surface_precipitation.water_to_litter_m3_per_h);
            const base_water_to_matrix = try allocator.dupe(f64, context.surface_precipitation.water_to_matrix_m3_per_h);
            const base_water_to_macropore = try allocator.dupe(f64, context.surface_precipitation.water_to_macropore_m3_per_h);
            const snow_downward_total = try allocator.alloc(f64, context.transport_hydrology.snow_downward_water_flux_m3_per_step.len);
            const snow_litter_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_matrix_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_macropore_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_downward_g_total = try allocator.alloc(f64, context.snow_accepted_downward_g.len);
            const snow_downward_salt_total = try allocator.alloc(f64, context.snow_accepted_downward_salt_mol.len);
            const snow_layer_count = context.snow_transport.active.len;
            const snow_relayering_step = try ecosys.snow_relayering.AcceptedTransfers.init(allocator, snow_layer_count);
            const snow_relayering_total = try ecosys.snow_relayering.AcceptedTransfers.init(allocator, snow_layer_count);
            const snow_face_entry_temperature = try allocator.alloc(f64, snow_layer_count);
            const snow_activity_active = try allocator.alloc(bool, snow_layer_count);
            const snow_conduction_heat_step = try allocator.alloc(f64, snow_layer_count);
            const snow_conduction_heat_total = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_diffusion_water_step = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_diffusion_water_total = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_diffusion_water_downward_total = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_diffusion_water_upward_total = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_diffusion_heat_step = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_diffusion_heat_total = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_diffusion_heat_downward_total = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_diffusion_heat_upward_total = try allocator.alloc(f64, snow_layer_count);
            const snow_vapor_equilibrium_heat_total = try allocator.alloc(f64, snow_layer_count);
            const snow_inactive_reference_heat_step = try allocator.alloc(f64, snow_layer_count);
            const snow_inactive_reference_heat_total = try allocator.alloc(f64, snow_layer_count);
            const snow_melt_heat_step = try allocator.alloc(f64, snow_layer_count);
            const snow_melt_heat_total = try allocator.alloc(f64, snow_layer_count);
            const snow_discharge_heat_step = try allocator.alloc(f64, context.grid.cell_count);
            const snow_discharge_heat_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_surface_transfer_water_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_topsoil_transfer_water_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_surface_transfer_heat_step = try allocator.alloc(f64, context.grid.cell_count);
            const snow_topsoil_transfer_heat_step = try allocator.alloc(f64, context.grid.cell_count);
            const snow_surface_transfer_heat_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_topsoil_transfer_heat_total = try allocator.alloc(f64, context.grid.cell_count);
            const snow_base_litter_conduction_step = try allocator.alloc(f64, context.grid.cell_count);
            const snow_base_topsoil_conduction_step = try allocator.alloc(f64, context.grid.cell_count);
            const snow_base_litter_conduction_by_layer = try allocator.alloc(f64, snow_layer_count);
            const snow_base_topsoil_conduction_by_layer = try allocator.alloc(f64, snow_layer_count);
            const snow_discharge_water_by_layer = try allocator.alloc(f64, snow_layer_count);
            const snow_discharge_heat_by_layer = try allocator.alloc(f64, snow_layer_count);
            const snow_discharge_g_by_layer = try allocator.alloc(
                f64,
                try std.math.mul(usize, snow_layer_count, ecosys.snow_solute_transport.species_count),
            );
            const snow_discharge_salt_by_layer = try allocator.alloc(
                f64,
                try std.math.mul(usize, snow_layer_count, ecosys.snow_solute_transport.salt_species_count),
            );
            const snow_discharge_total = try allocator.alloc(ecosys.snow_solute_transport.SurfaceDischarge, context.grid.cell_count);
            const snow_phase_heat_by_cell = try allocator.alloc(f64, context.grid.cell_count);
            const snow_vapor_heat_by_cell = try allocator.alloc(f64, context.grid.cell_count);
            const snow_inactive_reference_heat_by_cell = try allocator.alloc(f64, context.grid.cell_count);
            const drift_cell_ledger = try ecosys.hourly_cell_conservation.BoundaryLedger.init(allocator, context.grid.cell_count);
            const water_storage_update_operation_count_by_scope = try allocator.alloc(
                u16,
                try context.hourly_layer_boundary_ledger.layout.scopeCount(),
            );
            const chemistry_rebase_roundoff_by_layer = try allocator.alloc(
                ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
                context.grid.layer_count,
            );
            const snow_water_storage_before_m3 = try allocator.alloc(
                f64,
                context.snow_transport.active.len,
            );
            var self: Self = .{
                .context = context,
                .scratch = scratch,
                .allocator = backing_allocator,
                .forcing = forcing,
                .schedule_snapshot = schedule_snapshot,
                .transport_replay = transport_replay,
                .entry_topsoil_chemistry = entry_topsoil_chemistry,
                .litter_soil_physical_candidates = litter_soil_candidates,
                .litter_soil_water_flux_m3 = litter_soil_flux,
                .initial_gas_state = initial_gas_state,
                .surface_temperature_work = surface_temperature_work,
                .surface_temperature_total = surface_temperature_total,
                .surface_energy_work = surface_energy_work,
                .surface_energy_total = surface_energy_total,
                .surface_air_vapor_pressure_kpa = surface_air_vapor_pressure,
                .surface_snow_cover_fraction = surface_snow_cover,
                .surface_dry_litter_albedo = surface_dry_litter_albedo,
                .surface_live_litter_cover_fraction = surface_live_litter_cover_fraction,
                .surface_liquid_water_before_temperature_m3 = surface_liquid_water_before_temperature,
                .litter_vapor_water_equivalent_m3 = litter_vapor_water_equivalent,
                .litter_vapor_conductance_m3_per_h = litter_vapor_conductance,
                .litter_sensible_conductance_megajoules_per_h_k = litter_sensible_conductance,
                .topsoil_vapor_conductance_m3_per_h = topsoil_vapor_conductance,
                .topsoil_sensible_conductance_megajoules_per_h_k = topsoil_sensible_conductance,
                .topsoil_sensible_heat_step_megajoules = topsoil_sensible_heat_step,
                .deferred_sensible_conductance = deferred_sensible_conductance,
                .sensible_pair_capacity_megajoules_per_k = sensible_pair_capacity,
                .sensible_pair_temperature_k = sensible_pair_temperature,
                .sensible_pair_conductance_megajoules_per_h_k = sensible_pair_conductance,
                .topsoil_sensible_heat_total_megajoules = topsoil_sensible_heat_total,
                .surface_iteration_total = surface_iteration_total,
                .surface_newton_total = surface_newton_total,
                .surface_picard_total = surface_picard_total,
                .base_cell_heat_source_megajoules = base_cell_heat_source,
                .surface_conduction_total_megajoules = surface_conduction_total,
                .surface_phase_sensible_adjustment_total_megajoules_by_cell = surface_phase_sensible_adjustment_total,
                .surface_internal_vapor_latent_heat_total_megajoules_by_cell = surface_internal_vapor_latent_heat_total,
                .surface_atmospheric_water_thermalization_total_megajoules_by_cell = surface_atmospheric_water_thermalization_total,
                .surface_energy_residual_signed_total_megajoules_by_cell = surface_energy_residual_signed_total,
                .surface_energy_residual_absolute_total_megajoules_by_cell = surface_energy_residual_absolute_total,
                .irrigation_parameters = irrigationChemistryParameters(context),
                .max_iterations = max_iterations,
                .exact_substep_count = exact_substep_count,
                .gas_failure_report = gas_failure_report,
                .pore_diffusivity_m2_per_h = pore_diffusivity,
                .micropore_face_step_mol = micro_step,
                .macropore_face_step_mol = macro_step,
                .boundary_step_mol = boundary_step,
                .micropore_face_total_mol = micro_total,
                .macropore_face_total_mol = macro_total,
                .boundary_total_mol = boundary_total,
                .organic_boundary_total_g = organic_total,
                .mineral_boundary_total_g_n = mineral_total,
                .dissolved_gas_boundary_total_g = dissolved_gas_total,
                .litter_soil_organic_heat_rebase_total_megajoules_by_cell = litter_soil_organic_heat_rebase_total,
                .litter_soil_organic_carbon_step_total_g_c_by_cell = litter_soil_organic_carbon_step_total,
                .litter_soil_surface_to_topsoil_total = litter_soil_surface_to_topsoil_total,
                .litter_soil_topsoil_to_surface_total = litter_soil_topsoil_to_surface_total,
                .organic_micropore_face_step_g = organic_micro_face_step,
                .organic_macropore_face_step_g = organic_macro_face_step,
                .organic_micropore_face_total_g = organic_micro_face_total,
                .organic_macropore_face_total_g = organic_macro_face_total,
                .mineral_micropore_face_step_mol = mineral_micro_face_step,
                .mineral_macropore_face_step_mol = mineral_macro_face_step,
                .mineral_micropore_face_total_mol = mineral_micro_face_total,
                .mineral_macropore_face_total_mol = mineral_macro_face_total,
                .dissolved_gas_micropore_face_step_g = dissolved_gas_micro_face_step,
                .dissolved_gas_macropore_face_step_g = dissolved_gas_macro_face_step,
                .dissolved_gas_micropore_face_total_g = dissolved_gas_micro_face_total,
                .dissolved_gas_macropore_face_total_g = dissolved_gas_macro_face_total,
                .gas_atmospheric_total_g = gas_atmospheric_total,
                .gas_subsurface_total_g = gas_subsurface_total,
                .gas_face_total_g = gas_face_total,
                .gas_bubble_input_total = gas_bubble_input_total,
                .gas_bubble_output_total = gas_bubble_output_total,
                .ground_air_snow_surface_vapor_fraction = ground_air_snow_vapor,
                .ground_air_snow_surface_temperature_k = ground_air_snow_temperature,
                .ground_air_combined_surface_sensible_conductance = ground_air_combined_sensible,
                .ground_air_combined_surface_vapor_conductance = ground_air_combined_vapor,
                .ground_air_combined_surface_vapor_fraction = ground_air_combined_vapor_fraction,
                .ground_air_combined_surface_temperature_k = ground_air_combined_temperature,
                .ground_air_step_entry_sensible_heat_megajoules = ground_air_step_entry_sensible_heat,
                .ground_air_step_vapor_balance = ground_air_step_balance,
                .ground_air_vapor_balance_total = ground_air_balance_total,
                .ground_air_sensible_heat_closure_absolute_total_megajoules = ground_air_sensible_heat_closure_absolute_total,
                .ground_air_sensible_heat_storage_activity_total_megajoules = ground_air_sensible_heat_storage_activity_total,
                .ground_air_sensible_heat_transfer_activity_total_megajoules = ground_air_sensible_heat_transfer_activity_total,
                .ground_air_sensible_heat_arithmetic_activity_total_megajoules = ground_air_sensible_heat_arithmetic_activity_total,
                .ground_air_iteration_total = ground_air_iteration_total,
                .ground_air_accepted_substep_count = 0,
                .ground_air_accepted_duration_hours = 0,
                .ground_air_geometry_balance = ground_air_geometry_balance,
                .ground_air_published_vapor_balance = ground_air_published_balance,
                .ground_air_published_iterations = ground_air_published_iterations,
                .snow_vapor_conductance_m3_per_h = snow_vapor_conductance,
                .snow_sensible_conductance_megajoules_per_h_k = snow_sensible_conductance,
                .snow_radiative_heat_megajoules_per_h = snow_radiation_rate,
                .snow_evaporation_m3 = snow_evaporation,
                .snow_condensation_m3 = snow_condensation,
                .snow_boundary_heat_megajoules = snow_boundary_heat,
                .snow_evaporation_total_m3 = snow_evaporation_total,
                .snow_condensation_total_m3 = snow_condensation_total,
                .snow_boundary_heat_total_megajoules = snow_boundary_heat_total,
                .snow_latent_heat_megajoules = snow_latent_heat,
                .snow_carrier_sensible_heat_megajoules = snow_carrier_heat,
                .snow_air_sensible_heat_megajoules = snow_air_heat,
                .snow_radiative_heat_megajoules = snow_radiative_heat,
                .snow_reference_state_heat_megajoules = 0,
                .snow_reference_state_heat_megajoules_by_cell = snow_reference_state_heat_by_cell,
                .snow_drift_source_carrier_m3 = drift_source_carrier,
                .snow_drift_total_m3 = drift_total,
                .snow_drift_east_m3 = drift_east,
                .snow_drift_west_m3 = drift_west,
                .snow_drift_south_m3 = drift_south,
                .snow_drift_north_m3 = drift_north,
                .snow_compaction_snowfall_m3 = compaction_snowfall,
                .snow_relayering_step = snow_relayering_step,
                .snow_relayering_total = snow_relayering_total,
                .snow_solid_input_step_m3 = snow_solid_step,
                .snow_liquid_input_step_m3 = snow_liquid_step,
                .snow_heat_input_step_megajoules = snow_heat_step,
                .snow_solid_input_total_m3 = snow_solid_total,
                .snow_liquid_input_total_m3 = snow_liquid_total,
                .snow_heat_input_total_megajoules = snow_heat_total,
                .snow_entry_top_heat_capacity_megajoules_per_k = snow_entry_top_heat_capacity,
                .snow_face_entry_temperature_k = snow_face_entry_temperature,
                .snow_atmospheric_input_step_g = snow_atmospheric_step_g,
                .snow_atmospheric_input_step_salt_mol = snow_atmospheric_step_salt,
                .snow_atmospheric_input_total_g = snow_atmospheric_total_g,
                .snow_atmospheric_input_total_salt_mol = snow_atmospheric_total_salt,
                .base_water_to_litter_m3_per_h = base_water_to_litter,
                .base_water_to_matrix_m3_per_h = base_water_to_matrix,
                .base_water_to_macropore_m3_per_h = base_water_to_macropore,
                .snow_downward_water_total_m3 = snow_downward_total,
                .snow_to_litter_water_total_m3 = snow_litter_total,
                .snow_to_matrix_water_total_m3 = snow_matrix_total,
                .snow_to_macropore_water_total_m3 = snow_macropore_total,
                .snow_accepted_downward_total_g = snow_downward_g_total,
                .snow_accepted_downward_total_salt_mol = snow_downward_salt_total,
                .snow_activity_active_by_layer = snow_activity_active,
                .snow_conduction_heat_step_megajoules_by_layer = snow_conduction_heat_step,
                .snow_conduction_heat_total_megajoules_by_layer = snow_conduction_heat_total,
                .snow_vapor_diffusion_water_step_m3_by_layer = snow_vapor_diffusion_water_step,
                .snow_vapor_diffusion_water_total_m3_by_layer = snow_vapor_diffusion_water_total,
                .snow_vapor_diffusion_water_downward_total_m3_by_layer = snow_vapor_diffusion_water_downward_total,
                .snow_vapor_diffusion_water_upward_total_m3_by_layer = snow_vapor_diffusion_water_upward_total,
                .snow_vapor_diffusion_heat_step_megajoules_by_layer = snow_vapor_diffusion_heat_step,
                .snow_vapor_diffusion_heat_total_megajoules_by_layer = snow_vapor_diffusion_heat_total,
                .snow_vapor_diffusion_heat_downward_total_megajoules_by_layer = snow_vapor_diffusion_heat_downward_total,
                .snow_vapor_diffusion_heat_upward_total_megajoules_by_layer = snow_vapor_diffusion_heat_upward_total,
                .snow_vapor_equilibrium_heat_total_megajoules_by_layer = snow_vapor_equilibrium_heat_total,
                .snow_inactive_reference_heat_step_megajoules_by_layer = snow_inactive_reference_heat_step,
                .snow_inactive_reference_heat_total_megajoules_by_layer = snow_inactive_reference_heat_total,
                .snow_melt_heat_step_megajoules_by_layer = snow_melt_heat_step,
                .snow_melt_heat_total_megajoules_by_layer = snow_melt_heat_total,
                .snow_discharge_heat_step_megajoules_by_cell = snow_discharge_heat_step,
                .snow_discharge_heat_total_megajoules_by_cell = snow_discharge_heat_total,
                .snow_surface_transfer_water_total_m3_by_cell = snow_surface_transfer_water_total,
                .snow_topsoil_transfer_water_total_m3_by_cell = snow_topsoil_transfer_water_total,
                .snow_surface_transfer_heat_step_megajoules_by_cell = snow_surface_transfer_heat_step,
                .snow_topsoil_transfer_heat_step_megajoules_by_cell = snow_topsoil_transfer_heat_step,
                .snow_surface_transfer_heat_total_megajoules_by_cell = snow_surface_transfer_heat_total,
                .snow_topsoil_transfer_heat_total_megajoules_by_cell = snow_topsoil_transfer_heat_total,
                .snow_base_litter_conduction_heat_step_megajoules_by_cell = snow_base_litter_conduction_step,
                .snow_base_topsoil_conduction_heat_step_megajoules_by_cell = snow_base_topsoil_conduction_step,
                .snow_base_litter_conduction_heat_total_megajoules_by_source_layer = snow_base_litter_conduction_by_layer,
                .snow_base_topsoil_conduction_heat_total_megajoules_by_source_layer = snow_base_topsoil_conduction_by_layer,
                .snow_discharge_water_total_m3_by_source_layer = snow_discharge_water_by_layer,
                .snow_discharge_heat_total_megajoules_by_source_layer = snow_discharge_heat_by_layer,
                .snow_discharge_total_g_by_source_layer_species = snow_discharge_g_by_layer,
                .snow_discharge_total_salt_mol_by_source_layer_species = snow_discharge_salt_by_layer,
                .snow_surface_discharge_total = snow_discharge_total,
                .snow_phase_heat_total_megajoules_by_cell = snow_phase_heat_by_cell,
                .snow_vapor_heat_total_megajoules_by_cell = snow_vapor_heat_by_cell,
                .snow_inactive_reference_heat_total_megajoules_by_cell = snow_inactive_reference_heat_by_cell,
                .snow_phase_heat_total_megajoules = 0,
                .snow_vapor_heat_total_megajoules = 0,
                .snow_inactive_reference_heat_total_megajoules = 0,
                .snow_drift_cell_ledger = drift_cell_ledger,
                .snow_drift_landscape_ledger = .{},
                .snow_water_storage_before_m3 = snow_water_storage_before_m3,
                .water_storage_update_operation_count_by_scope = water_storage_update_operation_count_by_scope,
                .chemistry_rebase_roundoff_by_layer = chemistry_rebase_roundoff_by_layer,
                .surface_chemistry_rebase_roundoff_by_cell = surface_chemistry_rebase_roundoff_by_cell,
            };
            self.zeroTotals();
            return self;
        }

        noinline fn zeroTotals(self: *Self) void {
            self.transport_replay.reset();
            @memset(self.water_storage_update_operation_count_by_scope, 0);
            @memset(self.chemistry_rebase_roundoff_by_layer, .{});
            @memset(self.surface_chemistry_rebase_roundoff_by_cell, .{});
            inline for (.{
                self.surface_temperature_total.equilibrium_temperature_k,
                self.surface_temperature_total.snow_free_surface_albedo,
                self.surface_temperature_total.energy_residual_megajoules_per_m2,
                self.surface_temperature_total.residual_tolerance_megajoules_per_m2,
                self.surface_temperature_total.energy_conservation_tolerance_megajoules_per_m2,
                self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2,
                self.surface_temperature_total.latent_heat_flux_megajoules_per_m2,
                self.surface_temperature_total.vapor_sensible_heat_flux_megajoules_per_m2,
                self.surface_temperature_total.conductive_heat_flux_megajoules_per_m2,
                self.surface_temperature_total.storage_heat_flux_megajoules_per_m2,
                self.surface_temperature_total.phase_heat_flux_megajoules_per_m2,
                self.surface_temperature_total.latent_heat_outside_surface_residual_megajoules_per_m2,
                self.surface_temperature_total.vapor_liquid_water_change_m3,
                self.surface_temperature_total.atmospheric_vapor_water_change_m3,
                self.surface_temperature_total.internal_vapor_water_change_m3,
                self.surface_temperature_total.liquid_water_change_m3,
                self.surface_temperature_total.ice_water_equivalent_change_m3,
                self.surface_energy_total.downward_sky_longwave_megajoules_per_m2,
                self.surface_energy_total.emitted_sky_longwave_megajoules_per_m2,
                self.surface_energy_total.net_longwave_megajoules_per_m2,
                self.surface_energy_total.net_radiation_megajoules_per_m2,
            }) |values| @memset(values, 0);
            @memset(self.surface_temperature_total.iteration_count, 0);
            @memset(self.surface_temperature_total.newton_raphson_step_count, 0);
            @memset(self.surface_temperature_total.picard_step_count, 0);
            @memset(self.surface_temperature_total.residual_has_adjacent_root_certificate, false);
            @memset(self.surface_temperature_total.residual_accepted_by_conservation_ceiling, false);
            @memset(self.surface_iteration_total, 0);
            @memset(self.surface_newton_total, 0);
            @memset(self.surface_picard_total, 0);
            @memset(self.surface_conduction_total_megajoules, 0);
            @memset(self.surface_phase_sensible_adjustment_total_megajoules_by_cell, 0);
            @memset(self.surface_internal_vapor_latent_heat_total_megajoules_by_cell, 0);
            @memset(self.surface_atmospheric_water_thermalization_total_megajoules_by_cell, 0);
            @memset(self.surface_energy_residual_signed_total_megajoules_by_cell, 0);
            @memset(self.surface_energy_residual_absolute_total_megajoules_by_cell, 0);
            @memset(self.topsoil_sensible_heat_total_megajoules, 0);
            @memset(self.topsoil_sensible_heat_step_megajoules, 0);
            @memset(self.micropore_face_total_mol, 0);
            @memset(self.macropore_face_total_mol, 0);
            @memset(self.boundary_total_mol, 0);
            @memset(self.organic_boundary_total_g, 0);
            @memset(self.mineral_boundary_total_g_n, 0);
            @memset(self.dissolved_gas_boundary_total_g, 0);
            @memset(self.litter_soil_organic_heat_rebase_total_megajoules_by_cell, 0);
            @memset(self.litter_soil_organic_carbon_step_total_g_c_by_cell, 0);
            @memset(self.litter_soil_surface_to_topsoil_total, .{});
            @memset(self.litter_soil_topsoil_to_surface_total, .{});
            @memset(self.organic_micropore_face_total_g, 0);
            @memset(self.organic_macropore_face_total_g, 0);
            @memset(self.mineral_micropore_face_total_mol, 0);
            @memset(self.mineral_macropore_face_total_mol, 0);
            @memset(self.dissolved_gas_micropore_face_total_g, 0);
            @memset(self.dissolved_gas_macropore_face_total_g, 0);
            @memset(self.gas_atmospheric_total_g, 0);
            @memset(self.gas_subsurface_total_g, 0);
            @memset(self.gas_face_total_g, 0);
            @memset(self.gas_bubble_input_total, .{});
            @memset(self.gas_bubble_output_total, .{});
            seedGroundAirFullHourBalance(
                self.ground_air_vapor_balance_total,
                self.ground_air_geometry_balance,
            );
            @memset(self.ground_air_sensible_heat_closure_absolute_total_megajoules, 0);
            @memset(self.ground_air_sensible_heat_storage_activity_total_megajoules, 0);
            for (self.ground_air_sensible_heat_arithmetic_activity_total_megajoules, self.ground_air_geometry_balance) |*activity, geometry| {
                const refreshed_sensible_heat_megajoules =
                    geometry.initial_sensible_heat_megajoules +
                    geometry.sensible_heat_storage_change_megajoules;
                activity.* = @abs(geometry.initial_sensible_heat_megajoules) +
                    @abs(refreshed_sensible_heat_megajoules) +
                    @abs(geometry.sensible_heat_storage_change_megajoules) +
                    @abs(geometry.atmospheric_sensible_heat_transfer_megajoules);
            }
            for (self.ground_air_sensible_heat_transfer_activity_total_megajoules, self.ground_air_geometry_balance) |*activity, geometry|
                activity.* = @abs(geometry.atmospheric_sensible_heat_transfer_megajoules);
            @memset(self.ground_air_iteration_total, 0);
            self.ground_air_accepted_substep_count = 0;
            self.ground_air_accepted_duration_hours = 0;
            self.snow_reference_state_heat_megajoules = 0;
            @memset(self.snow_reference_state_heat_megajoules_by_cell, 0);
            inline for (.{
                self.snow_drift_source_carrier_m3,
                self.snow_drift_total_m3,
                self.snow_drift_east_m3,
                self.snow_drift_west_m3,
                self.snow_drift_south_m3,
                self.snow_drift_north_m3,
            }) |values| @memset(values, 0);
            self.snow_drift_cell_ledger.reset();
            self.snow_drift_landscape_ledger.reset();
            self.snow_relayering_step.reset();
            self.snow_relayering_total.reset();
            inline for (.{
                self.snow_solid_input_total_m3,
                self.snow_liquid_input_total_m3,
                self.snow_heat_input_total_megajoules,
                self.snow_atmospheric_input_total_g,
                self.snow_atmospheric_input_total_salt_mol,
                self.snow_evaporation_total_m3,
                self.snow_condensation_total_m3,
                self.snow_boundary_heat_total_megajoules,
                self.snow_downward_water_total_m3,
                self.snow_to_litter_water_total_m3,
                self.snow_to_matrix_water_total_m3,
                self.snow_to_macropore_water_total_m3,
                self.snow_accepted_downward_total_g,
                self.snow_accepted_downward_total_salt_mol,
                self.snow_conduction_heat_step_megajoules_by_layer,
                self.snow_conduction_heat_total_megajoules_by_layer,
                self.snow_vapor_diffusion_water_step_m3_by_layer,
                self.snow_vapor_diffusion_water_total_m3_by_layer,
                self.snow_vapor_diffusion_water_downward_total_m3_by_layer,
                self.snow_vapor_diffusion_water_upward_total_m3_by_layer,
                self.snow_vapor_diffusion_heat_step_megajoules_by_layer,
                self.snow_vapor_diffusion_heat_total_megajoules_by_layer,
                self.snow_vapor_diffusion_heat_downward_total_megajoules_by_layer,
                self.snow_vapor_diffusion_heat_upward_total_megajoules_by_layer,
                self.snow_vapor_equilibrium_heat_total_megajoules_by_layer,
                self.snow_inactive_reference_heat_step_megajoules_by_layer,
                self.snow_inactive_reference_heat_total_megajoules_by_layer,
                self.snow_melt_heat_step_megajoules_by_layer,
                self.snow_melt_heat_total_megajoules_by_layer,
                self.snow_discharge_heat_step_megajoules_by_cell,
                self.snow_discharge_heat_total_megajoules_by_cell,
                self.snow_surface_transfer_water_total_m3_by_cell,
                self.snow_topsoil_transfer_water_total_m3_by_cell,
                self.snow_surface_transfer_heat_step_megajoules_by_cell,
                self.snow_topsoil_transfer_heat_step_megajoules_by_cell,
                self.snow_surface_transfer_heat_total_megajoules_by_cell,
                self.snow_topsoil_transfer_heat_total_megajoules_by_cell,
                self.snow_base_litter_conduction_heat_step_megajoules_by_cell,
                self.snow_base_topsoil_conduction_heat_step_megajoules_by_cell,
                self.snow_base_litter_conduction_heat_total_megajoules_by_source_layer,
                self.snow_base_topsoil_conduction_heat_total_megajoules_by_source_layer,
                self.snow_discharge_water_total_m3_by_source_layer,
                self.snow_discharge_heat_total_megajoules_by_source_layer,
                self.snow_discharge_total_g_by_source_layer_species,
                self.snow_discharge_total_salt_mol_by_source_layer_species,
                self.snow_phase_heat_total_megajoules_by_cell,
                self.snow_vapor_heat_total_megajoules_by_cell,
                self.snow_inactive_reference_heat_total_megajoules_by_cell,
            }) |values| @memset(values, 0);
            @memset(self.snow_activity_active_by_layer, false);
            @memset(self.snow_surface_discharge_total, .{});
            self.snow_phase_heat_total_megajoules = 0;
            self.snow_vapor_heat_total_megajoules = 0;
            self.snow_inactive_reference_heat_total_megajoules = 0;
        }

        fn incrementWaterStorageUpdate(
            self: *Self,
            address: ecosys.layer_local_conservation.ScopeAddress,
            amount: u16,
        ) !void {
            if (amount == 0) return;
            const scope = try self.context.hourly_layer_boundary_ledger.layout.index(address);
            if (scope >= self.water_storage_update_operation_count_by_scope.len)
                return error.WaterStorageUpdateProvenanceDimensionMismatch;
            self.water_storage_update_operation_count_by_scope[scope] =
                std.math.add(
                    u16,
                    self.water_storage_update_operation_count_by_scope[scope],
                    amount,
                ) catch return error.WaterStorageUpdateProvenanceOverflow;
        }

        fn captureSnowWaterStorage(self: *Self) !void {
            const snow = self.context.snow_transport;
            if (self.snow_water_storage_before_m3.len != snow.active.len)
                return error.WaterStorageUpdateProvenanceDimensionMismatch;
            const ice_density = self.context.runscript.snow_ice_density_megagrams_per_m3;
            for (self.snow_water_storage_before_m3, 0..) |*before, layer| {
                before.* = snow.solid_snow_water_equivalent_m3[layer] +
                    snow.liquid_water_volume_m3[layer] +
                    snow.vapor_water_equivalent_m3[layer] +
                    snow.ice_volume_m3[layer] * ice_density;
                if (!std.math.isFinite(before.*) or before.* < 0)
                    return error.InvalidWaterStorageUpdateArithmeticProvenance;
            }
        }

        fn incrementChangedSnowWaterStorageUpdates(self: *Self) !void {
            const snow = self.context.snow_transport;
            if (self.snow_water_storage_before_m3.len != snow.active.len)
                return error.WaterStorageUpdateProvenanceDimensionMismatch;
            const ice_density = self.context.runscript.snow_ice_density_megagrams_per_m3;
            for (self.snow_water_storage_before_m3, 0..) |before, layer| {
                const after = snow.solid_snow_water_equivalent_m3[layer] +
                    snow.liquid_water_volume_m3[layer] +
                    snow.vapor_water_equivalent_m3[layer] +
                    snow.ice_volume_m3[layer] * ice_density;
                if (!std.math.isFinite(after) or after < 0)
                    return error.InvalidWaterStorageUpdateArithmeticProvenance;
                if (after == before) continue;
                try self.incrementWaterStorageUpdate(.{
                    .kind = .snow_layer,
                    .cell = layer / snow.layer_capacity,
                    .layer = layer % snow.layer_capacity,
                }, 1);
            }
        }

        fn addWaterStorageRoundoffUpward(left: f64, right: f64) !f64 {
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

        fn publishWaterStorageUpdateProvenance(
            self: *Self,
            soil_roundoff_allowance_m3_by_layer: []const f64,
        ) !void {
            const destination = self.context.hourly_layer_boundary_ledger
                .water_storage_update_operation_count_by_scope;
            const pending = self.context.hourly_layer_boundary_ledger
                .pending_water_storage_roundoff_allowance_m3_by_scope;
            if (destination.len != self.water_storage_update_operation_count_by_scope.len)
                return error.WaterStorageUpdateProvenanceDimensionMismatch;
            if (pending.len != destination.len or
                soil_roundoff_allowance_m3_by_layer.len != self.context.grid.layer_count)
                return error.WaterStorageUpdateProvenanceDimensionMismatch;
            for (destination) |count| if (count != 0)
                return error.DuplicateWaterStorageUpdateArithmeticProvenance;
            // Preflight the complete mapping before either sidecar changes.
            for (0..self.context.grid.cell_count) |cell| {
                for (0..self.context.grid.soil_layer_capacity) |local_layer| {
                    const layer = try self.context.grid.layerIndex(cell, local_layer);
                    const allowance = soil_roundoff_allowance_m3_by_layer[layer];
                    if (!std.math.isFinite(allowance) or allowance < 0)
                        return error.InvalidWaterStorageUpdateArithmeticProvenance;
                    if (local_layer >= self.context.grid.active_soil_layer_count[cell]) {
                        if (allowance != 0)
                            return error.InvalidWaterStorageUpdateArithmeticProvenance;
                        continue;
                    }
                    const scope = try self.context.hourly_layer_boundary_ledger.layout.index(.{
                        .kind = .soil_layer,
                        .cell = cell,
                        .layer = local_layer,
                    });
                    _ = try addWaterStorageRoundoffUpward(pending[scope], allowance);
                }
            }
            for (0..self.context.grid.cell_count) |cell| {
                for (0..self.context.grid.active_soil_layer_count[cell]) |local_layer| {
                    const layer = self.context.grid.layerIndex(cell, local_layer) catch unreachable;
                    const scope = self.context.hourly_layer_boundary_ledger.layout.index(.{
                        .kind = .soil_layer,
                        .cell = cell,
                        .layer = local_layer,
                    }) catch unreachable;
                    pending[scope] = addWaterStorageRoundoffUpward(
                        pending[scope],
                        soil_roundoff_allowance_m3_by_layer[layer],
                    ) catch unreachable;
                }
            }
            @memcpy(destination, self.water_storage_update_operation_count_by_scope);
        }

        fn addHeatStorageRoundoffUpward(left: f64, right: f64) !f64 {
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

        fn publishHeatStorageUpdateProvenance(
            self: *Self,
            soil_roundoff_allowance_megajoules_by_layer: []const f64,
        ) !void {
            const pending = self.context.hourly_layer_boundary_ledger
                .pending_heat_storage_roundoff_allowance_megajoules_by_scope;
            if (pending.len != self.context.hourly_layer_boundary_ledger.activity.len or
                soil_roundoff_allowance_megajoules_by_layer.len != self.context.grid.layer_count)
                return error.HeatStorageUpdateProvenanceDimensionMismatch;
            for (0..self.context.grid.cell_count) |cell| {
                for (0..self.context.grid.soil_layer_capacity) |local_layer| {
                    const layer = try self.context.grid.layerIndex(cell, local_layer);
                    const allowance = soil_roundoff_allowance_megajoules_by_layer[layer];
                    if (!std.math.isFinite(allowance) or allowance < 0)
                        return error.InvalidHeatStorageUpdateArithmeticProvenance;
                    if (local_layer >= self.context.grid.active_soil_layer_count[cell]) {
                        if (allowance != 0)
                            return error.InvalidHeatStorageUpdateArithmeticProvenance;
                        continue;
                    }
                    const scope = try self.context.hourly_layer_boundary_ledger.layout.index(.{
                        .kind = .soil_layer,
                        .cell = cell,
                        .layer = local_layer,
                    });
                    _ = try addHeatStorageRoundoffUpward(pending[scope], allowance);
                }
            }
            for (0..self.context.grid.cell_count) |cell| {
                for (0..self.context.grid.active_soil_layer_count[cell]) |local_layer| {
                    const layer = self.context.grid.layerIndex(cell, local_layer) catch unreachable;
                    const scope = self.context.hourly_layer_boundary_ledger.layout.index(.{
                        .kind = .soil_layer,
                        .cell = cell,
                        .layer = local_layer,
                    }) catch unreachable;
                    pending[scope] = addHeatStorageRoundoffUpward(
                        pending[scope],
                        soil_roundoff_allowance_megajoules_by_layer[layer],
                    ) catch unreachable;
                }
            }
        }

        fn accumulateChemistryRebaseRoundoff(
            self: *Self,
            layer: usize,
            allowance: ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
        ) !void {
            if (layer >= self.chemistry_rebase_roundoff_by_layer.len)
                return error.ChemistryRebaseProvenanceDimensionMismatch;
            try self.chemistry_rebase_roundoff_by_layer[layer].add(allowance);
        }

        fn accumulateSurfaceChemistryRebaseRoundoff(
            self: *Self,
            cell: usize,
            allowance: ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
        ) !void {
            if (cell >= self.surface_chemistry_rebase_roundoff_by_cell.len)
                return error.ChemistryRebaseProvenanceDimensionMismatch;
            try self.surface_chemistry_rebase_roundoff_by_cell[cell].add(allowance);
        }

        fn previewAndAccumulateSurfaceWaterRebase(
            self: *Self,
            cell: usize,
            old_live_water_m3: f64,
            new_live_water_m3: f64,
        ) !void {
            const allowance = try ecosys.surface_litter_chemistry_carrier_rebase
                .previewCellWaterRoundoff(
                self.context.surface_litter_chemistry,
                cell,
                old_live_water_m3,
                new_live_water_m3,
                try surfaceChemistryRebaseInventoryInputs(self.context, cell),
            );
            try self.accumulateSurfaceChemistryRebaseRoundoff(cell, allowance);
        }

        fn chemistryRebaseInventoryFractions(
            self: *const Self,
            layer: usize,
        ) !ecosys.soil_chemistry_water_carrier_rebase.InventoryFractions {
            const fractions = try self.context.fertilizer_band
                .scienceZoneFractionsForFlatIndex(layer);
            return .{
                .phosphate_non_band = fractions.phosphate_non_band,
                .phosphate_band = fractions.phosphate_band,
            };
        }

        fn publishChemistryRebaseRoundoff(self: *Self) !void {
            try ecosys.layer_local_conservation.accumulateAcceptedChemistryRebaseRoundoff(
                self.context.hourly_cell_boundary_ledger,
                self.context.hourly_layer_boundary_ledger,
                self.chemistry_rebase_roundoff_by_layer,
                12.0,
                self.context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
            );
            try ecosys.layer_local_conservation.accumulateAcceptedSurfaceChemistryRebaseRoundoff(
                self.context.hourly_cell_boundary_ledger,
                self.context.hourly_layer_boundary_ledger,
                self.surface_chemistry_rebase_roundoff_by_cell,
                12.0,
                self.context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                self.context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
            );
        }

        noinline fn restoreSchedule(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.schedule_snapshot.restore();
            Forcing.restoreSchedule(@ptrCast(&self.forcing));
            self.zeroTotals();
        }

        noinline fn rollbackFailure(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.schedule_snapshot.restore();
            Forcing.rollbackFailure(@ptrCast(&self.forcing));
            self.zeroTotals();
        }

        noinline fn prepareSubstep(raw: *anyopaque, time_step_hours: f64) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            try diagnostics.traceSurfaceFrontier(self.context, "substep_entry", time_step_hours);
            const profile_active = !builtin.is_test and
                self.context.executed_weather_hours.* >= 48 and
                self.context.executed_weather_hours.* < 56;
            const profile_start = std.Io.Clock.now(.boot, self.context.io);
            defer {
                if (profile_active) self.temporary_profile_prepare_ns +=
                    profile_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            }
            // VOLWM(M) is the carrier at WATSUB step entry. Keep the pending
            // slot private until the matching face/FLWR fluxes are accepted.
            try self.transport_replay.beginSubstep(time_step_hours);
            try self.entry_topsoil_chemistry.capture(
                self.context.grid,
                self.context.soil_chemistry,
            );
            for (self.snow_entry_top_heat_capacity_megajoules_per_k, 0..) |*capacity, cell|
                capacity.* = self.context.snow_transport.heat_capacity_megajoules_per_k[
                    cell * self.context.snow_transport.layer_capacity
                ];
            var profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceSnowBeforeSoil(time_step_hours);
            try diagnostics.traceSurfaceFrontier(self.context, "after_snow", time_step_hours);
            if (profile_active) self.temporary_profile_prepare_snow_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            if (!builtin.is_test and self.context.executed_weather_hours.* >= 2531 and self.context.executed_weather_hours.* < 2534) {
                const grid = self.context.grid;
                std.log.info("THERMAL_INGRESS stage=before_forcing hour={d} dt_hours={e} temperature_k={e} matrix_water_m3={e} macro_water_m3={e} vapor_m3={e} matrix_input_rate={e} macro_input_rate={e}", .{ self.context.executed_weather_hours.* + 1, time_step_hours, grid.soil_temperature_k[0], grid.matrix_liquid_water_m3[0], grid.macropore_liquid_water_m3[0], grid.water_vapor_volume_m3[0], self.context.surface_precipitation.water_to_matrix_m3_per_h[0], self.context.surface_precipitation.water_to_macropore_m3_per_h[0] });
            }
            try Forcing.prepareSubstep(@ptrCast(&self.forcing), time_step_hours);
            try diagnostics.traceSurfaceFrontier(self.context, "after_forcing", time_step_hours);
            // Direct rain/irrigation water now exists at the current topsoil
            // temperature. Its represented Cl*Tsoil*dW must not also enter
            // through the full donor heat source. Reprice every substep, using
            // the captured direct rates rather than the snow-augmented rates.
            // This is a borrowed read-only view; the runtime owners stay intact.
            var direct_precipitation = self.context.surface_precipitation.*;
            direct_precipitation.water_to_matrix_m3_per_h = self.base_water_to_matrix_m3_per_h;
            direct_precipitation.water_to_macropore_m3_per_h = self.base_water_to_macropore_m3_per_h;
            try ecosys.surface_precipitation.bindSoilHeatIngress(
                &direct_precipitation,
                self.context.grid,
                self.context.soil_hourly_workspace.cell_heat_source_megajoules,
                1,
                self.context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            );
            if (!builtin.is_test and self.context.executed_weather_hours.* >= 2531 and self.context.executed_weather_hours.* < 2534) {
                const grid = self.context.grid;
                std.log.info("THERMAL_INGRESS stage=after_forcing hour={d} dt_hours={e} temperature_k={e} matrix_water_m3={e} macro_water_m3={e} vapor_m3={e} source_rate={e}", .{ self.context.executed_weather_hours.* + 1, time_step_hours, grid.soil_temperature_k[0], grid.matrix_liquid_water_m3[0], grid.macropore_liquid_water_m3[0], grid.water_vapor_volume_m3[0], self.context.soil_hourly_workspace.cell_heat_source_megajoules[0] });
            }
            if (profile_active) self.temporary_profile_prepare_forcing_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            for (0..self.context.grid.cell_count) |cell| {
                if (self.surface_temperature_work.atmospheric_vapor_water_change_m3[cell] != 0 or
                    self.surface_temperature_work.internal_vapor_water_change_m3[cell] != 0 or
                    self.surface_temperature_work.liquid_water_change_m3[cell] != 0 or
                    self.surface_temperature_work.ice_water_equivalent_change_m3[cell] != 0)
                    try self.incrementWaterStorageUpdate(.{ .kind = .surface, .cell = cell }, 1);
                if (self.forcing.litter_ingress_step_m3[cell] != 0)
                    try self.incrementWaterStorageUpdate(.{ .kind = .surface, .cell = cell }, 1);
                if (self.context.surface_precipitation.water_to_matrix_m3_per_h[cell] != 0 or
                    self.context.surface_precipitation.water_to_macropore_m3_per_h[cell] != 0)
                {
                    try self.incrementWaterStorageUpdate(.{
                        .kind = .soil_layer,
                        .cell = cell,
                        .layer = 0,
                    }, 1);
                }
            }
            try ecosys.surface_precipitation.state_updateLitterHeatIngress(
                self.context.surface_precipitation,
                self.base_water_to_litter_m3_per_h,
                .{
                    .heat_capacity_megajoules_per_k = self.context.surface_heat_capacity_megajoules_per_k,
                    .surface_temperature_k = self.context.grid.surface_temperature_k,
                    .gas_temperature_k = self.context.litter_gas_transport.temperature_k,
                    .accepted_temperature_k = self.surface_temperature_total.equilibrium_temperature_k,
                },
                time_step_hours,
                self.context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
            );
            try self.applySnowDischargeRecipientHeat(time_step_hours);
            try diagnostics.traceSurfaceFrontier(self.context, "after_recipient_heat", time_step_hours);
        }

        noinline fn acceptSubstep(raw: *anyopaque, time_step_hours: f64) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            try diagnostics.traceSurfaceFrontier(self.context, "accept_entry", time_step_hours);
            const profile_active = !builtin.is_test and
                self.context.executed_weather_hours.* >= 48 and
                self.context.executed_weather_hours.* < 56;
            const profile_start = std.Io.Clock.now(.boot, self.context.io);
            defer {
                if (profile_active) self.temporary_profile_accept_ns +=
                    profile_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            }
            // The Richards/vapor/phase carrier is accepted before snow/direct
            // solutes are deposited. Rebase existing soil inventory first so
            // those new extensive inputs are divided by the carrier on which
            // they actually arrive, never by the prior M-entry volume.
            try self.entry_topsoil_chemistry.restoreAndDisarm(
                self.context.grid,
                self.context.soil_chemistry,
            );
            var profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceAcceptedSoilChemistryCarrier();
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659) try diagnostics.logPhosphorusRepresentation(self.context, "accept_after_soil_chemistry_carrier");
            if (profile_active) self.temporary_profile_accept_carrier_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.captureSnowWaterStorage();
            var disappearance = try self.armSnowDisappearance();
            try diagnostics.traceSurfaceFrontier(self.context, "after_disappearance_arm", time_step_hours);
            try self.incrementChangedSnowWaterStorageUpdates();
            defer disappearance.deinit();
            try self.advanceSnowDrift(time_step_hours);
            try self.consumeSnowDisappearance(&disappearance);
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659) try diagnostics.logPhosphorusRepresentation(self.context, "accept_after_snow_disappearance");
            try diagnostics.traceSurfaceFrontier(self.context, "after_disappearance_consume", time_step_hours);
            try self.applyAcceptedSurfaceDischarge(time_step_hours);
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659) try diagnostics.logPhosphorusRepresentation(self.context, "accept_after_surface_discharge");
            try diagnostics.traceSurfaceFrontier(self.context, "after_discharge", time_step_hours);
            if (profile_active) self.temporary_profile_accept_snow_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            // WATSUB owns FLWR/HFLWR and publishes physical storage before
            // biology. TRNSFR later consumes the exact accepted FLWR without
            // moving water or heat a second time.
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.transport_replay.stageAcceptedFluxes();
            if (profile_active) self.temporary_profile_accept_transport_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceAcceptedLitterSoilPhysical(time_step_hours);
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659) try diagnostics.logPhosphorusRepresentation(self.context, "accept_after_litter_soil_physical");
            try diagnostics.traceSurfaceFrontier(self.context, "after_litter_soil", time_step_hours);
            if (profile_active) self.temporary_profile_accept_litter_soil_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            self.transport_replay.acceptSubstep(self.litter_soil_water_flux_m3);
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceSnowCompactionAndRelayering(time_step_hours);
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659) try diagnostics.logPhosphorusRepresentation(self.context, "accept_after_snow_compaction");
            try diagnostics.traceSurfaceFrontier(self.context, "after_snow_compaction", time_step_hours);
            if (profile_active) self.temporary_profile_accept_compaction_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            // Soil arithmetic provenance is certified by the two local water
            // closure producers and published only after the full stage accepts.
        }

        noinline fn acceptPhaseDisplacement(
            raw: *anyopaque,
            displacement_by_layer: []const ecosys.soil_water_heat_step.PhaseDisplacement,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            try self.advanceAcceptedPhaseDisplacement(displacement_by_layer);
        }

        fn bindAcceptedUpwardPhaseFace(
            self: *Self,
            shallower: usize,
            deeper: usize,
            upward: ecosys.soil_water_heat_step.PhaseDisplacement,
        ) !void {
            try validatePhaseDisplacement(upward);
            if (upward.matrix_liquid_water_m3 == 0 and
                upward.macropore_liquid_water_m3 == 0 and
                upward.advective_enthalpy_megajoules == 0) return;
            const faces = self.context.soil_transport_faces;
            for (faces.direction_axis, faces.active_by_face, faces.micropore_faces, 0..) |axis, active, face, slot| {
                if (!active or axis != 2 or face.first_cell != shallower or face.second_cell != deeper) continue;
                const matrix_flux = -upward.matrix_liquid_water_m3;
                const macro_flux = -upward.macropore_liquid_water_m3;
                const heat_flux = -upward.advective_enthalpy_megajoules;
                faces.micropore_faces[slot].water_flux_m3_per_step = try checkedAddFiniteValue(faces.micropore_faces[slot].water_flux_m3_per_step, matrix_flux);
                faces.macropore_faces[slot].water_flux_m3_per_step = try checkedAddFiniteValue(faces.macropore_faces[slot].water_flux_m3_per_step, macro_flux);
                faces.micropore_water_flux_m3_per_step[slot] = try checkedAddFiniteValue(faces.micropore_water_flux_m3_per_step[slot], matrix_flux);
                faces.macropore_water_flux_m3_per_step[slot] = try checkedAddFiniteValue(faces.macropore_water_flux_m3_per_step[slot], macro_flux);
                faces.heat_flux_megajoules_per_step[slot] = try checkedAddFiniteValue(faces.heat_flux_megajoules_per_step[slot], heat_flux);
                const state_index = shallower * 3 + 2;
                self.context.transport_hydrology.micropore_face_flux_m3_per_step[state_index] = try checkedAddFiniteValue(self.context.transport_hydrology.micropore_face_flux_m3_per_step[state_index], matrix_flux);
                self.context.transport_hydrology.macropore_face_flux_m3_per_step[state_index] = try checkedAddFiniteValue(self.context.transport_hydrology.macropore_face_flux_m3_per_step[state_index], macro_flux);
                self.context.transport_hydrology.heat_face_flux_megajoules_per_step[state_index] = try checkedAddFiniteValue(self.context.transport_hydrology.heat_face_flux_megajoules_per_step[state_index], heat_flux);
                return;
            }
            return error.MissingAcceptedSoilPhaseVerticalRecipientFace;
        }

        /// WATSUB 4891--4908 and 4977--5012 route expansion water upward,
        /// carrying donor-temperature enthalpy. Traverse the live DLYRM face
        /// topology bottom-to-top so a saturated recipient propagates its new
        /// overfill instead of hiding it in a zero-air clamp. The final carry
        /// enters the canonical litter/pond carrier (WATSUB 3677--3710).
        noinline fn advanceAcceptedPhaseDisplacement(
            self: *Self,
            displacement_by_layer: []const ecosys.soil_water_heat_step.PhaseDisplacement,
        ) !void {
            const context = self.context;
            if (displacement_by_layer.len != context.grid.layer_count or
                context.soil_transport_faces.active_by_layer.len != context.grid.layer_count or
                self.litter_soil_water_flux_m3.len != context.grid.cell_count)
                return error.AcceptedSoilPhaseDisplacementDimensionMismatch;
            @memset(self.litter_soil_water_flux_m3, 0);
            for (displacement_by_layer) |value| try validatePhaseDisplacement(value);
            const ice_density = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3;
            const liquid_heat_capacity = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k;
            const ice_heat_capacity_per_water_equivalent = try ecosys.ice_units.heatCapacityPerWaterEquivalentM3K(
                context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                ice_density,
            );
            for (0..context.grid.cell_count) |cell| {
                var deepest_local: ?usize = null;
                var local = context.grid.active_soil_layer_count[cell];
                while (local > 0) {
                    local -= 1;
                    const layer = try context.grid.layerIndex(cell, local);
                    if (context.soil_transport_faces.active_by_layer[layer]) {
                        deepest_local = local;
                        break;
                    }
                    const inactive = displacement_by_layer[layer];
                    if (inactive.matrix_liquid_water_m3 != 0 or inactive.macropore_liquid_water_m3 != 0 or inactive.advective_enthalpy_megajoules != 0)
                        return error.AcceptedSoilPhaseDisplacementFromInactiveLayer;
                }
                const deepest = deepest_local orelse continue;
                var source_local = deepest;
                var source = try context.grid.layerIndex(cell, source_local);
                var carry = displacement_by_layer[source];
                while (source_local > 0) {
                    var shallower_local = source_local;
                    var found = false;
                    while (shallower_local > 0) {
                        shallower_local -= 1;
                        const candidate = try context.grid.layerIndex(cell, shallower_local);
                        if (context.soil_transport_faces.active_by_layer[candidate]) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) break;
                    const shallower = try context.grid.layerIndex(cell, shallower_local);
                    const old_capacity = context.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[shallower] *
                        context.soil_solver_properties.layer_volume_m3[shallower] +
                        liquid_heat_capacity *
                            (context.grid.matrix_liquid_water_m3[shallower] +
                                context.grid.macropore_liquid_water_m3[shallower] +
                                context.grid.water_vapor_volume_m3[shallower]) +
                        ice_heat_capacity_per_water_equivalent *
                            (context.grid.matrix_ice_water_m3[shallower] + context.grid.macropore_ice_water_m3[shallower]);
                    const routed = try routePhaseDisplacementIntoSoilRecipient(.{
                        .matrix_liquid_water_m3 = context.grid.matrix_liquid_water_m3[shallower],
                        .matrix_ice_water_equivalent_m3 = context.grid.matrix_ice_water_m3[shallower],
                        .macropore_liquid_water_m3 = context.grid.macropore_liquid_water_m3[shallower],
                        .macropore_ice_water_equivalent_m3 = context.grid.macropore_ice_water_m3[shallower],
                        .temperature_k = context.grid.soil_temperature_k[shallower],
                        .heat_capacity_megajoules_per_k = old_capacity,
                    }, carry, displacement_by_layer[shallower], context.grid.matrix_pore_capacity_m3[shallower], context.grid.macropore_pore_capacity_m3[shallower], ice_density, liquid_heat_capacity);
                    const recipient_water_changed =
                        routed.state.matrix_liquid_water_m3 != context.grid.matrix_liquid_water_m3[shallower] or
                        routed.state.macropore_liquid_water_m3 != context.grid.macropore_liquid_water_m3[shallower];
                    try self.bindAcceptedUpwardPhaseFace(shallower, source, carry);
                    context.grid.matrix_liquid_water_m3[shallower] = routed.state.matrix_liquid_water_m3;
                    context.grid.macropore_liquid_water_m3[shallower] = routed.state.macropore_liquid_water_m3;
                    context.grid.liquid_water_m3[shallower] = routed.state.matrix_liquid_water_m3 + routed.state.macropore_liquid_water_m3;
                    context.grid.soil_temperature_k[shallower] = routed.state.temperature_k;
                    context.soil_hourly_workspace.heat_capacity_megajoules_per_k[shallower] = routed.state.heat_capacity_megajoules_per_k;
                    context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[shallower] = routed.state.heat_capacity_megajoules_per_k /
                        context.soil_solver_properties.layer_volume_m3[shallower];
                    context.grid.matrix_air_volume_m3[shallower] = @max(0, context.grid.matrix_pore_capacity_m3[shallower] - routed.state.matrix_liquid_water_m3 - routed.state.matrix_ice_water_equivalent_m3 / ice_density);
                    context.grid.macropore_air_volume_m3[shallower] = @max(0, context.grid.macropore_pore_capacity_m3[shallower] - routed.state.macropore_liquid_water_m3 - routed.state.macropore_ice_water_equivalent_m3 / ice_density);
                    context.grid.air_volume_m3[shallower] = context.grid.matrix_air_volume_m3[shallower] + context.grid.macropore_air_volume_m3[shallower];
                    const matrix_parameters = context.soil_solver_properties.mualem_van_genuchten_parameters[shallower];
                    context.grid.matric_potential_megapascal[shallower] = try matrix_parameters.pressureHeadAtWaterContent(std.math.clamp(
                        routed.state.matrix_liquid_water_m3 / context.soil_solver_properties.matrix_bulk_volume_m3[shallower],
                        matrix_parameters.residual_water_content_m3_per_m3,
                        matrix_parameters.saturated_water_content_m3_per_m3,
                    )) * context.runscript.soil_process_parameters.gravitational_water_potential_mpa_per_m;
                    if (recipient_water_changed) try self.incrementWaterStorageUpdate(.{
                        .kind = .soil_layer,
                        .cell = cell,
                        .layer = shallower_local,
                    }, 1);
                    carry = routed.upward;
                    source_local = shallower_local;
                    source = shallower;
                }
                const old_surface_water = context.surface_precipitation.litter_water_m3[cell];
                // ISSUE-089. Capture the surface enthalpy BEFORE the routing
                // overwrites its owners, so the transfer can be declared to the
                // layer-local ledger below. `run-017` measured this leg moving
                // 3.15e-3 m3 and 4.275 MJ from soil layer 0 into the surface at
                // hour 3,253 with nothing booked on either side, which is what
                // `HourlyLayerConservationFailure` was reporting.
                const old_surface_temperature_k = context.grid.surface_temperature_k[cell];
                const old_surface_capacity = context.surface_heat_capacity_megajoules_per_k[cell];
                const surface = try routePhaseDisplacementIntoSurfaceRecipient(.{
                    .liquid_water_m3 = old_surface_water,
                    .ice_water_equivalent_m3 = context.surface_litter_ice_m3[cell],
                    .temperature_k = old_surface_temperature_k,
                    .heat_capacity_megajoules_per_k = old_surface_capacity,
                }, carry, liquid_heat_capacity);
                try ecosys.surface_litter_chemistry_carrier_rebase.validateCellForAcceptedWater(
                    context.surface_litter_chemistry,
                    cell,
                    old_surface_water,
                    surface.liquid_water_m3,
                );
                try self.previewAndAccumulateSurfaceWaterRebase(
                    cell,
                    old_surface_water,
                    surface.liquid_water_m3,
                );
                ecosys.surface_litter_chemistry_carrier_rebase.rebaseCellForAcceptedWater(
                    context.surface_litter_chemistry,
                    cell,
                    old_surface_water,
                    surface.liquid_water_m3,
                ) catch unreachable;
                context.surface_precipitation.litter_water_m3[cell] = surface.liquid_water_m3;
                context.grid.surface_temperature_k[cell] = surface.temperature_k;
                context.surface_heat_capacity_megajoules_per_k[cell] = surface.heat_capacity_megajoules_per_k;
                context.surface_litter_geometry.air_volume_m3[cell] = @max(0, context.surface_litter_geometry.pore_volume_m3[cell] - surface.liquid_water_m3 - surface.ice_water_equivalent_m3 / ice_density);
                context.surface_solute_transport.carrier_volume_m3[cell] = surface.liquid_water_m3;
                self.litter_soil_water_flux_m3[cell] = -(carry.matrix_liquid_water_m3 + carry.macropore_liquid_water_m3);
                // ISSUE-089: declare this leg to the layer-local ledger. It is
                // the `FLQR` analogue (`watsub.f:3683-3685`) for the accepted
                // displacement path, and it is genuinely conservative -- the
                // audit's own heat residuals for the two scopes were equal and
                // opposite to ~11 significant figures -- so the only thing
                // missing was the declaration. The paired litter--topsoil
                // producer at the transport replay already books its own
                // transfers this way via `accumulateLitterSoilLocalTransfer`,
                // which is why that path passes its audit and this one did not.
                //
                // Sign convention matches that helper: positive is surface ->
                // topsoil, so a displacement arriving AT the surface is
                // negative. Water is the liquid the carry delivered; heat is the
                // surface's exact enthalpy change, which equals what the soil
                // side gave up because `routePhaseDisplacementIntoSurfaceRecipient`
                // conserves it.
                const displaced_water_m3 = carry.matrix_liquid_water_m3 + carry.macropore_liquid_water_m3;
                const surface_heat_gain_megajoules = surface.heat_capacity_megajoules_per_k * surface.temperature_k -
                    old_surface_capacity * old_surface_temperature_k;
                if (displaced_water_m3 != 0) try self.accumulateLitterSoilLocalTransfer(
                    cell,
                    -displaced_water_m3,
                    .{ .water_m3 = @abs(displaced_water_m3) },
                );
                if (surface_heat_gain_megajoules != 0) try self.accumulateLitterSoilLocalTransfer(
                    cell,
                    -surface_heat_gain_megajoules,
                    .{ .heat_megajoules = @abs(surface_heat_gain_megajoules) },
                );
                if (surface.liquid_water_m3 != old_surface_water)
                    try self.incrementWaterStorageUpdate(.{ .kind = .surface, .cell = cell }, 1);
            }
            @memcpy(context.transport_hydrology.micropore_water_volume_m3, context.grid.matrix_liquid_water_m3);
            @memcpy(context.transport_hydrology.macropore_water_volume_m3, context.grid.macropore_liquid_water_m3);
            @memcpy(context.transport_hydrology.matrix_air_volume_m3, context.grid.matrix_air_volume_m3);
            @memcpy(context.transport_hydrology.macropore_air_volume_m3, context.grid.macropore_air_volume_m3);
            @memcpy(context.transport_hydrology.air_volume_m3, context.grid.air_volume_m3);
        }

        noinline fn advanceAcceptedSoilChemistryCarrier(self: *Self) !void {
            const context = self.context;
            const pending_snapshot = try self.transport_replay.pendingSnapshot();
            const entry_matrix_water_m3 =
                try self.transport_replay.gridCarrierFromSnapshot(pending_snapshot, 0);
            // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. `RoundoffAllowance`
            // rejects negative contributions and sums with `addRoundUp`, so what is
            // booked here is an upper BOUND on the rebase's roundoff magnitude, not
            // a signed correction. `publishChemistryRebaseRoundoff` then books it as
            // ledger activity, so the conservation audit only accepts the rebase's
            // mass change up to that bound.
            //
            // That makes the defect directly testable with no algebra: measure the
            // ACTUAL signed ledger change across the rebase and compare it with the
            // bound. If |actual| > bound, the bound does not bound, and raising it
            // to cover a real numerical effect is a correctness fix rather than a
            // weakened tolerance.
            const trace_allowance = context.executed_weather_hours.* >= 2656 and
                context.executed_weather_hours.* < 2659;
            // Evaluate the invariant against the carrier each concentration is
            // actually valid on -- the ENTRY carrier before, the live carrier after.
            // Reading the ledger instead measures the stale-integral correction
            // (7.81e-2 g P), which is legitimate and not the roundoff at all; that
            // mis-designed comparison is what made the bound look 12 orders wrong.
            var invariant_before_g: f64 = 0;
            if (trace_allowance) for (0..context.grid.layer_count) |layer| {
                invariant_before_g += try diagnostics.waterScaledPhosphateForLayer(
                    context,
                    layer,
                    entry_matrix_water_m3[layer],
                );
            };
            var booked_bound_phosphorus_g: f64 = 0;
            for (0..context.grid.layer_count) |layer| {
                const layer_cell = layer / context.grid.soil_layer_capacity;
                const roundoff = try ecosys.soil_chemistry_water_carrier_rebase.previewLayerRoundoff(
                    context.soil_chemistry,
                    layer,
                    entry_matrix_water_m3[layer],
                    context.grid.matrix_liquid_water_m3[layer],
                    try self.chemistryRebaseInventoryFractions(layer),
                    12.0,
                    context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[layer_cell]),
                );
                booked_bound_phosphorus_g += roundoff.phosphorus_g;
                try self.accumulateChemistryRebaseRoundoff(layer, roundoff);
            }
            // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001 confirmation.
            // This is the rebase; `state_updateHourlyWaterHeatStateGeneration`
            // then moves the carrier again, so C is rebased against one value and
            // integrated against another. Sum-level algebra over-predicted the
            // residual by four orders, so print the PER-LAYER carriers and the
            // booked allowance instead of reasoning about totals.
            if (context.executed_weather_hours.* >= 2656 and context.executed_weather_hours.* < 2659) {
                for (0..@min(3, context.grid.layer_count)) |layer| {
                    const entry = entry_matrix_water_m3[layer];
                    const live = context.grid.matrix_liquid_water_m3[layer];
                    std.log.info(
                        "phosphorus rebase carrier: layer={d} entry_m3={e} live_m3={e} absolute_m3={e} relative={e}",
                        .{ layer, entry, live, live - entry, if (entry != 0) (live - entry) / entry else 0 },
                    );
                }
            }
            for (0..context.grid.layer_count) |layer| {
                // ISSUE-065 DRY_CARRIER_TRACE, see the topsoil_vapor_rebase
                // site (`:731`) for rationale. This is the main per-layer
                // WATSUB commit call site named in issue-065's addendum.
                const dry_carrier_trace_2894 = context.executed_weather_hours.* >= 2888 and
                    context.executed_weather_hours.* < 2896 and layer == 0;
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=watsub_commit hour={d} layer={d} old_water_m3={e} new_water_m3={e} dry_reference_before={e}",
                    .{
                        context.executed_weather_hours.* + 1,
                        layer,
                        entry_matrix_water_m3[layer],
                        context.grid.matrix_liquid_water_m3[layer],
                        context.soil_chemistry.dry_reference_water_m3[layer],
                    },
                );
                ecosys.soil_chemistry_water_carrier_rebase.rebaseLayer(
                    context.soil_chemistry,
                    layer,
                    entry_matrix_water_m3[layer],
                    context.grid.matrix_liquid_water_m3[layer],
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[layer / context.grid.soil_layer_capacity]),
                ) catch unreachable;
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=watsub_commit hour={d} layer={d} dry_reference_after={e}",
                    .{ context.executed_weather_hours.* + 1, layer, context.soil_chemistry.dry_reference_water_m3[layer] },
                );
            }
            if (trace_allowance) {
                var invariant_after_g: f64 = 0;
                for (0..context.grid.layer_count) |layer| {
                    invariant_after_g += try diagnostics.waterScaledPhosphateForLayer(
                        context,
                        layer,
                        context.grid.matrix_liquid_water_m3[layer],
                    );
                }
                const actual_g = invariant_after_g - invariant_before_g;
                std.log.info(
                    "phosphorus rebase invariant: before_g={e} after_g={e} actual_signed_g={e} booked_bound_g={e} bounded={}",
                    .{
                        invariant_before_g,
                        invariant_after_g,
                        actual_g,
                        booked_bound_phosphorus_g,
                        @abs(actual_g) <= booked_bound_phosphorus_g,
                    },
                );
            }
        }

        const SnowBaseConduction = struct {
            litter_megajoules: f64 = 0,
            topsoil_megajoules: f64 = 0,
            total_megajoules: f64 = 0,
        };

        /// WATSUB 1773--1796 (`HFLWS1`) and 1861--1872 plus 2025--2033
        /// (`HFLWSRX`): the two continuous conductive faces the lowest active
        /// snow layer forms against the bare soil surface and the surface
        /// litter. These are independent of the meltwater carrier heat: no
        /// water crosses either face.
        ///
        /// Both limiters are formed here, where the flux is formed, so one
        /// single limited value can be debited from the snowpack and credited
        /// to the recipient. `docs/traceability/surface_soil_conduction_pairing_audit.md`
        /// Finding 2 records why limiting at the consumer instead manufactures
        /// an asymmetry.
        noinline fn acceptedSnowBaseConduction(
            self: *Self,
            cell: usize,
            snow_layer: usize,
            entry: *const ecosys.snow_solute_transport.State,
            time_step_hours: f64,
        ) !SnowBaseConduction {
            const context = self.context;
            const area_m2 = context.canopy_cell_area_m2[cell];
            if (!std.math.isFinite(area_m2) or area_m2 <= 0)
                return error.InvalidSnowBaseConductionCellArea;
            // WATSUB 1425: no base face exists until the snow layer holds more
            // than the activation heat capacity.
            const snow_capacity = entry.heat_capacity_megajoules_per_k[snow_layer];
            const activation_threshold =
                ecosys.snow_solute_transport.activation_heat_capacity_megajoules_per_m2_k *
                entry.horizontal_area_m2[snow_layer];
            if (!(snow_capacity > activation_threshold)) return .{};
            const snow_temperature_k = entry.temperature_k[snow_layer];
            const snow_thickness_m = entry.layer_thickness_m[snow_layer];
            const conduction_parameters = context.runscript.snow_heat_conduction_parameters;
            // WATSUB 1436--1448: the layer's own current density drives the
            // J. Glaciology conductivity, using the same law and the same
            // runtime coefficients as the internal snow faces.
            const snow_conductivity = ecosys.snow_heat_conduction.conductivityMMegajoulesPerHK(
                conduction_parameters,
                ecosys.snow_heat_conduction.effectiveDensityMegagramsPerM3(
                    conduction_parameters,
                    entry.solid_snow_water_equivalent_m3[snow_layer],
                    entry.liquid_water_volume_m3[snow_layer],
                    entry.ice_volume_m3[snow_layer],
                    entry.total_layer_volume_m3[snow_layer],
                    context.runscript.initial_snow_density_megagrams_per_m3,
                ),
            );
            // WATSUB 399: CVRD = 1 - BARE. The two lanes partition the
            // footprint exactly, which is what makes the cover-apportioned
            // equalization bound in `snow_base_thermal_coupling` sum to the
            // pack's own joint equilibrium.
            const litter_cover = context.surface_precipitation.litter_cover_fraction[cell];
            if (!std.math.isFinite(litter_cover) or litter_cover < 0 or litter_cover > 1)
                return error.InvalidSnowBaseConductionCover;
            const bare_cover = 1 - litter_cover;
            const snow_cover = self.surface_snow_cover_fraction[cell];

            var result: SnowBaseConduction = .{};

            // WATSUB 1773--1796: snow to bare soil surface. TCNDS is already
            // owned by `soil/heat/thermal.zig`, which translates WTHET2 and
            // the mineral-soil weights verbatim.
            if (context.grid.active_soil_layer_count[cell] > 0) {
                const top = try context.grid.layerIndex(cell, 0);
                const soil_capacity =
                    context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[top] *
                    context.soil_solver_properties.layer_volume_m3[top];
                const soil = try ecosys.snow_base_thermal_coupling.acceptedInterfaceHeat(.{
                    .snow_temperature_k = snow_temperature_k,
                    .recipient_temperature_k = context.grid.soil_temperature_k[top],
                    .snow_heat_capacity_megajoules_per_k = snow_capacity,
                    .recipient_heat_capacity_megajoules_per_k = soil_capacity,
                    .snow_conductivity_m_megajoules_per_h_k = snow_conductivity,
                    .recipient_conductivity_m_megajoules_per_h_k = context.soil_thermal.thermal_conductivity_m_megajoules_per_h_k[top],
                    .snow_thickness_m = snow_thickness_m,
                    .recipient_thickness_m = context.soil_solver_properties.layer_thickness_m[top],
                    .horizontal_area_m2 = area_m2,
                    .snow_cover_fraction = snow_cover,
                    .recipient_cover_fraction = bare_cover,
                    .time_step_hours = time_step_hours,
                });
                result.topsoil_megajoules = soil.accepted_heat_megajoules;
            }

            // WATSUB 1846--1872 and 2025--2033: snow to surface litter. TCNDR
            // has no other owner in the tree, so the litter conductivity is
            // derived here from the live litter geometry.
            const litter_volume_m3 = context.surface_litter_geometry.expanded_total_volume_m3[cell];
            const litter_capacity = context.surface_heat_capacity_megajoules_per_k[cell];
            if (litter_cover > 0 and litter_volume_m3 > 0 and litter_capacity > 0) {
                const ice_density =
                    context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3;
                const litter_physical_ice_m3 = try ecosys.ice_units.physicalVolumeM3FromWaterEquivalent(
                    context.surface_litter_ice_m3[cell],
                    ice_density,
                );
                const litter_conductivity = try ecosys.snow_base_thermal_coupling.litterConductivityMMegajoulesPerHK(
                    @max(0, context.surface_precipitation.litter_water_m3[cell]) / litter_volume_m3,
                    litter_physical_ice_m3 / litter_volume_m3,
                    @max(0, context.surface_litter_geometry.air_volume_m3[cell]) / litter_volume_m3,
                );
                const litter = try ecosys.snow_base_thermal_coupling.acceptedInterfaceHeat(.{
                    .snow_temperature_k = snow_temperature_k,
                    .recipient_temperature_k = context.grid.surface_temperature_k[cell],
                    .snow_heat_capacity_megajoules_per_k = snow_capacity,
                    .recipient_heat_capacity_megajoules_per_k = litter_capacity,
                    .snow_conductivity_m_megajoules_per_h_k = snow_conductivity,
                    .recipient_conductivity_m_megajoules_per_h_k = litter_conductivity,
                    .snow_thickness_m = snow_thickness_m,
                    // WATSUB DLYRR: the litter layer depth is its expanded
                    // bulk volume spread over the cell footprint.
                    .recipient_thickness_m = litter_volume_m3 / area_m2,
                    .horizontal_area_m2 = area_m2,
                    .snow_cover_fraction = snow_cover,
                    .recipient_cover_fraction = litter_cover,
                    .time_step_hours = time_step_hours,
                });
                result.litter_megajoules = litter.accepted_heat_megajoules;
            }

            result.total_megajoules = try checkedAddFiniteValue(
                result.litter_megajoules,
                result.topsoil_megajoules,
            );
            return result;
        }

        /// Fused WATSUB 1423--2446 snow turn. Melt, vapor, and conduction are
        /// valued from one frozen layer-entry state; their mass moves precede
        /// local equilibrium/phase; incoming face energy is consumed only on
        /// the receiving layer's later turn. The live state is finally
        /// replaced by an independent replay through the atomic source-order
        /// helper, so a late donor failure publishes no partial snow result.
        noinline fn advanceSourceOrderedSnowPhysics(
            self: *Self,
            time_step_hours: f64,
            thermodynamics: ecosys.snow_solute_transport.ThermodynamicParameters,
        ) !void {
            const context = self.context;
            const cells = context.grid.cell_count;
            const capacity = context.snow_transport.layer_capacity;
            const layers = try std.math.mul(usize, cells, capacity);
            var entry = try ecosys.snow_source_order_energy.cloneState(
                self.allocator,
                context.snow_transport,
            );
            defer entry.deinit();
            const steps = try self.allocator.alloc(
                ecosys.snow_source_order_energy.LayerStep,
                layers,
            );
            defer self.allocator.free(steps);
            const pending_heat = try self.allocator.alloc(f64, layers);
            defer self.allocator.free(pending_heat);
            @memset(pending_heat, 0);
            const bottom_by_cell = try self.allocator.alloc(usize, cells);
            defer self.allocator.free(bottom_by_cell);
            @memset(bottom_by_cell, capacity);
            for (0..cells) |cell| for (0..capacity) |local_layer| {
                const layer = cell * capacity + local_layer;
                if (context.snow_transport.active[layer]) bottom_by_cell[cell] = local_layer;
            };

            const route_downward = try self.allocator.alloc(f64, layers);
            defer self.allocator.free(route_downward);
            const route_litter = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(route_litter);
            const route_matrix = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(route_matrix);
            const route_macropore = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(route_macropore);
            const face_solid = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(face_solid);
            const face_liquid = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(face_liquid);
            const face_vapor = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(face_vapor);
            const face_ice = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(face_ice);
            const pre_phase_solid = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(pre_phase_solid);
            const pre_phase_ice = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(pre_phase_ice);
            const equilibrium_raw_heat = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(equilibrium_raw_heat);
            const equilibrium_canonical_heat = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(equilibrium_canonical_heat);
            const source_order_process_heat_by_cell = try self.allocator.alloc(f64, cells);
            defer self.allocator.free(source_order_process_heat_by_cell);
            @memset(source_order_process_heat_by_cell, 0);

            @memset(context.transport_hydrology.snow_downward_water_flux_m3_per_step, 0);
            @memset(context.transport_hydrology.snow_to_litter_water_flux_m3_per_step, 0);
            @memset(context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step, 0);
            @memset(context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step, 0);
            @memset(self.snow_melt_heat_step_megajoules_by_layer, 0);
            @memset(self.snow_discharge_heat_step_megajoules_by_cell, 0);
            @memset(self.snow_surface_transfer_heat_step_megajoules_by_cell, 0);
            @memset(self.snow_topsoil_transfer_heat_step_megajoules_by_cell, 0);
            @memset(self.snow_base_litter_conduction_heat_step_megajoules_by_cell, 0);
            @memset(self.snow_base_topsoil_conduction_heat_step_megajoules_by_cell, 0);
            @memcpy(
                context.transport_hydrology.snow_liquid_water_volume_m3,
                context.snow_transport.liquid_water_volume_m3,
            );
            for (0..cells) |cell| {
                self.snow_solid_input_step_m3[cell] =
                    self.base_water_to_matrix_m3_per_h[cell] * time_step_hours;
                self.snow_liquid_input_step_m3[cell] =
                    self.base_water_to_macropore_m3_per_h[cell] * time_step_hours;
            }
            const solid_reference =
                try ecosys.ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
                    thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k,
                    thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
                    context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
                    thermodynamics.pure_water_melting_temperature_k,
                );
            const ice_capacity_per_water_equivalent_m3_k =
                try ecosys.ice_units.heatCapacityPerWaterEquivalentM3K(
                    thermodynamics.ice_heat_capacity_megajoules_per_m3_k,
                    context.runscript.snow_ice_density_megagrams_per_m3,
                );
            const ice_reference =
                try ecosys.ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
                    ice_capacity_per_water_equivalent_m3_k,
                    thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
                    context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
                    thermodynamics.pure_water_melting_temperature_k,
                );

            for (0..capacity) |local_layer| {
                var face_entry = try ecosys.snow_source_order_energy.cloneState(
                    self.allocator,
                    context.snow_transport,
                );
                defer face_entry.deinit();
                @memcpy(self.snow_face_entry_temperature_k, face_entry.temperature_k);
                try ecosys.snow_melt_water_routing.calculate(.{
                    .cell_count = cells,
                    .layer_capacity = capacity,
                    .active = face_entry.active,
                    .liquid_water_volume_m3 = face_entry.liquid_water_volume_m3,
                    .solid_snow_volume_m3 = face_entry.solid_snow_water_equivalent_m3,
                    .air_filled_volume_m3 = face_entry.air_filled_volume_m3,
                    .total_layer_volume_m3 = face_entry.total_layer_volume_m3,
                    .minimum_air_fraction = context.runscript.snow_vapor_diffusion_parameters.minimum_air_fraction,
                    .litter_cover_fraction = context.surface_precipitation.litter_cover_fraction,
                    .micropore_fraction = context.surface_precipitation.matrix_fraction,
                    .macropore_fraction = context.surface_precipitation.macropore_fraction,
                    .topsoil_micropore_air_capacity_m3 = context.surface_precipitation.matrix_air_capacity_m3,
                    .topsoil_macropore_air_capacity_m3 = context.surface_precipitation.macropore_air_capacity_m3,
                    .other_micropore_water_input_m3 = self.snow_solid_input_step_m3,
                    .other_macropore_water_input_m3 = self.snow_liquid_input_step_m3,
                    .step_fraction = time_step_hours,
                }, .{
                    .downward_water_flux_m3 = route_downward,
                    .litter_water_flux_m3 = route_litter,
                    .soil_micropore_water_flux_m3 = route_matrix,
                    .soil_macropore_water_flux_m3 = route_macropore,
                });
                @memset(self.snow_conduction_heat_step_megajoules_by_layer, 0);
                @memset(self.snow_vapor_diffusion_water_step_m3_by_layer, 0);
                @memset(self.snow_vapor_diffusion_heat_step_megajoules_by_layer, 0);
                if (local_layer + 1 < capacity) {
                    _ = try ecosys.snow_heat_conduction.solve(
                        self.allocator,
                        context.snow_transport,
                        context.runscript.snow_heat_conduction_parameters,
                        .{
                            .physical_time_step_hours = time_step_hours,
                            .full_snow_cover_depth_m = context.runscript.snow_full_cover_depth_m,
                            .snow_cover_fraction_by_cell = self.surface_snow_cover_fraction,
                            .accepted_interface_heat_megajoules = self.snow_conduction_heat_step_megajoules_by_layer,
                            .local_face_index = local_layer,
                        },
                    );
                    _ = try ecosys.snow_vapor_diffusion.solve(
                        self.allocator,
                        context.snow_transport,
                        context.runscript.snow_vapor_diffusion_parameters,
                        .{
                            .physical_time_step_hours = time_step_hours,
                            .donor_availability_fraction = 1,
                            .full_snow_cover_depth_m = context.runscript.snow_full_cover_depth_m,
                            .thermodynamics = thermodynamics,
                            .snow_cover_fraction_by_cell = self.surface_snow_cover_fraction,
                            .accepted_interface_vapor_water_m3 = self.snow_vapor_diffusion_water_step_m3_by_layer,
                            .accepted_interface_heat_megajoules = self.snow_vapor_diffusion_heat_step_megajoules_by_layer,
                            .local_face_index = local_layer,
                            .calculation_temperature_k = self.snow_face_entry_temperature_k,
                        },
                    );
                    try addFiniteSlices(
                        self.snow_conduction_heat_total_megajoules_by_layer,
                        self.snow_conduction_heat_step_megajoules_by_layer,
                    );
                    try addFiniteSlices(
                        self.snow_vapor_diffusion_water_total_m3_by_layer,
                        self.snow_vapor_diffusion_water_step_m3_by_layer,
                    );
                    try addSignedDirectionalSlices(
                        self.snow_vapor_diffusion_water_downward_total_m3_by_layer,
                        self.snow_vapor_diffusion_water_upward_total_m3_by_layer,
                        self.snow_vapor_diffusion_water_step_m3_by_layer,
                    );
                    try addFiniteSlices(
                        self.snow_vapor_diffusion_heat_total_megajoules_by_layer,
                        self.snow_vapor_diffusion_heat_step_megajoules_by_layer,
                    );
                    try addSignedDirectionalSlices(
                        self.snow_vapor_diffusion_heat_downward_total_megajoules_by_layer,
                        self.snow_vapor_diffusion_heat_upward_total_megajoules_by_layer,
                        self.snow_vapor_diffusion_heat_step_megajoules_by_layer,
                    );
                }

                // Vapor has moved mass on the candidate, but neither face is
                // allowed to publish C/T yet. Restore the frozen face-entry
                // capacities and temperatures, then add the accepted melt
                // mass on the same transaction.
                for (0..cells) |cell| {
                    const source = cell * capacity + local_layer;
                    const bottom = bottom_by_cell[cell];
                    const has_lower = bottom < capacity and local_layer < bottom;
                    const is_bottom = bottom < capacity and local_layer == bottom;
                    const liquid_to_lower = if (has_lower) route_downward[source + 1] else 0;
                    const discharge = if (is_bottom)
                        route_litter[cell] + route_matrix[cell] + route_macropore[cell]
                    else
                        0;
                    context.transport_hydrology.snow_liquid_water_volume_m3[source] =
                        face_entry.liquid_water_volume_m3[source];
                    if (has_lower) {
                        context.transport_hydrology.snow_downward_water_flux_m3_per_step[source + 1] =
                            liquid_to_lower;
                        context.snow_transport.liquid_water_volume_m3[source] -= liquid_to_lower;
                        context.snow_transport.liquid_water_volume_m3[source + 1] += liquid_to_lower;
                        context.snow_transport.temperature_k[source + 1] = face_entry.temperature_k[source + 1];
                        context.snow_transport.heat_capacity_megajoules_per_k[source + 1] =
                            face_entry.heat_capacity_megajoules_per_k[source + 1];
                    } else if (is_bottom) {
                        context.transport_hydrology.snow_to_litter_water_flux_m3_per_step[cell] = route_litter[cell];
                        context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step[cell] = route_matrix[cell];
                        context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step[cell] = route_macropore[cell];
                        context.snow_transport.liquid_water_volume_m3[source] -= discharge;
                    }
                    context.snow_transport.temperature_k[source] = face_entry.temperature_k[source];
                    context.snow_transport.heat_capacity_megajoules_per_k[source] =
                        face_entry.heat_capacity_megajoules_per_k[source];
                    if (!std.math.isFinite(context.snow_transport.liquid_water_volume_m3[source]) or
                        context.snow_transport.liquid_water_volume_m3[source] < 0)
                        return error.SnowSourceOrderMeltOverdraw;
                }
                context.snow_transport.refreshAllGeometry();
                @memset(equilibrium_raw_heat, 0);
                @memset(equilibrium_canonical_heat, 0);
                for (0..cells) |cell| {
                    const source = cell * capacity + local_layer;
                    face_solid[cell] = context.snow_transport.solid_snow_water_equivalent_m3[source];
                    face_liquid[cell] = context.snow_transport.liquid_water_volume_m3[source];
                    face_vapor[cell] = context.snow_transport.vapor_water_equivalent_m3[source];
                    face_ice[cell] = context.snow_transport.ice_volume_m3[source];
                    const threshold = ecosys.snow_solute_transport.activation_heat_capacity_megajoules_per_m2_k *
                        context.snow_transport.horizontal_area_m2[source];
                    if (local_layer > 0 and
                        face_entry.heat_capacity_megajoules_per_k[source] > threshold and
                        context.snow_transport.air_filled_volume_m3[source] > 0)
                    {
                        const transfer = try ecosys.snow_vapor_equilibrium.explicitTransfer(
                            face_solid[cell],
                            face_liquid[cell],
                            face_vapor[cell],
                            context.snow_transport.air_filled_volume_m3[source],
                            face_entry.temperature_k[source],
                            context.runscript.snow_vapor_parameters,
                            1,
                        );
                        context.snow_transport.solid_snow_water_equivalent_m3[source] += transfer.solid_change_m3;
                        context.snow_transport.liquid_water_volume_m3[source] += transfer.liquid_change_m3;
                        context.snow_transport.vapor_water_equivalent_m3[source] += transfer.vapor_change_m3;
                        equilibrium_raw_heat[cell] =
                            context.runscript.snow_vapor_parameters.liquid_evaporation_latent_heat_megajoules_per_m3 * transfer.liquid_change_m3 +
                            context.runscript.snow_vapor_parameters.snow_sublimation_latent_heat_megajoules_per_m3 * transfer.solid_change_m3;
                        equilibrium_canonical_heat[cell] = equilibrium_raw_heat[cell] +
                            solid_reference * transfer.solid_change_m3;
                    }
                    pre_phase_solid[cell] = context.snow_transport.solid_snow_water_equivalent_m3[source];
                    pre_phase_ice[cell] = context.snow_transport.ice_volume_m3[source];
                    context.snow_transport.heat_capacity_megajoules_per_k[source] =
                        thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * context.snow_transport.solid_snow_water_equivalent_m3[source] +
                        thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                            (context.snow_transport.liquid_water_volume_m3[source] + context.snow_transport.vapor_water_equivalent_m3[source]) +
                        thermodynamics.ice_heat_capacity_megajoules_per_m3_k * context.snow_transport.ice_volume_m3[source];
                    context.snow_transport.temperature_k[source] = face_entry.temperature_k[source];
                }
                context.snow_transport.refreshAllGeometry();
                var phase_report = try ecosys.snow_phase_change.solve(
                    self.allocator,
                    context.snow_transport,
                    .{
                        .physical_rate_time_step_hours = time_step_hours,
                        .donor_availability_fraction = 1,
                        .ice_density_megagrams_per_m3 = context.runscript.snow_ice_density_megagrams_per_m3,
                        .latent_heat_of_fusion_megajoules_per_m3 = context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
                        .solid_snow_heat_capacity_megajoules_per_m3_k = thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k,
                        .liquid_water_heat_capacity_megajoules_per_m3_k = thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
                        .ice_heat_capacity_megajoules_per_m3_k = thermodynamics.ice_heat_capacity_megajoules_per_m3_k,
                        .pure_water_melting_temperature_k = thermodynamics.pure_water_melting_temperature_k,
                        .damping_divisor = context.runscript.snow_phase_damping_divisor,
                        .absolute_temperature_tolerance_k = context.config.nonlinear_tolerance.temperature_k,
                        .relative_tolerance = context.config.nonlinear_tolerance.relative,
                        .energy_conservation_absolute_tolerance_megajoules_per_m2 = context.config.mass_balance_absolute_tolerance.heat_megajoules_m2,
                        .energy_conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                        .picard_relaxation = context.config.picard_relaxation,
                        .max_iterations = context.iteration_limits.snowpack_max_iterations,
                        .local_layer_index = local_layer,
                    },
                );
                defer phase_report.deinit(self.allocator);
                try addFiniteSlices(
                    self.snow_phase_heat_total_megajoules_by_cell,
                    phase_report.sensible_energy_change_megajoules_by_cell,
                );
                self.snow_phase_heat_total_megajoules = try checkedAddFiniteValue(
                    self.snow_phase_heat_total_megajoules,
                    phase_report.sensible_energy_change_megajoules,
                );

                for (0..cells) |cell| {
                    const source = cell * capacity + local_layer;
                    const bottom = bottom_by_cell[cell];
                    const has_lower = bottom < capacity and local_layer < bottom;
                    const is_bottom = bottom < capacity and local_layer == bottom;
                    const destination = if (has_lower) source + 1 else source;
                    const liquid_to_lower = if (has_lower)
                        context.transport_hydrology.snow_downward_water_flux_m3_per_step[destination]
                    else
                        0;
                    const litter_discharge = if (is_bottom)
                        context.transport_hydrology.snow_to_litter_water_flux_m3_per_step[cell]
                    else
                        0;
                    const topsoil_discharge = if (is_bottom)
                        try checkedAddFiniteValue(
                            context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step[cell],
                            context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step[cell],
                        )
                    else
                        0;
                    const discharge = try checkedAddFiniteValue(
                        litter_discharge,
                        topsoil_discharge,
                    );
                    const melt_heat = thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                        face_entry.temperature_k[source] * liquid_to_lower;
                    const discharge_heat_split = if (is_bottom)
                        try ecosys.snow_surface_transfer_heat.acceptedRecipientHeatSplit(
                            litter_discharge,
                            topsoil_discharge,
                            face_entry.temperature_k[source],
                            thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
                        )
                    else
                        ecosys.snow_surface_transfer_heat.RecipientHeatSplit{
                            .litter_megajoules = 0,
                            .topsoil_megajoules = 0,
                            .total_megajoules = 0,
                        };
                    const discharge_heat = discharge_heat_split.total_megajoules;
                    // WATSUB 1773--1796 and 2025--2033. Valued from the same
                    // frozen layer-entry temperature and capacity as every
                    // other flux on this turn, so the accepted schedule stays
                    // replayable.
                    const base_conduction = if (is_bottom)
                        try self.acceptedSnowBaseConduction(cell, source, &face_entry, time_step_hours)
                    else
                        SnowBaseConduction{};
                    if (has_lower) self.snow_melt_heat_step_megajoules_by_layer[destination] = melt_heat;
                    if (is_bottom) {
                        self.snow_discharge_heat_step_megajoules_by_cell[cell] = discharge_heat;
                        self.snow_surface_transfer_heat_step_megajoules_by_cell[cell] =
                            discharge_heat_split.litter_megajoules;
                        self.snow_topsoil_transfer_heat_step_megajoules_by_cell[cell] =
                            discharge_heat_split.topsoil_megajoules;
                        self.snow_base_litter_conduction_heat_step_megajoules_by_cell[cell] =
                            base_conduction.litter_megajoules;
                        self.snow_base_topsoil_conduction_heat_step_megajoules_by_cell[cell] =
                            base_conduction.topsoil_megajoules;
                        self.snow_base_litter_conduction_heat_total_megajoules_by_source_layer[source] =
                            try checkedAddFiniteValue(
                                self.snow_base_litter_conduction_heat_total_megajoules_by_source_layer[source],
                                base_conduction.litter_megajoules,
                            );
                        self.snow_base_topsoil_conduction_heat_total_megajoules_by_source_layer[source] =
                            try checkedAddFiniteValue(
                                self.snow_base_topsoil_conduction_heat_total_megajoules_by_source_layer[source],
                                base_conduction.topsoil_megajoules,
                            );
                    }
                    const signed_face_heat = if (has_lower)
                        melt_heat +
                            self.snow_conduction_heat_step_megajoules_by_layer[destination] +
                            self.snow_vapor_diffusion_heat_step_megajoules_by_layer[destination]
                    else
                        0;
                    // The phase solver conserves the canonical census by
                    // changing sensible storage by the negative frozen-state
                    // reference change. Replaying only L*dW double-counts
                    // latent heat and omits the (Cl-Cf)*Tm carrier rebase.
                    const phase_sensible_heat = -(solid_reference *
                        (context.snow_transport.solid_snow_water_equivalent_m3[source] -
                            pre_phase_solid[cell]) +
                        ice_reference * context.runscript.snow_ice_density_megagrams_per_m3 *
                            (context.snow_transport.ice_volume_m3[source] -
                                pre_phase_ice[cell]));
                    const local_heat = equilibrium_raw_heat[cell] + phase_sensible_heat;
                    const next_capacity =
                        thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k * context.snow_transport.solid_snow_water_equivalent_m3[source] +
                        thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k *
                            (context.snow_transport.liquid_water_volume_m3[source] + context.snow_transport.vapor_water_equivalent_m3[source]) +
                        thermodynamics.ice_heat_capacity_megajoules_per_m3_k * context.snow_transport.ice_volume_m3[source];
                    const next_energy = face_entry.heat_capacity_megajoules_per_k[source] *
                        face_entry.temperature_k[source] + pending_heat[source] -
                        signed_face_heat - discharge_heat -
                        base_conduction.total_megajoules + local_heat;
                    if (!std.math.isFinite(next_capacity) or next_capacity < 0 or
                        !std.math.isFinite(next_energy) or
                        (next_capacity == 0 and next_energy != 0))
                        return error.InvalidSnowSourceOrderCandidate;
                    if (next_capacity > 0) {
                        context.snow_transport.temperature_k[source] = next_energy / next_capacity;
                        if (!std.math.isFinite(context.snow_transport.temperature_k[source]) or
                            context.snow_transport.temperature_k[source] <= 0)
                            return error.InvalidSnowSourceOrderCandidate;
                    }
                    context.snow_transport.heat_capacity_megajoules_per_k[source] = next_capacity;
                    pending_heat[source] = 0;
                    if (has_lower) pending_heat[destination] = try checkedAddFiniteValue(
                        pending_heat[destination],
                        signed_face_heat,
                    );
                    const step_index = cell * capacity + local_layer;
                    steps[step_index] = .{
                        .cell = cell,
                        .local_layer = local_layer,
                        .has_active_lower = has_lower,
                        .liquid_to_lower_m3 = liquid_to_lower,
                        .vapor_to_lower_m3 = if (has_lower)
                            self.snow_vapor_diffusion_water_step_m3_by_layer[destination]
                        else
                            0,
                        .signed_face_heat_to_lower_megajoules = signed_face_heat,
                        .discharge_water_m3 = discharge,
                        .discharge_heat_megajoules = discharge_heat,
                        .base_conduction_heat_megajoules = base_conduction.total_megajoules,
                        .local_solid_change_m3 = context.snow_transport.solid_snow_water_equivalent_m3[source] - face_solid[cell],
                        .local_liquid_change_m3 = context.snow_transport.liquid_water_volume_m3[source] - face_liquid[cell],
                        .local_vapor_change_m3 = context.snow_transport.vapor_water_equivalent_m3[source] - face_vapor[cell],
                        .local_ice_change_m3 = context.snow_transport.ice_volume_m3[source] - face_ice[cell],
                        .local_process_heat_megajoules = local_heat,
                    };
                    self.snow_vapor_equilibrium_heat_total_megajoules_by_layer[source] =
                        try checkedAddFiniteValue(
                            self.snow_vapor_equilibrium_heat_total_megajoules_by_layer[source],
                            equilibrium_canonical_heat[cell],
                        );
                    self.snow_vapor_heat_total_megajoules_by_cell[cell] = try checkedAddFiniteValue(
                        self.snow_vapor_heat_total_megajoules_by_cell[cell],
                        equilibrium_canonical_heat[cell],
                    );
                    self.snow_vapor_heat_total_megajoules = try checkedAddFiniteValue(
                        self.snow_vapor_heat_total_megajoules,
                        equilibrium_canonical_heat[cell],
                    );
                    source_order_process_heat_by_cell[cell] = try checkedAddFiniteValue(
                        source_order_process_heat_by_cell[cell],
                        equilibrium_canonical_heat[cell],
                    );
                }
                context.snow_transport.refreshAllGeometry();
            }
            for (pending_heat) |heat| if (heat != 0)
                return error.UnconsumedSnowSourceOrderEnergy;
            var replay = try ecosys.snow_source_order_energy.cloneState(self.allocator, &entry);
            defer replay.deinit();
            try ecosys.snow_source_order_energy.apply(
                self.allocator,
                &replay,
                thermodynamics,
                steps,
            );
            inline for (.{
                .{ replay.solid_snow_water_equivalent_m3, context.snow_transport.solid_snow_water_equivalent_m3 },
                .{ replay.liquid_water_volume_m3, context.snow_transport.liquid_water_volume_m3 },
                .{ replay.vapor_water_equivalent_m3, context.snow_transport.vapor_water_equivalent_m3 },
                .{ replay.ice_volume_m3, context.snow_transport.ice_volume_m3 },
                .{ replay.heat_capacity_megajoules_per_k, context.snow_transport.heat_capacity_megajoules_per_k },
                .{ replay.temperature_k, context.snow_transport.temperature_k },
            }) |pair| for (pair[0], pair[1]) |expected, accepted| {
                const scale = @max(1, @max(@abs(expected), @abs(accepted)));
                if (!std.math.isFinite(accepted) or
                    @abs(expected - accepted) > 256 * std.math.floatEps(f64) * scale)
                    return error.SnowSourceOrderReplayMismatch;
            };
            // The fused replay moves liquid, vapor, conduction heat, and
            // donor-temperature carrier heat only between layers.  Its sole
            // cell-boundary heat is bottom discharge; vapor equilibrium is
            // the only canonical local source.  Verify that complete cell
            // balance here, before later snow stages can obscure its owner.
            for (0..cells) |cell| {
                var before_heat: f64 = 0;
                var after_heat: f64 = 0;
                var vapor_water: f64 = 0;
                var vapor_carrier_heat: f64 = 0;
                const first = cell * capacity;
                const end = first + capacity;
                for (first..end) |layer| {
                    before_heat = try checkedAddFiniteValue(
                        before_heat,
                        entry.heat_capacity_megajoules_per_k[layer] *
                            entry.temperature_k[layer] +
                            solid_reference * entry.solid_snow_water_equivalent_m3[layer] +
                            ice_reference * entry.ice_volume_m3[layer] *
                                context.runscript.snow_ice_density_megagrams_per_m3,
                    );
                    after_heat = try checkedAddFiniteValue(
                        after_heat,
                        replay.heat_capacity_megajoules_per_k[layer] *
                            replay.temperature_k[layer] +
                            solid_reference * replay.solid_snow_water_equivalent_m3[layer] +
                            ice_reference * replay.ice_volume_m3[layer] *
                                context.runscript.snow_ice_density_megagrams_per_m3,
                    );
                    vapor_water = try checkedAddFiniteValue(
                        vapor_water,
                        self.snow_vapor_diffusion_water_step_m3_by_layer[layer],
                    );
                    vapor_carrier_heat = try checkedAddFiniteValue(
                        vapor_carrier_heat,
                        self.snow_vapor_diffusion_heat_step_megajoules_by_layer[layer],
                    );
                }
                // WATSUB 2259 removes both the meltwater carrier heat and the
                // two base conduction lanes from the pack.
                const base_conduction_heat = try checkedAddFiniteValue(
                    self.snow_base_litter_conduction_heat_step_megajoules_by_cell[cell],
                    self.snow_base_topsoil_conduction_heat_step_megajoules_by_cell[cell],
                );
                const expected_change = source_order_process_heat_by_cell[cell] -
                    self.snow_discharge_heat_step_megajoules_by_cell[cell] -
                    base_conduction_heat;
                const defect = (after_heat - before_heat) - expected_change;
                const scale = @max(
                    1,
                    @max(
                        @max(@abs(before_heat), @abs(after_heat)),
                        @max(@abs(expected_change), @abs(vapor_carrier_heat)),
                    ),
                );
                const tolerance = context.config.mass_balance_absolute_tolerance.heat_megajoules_m2 *
                    context.canopy_cell_area_m2[cell] +
                    context.config.mass_balance_relative_tolerance * scale +
                    512 * std.math.floatEps(f64) * scale;
                if (vapor_water != 0 and !builtin.is_test) std.log.debug(
                    "source-ordered snow vapor energy: cell={d} vapor_water_m3={e} vapor_carrier_heat_mj={e} before_mj={e} after_mj={e} local_process_mj={e} discharge_mj={e} defect_mj={e} tolerance_mj={e}",
                    .{ cell, vapor_water, vapor_carrier_heat, before_heat, after_heat, source_order_process_heat_by_cell[cell], self.snow_discharge_heat_step_megajoules_by_cell[cell], defect, tolerance },
                );
                if (!std.math.isFinite(defect) or !std.math.isFinite(tolerance) or
                    @abs(defect) > tolerance)
                {
                    if (!builtin.is_test) std.log.err(
                        "source-ordered snow energy failure: cell={d} before_mj={e} after_mj={e} local_process_mj={e} discharge_mj={e} vapor_water_m3={e} vapor_carrier_heat_mj={e} defect_mj={e} tolerance_mj={e}",
                        .{ cell, before_heat, after_heat, source_order_process_heat_by_cell[cell], self.snow_discharge_heat_step_megajoules_by_cell[cell], vapor_water, vapor_carrier_heat, defect, tolerance },
                    );
                    return error.SnowSourceOrderEnergyConservationFailure;
                }
            }
            try ecosys.snow_source_order_energy.copyState(context.snow_transport, &replay);
        }

        noinline fn advanceSnowBeforeSoil(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            if (!std.math.isFinite(time_step_hours) or time_step_hours <= 0 or time_step_hours > 1)
                return error.InvalidCoupledSnowSubstep;

            for (0..context.grid.cell_count) |cell| {
                self.snow_solid_input_step_m3[cell] = context.surface_precipitation.snow_to_snow_m3_per_h[cell] * time_step_hours;
                self.snow_liquid_input_step_m3[cell] = context.surface_precipitation.rain_to_snow_m3_per_h[cell] * time_step_hours;
                self.snow_heat_input_step_megajoules[cell] = context.surface_precipitation.heat_to_snow_megajoules_per_h[cell] * time_step_hours;
            }
            for (self.snow_atmospheric_input_step_g, context.snow_atmospheric_input_g) |*step, hourly| step.* = hourly * time_step_hours;
            for (self.snow_atmospheric_input_step_salt_mol, context.snow_atmospheric_input_salt_mol) |*step, hourly| step.* = hourly * time_step_hours;

            const thermodynamics: ecosys.snow_solute_transport.ThermodynamicParameters = .{
                .solid_snow_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
                .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                .ice_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                .pure_water_melting_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
            };
            // The exposed litter surface, ground-air storage, and snow boundary
            // exchange are one WATSUB transaction. Recompute in source order
            // on every retry substep; diagnostics remain private until the
            // complete one-hour schedule succeeds. WATSUB 1275--1348 applies
            // the L=1 pore equilibrium and EVAP02 before adding FLQ0S/W/I.
            try self.advanceSurfaceTemperature(time_step_hours);
            try self.captureSnowWaterStorage();
            try self.advanceSnowSurfaceEquilibrium(time_step_hours);
            try self.incrementChangedSnowWaterStorageUpdates();
            try self.captureSnowWaterStorage();
            try self.advanceSnowSurface(time_step_hours);
            try self.incrementChangedSnowWaterStorageUpdates();
            try self.captureSnowWaterStorage();
            try context.snow_transport.state_updateAtmosphericWater(
                self.snow_solid_input_step_m3,
                self.snow_liquid_input_step_m3,
                self.snow_heat_input_step_megajoules,
                context.atmosphere.air_temperature_k,
                context.runscript.initial_snow_density_megagrams_per_m3,
                thermodynamics,
            );
            try self.incrementChangedSnowWaterStorageUpdates();
            try addFiniteSlices(self.snow_solid_input_total_m3, self.snow_solid_input_step_m3);
            try addFiniteSlices(self.snow_liquid_input_total_m3, self.snow_liquid_input_step_m3);
            const solid_frozen_reference_megajoules_per_m3 = try ecosys.ice_units.frozenWaterEquivalentCorrectionFromCarrierSensiblePerM3(
                thermodynamics.solid_snow_heat_capacity_megajoules_per_m3_k,
                thermodynamics.liquid_water_heat_capacity_megajoules_per_m3_k,
                context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
                thermodynamics.pure_water_melting_temperature_k,
            );
            for (0..context.grid.cell_count) |cell| {
                const canonical_heat = self.snow_heat_input_step_megajoules[cell] +
                    solid_frozen_reference_megajoules_per_m3 * self.snow_solid_input_step_m3[cell];
                self.snow_heat_input_total_megajoules[cell] = try checkedAddFiniteValue(
                    self.snow_heat_input_total_megajoules[cell],
                    canonical_heat,
                );
            }
            try addFiniteSlices(self.snow_atmospheric_input_total_g, self.snow_atmospheric_input_step_g);
            try addFiniteSlices(
                self.snow_atmospheric_input_total_salt_mol,
                self.snow_atmospheric_input_step_salt_mol,
            );
            for (self.snow_activity_active_by_layer, context.snow_transport.active) |*ever_active, active|
                ever_active.* = ever_active.* or active;
            try self.captureSnowWaterStorage();
            try self.advanceSourceOrderedSnowPhysics(time_step_hours, thermodynamics);
            try self.incrementChangedSnowWaterStorageUpdates();
            _ = try ecosys.snow_transport_solver.solve(self.allocator, context.snow_transport, .{
                .atmospheric_top_input_g = self.snow_atmospheric_input_step_g,
                .atmospheric_top_input_salt_mol = self.snow_atmospheric_input_step_salt_mol,
                .transport_water_volume_m3 = context.transport_hydrology.snow_liquid_water_volume_m3,
                .water_flux_to_lower_m3 = context.transport_hydrology.snow_downward_water_flux_m3_per_step,
                .litter_water_flux_m3 = context.transport_hydrology.snow_to_litter_water_flux_m3_per_step,
                .soil_micropore_water_flux_m3 = context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step,
                .soil_macropore_water_flux_m3 = context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step,
                .surface_partitions = context.snow_surface_partitions,
                .water_flux_absolute_tolerance_m3 = context.config.physical_tolerance.water_volume_m3,
                .water_flux_relative_tolerance = context.config.physical_tolerance.relative,
                .accepted_downward_g = context.snow_accepted_downward_g,
                .accepted_downward_salt_mol = context.snow_accepted_downward_salt_mol,
            }, .{
                .absolute_tolerance_g_by_species = .{
                    context.config.nonlinear_tolerance.carbon_g,
                    context.config.nonlinear_tolerance.carbon_g,
                    context.config.nonlinear_tolerance.oxygen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.nitrogen_g,
                    context.config.nonlinear_tolerance.phosphorus_g,
                    context.config.nonlinear_tolerance.phosphorus_g,
                    context.config.nonlinear_tolerance.solute_g,
                    context.config.nonlinear_tolerance.solute_g,
                    context.config.nonlinear_tolerance.solute_g,
                    context.config.nonlinear_tolerance.solute_g,
                    context.config.nonlinear_tolerance.solute_g,
                    context.config.nonlinear_tolerance.solute_g,
                    context.config.nonlinear_tolerance.solute_g,
                    context.config.nonlinear_tolerance.solute_g,
                },
                .relative_tolerance = context.config.nonlinear_tolerance.relative,
                .picard_relaxation = context.config.picard_relaxation,
                .max_iterations = context.iteration_limits.snowpack_max_iterations,
            }, context.snow_surface_discharge);
            for (0..context.grid.cell_count) |cell| {
                var bottom_local: ?usize = null;
                for (0..context.snow_transport.layer_capacity) |local_layer| {
                    const layer = cell * context.snow_transport.layer_capacity + local_layer;
                    if (context.snow_transport.active[layer]) bottom_local = local_layer;
                }
                const water = context.transport_hydrology.snow_to_litter_water_flux_m3_per_step[cell] +
                    context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step[cell] +
                    context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step[cell];
                const discharge = context.snow_surface_discharge[cell];
                const bottom = bottom_local orelse {
                    if (water != 0 or self.snow_discharge_heat_step_megajoules_by_cell[cell] != 0)
                        return error.SnowMeltDischargeWithoutActiveLayer;
                    inline for (.{ discharge.litter_g, discharge.soil_nonband_g, discharge.soil_band_g }) |amounts|
                        for (amounts) |amount| if (amount != 0) return error.SnowMeltDischargeWithoutActiveLayer;
                    inline for (.{ discharge.litter_salt_mol, discharge.soil_nonband_salt_mol, discharge.soil_band_salt_mol }) |amounts|
                        for (amounts) |amount| if (amount != 0) return error.SnowMeltDischargeWithoutActiveLayer;
                    continue;
                };
                const layer = cell * context.snow_transport.layer_capacity + bottom;
                self.snow_discharge_water_total_m3_by_source_layer[layer] = try checkedAddFiniteValue(
                    self.snow_discharge_water_total_m3_by_source_layer[layer],
                    water,
                );
                self.snow_discharge_heat_total_megajoules_by_source_layer[layer] = try checkedAddFiniteValue(
                    self.snow_discharge_heat_total_megajoules_by_source_layer[layer],
                    self.snow_discharge_heat_step_megajoules_by_cell[cell],
                );
                for (0..ecosys.snow_solute_transport.species_count) |species| {
                    const amount = discharge.litter_g[species] +
                        discharge.soil_nonband_g[species] + discharge.soil_band_g[species];
                    const index = layer * ecosys.snow_solute_transport.species_count + species;
                    self.snow_discharge_total_g_by_source_layer_species[index] = try checkedAddFiniteValue(
                        self.snow_discharge_total_g_by_source_layer_species[index],
                        amount,
                    );
                }
                for (0..ecosys.snow_solute_transport.salt_species_count) |species| {
                    const amount = discharge.litter_salt_mol[species] +
                        discharge.soil_nonband_salt_mol[species] + discharge.soil_band_salt_mol[species];
                    const index = layer * ecosys.snow_solute_transport.salt_species_count + species;
                    self.snow_discharge_total_salt_mol_by_source_layer_species[index] = try checkedAddFiniteValue(
                        self.snow_discharge_total_salt_mol_by_source_layer_species[index],
                        amount,
                    );
                }
            }
            // WATSUB assigns a reference temperature below VHCPWX even while
            // cold canonical snow remains. Publish the exact C*dT as a signed
            // reference-state process so no remnant mass or energy vanishes
            // behind the activation threshold.
            try ecosys.snow_inactive_temperature.apply(
                self.allocator,
                context.snow_transport,
                context.ground_air.temperature_k,
                self.snow_inactive_reference_heat_step_megajoules_by_layer,
            );

            try addFiniteSlices(self.snow_downward_water_total_m3, context.transport_hydrology.snow_downward_water_flux_m3_per_step);
            try addFiniteSlices(self.snow_to_litter_water_total_m3, context.transport_hydrology.snow_to_litter_water_flux_m3_per_step);
            try addFiniteSlices(self.snow_to_matrix_water_total_m3, context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step);
            try addFiniteSlices(self.snow_to_macropore_water_total_m3, context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step);
            try addFiniteSlices(self.snow_surface_transfer_water_total_m3_by_cell, context.transport_hydrology.snow_to_litter_water_flux_m3_per_step);
            for (self.snow_topsoil_transfer_water_total_m3_by_cell, context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step, context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step) |*total, matrix, macropore|
                total.* = try checkedAddFiniteValue(total.*, try checkedAddFiniteValue(matrix, macropore));
            try addFiniteSlices(self.snow_surface_transfer_heat_total_megajoules_by_cell, self.snow_surface_transfer_heat_step_megajoules_by_cell);
            try addFiniteSlices(self.snow_topsoil_transfer_heat_total_megajoules_by_cell, self.snow_topsoil_transfer_heat_step_megajoules_by_cell);
            try addFiniteSlices(self.snow_accepted_downward_total_g, context.snow_accepted_downward_g);
            try addFiniteSlices(self.snow_accepted_downward_total_salt_mol, context.snow_accepted_downward_salt_mol);
            try addFiniteSlices(self.snow_melt_heat_total_megajoules_by_layer, self.snow_melt_heat_step_megajoules_by_layer);
            try addFiniteSlices(self.snow_discharge_heat_total_megajoules_by_cell, self.snow_discharge_heat_step_megajoules_by_cell);
            try addFiniteSlices(
                self.snow_inactive_reference_heat_total_megajoules_by_layer,
                self.snow_inactive_reference_heat_step_megajoules_by_layer,
            );
            for (self.snow_inactive_reference_heat_step_megajoules_by_layer, 0..) |heat, layer| {
                const cell = layer / context.snow_transport.layer_capacity;
                self.snow_inactive_reference_heat_total_megajoules_by_cell[cell] =
                    try checkedAddFiniteValue(
                        self.snow_inactive_reference_heat_total_megajoules_by_cell[cell],
                        heat,
                    );
                self.snow_inactive_reference_heat_total_megajoules =
                    try checkedAddFiniteValue(
                        self.snow_inactive_reference_heat_total_megajoules,
                        heat,
                    );
            }
            // Forcing consumes hourly rates. Melt is already an accepted
            // substep amount, so divide by dt to make its subsequent `* dt`
            // application exact once.
            for (0..context.grid.cell_count) |cell| {
                context.surface_precipitation.water_to_litter_m3_per_h[cell] = self.base_water_to_litter_m3_per_h[cell] + context.transport_hydrology.snow_to_litter_water_flux_m3_per_step[cell] / time_step_hours;
                context.surface_precipitation.water_to_matrix_m3_per_h[cell] = self.base_water_to_matrix_m3_per_h[cell] + context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step[cell] / time_step_hours;
                context.surface_precipitation.water_to_macropore_m3_per_h[cell] = self.base_water_to_macropore_m3_per_h[cell] + context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step[cell] / time_step_hours;
            }
        }

        noinline fn advanceSnowDrift(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            const molar_mass = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol;
            try self.captureSnowWaterStorage();
            _ = try ecosys.snow_drift_routing.produceAndRoute(
                self.allocator,
                context.snow_transport,
                context.terrain_hydrology.columns,
                context.terrain_hydrology.rows,
                .{
                    .ground_surface_elevation_m = context.terrain_hydrology.current_surface_elevation_m,
                    .wind_speed_m_per_h = context.atmosphere.wind_speed_m_per_h,
                    .east_west_fraction = context.terrain_hydrology.east_west_runoff_fraction,
                    .north_south_fraction = context.terrain_hydrology.north_south_runoff_fraction,
                    .downhill = .{
                        .east = context.terrain_hydrology.runoff_to_east,
                        .west = context.terrain_hydrology.runoff_to_west,
                        .south = context.terrain_hydrology.runoff_to_south,
                        .north = context.terrain_hydrology.runoff_to_north,
                    },
                    .boundaries = .{
                        .east_open = context.surface_erosion.east_boundary_open,
                        .west_open = context.surface_erosion.west_boundary_open,
                        .south_open = context.surface_erosion.south_boundary_open,
                        .north_open = context.surface_erosion.north_boundary_open,
                    },
                    .timestep_h = time_step_hours,
                    .thermodynamics = .{
                        .solid_snow_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
                        .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                        .ice_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                        .pure_water_melting_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
                    },
                    .ice_density_megagrams_per_m3 = context.runscript.snow_ice_density_megagrams_per_m3,
                    .latent_heat_of_fusion_megajoules_per_m3 = context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
                    .elevation_absolute_tolerance_m = context.config.physical_tolerance.length_m,
                    .relative_tolerance = context.config.physical_tolerance.relative,
                    .ion_molar_mass_g_per_mol = .{
                        .aluminum = molar_mass.aluminum,
                        .iron = molar_mass.iron,
                        .calcium = molar_mass.calcium,
                        .magnesium = molar_mass.magnesium,
                        .sodium = molar_mass.sodium,
                        .potassium = molar_mass.potassium,
                        .sulfur = molar_mass.sulfur,
                        .chloride = molar_mass.chloride,
                    },
                    .accepted_fluxes = .{
                        .source_carrier_m3 = self.snow_drift_source_carrier_m3,
                        .total_m3 = self.snow_drift_total_m3,
                        .east_m3 = self.snow_drift_east_m3,
                        .west_m3 = self.snow_drift_west_m3,
                        .south_m3 = self.snow_drift_south_m3,
                        .north_m3 = self.snow_drift_north_m3,
                    },
                    .accumulate_accepted_fluxes = true,
                    .cell_boundary_ledger = &self.snow_drift_cell_ledger,
                    .landscape_boundary_ledger = &self.snow_drift_landscape_ledger,
                },
            );
            try self.incrementChangedSnowWaterStorageUpdates();
            for (self.snow_activity_active_by_layer, context.snow_transport.active) |*ever_active, active|
                ever_active.* = ever_active.* or active;
        }

        /// WATSUB 1609--1633 and 2534--2595 carry the accepted bottom-snow
        /// liquid at donor temperature into the actual litter/topsoil owner.
        /// The source-order snow solve has already removed this enthalpy.  The
        /// precipitation carrier is published immediately before this call;
        /// complete the paired recipient update before the soil nonlinear
        /// solve reads either temperature or heat capacity.
        noinline fn applySnowDischargeRecipientHeat(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            if (!std.math.isFinite(time_step_hours) or time_step_hours <= 0 or time_step_hours > 1)
                return error.InvalidSnowDischargeRecipientTimestep;
            const liquid_heat_capacity = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k;
            if (!std.math.isFinite(liquid_heat_capacity) or liquid_heat_capacity <= 0)
                return error.InvalidSnowDischargeRecipientHeatCapacity;
            for (0..context.grid.cell_count) |cell| {
                const surface_water = context.transport_hydrology.snow_to_litter_water_flux_m3_per_step[cell];
                const topsoil_water = try checkedAddFiniteValue(
                    context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step[cell],
                    context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step[cell],
                );
                const surface_heat = self.snow_surface_transfer_heat_step_megajoules_by_cell[cell];
                const topsoil_heat = self.snow_topsoil_transfer_heat_step_megajoules_by_cell[cell];
                inline for (.{ surface_water, topsoil_water, surface_heat, topsoil_heat }) |value|
                    if (!std.math.isFinite(value) or value < 0)
                        return error.InvalidSnowDischargeRecipientHeat;

                if (surface_water != 0 or surface_heat != 0) {
                    const old_capacity = context.surface_heat_capacity_megajoules_per_k[cell];
                    const old_temperature = context.grid.surface_temperature_k[cell];
                    const candidate = try ecosys.snow_surface_transfer_heat.acceptedLitterCandidate(
                        old_capacity,
                        old_temperature,
                        surface_water,
                        surface_heat,
                        liquid_heat_capacity,
                    );
                    context.surface_heat_capacity_megajoules_per_k[cell] = candidate.heat_capacity_megajoules_per_k;
                    context.grid.surface_temperature_k[cell] = candidate.temperature_k;
                    context.litter_gas_transport.temperature_k[cell] = candidate.temperature_k;
                    self.surface_temperature_total.equilibrium_temperature_k[cell] = candidate.temperature_k;
                }
                if (topsoil_water != 0 or topsoil_heat != 0) {
                    const top = try context.grid.layerIndex(cell, 0);
                    // Forcing has already bound this meltwater as topsoil
                    // ingress. Richards publishes it into the carrier at the
                    // current soil temperature, which changes the canonical
                    // census by Cl*Tsoil*dW. Add only the donor-temperature
                    // remainder here; adding the full heat double-counts that
                    // represented carrier enthalpy.
                    const unrepresented_heat = try ecosys.snow_surface_transfer_heat.acceptedTopsoilHeatRemainder(
                        topsoil_water,
                        topsoil_heat,
                        context.grid.soil_temperature_k[top],
                        liquid_heat_capacity,
                    );
                    context.soil_hourly_workspace.cell_heat_source_megajoules[top] =
                        try checkedAddFiniteValue(
                            context.soil_hourly_workspace.cell_heat_source_megajoules[top],
                            unrepresented_heat / time_step_hours,
                        );
                }

                // WATSUB 2235 (`HFLWLT`) and 2241 (`HFLWRT`) credit the base
                // conduction to the same two recipients that the meltwater
                // carrier reaches. Signed, and no water moves, so the
                // recipient heat capacities are unchanged and there is no
                // already-represented carrier enthalpy to subtract.
                const base_litter_heat =
                    self.snow_base_litter_conduction_heat_step_megajoules_by_cell[cell];
                const base_topsoil_heat =
                    self.snow_base_topsoil_conduction_heat_step_megajoules_by_cell[cell];
                inline for (.{ base_litter_heat, base_topsoil_heat }) |value|
                    if (!std.math.isFinite(value)) return error.InvalidSnowBaseConductionRecipientHeat;
                if (base_litter_heat != 0) {
                    const temperature = try ecosys.snow_base_thermal_coupling.acceptedRecipientTemperatureK(
                        context.surface_heat_capacity_megajoules_per_k[cell],
                        context.grid.surface_temperature_k[cell],
                        base_litter_heat,
                    );
                    context.grid.surface_temperature_k[cell] = temperature;
                    context.litter_gas_transport.temperature_k[cell] = temperature;
                    self.surface_temperature_total.equilibrium_temperature_k[cell] = temperature;
                }
                if (base_topsoil_heat != 0) {
                    const top = try context.grid.layerIndex(cell, 0);
                    context.soil_hourly_workspace.cell_heat_source_megajoules[top] =
                        try checkedAddFiniteValue(
                            context.soil_hourly_workspace.cell_heat_source_megajoules[top],
                            base_topsoil_heat / time_step_hours,
                        );
                }
                if ((base_litter_heat != 0 or base_topsoil_heat != 0) and !builtin.is_test)
                    std.log.debug(
                        "snow base conduction: cell={d} litter_heat_mj={e} topsoil_heat_mj={e} litter_temperature_k={e} snow_cover_fraction={e} litter_cover_fraction={e}",
                        .{
                            cell,
                            base_litter_heat,
                            base_topsoil_heat,
                            context.grid.surface_temperature_k[cell],
                            self.surface_snow_cover_fraction[cell],
                            context.surface_precipitation.litter_cover_fraction[cell],
                        },
                    );
                if (!builtin.is_test and context.executed_weather_hours.* >= 2531 and context.executed_weather_hours.* < 2534) {
                    const top = try context.grid.layerIndex(cell, 0);
                    std.log.info("THERMAL_RECIPIENT hour={d} dt_hours={e} cell={d} snow_water_m3={e} snow_heat_megajoules={e} snow_base_heat_megajoules={e} soil_temperature_k={e} source_rate={e} base_source_rate={e} litter_conduction_rate={e}", .{ context.executed_weather_hours.* + 1, time_step_hours, cell, topsoil_water, topsoil_heat, base_topsoil_heat, context.grid.soil_temperature_k[top], context.soil_hourly_workspace.cell_heat_source_megajoules[top], self.base_cell_heat_source_megajoules[top], context.soil_hourly_workspace.published_surface_conduction_heat_megajoules[top] });
                }
            }
        }

        noinline fn armSnowDisappearance(self: *Self) !ecosys.snowpack_litter_heat_water_transfer.ArmedLiveDisappearance {
            const context = self.context;
            // SURFACE-HEAT-CAPACITY-STALE-WITHIN-HOUR-001 is NOT repaired here,
            // deliberately, and the attempt is recorded because the reasoning
            // is the load-bearing part.
            //
            // The transfer below derives its DRY capacity by subtracting a
            // freshly-recomputed wet capacity from
            // `litter_heat_capacity_megajoules_per_k`, a total published once
            // per hour at `hourly_snow_energy.zig:432` -- before the substeps
            // that move surface liquid, vapor and ice. It was measured stale by
            // `2.492331186283031e-6` MJ/K at the hour surface vapor and ice
            // first become nonzero, so the subtraction yields a slightly
            // fictitious dry capacity.
            //
            // Republishing it here from its one owner was implemented, passed
            // the full suite, and **regressed the fresh frontier from 2,657 to
            // 2,560 accepted hours**, with a new terminal
            // `SoluteReactionAcceptedStateConservationFailure` at attempt 2,561
            // -- a different subsystem, 97 hours earlier. It was reverted for
            // three reasons together, none of which would be sufficient alone:
            // the old formula is not *wrong*, only stale; the staleness's
            // measured `7.25e-4` MJ is 16.5x the
            // `SURFACE-HEAT-PONDED-LITTER-BOOKING-001` residual it was meant to
            // explain and of the wrong shape, so it was never the cause; and
            // the perturbation opens the soil-chemistry front, which carries a
            // twelve-round unresolved history.
            //
            // The `litter_geometry.heatCapacityMegajoulesPerK` owner introduced
            // for the attempt is KEPT -- it deduplicates a formula that existed
            // in three places and is behaviour-identical. Repair the staleness
            // together with the solute sensitivity, not before it.
            return ecosys.snowpack_litter_heat_water_transfer.armWarmThinPack(
                self.allocator,
                context.snow_transport,
                context.canopy_cell_area_m2,
                context.ground_air.temperature_k,
                self.snow_entry_top_heat_capacity_megajoules_per_k,
                .{
                    .litter_liquid_water_m3 = context.surface_precipitation.litter_water_m3,
                    .litter_water_vapor_mol = context.litter_gas_transport.water_vapor_mol,
                    .litter_ice_water_equivalent_m3 = context.surface_litter_ice_m3,
                    .litter_temperature_k = context.grid.surface_temperature_k,
                    .litter_heat_capacity_megajoules_per_k = context.surface_heat_capacity_megajoules_per_k,
                    .accepted_litter_discharge = context.snow_surface_discharge,
                },
                .{
                    .thermodynamics = .{
                        .solid_snow_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
                        .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                        .ice_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                        .pure_water_melting_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
                    },
                    // Donor: converts the snowpack's physical ice volume to a
                    // water-equivalent mass, so it must be the snow's.
                    .ice_density_megagrams_per_m3 = context.runscript.snow_ice_density_megagrams_per_m3,
                    // Recipient: every litter-side capacity and enthalpy, so it
                    // must be the one the surface inventory uses
                    // (`ecosys_ng.zig:3102`). Sharing the donor's here was
                    // `SURFACE-HEAT-PONDED-LITTER-BOOKING-001`.
                    .surface_ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                    .reset_snow_density_megagrams_per_m3 = context.runscript.initial_snow_density_megagrams_per_m3,
                    .water_molar_mass_g_per_mol = context.runscript.soil_gas_transport_parameters.water_molar_mass_g_per_mol,
                    .water_density_g_per_m3 = context.runscript.soil_gas_transport_parameters.water_density_g_per_m3,
                    .snow_latent_heat_of_fusion_megajoules_per_m3 = context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
                    .surface_latent_heat_of_fusion_megajoules_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
                    .heat_capacity_absolute_tolerance_megajoules_per_k = context.config.physical_tolerance.heat_megajoules /
                        context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
                    .physical_relative_tolerance = context.config.physical_tolerance.relative,
                    .conservation = snowDisappearanceConservationTolerances(context),
                },
            );
        }

        noinline fn consumeSnowDisappearance(
            self: *Self,
            disappearance: *ecosys.snowpack_litter_heat_water_transfer.ArmedLiveDisappearance,
        ) !void {
            const context = self.context;
            const old_litter_water_m3 = try self.allocator.dupe(
                f64,
                context.surface_precipitation.litter_water_m3,
            );
            defer self.allocator.free(old_litter_water_m3);
            // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. This operation
            // loses 5.206857167650014e-10 g P from the CELL total, which must be
            // invariant across an intra-cell snow-to-surface move. Split it: the
            // transfer itself (`consume`) versus everything after it (the litter
            // carrier rebase and the geometry republish). Reconstructing the old
            // carrier as `new - change` was already ruled out -- replacing it with
            // the exact captured value was bit-identical, since `change = new - old`
            // is exact by Sterbenz and so `new - change == old`.
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659)
                try diagnostics.logPhosphorusRepresentation(self.context, "snow_disappearance_before_consume");
            const report = try disappearance.consume();
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659)
                try diagnostics.logPhosphorusRepresentation(self.context, "snow_disappearance_after_consume");
            if (report.triggered_cells == 0) return;

            var retained_trigger_count: usize = 0;
            for (disappearance.accepted_transfer_by_cell, 0..) |accepted, cell| {
                if (!accepted.triggered) continue;
                retained_trigger_count += 1;
                if (accepted.water_equivalent_m3 != 0)
                    try self.incrementWaterStorageUpdate(.{ .kind = .surface, .cell = cell }, 1);
                const source = cell * context.snow_transport.layer_capacity;
                self.snow_discharge_water_total_m3_by_source_layer[source] = try checkedAddFiniteValue(
                    self.snow_discharge_water_total_m3_by_source_layer[source],
                    accepted.water_equivalent_m3,
                );
                self.snow_discharge_heat_total_megajoules_by_source_layer[source] = try checkedAddFiniteValue(
                    self.snow_discharge_heat_total_megajoules_by_source_layer[source],
                    accepted.canonical_heat_megajoules,
                );
                self.snow_surface_transfer_water_total_m3_by_cell[cell] = try checkedAddFiniteValue(
                    self.snow_surface_transfer_water_total_m3_by_cell[cell],
                    accepted.water_equivalent_m3,
                );
                self.snow_surface_transfer_heat_total_megajoules_by_cell[cell] = try checkedAddFiniteValue(
                    self.snow_surface_transfer_heat_total_megajoules_by_cell[cell],
                    accepted.canonical_heat_megajoules,
                );
                for (accepted.amount_g, 0..) |amount, species| {
                    const index = source * ecosys.snow_solute_transport.species_count + species;
                    self.snow_discharge_total_g_by_source_layer_species[index] = try checkedAddFiniteValue(
                        self.snow_discharge_total_g_by_source_layer_species[index],
                        amount,
                    );
                }
                for (accepted.salt_amount_mol, 0..) |amount, species| {
                    const index = source * ecosys.snow_solute_transport.salt_species_count + species;
                    self.snow_discharge_total_salt_mol_by_source_layer_species[index] = try checkedAddFiniteValue(
                        self.snow_discharge_total_salt_mol_by_source_layer_species[index],
                        amount,
                    );
                }
            }
            if (retained_trigger_count != report.triggered_cells)
                return error.SnowDisappearanceAcceptedSidecarMismatch;

            const litter_water_change_m3 = try self.allocator.alloc(f64, context.grid.cell_count);
            defer self.allocator.free(litter_water_change_m3);
            for (litter_water_change_m3, context.surface_precipitation.litter_water_m3, old_litter_water_m3) |*change, new, old|
                change.* = new - old;
            for (0..context.grid.cell_count) |cell|
                try self.accumulateSurfaceChemistryRebaseRoundoff(
                    cell,
                    try ecosys.surface_litter_chemistry_carrier_rebase.previewCellWaterRoundoffFromScaleSource(
                        context.surface_litter_chemistry,
                        cell,
                        old_litter_water_m3[cell],
                        context.surface_precipitation.litter_water_m3[cell] - litter_water_change_m3[cell],
                        context.surface_precipitation.litter_water_m3[cell],
                        try surfaceChemistryRebaseInventoryInputs(context, cell),
                    ),
                );
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659)
                try diagnostics.logPhosphorusRepresentation(self.context, "snow_disappearance_before_litter_rebase");
            try ecosys.surface_litter_chemistry_carrier_rebase.rebaseFromAcceptedLiquidWaterChange(
                context.surface_litter_chemistry,
                context.surface_precipitation.litter_water_m3,
                litter_water_change_m3,
            );
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659)
                try diagnostics.logPhosphorusRepresentation(self.context, "snow_disappearance_after_litter_rebase");

            // The litter--soil interface follows immediately, so republish
            // geometry from the transferred phase carriers before it reads
            // pore volume, retention and air storage.
            for (0..context.grid.cell_count) |cell|
                context.surface_charcoal_carbon_g_c[cell] = try context.surface_organic.charcoalCarbon_g_c(cell);
            const surface_parameters = context.surface_gas_parameters.*;
            var geometry_context: ecosys.surface_litter_geometry_step.ApplyContext = .{
                .result = context.surface_litter_geometry,
                .surface_organic = context.surface_organic,
                .water_m3 = context.surface_precipitation.litter_water_m3,
                .ice_water_equivalent_m3 = context.surface_litter_ice_m3,
                .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                .charcoal_carbon_g_c = context.surface_charcoal_carbon_g_c,
                .retention_mode = .preserve,
                .parameters = surface_parameters.litter_geometry,
            };
            // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. The geometry
            // republish recomputes `surface_litter_geometry.dry_mass_megagrams`,
            // and the litter chemistry's exchange pools are inventoried against it
            // as `dry_mass_megagrams * *_mol_per_megagram`. That is a SOLID carrier
            // change, and this path performed it with no chemistry rebase and no
            // booked allowance -- measured as `+1.1050360626541078e-10` g P, which
            // is the frontier residual `1.10503606265411e-10` to every digit.
            //
            // The bracketing that found it: `disappearance.consume()` and the
            // litter water rebase both step the cell invariant by exactly `0`,
            // and the entire residual appears across this republish. It is also
            // why every water-carrier check in this investigation came back exact
            // -- the defective carrier is not water.
            //
            // `hourly_sediment.zig:1091-1132` is the correct sibling and this
            // mirrors it: capture the old dry mass, preview the allowance per cell,
            // rebase the dry-mass-normalized pools, then book the allowance.
            const old_litter_dry_mass_megagrams = try self.allocator.dupe(
                f64,
                context.surface_litter_geometry.dry_mass_megagrams,
            );
            defer self.allocator.free(old_litter_dry_mass_megagrams);
            try tile_kernels.runKernelAcrossSerialTiles(
                context,
                &geometry_context,
                ecosys.surface_litter_geometry_step.applyTile,
            );
            const dry_mass_rebase_roundoff_by_cell = try self.allocator.alloc(
                ecosys.soil_chemistry_water_carrier_rebase.RoundoffAllowance,
                context.grid.cell_count,
            );
            defer self.allocator.free(dry_mass_rebase_roundoff_by_cell);
            for (dry_mass_rebase_roundoff_by_cell, 0..) |*allowance, cell| {
                const aqueous_carrier_m3 = try ecosys.surface_litter_chemistry_carrier_rebase.effectiveAqueousCarrierM3(
                    context.surface_precipitation.litter_water_m3[cell],
                    context.surface_litter_chemistry.dry_reference_water_m3[cell],
                );
                allowance.* = try ecosys.surface_litter_chemistry_carrier_rebase.previewCellDryMassRoundoff(
                    context.surface_litter_chemistry.cells[cell],
                    aqueous_carrier_m3,
                    context.surface_litter_chemistry.mineral_reference_water_m3[cell],
                    .{
                        .dry_mass_megagrams = old_litter_dry_mass_megagrams[cell],
                        .carbon_g_per_mol = 12.0,
                        .nitrogen_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                        .phosphorus_g_per_mol = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                        .fertilizer_ammonium_mol_n = context.surface_litter_fertilizer.cells[cell].ammonium_mol_n,
                        .fertilizer_ammonia_mol_n = context.surface_litter_fertilizer.cells[cell].ammonia_mol_n,
                        .fertilizer_urea_mol_n = context.surface_litter_fertilizer.cells[cell].urea_mol_n,
                        .fertilizer_nitrate_mol_n = context.surface_litter_fertilizer.cells[cell].nitrate_mol_n,
                        .denitrification_nitrite_g_n = context.surface_denitrification.nitrite_g_n[cell],
                    },
                    old_litter_dry_mass_megagrams[cell],
                    context.surface_litter_geometry.dry_mass_megagrams[cell],
                );
            }
            try ecosys.surface_litter_chemistry_carrier_rebase.rebaseFromAcceptedDryMassChange(
                context.surface_litter_chemistry,
                old_litter_dry_mass_megagrams,
                context.surface_litter_geometry.dry_mass_megagrams,
            );
            try ecosys.layer_local_conservation.accumulateAcceptedSurfaceChemistryRebaseRoundoff(
                context.hourly_cell_boundary_ledger,
                context.hourly_layer_boundary_ledger,
                dry_mass_rebase_roundoff_by_cell,
                12.0,
                context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
            );
            @memcpy(
                context.surface_precipitation.litter_water_capacity_m3,
                context.surface_litter_geometry.water_retention_capacity_m3,
            );
            for (0..context.grid.cell_count) |cell| {
                context.litter_gas_transport.air_volume_m3[cell] = context.surface_litter_geometry.air_volume_m3[cell];
                context.litter_gas_transport.temperature_k[cell] = context.grid.surface_temperature_k[cell];
                self.surface_temperature_total.equilibrium_temperature_k[cell] = context.grid.surface_temperature_k[cell];
            }
        }

        noinline fn applyAcceptedSurfaceDischarge(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            if (!std.math.isFinite(time_step_hours) or time_step_hours <= 0 or time_step_hours > 1)
                return error.InvalidSurfaceDischargeSubstep;
            const accepted_step = try self.allocator.dupe(
                ecosys.snow_solute_transport.SurfaceDischarge,
                context.snow_surface_discharge,
            );
            defer self.allocator.free(accepted_step);
            try addScaledSnowSurfaceDischarge(
                accepted_step,
                context.direct_surface_solute_input,
                time_step_hours,
            );
            if (!snowSurfaceDischargeHasActivity(accepted_step)) return;
            const ion_parameters = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol;
            try ecosys.snow_surface_discharge.state_update(
                self.allocator,
                .{
                    .discharge = accepted_step,
                    .litter_water_volume_m3 = context.surface_precipitation.litter_water_m3,
                    .topsoil_water_volume_m3 = context.grid.matrix_liquid_water_m3[0..context.grid.layer_count],
                    .soil_layer_capacity = context.grid.soil_layer_capacity,
                    .nitrogen_molar_mass_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                    .phosphorus_molar_mass_g_per_mol = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                    .ion_molar_mass_g_per_mol = .{
                        .aluminum = ion_parameters.aluminum,
                        .iron = ion_parameters.iron,
                        .calcium = ion_parameters.calcium,
                        .magnesium = ion_parameters.magnesium,
                        .sodium = ion_parameters.sodium,
                        .potassium = ion_parameters.potassium,
                        .sulfur = ion_parameters.sulfur,
                        .chloride = ion_parameters.chloride,
                    },
                    .surface_aqueous = context.surface_solute_transport,
                    .soil_transport_owners = .{
                        .aqueous = context.micropore_solute_state,
                        .mineral_nitrogen = context.mineral_nitrogen_transport,
                    },
                    .fertilizer_band = context.fertilizer_band,
                },
                context.litter_gas_transport,
                context.gas_transport,
                context.surface_litter_chemistry,
                context.soil_chemistry,
            );
            // Only snow-owned movement belongs in the accepted snow diagnostic;
            // direct atmospheric input has its independent external ledger.
            try addSnowSurfaceDischarge(self.snow_surface_discharge_total, context.snow_surface_discharge);
            // This transient owner is consumed exactly once. Hourly publication
            // below is diagnostic only; `hourly_sediment` no longer reapplies it.
            @memset(context.snow_surface_discharge, .{});
        }

        noinline fn advanceSnowCompactionAndRelayering(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            // REDIST applies both fresh-snow density mixing and metamorphism
            // in every physical WATSUB subcycle. The atmospheric producer is
            // now schedule-owned, so both terms use the same accepted dt.
            for (self.snow_compaction_snowfall_m3, context.surface_precipitation.snow_to_snow_m3_per_h) |*amount, hourly_amount| {
                amount.* = hourly_amount * time_step_hours;
                if (!std.math.isFinite(amount.*) or amount.* < 0)
                    return error.InvalidSnowCompactionInput;
            }
            try ecosys.snow_compaction.apply(self.allocator, context.snow_transport, .{
                .snowfall_water_equivalent_m3 = self.snow_compaction_snowfall_m3,
                .atmospheric_temperature_k = context.atmosphere.air_temperature_k,
                .timestep_h = time_step_hours,
                .initial_snow_density_megagrams_per_m3 = context.runscript.initial_snow_density_megagrams_per_m3,
                .ice_density_megagrams_per_m3 = context.runscript.snow_ice_density_megagrams_per_m3,
            }, context.runscript.snow_compaction_parameters);
            const freezing_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k;
            if (!std.math.isFinite(freezing_temperature_k) or freezing_temperature_k <= 0)
                return error.InvalidSnowRelayeringReferenceTemperature;
            try self.captureSnowWaterStorage();
            _ = try ecosys.snow_relayering.applyAccepted(self.allocator, context.snow_transport, .{
                .solid_snow_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
                .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                .ice_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                .pure_water_melting_temperature_k = freezing_temperature_k,
            }, .{
                .volume_absolute_m3 = context.config.physical_tolerance.water_volume_m3,
                .heat_capacity_absolute_megajoules_per_k = context.config.physical_tolerance.heat_megajoules / freezing_temperature_k,
                .relative = context.config.physical_tolerance.relative,
            }, &self.snow_relayering_step);
            try self.incrementChangedSnowWaterStorageUpdates();
            try self.snow_relayering_total.add(self.snow_relayering_step);
            for (
                self.snow_activity_active_by_layer,
                context.snow_transport.active,
                self.snow_relayering_step.touched_by_layer,
            ) |*ever_active, active, touched| ever_active.* = ever_active.* or active or touched;
            for (0..context.grid.cell_count) |cell| {
                context.snow_depth_m[cell] = context.snow_transport.cumulative_depth_m[(cell + 1) * context.snow_transport.layer_capacity - 1];
                context.surface_precipitation.snow_cover_fraction[cell] = (try ecosys.snow_cover_fraction.evaluate(
                    context.snow_depth_m[cell],
                    context.runscript.snow_full_cover_depth_m,
                )).snow_fraction;
                var solid_snow_water_equivalent_m3: f64 = 0;
                for (0..context.snow_transport.layer_capacity) |layer|
                    solid_snow_water_equivalent_m3 += context.snow_transport.solid_snow_water_equivalent_m3[cell * context.snow_transport.layer_capacity + layer];
                context.surface_precipitation.solid_snow_water_equivalent_m3[cell] = solid_snow_water_equivalent_m3;
            }
        }

        noinline fn refreshSurfaceHeatCapacity(self: *Self) !void {
            const context = self.context;
            const ice_heat_capacity_per_water_equivalent_m3_k =
                try ecosys.ice_units.heatCapacityPerWaterEquivalentM3K(
                    context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                    context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                );
            for (0..context.grid.cell_count) |cell| {
                const vapor_water_equivalent_m3 = context.litter_gas_transport.water_vapor_mol[cell] *
                    context.runscript.soil_gas_transport_parameters.water_molar_mass_g_per_mol /
                    context.runscript.soil_gas_transport_parameters.water_density_g_per_m3;
                // SURFACE-HEAT-CAPACITY-SIX-OWNERS-001: the last open-coded copy
                // of this formula, converged onto the one owner. Of the six
                // production writers of `surface_heat_capacity_megajoules_per_k`,
                // four publish a consistent (capacity, temperature) pair that a
                // solver computed together -- `:4404`, `:5433`, `:7886` and
                // `tillage/runtime_adapter.zig:1082` -- and are legitimate.
                // This site and `hourly_snow_energy.zig:435` were the two that
                // recomputed the formula from state, and the inventory
                // (`landscape_mass_inventory_surface.zig:513-517`) makes a
                // third. Behaviour-identical: same terms, same parameters,
                // same order; the owner's own validation replaces the local
                // finite/positive check.
                context.surface_heat_capacity_megajoules_per_k[cell] =
                    ecosys.surface_litter_geometry.heatCapacityMegajoulesPerK(
                        context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
                        try context.surface_organic.totalCarbon_g_c(cell),
                        context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                        context.surface_precipitation.litter_water_m3[cell],
                        vapor_water_equivalent_m3,
                        ice_heat_capacity_per_water_equivalent_m3_k,
                        context.surface_litter_ice_m3[cell],
                    ) catch return error.InvalidSurfaceHeatCapacity;
            }
        }

        noinline fn advanceSurfaceTemperature(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            const ice_heat_capacity_per_water_equivalent_m3_k =
                try ecosys.ice_units.heatCapacityPerWaterEquivalentM3K(
                    context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                    context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                );
            // EVAPG is produced only by the post-phase hook. Clear the prior
            // accepted substep before pre-phase forcing preparation can see it.
            @memset(self.forcing.accepted_topsoil_vapor_change_m3, 0);
            @memset(self.forcing.accepted_topsoil_liquid_change_m3, 0);
            // WATSUB refreshes PSISVR from the current litter water and solute
            // carriers on every retry substep. Keep that refresh inside the
            // transactional schedule so failed attempts leave no stale phase
            // or vapor potential behind.
            var litter_water_environment_context: ecosys.surface_litter_water_environment.ApplyContext = .{
                .result = context.surface_litter_water_environment,
                .litter_geometry = context.surface_litter_geometry,
                .litter_chemistry = context.surface_litter_chemistry,
                .litter_water_m3 = context.surface_precipitation.litter_water_m3,
                .litter_temperature_k = context.grid.surface_temperature_k,
                .field_capacity_potential_megapascal = context.surface_field_capacity_potential_megapascal,
                .wilting_point_potential_megapascal = context.surface_wilting_point_potential_megapascal,
                .parameters = context.surface_gas_parameters.litter_water_environment,
            };
            try tile_kernels.runKernelAcrossSerialTiles(
                context,
                &litter_water_environment_context,
                ecosys.surface_litter_water_environment.applyTile,
            );
            try self.refreshSurfaceHeatCapacity();
            for (0..context.grid.cell_count) |cell| {
                self.litter_vapor_water_equivalent_m3[cell] =
                    context.litter_gas_transport.water_vapor_mol[cell] *
                    context.runscript.soil_gas_transport_parameters.water_molar_mass_g_per_mol /
                    context.runscript.soil_gas_transport_parameters.water_density_g_per_m3;
                if (!std.math.isFinite(self.litter_vapor_water_equivalent_m3[cell]) or
                    self.litter_vapor_water_equivalent_m3[cell] < 0)
                    return error.InvalidSurfaceLitterVaporStorage;
                self.surface_air_vapor_pressure_kpa[cell] = try ecosys.ground_air_exchange.vaporPressureKpa(
                    context.ground_air.vapor_volume_fraction[cell],
                    context.ground_air.temperature_k[cell],
                    context.runscript.ground_air_parameters,
                );
                const bottom = (cell + 1) * context.snow_transport.layer_capacity - 1;
                self.surface_snow_cover_fraction[cell] = (try ecosys.snow_cover_fraction.evaluate(
                    context.snow_transport.cumulative_depth_m[bottom],
                    context.runscript.snow_full_cover_depth_m,
                )).snow_fraction;
                const total_litter_carbon_g_c = try context.surface_organic.totalCarbon_g_c(cell);
                const charcoal_carbon_g_c = try context.surface_organic.charcoalCarbon_g_c(cell);
                if (charcoal_carbon_g_c > total_litter_carbon_g_c)
                    return error.InvalidSurfaceLitterCarbonPartition;
                self.surface_dry_litter_albedo[cell] = try ecosys.ground_radiation.dryLitterAlbedo(
                    total_litter_carbon_g_c - charcoal_carbon_g_c,
                    charcoal_carbon_g_c,
                    context.config.physical_tolerance.carbon_g +
                        context.config.physical_tolerance.relative * total_litter_carbon_g_c,
                );
                // WATSUB XVOLT uses the current substep litter phases, not the
                // previous runoff publication: AMAX1(0,VOLW(0)+VOLI(0)-VOLWRX).
                const current_litter_phase_volume_m3 =
                    try group_gas_surface_water.litterLiquidAndPhysicalIceVolumeM3(
                        context.surface_precipitation.litter_water_m3[cell],
                        context.surface_litter_ice_m3[cell],
                        context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                    );
                const current_litter_excess_m3 = current_litter_phase_volume_m3 -
                    context.surface_precipitation.litter_water_capacity_m3[cell];
                if (!std.math.isFinite(current_litter_excess_m3))
                    return error.InvalidSurfaceLitterWaterStorage;
                self.surface_live_litter_cover_fraction[cell] = try ecosys.ground_radiation.liveLitterCoverFraction(
                    total_litter_carbon_g_c,
                    context.canopy_cell_area_m2[cell],
                    context.surface_heat_capacity_megajoules_per_k[cell],
                    context.surface_pond_minimum_heat_capacity_megajoules_per_k[cell],
                    @max(0, current_litter_excess_m3),
                    context.runscript.surface_runoff_parameters.ground_surface_retention_m3_per_m2 *
                        context.canopy_cell_area_m2[cell],
                );

                // WATSUB 655-657, 825-908: derive the six live surface
                // conductances from the accepted entry state of this recovery
                // substep. The runscript's legacy scalar conductances are not
                // inputs to this network.
                const area_m2 = context.canopy_cell_area_m2[cell];
                const top = try context.grid.layerIndex(cell, 0);
                const snow_first = cell * context.snow_transport.layer_capacity;
                const snow_end = snow_first + context.snow_transport.layer_capacity;
                for (snow_first..snow_end) |snow_layer| {
                    const snow_temperature_k = if (context.snow_transport.temperature_k[snow_layer] > 0)
                        context.snow_transport.temperature_k[snow_layer]
                    else
                        context.grid.surface_temperature_k[cell];
                    context.snow_layer_gas_diffusivity_m2_per_h[snow_layer] =
                        context.runscript.snow_vapor_diffusion_parameters.reference_vapor_diffusivity_m2_per_h *
                        std.math.pow(
                            f64,
                            snow_temperature_k / context.runscript.snow_vapor_diffusion_parameters.reference_temperature_k,
                            context.runscript.snow_vapor_diffusion_parameters.temperature_exponent,
                        );
                }
                const snow_surface_temperature_k = if (context.snow_transport.temperature_k[snow_first] > 0)
                    context.snow_transport.temperature_k[snow_first]
                else
                    context.grid.surface_temperature_k[cell];
                const water_adjusted_litter = self.surface_live_litter_cover_fraction[cell];
                const water_adjusted_bare = 1 - water_adjusted_litter;
                const snow_free = 1 - self.surface_snow_cover_fraction[cell];
                const composite_surface_temperature_k = self.surface_snow_cover_fraction[cell] * snow_surface_temperature_k +
                    snow_free * (water_adjusted_litter * context.grid.surface_temperature_k[cell] +
                        water_adjusted_bare * context.grid.soil_temperature_k[top]);
                const atmospheric_diffusivity_m2_per_h =
                    context.runscript.soil_process_parameters.reference_water_vapor_diffusivity_m2_per_h *
                    std.math.pow(
                        f64,
                        context.atmosphere.air_temperature_k[cell] /
                            context.runscript.soil_process_parameters.vapor_diffusivity_reference_temperature_k,
                        context.runscript.soil_process_parameters.vapor_diffusivity_temperature_exponent,
                    );
                const litter_diffusivity_m2_per_h =
                    context.runscript.soil_process_parameters.reference_water_vapor_diffusivity_m2_per_h *
                    std.math.pow(
                        f64,
                        context.grid.surface_temperature_k[cell] /
                            context.runscript.soil_process_parameters.vapor_diffusivity_reference_temperature_k,
                        context.runscript.soil_process_parameters.vapor_diffusivity_temperature_exponent,
                    );
                const litter_volume_m3 = context.surface_litter_geometry.expanded_total_volume_m3[cell];
                const litter_porosity = context.surface_litter_geometry.porosity_m3_per_m3[cell];
                const litter_thickness_m = if (litter_volume_m3 > 0) @max(1.0e-6, litter_volume_m3 / area_m2) else 0;
                const raw_litter_resistance_h_per_m = if (litter_thickness_m > 0)
                    litter_thickness_m / litter_diffusivity_m2_per_h
                else
                    0;
                const surface_capacity_m3 = context.runscript.surface_runoff_parameters.ground_surface_retention_m3_per_m2 * area_m2;
                const surface_excess_m3 = @max(0, current_litter_excess_m3);
                const water_cover_fraction = if (surface_capacity_m3 > 0)
                    std.math.clamp(surface_excess_m3 / surface_capacity_m3, 0, 1)
                else if (surface_excess_m3 > 0)
                    @as(f64, 1)
                else
                    @as(f64, 0);
                const litter_air_fraction = if (litter_volume_m3 > 0)
                    std.math.clamp(context.surface_litter_geometry.air_volume_m3[cell] / litter_volume_m3, 0, litter_porosity)
                else
                    0;
                const effective_litter_air_fraction = litter_air_fraction * @max(0, 1 - water_cover_fraction);
                const litter_transport_factor = @max(
                    context.runscript.surface_gas_resistance_parameters.minimum_air_fraction,
                    if (litter_porosity > 0)
                        context.runscript.soil_gas_transport_parameters.penman_tortuosity *
                            effective_litter_air_fraction * effective_litter_air_fraction / litter_porosity
                    else
                        0,
                );
                const effective_litter_resistance_h_per_m = if (raw_litter_resistance_h_per_m > 0)
                    raw_litter_resistance_h_per_m / litter_transport_factor
                else
                    0;
                const resistance = try ecosys.surface_gas_boundary_conductance.calculate(.{
                    .cell_area_m2 = area_m2,
                    .air_temperature_k = context.atmosphere.air_temperature_k[cell],
                    .ground_air_temperature_k = context.ground_air.temperature_k[cell],
                    .surface_temperature_k = composite_surface_temperature_k,
                    .bulk_richardson_coefficient_k = context.surface_aerodynamics.bulk_richardson_coefficient_k[cell],
                    .isothermal_atmospheric_resistance_h_per_m = context.surface_aerodynamics.isothermal_aerodynamic_resistance_h_per_m[cell],
                    .total_canopy_area_m2 = context.surface_total_canopy_area_m2[cell],
                    .canopy_height_m = context.surface_canopy_height_m[cell],
                    .roughness_height_m = context.canopy_surface_roughness_height_m[cell],
                    .atmospheric_vapor_diffusivity_m2_per_h = atmospheric_diffusivity_m2_per_h,
                    .isothermal_ground_surface_resistance_h_per_m = ecosys.surface_gas_boundary_conductance.ground_isothermal_surface_resistance_h_per_m,
                    .bare_surface_fraction = water_adjusted_bare,
                    .litter_surface_fraction = water_adjusted_litter,
                    .litter_porous_resistance_h_per_m = effective_litter_resistance_h_per_m,
                    .snow_layer_thickness_m = context.snow_transport.layer_thickness_m[snow_first..snow_end],
                    .snow_layer_total_volume_m3 = context.snow_transport.total_layer_volume_m3[snow_first..snow_end],
                    .snow_layer_air_volume_m3 = context.snow_transport.air_filled_volume_m3[snow_first..snow_end],
                    .snow_layer_vapor_diffusivity_m2_per_h = context.snow_layer_gas_diffusivity_m2_per_h[snow_first..snow_end],
                }, context.runscript.surface_gas_resistance_parameters);
                const dry_bare = if (context.surface_heat_capacity_megajoules_per_k[cell] >
                    context.surface_pond_minimum_heat_capacity_megajoules_per_k[cell])
                    std.math.exp(-0.005 * total_litter_carbon_g_c / area_m2)
                else
                    1;
                const topsoil_diffusivity_m2_per_h =
                    context.runscript.soil_process_parameters.reference_water_vapor_diffusivity_m2_per_h *
                    std.math.pow(
                        f64,
                        context.grid.soil_temperature_k[top] /
                            context.runscript.soil_process_parameters.vapor_diffusivity_reference_temperature_k,
                        context.runscript.soil_process_parameters.vapor_diffusivity_temperature_exponent,
                    );
                const exchange = try ecosys.surface_gas_boundary_conductance.calculateSurfaceExchange(.{
                    .cell_area_m2 = area_m2,
                    .flux_timestep_h = time_step_hours,
                    .snow_flux_timestep_h = time_step_hours,
                    .litter_flux_timestep_h = time_step_hours,
                    .snow_depth_m = context.snow_transport.cumulative_depth_m[snow_end - 1],
                    .full_snow_cover_depth_m = context.runscript.snow_full_cover_depth_m,
                    .nominal_bare_soil_fraction = dry_bare,
                    .surface_excess_water_m3 = surface_excess_m3,
                    .surface_water_capacity_m3 = surface_capacity_m3,
                    .current_ground_surface_resistance_h_per_m = resistance.current_surface_resistance_h_per_m,
                    .current_snow_surface_resistance_h_per_m = resistance.current_surface_resistance_h_per_m,
                    .litter_porous_resistance_h_per_m = raw_litter_resistance_h_per_m,
                    .litter_air_fraction = effective_litter_air_fraction,
                    .litter_porosity_m3_per_m3 = if (litter_porosity > 0) litter_porosity else 1,
                    .litter_tortuosity = context.runscript.soil_gas_transport_parameters.penman_tortuosity,
                    .minimum_air_transport_factor = context.runscript.surface_gas_resistance_parameters.minimum_air_fraction,
                    .soil_evaporation_pore_resistance_h_per_m = context.soil_solver_properties.layer_thickness_m[top] / topsoil_diffusivity_m2_per_h,
                    .soil_surface_air_fraction = context.grid.matrix_air_volume_m3[top] /
                        context.soil_solver_properties.layer_volume_m3[top],
                    .evaporation_surface_resistance_h_per_m = ecosys.surface_gas_boundary_conductance.evaporation_surface_resistance_h_per_m,
                });
                const partition_scale = @max(1, @max(@abs(water_adjusted_litter), @abs(exchange.water_adjusted_litter_fraction)));
                if (@abs(exchange.water_adjusted_litter_fraction - water_adjusted_litter) >
                    256 * std.math.floatEps(f64) * partition_scale)
                    return error.SurfaceExchangePartitionMismatch;
                self.litter_vapor_conductance_m3_per_h[cell] = exchange.litter_latent_conductance_m3_per_step / time_step_hours;
                self.litter_sensible_conductance_megajoules_per_h_k[cell] = exchange.litter_sensible_conductance_megajoules_per_k_step / time_step_hours;
                self.topsoil_vapor_conductance_m3_per_h[cell] = exchange.soil_latent_conductance_m3_per_step / time_step_hours;
                self.topsoil_sensible_conductance_megajoules_per_h_k[cell] = exchange.soil_sensible_conductance_megajoules_per_k_step / time_step_hours;
                self.snow_vapor_conductance_m3_per_h[cell] = exchange.snow_latent_conductance_m3_per_step / time_step_hours;
                self.snow_sensible_conductance_megajoules_per_h_k[cell] = exchange.snow_sensible_conductance_megajoules_per_k_step / time_step_hours;
            }
            self.surface_temperature_work.resetPhaseChangeDiagnostics();
            var apply_context: ecosys.surface_temperature_solver.ApplyContext = .{
                .result = &self.surface_temperature_work,
                .grid = context.grid,
                .atmosphere = context.atmosphere,
                .air_temperature_k = context.ground_air.temperature_k,
                .air_vapor_pressure_kpa = self.surface_air_vapor_pressure_kpa,
                .air_vapor_volume_fraction = context.ground_air.vapor_volume_fraction,
                .litter_vapor_conductance_m3_per_h = self.litter_vapor_conductance_m3_per_h,
                // Sensible exchange is one paired finite-capacity air/surface
                // solve after phase and vapor; do not apply it twice here.
                .litter_sensible_conductance_megajoules_per_h_k = self.deferred_sensible_conductance,
                .litter_air_volume_m3 = context.litter_gas_transport.air_volume_m3,
                .litter_vapor_water_equivalent_m3 = self.litter_vapor_water_equivalent_m3,
                .vapor_fraction_conversion_k_per_kpa = context.runscript.ground_air_parameters.saturation_vapor_prefactor_k,
                .ground_radiation = context.ground_radiation,
                .surface_energy = &self.surface_energy_work,
                .soil_thermal = context.soil_thermal,
                .surface_heat_capacity_megajoules_per_k = context.surface_heat_capacity_megajoules_per_k,
                .surface_water_potential_megapascal = context.surface_litter_water_environment.matric_plus_osmotic_water_potential_megapascal,
                .snow_cover_fraction = self.surface_snow_cover_fraction,
                .snow_free_surface_emissivity = context.surface_energy_settings.soil_longwave_emissivity,
                .exposure = if (context.canopy_exposure.*) |*exposure| exposure else null,
                // The delayed fire owner is a one-hour energy. Over the fixed
                // one-hour external clock its numeric value is the constant
                // rate used by each internal step; integration occurs exactly
                // once through the solver's physical dt.
                .external_heat_megajoules_per_m2 = context.surface_combustion_heat_megajoules_per_m2,
                .surface_phase = .{
                    .liquid_water_m3 = context.surface_precipitation.litter_water_m3,
                    .ice_water_equivalent_m3 = context.surface_litter_ice_m3,
                    .retention_capacity_m3 = context.surface_precipitation.litter_water_capacity_m3,
                    .horizontal_area_m2 = context.canopy_cell_area_m2,
                    .residual_water_content_m3_per_m3 = context.runscript.soil_process_parameters.surface_residue_residual_water_content_m3_per_m3,
                    .van_genuchten_alpha_per_m = context.runscript.soil_process_parameters.surface_residue_van_genuchten_alpha_per_m,
                    .van_genuchten_n = context.runscript.soil_process_parameters.surface_residue_van_genuchten_n,
                    .gravitational_water_potential_mpa_per_m = context.runscript.soil_process_parameters.gravitational_water_potential_mpa_per_m,
                    .latent_heat_of_fusion_megajoules_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3,
                    .pure_water_melting_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
                    .ice_heat_capacity_per_water_equivalent_m3_k = ice_heat_capacity_per_water_equivalent_m3_k,
                },
                .surface_albedo = .{
                    .matrix_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
                    .bulk_density_megagrams_per_m3 = context.soil_solver_properties.bulk_density_megagrams_per_m3,
                    .dry_litter_albedo = self.surface_dry_litter_albedo,
                    .dry_litter_mass_megagrams = context.surface_litter_geometry.dry_mass_megagrams,
                    .litter_cover_fraction = self.surface_live_litter_cover_fraction,
                    .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                    .phase_volume_absolute_tolerance_m3 = context.config.physical_tolerance.water_volume_m3,
                    .phase_volume_relative_tolerance = context.config.physical_tolerance.relative,
                },
                .settings = .{
                    .timestep_hours = time_step_hours,
                    .sensible_heat_conductance_megajoules_per_m2_h_k = 0,
                    .latent_heat_conductance_megajoules_per_m2_h_kpa = 0,
                    .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                    .latent_heat_of_vaporization_megajoules_per_m3 = context.runscript.ground_air_parameters.liquid_water_latent_heat_megajoules_per_m3,
                    .surface_vapor_activity_fraction = context.runscript.surface_vapor_activity_fraction,
                    .minimum_temperature_k = context.runscript.minimum_surface_temperature_k,
                    .maximum_temperature_k = context.runscript.maximum_surface_temperature_k,
                    .energy_conservation_absolute_tolerance_megajoules_per_m2_h = context.config.mass_balance_absolute_tolerance.heat_megajoules_m2,
                    .energy_conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                    // A one-ULP Newton step can be unable to reduce an
                    // already machine-precision residual.  Publish that best
                    // iterate only when the surface solver's independent
                    // physical energy-closure gate accepts it.
                    .accept_physically_conserved_ceiling = true,
                    .solver_options = .{
                        .absolute_tolerance = 0,
                        .relative_tolerance = context.config.nonlinear_tolerance.relative,
                        .picard_relaxation = context.config.picard_relaxation,
                        .residual_scale = 1,
                        .max_iterations = self.max_iterations,
                        .accept_nearest_representable_root = true,
                    },
                },
            };
            try ecosys.surface_temperature_solver.validateApplyContext(&apply_context);
            @memcpy(
                self.surface_liquid_water_before_temperature_m3,
                context.surface_precipitation.litter_water_m3,
            );
            try tile_kernels.runKernelAcrossSerialTiles(
                context,
                &apply_context,
                ecosys.surface_temperature_solver.applyValidatedTile,
            );
            for (0..context.grid.cell_count) |cell| {
                const vapor_change_m3 = self.surface_temperature_work.atmospheric_vapor_water_change_m3[cell];
                const internal_vapor_change_m3 = self.surface_temperature_work.internal_vapor_water_change_m3[cell];
                const old_vapor_m3 = self.litter_vapor_water_equivalent_m3[cell];
                const new_vapor_m3 = old_vapor_m3 + internal_vapor_change_m3 + vapor_change_m3;
                if (!std.math.isFinite(new_vapor_m3) or new_vapor_m3 < 0)
                    return error.InvalidAcceptedSurfaceLitterVaporStorage;
                context.litter_gas_transport.water_vapor_mol[cell] = new_vapor_m3 *
                    context.runscript.soil_gas_transport_parameters.water_density_g_per_m3 /
                    context.runscript.soil_gas_transport_parameters.water_molar_mass_g_per_mol;
                if (!std.math.isFinite(context.litter_gas_transport.water_vapor_mol[cell]) or
                    context.litter_gas_transport.water_vapor_mol[cell] < 0)
                    return error.InvalidAcceptedSurfaceLitterVaporStorage;
            }
            for (0..context.grid.cell_count) |cell| {
                const new_water_m3 = context.surface_precipitation.litter_water_m3[cell];
                const allowance = try ecosys.surface_litter_chemistry_carrier_rebase.previewCellWaterRoundoffFromScaleSource(
                    context.surface_litter_chemistry,
                    cell,
                    self.surface_liquid_water_before_temperature_m3[cell],
                    new_water_m3 - self.surface_temperature_work.liquid_water_change_m3[cell],
                    new_water_m3,
                    try surfaceChemistryRebaseInventoryInputs(context, cell),
                );
                try self.accumulateSurfaceChemistryRebaseRoundoff(cell, allowance);
            }
            if (self.context.executed_weather_hours.* >= 2656 and self.context.executed_weather_hours.* < 2659)
                try diagnostics.logPhosphorusRepresentation(self.context, "snow_disappearance_before_litter_rebase");
            try ecosys.surface_litter_chemistry_carrier_rebase.rebaseFromAcceptedLiquidWaterChange(
                context.surface_litter_chemistry,
                context.surface_precipitation.litter_water_m3,
                self.surface_temperature_work.liquid_water_change_m3,
            );
            try self.refreshSurfaceHeatCapacity();

            @memcpy(context.soil_hourly_workspace.cell_heat_source_megajoules, self.base_cell_heat_source_megajoules);
            @memset(context.soil_hourly_workspace.published_surface_conduction_heat_megajoules, 0);
            for (0..context.grid.cell_count) |cell| {
                const top = cell * context.grid.soil_layer_capacity;
                // EVAPR2W is the litter-owned atmospheric lane solved inside
                // the surface Newton residual.  Its water, latent heat and
                // donor-temperature carrier heat therefore share one cap and
                // one accepted temperature.
                self.forcing.accepted_litter_vapor_change_m3[cell] =
                    self.surface_temperature_work.atmospheric_vapor_water_change_m3[cell] +
                    self.surface_temperature_work.vapor_liquid_water_change_m3[cell];
                const rate = -self.surface_temperature_work.conductive_heat_flux_megajoules_per_m2[cell] *
                    context.canopy_cell_area_m2[cell];
                context.soil_hourly_workspace.cell_heat_source_megajoules[top] =
                    try checkedAddFiniteValue(context.soil_hourly_workspace.cell_heat_source_megajoules[top], rate);
                context.soil_hourly_workspace.published_surface_conduction_heat_megajoules[top] = rate;
                self.surface_conduction_total_megajoules[top] = try checkedAddFiniteValue(
                    self.surface_conduction_total_megajoules[top],
                    rate * time_step_hours,
                );
                // Endpoint-capacity storage already carries the accepted
                // temperature-dependent liquid/ice sensible difference. The
                // remaining enthalpy-census reference is fixed at Tm, so it
                // sums exactly across any recovery substep schedule.
                const phase_sensible_adjustment_megajoules =
                    (context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k -
                        ice_heat_capacity_per_water_equivalent_m3_k) *
                    context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k *
                    self.surface_temperature_work.ice_water_equivalent_change_m3[cell];
                self.surface_phase_sensible_adjustment_total_megajoules_by_cell[cell] =
                    try checkedAddFiniteValue(
                        self.surface_phase_sensible_adjustment_total_megajoules_by_cell[cell],
                        phase_sensible_adjustment_megajoules,
                    );
                // Represented litter vapor storage is inventoried with its
                // liquid sensible carrier only. FLVR is an internal
                // liquid<->vapor transfer, so retain the opposite latent heat
                // for each accepted substep rather than reconstructing it from
                // a net carrier after temperatures and direction may change.
                const internal_vapor_latent_heat_megajoules =
                    -context.runscript.ground_air_parameters.liquid_water_latent_heat_megajoules_per_m3 *
                    self.surface_temperature_work.internal_vapor_water_change_m3[cell];
                self.surface_internal_vapor_latent_heat_total_megajoules_by_cell[cell] =
                    try checkedAddFiniteValue(
                        self.surface_internal_vapor_latent_heat_total_megajoules_by_cell[cell],
                        internal_vapor_latent_heat_megajoules,
                    );
                // Same FLVR2 term the source model puts inside EFLXR2
                // (`watsub.f:3231`) and therefore inside the reported ground
                // latent heat `HEATE`/`TLES` (`watsub.f:4185`,
                // `redist.f:10629`). The expression above already carries the
                // source sign (FLVR2 is condensation-positive, so it is the
                // negative of the represented vapor change); publish it into
                // the reported-only lane without touching the residual lane
                // that every conservation gate and the boundary-air vapor
                // source consume.
                self.surface_temperature_total.latent_heat_outside_surface_residual_megajoules_per_m2[cell] =
                    try checkedAddFiniteValue(
                        self.surface_temperature_total.latent_heat_outside_surface_residual_megajoules_per_m2[cell],
                        internal_vapor_latent_heat_megajoules / context.canopy_cell_area_m2[cell],
                    );
                // Incoming atmospheric water is valued at its air donor
                // temperature by the boundary flux, then becomes surface
                // storage at the accepted surface temperature. The Newton
                // storage term uses the entry heat capacity, so retain that
                // carrier thermalization path explicitly. For evaporation the
                // donor is already the surface and the correction is zero.
                const atmospheric_water_change_m3 =
                    self.surface_temperature_work.atmospheric_vapor_water_change_m3[cell] +
                    self.surface_temperature_work.vapor_liquid_water_change_m3[cell];
                const donor_temperature_k = if (atmospheric_water_change_m3 >= 0)
                    context.ground_air.temperature_k[cell]
                else
                    context.grid.surface_temperature_k[cell];
                const atmospheric_water_thermalization_megajoules =
                    context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                    (context.grid.surface_temperature_k[cell] - donor_temperature_k) *
                    atmospheric_water_change_m3;
                self.surface_atmospheric_water_thermalization_total_megajoules_by_cell[cell] =
                    try checkedAddFiniteValue(
                        self.surface_atmospheric_water_thermalization_total_megajoules_by_cell[cell],
                        atmospheric_water_thermalization_megajoules,
                    );

                // Final-state convergence diagnostics are retained from the
                // last accepted substep. Extensive hourly diagnostics are the
                // sum of accepted rate*dt or the direct phase amount.
                self.surface_temperature_total.equilibrium_temperature_k[cell] = self.surface_temperature_work.equilibrium_temperature_k[cell];
                self.surface_temperature_total.snow_free_surface_albedo[cell] = self.surface_temperature_work.snow_free_surface_albedo[cell];
                self.surface_temperature_total.energy_residual_megajoules_per_m2[cell] = self.surface_temperature_work.energy_residual_megajoules_per_m2[cell];
                self.surface_temperature_total.residual_tolerance_megajoules_per_m2[cell] = self.surface_temperature_work.residual_tolerance_megajoules_per_m2[cell];
                self.surface_temperature_total.residual_has_adjacent_root_certificate[cell] = self.surface_temperature_work.residual_has_adjacent_root_certificate[cell];
                self.surface_temperature_total.residual_accepted_by_conservation_ceiling[cell] = self.surface_temperature_work.residual_accepted_by_conservation_ceiling[cell];
                self.surface_temperature_total.energy_conservation_tolerance_megajoules_per_m2[cell] = self.surface_temperature_work.energy_conservation_tolerance_megajoules_per_m2[cell];
                const surface_residual_megajoules =
                    self.surface_temperature_work.energy_residual_megajoules_per_m2[cell] *
                    time_step_hours * context.canopy_cell_area_m2[cell];
                self.surface_energy_residual_signed_total_megajoules_by_cell[cell] =
                    try checkedAddFiniteValue(
                        self.surface_energy_residual_signed_total_megajoules_by_cell[cell],
                        surface_residual_megajoules,
                    );
                self.surface_energy_residual_absolute_total_megajoules_by_cell[cell] =
                    try checkedAddFiniteValue(
                        self.surface_energy_residual_absolute_total_megajoules_by_cell[cell],
                        @abs(surface_residual_megajoules),
                    );
                // The retained residual is the accepted scalar solve's exact
                // energy mismatch in MJ m-2 h-1. Keep the constitutive flux
                // unchanged for every downstream solver, then publish the
                // opposite residual through the external atmospheric sensible
                // lane. This exact, tightly bounded correction closes the
                // ledger without perturbing the accepted physical state.
                self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2[cell] =
                    try checkedAddFiniteValue(
                        self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2[cell],
                        (self.surface_temperature_work.sensible_heat_flux_megajoules_per_m2[cell] -
                            self.surface_temperature_work.energy_residual_megajoules_per_m2[cell]) *
                            time_step_hours,
                    );
                inline for (.{
                    "latent_heat_flux_megajoules_per_m2",
                    "vapor_sensible_heat_flux_megajoules_per_m2",
                    "conductive_heat_flux_megajoules_per_m2",
                    "storage_heat_flux_megajoules_per_m2",
                }) |field_name| {
                    const total = &@field(self.surface_temperature_total, field_name)[cell];
                    total.* = try checkedAddFiniteValue(
                        total.*,
                        @field(self.surface_temperature_work, field_name)[cell] * time_step_hours,
                    );
                }
                inline for (.{
                    "phase_heat_flux_megajoules_per_m2",
                    "vapor_liquid_water_change_m3",
                    "atmospheric_vapor_water_change_m3",
                    "internal_vapor_water_change_m3",
                    "liquid_water_change_m3",
                    "ice_water_equivalent_change_m3",
                }) |field_name| {
                    const total = &@field(self.surface_temperature_total, field_name)[cell];
                    total.* = try checkedAddFiniteValue(total.*, @field(self.surface_temperature_work, field_name)[cell]);
                }
                self.surface_iteration_total[cell] = std.math.add(u32, self.surface_iteration_total[cell], self.surface_temperature_work.iteration_count[cell]) catch return error.SurfaceTemperatureIterationCountOverflow;
                self.surface_newton_total[cell] = std.math.add(u32, self.surface_newton_total[cell], self.surface_temperature_work.newton_raphson_step_count[cell]) catch return error.SurfaceTemperatureIterationCountOverflow;
                self.surface_picard_total[cell] = std.math.add(u32, self.surface_picard_total[cell], self.surface_temperature_work.picard_step_count[cell]) catch return error.SurfaceTemperatureIterationCountOverflow;
                inline for (.{
                    "downward_sky_longwave_megajoules_per_m2",
                    "emitted_sky_longwave_megajoules_per_m2",
                    "net_longwave_megajoules_per_m2",
                    "net_radiation_megajoules_per_m2",
                }) |field_name| {
                    const total = &@field(self.surface_energy_total, field_name)[cell];
                    total.* = try checkedAddFiniteValue(
                        total.*,
                        @field(self.surface_energy_work, field_name)[cell] * time_step_hours,
                    );
                }
            }
        }

        noinline fn postPhasePreHeat(
            raw: *anyopaque,
            time_step_hours: f64,
            grid: *ecosys.grid.GridState,
            hydrology: *ecosys.transport_hydrology.State,
            heat_source_megajoules: []f64,
            external_water_change_m3_by_layer: []f64,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(raw));
            const profile_active = !builtin.is_test and
                self.context.executed_weather_hours.* >= 48 and
                self.context.executed_weather_hours.* < 56;
            const profile_start = std.Io.Clock.now(.boot, self.context.io);
            defer {
                if (profile_active) self.temporary_profile_post_phase_ns +=
                    profile_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            }
            const context = self.context;
            if (grid != context.grid or hydrology != context.transport_hydrology or
                heat_source_megajoules.len != grid.layer_count or
                external_water_change_m3_by_layer.len != grid.layer_count)
                return error.PostPhaseTopsoilBoundaryDimensionMismatch;
            const ice_density = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3;
            for (0..grid.cell_count) |cell| {
                const top = try grid.layerIndex(cell, 0);
                const matrix_parameters = context.soil_solver_properties.mualem_van_genuchten_parameters[top];
                const matric_potential_mpa = try matrix_parameters.pressureHeadAtWaterContent(std.math.clamp(
                    grid.matrix_liquid_water_m3[top] /
                        context.soil_solver_properties.matrix_bulk_volume_m3[top],
                    matrix_parameters.residual_water_content_m3_per_m3,
                    matrix_parameters.saturated_water_content_m3_per_m3,
                )) * context.runscript.soil_process_parameters.gravitational_water_potential_mpa_per_m;
                const osmotic_potential_mpa = context.soil_hourly_workspace.osmotic_potential_megapascal[top];
                const matric_plus_osmotic = matric_potential_mpa + osmotic_potential_mpa;
                // ISSUE-024 ROUND 6 diagnostic (temporary; gated identically to
                // this file's existing thermal_trace_active pattern, so it is
                // zero-cost when verbose_diagnostics_enabled is false, and
                // silent after hour 1). Separates the matric and osmotic terms
                // feeding the shared TFREEZ/freezing_temperature formula for a
                // direct oracle-vs-Zig comparison (issue-024 round 5/6).
                if (!builtin.is_test and run_support.verbose_diagnostics_enabled and
                    context.executed_weather_hours.* < 1)
                {
                    std.log.info("MATRIC_TRACE024 hour={d} cell={d} layer={d} matric_mpa={e} osmotic_mpa={e} matric_plus_osmotic_mpa={e} liquid_m3={e} temperature_k={e}", .{
                        context.executed_weather_hours.* + 1,
                        cell,
                        top,
                        matric_potential_mpa,
                        osmotic_potential_mpa,
                        matric_plus_osmotic,
                        grid.matrix_liquid_water_m3[top],
                        grid.soil_temperature_k[top],
                    });
                }
                // WATSUB 2765--2879: FLVGS/freeze-thaw have already committed
                // in phase_solver; EVAPG now reads their accepted VOLV2/VOLW2.
                const topsoil_vapor = try ecosys.ground_vapor_exchange.accepted(.{
                    .time_step_hours = time_step_hours,
                    .vapor_conductance_m3_per_h = self.topsoil_vapor_conductance_m3_per_h[cell],
                    .air_vapor_volume_fraction = context.ground_air.vapor_volume_fraction[cell],
                    .vapor_fraction_conversion_k_per_kpa = context.runscript.ground_air_parameters.saturation_vapor_prefactor_k,
                    .air_temperature_k = context.ground_air.temperature_k[cell],
                    .owner_temperature_k = grid.soil_temperature_k[top],
                    .owner_air_volume_m3 = grid.air_volume_m3[top],
                    .owner_vapor_water_equivalent_m3 = grid.water_vapor_volume_m3[top],
                    .owner_water_potential_megapascal = matric_plus_osmotic,
                    .owner_liquid_water_m3 = grid.matrix_liquid_water_m3[top],
                    .surface_vapor_activity_fraction = context.runscript.surface_vapor_activity_fraction,
                    .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                    .latent_heat_of_vaporization_megajoules_per_m3 = context.runscript.ground_air_parameters.liquid_water_latent_heat_megajoules_per_m3,
                });
                const old_liquid_m3 = grid.matrix_liquid_water_m3[top];
                const next_liquid_m3 = old_liquid_m3 + topsoil_vapor.liquid_water_change_m3;
                const next_vapor_m3 = grid.water_vapor_volume_m3[top] + topsoil_vapor.vapor_water_change_m3;
                if (!std.math.isFinite(next_liquid_m3) or next_liquid_m3 < 0 or
                    !std.math.isFinite(next_vapor_m3) or next_vapor_m3 < 0)
                    return error.InvalidAcceptedTopsoilVaporStorage;
                const matrix_air_raw = grid.matrix_pore_capacity_m3[top] - next_liquid_m3 -
                    grid.matrix_ice_water_m3[top] / ice_density;
                const macro_air_raw = grid.macropore_pore_capacity_m3[top] - grid.macropore_liquid_water_m3[top] -
                    grid.macropore_ice_water_m3[top] / ice_density;
                const air_tolerance = context.config.physical_tolerance.water_volume_m3 +
                    context.config.physical_tolerance.relative *
                        (grid.matrix_pore_capacity_m3[top] + grid.macropore_pore_capacity_m3[top]);
                if (matrix_air_raw < -air_tolerance or macro_air_raw < -air_tolerance)
                    return error.AcceptedTopsoilVaporPoreOverfill;
                grid.matrix_liquid_water_m3[top] = next_liquid_m3;
                grid.liquid_water_m3[top] = next_liquid_m3 + grid.macropore_liquid_water_m3[top];
                grid.water_vapor_volume_m3[top] = next_vapor_m3;
                grid.matrix_air_volume_m3[top] = @max(0, matrix_air_raw);
                grid.macropore_air_volume_m3[top] = @max(0, macro_air_raw);
                grid.air_volume_m3[top] = grid.matrix_air_volume_m3[top] + grid.macropore_air_volume_m3[top];
                hydrology.micropore_water_volume_m3[top] = next_liquid_m3;
                hydrology.water_vapor_volume_m3[top] = next_vapor_m3;
                hydrology.matrix_air_volume_m3[top] = grid.matrix_air_volume_m3[top];
                hydrology.macropore_air_volume_m3[top] = grid.macropore_air_volume_m3[top];
                hydrology.air_volume_m3[top] = grid.air_volume_m3[top];
                self.forcing.accepted_topsoil_vapor_change_m3[cell] = topsoil_vapor.water_change_m3;
                self.forcing.accepted_topsoil_liquid_change_m3[cell] = topsoil_vapor.liquid_water_change_m3;
                external_water_change_m3_by_layer[top] = topsoil_vapor.water_change_m3;
                if (topsoil_vapor.liquid_water_change_m3 != 0 or
                    topsoil_vapor.vapor_water_change_m3 != 0)
                {
                    try self.incrementWaterStorageUpdate(.{
                        .kind = .soil_layer,
                        .cell = cell,
                        .layer = 0,
                    }, 1);
                }
                // Refresh VHCPG2 from the phase/water owners actually present
                // at this split-stage boundary, not the top-of-hour capacity.
                const topsoil_capacity = context.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[top] *
                    context.soil_solver_properties.layer_volume_m3[top] +
                    context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                        (grid.matrix_liquid_water_m3[top] + grid.macropore_liquid_water_m3[top] + grid.water_vapor_volume_m3[top]) +
                    (try ecosys.ice_units.heatCapacityPerWaterEquivalentM3K(
                        context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                        ice_density,
                    )) * (grid.matrix_ice_water_m3[top] + grid.macropore_ice_water_m3[top]);
                const snow_top = cell * context.snow_transport.layer_capacity;
                self.sensible_pair_capacity_megajoules_per_k[cell] = .{
                    context.surface_heat_capacity_megajoules_per_k[cell],
                    topsoil_capacity,
                    if (context.snow_transport.active[snow_top] and
                        context.snow_transport.heat_capacity_megajoules_per_k[snow_top] >
                            ecosys.snow_solute_transport.activation_heat_capacity_megajoules_per_m2_k * context.snow_transport.horizontal_area_m2[snow_top])
                        context.snow_transport.heat_capacity_megajoules_per_k[snow_top]
                    else
                        0,
                };
                self.sensible_pair_temperature_k[cell] = .{
                    grid.surface_temperature_k[cell],
                    grid.soil_temperature_k[top],
                    if (context.snow_transport.active[snow_top]) context.snow_transport.temperature_k[snow_top] else grid.surface_temperature_k[cell],
                };
                const raw_conductances = [_]f64{
                    self.litter_sensible_conductance_megajoules_per_h_k[cell],
                    self.topsoil_sensible_conductance_megajoules_per_h_k[cell],
                    self.snow_sensible_conductance_megajoules_per_h_k[cell],
                };
                for (raw_conductances, self.sensible_pair_capacity_megajoules_per_k[cell], &self.sensible_pair_conductance_megajoules_per_h_k[cell]) |conductance, capacity, *effective| {
                    effective.* = try ecosys.ground_air_exchange.finiteSurfaceSensibleConductance(conductance, capacity, time_step_hours);
                }
                // Publishing the accepted water at the current soil
                // temperature already changes the canonical soil enthalpy by
                // Cl*Tsoil*dW. Feed only the remainder to the spatial heat
                // residual so carrier heat is represented exactly once.
                const represented_storage_heat = topsoil_vapor.water_change_m3 *
                    context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k *
                    grid.soil_temperature_k[top];
                heat_source_megajoules[top] = try checkedAddFiniteValue(
                    heat_source_megajoules[top],
                    topsoil_vapor.total_heat_megajoules - represented_storage_heat,
                );
                self.forcing.topsoil_vapor_heat_total_megajoules[cell] = try checkedAddFiniteValue(
                    self.forcing.topsoil_vapor_heat_total_megajoules[cell],
                    topsoil_vapor.total_heat_megajoules,
                );
                // Legacy EFLXG (`watsub.f:2894`) is part of the published
                // ground latent heat `HEATE`/`TLES` (`watsub.f:4185`,
                // `redist.f:10629`), but this topsoil lane's latent heat is
                // owned by `heat_source_megajoules` and the separate audited
                // `topsoil_atmospheric_heat_megajoules` ledger, so it never
                // reached the reported column. Publish only its latent part
                // (not `total_heat_megajoules`, which also carries the
                // donor-temperature carrier sensible heat that legacy books
                // into VFLXG/HEATV instead).
                self.surface_temperature_total.latent_heat_outside_surface_residual_megajoules_per_m2[cell] =
                    try checkedAddFiniteValue(
                        self.surface_temperature_total.latent_heat_outside_surface_residual_megajoules_per_m2[cell],
                        topsoil_vapor.latent_heat_megajoules / context.canopy_cell_area_m2[cell],
                    );
                self.forcing.topsoil_evaporation_total_m3[cell] = try checkedAddFiniteValue(
                    self.forcing.topsoil_evaporation_total_m3[cell],
                    topsoil_vapor.evaporation_m3,
                );
                self.forcing.topsoil_condensation_total_m3[cell] = try checkedAddFiniteValue(
                    self.forcing.topsoil_condensation_total_m3[cell],
                    topsoil_vapor.condensation_m3,
                );
                context.ground_surface_evaporation_m3_per_h[cell] = try checkedAddFiniteValue(
                    context.ground_surface_evaporation_m3_per_h[cell],
                    topsoil_vapor.evaporation_m3 / time_step_hours,
                );
                context.ground_surface_condensation_m3_per_h[cell] = try checkedAddFiniteValue(
                    context.ground_surface_condensation_m3_per_h[cell],
                    topsoil_vapor.condensation_m3 / time_step_hours,
                );
                context.ground_surface_topsoil_water_change_m3[cell] = try checkedAddFiniteValue(
                    context.ground_surface_topsoil_water_change_m3[cell],
                    topsoil_vapor.water_change_m3,
                );
            }
            try self.advanceGroundAir(time_step_hours);
            try self.applyPairedSurfaceSensibleHeat(time_step_hours, heat_source_megajoules);
            try self.validateGroundAirSurfaceVaporTransfer(time_step_hours);
        }

        /// Commit the equal-and-opposite Schur-complement transfers from the
        /// accepted air solve. Litter/snow receive sensible storage directly;
        /// topsoil heat remains in the existing enthalpy-solve source lane.
        noinline fn applyPairedSurfaceSensibleHeat(self: *Self, time_step_hours: f64, heat_source_megajoules: []f64) !void {
            const context = self.context;
            for (0..context.grid.cell_count) |cell| {
                var heat: [3]f64 = undefined;
                for (self.sensible_pair_conductance_megajoules_per_h_k[cell], self.sensible_pair_temperature_k[cell], &heat) |conductance, temperature, *value| {
                    value.* = try ecosys.ground_air_exchange.pairedSurfaceSensibleHeat(conductance, temperature, context.ground_air.temperature_k[cell], time_step_hours);
                }
                const air_heat = self.ground_air_step_vapor_balance[cell].implicit_non_atmospheric_sensible_heat_transfer_megajoules;
                const sum_heat = heat[0] + heat[1] + heat[2];
                const scale = @abs(air_heat) + @abs(heat[0]) + @abs(heat[1]) + @abs(heat[2]) +
                    time_step_hours * self.ground_air_combined_surface_sensible_conductance[cell] *
                        (@abs(context.ground_air.temperature_k[cell]) + @abs(self.ground_air_combined_surface_temperature_k[cell]));
                if (@abs(sum_heat + air_heat) > 128 * std.math.floatEps(f64) * scale)
                    return error.GroundAirSurfaceSensiblePairMismatch;

                const area = context.canopy_cell_area_m2[cell];
                const litter_capacity = self.sensible_pair_capacity_megajoules_per_k[cell][0];
                if (litter_capacity > 0) {
                    const temperature = self.sensible_pair_temperature_k[cell][0] + heat[0] / litter_capacity;
                    if (!std.math.isFinite(temperature) or temperature <= 0) return error.InvalidPairedSurfaceTemperature;
                    context.grid.surface_temperature_k[cell] = temperature;
                    context.litter_gas_transport.temperature_k[cell] = temperature;
                    self.surface_temperature_total.equilibrium_temperature_k[cell] = temperature;
                }
                self.surface_temperature_work.sensible_heat_flux_megajoules_per_m2[cell] = heat[0] / (area * time_step_hours);
                self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2[cell] = try checkedAddFiniteValue(self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2[cell], (heat[0] + heat[2]) / area);
                self.surface_temperature_total.storage_heat_flux_megajoules_per_m2[cell] = try checkedAddFiniteValue(self.surface_temperature_total.storage_heat_flux_megajoules_per_m2[cell], -heat[0] / area);
                const top = try context.grid.layerIndex(cell, 0);
                heat_source_megajoules[top] = try checkedAddFiniteValue(heat_source_megajoules[top], heat[1]);
                self.topsoil_sensible_heat_step_megajoules[cell] = heat[1];
                self.topsoil_sensible_heat_total_megajoules[cell] = try checkedAddFiniteValue(self.topsoil_sensible_heat_total_megajoules[cell], heat[1]);
                const snow_capacity = self.sensible_pair_capacity_megajoules_per_k[cell][2];
                if (snow_capacity > 0) {
                    const snow_top = cell * context.snow_transport.layer_capacity;
                    const temperature = self.sensible_pair_temperature_k[cell][2] + heat[2] / snow_capacity;
                    if (!std.math.isFinite(temperature) or temperature <= 0) return error.InvalidPairedSurfaceTemperature;
                    context.snow_transport.temperature_k[snow_top] = temperature;
                }
                self.snow_air_sensible_heat_megajoules[cell] = heat[2];
                self.snow_boundary_heat_total_megajoules[cell] = try checkedAddFiniteValue(self.snow_boundary_heat_total_megajoules[cell], heat[2]);
                if (!builtin.is_test and context.executed_weather_hours.* < 8) std.log.info("THERMAL_PAIRED hour={d} dt_hours={e} air_temperature_k={e} litter_temperature_k={e} soil_temperature_k={e} litter_heat_megajoules={e} soil_heat_megajoules={e} snow_heat_megajoules={e} air_heat_megajoules={e}", .{ context.executed_weather_hours.* + 1, time_step_hours, context.ground_air.temperature_k[cell], context.grid.surface_temperature_k[cell], context.grid.soil_temperature_k[top], heat[0], heat[1], heat[2], air_heat });
            }
        }

        noinline fn advanceGroundAir(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            const expected_time_step_hours = 1.0 /
                @as(f64, @floatFromInt(self.exact_substep_count));
            if (time_step_hours != expected_time_step_hours)
                return error.InvalidGroundAirAcceptedSubstepDuration;
            try ecosys.snow_surface_atmosphere_exchange.prepareSurfaceSources(
                context.snow_transport,
                snowSurfaceExchangeParameters(context),
                .{
                    .fallback_temperature_k = context.grid.surface_temperature_k,
                    .vapor_fraction = self.ground_air_snow_surface_vapor_fraction,
                    .temperature_k = self.ground_air_snow_surface_temperature_k,
                },
            );

            @memset(context.ground_air_sensible_source_megajoules_per_h, 0);
            @memset(context.ground_air_vapor_source_m3_per_h, 0);
            if (context.canopy_air_exchange.*) |*canopy_air| if (context.canopy_airflow.*) |*airflow| if (context.canopy_precipitation_retention.*) |*retention| {
                for (0..context.grid.cell_count) |cell| {
                    var total_canopy_exposure: f64 = 0;
                    for (0..context.config.plant_populations) |population| {
                        const population_index = cell * context.config.plant_populations + population;
                        total_canopy_exposure += retention.living_radiation_fraction[population_index] + retention.standing_dead_radiation_fraction[population_index];
                    }
                    for (0..context.config.plant_populations) |species| {
                        const plant = cell * context.config.plant_populations + species;
                        const canopy_share = if (total_canopy_exposure > 1.0e-12) retention.living_radiation_fraction[plant] / total_canopy_exposure else 0;
                        if (canopy_share <= 1.0e-12) continue;
                        const resistance_h_per_m = airflow.resistance_below_species_h_per_m[plant];
                        if (resistance_h_per_m <= 0) return error.InvalidCanopyGroundAirResistance;
                        const sensible_conductance = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell] / resistance_h_per_m * total_canopy_exposure * canopy_share;
                        const vapor_conductance = airflow.latent_boundary_numerator_m2_per_h[cell] / resistance_h_per_m * total_canopy_exposure * canopy_share;
                        context.ground_air_sensible_source_megajoules_per_h[cell] += sensible_conductance * (canopy_air.temperature_k[plant] - context.ground_air.temperature_k[cell]);
                        context.ground_air_vapor_source_m3_per_h[cell] += vapor_conductance * (canopy_air.vapor_fraction[plant] - context.ground_air.vapor_volume_fraction[cell]);
                    }
                }
            };
            if (context.standing_dead_air_exchange.*) |*dead_air| if (context.canopy_airflow.*) |*airflow| if (context.canopy_precipitation_retention.*) |*retention| {
                for (0..context.grid.cell_count) |cell| {
                    var total_canopy_exposure: f64 = 0;
                    for (0..context.config.plant_populations) |population| {
                        const population_index = cell * context.config.plant_populations + population;
                        total_canopy_exposure += retention.living_radiation_fraction[population_index] + retention.standing_dead_radiation_fraction[population_index];
                    }
                    for (0..context.config.plant_populations) |species| {
                        const plant = cell * context.config.plant_populations + species;
                        const dead_share = if (total_canopy_exposure > 1.0e-12) retention.standing_dead_radiation_fraction[plant] / total_canopy_exposure else 0;
                        if (dead_share <= 1.0e-12) continue;
                        const resistance_h_per_m = airflow.resistance_below_standing_dead_h_per_m[plant];
                        if (resistance_h_per_m <= 0) return error.InvalidStandingDeadGroundAirResistance;
                        const sensible_conductance = airflow.sensible_boundary_numerator_megajoules_per_m_h_k[cell] / resistance_h_per_m * total_canopy_exposure * dead_share;
                        const vapor_conductance = airflow.latent_boundary_numerator_m2_per_h[cell] / resistance_h_per_m * total_canopy_exposure * dead_share;
                        context.ground_air_sensible_source_megajoules_per_h[cell] += sensible_conductance * (dead_air.temperature_k[plant] - context.ground_air.temperature_k[cell]);
                        context.ground_air_vapor_source_m3_per_h[cell] += vapor_conductance * (dead_air.vapor_fraction[plant] - context.ground_air.vapor_volume_fraction[cell]);
                    }
                }
            };

            for (0..context.grid.cell_count) |cell| {
                const bottom = (cell + 1) * context.snow_transport.layer_capacity - 1;
                const snow_fraction = (try ecosys.snow_cover_fraction.evaluate(
                    context.snow_transport.cumulative_depth_m[bottom],
                    context.runscript.snow_full_cover_depth_m,
                )).snow_fraction;
                if (!std.math.isFinite(snow_fraction) or snow_fraction < 0 or snow_fraction > 1)
                    return error.InvalidSnowCoverFraction;
                // Eliminate all finite-capacity sensible owners into this
                // one air Newton-Anderson equation. Vapor transfers remain
                // independently accepted, donor-limited prescribed sources.
                var total_conductance: f64 = 0;
                var weighted_temperature: f64 = 0;
                for (self.sensible_pair_conductance_megajoules_per_h_k[cell], self.sensible_pair_temperature_k[cell]) |conductance, temperature| {
                    total_conductance += conductance;
                    weighted_temperature += conductance * temperature;
                }
                self.ground_air_combined_surface_sensible_conductance[cell] = total_conductance;
                self.ground_air_combined_surface_temperature_k[cell] = if (total_conductance > 0)
                    weighted_temperature / total_conductance
                else
                    context.ground_air.temperature_k[cell];
                const snow_to_air_water_rate =
                    (self.snow_evaporation_m3[cell] - self.snow_condensation_m3[cell]) /
                    time_step_hours;
                context.ground_air_surface_sensible_conductance_megajoules_per_h_k[cell] = total_conductance;
                context.ground_air_vapor_source_m3_per_h[cell] = try checkedAddFiniteValue(
                    context.ground_air_vapor_source_m3_per_h[cell],
                    -(self.forcing.accepted_litter_vapor_change_m3[cell] +
                        self.forcing.accepted_topsoil_vapor_change_m3[cell]) / time_step_hours +
                        snow_to_air_water_rate,
                );
                context.ground_air_surface_vapor_conductance_m3_per_h[cell] = 0;
                self.ground_air_combined_surface_vapor_conductance[cell] = 0;
                const surface_temperature_k = context.grid.surface_temperature_k[cell];
                context.ground_air_surface_vapor_fraction[cell] = try ecosys.ground_air_exchange.surfaceVaporFractionWithKelvinSuppression(
                    surface_temperature_k,
                    context.surface_litter_water_environment.matric_plus_osmotic_water_potential_megapascal[cell],
                    context.runscript.surface_vapor_activity_fraction,
                    context.runscript.ground_air_parameters,
                );
                self.ground_air_combined_surface_vapor_fraction[cell] = self.ground_air_snow_surface_vapor_fraction[cell];
            }

            for (0..context.grid.cell_count) |cell| {
                const entry_sensible_heat_megajoules =
                    context.ground_air.temperature_k[cell] *
                    context.ground_air.heat_capacity_megajoules_per_k[cell];
                if (!std.math.isFinite(entry_sensible_heat_megajoules))
                    return error.NonFiniteGroundAirEnergyInput;
                self.ground_air_step_entry_sensible_heat_megajoules[cell] =
                    entry_sensible_heat_megajoules;
            }
            try ecosys.ground_air_exchange.solve(context.ground_air, .{
                .atmospheric_temperature_k = context.atmosphere.air_temperature_k,
                .atmospheric_vapor_volume_fraction = context.atmospheric_vapor_fraction,
                .cell_area_m2 = context.canopy_cell_area_m2,
                .bulk_richardson_coefficient_k = context.surface_aerodynamics.bulk_richardson_coefficient_k,
                .neutral_atmospheric_resistance_h_per_m = context.surface_aerodynamics.isothermal_aerodynamic_resistance_h_per_m,
                .canopy_resistance_h_per_m = context.ground_air_canopy_resistance_h_per_m,
                .non_atmospheric_sensible_heat_megajoules_per_h = context.ground_air_sensible_source_megajoules_per_h,
                .non_atmospheric_vapor_flux_m3_per_h = context.ground_air_vapor_source_m3_per_h,
                .non_atmospheric_sensible_conductance_megajoules_per_h_k = self.ground_air_combined_surface_sensible_conductance,
                .non_atmospheric_sensible_source_temperature_k = self.ground_air_combined_surface_temperature_k,
                .non_atmospheric_vapor_conductance_m3_per_h = self.ground_air_combined_surface_vapor_conductance,
                .non_atmospheric_vapor_source_fraction = self.ground_air_combined_surface_vapor_fraction,
            }, context.runscript.ground_air_parameters, .{
                .absolute_tolerance = context.config.nonlinear_tolerance.heat_megajoules,
                .relative_tolerance = context.config.nonlinear_tolerance.relative,
                .max_iterations = context.iteration_limits.water_heat_solute_max_iterations,
                .picard_relaxation = context.config.picard_relaxation,
                .residual_scale = 1,
            }, .{
                .absolute_water_depth_m = context.config.mass_balance_absolute_tolerance.water_m,
                .relative = context.config.mass_balance_relative_tolerance,
                .accept_bounded_zero_vapor_state = true,
            }, .{
                .absolute_megajoules_per_m2 = context.config.mass_balance_absolute_tolerance.heat_megajoules_m2,
                .relative = context.config.mass_balance_relative_tolerance,
                .accept_bounded_temperature_state = false,
                // Physical-acceptance goal (2026-09-04): a Newton-Anderson
                // ceiling failure here is checked against the exact same
                // sensible-energy closure gate that already governs every
                // converged root, instead of unconditionally propagating
                // into the substep recovery ladder. No new tolerance; see
                // ground_air_exchange.zig's EnergyConservationTolerances.
                .accept_physically_conserved_ceiling = true,
            }, time_step_hours);

            @memcpy(self.ground_air_step_vapor_balance, context.ground_air.vapor_balance);
            for (0..context.grid.cell_count) |cell| {
                const step = context.ground_air.vapor_balance[cell];
                const total = &self.ground_air_vapor_balance_total[cell];
                try accumulateGroundAirSubstepBalance(total, step);
                const final_sensible_heat_megajoules =
                    context.ground_air.temperature_k[cell] *
                    context.ground_air.heat_capacity_megajoules_per_k[cell];
                const transfer_activity_megajoules =
                    @abs(step.atmospheric_sensible_heat_transfer_megajoules) +
                    @abs(step.prescribed_non_atmospheric_sensible_heat_transfer_megajoules) +
                    @abs(step.implicit_non_atmospheric_sensible_heat_transfer_megajoules);
                const storage_activity_megajoules = time_step_hours * @max(
                    @abs(self.ground_air_step_entry_sensible_heat_megajoules[cell]),
                    @abs(final_sensible_heat_megajoules),
                );
                const arithmetic_activity_megajoules =
                    @abs(self.ground_air_step_entry_sensible_heat_megajoules[cell]) +
                    @abs(final_sensible_heat_megajoules) +
                    @abs(step.sensible_heat_storage_change_megajoules) +
                    transfer_activity_megajoules +
                    @abs(step.sensible_heat_closure_residual_megajoules);
                self.ground_air_sensible_heat_closure_absolute_total_megajoules[cell] =
                    try checkedAddFiniteValue(
                        self.ground_air_sensible_heat_closure_absolute_total_megajoules[cell],
                        @abs(step.sensible_heat_closure_residual_megajoules),
                    );
                self.ground_air_sensible_heat_storage_activity_total_megajoules[cell] =
                    try checkedAddFiniteValue(
                        self.ground_air_sensible_heat_storage_activity_total_megajoules[cell],
                        storage_activity_megajoules,
                    );
                self.ground_air_sensible_heat_transfer_activity_total_megajoules[cell] =
                    try checkedAddFiniteValue(
                        self.ground_air_sensible_heat_transfer_activity_total_megajoules[cell],
                        transfer_activity_megajoules,
                    );
                self.ground_air_sensible_heat_arithmetic_activity_total_megajoules[cell] =
                    try checkedAddFiniteValue(
                        self.ground_air_sensible_heat_arithmetic_activity_total_megajoules[cell],
                        arithmetic_activity_megajoules,
                    );
                self.ground_air_iteration_total[cell] = std.math.add(u32, self.ground_air_iteration_total[cell], context.ground_air.iteration_count[cell]) catch return error.GroundAirIterationCountOverflow;
            }
            self.ground_air_accepted_substep_count = std.math.add(
                u8,
                self.ground_air_accepted_substep_count,
                1,
            ) catch return error.GroundAirAcceptedSubstepCountOverflow;
            self.ground_air_accepted_duration_hours = try checkedAddFiniteValue(
                self.ground_air_accepted_duration_hours,
                time_step_hours,
            );
            // Temperature/vapor are authoritative accepted state. Diagnostics
            // are schedule output and remain unchanged until all substeps pass.
            @memcpy(context.ground_air.vapor_balance, self.ground_air_published_vapor_balance);
            @memcpy(context.ground_air.iteration_count, self.ground_air_published_iterations);
        }

        noinline fn advanceSnowSurfaceEquilibrium(self: *Self, time_step_hours: f64) !void {
            _ = time_step_hours;
            const context = self.context;
            try ecosys.snow_surface_atmosphere_exchange.equilibrateSurface(
                self.allocator,
                context.snow_transport,
                snowSurfaceExchangeParameters(context),
                .{
                    .donor_availability_fraction = 1,
                    .latent_heat_megajoules = self.snow_latent_heat_megajoules,
                    .reference_state_heat_megajoules = self.snow_boundary_heat_megajoules,
                    .cell_area_m2 = context.canopy_cell_area_m2,
                    .energy_conservation_absolute_tolerance_megajoules_per_m2 = context.config.mass_balance_absolute_tolerance.heat_megajoules_m2,
                    .energy_conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                },
            );
            for (0..context.grid.cell_count) |cell| {
                const process_heat = self.snow_boundary_heat_megajoules[cell];
                const top = cell * context.snow_transport.layer_capacity;
                self.snow_vapor_equilibrium_heat_total_megajoules_by_layer[top] = try checkedAddFiniteValue(
                    self.snow_vapor_equilibrium_heat_total_megajoules_by_layer[top],
                    process_heat,
                );
                self.snow_vapor_heat_total_megajoules_by_cell[cell] = try checkedAddFiniteValue(
                    self.snow_vapor_heat_total_megajoules_by_cell[cell],
                    process_heat,
                );
                self.snow_vapor_heat_total_megajoules = try checkedAddFiniteValue(
                    self.snow_vapor_heat_total_megajoules,
                    process_heat,
                );
            }
        }

        noinline fn advanceSnowSurface(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            const parameters = snowSurfaceExchangeParameters(context);
            for (0..context.grid.cell_count) |cell| {
                const top = cell * context.snow_transport.layer_capacity;
                const bottom = top + context.snow_transport.layer_capacity - 1;
                const snow_fraction = (try ecosys.snow_cover_fraction.evaluate(
                    context.snow_transport.cumulative_depth_m[bottom],
                    context.runscript.snow_full_cover_depth_m,
                )).snow_fraction;
                // Evaluate snow against the saved substep-entry ground-air
                // state. The single aggregate ground-air solve follows EVAPG.
                var solid_m3: f64 = 0;
                var liquid_m3: f64 = 0;
                var ice_m3: f64 = 0;
                if (context.snow_transport.layer_capacity > 0) {
                    solid_m3 = context.snow_transport.solid_snow_water_equivalent_m3[top];
                    liquid_m3 = context.snow_transport.liquid_water_volume_m3[top];
                    ice_m3 = context.snow_transport.ice_volume_m3[top];
                }
                var living_canopy_temperature_k: []const f64 = &.{};
                var standing_dead_temperature_k: []const f64 = &.{};
                var living_canopy_radiation_fraction: []const f64 = &.{};
                var standing_dead_radiation_fraction: []const f64 = &.{};
                if (context.detailed_canopy.*) |*canopy| if (context.canopy_precipitation_retention.*) |*retention| {
                    const first = cell * context.config.plant_populations;
                    const last = first + context.config.plant_populations;
                    living_canopy_temperature_k = context.plants.canopy_temperature_k[first..last];
                    standing_dead_temperature_k = canopy.plant_standing_dead_surface_temperature_k[first..last];
                    living_canopy_radiation_fraction = retention.living_radiation_fraction[first..last];
                    standing_dead_radiation_fraction = retention.standing_dead_radiation_fraction[first..last];
                };
                const radiation = try ecosys.snow_surface_atmosphere_exchange.calculateNetRadiation(.{
                    .snow_cover_fraction = snow_fraction,
                    .cell_area_m2 = context.canopy_cell_area_m2[cell],
                    .incident_shortwave_megajoules_per_m2_h = context.ground_radiation.incident_shortwave_megajoules_per_m2[cell],
                    .atmospheric_longwave_megajoules_per_m2_h = context.atmosphere.longwave_radiation_megajoules_per_m2[cell],
                    .ground_exposure_fraction = if (context.canopy_exposure.*) |*exposure| exposure.ground_exposure_fraction[cell] else 1,
                    .snow_longwave_emissivity = context.runscript.snow_longwave_emissivity,
                    .stefan_boltzmann_megajoules_per_m2_h_k4 = 2.04e-10,
                    .snow_temperature_k = context.snow_transport.temperature_k[top],
                    .solid_snow_water_equivalent_m3 = solid_m3,
                    .liquid_water_m3 = liquid_m3,
                    .ice_volume_m3 = ice_m3,
                    .living_canopy_temperature_k = living_canopy_temperature_k,
                    .standing_dead_temperature_k = standing_dead_temperature_k,
                    .living_canopy_radiation_fraction = living_canopy_radiation_fraction,
                    .standing_dead_radiation_fraction = standing_dead_radiation_fraction,
                });
                self.snow_radiative_heat_megajoules_per_h[cell] = radiation.net_radiation_megajoules_per_h;
            }
            try ecosys.snow_surface_atmosphere_exchange.applyAccepted(self.allocator, context.snow_transport, parameters, .{
                .physical_time_step_hours = time_step_hours,
                // One accepted modern recovery pass may consume the current
                // donor inventory; this is not the legacy XNPS loop fraction.
                .donor_availability_fraction = 1,
                .cell_area_m2 = context.canopy_cell_area_m2,
                .energy_conservation_absolute_tolerance_megajoules_per_m2 = context.config.mass_balance_absolute_tolerance.heat_megajoules_m2,
                .energy_conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                .minimum_temperature_k = context.runscript.minimum_surface_temperature_k,
                .maximum_temperature_k = context.runscript.maximum_surface_temperature_k,
                .vapor_conductance_m3_per_h = self.snow_vapor_conductance_m3_per_h,
                .sensible_conductance_megajoules_per_h_k = self.deferred_sensible_conductance,
                .accepted_ground_air_vapor_fraction = context.ground_air.vapor_volume_fraction,
                .accepted_ground_air_temperature_k = context.ground_air.temperature_k,
                .radiative_heat_megajoules_per_h = self.snow_radiative_heat_megajoules_per_h,
                .evaporation_m3 = self.snow_evaporation_m3,
                .condensation_m3 = self.snow_condensation_m3,
                .boundary_heat_megajoules = self.snow_boundary_heat_megajoules,
                .latent_heat_megajoules = self.snow_latent_heat_megajoules,
                .carrier_sensible_heat_megajoules = self.snow_carrier_sensible_heat_megajoules,
                .air_sensible_heat_megajoules = self.snow_air_sensible_heat_megajoules,
                .radiative_heat_megajoules = self.snow_radiative_heat_megajoules,
            });
            try addFiniteSlices(self.snow_evaporation_total_m3, self.snow_evaporation_m3);
            try addFiniteSlices(self.snow_condensation_total_m3, self.snow_condensation_m3);
            try addFiniteSlices(
                self.snow_boundary_heat_total_megajoules,
                self.snow_boundary_heat_megajoules,
            );
            for (0..context.grid.cell_count) |cell| {
                const inverse_area = 1 / context.canopy_cell_area_m2[cell];
                context.ground_surface_evaporation_m3_per_h[cell] += self.snow_evaporation_m3[cell];
                context.ground_surface_condensation_m3_per_h[cell] += self.snow_condensation_m3[cell];
                self.surface_energy_total.net_radiation_megajoules_per_m2[cell] = try checkedAddFiniteValue(
                    self.surface_energy_total.net_radiation_megajoules_per_m2[cell],
                    self.snow_radiative_heat_megajoules[cell] * inverse_area,
                );
                self.surface_temperature_total.latent_heat_flux_megajoules_per_m2[cell] = try checkedAddFiniteValue(
                    self.surface_temperature_total.latent_heat_flux_megajoules_per_m2[cell],
                    self.snow_latent_heat_megajoules[cell] * inverse_area,
                );
                self.surface_temperature_total.vapor_sensible_heat_flux_megajoules_per_m2[cell] = try checkedAddFiniteValue(
                    self.surface_temperature_total.vapor_sensible_heat_flux_megajoules_per_m2[cell],
                    self.snow_carrier_sensible_heat_megajoules[cell] * inverse_area,
                );
                self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2[cell] = try checkedAddFiniteValue(
                    self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2[cell],
                    self.snow_air_sensible_heat_megajoules[cell] * inverse_area,
                );
                const reference_adjustment = try snowReferenceStateHeatMegajoules(
                    self.snow_boundary_heat_megajoules[cell],
                    self.snow_radiative_heat_megajoules[cell],
                    self.snow_latent_heat_megajoules[cell],
                    self.snow_carrier_sensible_heat_megajoules[cell],
                    self.snow_air_sensible_heat_megajoules[cell],
                );
                const next_reference_cell = self.snow_reference_state_heat_megajoules_by_cell[cell] + reference_adjustment;
                const next_reference_total = self.snow_reference_state_heat_megajoules + reference_adjustment;
                if (!std.math.isFinite(reference_adjustment) or !std.math.isFinite(next_reference_cell) or !std.math.isFinite(next_reference_total))
                    return error.NonFiniteSnowReferenceStateHeat;
                self.snow_reference_state_heat_megajoules_by_cell[cell] = next_reference_cell;
                self.snow_reference_state_heat_megajoules = next_reference_total;
            }
        }

        noinline fn validateGroundAirSurfaceVaporTransfer(self: *const Self, time_step_hours: f64) !void {
            const context = self.context;
            for (0..context.grid.cell_count) |cell| {
                const snow_to_air_m3 = self.snow_evaporation_m3[cell] - self.snow_condensation_m3[cell];
                const accepted_ground_air_transfer_m3 = self.ground_air_step_vapor_balance[cell].implicit_surface_transfer_m3;
                const accepted_prescribed_m3 = self.ground_air_step_vapor_balance[cell].prescribed_non_atmospheric_transfer_m3;
                const expected_prescribed_m3 = context.ground_air_vapor_source_m3_per_h[cell] *
                    time_step_hours;
                const scale_m3 = @max(
                    @max(@abs(snow_to_air_m3), @abs(accepted_ground_air_transfer_m3)),
                    @max(@abs(expected_prescribed_m3), @abs(accepted_prescribed_m3)),
                );
                const tolerance_m3 = context.config.mass_balance_absolute_tolerance.water_m * context.canopy_cell_area_m2[cell] +
                    context.config.mass_balance_relative_tolerance * scale_m3 +
                    32 * std.math.floatEps(f64) * scale_m3;
                inline for (.{ snow_to_air_m3, accepted_ground_air_transfer_m3, expected_prescribed_m3, accepted_prescribed_m3, tolerance_m3 }) |value|
                    if (!std.math.isFinite(value)) return error.NonFiniteGroundAirSurfaceVaporTransfer;
                if (@abs(accepted_ground_air_transfer_m3) > tolerance_m3 or
                    @abs(expected_prescribed_m3 - accepted_prescribed_m3) > tolerance_m3 or
                    @abs(snow_to_air_m3 -
                        (self.snow_evaporation_m3[cell] - self.snow_condensation_m3[cell])) > tolerance_m3)
                    return error.GroundAirSurfaceVaporTransferMismatch;
            }
        }

        noinline fn advanceTransport(
            self: *Self,
            time_step_hours: f64,
            litter_soil_water_flux_m3: []const f64,
        ) !void {
            const profile_active = !builtin.is_test and
                self.context.executed_weather_hours.* >= 48 and
                self.context.executed_weather_hours.* < 56;
            var profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceTransportInterfaceAndDiffusivity(
                time_step_hours,
                litter_soil_water_flux_m3,
            );
            if (profile_active) self.temporary_profile_replay_interface_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceAqueousSoluteTransport(time_step_hours);
            if (profile_active) self.temporary_profile_replay_aqueous_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceOrganicTransport(time_step_hours);
            if (profile_active) self.temporary_profile_replay_organic_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceMineralNitrogenTransport(time_step_hours);
            if (profile_active) self.temporary_profile_replay_mineral_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceDissolvedGasTransport(time_step_hours);
            if (profile_active) self.temporary_profile_replay_dissolved_gas_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.advanceSoilGasTransport(time_step_hours);
            if (profile_active) self.temporary_profile_replay_soil_gas_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
        }

        noinline fn advanceTransportInterfaceAndDiffusivity(
            self: *Self,
            time_step_hours: f64,
            litter_soil_water_flux_m3: []const f64,
        ) !void {
            const context = self.context;
            if (!std.math.isFinite(time_step_hours) or time_step_hours <= 0 or time_step_hours > 1)
                return error.InvalidCoupledTransportSubstep;
            try self.advanceLitterSoilInterface(time_step_hours, litter_soil_water_flux_m3);
            const reference_temperature_k: f64 = 298.15;
            const temperature_exponent: f64 = 6;
            const other_ion_diffusivity_m2_per_h: f64 = 5.0e-6;
            for (0..context.grid.layer_count) |layer| {
                const temperature_factor = std.math.pow(
                    f64,
                    context.grid.soil_temperature_k[layer] / reference_temperature_k,
                    temperature_exponent,
                );
                const diffusivity = other_ion_diffusivity_m2_per_h * temperature_factor;
                if (!std.math.isFinite(diffusivity) or diffusivity < 0)
                    return error.InvalidCoupledTransportDiffusivity;
                self.pore_diffusivity_m2_per_h[layer] = diffusivity;
            }
        }

        noinline fn advanceAqueousSoluteTransport(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            try ecosys.subsurface_irrigation_chemistry.addTransportedIonsFraction(
                context.irrigation_loads,
                context.micropore_solute_state,
                self.irrigation_parameters,
                time_step_hours,
            );
            try context.soil_solute_face_parameters.refresh(
                context.grid,
                context.soil_transport_faces,
                context.soil_face_geometry,
                context.soil_solver_properties.matrix_bulk_volume_m3,
                context.soil_solver_properties.bulk_density_megagrams_per_m3,
                time_step_hours,
                .{},
            );
            @memset(self.micropore_face_step_mol, 0);
            @memset(self.macropore_face_step_mol, 0);
            @memset(self.boundary_step_mol, 0);
            const transport_result = try ecosys.transport_step.advanceSoilSolutes(
                context.allocator,
                context.grid,
                context.transport_hydrology,
                context.soil_transport_faces,
                context.micropore_solute_state,
                context.macropore_solute_state,
                .{
                    .micropore_diffusive_conductance_m3_per_step = context.soil_solute_face_parameters.micropore_conductance_m3_per_step,
                    .macropore_diffusive_conductance_m3_per_step = context.soil_solute_face_parameters.macropore_conductance_m3_per_step,
                    .micropore_mobility_fraction = context.soil_solute_face_parameters.micropore_mobility_fraction,
                    .macropore_mobility_fraction = context.soil_solute_face_parameters.macropore_mobility_fraction,
                    .layer_volume_m3 = context.soil_solver_properties.layer_volume_m3,
                    .macropore_spacing_m = context.soil_hourly_workspace.macropore_spacing_m,
                    .micropore_diffusivity_m2_per_h = self.pore_diffusivity_m2_per_h,
                    .maximum_convective_fraction = 1,
                    .pore_exchange_step_fraction = time_step_hours,
                    .boundary_mobility_fraction = context.soil_solute_face_parameters.boundary_mobility_fraction,
                    .recharge_concentration_mol_per_m3 = context.soil_recharge_concentration_mol_per_m3,
                    .recharge_zone_fraction_provider = .{
                        .context = context.fertilizer_band,
                        .at = @TypeOf(context.fertilizer_band.*).scienceZoneFractionsForFlatIndexOpaque,
                    },
                    .boundary_net_flux_mol_by_cell = self.boundary_step_mol,
                    .micropore_face_flux_mol_by_component = self.micropore_face_step_mol,
                    .macropore_face_flux_mol_by_component = self.macropore_face_step_mol,
                    .conservation_absolute_tolerance_mol_per_m2 = context.config.mass_balance_absolute_tolerance.ions_mol_m2,
                    .conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                    .horizontal_cell_area_m2 = context.canopy_cell_area_m2,
                    .solver_options = .{
                        .absolute_tolerance_mol = context.config.nonlinear_tolerance.amount_mol,
                        .relative_tolerance = context.config.nonlinear_tolerance.relative,
                        .picard_relaxation = context.config.picard_relaxation,
                        .max_iterations = self.max_iterations,
                    },
                },
            );
            self.temporary_profile_aqueous_micropore_iterations += transport_result.micropore.iterations;
            self.temporary_profile_aqueous_macropore_iterations += transport_result.macropore.iterations;
            self.temporary_profile_aqueous_micropore_newton_steps += transport_result.micropore.newton_raphson_steps;
            self.temporary_profile_aqueous_macropore_newton_steps += transport_result.macropore.newton_raphson_steps;
            try addFiniteSlices(self.micropore_face_total_mol, self.micropore_face_step_mol);
            try addFiniteSlices(self.macropore_face_total_mol, self.macropore_face_step_mol);
            try addFiniteSlices(self.boundary_total_mol, self.boundary_step_mol);
            try ecosys.soil_aqueous_transport_bridge.importChemistry(
                context.micropore_solute_state,
                context.soil_chemistry,
                context.fertilizer_band,
                context.config.physical_tolerance.water_volume_m3,
            );
            try ecosys.subsurface_irrigation_chemistry.addPhosphateFractionWithZones(
                context.irrigation_loads,
                context.soil_chemistry,
                context.grid.matrix_liquid_water_m3,
                self.irrigation_parameters,
                context.fertilizer_band,
                time_step_hours,
            );
            // The four bare phosphate species are now first-class physical
            // transport owners. Publish each substep's irrigation increment
            // before a retry or following substep can re-import chemistry.
            for (0..context.grid.layer_count) |layer| {
                if (context.grid.matrix_liquid_water_m3[layer] == 0) continue;
                try ecosys.soil_aqueous_transport_bridge.synchronizeCellAfterCarrierChange(
                    context.soil_chemistry,
                    context.micropore_solute_state,
                    layer,
                    context.grid.matrix_liquid_water_m3[layer],
                    &.{ .non_band_hpo4, .non_band_h2po4, .band_hpo4, .band_h2po4 },
                    context.fertilizer_band,
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(
                        context.canopy_cell_area_m2[layer / context.grid.soil_layer_capacity],
                    ),
                );
            }
        }

        noinline fn advanceOrganicTransport(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            try context.soil_organic_face_parameters.refresh(
                context.grid,
                context.soil_transport_faces,
                context.soil_face_geometry,
                context.soil_solver_properties.matrix_bulk_volume_m3,
                context.soil_solver_properties.bulk_density_megagrams_per_m3,
                time_step_hours,
                .{},
            );
            _ = try ecosys.soil_organic_transport.advance(
                context.allocator,
                context.soil_organic_transport,
                context.soil_organic,
                context.soil_transport_faces,
                .{
                    .micropore_conductance_m3_per_step = context.soil_organic_face_parameters.micropore_conductance_m3_per_step,
                    .macropore_conductance_m3_per_step = context.soil_organic_face_parameters.macropore_conductance_m3_per_step,
                    .matrix_water_m3 = context.grid.matrix_liquid_water_m3,
                    .macropore_water_m3 = context.grid.macropore_liquid_water_m3,
                    .layer_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
                    .micropore_external_water_flux_m3_per_step = context.transport_hydrology.micropore_external_water_flux_m3_per_step,
                    .macropore_external_water_flux_m3_per_step = context.transport_hydrology.macropore_external_water_flux_m3_per_step,
                    .macropore_to_matrix_water_flux_m3_per_step = context.transport_hydrology.macropore_to_matrix_water_flux_m3_per_step,
                    .recharge_concentration_g_per_m3 = context.soil_organic_recharge_concentration_g_per_m3,
                    .micropore_face_flux_g_by_component = self.organic_micropore_face_step_g,
                    .macropore_face_flux_g_by_component = self.organic_macropore_face_step_g,
                },
                .{
                    .absolute_tolerance_g_by_component = .{
                        context.config.nonlinear_tolerance.carbon_g,
                        context.config.nonlinear_tolerance.nitrogen_g,
                        context.config.nonlinear_tolerance.phosphorus_g,
                        context.config.nonlinear_tolerance.carbon_g,
                    },
                    .relative_tolerance = context.config.nonlinear_tolerance.relative,
                    .picard_relaxation = context.config.picard_relaxation,
                    .max_iterations = context.iteration_limits.organic_transport_max_iterations,
                    .pore_exchange_fraction = time_step_hours,
                    .conservation_absolute_tolerance_g_per_m2_by_component = .{
                        context.config.mass_balance_absolute_tolerance.carbon_g_m2,
                        context.config.mass_balance_absolute_tolerance.nitrogen_g_m2,
                        context.config.mass_balance_absolute_tolerance.phosphorus_g_m2,
                        context.config.mass_balance_absolute_tolerance.carbon_g_m2,
                    },
                    .conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                    .soil_layer_capacity = context.grid.soil_layer_capacity,
                    .horizontal_cell_area_m2 = context.canopy_cell_area_m2,
                },
            );
            try addFiniteSlices(self.organic_boundary_total_g, context.soil_organic_transport.boundary_net_flux_g);
            try addFiniteSlices(self.organic_micropore_face_total_g, self.organic_micropore_face_step_g);
            try addFiniteSlices(self.organic_macropore_face_total_g, self.organic_macropore_face_step_g);
        }

        noinline fn advanceMineralNitrogenTransport(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            try ecosys.subsurface_irrigation_chemistry.addMineralNitrogenFractionWithZones(
                context.irrigation_loads,
                context.mineral_nitrogen_transport,
                self.irrigation_parameters,
                context.fertilizer_band,
                time_step_hours,
            );
            try context.mineral_nitrogen_face_parameters.refresh(
                context.grid,
                context.soil_transport_faces,
                context.soil_face_geometry,
                context.soil_solver_properties.matrix_bulk_volume_m3,
                context.soil_solver_properties.bulk_density_megagrams_per_m3,
                context.runscript.root_nutrient_parameters,
                time_step_hours,
            );
            // ISSUE-065 (seventeenth pass): the sixteenth addendum's handoff
            // named `mineral_nitrogen_transport.advance`'s output and its
            // booking into `hourly_layer_boundary_ledger` as the last
            // untraced nitrogen candidate. This brackets exactly the
            // `advance()` call: capture profile_cell 0's own extensive
            // storage (matrix+macropore, all eight species) immediately
            // before and after, plus the water carrier `advance()` actually
            // uses internally (`matrix.water_volume_m3[0]`, raw, per
            // `advance`'s own unconditional `@memcpy` from
            // `inputs.matrix_water_volume_m3`), so a rerun can directly
            // compare `advance()`'s own reported state change against the
            // face-flux/boundary-export values it reports for the SAME call
            // -- rather than continuing to infer the comparison from
            // `requireLocalConservation`'s pass/fail alone.
            const mineral_n_species_count = ecosys.mineral_nitrogen_transport.species_count;
            const nitrogen_trace_2894 = !builtin.is_test and
                context.executed_weather_hours.* >= 2888 and context.executed_weather_hours.* < 2896;
            var before_matrix_mol: f64 = 0;
            var before_macro_mol: f64 = 0;
            if (nitrogen_trace_2894) {
                for (context.mineral_nitrogen_transport.matrix.amount_mol[0..mineral_n_species_count]) |v| before_matrix_mol += v;
                for (context.mineral_nitrogen_transport.macropore.amount_mol[0..mineral_n_species_count]) |v| before_macro_mol += v;
            }
            _ = try ecosys.mineral_nitrogen_transport.advance(context.allocator, context.mineral_nitrogen_transport, .{
                .active_by_layer = context.soil_transport_faces.active_by_layer,
                .matrix_water_volume_m3 = context.grid.matrix_liquid_water_m3,
                .macropore_water_volume_m3 = context.grid.macropore_liquid_water_m3,
                .layer_volume_m3 = context.soil_solver_properties.layer_volume_m3,
                .macropore_spacing_m = context.soil_hourly_workspace.macropore_spacing_m,
                .micropore_diffusivity_m2_per_h = self.pore_diffusivity_m2_per_h,
                .matrix_faces = context.soil_transport_faces.micropore_faces,
                .macropore_faces = context.soil_transport_faces.macropore_faces,
                .matrix_conductance_m3_per_step = context.mineral_nitrogen_face_parameters.matrix_conductance_m3_per_step,
                .macropore_conductance_m3_per_step = context.mineral_nitrogen_face_parameters.macropore_conductance_m3_per_step,
                .mobility_fraction = context.mineral_nitrogen_face_parameters.mobility_fraction,
                .matrix_external_water_flux_m3_per_step = context.transport_hydrology.micropore_external_water_flux_m3_per_step,
                .macropore_external_water_flux_m3_per_step = context.transport_hydrology.macropore_external_water_flux_m3_per_step,
                .macropore_to_matrix_water_flux_m3_per_step = context.transport_hydrology.macropore_to_matrix_water_flux_m3_per_step,
                .maximum_convective_fraction = 1,
                .pore_exchange_step_fraction = time_step_hours,
                .nitrogen_molar_mass_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                .conservation_absolute_tolerance_g_n_per_m2 = context.config.mass_balance_absolute_tolerance.nitrogen_g_m2,
                .conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                .soil_layer_capacity = context.grid.soil_layer_capacity,
                .horizontal_cell_area_m2 = context.canopy_cell_area_m2,
                .solver_options = .{
                    .absolute_tolerance_mol = context.config.nonlinear_tolerance.amount_mol,
                    .relative_tolerance = context.config.nonlinear_tolerance.relative,
                    .picard_relaxation = context.config.picard_relaxation,
                    .max_iterations = self.max_iterations,
                },
                .matrix_face_flux_mol_by_component = self.mineral_micropore_face_step_mol,
                .macropore_face_flux_mol_by_component = self.mineral_macropore_face_step_mol,
            });
            if (nitrogen_trace_2894) {
                var after_matrix_mol: f64 = 0;
                var after_macro_mol: f64 = 0;
                for (context.mineral_nitrogen_transport.matrix.amount_mol[0..mineral_n_species_count]) |v| after_matrix_mol += v;
                for (context.mineral_nitrogen_transport.macropore.amount_mol[0..mineral_n_species_count]) |v| after_macro_mol += v;
                // Net mol flowing INTO profile_cell 0 across every face this
                // call touched (matrix and macropore), signed per
                // `recordFaceTransfers`' own convention: positive flux moves
                // first_cell -> second_cell.
                var net_face_in_mol: f64 = 0;
                for (context.soil_transport_faces.micropore_faces, 0..) |face, face_index| {
                    if (face.first_cell != 0 and face.second_cell != 0) continue;
                    const start = face_index * mineral_n_species_count;
                    for (self.mineral_micropore_face_step_mol[start..][0..mineral_n_species_count]) |flux|
                        net_face_in_mol += if (face.first_cell == 0) -flux else flux;
                }
                for (context.soil_transport_faces.macropore_faces, 0..) |face, face_index| {
                    if (face.first_cell != 0 and face.second_cell != 0) continue;
                    const start = face_index * mineral_n_species_count;
                    for (self.mineral_macropore_face_step_mol[start..][0..mineral_n_species_count]) |flux|
                        net_face_in_mol += if (face.first_cell == 0) -flux else flux;
                }
                const boundary_export_g = context.mineral_nitrogen_transport.boundary_export_g_n_per_step[0];
                const boundary_export_mol = boundary_export_g / context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol;
                const storage_before_mol = before_matrix_mol + before_macro_mol;
                const storage_after_mol = after_matrix_mol + after_macro_mol;
                const storage_delta_mol = storage_after_mol - storage_before_mol;
                const implied_delta_mol = net_face_in_mol - boundary_export_mol;
                std.log.info(
                    "DRY_CARRIER_TRACE site=mineral_nitrogen_advance_call hour={d} cell=0 layer=0 storage_before_mol={e} storage_after_mol={e} storage_delta_mol={e} net_face_flux_in_mol={e} boundary_export_g_n={e} implied_delta_mol={e} residual_mol={e} matrix_water_volume_m3={e} live_water_m3={e} dry_reference_water_m3={e}",
                    .{
                        context.executed_weather_hours.* + 1,
                        storage_before_mol,
                        storage_after_mol,
                        storage_delta_mol,
                        net_face_in_mol,
                        boundary_export_g,
                        implied_delta_mol,
                        storage_delta_mol - implied_delta_mol,
                        context.mineral_nitrogen_transport.matrix.water_volume_m3[0],
                        context.grid.matrix_liquid_water_m3[0],
                        context.soil_chemistry.dry_reference_water_m3[0],
                    },
                );
            }
            try context.mineral_nitrogen_transport.publishMatrix(
                context.soil_chemistry,
                context.soil_reactive_nitrogen,
                context.fertilizer_band,
                context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                context.config.physical_tolerance.water_volume_m3,
            );
            try addFiniteSlices(self.mineral_boundary_total_g_n, context.mineral_nitrogen_transport.boundary_export_g_n_per_step);
            try addFiniteSlices(self.mineral_micropore_face_total_mol, self.mineral_micropore_face_step_mol);
            try addFiniteSlices(self.mineral_macropore_face_total_mol, self.mineral_macropore_face_step_mol);

            // ZNH3S/ZNH3B remain mineral-N owned. The gas solver receives an
            // exact g-N mirror only for its coupled gas/water phase equations;
            // generic dissolved-gas transport excludes this species.
            try ecosys.soil_ammonia_phase_bridge.refreshTransientFromMineral(
                context.mineral_nitrogen_transport,
                context.gas_transport,
                context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            );
        }

        noinline fn advanceDissolvedGasTransport(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            try context.soil_dissolved_gas_face_parameters.refresh(
                context.grid,
                context.soil_transport_faces,
                context.soil_face_geometry,
                context.soil_solver_properties.matrix_bulk_volume_m3,
                context.soil_solver_properties.bulk_density_megagrams_per_m3,
                time_step_hours,
                .{},
            );
            _ = try ecosys.soil_dissolved_gas_transport.advance(
                context.allocator,
                context.soil_dissolved_gas_transport,
                context.gas_transport,
                .{
                    .faces = context.soil_transport_faces,
                    .micropore_conductance_m3_per_step = context.soil_dissolved_gas_face_parameters.micropore_conductance_m3_per_step,
                    .macropore_conductance_m3_per_step = context.soil_dissolved_gas_face_parameters.macropore_conductance_m3_per_step,
                    .micropore_water_m3 = context.grid.matrix_liquid_water_m3,
                    .macropore_water_m3 = context.grid.macropore_liquid_water_m3,
                    .layer_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
                    .micropore_external_water_flux_m3_per_step = context.transport_hydrology.micropore_external_water_flux_m3_per_step,
                    .macropore_external_water_flux_m3_per_step = context.transport_hydrology.macropore_external_water_flux_m3_per_step,
                    .macropore_to_matrix_water_flux_m3_per_step = context.transport_hydrology.macropore_to_matrix_water_flux_m3_per_step,
                    .recharge_concentration_g_per_m3 = context.soil_dissolved_gas_recharge_concentration_g_per_m3,
                },
                .{
                    .absolute_tolerance_by_species = &.{
                        context.config.nonlinear_tolerance.carbon_g,
                        context.config.nonlinear_tolerance.carbon_g,
                        context.config.nonlinear_tolerance.oxygen_g,
                        context.config.nonlinear_tolerance.nitrogen_g,
                        context.config.nonlinear_tolerance.nitrogen_g,
                        context.config.nonlinear_tolerance.nitrogen_g,
                        context.config.nonlinear_tolerance.solute_g,
                    },
                    .relative_tolerance = context.config.nonlinear_tolerance.relative,
                    .conservation_absolute_tolerance_g_per_m2_by_species = &.{
                        context.config.mass_balance_absolute_tolerance.carbon_g_m2,
                        context.config.mass_balance_absolute_tolerance.carbon_g_m2,
                        context.config.mass_balance_absolute_tolerance.oxygen_g_m2,
                        context.config.mass_balance_absolute_tolerance.nitrogen_g_m2,
                        context.config.mass_balance_absolute_tolerance.nitrogen_g_m2,
                        context.config.mass_balance_absolute_tolerance.nitrogen_g_m2,
                        context.config.mass_balance_absolute_tolerance.hydrogen_g_m2,
                    },
                    .conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                    .soil_layer_capacity = context.grid.soil_layer_capacity,
                    .horizontal_cell_area_m2 = context.canopy_cell_area_m2,
                    .picard_relaxation = context.config.picard_relaxation,
                    .max_iterations = context.iteration_limits.gas_max_iterations,
                    .pore_exchange_fraction = time_step_hours,
                    .micropore_face_flux_by_component = self.dissolved_gas_micropore_face_step_g,
                    .macropore_face_flux_by_component = self.dissolved_gas_macropore_face_step_g,
                },
            );
            try addFiniteSlices(self.dissolved_gas_boundary_total_g, context.soil_dissolved_gas_transport.boundary_net_flux_g);
            try addFiniteSlices(self.dissolved_gas_micropore_face_total_g, self.dissolved_gas_micropore_face_step_g);
            try addFiniteSlices(self.dissolved_gas_macropore_face_total_g, self.dissolved_gas_macropore_face_step_g);
        }

        noinline fn advanceSoilGasTransport(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            const temporary_profile_active = !builtin.is_test and
                context.executed_weather_hours.* >= 48 and
                context.executed_weather_hours.* < 56;
            const gas_result = try context.soil_gas_transport.advance(.{
                .grid = context.grid,
                .hydrology = context.transport_hydrology,
                .soil_faces = context.soil_transport_faces,
                .geometry = context.soil_face_geometry,
                .matrix_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3,
                .total_porosity_fraction = context.soil_solver_properties.porosity_fraction,
                .field_capacity_fraction = context.soil_field_capacity_fraction,
                .gas_state = context.gas_transport,
                .solubility_parameters = context.surface_gas_parameters.*.solubility,
                .exchange_parameters = context.surface_gas_parameters.*.exchange,
                .ice_density_megagrams_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3,
                .ammonium_band_fraction_provider = .{
                    .context = context.fertilizer_band,
                    .at = @TypeOf(context.fertilizer_band.*).scienceAmmoniumBandFractionForFlatIndexOpaque,
                },
                .surface_boundary_inputs = .{
                    .atmospheric_conductance_m3_per_step = context.soil_atmospheric_gas_conductance_m3_per_h,
                    .cell_area_m2 = context.canopy_cell_area_m2,
                    .top_layer_thickness_m = context.soil_solver_properties.layer_thickness_m,
                    .atmospheric_concentration_g_per_m3 = context.current_atmospheric_gas_concentration_g_per_m3,
                },
                .subsurface_boundary_inputs = .{
                    .topology = context.soil_boundary_topology,
                    .layer_thickness_m = context.soil_solver_properties.layer_thickness_m,
                    .external_concentration_g_per_m3 = context.current_atmospheric_gas_concentration_g_per_m3,
                },
                .parameters = context.runscript.soil_gas_transport_parameters,
                .solver_options = .{
                    .absolute_tolerance_g_by_species = .{
                        context.config.nonlinear_tolerance.carbon_g,
                        context.config.nonlinear_tolerance.carbon_g,
                        context.config.nonlinear_tolerance.oxygen_g,
                        context.config.nonlinear_tolerance.nitrogen_g,
                        context.config.nonlinear_tolerance.nitrogen_g,
                        context.config.nonlinear_tolerance.nitrogen_g,
                        context.config.nonlinear_tolerance.solute_g,
                    },
                    .relative_tolerance = context.config.nonlinear_tolerance.relative,
                    .picard_relaxation = context.config.picard_relaxation,
                    .max_iterations = context.iteration_limits.gas_max_iterations,
                    .accept_physically_conserved_ceiling = true,
                },
                .time_step_hours = time_step_hours,
                // The fixed-hour recovery owner binds this only for its final
                // schedule, so transient failed schedules never publish a
                // replay snapshot while the terminal failure remains exact.
                .failure_report = self.gas_failure_report,
                .temporary_profile = if (temporary_profile_active) .{
                    .io = context.io,
                    .counters = &self.temporary_profile_soil_gas_step,
                } else null,
            });
            const temporary_profile_post_start: std.Io.Timestamp = if (temporary_profile_active)
                std.Io.Clock.now(.boot, context.io)
            else
                undefined;
            self.temporary_profile_soil_gas_iterations += gas_result.iterations;
            self.temporary_profile_soil_gas_newton_steps += gas_result.newton_raphson_steps;
            self.temporary_profile_soil_gas_anderson_steps += gas_result.anderson_steps;
            self.temporary_profile_soil_gas_dense_jacobian_assemblies +=
                gas_result.dense_full_jacobian_assemblies;
            self.temporary_profile_soil_gas_dense_jacobian_reuses +=
                gas_result.dense_full_jacobian_reuses;
            self.temporary_profile_soil_gas_krylov_direction_calls +=
                gas_result.krylov_direction_calls;
            self.temporary_profile_soil_gas_krylov_iterations +=
                gas_result.krylov_iterations;
            try ecosys.soil_ammonia_phase_bridge.publishTransientToMineral(
                context.mineral_nitrogen_transport,
                context.gas_transport,
                context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            );
            try context.mineral_nitrogen_transport.publishMatrix(
                context.soil_chemistry,
                context.soil_reactive_nitrogen,
                context.fertilizer_band,
                context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                context.config.physical_tolerance.water_volume_m3,
            );
            try self.accumulateAcceptedGasBubbleActivity();
            try addFiniteSlices(self.gas_atmospheric_total_g, context.soil_gas_transport.atmospheric_flux_g_per_h);
            try addFiniteSlices(self.gas_subsurface_total_g, context.soil_gas_transport.subsurface_flux_g_per_h);
            try addFiniteSlices(self.gas_face_total_g, context.soil_gas_transport.accepted_face_flux_g_per_h);
            if (temporary_profile_active)
                self.temporary_profile_soil_gas_stage_post_ns += temporary_profile_post_start
                    .durationTo(std.Io.Clock.now(.boot, context.io)).nanoseconds;
        }

        noinline fn replayAcceptedTransport(self: *Self) !void {
            if (self.transport_replay.count == 0)
                return error.EmptyAcceptedTransportReplaySchedule;
            if (!self.transport_replay.final_captured)
                return error.MissingTransportReplayFinalState;
            // NITRO may refresh dry litter geometry after biological pool
            // changes. Save that authoritative downstream publication before
            // temporarily rebinding HOUR1's per-M transport geometry.
            const profile_active = !builtin.is_test and
                self.context.executed_weather_hours.* >= 48 and
                self.context.executed_weather_hours.* < 56;
            var profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.transport_replay.captureRestoreState();
            try self.transport_replay.captureFinalSurfaceGeometry();
            if (profile_active) self.temporary_profile_replay_setup_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            errdefer self.transport_replay.restoreFinal() catch unreachable;
            // NITRO/UPTAKE/SOLUTE produced extensive amounts on WATSUB's final
            // carrier. TRNSFR begins from WATSUB's first M-entry carrier, so
            // change only concentration coordinates before the first replay.
            // TUPWTR remains deferred until REDIST. All cells/layers are
            // validated before mutation.
            // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. The unbooked
            // +1.1027623258996755e-10 g P is created inside this replay. This gate
            // brackets all `1 + 2*count` operations so the creating one is named
            // rather than inferred.
            //
            // Falsifiable prediction with a driver, not a fitted scale: the residual
            // is hypothesised to accumulate per rebase, so it should scale with
            // `transport_replay.count`, NOT with the water movement -- the front-end
            // gap went 6 eps -> 404 eps between consecutive hours while the water
            // movement HALVED, which a per-substep accumulation explains and a
            // magnitude-driven error does not. If the two hours turn out to have the
            // same substep count, this mechanism is refuted like the six before it.
            const phosphorus_replay_trace = self.context.executed_weather_hours.* >= 2656 and
                self.context.executed_weather_hours.* < 2659;
            if (phosphorus_replay_trace) {
                std.log.info("phosphorus replay: substep_count={d}", .{self.transport_replay.count});
                try diagnostics.logPhosphorusRepresentation(self.context, "replay_entry");
            }
            const first_snapshot = try self.transport_replay.acceptedSnapshot(0);
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.rebaseAllChemistryCarriers(
                self.context.surface_precipitation.litter_water_m3,
                try self.transport_replay.surfaceWaterFromSnapshot(first_snapshot),
                self.context.grid.matrix_liquid_water_m3,
                try self.transport_replay.gridCarrierFromSnapshot(first_snapshot, 0),
            );
            if (phosphorus_replay_trace) try diagnostics.logPhosphorusRepresentation(self.context, "replay_after_entry_rebase");
            if (profile_active) self.temporary_profile_replay_rebase_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
            for (0..self.transport_replay.count) |substep| {
                const entry_snapshot = try self.transport_replay.acceptedSnapshot(substep);
                profile_section_start = std.Io.Clock.now(.boot, self.context.io);
                try self.transport_replay.bindAccepted(substep);
                if (profile_active) self.temporary_profile_replay_bind_ns +=
                    profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
                const litter_soil_flux = try self.transport_replay.litterSoilWaterFlux(substep);
                if (phosphorus_replay_trace) try diagnostics.logPhosphorusRepresentation(self.context, "replay_before_advance_transport");
                try self.advanceTransport(
                    self.transport_replay.time_step_hours[substep],
                    litter_soil_flux,
                );
                if (phosphorus_replay_trace) try diagnostics.logPhosphorusRepresentation(self.context, "replay_after_advance_transport");
                const exit_snapshot = try self.transport_replay.exitSnapshot(substep);
                const entry_surface = try self.transport_replay.surfaceWaterFromSnapshot(entry_snapshot);
                for (self.litter_soil_water_flux_m3, entry_surface, litter_soil_flux) |*projected, entry, flux| {
                    projected.* = entry - flux;
                    if (!std.math.isFinite(projected.*) or projected.* < 0)
                        return error.InvalidLitterSoilWaterCandidate;
                }
                // Soil transport publishes concentrations on its M-entry
                // volume. The litter interface publishes on entry-FLWR. REDIST
                // then advances both to the complete accepted M-exit carriers,
                // which include the rest of WATSUB's water changes.
                profile_section_start = std.Io.Clock.now(.boot, self.context.io);
                try self.rebaseAllChemistryCarriers(
                    self.litter_soil_water_flux_m3,
                    try self.transport_replay.surfaceWaterFromSnapshot(exit_snapshot),
                    try self.transport_replay.gridCarrierFromSnapshot(entry_snapshot, 0),
                    try self.transport_replay.gridCarrierFromSnapshot(exit_snapshot, 0),
                );
                if (profile_active) self.temporary_profile_replay_rebase_ns +=
                    profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
                if (phosphorus_replay_trace) try diagnostics.logPhosphorusRepresentation(self.context, "replay_after_exit_rebase");
            }
            // Restore the accepted WATSUB physical carriers and downstream
            // litter geometry. REDIST alone applies deferred root TUPWTR after
            // TRNSFR/TRNSFRS and EROSION, so there is no post-root carrier to
            // rebase in this replay transaction.
            profile_section_start = std.Io.Clock.now(.boot, self.context.io);
            try self.transport_replay.restoreFinal();
            if (phosphorus_replay_trace) try diagnostics.logPhosphorusRepresentation(self.context, "replay_after_restore_final");
            if (profile_active) self.temporary_profile_replay_restore_ns +=
                profile_section_start.durationTo(std.Io.Clock.now(.boot, self.context.io)).nanoseconds;
        }

        noinline fn rebaseAllChemistryCarriers(
            self: *Self,
            old_surface_water_m3: []const f64,
            new_surface_water_m3: []const f64,
            old_matrix_water_m3: []const f64,
            new_matrix_water_m3: []const f64,
        ) !void {
            const context = self.context;
            if (old_surface_water_m3.len != context.grid.cell_count or
                new_surface_water_m3.len != context.grid.cell_count or
                old_matrix_water_m3.len != context.grid.layer_count or
                new_matrix_water_m3.len != context.grid.layer_count)
                return error.TransportReplayDimensionMismatch;
            for (0..context.grid.cell_count) |cell| {
                try ecosys.surface_litter_chemistry_carrier_rebase.validateCellForAcceptedWater(
                    context.surface_litter_chemistry,
                    cell,
                    old_surface_water_m3[cell],
                    new_surface_water_m3[cell],
                );
                try self.previewAndAccumulateSurfaceWaterRebase(
                    cell,
                    old_surface_water_m3[cell],
                    new_surface_water_m3[cell],
                );
            }
            for (0..context.grid.layer_count) |layer| {
                const layer_cell = layer / context.grid.soil_layer_capacity;
                const roundoff = try ecosys.soil_chemistry_water_carrier_rebase.previewLayerRoundoff(
                    context.soil_chemistry,
                    layer,
                    old_matrix_water_m3[layer],
                    new_matrix_water_m3[layer],
                    try self.chemistryRebaseInventoryFractions(layer),
                    12.0,
                    context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[layer_cell]),
                );
                try self.accumulateChemistryRebaseRoundoff(layer, roundoff);
            }
            for (0..context.grid.cell_count) |cell|
                ecosys.surface_litter_chemistry_carrier_rebase.rebaseCellForAcceptedWater(
                    context.surface_litter_chemistry,
                    cell,
                    old_surface_water_m3[cell],
                    new_surface_water_m3[cell],
                ) catch unreachable;
            for (0..context.grid.layer_count) |layer| {
                // ISSUE-065 DRY_CARRIER_TRACE, see the topsoil_vapor_rebase
                // site (`:731`) for rationale. This is the TRNSFR
                // transport-replay commit call site named in issue-065's
                // addendum; `self.transport_replay.count`-many substeps can
                // call this within a single external hour.
                const dry_carrier_trace_2894 = self.context.executed_weather_hours.* >= 2888 and
                    self.context.executed_weather_hours.* < 2896 and layer == 0;
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=transport_replay hour={d} layer={d} old_water_m3={e} new_water_m3={e} dry_reference_before={e}",
                    .{
                        self.context.executed_weather_hours.* + 1,
                        layer,
                        old_matrix_water_m3[layer],
                        new_matrix_water_m3[layer],
                        context.soil_chemistry.dry_reference_water_m3[layer],
                    },
                );
                ecosys.soil_chemistry_water_carrier_rebase.rebaseLayer(
                    context.soil_chemistry,
                    layer,
                    old_matrix_water_m3[layer],
                    new_matrix_water_m3[layer],
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[layer / context.grid.soil_layer_capacity]),
                ) catch unreachable;
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=transport_replay hour={d} layer={d} dry_reference_after={e}",
                    .{ self.context.executed_weather_hours.* + 1, layer, context.soil_chemistry.dry_reference_water_m3[layer] },
                );
            }
        }

        fn accumulateLitterSoilLocalTransfer(
            self: *Self,
            cell: usize,
            signed_litter_to_topsoil: f64,
            transfer: ecosys.hourly_cell_conservation.IntercellTransfer,
        ) !void {
            if (cell >= self.context.grid.cell_count or
                !std.math.isFinite(signed_litter_to_topsoil))
                return error.InvalidLitterSoilLocalActivity;
            inline for (std.meta.fields(ecosys.hourly_cell_conservation.IntercellTransfer)) |field| {
                const value = @field(transfer, field.name);
                if (!std.math.isFinite(value) or value < 0)
                    return error.InvalidLitterSoilLocalActivity;
            }
            if (signed_litter_to_topsoil == 0) {
                if (!std.meta.eql(transfer, ecosys.hourly_cell_conservation.IntercellTransfer{}))
                    return error.InvalidLitterSoilLocalActivity;
                return;
            }
            const target = if (signed_litter_to_topsoil > 0)
                &self.litter_soil_surface_to_topsoil_total[cell]
            else
                &self.litter_soil_topsoil_to_surface_total[cell];
            // PHOSPHORUS-SURFACE-CLOSURE-HOUR-2658-001, the decisive
            // subtraction. `accumulateLitterSoilInterfaceActivity` books these
            // totals as EXACT paired transfers and nothing certifies their
            // accumulation arithmetic, while the measured residual is ~300-360
            // eps of the CELL's phosphorus stock rather than the surface's.
            //
            // Printing each per-substep increment beside the running total
            // separates the two candidates directly: if the total equals the sum
            // of increments to the last bits then the accumulation is exact and
            // a producer is losing phosphorus; if it does not, the accumulation
            // needs a derived allowance the way the water path has one.
            //
            // Gated to the same three-hour window as `traceSurfaceFrontier`, so
            // it fires only around the failing hour.
            const phosphorus_before_accumulate = target.phosphorus_g;
            inline for (std.meta.fields(ecosys.hourly_cell_conservation.IntercellTransfer)) |field|
                @field(target, field.name) = try checkedAddFiniteValue(
                    @field(target, field.name),
                    @field(transfer, field.name),
                );
            if (!builtin.is_test and
                self.context.executed_weather_hours.* >= 2656 and
                self.context.executed_weather_hours.* < 2659)
                std.log.info(
                    "litter soil interface phosphorus accumulate: cell={d} hour={d} direction={s} increment_g={e} running_total_before_g={e} running_total_after_g={e} exact_sum_gap_g={e} signed_litter_to_topsoil={e}",
                    .{
                        cell,
                        self.context.executed_weather_hours.* + 1,
                        if (signed_litter_to_topsoil > 0) "surface_to_topsoil" else "topsoil_to_surface",
                        transfer.phosphorus_g,
                        phosphorus_before_accumulate,
                        target.phosphorus_g,
                        target.phosphorus_g - (phosphorus_before_accumulate + transfer.phosphorus_g),
                        signed_litter_to_topsoil,
                    },
                );
        }

        fn accumulateAcceptedLitterSoilChemistryActivity(
            self: *Self,
            cell: usize,
            accepted: ecosys.litter_soil_interface.Result,
        ) !void {
            const context = self.context;
            const carbon_g_per_mol: f64 = 12.0;
            const nitrogen_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol;
            const phosphorus_g_per_mol = context.runscript.root_nutrient_parameters
                .phosphorus_molar_mass_g_per_mol;
            inline for (.{ carbon_g_per_mol, nitrogen_g_per_mol, phosphorus_g_per_mol }) |value|
                if (!std.math.isFinite(value) or value <= 0)
                    return error.InvalidLitterSoilLocalActivityMolarMass;

            for (accepted.signed_solute_transfer_mol, 0..) |signed, species| {
                if (signed == 0) continue;
                const formula = ecosys.surface_aqueous_runoff_transport.formula(@enumFromInt(species));
                const amount = @abs(signed);
                try self.accumulateLitterSoilLocalTransfer(cell, signed, .{
                    .carbon_g = amount * formula.carbon_mol * carbon_g_per_mol,
                    .phosphorus_g = amount * formula.phosphorus_mol * phosphorus_g_per_mol,
                    .aluminum_mol = amount * formula.aluminum_mol,
                    .iron_mol = amount * formula.iron_mol,
                    .calcium_mol = amount * formula.calcium_mol,
                    .magnesium_mol = amount * formula.magnesium_mol,
                    .sodium_mol = amount * formula.sodium_mol,
                    .potassium_mol = amount * formula.potassium_mol,
                    .sulfur_mol = amount * formula.sulfur_mol,
                    .chloride_mol = amount * formula.chloride_mol,
                    .silicon_mol = amount * formula.silicon_mol,
                });
            }
            for (accepted.signed_organic_transfer_g) |fraction| for (fraction, 0..) |signed, component| {
                if (signed == 0) continue;
                const amount = @abs(signed);
                try self.accumulateLitterSoilLocalTransfer(cell, signed, switch (component) {
                    0, 3 => .{ .carbon_g = amount },
                    1 => .{ .nitrogen_g = amount },
                    2 => .{ .phosphorus_g = amount },
                    else => unreachable,
                });
            };
            for (accepted.signed_mineral_transfer_mol, 0..) |signed, species| {
                if (signed == 0) continue;
                const amount = @abs(signed);
                try self.accumulateLitterSoilLocalTransfer(cell, signed, if (species < 4)
                    .{ .nitrogen_g = amount * nitrogen_g_per_mol }
                else
                    .{ .phosphorus_g = amount * phosphorus_g_per_mol });
            }
        }

        /// REDIST `LL=MIN(L,LG)` bubbling is an internal, generally nonlocal
        /// soil-layer transfer rather than a gas face or boundary flux. The
        /// coupled solver exposes the exact accepted released mass while the
        /// still-current receiver map supplies its destination. Accumulate
        /// both local legs together so failed recovery schedules publish no
        /// partial activity.
        fn accumulateAcceptedGasBubbleActivity(self: *Self) !void {
            const state = self.context.soil_gas_transport;
            const layer_count = self.context.grid.layer_count;
            const expected = try std.math.mul(
                usize,
                layer_count,
                ecosys.gas_transport.species_count,
            );
            if (state.accepted_bubble_transfer_g_per_step.len != expected or
                state.bubble_receiver_cell_by_cell.len != layer_count or
                self.gas_bubble_input_total.len != layer_count or
                self.gas_bubble_output_total.len != layer_count)
                return error.InvalidSoilGasBubbleActivityDimensions;
            for (0..layer_count) |source| {
                const receiver = state.bubble_receiver_cell_by_cell[source] orelse continue;
                if (receiver >= layer_count)
                    return error.InvalidSoilGasBubbleActivityReceiver;
                if (receiver == source) continue;
                const start = source * ecosys.gas_transport.species_count;
                for (state.accepted_bubble_transfer_g_per_step[start..][0..ecosys.gas_transport.species_count], 0..) |amount, species| {
                    if (!std.math.isFinite(amount) or amount < 0)
                        return error.InvalidSoilGasBubbleActivity;
                    if (amount == 0) continue;
                    const transfer: ecosys.hourly_cell_conservation.IntercellTransfer = switch (@as(
                        ecosys.gas_transport.Species,
                        @enumFromInt(species),
                    )) {
                        .carbon_dioxide, .methane => .{ .carbon_g = amount },
                        .oxygen => .{ .oxygen_g = amount },
                        .nitrogen, .nitrous_oxide, .ammonia => .{ .nitrogen_g = amount },
                        .hydrogen => .{ .hydrogen_g = amount },
                    };
                    var output_next = self.gas_bubble_output_total[source];
                    var input_next = self.gas_bubble_input_total[receiver];
                    inline for (std.meta.fields(ecosys.hourly_cell_conservation.IntercellTransfer)) |field| {
                        @field(output_next, field.name) = try checkedAddFiniteValue(
                            @field(output_next, field.name),
                            @field(transfer, field.name),
                        );
                        @field(input_next, field.name) = try checkedAddFiniteValue(
                            @field(input_next, field.name),
                            @field(transfer, field.name),
                        );
                    }
                    self.gas_bubble_output_total[source] = output_next;
                    self.gas_bubble_input_total[receiver] = input_next;
                }
            }
        }

        /// WATSUB's accepted physical litter-soil FLWR/HFLWR owner. Every cell
        /// is fully preflighted before the first storage, air, heat-capacity or
        /// temperature publication, so an invalid candidate has no scientific
        /// side effect even before the enclosing schedule rollback runs.
        noinline fn advanceAcceptedLitterSoilPhysical(self: *Self, time_step_hours: f64) !void {
            const context = self.context;
            if (self.litter_soil_physical_candidates.len != context.grid.cell_count or
                self.litter_soil_water_flux_m3.len != context.grid.cell_count or
                context.micropore_solute_state.water_volume_m3.len != context.grid.layer_count or
                context.macropore_solute_state.water_volume_m3.len != context.grid.layer_count or
                context.surface_solute_transport.carrier_volume_m3.len != context.grid.cell_count or
                context.mineral_nitrogen_transport.matrix.water_volume_m3.len != context.grid.layer_count or
                context.mineral_nitrogen_transport.macropore.water_volume_m3.len != context.grid.layer_count or
                context.gas_transport.temperature_k.len != context.grid.layer_count or
                context.gas_transport.air_volume_m3.len != context.grid.layer_count or
                context.transport_hydrology.micropore_water_volume_m3.len != context.grid.layer_count or
                context.transport_hydrology.matrix_air_volume_m3.len != context.grid.layer_count or
                context.transport_hydrology.air_volume_m3.len != context.grid.layer_count)
                return error.LitterSoilPhysicalDimensionMismatch;
            for (self.litter_soil_physical_candidates, 0..) |*candidate, cell| {
                const top = try context.grid.layerIndex(cell, 0);
                const area_m2 = context.canopy_cell_area_m2[cell];
                const litter_volume_m3 = context.surface_litter_geometry.expanded_total_volume_m3[cell];
                const litter_pore_m3 = context.surface_litter_geometry.pore_volume_m3[cell];
                const old_litter_water_m3 = context.surface_precipitation.litter_water_m3[cell];
                const old_soil_water_m3 = context.grid.matrix_liquid_water_m3[top];
                const litter_ice_m3 = context.surface_litter_ice_m3[cell];
                inline for (.{ area_m2, litter_volume_m3, litter_pore_m3, old_litter_water_m3, old_soil_water_m3, litter_ice_m3 }) |value|
                    if (!std.math.isFinite(value) or value < 0) return error.InvalidLitterSoilInterfacePhysicalState;
                if (area_m2 <= 0) return error.InvalidLitterSoilInterfacePhysicalState;
                const litter_cover = context.surface_precipitation.litter_cover_fraction[cell];
                const litter_present = litter_volume_m3 >
                    context.config.physical_tolerance.waterVolume(litter_volume_m3) and
                    litter_cover > 0;
                const soil_ice_density = context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3;
                const litter_physical_ice_m3 = try ecosys.ice_units.physicalVolumeM3FromWaterEquivalent(
                    litter_ice_m3,
                    soil_ice_density,
                );
                // LITTER-ICE-PORE-DOMAIN-001: there is deliberately no fatal
                // check that ice fits in the DRY pore volume. `hour1.f:4366`
                // clamps (`VOLP(0)=AMAX1(0.0,VOLA(0)-VOLW(0)-VOLI(0))`), excess
                // water and ice expand the layer (`:4353`, `:4356`), and `:4372`
                // clamps ice content at unity, so the oracle anticipates a
                // stronger overfill than any state reaching here. The clamp is
                // owned by `surface_litter_geometry.liquidCapacityAfterIceM3`.
                const retained_litter_liquid_capacity_m3 = try ecosys.surface_litter_geometry.liquidCapacityAfterIceM3(
                    litter_pore_m3,
                    litter_physical_ice_m3,
                );
                const litter_air_m3 = if (litter_present)
                    @max(0, retained_litter_liquid_capacity_m3 - old_litter_water_m3)
                else
                    context.surface_litter_geometry.air_volume_m3[cell];
                if (!std.math.isFinite(litter_air_m3) or litter_air_m3 < 0)
                    return error.InvalidLitterSoilInterfacePhysicalState;
                const soil_parameters = context.soil_solver_properties.mualem_van_genuchten_parameters[top];
                const litter_porosity = context.surface_litter_geometry.porosity_m3_per_m3[cell];
                if (litter_present and litter_porosity <= context.runscript.soil_process_parameters.surface_residue_residual_water_content_m3_per_m3)
                    return error.InvalidLitterSoilRetentionState;
                const litter_parameters = ecosys.soil_water_retention.MualemVanGenuchtenParameters{
                    .residual_water_content_m3_per_m3 = context.runscript.soil_process_parameters.surface_residue_residual_water_content_m3_per_m3,
                    .saturated_water_content_m3_per_m3 = litter_porosity,
                    .alpha_per_m = context.runscript.soil_process_parameters.surface_residue_van_genuchten_alpha_per_m,
                    .n = context.runscript.soil_process_parameters.surface_residue_van_genuchten_n,
                    .pore_connectivity = soil_parameters.pore_connectivity,
                    .saturated_hydraulic_conductivity_m_per_h = soil_parameters.saturated_hydraulic_conductivity_m_per_h,
                };
                const litter_thickness_m = if (litter_present) litter_volume_m3 / area_m2 else 0;
                const wet_litter_cover = if (old_litter_water_m3 > context.config.physical_tolerance.waterVolume(litter_pore_m3)) litter_cover else 0;
                const soil_excess_pore_volume_m3 = try ecosys.soil_water_solver.physicalPoreSpaceM3(
                    context.grid.matrix_pore_capacity_m3[top],
                    old_soil_water_m3,
                    context.grid.matrix_ice_water_m3[top],
                    soil_ice_density,
                );
                const liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k;
                const water_flux = if (litter_present)
                    try ecosys.surface_water_flow.litterSoilFlux(.{
                        .litter_water_m3 = old_litter_water_m3,
                        .soil_matrix_water_m3 = old_soil_water_m3,
                        .litter_air_m3 = litter_air_m3,
                        .soil_matrix_air_m3 = context.grid.matrix_air_volume_m3[top],
                        .litter_volume_m3 = litter_volume_m3,
                        .soil_matrix_bulk_volume_m3 = context.soil_solver_properties.matrix_bulk_volume_m3[top],
                        // LITTER-RETENTION-THETWR-001: HOUR1 `THETWR`
                        // (`hour1.f:4385`) bounds by the retention capacity
                        // VOLWRX and divides by the DRY residue volume VOLR.
                        // It carries no ice term and does not use the expanded
                        // volume VOLT(0).
                        .litter_water_fraction = try ecosys.surface_litter_geometry.retentionWaterFraction(
                            context.surface_litter_geometry.water_retention_capacity_m3[cell],
                            old_litter_water_m3,
                            context.surface_litter_geometry.dry_litter_volume_m3[cell],
                        ),
                        .soil_water_fraction = old_soil_water_m3 / context.soil_solver_properties.matrix_bulk_volume_m3[top],
                        .litter_parameters = litter_parameters,
                        .soil_parameters = soil_parameters,
                        .litter_external_water_potential_megapascal = context.runscript.soil_process_parameters.gravitational_water_potential_mpa_per_m * context.terrain_hydrology.relative_surface_elevation_m[cell] +
                            context.surface_litter_water_environment.osmotic_water_potential_megapascal[cell],
                        .soil_external_water_potential_megapascal = context.soil_hourly_workspace.gravitational_potential_megapascal[top] + context.soil_hourly_workspace.osmotic_potential_megapascal[top],
                        .litter_ice_water_equivalent_m3 = litter_ice_m3,
                        .soil_ice_water_equivalent_m3 = context.grid.matrix_ice_water_m3[top],
                        .conductivity_multiplier = context.soil_solver_properties.rainfall_conductivity_multiplier[top],
                        .frozen_hydraulic_impedance_exponent = context.soil_hourly_workspace.frozen_hydraulic_impedance_exponent,
                        .ice_density_megagrams_per_m3 = soil_ice_density,
                        .gravitational_water_potential_mpa_per_m = context.runscript.soil_process_parameters.gravitational_water_potential_mpa_per_m,
                        .litter_thickness_m = litter_thickness_m,
                        .soil_thickness_m = context.soil_solver_properties.layer_thickness_m[top],
                        .soil_face_area_m2 = area_m2,
                        .litter_cover_fraction = litter_cover,
                        .wet_litter_cover_fraction = wet_litter_cover,
                        .time_fraction = time_step_hours,
                        .soil_excess_pore_volume_m3 = soil_excess_pore_volume_m3,
                        .litter_temperature_k = context.grid.surface_temperature_k[cell],
                        .soil_temperature_k = context.grid.soil_temperature_k[top],
                        .liquid_water_heat_capacity_megajoules_per_m3_k = liquid_water_heat_capacity_megajoules_per_m3_k,
                    })
                else
                    try ecosys.surface_water_flow.bareSurfaceSoilFreezingFlux(
                        old_soil_water_m3,
                        soil_excess_pore_volume_m3,
                        time_step_hours,
                        context.grid.soil_temperature_k[top],
                        liquid_water_heat_capacity_megajoules_per_m3_k,
                    );
                const new_litter_water_m3 = old_litter_water_m3 - water_flux.water_m3;
                const new_soil_water_m3 = old_soil_water_m3 + water_flux.water_m3;
                const new_litter_air_m3 = if (litter_present)
                    @max(0, retained_litter_liquid_capacity_m3 - new_litter_water_m3)
                else
                    litter_air_m3;
                const new_soil_air_m3 = try ecosys.soil_water_solver.derivedPhysicalAirVolumeM3(
                    context.grid.matrix_pore_capacity_m3[top],
                    new_soil_water_m3,
                    context.grid.matrix_ice_water_m3[top],
                    soil_ice_density,
                );
                inline for (.{ new_litter_water_m3, new_soil_water_m3, new_litter_air_m3, new_soil_air_m3 }) |value|
                    if (!std.math.isFinite(value) or value < 0) return error.InvalidLitterSoilWaterCandidate;
                // WATSUB changes the physical carrier before NITRO consumes
                // concentrations. Preflight every concentration owner now so
                // the later all-cell commit cannot expose a partially diluted
                // landscape to biology.
                try ecosys.surface_litter_chemistry_carrier_rebase.validateCellForAcceptedWater(
                    context.surface_litter_chemistry,
                    cell,
                    old_litter_water_m3,
                    new_litter_water_m3,
                );
                const chemistry_rebase_roundoff = try ecosys.soil_chemistry_water_carrier_rebase.previewLayerRoundoff(
                    context.soil_chemistry,
                    top,
                    old_soil_water_m3,
                    new_soil_water_m3,
                    try self.chemistryRebaseInventoryFractions(top),
                    12.0,
                    context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[cell]),
                );
                const surface_chemistry_rebase_roundoff = try ecosys.surface_litter_chemistry_carrier_rebase.previewCellWaterRoundoff(
                    context.surface_litter_chemistry,
                    cell,
                    old_litter_water_m3,
                    new_litter_water_m3,
                    try surfaceChemistryRebaseInventoryInputs(context, cell),
                );
                const old_surface_capacity = context.surface_heat_capacity_megajoules_per_k[cell];
                const old_soil_capacity = context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[top] * context.soil_solver_properties.layer_volume_m3[top];
                const capacity_transfer = liquid_water_heat_capacity_megajoules_per_m3_k * water_flux.water_m3;
                const new_surface_capacity = old_surface_capacity - capacity_transfer;
                const new_soil_capacity = old_soil_capacity + capacity_transfer;
                if (!std.math.isFinite(new_surface_capacity) or !std.math.isFinite(new_soil_capacity) or
                    new_surface_capacity <= 0 or new_soil_capacity <= 0)
                    return error.InvalidLitterSoilHeatCapacityCandidate;
                const new_surface_temperature = (old_surface_capacity * context.grid.surface_temperature_k[cell] - water_flux.convective_heat_megajoules) / new_surface_capacity;
                const new_soil_temperature = (old_soil_capacity * context.grid.soil_temperature_k[top] + water_flux.convective_heat_megajoules) / new_soil_capacity;
                if (!builtin.is_test and context.executed_weather_hours.* >= 2531 and context.executed_weather_hours.* < 2534)
                    std.log.info("THERMAL_INTERFACE hour={d} dt_hours={e} cell={d} water_m3={e} heat_megajoules={e} cached_soil_capacity={e} old_soil_temperature_k={e} new_soil_temperature_k={e}", .{ context.executed_weather_hours.* + 1, time_step_hours, cell, water_flux.water_m3, water_flux.convective_heat_megajoules, old_soil_capacity, context.grid.soil_temperature_k[top], new_soil_temperature });
                inline for (.{ new_surface_temperature, new_soil_temperature }) |temperature|
                    if (!std.math.isFinite(temperature) or temperature <= 0) return error.InvalidLitterSoilTemperatureCandidate;
                const old_pair_water_m3 = old_litter_water_m3 + old_soil_water_m3;
                const new_pair_water_m3 = new_litter_water_m3 + new_soil_water_m3;
                if (@abs(new_pair_water_m3 - old_pair_water_m3) >
                    context.config.physical_tolerance.waterVolume(@max(@abs(old_pair_water_m3), @abs(new_pair_water_m3))))
                    return error.LitterSoilWaterTransferConservationFailure;
                const old_pair_heat_megajoules = old_surface_capacity * context.grid.surface_temperature_k[cell] +
                    old_soil_capacity * context.grid.soil_temperature_k[top];
                const new_pair_heat_megajoules = new_surface_capacity * new_surface_temperature +
                    new_soil_capacity * new_soil_temperature;
                if (@abs(new_pair_heat_megajoules - old_pair_heat_megajoules) >
                    context.config.physical_tolerance.heat(@max(@abs(old_pair_heat_megajoules), @abs(new_pair_heat_megajoules))))
                    return error.LitterSoilHeatTransferConservationFailure;
                candidate.* = .{
                    .cell = cell,
                    .top = top,
                    .water_flux = water_flux,
                    .new_litter_water_m3 = new_litter_water_m3,
                    .new_soil_water_m3 = new_soil_water_m3,
                    .new_litter_air_m3 = new_litter_air_m3,
                    .new_soil_air_m3 = new_soil_air_m3,
                    .new_surface_capacity_megajoules_per_k = new_surface_capacity,
                    .new_soil_capacity_megajoules_per_k = new_soil_capacity,
                    .new_surface_temperature_k = new_surface_temperature,
                    .new_soil_temperature_k = new_soil_temperature,
                    .chemistry_rebase_roundoff = chemistry_rebase_roundoff,
                    .surface_chemistry_rebase_roundoff = surface_chemistry_rebase_roundoff,
                };
                self.litter_soil_water_flux_m3[cell] = try checkedAddFiniteValue(
                    self.litter_soil_water_flux_m3[cell],
                    water_flux.water_m3,
                );
            }
            for (self.litter_soil_physical_candidates) |candidate| {
                const cell = candidate.cell;
                const top = candidate.top;
                const water = candidate.water_flux.water_m3;
                const heat = candidate.water_flux.convective_heat_megajoules;
                if (water != 0) try self.accumulateLitterSoilLocalTransfer(
                    cell,
                    water,
                    .{ .water_m3 = @abs(water) },
                );
                if (heat != 0) try self.accumulateLitterSoilLocalTransfer(
                    cell,
                    heat,
                    .{ .heat_megajoules = @abs(heat) },
                );
                const old_litter_water_m3 = context.surface_precipitation.litter_water_m3[cell];
                const old_soil_water_m3 = context.grid.matrix_liquid_water_m3[top];
                ecosys.surface_litter_chemistry_carrier_rebase.rebaseCellForAcceptedWater(
                    context.surface_litter_chemistry,
                    cell,
                    old_litter_water_m3,
                    candidate.new_litter_water_m3,
                ) catch unreachable;
                // ISSUE-065 DRY_CARRIER_TRACE, see the topsoil_vapor_rebase
                // site (`:731`) for rationale. This is the litter/soil
                // interface commit call site named in issue-065's addendum.
                const dry_carrier_trace_2894 = context.executed_weather_hours.* >= 2888 and
                    context.executed_weather_hours.* < 2896 and top == 0;
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=litter_soil_interface hour={d} cell={d} layer={d} old_water_m3={e} new_water_m3={e} dry_reference_before={e}",
                    .{
                        context.executed_weather_hours.* + 1,
                        cell,
                        top,
                        old_soil_water_m3,
                        candidate.new_soil_water_m3,
                        context.soil_chemistry.dry_reference_water_m3[top],
                    },
                );
                ecosys.soil_chemistry_water_carrier_rebase.rebaseLayer(
                    context.soil_chemistry,
                    top,
                    old_soil_water_m3,
                    candidate.new_soil_water_m3,
                    ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(context.canopy_cell_area_m2[cell]),
                ) catch unreachable;
                if (dry_carrier_trace_2894) std.log.info(
                    "DRY_CARRIER_TRACE site=litter_soil_interface hour={d} cell={d} layer={d} dry_reference_after={e}",
                    .{ context.executed_weather_hours.* + 1, cell, top, context.soil_chemistry.dry_reference_water_m3[top] },
                );
                try self.accumulateChemistryRebaseRoundoff(
                    top,
                    candidate.chemistry_rebase_roundoff,
                );
                try self.accumulateSurfaceChemistryRebaseRoundoff(
                    cell,
                    candidate.surface_chemistry_rebase_roundoff,
                );
                context.surface_precipitation.litter_water_m3[cell] = candidate.new_litter_water_m3;
                context.surface_litter_geometry.air_volume_m3[cell] = candidate.new_litter_air_m3;
                context.grid.matrix_liquid_water_m3[top] = candidate.new_soil_water_m3;
                context.grid.liquid_water_m3[top] = candidate.new_soil_water_m3 + context.grid.macropore_liquid_water_m3[top];
                context.grid.matrix_air_volume_m3[top] = candidate.new_soil_air_m3;
                context.grid.air_volume_m3[top] = candidate.new_soil_air_m3 + context.grid.macropore_air_volume_m3[top];
                context.transport_hydrology.micropore_water_volume_m3[top] = candidate.new_soil_water_m3;
                context.transport_hydrology.matrix_air_volume_m3[top] = candidate.new_soil_air_m3;
                context.transport_hydrology.air_volume_m3[top] = context.grid.air_volume_m3[top];
                context.micropore_solute_state.water_volume_m3[top] = candidate.new_soil_water_m3;
                context.mineral_nitrogen_transport.matrix.water_volume_m3[top] = candidate.new_soil_water_m3;
                context.surface_solute_transport.carrier_volume_m3[cell] = candidate.new_litter_water_m3;
                context.surface_heat_capacity_megajoules_per_k[cell] = candidate.new_surface_capacity_megajoules_per_k;
                context.grid.surface_temperature_k[cell] = candidate.new_surface_temperature_k;
                context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[top] = candidate.new_soil_capacity_megajoules_per_k / context.soil_solver_properties.layer_volume_m3[top];
                context.soil_hourly_workspace.heat_capacity_megajoules_per_k[top] = candidate.new_soil_capacity_megajoules_per_k;
                context.grid.soil_temperature_k[top] = candidate.new_soil_temperature_k;
                if (water != 0) {
                    try self.incrementWaterStorageUpdate(.{
                        .kind = .surface,
                        .cell = cell,
                    }, 1);
                    try self.incrementWaterStorageUpdate(.{
                        .kind = .soil_layer,
                        .cell = cell,
                        .layer = 0,
                    }, 1);
                }
            }
            // Amount-based transport owners retain extensive inventory across
            // pure-water WATSUB changes, but their carrier mirrors must move
            // with the just-accepted grid before NITRO/root consumers run.
            @memcpy(context.micropore_solute_state.water_volume_m3, context.grid.matrix_liquid_water_m3);
            @memcpy(context.macropore_solute_state.water_volume_m3, context.grid.macropore_liquid_water_m3);
            @memcpy(context.mineral_nitrogen_transport.matrix.water_volume_m3, context.grid.matrix_liquid_water_m3);
            @memcpy(context.mineral_nitrogen_transport.macropore.water_volume_m3, context.grid.macropore_liquid_water_m3);
            @memcpy(context.gas_transport.temperature_k, context.grid.soil_temperature_k);
            @memcpy(context.gas_transport.air_volume_m3, context.grid.air_volume_m3);
        }

        /// TRNSFR's chemical-only litter-soil consumer. `water_flux_m3` is the
        /// exact accepted FLWR produced by WATSUB for the rebound M-entry
        /// volumes; this path must never republish a physical carrier.
        noinline fn advanceLitterSoilInterface(self: *Self, time_step_hours: f64, water_flux_m3: []const f64) !void {
            const context = self.context;
            const interface = ecosys.litter_soil_interface;
            const organic_substrate_count = ecosys.soil_organic_initialization.substrate_count;
            if (water_flux_m3.len != context.grid.cell_count)
                return error.LitterSoilInterfaceFluxDimensionMismatch;
            try validateLitterSoilInterfaceDimensions(
                context.surface_solute_transport,
                context.micropore_solute_state,
                context.grid.cell_count,
                context.grid.layer_count,
            );
            if (context.surface_litter_chemistry.cells.len != context.grid.cell_count or
                context.surface_litter_chemistry.dry_reference_water_m3.len != context.grid.cell_count or
                context.surface_litter_chemistry.mineral_reference_water_m3.len != context.grid.cell_count)
                return error.LitterSoilInterfaceChemistryDimensionMismatch;
            for (0..context.grid.cell_count) |cell| {
                const litter_organic_carbon_before_g_c = try context.surface_organic.totalCarbon_g_c(cell);
                const top = try context.grid.layerIndex(cell, 0);
                const top_zone_fractions = try context.fertilizer_band.scienceZoneFractions(cell, 0);
                const phosphate_band = top_zone_fractions.phosphate_band;
                const area_m2 = context.canopy_cell_area_m2[cell];
                const litter_volume_m3 = context.surface_litter_geometry.expanded_total_volume_m3[cell];
                const litter_pore_m3 = context.surface_litter_geometry.pore_volume_m3[cell];
                const old_litter_water_m3 = context.surface_precipitation.litter_water_m3[cell];
                const old_soil_water_m3 = context.grid.matrix_liquid_water_m3[top];
                const litter_ice_m3 = context.surface_litter_ice_m3[cell];
                inline for (.{ area_m2, litter_volume_m3, litter_pore_m3, old_litter_water_m3, old_soil_water_m3, litter_ice_m3 }) |value|
                    if (!std.math.isFinite(value) or value < 0) return error.InvalidLitterSoilInterfacePhysicalState;
                if (area_m2 <= 0) return error.InvalidLitterSoilInterfacePhysicalState;
                const litter_cover = context.surface_precipitation.litter_cover_fraction[cell];
                const litter_present = litter_volume_m3 >
                    context.config.physical_tolerance.waterVolume(litter_volume_m3) and
                    litter_cover > 0;
                const litter_thickness_m = if (litter_present) litter_volume_m3 / area_m2 else 0;
                const water_flux = water_flux_m3[cell];
                if (!std.math.isFinite(water_flux)) return error.NonFiniteLitterSoilInterfaceFlux;
                const projected_new_litter_water_m3 = old_litter_water_m3 - water_flux;
                const projected_new_soil_water_m3 = old_soil_water_m3 + water_flux;
                if (!std.math.isFinite(projected_new_litter_water_m3) or projected_new_litter_water_m3 < 0 or
                    !std.math.isFinite(projected_new_soil_water_m3) or projected_new_soil_water_m3 < 0)
                    return error.InvalidLitterSoilWaterCandidate;
                const litter_chemistry_carriers = try interface.aqueousCarrierTransition(
                    old_litter_water_m3,
                    projected_new_litter_water_m3,
                    context.surface_litter_chemistry.dry_reference_water_m3[cell],
                );

                var litter_solute: [interface.litter_species_count]f64 = undefined;
                var soil_solute: [interface.soil_species_count]f64 = undefined;
                const surface_amounts = try context.surface_solute_transport.cellAmounts(cell);
                const soil_amounts = try context.micropore_solute_state.cellAmounts(top);
                // The source-order litter interface projects the established
                // 50 salt coordinates. Bare HPO4/H2PO4 are carried through its
                // dedicated mineral vector and published to the appended
                // transport coordinates after acceptance below.
                try interface.projectCanonicalSolutes(
                    surface_amounts,
                    soil_amounts,
                    &litter_solute,
                    &soil_solute,
                );
                try interface.exportRepresentedLitterChemistry(
                    &context.surface_litter_chemistry.cells[cell],
                    litter_chemistry_carriers.before_m3,
                    &litter_solute,
                );
                var litter_organic: [interface.organic_fraction_count]ecosys.redist_litter_dissolved_organic_update.OrganicPool = undefined;
                var soil_organic: [interface.organic_fraction_count]ecosys.redist_litter_dissolved_organic_update.OrganicPool = undefined;
                for (0..interface.organic_fraction_count) |fraction| {
                    const litter_index = cell * organic_substrate_count + fraction;
                    const soil_index = top * organic_substrate_count + fraction;
                    const litter_pool = context.surface_organic.dissolved[litter_index];
                    const soil_pool = context.soil_organic.dissolved[soil_index];
                    litter_organic[fraction] = .{ .doc_g = litter_pool.carbon_g_c, .don_g = litter_pool.nitrogen_g_n, .dop_g = litter_pool.phosphorus_g_p, .acetate_g = context.surface_organic.dissolved_acetate_carbon_g_c[litter_index] };
                    soil_organic[fraction] = .{ .doc_g = soil_pool.carbon_g_c, .don_g = soil_pool.nitrogen_g_n, .dop_g = soil_pool.phosphorus_g_p, .acetate_g = context.soil_organic.dissolved_acetate_carbon_g_c[soil_index] };
                }
                const litter_cell = context.surface_litter_chemistry.cells[cell];
                const nitrogen_molar_mass_g_per_mol = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol;
                if (!std.math.isFinite(nitrogen_molar_mass_g_per_mol) or nitrogen_molar_mass_g_per_mol <= 0)
                    return error.InvalidLitterSoilNitrogenMolarMass;
                const litter_nitrite_mol = context.surface_denitrification.nitrite_g_n[cell] / nitrogen_molar_mass_g_per_mol;
                var litter_mineral = try interface.exportLitterAqueousMinerals(
                    litter_cell,
                    litter_chemistry_carriers.before_m3,
                    litter_nitrite_mol,
                );
                var soil_mineral: [interface.mineral_soil_zone_count]f64 = undefined;
                const matrix_n = try context.mineral_nitrogen_transport.matrix.cellAmounts(top);
                @memcpy(soil_mineral[0..8], matrix_n[0..8]);
                const nonband_phosphate = 1 - phosphate_band;
                const soil_nonband_phosphate = context.soil_chemistry.non_band_phosphate[top];
                const soil_band_phosphate = context.soil_chemistry.band_phosphate[top];
                soil_mineral[8] = soil_nonband_phosphate.dissolved_hpo4_mol_p_per_m3 * old_soil_water_m3 * nonband_phosphate;
                soil_mineral[9] = soil_band_phosphate.dissolved_hpo4_mol_p_per_m3 * old_soil_water_m3 * phosphate_band;
                soil_mineral[10] = soil_nonband_phosphate.dissolved_h2po4_mol_p_per_m3 * old_soil_water_m3 * nonband_phosphate;
                soil_mineral[11] = soil_band_phosphate.dissolved_h2po4_mol_p_per_m3 * old_soil_water_m3 * phosphate_band;

                const temperature_factor = std.math.pow(f64, context.grid.surface_temperature_k[cell] / 298.15, 6);
                const litter_saturation = if (litter_pore_m3 > 0) old_litter_water_m3 / litter_pore_m3 else 0;
                const soil_saturation = if (context.grid.matrix_pore_capacity_m3[top] > 0) old_soil_water_m3 / context.grid.matrix_pore_capacity_m3[top] else 0;
                const diffusivity_step_scale = temperature_factor * time_step_hours;
                var aqueous_diffusivity = interface.reference_salt_diffusivity_m2_per_h;
                var organic_diffusivity = interface.reference_organic_diffusivity_m2_per_h;
                var mineral_diffusivity = interface.reference_mineral_diffusivity_m2_per_h;
                for (&aqueous_diffusivity) |*value| value.* *= diffusivity_step_scale;
                for (&organic_diffusivity) |*value| value.* *= diffusivity_step_scale;
                for (&mineral_diffusivity) |*value| value.* *= diffusivity_step_scale;
                const mean_distance_m = 0.5 * (litter_thickness_m + context.soil_solver_properties.layer_thickness_m[top]);
                const accepted_interface = try interface.advance(.{
                    .litter_bulk_volume_m3 = litter_volume_m3,
                    .litter_water_m3 = old_litter_water_m3,
                    .soil_surface_water_m3 = old_soil_water_m3,
                    .litter_thickness_m = litter_thickness_m,
                    .soil_surface_thickness_m = context.soil_solver_properties.layer_thickness_m[top],
                    .soil_surface_area_m2 = area_m2,
                    .litter_to_soil_water_flux_m3_per_step = water_flux,
                    .litter_solute_mol = &litter_solute,
                    .soil_solute_mol = &soil_solute,
                    .litter_organic = &litter_organic,
                    .soil_organic = &soil_organic,
                    .litter_mineral_mol = &litter_mineral,
                    .soil_mineral_mol = &soil_mineral,
                }, .{
                    .minimum_litter_bulk_volume_m3 = context.config.physical_tolerance.waterVolume(litter_volume_m3),
                    .minimum_water_m3 = context.config.physical_tolerance.waterVolume(@max(old_litter_water_m3, old_soil_water_m3)),
                    .minimum_thickness_m = context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
                    .litter_tortuosity = context.surface_gas_parameters.exchange.aqueous_tortuosity_coefficient * litter_saturation * litter_saturation,
                    .soil_surface_tortuosity = 0.7 * soil_saturation * soil_saturation,
                    .litter_cover_fraction = litter_cover,
                    .dispersivity_m = 0.20 * std.math.pow(f64, mean_distance_m, 1.07) * time_step_hours,
                    .maximum_pore_velocity_m_per_step = time_step_hours,
                    .maximum_convective_fraction = 1,
                    .nonband_phosphate_fraction = 1 - phosphate_band,
                    .band_phosphate_fraction = phosphate_band,
                    // TRNSFR 2095--2102 partitions NH4/NH3 with VLNH4,
                    // NO3/NO2 with VLNO3, and both phosphates with VLPO4.
                    // A shared phosphate split silently routes mineral N to
                    // the wrong fertilizer zone whenever the bands differ.
                    .nonband_mineral_fraction = .{
                        top_zone_fractions.ammonium_non_band,
                        top_zone_fractions.ammonium_non_band,
                        top_zone_fractions.nitrate_non_band,
                        top_zone_fractions.nitrate_non_band,
                        top_zone_fractions.phosphate_non_band,
                        top_zone_fractions.phosphate_non_band,
                    },
                    .band_mineral_fraction = .{
                        top_zone_fractions.ammonium_band,
                        top_zone_fractions.ammonium_band,
                        top_zone_fractions.nitrate_band,
                        top_zone_fractions.nitrate_band,
                        top_zone_fractions.phosphate_band,
                        top_zone_fractions.phosphate_band,
                    },
                    .phosphorus_g_per_mol = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                    .aqueous_diffusivity_m2_per_step = aqueous_diffusivity,
                    .organic_diffusivity_m2_per_step = organic_diffusivity,
                    .mineral_diffusivity_m2_per_step = mineral_diffusivity,
                    .solute_admissibility_absolute_tolerance_mol = context.config.physical_tolerance.amount_mol,
                    .phosphate_admissibility_absolute_tolerance_g_p = context.config.physical_tolerance.phosphorus_g,
                    .organic_admissibility_absolute_tolerance_g = .{
                        context.config.physical_tolerance.carbon_g,
                        context.config.physical_tolerance.nitrogen_g,
                        context.config.physical_tolerance.phosphorus_g,
                        context.config.physical_tolerance.carbon_g,
                    },
                    .mineral_admissibility_absolute_tolerance_mol = context.config.physical_tolerance.amount_mol,
                    .admissibility_relative_tolerance = context.config.physical_tolerance.relative,
                    .zone_fraction_absolute_tolerance = context.config.physical_tolerance.dimensionless,
                    .zone_fraction_relative_tolerance = context.config.physical_tolerance.relative,
                    .solute_conservation_absolute_tolerance_mol = context.config.mass_balance_absolute_tolerance.ions_mol_m2 * area_m2,
                    .phosphate_conservation_absolute_tolerance_g_p = context.config.mass_balance_absolute_tolerance.phosphorus_g_m2 * area_m2,
                    .organic_conservation_absolute_tolerance_g = .{
                        context.config.mass_balance_absolute_tolerance.carbon_g_m2 * area_m2,
                        context.config.mass_balance_absolute_tolerance.nitrogen_g_m2 * area_m2,
                        context.config.mass_balance_absolute_tolerance.phosphorus_g_m2 * area_m2,
                        context.config.mass_balance_absolute_tolerance.carbon_g_m2 * area_m2,
                    },
                    .mineral_conservation_absolute_tolerance_mol = context.config.mass_balance_absolute_tolerance.ions_mol_m2 * area_m2,
                    .conservation_relative_tolerance = context.config.mass_balance_relative_tolerance,
                });

                const new_litter_water_m3 = projected_new_litter_water_m3;
                const new_soil_water_m3 = projected_new_soil_water_m3;
                var litter_cell_candidate = context.surface_litter_chemistry.cells[cell];
                const litter_aqueous_carrier_m3 = try ecosys.surface_litter_chemistry_carrier_rebase.effectiveAqueousCarrierM3(
                    context.surface_precipitation.litter_water_m3[cell],
                    context.surface_litter_chemistry.dry_reference_water_m3[cell],
                );
                const litter_mineral_roundoff = try ecosys.surface_litter_chemistry_carrier_rebase.previewMineralCellRoundoff(
                    litter_cell_candidate,
                    litter_aqueous_carrier_m3,
                    try surfaceChemistryRebaseInventoryInputs(context, cell),
                    context.surface_litter_chemistry.mineral_reference_water_m3[cell],
                    new_litter_water_m3,
                );
                const litter_mineral_reference_candidate_m3 =
                    try ecosys.surface_litter_chemistry_carrier_rebase.rebaseMineralCellForAcceptedWater(
                        &litter_cell_candidate,
                        context.surface_litter_chemistry.mineral_reference_water_m3[cell],
                        new_litter_water_m3,
                    );
                try interface.importRepresentedLitterChemistry(
                    &litter_cell_candidate,
                    litter_chemistry_carriers.after_m3,
                    &litter_solute,
                    context.config.physical_tolerance.amount_mol,
                    context.config.physical_tolerance.relative,
                );
                const litter_nitrite_candidate_mol = try interface.importLitterAqueousMinerals(
                    &litter_cell_candidate,
                    litter_chemistry_carriers.after_m3,
                    &litter_mineral,
                );
                const litter_nitrite_candidate_g_n = litter_nitrite_candidate_mol * nitrogen_molar_mass_g_per_mol;
                if (!std.math.isFinite(litter_nitrite_candidate_g_n) or litter_nitrite_candidate_g_n < 0)
                    return error.InvalidLitterSoilNitriteCandidate;
                var soil_nonband_phosphate_candidate = context.soil_chemistry.non_band_phosphate[top];
                var soil_band_phosphate_candidate = context.soil_chemistry.band_phosphate[top];
                const nonband_water_m3 = new_soil_water_m3 * nonband_phosphate;
                const band_water_m3 = new_soil_water_m3 * phosphate_band;
                if ((nonband_water_m3 == 0 and (soil_mineral[8] != 0 or soil_mineral[10] != 0)) or
                    (band_water_m3 == 0 and (soil_mineral[9] != 0 or soil_mineral[11] != 0)))
                    return error.SoilPhosphateWithoutWaterCarrier;
                soil_nonband_phosphate_candidate.dissolved_hpo4_mol_p_per_m3 = if (nonband_water_m3 > 0) soil_mineral[8] / nonband_water_m3 else 0;
                soil_band_phosphate_candidate.dissolved_hpo4_mol_p_per_m3 = if (band_water_m3 > 0) soil_mineral[9] / band_water_m3 else 0;
                soil_nonband_phosphate_candidate.dissolved_h2po4_mol_p_per_m3 = if (nonband_water_m3 > 0) soil_mineral[10] / nonband_water_m3 else 0;
                soil_band_phosphate_candidate.dissolved_h2po4_mol_p_per_m3 = if (band_water_m3 > 0) soil_mineral[11] / band_water_m3 else 0;

                try interface.publishCanonicalSolutes(
                    surface_amounts,
                    soil_amounts,
                    &litter_solute,
                    &soil_solute,
                    &soil_mineral,
                );
                try self.accumulateSurfaceChemistryRebaseRoundoff(
                    cell,
                    litter_mineral_roundoff,
                );
                context.surface_litter_chemistry.cells[cell] = litter_cell_candidate;
                context.surface_denitrification.nitrite_g_n[cell] = litter_nitrite_candidate_g_n;
                context.surface_litter_chemistry.dry_reference_water_m3[cell] =
                    litter_chemistry_carriers.dry_reference_after_m3;
                context.surface_litter_chemistry.mineral_reference_water_m3[cell] =
                    litter_mineral_reference_candidate_m3;
                @memcpy(matrix_n[0..8], soil_mineral[0..8]);
                context.soil_chemistry.non_band_phosphate[top] = soil_nonband_phosphate_candidate;
                context.soil_chemistry.band_phosphate[top] = soil_band_phosphate_candidate;
                for (0..interface.organic_fraction_count) |fraction| {
                    const litter_index = cell * organic_substrate_count + fraction;
                    const soil_index = top * organic_substrate_count + fraction;
                    context.surface_organic.dissolved[litter_index] = .{ .carbon_g_c = litter_organic[fraction].doc_g, .nitrogen_g_n = litter_organic[fraction].don_g, .phosphorus_g_p = litter_organic[fraction].dop_g };
                    context.surface_organic.dissolved_acetate_carbon_g_c[litter_index] = litter_organic[fraction].acetate_g;
                    context.soil_organic.dissolved[soil_index] = .{ .carbon_g_c = soil_organic[fraction].doc_g, .nitrogen_g_n = soil_organic[fraction].don_g, .phosphorus_g_p = soil_organic[fraction].dop_g };
                    context.soil_organic.dissolved_acetate_carbon_g_c[soil_index] = soil_organic[fraction].acetate_g;
                }
                const litter_organic_carbon_after_g_c = try context.surface_organic.totalCarbon_g_c(cell);
                const rebase_heat_megajoules = try ecosys.surface_litter_organic_heat_rebase.organicCarbonRebaseHeatMegajoules(
                    litter_organic_carbon_before_g_c,
                    litter_organic_carbon_after_g_c,
                    context.grid.surface_temperature_k[cell],
                    context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k,
                );
                // HEAT-001, the located day-89 gap. This site books
                // `sum_i c_org*dC_i*T_i`, one term per SUBSTEP at that substep's
                // temperature, and the whole-hour census evaluates
                // `c_org*(C_f*T_f - C_0*T_0)`. Expanding the census telescopically
                // gives `sum_i [dC_i*T_{i+1} + C_i*dT_i]`, so the per-substep
                // booking above is CORRECT and the uncancelled remainder is the
                // cross term `c_org * sum_i dC_i*dT_i` -- carbon moving while the
                // surface temperature drifts within the same hour. Accumulating
                // exactly that, for cell 0, so it can be compared against the
                // `7.13310266409195e-9` MJ residual with nothing fitted.
                if (cell == 0) {
                    const probe = context.diagnostic_litter_soil_rebase_drift;
                    const probe_temperature_k = context.grid.surface_temperature_k[cell];
                    const probe_carbon_step_g_c =
                        litter_organic_carbon_after_g_c - litter_organic_carbon_before_g_c;
                    probe.*[0] += 1;
                    probe.*[1] += probe_carbon_step_g_c * (probe_temperature_k - probe.*[3]);
                    probe.*[2] += probe_carbon_step_g_c * probe_temperature_k;
                    probe.*[3] = probe_temperature_k;
                    // `sum(dC_i)` is what the first probe design missed. The
                    // substep temperatures are NOT bracketed by the census
                    // endpoints -- the last one measured `275.40985990937395 K`
                    // against a census end of `275.04131626252627 K` -- so the
                    // identity that matters is each step's carbon priced at its
                    // own temperature versus at the temperature the census
                    // finally uses, which needs this sum.
                    probe.*[4] += probe_carbon_step_g_c;
                }
                const next_rebase_heat_megajoules =
                    self.litter_soil_organic_heat_rebase_total_megajoules_by_cell[cell] + rebase_heat_megajoules;
                if (!std.math.isFinite(next_rebase_heat_megajoules))
                    return error.NonFiniteLitterSoilOrganicHeatRebase;
                self.litter_soil_organic_heat_rebase_total_megajoules_by_cell[cell] = next_rebase_heat_megajoules;
                // HEAT-001's fix. The heat total just accumulated prices each
                // substep's carbon step at that substep's own surface
                // temperature, and those temperatures are not the ones the
                // census uses: measured on Ottawa day 89, the substeps reach
                // `275.40985990937395 K` against census endpoints
                // `275.0170923602946 -> 275.04131626252627 K`, giving a
                // carbon-weighted effective `275.2900006596837 K` and an
                // overprice of `+0.2487 K`. That is exactly the
                // `7.13310653372406e-9` MJ the surface scope could not close.
                // So carry the CARBON as well, and let the publisher reprice it
                // once at the census temperature.
                const next_carbon_step_total_g_c =
                    self.litter_soil_organic_carbon_step_total_g_c_by_cell[cell] +
                    (litter_organic_carbon_after_g_c - litter_organic_carbon_before_g_c);
                if (!std.math.isFinite(next_carbon_step_total_g_c))
                    return error.NonFiniteLitterSoilOrganicHeatRebase;
                self.litter_soil_organic_carbon_step_total_g_c_by_cell[cell] = next_carbon_step_total_g_c;
                try self.accumulateAcceptedLitterSoilChemistryActivity(cell, accepted_interface);
            }
        }

        noinline fn publishAcceptedLedgers(self: *Self) void {
            @memcpy(self.context.micropore_solute_face_flux_mol, self.micropore_face_total_mol);
            @memcpy(self.context.macropore_solute_face_flux_mol, self.macropore_face_total_mol);
            @memcpy(self.context.soil_solute_boundary_net_flux_mol, self.boundary_total_mol);
            @memcpy(self.context.soil_organic_transport.boundary_net_flux_g, self.organic_boundary_total_g);
            @memcpy(self.context.mineral_nitrogen_transport.boundary_export_g_n_per_step, self.mineral_boundary_total_g_n);
            @memcpy(self.context.soil_dissolved_gas_transport.boundary_net_flux_g, self.dissolved_gas_boundary_total_g);
            @memcpy(self.context.soil_gas_transport.atmospheric_flux_g_per_h, self.gas_atmospheric_total_g);
            @memcpy(self.context.soil_gas_transport.subsurface_flux_g_per_h, self.gas_subsurface_total_g);
            @memcpy(self.context.soil_gas_transport.accepted_face_flux_g_per_h, self.gas_face_total_g);
        }

        /// Publish the exact WATSUB/TRNSFR litter--topsoil transfer only to the
        /// independently accepted local scopes. The enclosing horizontal cell
        /// and landscape see an internal transfer and remain untouched. Dry
        /// organic carbon additionally changes the surface sensible capacity,
        /// so its fixed-temperature heat rebase is published to all three heat
        /// ledgers in the same atomic candidate transaction.
        noinline fn publishLitterSoilOrganicHeatRebase(self: *Self) !void {
            const context = self.context;
            // HEAT-001. Reprice the hour's accumulated carbon steps at the
            // temperature the census actually uses, discarding the per-substep
            // pricing. The census stores surface organic enthalpy as
            // `c_org * totalCarbon_g_c * grid.surface_temperature_k`
            // (`landscape_mass_inventory_surface.zig:512-517`, `:533`), and this
            // publisher runs after the substep loop has closed, so that
            // temperature is final and available here. Pricing per substep
            // instead put `7.13310653372406e-9` MJ into the surface scope that
            // no census evaluation could attribute -- 99.91% of the day-89 cell
            // residual and the reason the deck stopped there.
            const dry_organic_heat_capacity =
                context.runscript.surface_pond_dry_organic_heat_capacity_megajoules_per_g_c_k;
            for (
                self.litter_soil_organic_heat_rebase_total_megajoules_by_cell,
                self.litter_soil_organic_carbon_step_total_g_c_by_cell,
                context.grid.surface_temperature_k,
            ) |*heat_megajoules, carbon_step_g_c, census_temperature_k| {
                if (!std.math.isFinite(census_temperature_k) or census_temperature_k <= 0)
                    return error.InvalidSurfaceLitterRebaseTemperature;
                const repriced = dry_organic_heat_capacity * carbon_step_g_c * census_temperature_k;
                if (!std.math.isFinite(repriced))
                    return error.NonFiniteLitterSoilOrganicHeatRebase;
                heat_megajoules.* = repriced;
            }
            const cell_candidate_values = try self.allocator.dupe(
                ecosys.hourly_cell_conservation.BoundaryActivity,
                context.hourly_cell_boundary_ledger.cells,
            );
            defer self.allocator.free(cell_candidate_values);
            var cell_candidate: ecosys.hourly_cell_conservation.BoundaryLedger = .{
                .allocator = self.allocator,
                .cells = cell_candidate_values,
            };
            try cell_candidate.accumulateSignedInternalHeat(
                self.litter_soil_organic_heat_rebase_total_megajoules_by_cell,
            );

            const layer_candidate_values = try self.allocator.dupe(
                ecosys.hourly_cell_conservation.BoundaryActivity,
                context.hourly_layer_boundary_ledger.activity,
            );
            defer self.allocator.free(layer_candidate_values);
            var layer_candidate: ecosys.layer_local_conservation.Ledger = .{
                .allocator = self.allocator,
                .layout = context.hourly_layer_boundary_ledger.layout,
                .activity = layer_candidate_values,
            };
            try ecosys.layer_local_conservation.accumulateLitterSoilInterfaceActivity(
                &layer_candidate,
                context.grid.active_soil_layer_count,
                self.litter_soil_surface_to_topsoil_total,
                self.litter_soil_topsoil_to_surface_total,
            );
            try ecosys.layer_local_conservation.accumulateSurfaceOrganicHeatRebase(
                &layer_candidate,
                self.litter_soil_organic_heat_rebase_total_megajoules_by_cell,
            );

            var landscape_candidate = context.landscape_boundary_ledger.*;
            var landscape_heat_megajoules: f64 = 0;
            for (self.litter_soil_organic_heat_rebase_total_megajoules_by_cell) |heat_megajoules| {
                landscape_heat_megajoules += heat_megajoules;
                if (!std.math.isFinite(landscape_heat_megajoules))
                    return error.NonFiniteLitterSoilOrganicHeatRebase;
            }
            try landscape_candidate.accumulateAcceptedSignedInternalHeat(landscape_heat_megajoules);

            @memcpy(context.hourly_cell_boundary_ledger.cells, cell_candidate_values);
            @memcpy(context.hourly_layer_boundary_ledger.activity, layer_candidate_values);
            context.landscape_boundary_ledger.* = landscape_candidate;
        }

        noinline fn publishAcceptedSurfaceTemperature(self: *Self) !void {
            const context = self.context;
            // N1's decisive comparison, diagnostic only: the surface solver's
            // OWN hour-accumulated residual, beside the surface scope's
            // ledger gap. `-009` measured that the scope residual is
            // insensitive to both tolerances that govern its acceptance, and
            // register `:7962-7971` argues a dropped term would be `O(1)`
            // relative rather than the observed `1.2268e-9`. Both named
            // branches are therefore constrained, and these two numbers
            // separate them: if the signed total equals the scope's
            // `storage_step - booked_step`, the defect IS the accepted process
            // residual; if it is ~0, a term reaches surface storage without
            // passing through the residual at all.
            //
            // The arrays already exist and are already summed by the budget
            // check below, so this adds arithmetic over `cell_count` and
            // changes no solver behaviour, no acceptance, and no state.
            var surface_residual_signed_megajoules: f64 = 0;
            var surface_residual_absolute_megajoules: f64 = 0;
            for (
                self.surface_energy_residual_signed_total_megajoules_by_cell,
                self.surface_energy_residual_absolute_total_megajoules_by_cell,
            ) |signed_megajoules, absolute_megajoules| {
                surface_residual_signed_megajoules += signed_megajoules;
                surface_residual_absolute_megajoules += absolute_megajoules;
            }
            if (!std.math.isFinite(surface_residual_signed_megajoules) or
                !std.math.isFinite(surface_residual_absolute_megajoules))
                return error.NonFiniteHourlyFailureTrace;
            context.diagnostic_surface_energy_residual_signed_megajoules.* =
                surface_residual_signed_megajoules;
            context.diagnostic_surface_energy_residual_absolute_megajoules.* =
                surface_residual_absolute_megajoules;
            try requireAcceptedSurfaceResidualBudget(.{
                .signed_total_megajoules = self.surface_energy_residual_signed_total_megajoules_by_cell,
                .absolute_total_megajoules = self.surface_energy_residual_absolute_total_megajoules_by_cell,
                .net_radiation_megajoules_per_m2 = self.surface_energy_total.net_radiation_megajoules_per_m2,
                .sensible_heat_megajoules_per_m2 = self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2,
                .latent_heat_megajoules_per_m2 = self.surface_temperature_total.latent_heat_flux_megajoules_per_m2,
                .vapor_sensible_heat_megajoules_per_m2 = self.surface_temperature_total.vapor_sensible_heat_flux_megajoules_per_m2,
                .conductive_heat_megajoules_per_m2 = self.surface_temperature_total.conductive_heat_flux_megajoules_per_m2,
                .phase_heat_megajoules_per_m2 = self.surface_temperature_total.phase_heat_flux_megajoules_per_m2,
                .snow_boundary_heat_megajoules = self.snow_boundary_heat_total_megajoules,
                .snow_reference_state_heat_megajoules = self.snow_reference_state_heat_megajoules_by_cell,
                .external_heat_megajoules = context.delayed_surface_combustion_heat_megajoules,
                .cell_area_m2 = context.canopy_cell_area_m2,
                // REAL-DECK-HOUR-11-FATAL-STAGNATION-001 (2026-09-04): this
                // check's own accumulated-absolute-residual design is
                // confirmed intentional (see "surface residual budget
                // rejects same-sign accumulation and hidden cancellation"),
                // but a real captured deck failure showed
                // mass_balance_absolute_tolerance.heat_megajoules_m2 at its
                // hardcoded runscript-parser default of exactly 0 lets a
                // genuinely negligible (~0.0015 J) same-signed per-substep
                // solver bias reject an otherwise-accepted schedule. Adding
                // a local floor HERE (not editing the shared config value,
                // which an A/B run proved is read by 7 other call sites
                // across the model and caused a worse regression when
                // touched globally) only affects this one surface-specific
                // ledger, matching this function's own existing test
                // fixture's validated absolute_tolerance_megajoules_per_m2
                // = 1.0e-9 constant. That threshold repeatedly made accepted
                // science depend on code layout at 0.0015-0.0104 J m-2. The
                // residual is now explicitly projected into the published
                // atmospheric sensible-transfer lane without perturbing a
                // downstream solver, so this check bounds a conserved
                // correction rather than permitting lost energy. One joule
                // per square metre per hour is a clear
                // physical cap (0.000278 W m-2), still negligible beside the
                // observed 0.1-0.8 MJ m-2 hourly activity; signed and absolute
                // accumulation continue to reject drift and cancellation.
                .absolute_tolerance_megajoules_per_m2 = @max(
                    context.config.mass_balance_absolute_tolerance.heat_megajoules_m2,
                    1.0e-6,
                ),
                .relative_tolerance = context.config.mass_balance_relative_tolerance,
                .substep_count = self.exact_substep_count,
            });
            for (0..context.grid.cell_count) |cell| {
                if (self.surface_iteration_total[cell] > std.math.maxInt(u16) or
                    self.surface_newton_total[cell] > std.math.maxInt(u16) or
                    self.surface_picard_total[cell] > std.math.maxInt(u16))
                    return error.SurfaceTemperatureIterationCountOverflow;
                self.surface_temperature_total.iteration_count[cell] = @intCast(self.surface_iteration_total[cell]);
                self.surface_temperature_total.newton_raphson_step_count[cell] = @intCast(self.surface_newton_total[cell]);
                self.surface_temperature_total.picard_step_count[cell] = @intCast(self.surface_picard_total[cell]);
            }
            try self.surface_temperature_total.validateFinite();
            _ = try self.surface_temperature_total.validateConvergence();
            inline for (.{
                self.surface_energy_total.downward_sky_longwave_megajoules_per_m2,
                self.surface_energy_total.emitted_sky_longwave_megajoules_per_m2,
                self.surface_energy_total.net_longwave_megajoules_per_m2,
                self.surface_energy_total.net_radiation_megajoules_per_m2,
                self.surface_conduction_total_megajoules,
            }) |values| for (values) |value|
                if (!std.math.isFinite(value)) return error.NonFiniteAcceptedSurfaceTemperatureLedger;

            inline for (@typeInfo(ecosys.surface_temperature_solver.State).@"struct".fields) |field| {
                if (comptime field.type == []f64 or field.type == []u16)
                    @memcpy(@field(context.surface_temperature, field.name), @field(self.surface_temperature_total, field.name));
            }
            inline for (.{
                "downward_sky_longwave_megajoules_per_m2",
                "emitted_sky_longwave_megajoules_per_m2",
                "net_longwave_megajoules_per_m2",
                "net_radiation_megajoules_per_m2",
            }) |field_name|
                @memcpy(@field(context.surface_energy, field_name), @field(self.surface_energy_total, field_name));
            @memcpy(
                context.soil_hourly_workspace.published_surface_conduction_heat_megajoules,
                self.surface_conduction_total_megajoules,
            );
            // Delayed combustion is consumed only after every retry substep and
            // all private diagnostics have passed their publication preflight.
            // The exact producer is booked here, before it is zeroed; the
            // surface residual's mixed fluxes cannot reconstruct this term.
            try context.hourly_cell_boundary_ledger.preflightSignedInternalHeat(
                context.delayed_surface_combustion_heat_megajoules,
            );
            try ecosys.layer_local_conservation.accumulateSurfaceCombustionHeat(
                context.hourly_layer_boundary_ledger,
                context.delayed_surface_combustion_heat_megajoules,
            );
            try context.landscape_boundary_ledger.accumulateAcceptedSurfaceCombustionHeat(
                context.delayed_surface_combustion_heat_megajoules,
            );
            try context.hourly_cell_boundary_ledger.accumulateSignedInternalHeat(
                context.delayed_surface_combustion_heat_megajoules,
            );
            @memset(context.delayed_surface_combustion_heat_megajoules, 0);
            @memset(context.surface_combustion_heat_megajoules_per_m2, 0);
            // WATSUB CVRDW is both the accepted radiation partition and the
            // next-hour precipitation/transport cover owner. Failed schedules
            // never reach this publication point.
            @memcpy(
                context.surface_precipitation.litter_cover_fraction,
                self.surface_live_litter_cover_fraction,
            );
        }

        noinline fn publishAcceptedGroundAir(self: *Self) !void {
            const context = self.context;
            return publishAcceptedGroundAirPhase(.{
                .cell_count = context.grid.cell_count,
                .ground_air = context.ground_air,
                .geometry_balance = self.ground_air_geometry_balance,
                .vapor_balance_total = self.ground_air_vapor_balance_total,
                .sensible_heat_closure_absolute_total_megajoules = self.ground_air_sensible_heat_closure_absolute_total_megajoules,
                .sensible_heat_storage_activity_total_megajoules = self.ground_air_sensible_heat_storage_activity_total_megajoules,
                .sensible_heat_transfer_activity_total_megajoules = self.ground_air_sensible_heat_transfer_activity_total_megajoules,
                .sensible_heat_arithmetic_activity_total_megajoules = self.ground_air_sensible_heat_arithmetic_activity_total_megajoules,
                .iteration_total = self.ground_air_iteration_total,
                .canopy_cell_area_m2 = context.canopy_cell_area_m2,
                .water_absolute_tolerance_m = context.config.mass_balance_absolute_tolerance.water_m,
                .heat_absolute_tolerance_megajoules_per_m2 = context.config.mass_balance_absolute_tolerance.heat_megajoules_m2,
                .relative_tolerance = context.config.mass_balance_relative_tolerance,
                .accepted_substep_count = self.ground_air_accepted_substep_count,
                .accepted_duration_hours = self.ground_air_accepted_duration_hours,
                .expected_substep_count = self.exact_substep_count,
            });
        }

        noinline fn publishAcceptedAtmosphericLocalActivity(self: *Self) !void {
            const context = self.context;
            const activities = try self.allocator.alloc(
                ecosys.atmospheric_local_conservation_sidecar.CellActivity,
                context.grid.cell_count,
            );
            defer self.allocator.free(activities);
            const accepted_ground_evaporation_m3 = try self.allocator.alloc(
                f64,
                context.grid.cell_count,
            );
            defer self.allocator.free(accepted_ground_evaporation_m3);
            const accepted_ground_condensation_m3 = try self.allocator.alloc(
                f64,
                context.grid.cell_count,
            );
            defer self.allocator.free(accepted_ground_condensation_m3);
            try composeAcceptedGroundSurfaceWaterTotals(
                accepted_ground_evaporation_m3,
                accepted_ground_condensation_m3,
                self.forcing.litter_evaporation_total_m3,
                self.forcing.topsoil_evaporation_total_m3,
                self.snow_evaporation_total_m3,
                self.forcing.litter_condensation_total_m3,
                self.forcing.topsoil_condensation_total_m3,
                self.snow_condensation_total_m3,
            );
            const topsoil_atmospheric_heat_megajoules = try self.allocator.alloc(
                f64,
                context.grid.cell_count,
            );
            defer self.allocator.free(topsoil_atmospheric_heat_megajoules);
            const chemistry_mass = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol;
            for (activities, 0..) |*activity, cell| {
                const primary_first = cell * ecosys.snow_solute_transport.species_count;
                const salt_first = cell * ecosys.snow_solute_transport.salt_species_count;
                var chemistry: ecosys.atmospheric_local_conservation_sidecar.ChemistryInputs = .{
                    .direct_surface_and_soil = context.direct_surface_solute_input[cell],
                    .ion_molar_mass_g_per_mol = .{
                        .aluminum = chemistry_mass.aluminum,
                        .iron = chemistry_mass.iron,
                        .calcium = chemistry_mass.calcium,
                        .magnesium = chemistry_mass.magnesium,
                        .sodium = chemistry_mass.sodium,
                        .potassium = chemistry_mass.potassium,
                        .sulfur = chemistry_mass.sulfur,
                        .chloride = chemistry_mass.chloride,
                    },
                };
                @memcpy(
                    &chemistry.top_snow_input_g,
                    self.snow_atmospheric_input_total_g[primary_first..][0..ecosys.snow_solute_transport.species_count],
                );
                @memcpy(
                    &chemistry.top_snow_input_salt_mol,
                    self.snow_atmospheric_input_total_salt_mol[salt_first..][0..ecosys.snow_solute_transport.salt_species_count],
                );

                // The published surface diagnostics combine exposed-ground
                // and snow fluxes.  Snow's canonical boundary heat is owned
                // independently below; remove only its four represented
                // components here, leaving its frozen-reference remainder in
                // the snow owner exactly once.
                const combined_surface_heat_megajoules = context.canopy_cell_area_m2[cell] *
                    (self.surface_energy_total.net_radiation_megajoules_per_m2[cell] +
                        self.surface_temperature_total.sensible_heat_flux_megajoules_per_m2[cell] +
                        self.surface_temperature_total.latent_heat_flux_megajoules_per_m2[cell] +
                        self.surface_temperature_total.vapor_sensible_heat_flux_megajoules_per_m2[cell]);
                const represented_snow_heat_megajoules = self.snow_boundary_heat_total_megajoules[cell] -
                    self.snow_reference_state_heat_megajoules_by_cell[cell];
                const exposed_ground_heat_megajoules = combined_surface_heat_megajoules -
                    represented_snow_heat_megajoules;
                if (!std.math.isFinite(exposed_ground_heat_megajoules))
                    return error.NonFiniteAcceptedAtmosphericLocalHeat;
                topsoil_atmospheric_heat_megajoules[cell] = try checkedAddFiniteValue(
                    self.forcing.topsoil_vapor_heat_total_megajoules[cell],
                    self.topsoil_sensible_heat_total_megajoules[cell],
                );

                activity.* = try ecosys.atmospheric_local_conservation_sidecar.acceptedCellActivity(
                    .{
                        .liquid_precipitation_m3 = context.surface_precipitation.rainfall_m3_per_h[cell],
                        .solid_precipitation_water_equivalent_m3 = self.snow_solid_input_total_m3[cell],
                        .canopy_retention_m3 = context.surface_precipitation.intercepted_rain_m3_per_h[cell],
                        .liquid_to_top_snow_m3 = self.snow_liquid_input_total_m3[cell],
                        .liquid_to_surface_litter_m3 = self.base_water_to_litter_m3_per_h[cell],
                        .liquid_to_topsoil_matrix_m3 = self.base_water_to_matrix_m3_per_h[cell],
                        .liquid_to_topsoil_macropore_m3 = self.base_water_to_macropore_m3_per_h[cell],
                        .atmospheric_temperature_k = context.surface_precipitation.atmospheric_temperature_k[cell],
                        .liquid_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                        .solid_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
                        .latent_heat_of_fusion_megajoules_per_m3 = context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
                        .pure_water_melting_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
                        .water_absolute_tolerance_m3 = context.config.mass_balance_absolute_tolerance.water_m * context.canopy_cell_area_m2[cell],
                        .relative_tolerance = context.config.mass_balance_relative_tolerance,
                    },
                    .{
                        .snow_evaporation_m3 = self.snow_evaporation_total_m3[cell],
                        .snow_condensation_m3 = self.snow_condensation_total_m3[cell],
                        .snow_boundary_heat_megajoules = self.snow_boundary_heat_total_megajoules[cell],
                        .litter_evaporation_m3 = self.forcing.litter_evaporation_total_m3[cell],
                        .topsoil_evaporation_m3 = self.forcing.topsoil_evaporation_total_m3[cell],
                        .litter_condensation_m3 = self.forcing.litter_condensation_total_m3[cell],
                        .topsoil_condensation_m3 = self.forcing.topsoil_condensation_total_m3[cell],
                        .surface_boundary_heat_megajoules = exposed_ground_heat_megajoules,
                        .topsoil_boundary_heat_megajoules = try checkedAddFiniteValue(
                            self.forcing.topsoil_vapor_heat_total_megajoules[cell],
                            self.topsoil_sensible_heat_total_megajoules[cell],
                        ),
                    },
                    chemistry,
                );
            }

            const cell_candidate_values = try self.allocator.dupe(
                ecosys.hourly_cell_conservation.BoundaryActivity,
                context.hourly_cell_boundary_ledger.cells,
            );
            defer self.allocator.free(cell_candidate_values);
            var cell_candidate: ecosys.hourly_cell_conservation.BoundaryLedger = .{
                .allocator = self.allocator,
                .cells = cell_candidate_values,
            };
            var landscape_candidate = context.landscape_boundary_ledger.*;
            try accumulateAcceptedTopsoilAtmosphericHeat(
                &cell_candidate,
                &landscape_candidate,
                topsoil_atmospheric_heat_megajoules,
            );
            const candidate_values = try self.allocator.dupe(
                ecosys.hourly_cell_conservation.BoundaryActivity,
                context.hourly_layer_boundary_ledger.activity,
            );
            defer self.allocator.free(candidate_values);
            var candidate: ecosys.layer_local_conservation.Ledger = .{
                .allocator = self.allocator,
                .layout = context.hourly_layer_boundary_ledger.layout,
                .activity = candidate_values,
            };
            try ecosys.layer_local_conservation.accumulateAcceptedAtmosphericActivity(
                &candidate,
                context.grid.active_soil_layer_count,
                self.snow_activity_active_by_layer,
                activities,
            );
            context.landscape_boundary_ledger.* = landscape_candidate;
            @memcpy(context.hourly_cell_boundary_ledger.cells, cell_candidate_values);
            @memcpy(context.hourly_layer_boundary_ledger.activity, candidate_values);
            // These legacy fields are consumed after WATSUB as a one-hour
            // volume (the external hour is exactly one hour).  Publish the
            // accepted integrated totals only after every local ledger
            // preflight has succeeded, replacing the private schedule's
            // transient sum of substep rates.
            @memcpy(
                context.ground_surface_evaporation_m3_per_h,
                accepted_ground_evaporation_m3,
            );
            @memcpy(
                context.ground_surface_condensation_m3_per_h,
                accepted_ground_condensation_m3,
            );
        }

        noinline fn publishAcceptedSnowSchedule(self: *Self) !void {
            const context = self.context;
            var phase_sum: f64 = 0;
            var vapor_sum: f64 = 0;
            var inactive_reference_sum: f64 = 0;
            for (self.snow_phase_heat_total_megajoules_by_cell) |value| phase_sum = try checkedAddFiniteValue(phase_sum, value);
            for (self.snow_vapor_heat_total_megajoules_by_cell) |value| vapor_sum = try checkedAddFiniteValue(vapor_sum, value);
            for (self.snow_inactive_reference_heat_total_megajoules_by_cell) |value|
                inactive_reference_sum = try checkedAddFiniteValue(inactive_reference_sum, value);
            const heat_scale = @max(
                1,
                @max(
                    @abs(self.snow_phase_heat_total_megajoules),
                    @max(
                        @abs(self.snow_vapor_heat_total_megajoules),
                        @abs(self.snow_inactive_reference_heat_total_megajoules),
                    ),
                ),
            );
            if (@abs(phase_sum - self.snow_phase_heat_total_megajoules) > 64 * std.math.floatEps(f64) * heat_scale or
                @abs(vapor_sum - self.snow_vapor_heat_total_megajoules) > 64 * std.math.floatEps(f64) * heat_scale or
                @abs(inactive_reference_sum - self.snow_inactive_reference_heat_total_megajoules) > 64 * std.math.floatEps(f64) * heat_scale)
                return error.SnowSubstepHeatPerCellMismatch;

            if (!builtin.is_test) for (0..context.grid.cell_count) |cell| {
                const first = cell * context.snow_transport.layer_capacity;
                const end = first + context.snow_transport.layer_capacity;
                var vapor_water_m3: f64 = 0;
                var vapor_carrier_heat_megajoules: f64 = 0;
                var conduction_heat_megajoules: f64 = 0;
                var melt_heat_megajoules: f64 = 0;
                for (first..end) |layer| {
                    vapor_water_m3 = try checkedAddFiniteValue(
                        vapor_water_m3,
                        self.snow_vapor_diffusion_water_total_m3_by_layer[layer],
                    );
                    vapor_carrier_heat_megajoules = try checkedAddFiniteValue(
                        vapor_carrier_heat_megajoules,
                        self.snow_vapor_diffusion_heat_total_megajoules_by_layer[layer],
                    );
                    conduction_heat_megajoules = try checkedAddFiniteValue(
                        conduction_heat_megajoules,
                        self.snow_conduction_heat_total_megajoules_by_layer[layer],
                    );
                    melt_heat_megajoules = try checkedAddFiniteValue(
                        melt_heat_megajoules,
                        self.snow_melt_heat_total_megajoules_by_layer[layer],
                    );
                }
                if (vapor_water_m3 != 0) std.log.debug(
                    "hourly snow vapor ownership: cell={d} vapor_water_m3={e} vapor_carrier_heat_mj={e} conduction_heat_mj={e} melt_heat_mj={e} atmospheric_solid_m3={e} atmospheric_liquid_m3={e} atmospheric_heat_mj={e} surface_boundary_heat_mj={e} surface_reference_heat_mj={e} phase_internal_heat_mj={e} vapor_internal_heat_mj={e} inactive_reference_heat_mj={e} discharge_heat_mj={e} surface_transfer_heat_mj={e} topsoil_transfer_heat_mj={e}",
                    .{
                        cell,
                        vapor_water_m3,
                        vapor_carrier_heat_megajoules,
                        conduction_heat_megajoules,
                        melt_heat_megajoules,
                        self.snow_solid_input_total_m3[cell],
                        self.snow_liquid_input_total_m3[cell],
                        self.snow_heat_input_total_megajoules[cell],
                        self.snow_boundary_heat_total_megajoules[cell],
                        self.snow_reference_state_heat_megajoules_by_cell[cell],
                        self.snow_phase_heat_total_megajoules_by_cell[cell],
                        self.snow_vapor_heat_total_megajoules_by_cell[cell],
                        self.snow_inactive_reference_heat_total_megajoules_by_cell[cell],
                        self.snow_discharge_heat_total_megajoules_by_cell[cell],
                        self.snow_surface_transfer_heat_total_megajoules_by_cell[cell],
                        self.snow_topsoil_transfer_heat_total_megajoules_by_cell[cell],
                    },
                );
            };

            // Preflight every ledger operation before publishing any schedule
            // output. The stage snapshot remains the final rollback owner.
            const signed_heat = try checkedAddFiniteValue(
                try checkedAddFiniteValue(
                    self.snow_phase_heat_total_megajoules,
                    self.snow_vapor_heat_total_megajoules,
                ),
                self.snow_inactive_reference_heat_total_megajoules,
            );
            var landscape_candidate = context.landscape_boundary_ledger.*;
            try landscape_candidate.accumulateAcceptedSignedInternalHeat(signed_heat);
            const cell_candidate_values = try self.allocator.dupe(ecosys.hourly_cell_conservation.BoundaryActivity, context.hourly_cell_boundary_ledger.cells);
            defer self.allocator.free(cell_candidate_values);
            var cell_candidate: ecosys.hourly_cell_conservation.BoundaryLedger = .{ .allocator = self.allocator, .cells = cell_candidate_values };
            try cell_candidate.accumulateSignedInternalHeat(self.snow_phase_heat_total_megajoules_by_cell);
            try cell_candidate.accumulateSignedInternalHeat(self.snow_vapor_heat_total_megajoules_by_cell);
            try cell_candidate.accumulateSignedInternalHeat(
                self.snow_inactive_reference_heat_total_megajoules_by_cell,
            );
            const layer_candidate_values = try self.allocator.dupe(
                ecosys.hourly_cell_conservation.BoundaryActivity,
                context.hourly_layer_boundary_ledger.activity,
            );
            defer self.allocator.free(layer_candidate_values);
            var layer_candidate: ecosys.layer_local_conservation.Ledger = .{
                .allocator = self.allocator,
                .layout = context.hourly_layer_boundary_ledger.layout,
                .activity = layer_candidate_values,
            };
            const molar_mass = context.runscript.chemistry_primary_initialization.molar_mass_g_per_mol;
            try ecosys.layer_local_conservation.accumulateSnowTransportActivity(
                &layer_candidate,
                .{
                    .active_by_layer = self.snow_activity_active_by_layer,
                    .downward_liquid_water_m3_by_destination = self.snow_downward_water_total_m3,
                    .downward_liquid_heat_megajoules_by_destination = self.snow_melt_heat_total_megajoules_by_layer,
                    .conduction_heat_megajoules_by_destination = self.snow_conduction_heat_total_megajoules_by_layer,
                    .vapor_water_m3_by_destination = self.snow_vapor_diffusion_water_total_m3_by_layer,
                    .vapor_heat_megajoules_by_destination = self.snow_vapor_diffusion_heat_total_megajoules_by_layer,
                    .vapor_water_downward_m3_by_destination = self.snow_vapor_diffusion_water_downward_total_m3_by_layer,
                    .vapor_water_upward_m3_by_destination = self.snow_vapor_diffusion_water_upward_total_m3_by_layer,
                    .vapor_heat_downward_megajoules_by_destination = self.snow_vapor_diffusion_heat_downward_total_megajoules_by_layer,
                    .vapor_heat_upward_megajoules_by_destination = self.snow_vapor_diffusion_heat_upward_total_megajoules_by_layer,
                    .vapor_equilibrium_heat_megajoules_by_layer = self.snow_vapor_equilibrium_heat_total_megajoules_by_layer,
                    .inactive_reference_heat_megajoules_by_layer = self.snow_inactive_reference_heat_total_megajoules_by_layer,
                    .accepted_downward_g_by_source_species = self.snow_accepted_downward_total_g,
                    .accepted_downward_salt_mol_by_source_species = self.snow_accepted_downward_total_salt_mol,
                    .dynamic_salts_by_cell = context.snow_transport.dynamic_salts_by_cell,
                    .molar_mass_g_per_mol = .{
                        .nitrogen = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                        .phosphorus = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                        .ions = .{
                            .aluminum = molar_mass.aluminum,
                            .iron = molar_mass.iron,
                            .calcium = molar_mass.calcium,
                            .magnesium = molar_mass.magnesium,
                            .sodium = molar_mass.sodium,
                            .potassium = molar_mass.potassium,
                            .sulfur = molar_mass.sulfur,
                            .chloride = molar_mass.chloride,
                        },
                    },
                },
            );
            try ecosys.layer_local_conservation.accumulateSnowRelayeringActivity(
                &layer_candidate,
                .{
                    .active_by_layer = self.snow_activity_active_by_layer,
                    .transfers = &self.snow_relayering_total,
                    .dynamic_salts_by_cell = context.snow_transport.dynamic_salts_by_cell,
                    .ice_density_megagrams_per_m3 = context.runscript.snow_ice_density_megagrams_per_m3,
                    .latent_heat_of_fusion_megajoules_per_m3 = context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3,
                    .thermodynamics = .{
                        .solid_snow_heat_capacity_megajoules_per_m3_k = context.runscript.snow_solid_heat_capacity_megajoules_per_m3_k,
                        .liquid_water_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
                        .ice_heat_capacity_megajoules_per_m3_k = context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
                        .pure_water_melting_temperature_k = context.runscript.soil_phase_heat_parameters.freeze_thaw.pure_water_freezing_temperature_k,
                    },
                    .molar_mass_g_per_mol = .{
                        .nitrogen = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                        .phosphorus = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                        .ions = .{
                            .aluminum = molar_mass.aluminum,
                            .iron = molar_mass.iron,
                            .calcium = molar_mass.calcium,
                            .magnesium = molar_mass.magnesium,
                            .sodium = molar_mass.sodium,
                            .potassium = molar_mass.potassium,
                            .sulfur = molar_mass.sulfur,
                            .chloride = molar_mass.chloride,
                        },
                    },
                },
            );
            try ecosys.layer_local_conservation.accumulateSnowSurfaceSoilTransferActivity(
                &layer_candidate,
                .{
                    .active_snow_by_layer = self.snow_activity_active_by_layer,
                    .active_soil_layer_count_by_cell = context.grid.active_soil_layer_count,
                    .donor_water_m3_by_snow_layer = self.snow_discharge_water_total_m3_by_source_layer,
                    .donor_heat_megajoules_by_snow_layer = self.snow_discharge_heat_total_megajoules_by_source_layer,
                    .donor_g_by_snow_layer_species = self.snow_discharge_total_g_by_source_layer_species,
                    .donor_salt_mol_by_snow_layer_species = self.snow_discharge_total_salt_mol_by_source_layer_species,
                    .surface_water_m3_by_cell = self.snow_surface_transfer_water_total_m3_by_cell,
                    .topsoil_water_m3_by_cell = self.snow_topsoil_transfer_water_total_m3_by_cell,
                    .surface_heat_megajoules_by_cell = self.snow_surface_transfer_heat_total_megajoules_by_cell,
                    .topsoil_heat_megajoules_by_cell = self.snow_topsoil_transfer_heat_total_megajoules_by_cell,
                    .accepted_chemistry_by_cell = self.snow_surface_discharge_total,
                    .dynamic_salts_by_cell = context.snow_transport.dynamic_salts_by_cell,
                    .molar_mass_g_per_mol = .{
                        .nitrogen = context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
                        .phosphorus = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
                        .ions = .{
                            .aluminum = molar_mass.aluminum,
                            .iron = molar_mass.iron,
                            .calcium = molar_mass.calcium,
                            .magnesium = molar_mass.magnesium,
                            .sodium = molar_mass.sodium,
                            .potassium = molar_mass.potassium,
                            .sulfur = molar_mass.sulfur,
                            .chloride = molar_mass.chloride,
                        },
                    },
                },
            );

            try ecosys.layer_local_conservation.accumulateSnowBaseConductionActivity(
                &layer_candidate,
                self.snow_activity_active_by_layer,
                context.grid.active_soil_layer_count,
                self.snow_base_litter_conduction_heat_total_megajoules_by_source_layer,
                self.snow_base_topsoil_conduction_heat_total_megajoules_by_source_layer,
            );

            @memcpy(context.transport_hydrology.snow_downward_water_flux_m3_per_step, self.snow_downward_water_total_m3);
            @memcpy(context.transport_hydrology.snow_to_litter_water_flux_m3_per_step, self.snow_to_litter_water_total_m3);
            @memcpy(context.transport_hydrology.snow_to_soil_micropore_flux_m3_per_step, self.snow_to_matrix_water_total_m3);
            @memcpy(context.transport_hydrology.snow_to_soil_macropore_flux_m3_per_step, self.snow_to_macropore_water_total_m3);
            @memcpy(context.snow_accepted_downward_g, self.snow_accepted_downward_total_g);
            @memcpy(context.snow_accepted_downward_salt_mol, self.snow_accepted_downward_total_salt_mol);
            @memcpy(context.snow_surface_discharge, self.snow_surface_discharge_total);
            for (0..context.grid.cell_count) |cell| {
                context.surface_precipitation.water_to_litter_m3_per_h[cell] = self.base_water_to_litter_m3_per_h[cell] + self.snow_to_litter_water_total_m3[cell];
                context.surface_precipitation.water_to_matrix_m3_per_h[cell] = self.base_water_to_matrix_m3_per_h[cell] + self.snow_to_matrix_water_total_m3[cell];
                context.surface_precipitation.water_to_macropore_m3_per_h[cell] = self.base_water_to_macropore_m3_per_h[cell] + self.snow_to_macropore_water_total_m3[cell];
                var accepted_solid_snow_water_equivalent_m3: f64 = 0;
                for (0..context.snow_transport.layer_capacity) |layer|
                    accepted_solid_snow_water_equivalent_m3 = try checkedAddFiniteValue(
                        accepted_solid_snow_water_equivalent_m3,
                        context.snow_transport.solid_snow_water_equivalent_m3[
                            cell * context.snow_transport.layer_capacity + layer
                        ],
                    );
                context.surface_precipitation.solid_snow_water_equivalent_m3[cell] =
                    accepted_solid_snow_water_equivalent_m3;
            }

            const layer_capacity = context.snow_transport.layer_capacity;
            const snow_layer_count = try std.math.mul(usize, context.grid.cell_count, layer_capacity);
            const salt_species_count = ecosys.snowpack_internal_salt_aggregation.salt_species_count;
            const salt_value_count = try std.math.mul(usize, snow_layer_count, salt_species_count);
            const salt_layer_value_count = try std.math.mul(usize, layer_capacity, salt_species_count);
            const salt_net_mol = try self.allocator.alloc(f64, salt_value_count);
            defer self.allocator.free(salt_net_mol);
            @memset(salt_net_mol, 0);
            const solute_net = try self.allocator.alloc(ecosys.snowpack_internal_solute_aggregation.SoluteFlux, snow_layer_count);
            defer self.allocator.free(solute_net);
            @memset(solute_net, .{});
            @memset(context.snowpack_internal_solute_flux_by_layer, .{});
            @memset(context.snowpack_internal_solute_flux_workspace, .{});
            @memset(context.snowpack_internal_salt_flux_mol_by_layer_species, 0);
            @memset(context.snowpack_internal_salt_flux_workspace_by_layer_species, 0);
            for (0..context.grid.cell_count) |cell| {
                const cell_layer_start = cell * layer_capacity;
                for (1..layer_capacity) |layer| {
                    const face_layer_start = cell_layer_start + layer;
                    const source_layer_start = (face_layer_start - 1) * ecosys.snow_solute_transport.species_count;
                    context.snowpack_internal_solute_flux_by_layer[face_layer_start] =
                        group_support.snowpackInternalNonSaltFluxFromSpeciesAmounts(
                            context.snow_accepted_downward_g[source_layer_start .. source_layer_start + ecosys.snow_solute_transport.species_count],
                        );
                    const salt_face_start = face_layer_start * salt_species_count;
                    const salt_source_start = (face_layer_start - 1) * salt_species_count;
                    @memcpy(
                        context.snowpack_internal_salt_flux_mol_by_layer_species[salt_face_start .. salt_face_start + salt_species_count],
                        context.snow_accepted_downward_salt_mol[salt_source_start .. salt_source_start + salt_species_count],
                    );
                }
                var solute_state: ecosys.snowpack_internal_solute_aggregation.State = .{ .net_flux_by_layer = solute_net[cell_layer_start .. cell_layer_start + layer_capacity] };
                const solute_workspace: ecosys.snowpack_internal_solute_aggregation.Workspace = .{ .net_flux_by_layer = context.snowpack_internal_solute_flux_workspace[cell_layer_start .. cell_layer_start + layer_capacity] };
                try ecosys.snowpack_internal_solute_aggregation.aggregate(.{
                    .heat_capacity_megajoules_per_k_by_layer = context.snow_transport.heat_capacity_megajoules_per_k[cell_layer_start .. cell_layer_start + layer_capacity],
                    .minimum_heat_capacity_megajoules_per_k = 1,
                    .upper_face_flux_by_layer = context.snowpack_internal_solute_flux_by_layer[cell_layer_start .. cell_layer_start + layer_capacity],
                }, &solute_state, solute_workspace);
                const cell_salt_start = cell_layer_start * salt_species_count;
                const cell_salt_end = @min(salt_value_count, cell_salt_start + salt_layer_value_count);
                var salt_state: ecosys.snowpack_internal_salt_aggregation.State = .{ .net_mol_per_step_by_layer_species = salt_net_mol[cell_salt_start..cell_salt_end] };
                const salt_workspace: ecosys.snowpack_internal_salt_aggregation.Workspace = .{ .net_mol_per_step_by_layer_species = context.snowpack_internal_salt_flux_workspace_by_layer_species[cell_salt_start..cell_salt_end] };
                try ecosys.snowpack_internal_salt_aggregation.aggregate(
                    if (context.snow_transport.dynamic_salts_by_cell[cell]) .dynamic else .static,
                    .{
                        .heat_capacity_megajoules_per_k_by_layer = context.snow_transport.heat_capacity_megajoules_per_k[cell_layer_start .. cell_layer_start + layer_capacity],
                        .minimum_heat_capacity_megajoules_per_k = 1,
                        .upper_face_mol_per_step_by_layer_species = context.snowpack_internal_salt_flux_mol_by_layer_species[cell_salt_start..cell_salt_end],
                    },
                    &salt_state,
                    salt_workspace,
                );
            }
            @memcpy(context.snowpack_internal_solute_flux_by_layer, solute_net);
            @memcpy(context.snowpack_internal_salt_flux_mol_by_layer_species, salt_net_mol);
            context.landscape_boundary_ledger.* = landscape_candidate;
            @memcpy(context.hourly_cell_boundary_ledger.cells, cell_candidate_values);
            @memcpy(context.hourly_layer_boundary_ledger.activity, layer_candidate_values);
        }

        noinline fn publishAcceptedSnowDrift(self: *Self) !void {
            const context = self.context;
            const cell_candidate_values = try self.allocator.dupe(
                ecosys.hourly_cell_conservation.BoundaryActivity,
                context.hourly_cell_boundary_ledger.cells,
            );
            defer self.allocator.free(cell_candidate_values);
            var cell_candidate: ecosys.hourly_cell_conservation.BoundaryLedger = .{
                .allocator = self.allocator,
                .cells = cell_candidate_values,
            };
            for (self.snow_drift_cell_ledger.cells, 0..) |activity, cell|
                try cell_candidate.accumulate(cell, activity);
            var landscape_candidate = context.landscape_boundary_ledger.*;
            try landscape_candidate.accumulateAccepted(self.snow_drift_landscape_ledger.cumulative);
            const layer_candidate_values = try self.allocator.dupe(
                ecosys.hourly_cell_conservation.BoundaryActivity,
                context.hourly_layer_boundary_ledger.activity,
            );
            defer self.allocator.free(layer_candidate_values);
            var layer_candidate: ecosys.layer_local_conservation.Ledger = .{
                .allocator = self.allocator,
                .layout = context.hourly_layer_boundary_ledger.layout,
                .activity = layer_candidate_values,
            };
            try ecosys.layer_local_conservation.accumulateCellActivityAtSnowTop(
                &layer_candidate,
                self.snow_activity_active_by_layer,
                self.snow_drift_cell_ledger.cells,
            );

            @memcpy(context.hourly_cell_boundary_ledger.cells, cell_candidate_values);
            @memcpy(context.hourly_layer_boundary_ledger.activity, layer_candidate_values);
            context.landscape_boundary_ledger.* = landscape_candidate;
            inline for (.{
                .{ context.transport_hydrology.snow_surface_carrier_volume_m3, self.snow_drift_source_carrier_m3 },
                .{ context.transport_hydrology.snow_transfer_total_m3_per_step, self.snow_drift_total_m3 },
                .{ context.transport_hydrology.snow_transfer_east_m3_per_step, self.snow_drift_east_m3 },
                .{ context.transport_hydrology.snow_transfer_west_m3_per_step, self.snow_drift_west_m3 },
                .{ context.transport_hydrology.snow_transfer_south_m3_per_step, self.snow_drift_south_m3 },
                .{ context.transport_hydrology.snow_transfer_north_m3_per_step, self.snow_drift_north_m3 },
            }) |pair| @memcpy(pair[0], pair[1]);
        }

        noinline fn publishGasGeneration(self: *const Self) !void {
            try group_timestep_finalize.publishHourlyGasContributionGenerationAlreadyApplied(
                self.context,
                &self.initial_gas_state,
            );
        }

        noinline fn publishSnowReferenceStateHeat(self: *const Self) !void {
            // The four surface diagnostic arrays publish radiation, latent,
            // carrier-sensible, and direct sensible heat later in the hourly
            // boundary ledger. Frozen snow is inventoried on a liquid
            // reference state, so solid gain/loss also carries the kernel's
            // `(Cl-Ci)*Tm-L` rebasing term. Book exactly that unrepresented
            // remainder here; schedule/stage rollback owns this ledger too.
            var per_cell_total: f64 = 0;
            for (self.snow_reference_state_heat_megajoules_by_cell) |value| per_cell_total += value;
            if (!std.math.isFinite(per_cell_total) or @abs(per_cell_total - self.snow_reference_state_heat_megajoules) >
                64 * std.math.floatEps(f64) * @max(1, @abs(self.snow_reference_state_heat_megajoules)))
                return error.SnowReferenceStatePerCellEnergyMismatch;
            try self.context.landscape_boundary_ledger.accumulateAcceptedSignedHeat(
                self.snow_reference_state_heat_megajoules,
            );
            try self.context.hourly_cell_boundary_ledger.accumulateSignedHeat(
                self.snow_reference_state_heat_megajoules_by_cell,
            );
        }

        noinline fn deinit(self: *Self) void {
            // Every retained child above was created with this arena allocator
            // and owns memory only. There are no separate child frees: one
            // teardown releases the complete scratch graph. Method-local
            // reports continue to use `self.allocator` and finish before here.
            self.scratch.deinit();
            self.* = undefined;
        }
    };
}

test "transport replay keeps pending retries private and certificates M-entry carriers" {
    const Grid = struct {
        layer_count: usize = 1,
        matrix_liquid_water_m3: []f64,
        macropore_liquid_water_m3: []f64,
        liquid_water_m3: []f64,
        matrix_air_volume_m3: []f64,
        macropore_air_volume_m3: []f64,
        air_volume_m3: []f64,
        water_vapor_volume_m3: []f64,
        matrix_ice_water_m3: []f64,
        macropore_ice_water_m3: []f64,
        ice_water_m3: []f64,
        soil_temperature_k: []f64,
        matric_potential_megapascal: []f64,
        surface_temperature_k: []f64,
    };
    const Face = struct { water_flux_m3_per_step: f64 };
    const Faces = struct {
        micropore_faces: []Face,
        macropore_faces: []Face,
    };
    const Hydrology = struct {
        micropore_external_water_flux_m3_per_step: []f64,
        macropore_external_water_flux_m3_per_step: []f64,
    };
    const Surface = struct {
        litter_water_m3: []f64,
        litter_cover_fraction: []f64,
    };
    const SurfaceGeometry = struct {
        expanded_total_volume_m3: []f64,
        pore_volume_m3: []f64,
        porosity_m3_per_m3: []f64,
    };

    var carrier_values: [transport_grid_carrier_count]f64 = undefined;
    for (&carrier_values, 0..) |*value, index| value.* = @floatFromInt(index + 1);
    var surface_temperature = [_]f64{280};
    var grid: Grid = .{
        .matrix_liquid_water_m3 = carrier_values[0..1],
        .macropore_liquid_water_m3 = carrier_values[1..2],
        .liquid_water_m3 = carrier_values[2..3],
        .matrix_air_volume_m3 = carrier_values[3..4],
        .macropore_air_volume_m3 = carrier_values[4..5],
        .air_volume_m3 = carrier_values[5..6],
        .water_vapor_volume_m3 = carrier_values[6..7],
        .matrix_ice_water_m3 = carrier_values[7..8],
        .macropore_ice_water_m3 = carrier_values[8..9],
        .ice_water_m3 = carrier_values[9..10],
        .soil_temperature_k = carrier_values[10..11],
        .matric_potential_megapascal = carrier_values[11..12],
        .surface_temperature_k = &surface_temperature,
    };
    var litter_water = [_]f64{0.2};
    var litter_cover = [_]f64{0.8};
    var surface: Surface = .{
        .litter_water_m3 = &litter_water,
        .litter_cover_fraction = &litter_cover,
    };
    var litter_ice = [_]f64{0.01};
    var expanded_volume = [_]f64{0.6};
    var pore_volume = [_]f64{0.4};
    var porosity = [_]f64{2.0 / 3.0};
    var surface_geometry: SurfaceGeometry = .{
        .expanded_total_volume_m3 = &expanded_volume,
        .pore_volume_m3 = &pore_volume,
        .porosity_m3_per_m3 = &porosity,
    };
    var micropore_faces = [_]Face{.{ .water_flux_m3_per_step = 0.01 }};
    var macropore_faces = [_]Face{.{ .water_flux_m3_per_step = -0.02 }};
    var faces: Faces = .{ .micropore_faces = &micropore_faces, .macropore_faces = &macropore_faces };
    var micropore_external = [_]f64{0.03};
    var macropore_external = [_]f64{-0.04};
    var hydrology: Hydrology = .{
        .micropore_external_water_flux_m3_per_step = &micropore_external,
        .macropore_external_water_flux_m3_per_step = &macropore_external,
    };
    const context = .{
        .grid = &grid,
        .soil_transport_faces = &faces,
        .transport_hydrology = &hydrology,
        .surface_precipitation = &surface,
        .surface_litter_geometry = &surface_geometry,
        .surface_litter_ice_m3 = litter_ice[0..],
    };
    const Replay = AcceptedTransportReplay(@TypeOf(context));
    var one_substep = try Replay.init(std.testing.allocator, context, 1);
    defer one_substep.deinit();
    var replay = try Replay.init(std.testing.allocator, context, 64);
    defer replay.deinit();

    try std.testing.expectEqual(@as(usize, 1), one_substep.substep_capacity);
    try std.testing.expectEqual(@as(usize, 64), replay.substep_capacity);
    try std.testing.expectEqual(
        one_substep.values_per_step,
        one_substep.accepted_values.len,
    );
    try std.testing.expectEqual(
        64 * replay.values_per_step,
        replay.accepted_values.len,
    );
    try std.testing.expectEqual(
        @as(usize, transport_surface_geometry_carrier_count),
        one_substep.accepted_surface_geometry_values.len,
    );
    try std.testing.expectEqual(
        @as(usize, 64 * transport_surface_geometry_carrier_count),
        replay.accepted_surface_geometry_values.len,
    );
    try std.testing.expectEqual(@as(usize, 1), one_substep.litter_soil_water_flux_m3.len);
    try std.testing.expectEqual(@as(usize, 64), replay.litter_soil_water_flux_m3.len);
    try std.testing.expectEqual(
        @as(usize, maximum_transport_replay_substeps),
        one_substep.time_step_hours.len,
    );
    try one_substep.beginSubstep(1);
    try one_substep.stageAcceptedFluxes();
    one_substep.acceptSubstep(&.{0.005});
    try std.testing.expectEqual(@as(usize, 1), one_substep.count);
    try std.testing.expectEqual(@as(f64, 0.005), (try one_substep.litterSoilWaterFlux(0))[0]);
    const carriers_before_one_overflow = carrier_values;
    try std.testing.expectError(
        error.TransportReplayScheduleOverflow,
        one_substep.beginSubstep(1),
    );
    try std.testing.expectEqualDeep(carriers_before_one_overflow, carrier_values);
    try std.testing.expectError(
        error.InvalidTransportReplaySubstepCapacity,
        Replay.init(std.testing.allocator, context, 3),
    );

    try replay.beginSubstep(0.5);
    try std.testing.expectEqual(@as(usize, 0), replay.count);
    try std.testing.expectEqual(@as(f64, 1), replay.accepted_values[0]);
    try std.testing.expectEqual(@as(f64, 0.2), replay.accepted_values[transport_grid_carrier_count]);
    try std.testing.expectEqual(@as(f64, 280), replay.accepted_values[transport_grid_carrier_count + 1]);
    try std.testing.expectEqual(@as(f64, 0.01), replay.accepted_values[transport_grid_carrier_count + 2]);
    try std.testing.expectEqualSlices(f64, &.{ 0.6, 0.4, 2.0 / 3.0, 0.8 }, replay.accepted_surface_geometry_values[0..4]);

    // A rejected attempt never increments count. Its successor overwrites the
    // same private slot instead of leaving a replayable stale carrier.
    carrier_values[0] = 21;
    litter_water[0] = 0.25;
    surface_temperature[0] = 281;
    try replay.beginSubstep(0.25);
    try std.testing.expectEqual(@as(usize, 0), replay.count);
    try std.testing.expectEqual(@as(f64, 21), replay.accepted_values[0]);
    try std.testing.expectEqual(@as(f64, 0.25), replay.accepted_values[transport_grid_carrier_count]);
    try std.testing.expectEqual(@as(f64, 281), replay.accepted_values[transport_grid_carrier_count + 1]);
    try replay.stageAcceptedFluxes();
    const flux_start = transport_grid_carrier_count + transport_surface_carrier_count;
    try std.testing.expectEqualSlices(f64, &.{ 0.01, -0.02, 0.03, -0.04 }, replay.accepted_values[flux_start..][0..4]);
    const flwr = [_]f64{0.005};
    replay.acceptSubstep(&flwr);
    try std.testing.expectEqual(@as(usize, 1), replay.count);
    try std.testing.expectEqual(@as(f64, 0.005), (try replay.litterSoilWaterFlux(0))[0]);

    // Reserving the next slot alone does not make it replayable.
    try replay.beginSubstep(0.25);
    try std.testing.expectEqual(@as(usize, 1), replay.count);
    try std.testing.expectError(error.TransportReplaySubstepOutOfBounds, replay.litterSoilWaterFlux(1));

    try replay.captureFinal();
    // WATSUB's immutable final carrier remains 21. The later 20.5 value is a
    // distinct post-NITRO/UPTAKE/SOLUTE live carrier which replay must restore
    // after temporarily binding M-entry snapshots.
    try std.testing.expectEqual(@as(f64, 21), replay.final_values[0]);
    carrier_values[0] = 20.5;
    try replay.captureRestoreState();
    try std.testing.expectEqual(@as(f64, 20.5), replay.restore_values[0]);
    try std.testing.expectEqual(@as(f64, 20.5), carrier_values[0]);
    expanded_volume[0] = 0.55;
    try replay.captureFinalSurfaceGeometry();
    try std.testing.expect(replay.final_captured);
    try std.testing.expect(replay.restore_captured);
    try std.testing.expect(replay.final_surface_geometry_captured);
    try std.testing.expectEqual(@as(f64, 281), replay.final_values[transport_grid_carrier_count + 1]);
    try std.testing.expectEqual(@as(f64, 0.55), replay.final_surface_geometry_values[0]);
    replay.reset();
    try std.testing.expectEqual(@as(usize, 0), replay.count);
    try std.testing.expect(!replay.final_captured);
    try std.testing.expect(!replay.restore_captured);
    try std.testing.expect(!replay.final_surface_geometry_captured);

    // The bounded schedule fails before reading or publishing physical state.
    replay.count = replay.substep_capacity;
    const carriers_before_overflow = carrier_values;
    const litter_before_overflow = litter_water;
    try std.testing.expectError(error.TransportReplayScheduleOverflow, replay.beginSubstep(0.25));
    try std.testing.expectEqualDeep(carriers_before_overflow, carrier_values);
    try std.testing.expectEqualDeep(litter_before_overflow, litter_water);

    // Any per-cell carrier disagreement fails before allocation/publication;
    // the cell count remains derived from authoritative litter water.
    var empty_geometry: [0]f64 = .{};
    surface_geometry.pore_volume_m3 = &empty_geometry;
    const carriers_before_bad_init = carrier_values;
    const litter_before_bad_init = litter_water;
    try std.testing.expectError(
        error.TransportReplayDimensionMismatch,
        Replay.init(std.testing.allocator, context, 64),
    );
    try std.testing.expectEqualDeep(carriers_before_bad_init, carrier_values);
    try std.testing.expectEqualDeep(litter_before_bad_init, litter_water);
}

test "maximum_transport_replay_substeps is genuinely ladder-derived, not a hardcoded duplicate (issue-059)" {
    // Proves the fix's array-sizing constant actually tracks
    // `recovery_substep_counts`'s own maximum, rather than merely
    // coinciding with it today the way the pre-fix hardcoded `64` literal
    // did. If a future edit changed the ladder's last member, this
    // constant (and therefore `time_step_hours`'s buffer size) would move
    // with it automatically.
    try std.testing.expectEqual(
        @as(usize, ecosys.soil_water_heat_step.recovery_substep_counts[
            ecosys.soil_water_heat_step.recovery_substep_counts.len - 1
        ]),
        maximum_transport_replay_substeps,
    );
}

test "transport replay substep buffer scales safely past today's committed maximum (extensibility, issue-059)" {
    // Reproduces issue-059's exact crash scenario in a SAFE way: a LOCAL,
    // test-only mirror of `AcceptedTransportReplay`'s fixed-size
    // `time_step_hours` field, sized via the same
    // "derive-the-maximum-from-the-ladder" pattern this fix applied to
    // production, but against a local ladder extended to `128` --
    // production's `recovery_substep_counts` is never touched (that
    // extension decision remains reserved for issue-015). Before this
    // fix's pattern was applied to production, an independently hardcoded
    // `64` buffer overflowed ("index out of bounds: index 64, len 64",
    // `hourly_heat_water_solute.zig:2663`) once a ladder-validated
    // `substep_capacity` reached a tier past `64`. Here the buffer's size
    // is derived from the very same extended ladder, so filling every one
    // of the new tier's 128 slots must succeed with no overflow.
    const extended_ladder = [_]u8{ 1, 2, 4, 8, 16, 20, 32, 64, 128 };

    const LocalReplayBuffer = struct {
        const capacity_bound: usize = extended_ladder[extended_ladder.len - 1];

        time_step_hours: [capacity_bound]f64 = @splat(0),
        substep_capacity: usize,
        count: usize = 0,

        fn init(exact_substep_count: u8) !@This() {
            for (extended_ladder) |allowed| {
                if (exact_substep_count != allowed) continue;
                const capacity: usize = @intCast(exact_substep_count);
                if (capacity > capacity_bound) return error.CapacityExceedsBuffer;
                return .{ .substep_capacity = capacity };
            }
            return error.InvalidCapacity;
        }

        fn beginSubstep(self: *@This(), value: f64) !void {
            if (self.count >= self.substep_capacity) return error.ScheduleOverflow;
            self.time_step_hours[self.count] = value;
            self.count += 1;
        }
    };

    try std.testing.expectEqual(@as(usize, 128), LocalReplayBuffer.capacity_bound);

    var replay = try LocalReplayBuffer.init(128);
    try std.testing.expectEqual(@as(usize, 128), replay.time_step_hours.len);
    try std.testing.expectEqual(@as(usize, 128), replay.substep_capacity);

    var substep: usize = 0;
    while (substep < 128) : (substep += 1) {
        try replay.beginSubstep(1.0 / 128.0);
    }
    try std.testing.expectEqual(@as(usize, 128), replay.count);
    try std.testing.expectError(error.ScheduleOverflow, replay.beginSubstep(1.0 / 128.0));
}

test "temporary PSISO carrier rebase is restored before the accepted soil carrier commit" {
    const config = try ecosys.config.SimulationConfig.init(
        .{ .lon_count = 1, .lat_count = 1, .soil_layers = 1, .plant_populations = 1 },
        .{ .worker_threads = 1, .tile_cells = 1 },
        .{ .relative_tolerance = 1e-8, .absolute_tolerance = 1e-9, .max_nonlinear_iterations = 1 },
    );
    var grid = try ecosys.grid.GridState.init(std.testing.allocator, config);
    defer grid.deinit();
    grid.active_soil_layer_count[0] = 1;
    grid.matrix_liquid_water_m3[0] = 4;

    var chemistry = try ecosys.solute_chemistry_state.State.init(std.testing.allocator, 1);
    defer chemistry.deinit();
    chemistry.aqueous[0].magnesium = 2;
    chemistry.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 3;
    chemistry.band_phosphate[0].dissolved_h2po4_mol_p_per_m3 = 5;
    chemistry.geochemistry_solids[0].magnesium_natural_silicate_mol_per_m3 = 7;

    var entry = try TopsoilChemistryCarrierSnapshot.init(std.testing.allocator, 1);
    defer entry.deinit();
    try entry.capture(&grid, &chemistry);

    // These two pure-water changes stand in for the topsoil vapor and ingress
    // rebases needed by the coefficient refresh. The prepared concentration is
    // visible to PSISO while every extensive amount remains unchanged.
    const test_negligible_water_volume_m3 = ecosys.soil_chemistry_water_carrier_rebase.legacyNegligibleWaterVolumeM3(1);
    try ecosys.soil_chemistry_water_carrier_rebase.rebaseLayer(&chemistry, 0, 4, 4.5, test_negligible_water_volume_m3);
    try ecosys.soil_chemistry_water_carrier_rebase.rebaseLayer(&chemistry, 0, 4.5, 5, test_negligible_water_volume_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), chemistry.aqueous[0].magnesium, 1e-15);
    try std.testing.expectApproxEqAbs(@as(f64, 8), chemistry.aqueous[0].magnesium * 5, 1e-14);

    // Acceptance discards those diagnostic mutations, then applies the sole
    // authoritative M-entry to M-exit carrier transition.
    try entry.restoreAndDisarm(&grid, &chemistry);
    try std.testing.expectEqual(@as(f64, 2), chemistry.aqueous[0].magnesium);
    try std.testing.expectEqual(@as(f64, 3), chemistry.non_band_phosphate[0].dissolved_h2po4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 5), chemistry.band_phosphate[0].dissolved_h2po4_mol_p_per_m3);
    try std.testing.expectEqual(@as(f64, 7), chemistry.geochemistry_solids[0].magnesium_natural_silicate_mol_per_m3);
    try std.testing.expectError(
        error.TopsoilChemistryCarrierSnapshotNotArmed,
        entry.restoreAndDisarm(&grid, &chemistry),
    );

    grid.matrix_liquid_water_m3[0] = 2;
    try ecosys.soil_chemistry_water_carrier_rebase.rebaseLayer(&chemistry, 0, 4, 2, test_negligible_water_volume_m3);
    try std.testing.expectApproxEqAbs(@as(f64, 8), chemistry.aqueous[0].magnesium * 2, 1e-14);
    try std.testing.expectEqual(
        @as(f64, 14),
        chemistry.geochemistry_solids[0].magnesium_natural_silicate_mol_per_m3,
    );
    try std.testing.expectEqual(
        @as(f64, 28),
        chemistry.geochemistry_solids[0].magnesium_natural_silicate_mol_per_m3 *
            grid.matrix_liquid_water_m3[0],
    );
}

test "stage transaction rolls bare-surface expulsion owners back byte exactly" {
    const Nested = struct { values: []f64 };
    const State = struct { counter: u32, nested: Nested };
    const SurfacePrecipitation = struct { litter_water_m3: []f64 };
    var values = [_]f64{ 1, 2 };
    var grid = State{ .counter = 7, .nested = .{ .values = &values } };
    var surface_water = [_]f64{0.04};
    var surface_precipitation = SurfacePrecipitation{ .litter_water_m3 = &surface_water };
    var surface_heat_capacity = [_]f64{3.5};
    var evaporation = [_]f64{3};
    var erosion_carbon_change = [_]f64{4};
    const context = .{
        .grid = &grid,
        .surface_precipitation = &surface_precipitation,
        .surface_heat_capacity_megajoules_per_k = surface_heat_capacity[0..],
        .ground_surface_evaporation_m3_per_h = evaporation[0..],
        .erosion_organic_carbon_net_change_g_c = erosion_carbon_change[0..],
    };
    var snapshot = try StageMemorySnapshot.capture(std.testing.allocator, context);
    defer snapshot.deinit();
    grid.counter = 99;
    grid.nested.values[0] = -8;
    surface_water[0] = 0.05;
    surface_heat_capacity[0] = 4.0;
    evaporation[0] = 42;
    erosion_carbon_change[0] = -9;
    snapshot.restore();
    try std.testing.expectEqual(@as(u32, 7), grid.counter);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2 }, &values);
    try std.testing.expectEqualSlices(f64, &.{0.04}, &surface_water);
    try std.testing.expectEqualSlices(f64, &.{3.5}, &surface_heat_capacity);
    try std.testing.expectEqualSlices(f64, &.{3}, &evaporation);
    try std.testing.expectEqualSlices(f64, &.{4}, &erosion_carbon_change);
}

test "stage transaction restores resized soil gas step owner exactly" {
    var gas_step = try ecosys.soil_gas_transport_step.State.init(std.testing.allocator, 1);
    defer gas_step.deinit();
    gas_step.atmospheric_flux_g_per_h[0] = 2.5;
    const context = .{ .soil_gas_transport = &gas_step };
    var snapshot = try StageMemorySnapshot.capture(std.testing.allocator, context);
    defer snapshot.deinit();

    gas_step.accepted_face_flux_g_per_h = try gas_step.allocator.realloc(
        gas_step.accepted_face_flux_g_per_h,
        ecosys.gas_transport.species_count,
    );
    gas_step.accepted_faces = try gas_step.allocator.realloc(gas_step.accepted_faces, 1);
    @memset(gas_step.accepted_face_flux_g_per_h, 7);
    gas_step.atmospheric_flux_g_per_h[0] = -4;

    snapshot.restore();
    try std.testing.expectEqual(@as(usize, 0), gas_step.accepted_face_flux_g_per_h.len);
    try std.testing.expectEqual(@as(usize, 0), gas_step.accepted_faces.len);
    try std.testing.expectEqual(@as(f64, 2.5), gas_step.atmospheric_flux_g_per_h[0]);
}

test "production-shaped litter soil interface accepts only canonical transport width" {
    const species_count = ecosys.solute_transport_species.AqueousSpecies.count;
    const cell_count: usize = 64;
    const layers_per_cell: usize = 20;
    const layer_count = cell_count * layers_per_cell;
    var surface = try ecosys.surface_solute_routing.State.init(std.testing.allocator, 8, 8, species_count);
    defer surface.deinit();
    var soil = try ecosys.solute_transport.State.init(std.testing.allocator, layer_count, species_count);
    defer soil.deinit();
    try validateLitterSoilInterfaceDimensions(&surface, &soil, cell_count, layer_count);

    var stale_surface = try ecosys.surface_solute_routing.State.init(std.testing.allocator, 8, 8, ecosys.litter_soil_interface.soil_species_count);
    defer stale_surface.deinit();
    try std.testing.expectError(error.LitterSoilInterfaceDimensionMismatch, validateLitterSoilInterfaceDimensions(&stale_surface, &soil, cell_count, layer_count));
    var stale_soil = try ecosys.solute_transport.State.init(std.testing.allocator, layer_count, ecosys.litter_soil_interface.soil_species_count);
    defer stale_soil.deinit();
    try std.testing.expectError(error.LitterSoilInterfaceDimensionMismatch, validateLitterSoilInterfaceDimensions(&surface, &stale_soil, cell_count, layer_count));
}

test "foldDelayedHeatSource retains the exact producer until accepted booking" {
    var delayed = [_]f64{ 1.5, -2.0, 0 };
    var heat_source = [_]f64{ 10.0, 5.0, 3.0 };
    try foldDelayedHeatSource(&delayed, &heat_source);
    try std.testing.expectEqualSlices(f64, &.{ 11.5, 3.0, 3.0 }, &heat_source);
    try std.testing.expectEqualSlices(f64, &.{ 1.5, -2.0, 0 }, &delayed);
}

test "foldDelayedHeatSource rejects a non-finite result" {
    var delayed = [_]f64{std.math.inf(f64)};
    var heat_source = [_]f64{1.0};
    try std.testing.expectError(error.NonFiniteDelayedHeatSource, foldDelayedHeatSource(&delayed, &heat_source));
}

test "bounded recovery chooses only deliberate fallback schedules" {
    try std.testing.expectEqual(
        @as(?u8, 20),
        boundedRecoveryFallback(1),
    );
    try std.testing.expectEqual(
        @as(?u8, 20),
        boundedRecoveryFallback(1),
    );
    try std.testing.expectEqual(
        @as(?u8, 20),
        boundedRecoveryFallback(4),
    );
    try std.testing.expectEqual(
        @as(?u8, 32),
        boundedRecoveryFallback(20),
    );
    try std.testing.expectEqual(
        @as(?u8, 64),
        boundedRecoveryFallback(32),
    );
    try std.testing.expectEqual(
        @as(?u8, null),
        boundedRecoveryFallback(64),
    );
    try std.testing.expectEqual(@as(u8, 64), try boundedInitialRecoverySubstepCount(64, false, false));
    try std.testing.expectEqual(@as(u8, 4), try boundedInitialRecoverySubstepCount(1, true, false));
}

test "boundedInitialRecoverySubstepCount: ICHKV proactive floor (issue-024/issue-068/issue-077)" {
    // Updated 2026-09-21 for the universal NFH=4 baseline (below): the
    // ordinary default of 1 is no longer a no-op -- it is now floored to
    // 4 unconditionally, per `universal_nfh_baseline_substeps`. The
    // dedicated "universal NFH=4 baseline" test group below covers that
    // floor's own before/after behavior in detail; this test keeps
    // covering the ICHKV-specific floor's interaction with it.
    try std.testing.expectEqual(@as(u8, 4), try boundedInitialRecoverySubstepCount(1, false, false));
    try std.testing.expectEqual(@as(u8, 64), try boundedInitialRecoverySubstepCount(64, false, false));
    try std.testing.expectEqual(@as(u8, 4), try boundedInitialRecoverySubstepCount(1, true, false));
    // New behavior (task requirement 4b): when the proactive floor is
    // active, the FIRST attempt starts at the ladder's existing 20-substep
    // rung (Fortran's `NPH=MAX(20,NPX)` baseline for this exact `ICHKV`
    // condition), not at the default of 1 -- a different starting point in
    // the already-existing ladder, not a new rung.
    try std.testing.expectEqual(@as(u8, 20), try boundedInitialRecoverySubstepCount(1, false, true));
    // A preferred count already at or above 20 is unaffected (the floor
    // only ever raises, never lowers, the requested count).
    try std.testing.expectEqual(@as(u8, 32), try boundedInitialRecoverySubstepCount(32, false, true));
    try std.testing.expectEqual(@as(u8, 64), try boundedInitialRecoverySubstepCount(64, false, true));
    // Both floors active simultaneously: the larger of the two applies,
    // exactly as `@max` implies (both are floors on the same quantity).
    try std.testing.expectEqual(@as(u8, 20), try boundedInitialRecoverySubstepCount(1, true, true));
}

test "boundedInitialRecoverySubstepCount: universal NFH=4 baseline floors every hour's first attempt (issue-024, 2026-09-21 committed fix)" {
    // (a) Hours that previously requested 1 (the ordinary, un-escalated
    // default -- no freeze-flow floor, no ICHKV floor active) are now
    // floored to 4, matching Fortran's unconditional `wthr.f:589-601`
    // `NFH=4` baseline for every non-fire hour. Before this fix, this
    // returned 1 unchanged (see the previous test's now-updated first
    // assertion, and issue-024's diagnostic-experiment section for the
    // full before/after production evidence at hours 2,894/2,895/3,252).
    try std.testing.expectEqual(@as(u8, 4), try boundedInitialRecoverySubstepCount(1, false, false));
    try std.testing.expectEqual(@as(u8, 4), try boundedInitialRecoverySubstepCount(2, false, false));
    try std.testing.expectEqual(@as(u8, 4), try boundedInitialRecoverySubstepCount(4, false, false));

    // (b) Hours that already requested a preferred count at or above 4
    // (e.g. an already-escalated degenerate hour whose adaptive schedule
    // has climbed the ladder from a prior hour's failure) are completely
    // unaffected -- the new floor is a strict no-op on the ceiling side,
    // never lowering an already-larger request.
    try std.testing.expectEqual(@as(u8, 8), try boundedInitialRecoverySubstepCount(8, false, false));
    try std.testing.expectEqual(@as(u8, 16), try boundedInitialRecoverySubstepCount(16, false, false));
    try std.testing.expectEqual(@as(u8, 20), try boundedInitialRecoverySubstepCount(20, false, false));
    try std.testing.expectEqual(@as(u8, 32), try boundedInitialRecoverySubstepCount(32, false, false));
    try std.testing.expectEqual(@as(u8, 64), try boundedInitialRecoverySubstepCount(64, false, false));

    // (c) Legacy source justification, cited exactly: `f77src/wthr.f:589-601`
    // fixes `NFH=4` (the outer `DO 9990 NFZ=1,NFH` substep count at
    // `soil.f:145`) unconditionally for every non-fire external hour --
    // it is not gated by any per-layer heat-capacity/thinness condition
    // (that additional, conditional escalation to `NPH>=20` is `ICHKV`,
    // `wthr.f:568-571`, tested separately above). This asserts the
    // committed constant actually equals that cited legacy value, so a
    // future accidental edit of `universal_nfh_baseline_substeps` without
    // updating this citation would be caught here.
    try std.testing.expectEqual(@as(u8, 4), universal_nfh_baseline_substeps);
}

test "boundedRecoveryFallback matches the old hardcoded 20/32/64 chain across the full u8 domain (before/after equivalence, issue-058)" {
    // `boundedRecoveryFallback` used to be a plain if/else-if chain over
    // three named literals (`stiff=20`, `secondary=32`, `maximum=64`)
    // that never read `recovery_substep_counts`. This test re-derives
    // that exact pre-fix formula as a literal, independent of any shared
    // helper or constant, and checks it against the new array-driven
    // implementation for every possible `u8` input -- not just today's
    // reachable array members -- so any behavior change at today's
    // committed ladder values would be caught here.
    var attempted: u16 = 0;
    while (attempted <= 255) : (attempted += 1) {
        const a: u8 = @intCast(attempted);
        const old_hardcoded_result: ?u8 = if (a < 20)
            @as(?u8, 20)
        else if (a < 32)
            @as(?u8, 32)
        else if (a < 64)
            @as(?u8, 64)
        else
            null;
        try std.testing.expectEqual(old_hardcoded_result, boundedRecoveryFallback(a));
    }
}

test "fallbackWithinLadder escalates to a new tier beyond today's committed maximum (extensibility, issue-058)" {
    // A local-only ladder extending 64 -> 128. The production
    // `recovery_substep_counts` array itself is untouched here (that
    // decision belongs to issue-015, not this fix). This exercises the
    // exact mechanism `boundedRecoveryFallback` delegates to, proving
    // the fix actually solves the extensibility problem -- before this
    // fix, an analogous change to the real array would either silently
    // no-op (old chain still capped at 64) or crash, per issue-024
    // round 7's `STATUS_ACCESS_VIOLATION` reproduction.
    const extended_ladder = [_]u8{ 1, 2, 4, 8, 16, 20, 32, 64, 128 };
    try std.testing.expectEqual(
        @as(?u8, 128),
        fallbackWithinLadder(&extended_ladder, stiff_heat_direct_recovery_substeps, 64),
    );
    try std.testing.expectEqual(
        @as(?u8, null),
        fallbackWithinLadder(&extended_ladder, stiff_heat_direct_recovery_substeps, 128),
    );
    try std.testing.expectEqual(
        @as(?u8, 20),
        fallbackWithinLadder(&extended_ladder, stiff_heat_direct_recovery_substeps, 1),
    );
    try std.testing.expectEqual(
        @as(?u8, 32),
        fallbackWithinLadder(&extended_ladder, stiff_heat_direct_recovery_substeps, 20),
    );
    try std.testing.expectEqual(
        @as(?u8, 64),
        fallbackWithinLadder(&extended_ladder, stiff_heat_direct_recovery_substeps, 32),
    );
}

test "isRecoverySubstepCountMember distinguishes true ladder rungs from drifted values (guards issue-058 comptime assertions)" {
    // `minimum_freeze_flow_coupling_substeps` and
    // `stiff_heat_direct_recovery_substeps` are each guarded by a
    // `comptime` assertion built on
    // `ecosys.soil_water_heat_step.isRecoverySubstepCountMember`. A
    // compile error itself cannot be asserted at runtime, but this test
    // pins the exact predicate those guards depend on: if a future edit
    // weakened it (e.g. made it always return true), this would still
    // catch it, and it is the same function that would have caught both
    // issue-058's dormant array/chain mismatch and a re-drifted floor
    // constant before it ever reached a build or production run.
    inline for (.{ 1, 2, 4, 8, 16, 20, 32, 64 }) |member|
        try std.testing.expect(ecosys.soil_water_heat_step.isRecoverySubstepCountMember(member));
    inline for (.{ 0, 3, 5, 17, 21, 63, 65, 80, 128, 255 }) |non_member|
        try std.testing.expect(!ecosys.soil_water_heat_step.isRecoverySubstepCountMember(non_member));
}

test "accepted schedule duration uses bounded floating point accumulation" {
    for (ecosys.soil_water_heat_step.recovery_substep_counts) |substep_count| {
        const time_step_hours = 1.0 / @as(f64, @floatFromInt(substep_count));
        var duration_hours: f64 = 0;
        for (0..substep_count) |_| duration_hours += time_step_hours;
        try std.testing.expect(isOneHourAcceptedScheduleDuration(
            substep_count,
            duration_hours,
        ));
    }
    try std.testing.expect(!isOneHourAcceptedScheduleDuration(3, 1));
    try std.testing.expect(!isOneHourAcceptedScheduleDuration(20, 1 + 1.0e-12));
}

test "accepted phase activity owns the freeze flow floor" {
    const Fixture = struct {
        accepted_had_significant_heat_induced_phase_change: bool,

        fn run(_: *@This(), _: u8) !void {}
    };

    var active = Fixture{ .accepted_had_significant_heat_induced_phase_change = true };
    var preferred: u8 = 4;
    var cooldown: u8 = 0;
    var freeze_flow_floor = true;
    try recoverFixedExternalHourAdaptively(&active, &preferred, &cooldown, &freeze_flow_floor, false);
    try std.testing.expect(freeze_flow_floor);
    try std.testing.expectEqual(@as(u8, 4), preferred);

    var inactive = Fixture{ .accepted_had_significant_heat_induced_phase_change = false };
    cooldown = 0;
    try recoverFixedExternalHourAdaptively(&inactive, &preferred, &cooldown, &freeze_flow_floor, false);
    try std.testing.expect(!freeze_flow_floor);
    try std.testing.expectEqual(@as(u8, 2), preferred);
}

test "fixed external hour recovery rolls back before its single bounded fallback" {
    const Fixture = struct {
        scientific_pool: f64 = 7,
        accepted_ledger: f64 = 11,
        attempted_schedules: [ecosys.soil_water_heat_step.recovery_substep_counts.len]u8 = @splat(0),
        attempt_count: usize = 0,
        rollback_count: usize = 0,
        biology_call_count: usize = 0,
        soil_failure_count: usize = 0,
        litter_failure_count: usize = 0,

        fn run(self: *@This(), substep_count: u8) !void {
            // Every attempt must enter from the exact same scientific state;
            // counters above are test instrumentation and intentionally survive.
            if (self.scientific_pool != 7 or self.accepted_ledger != 11)
                return error.DirtyHourlyRecoveryEntry;
            self.attempted_schedules[self.attempt_count] = substep_count;
            self.attempt_count += 1;
            const dt = 1.0 / @as(f64, @floatFromInt(substep_count));
            for (0..substep_count) |_| self.scientific_pool += dt;
            // Represents the single NITRO/HFUNC/UPTAKE/GROSUB/SOLUTE pass for
            // this complete candidate hour, never one call per WATSUB substep.
            self.biology_call_count += 1;
            self.scientific_pool += 10;
            self.accepted_ledger += 2;
            // Updated 2026-09-21 for the universal NFH=4 baseline: a fresh
            // hour's first attempt is now unconditionally floored at 4
            // (`universal_nfh_baseline_substeps`), not 1, so this first
            // rejected rung is now 4, not 1. `substep_count == 2` below
            // remains dead in this specific test (as it already was
            // before this fix -- the escalation chain never revisits 2),
            // kept only for local readability of the fixture's full
            // three-rung shape.
            if (substep_count == 4) {
                self.scientific_pool += 100;
                self.soil_failure_count += 1;
                self.scientific_pool = 7;
                self.accepted_ledger = 11;
                self.rollback_count += 1;
                return error.SoluteReactionSolverDidNotConverge;
            }
            if (substep_count == 2) {
                self.accepted_ledger += 100;
                self.litter_failure_count += 1;
                self.scientific_pool = 7;
                self.accepted_ledger = 11;
                self.rollback_count += 1;
                return error.LitterChemistrySolverStagnated;
            }
            self.scientific_pool += 3;
        }
    };

    var fixture: Fixture = .{};
    try recoverFixedExternalHour(&fixture);
    try std.testing.expectEqualSlices(u8, &.{ 4, 20 }, fixture.attempted_schedules[0..2]);
    try std.testing.expectEqual(@as(usize, 2), fixture.attempt_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.rollback_count);
    try std.testing.expectEqual(@as(usize, 2), fixture.biology_call_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.soil_failure_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.litter_failure_count);
    // Only the accepted bounded candidate survives: 1 h physical change,
    // one hourly biology/chemistry change, one downstream transport change.
    try std.testing.expectApproxEqAbs(@as(f64, 21), fixture.scientific_pool, 64 * std.math.floatEps(f64));
    try std.testing.expectEqual(@as(f64, 13), fixture.accepted_ledger);
    inline for (.{
        error.SoluteReactionSolverDiverged,
        error.SoluteReactionSolverStagnated,
        error.SoluteReactionSolverDidNotConverge,
        error.SoluteReactionPhysicalBalanceFailure,
    }) |solute_failure|
        try std.testing.expect(isFixedHourRecoveryFailure(solute_failure));
    try std.testing.expect(ecosys.soil_water_heat_step.isRetryableSolverFailure(error.LitterChemistrySolverStagnated));
}

test "adaptive fixed-hour recovery escalates through the full fallback chain to the secondary rescue (parent: stopped at one fallback and failed)" {
    // SOLUTE-HYDROGEN-ROW-RECURRING-NONCONVERGENCE-001 (hour 2,571): the
    // previous implementation made at most one error-aware fallback, so a
    // preferred schedule that wasn't already 20 could reach 20 but never the
    // documented 32-step rescue. Measured against the real captured failure,
    // 32 substeps converges where 1 and 20 do not -- this test pins that a
    // preferred schedule far below 20 still escalates all the way to 32
    // before giving up, matching `boundedRecoveryFallback`'s documented
    // chain rather than stopping after a single fallback.
    const Fixture = struct {
        schedules: [3]u8 = @splat(0),
        attempts: usize = 0,
        minimum_successful_substeps: u8,

        fn run(self: *@This(), substep_count: u8) !void {
            self.schedules[self.attempts] = substep_count;
            self.attempts += 1;
            if (substep_count < self.minimum_successful_substeps)
                return error.NewtonPicardStagnated;
        }
    };

    var refinement = Fixture{ .minimum_successful_substeps = 32 };
    var preferred: u8 = 16;
    var cooldown: u8 = 0;
    var freeze_flow_floor = false;
    try recoverFixedExternalHourAdaptively(&refinement, &preferred, &cooldown, &freeze_flow_floor, false);
    try std.testing.expectEqualSlices(u8, &.{ 16, 20, 32 }, refinement.schedules[0..refinement.attempts]);
    try std.testing.expectEqual(@as(u8, 32), preferred);
    try std.testing.expectEqual(coarsening_probe_cooldown_hours, cooldown);

    var accepted = Fixture{ .minimum_successful_substeps = 32 };
    preferred = 20;
    cooldown = 0;
    try recoverFixedExternalHourAdaptively(&accepted, &preferred, &cooldown, &freeze_flow_floor, false);
    try std.testing.expectEqualSlices(u8, &.{ 20, 32 }, accepted.schedules[0..accepted.attempts]);
    try std.testing.expectEqual(@as(u8, 32), preferred);
    try std.testing.expectEqual(coarsening_probe_cooldown_hours, cooldown);
}

test "adaptive fixed-hour recovery escalates past the secondary rescue to the true ladder maximum (parent: hardcoded ceiling at 32 reproduced the hour-2,604 defect one rung later)" {
    // SOLUTE-HYDROGEN-ROW-RECURRING-NONCONVERGENCE-001 (hour 2,604): the
    // 32-step rescue landed by the hour-2,571 fix was itself a hardcoded
    // ceiling one rung short of `recovery_substep_counts`'s own documented
    // maximum (64), even though the shared ladder array always declared 64.
    // A real production run advancing past the hour-2,571 fix hit the exact
    // same shape of defect 33 hours later at hour 2,604, where even the
    // 32-step rescue failed and the old two-tier chain gave up instead of
    // trying the ladder's actual maximum.
    const Fixture = struct {
        schedules: [4]u8 = @splat(0),
        attempts: usize = 0,
        minimum_successful_substeps: u8,

        fn run(self: *@This(), substep_count: u8) !void {
            self.schedules[self.attempts] = substep_count;
            self.attempts += 1;
            if (substep_count < self.minimum_successful_substeps)
                return error.NewtonPicardStagnated;
        }
    };

    var fixture = Fixture{ .minimum_successful_substeps = 64 };
    var preferred: u8 = 16;
    var cooldown: u8 = 0;
    var freeze_flow_floor = false;
    try recoverFixedExternalHourAdaptively(&fixture, &preferred, &cooldown, &freeze_flow_floor, false);
    try std.testing.expectEqualSlices(u8, &.{ 16, 20, 32, 64 }, fixture.schedules[0..fixture.attempts]);
    try std.testing.expectEqual(@as(u8, 64), preferred);
    try std.testing.expectEqual(coarsening_probe_cooldown_hours, cooldown);
}

test "adaptive fixed-hour recovery still terminates and reports failure when even the ladder maximum fails" {
    const Fixture = struct {
        schedules: [4]u8 = @splat(0),
        attempts: usize = 0,

        fn run(self: *@This(), substep_count: u8) !void {
            self.schedules[self.attempts] = substep_count;
            self.attempts += 1;
            return error.NewtonPicardStagnated;
        }
    };

    var fixture: Fixture = .{};
    var preferred: u8 = 1;
    var cooldown: u8 = 0;
    var freeze_flow_floor = false;
    try std.testing.expectError(
        error.NewtonPicardStagnated,
        recoverFixedExternalHourAdaptively(&fixture, &preferred, &cooldown, &freeze_flow_floor, false),
    );
    // Updated 2026-09-21 for the universal NFH=4 baseline: the first
    // attempt is now floored at 4, not 1 (see
    // `universal_nfh_baseline_substeps`); the rest of the escalation
    // chain (20, 32, 64) is unaffected.
    try std.testing.expectEqualSlices(u8, &.{ 4, 20, 32, 64 }, fixture.schedules[0..fixture.attempts]);
}

test "adaptive fixed-hour recovery retains a successful gas fallback" {
    const Fixture = struct {
        schedules: [2]u8 = @splat(0),
        attempts: usize = 0,

        fn run(self: *@This(), substep_count: u8) !void {
            self.schedules[self.attempts] = substep_count;
            self.attempts += 1;
            if (substep_count < 8)
                return error.CoupledGasSolverDidNotConverge;
        }
    };

    var fixture: Fixture = .{};
    var preferred: u8 = 4;
    var cooldown: u8 = 0;
    var freeze_flow_floor = false;
    try recoverFixedExternalHourAdaptively(&fixture, &preferred, &cooldown, &freeze_flow_floor, false);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 4, 20 },
        fixture.schedules[0..fixture.attempts],
    );
    try std.testing.expectEqual(@as(u8, 20), preferred);
    try std.testing.expectEqual(gas_coarsening_probe_cooldown_hours, cooldown);
}

test "adaptive fixed-hour recovery skips sub-quarter-hour rung after phase requirement" {
    const Fixture = struct {
        schedules: [2]u8 = @splat(0),
        attempts: usize = 0,
        accepted_had_significant_heat_induced_phase_change: bool = false,
        retain_phase_activity: bool = true,

        fn run(self: *@This(), substep_count: u8) !void {
            self.schedules[self.attempts] = substep_count;
            self.attempts += 1;
            if (substep_count < ecosys.soil_water_heat_step.minimum_freeze_flow_coupling_substeps)
                return error.HeatInducedPhaseChangeRequiresQuarterHourSubsteps;
            self.accepted_had_significant_heat_induced_phase_change =
                self.retain_phase_activity;
        }
    };

    // Updated 2026-09-21 for the universal NFH=4 baseline
    // (`universal_nfh_baseline_substeps`): a fresh hour's first attempt is
    // now unconditionally floored at 4, which already equals
    // `minimum_freeze_flow_coupling_substeps` (also 4) -- so the
    // `HeatInducedPhaseChangeRequiresQuarterHourSubsteps` failure this
    // test previously exercised on a bare first attempt (floored only at
    // 1 before this fix) can no longer occur on any fresh hour's first
    // attempt at all; it is subsumed by the universal floor. The first
    // attempt now succeeds immediately at substep_count=4, and
    // `freeze_flow_coupling_floor_active` is instead set directly from
    // this attempt's own significant-phase-change signal -- a real,
    // correct behavior change caused by the fix, not a test weakening.
    var fixture: Fixture = .{};
    var preferred: u8 = 1;
    var cooldown: u8 = 0;
    var freeze_flow_floor = false;
    try recoverFixedExternalHourAdaptively(&fixture, &preferred, &cooldown, &freeze_flow_floor, false);
    try std.testing.expectEqualSlices(u8, &.{4}, fixture.schedules[0..fixture.attempts]);
    try std.testing.expectEqual(@as(u8, 4), preferred);
    // No escalation occurred (the first attempt was accepted outright), so
    // the coarsening-probe cooldown, only ever set on a failed/escalated
    // attempt, stays at its initial value.
    try std.testing.expectEqual(@as(u8, 0), cooldown);
    try std.testing.expect(freeze_flow_floor);

    // A later accepted quarter-hour schedule with no significant heat-induced
    // phase activity releases the floor even while resident winter ice remains.
    preferred = 4;
    cooldown = 0;
    fixture = .{ .retain_phase_activity = false };
    try recoverFixedExternalHourAdaptively(&fixture, &preferred, &cooldown, &freeze_flow_floor, false);
    try std.testing.expectEqualSlices(u8, &.{4}, fixture.schedules[0..fixture.attempts]);
    try std.testing.expectEqual(@as(u8, 2), preferred);
    try std.testing.expect(!freeze_flow_floor);
}

test "adaptive fixed-hour recovery jumps directly from stiff whole-hour heat" {
    const Fixture = struct {
        schedules: [2]u8 = @splat(0),
        attempts: usize = 0,

        fn run(self: *@This(), substep_count: u8) !void {
            self.schedules[self.attempts] = substep_count;
            self.attempts += 1;
            if (substep_count < stiff_heat_direct_recovery_substeps)
                return error.SoilHeatSolverStagnated;
        }
    };

    var fixture: Fixture = .{};
    var preferred: u8 = 1;
    var cooldown: u8 = 0;
    var freeze_flow_floor = false;
    try recoverFixedExternalHourAdaptively(&fixture, &preferred, &cooldown, &freeze_flow_floor, false);
    // Updated 2026-09-21 for the universal NFH=4 baseline: the first
    // attempt is now floored at 4, not 1.
    try std.testing.expectEqualSlices(
        u8,
        &.{ 4, stiff_heat_direct_recovery_substeps },
        fixture.schedules[0..fixture.attempts],
    );
    try std.testing.expectEqual(stiff_heat_direct_recovery_substeps, preferred);
    try std.testing.expectEqual(coarsening_probe_cooldown_hours, cooldown);
}

test "adaptive fixed-hour recovery reports its bounded terminal failure" {
    const Fixture = struct {
        fn run(_: *@This(), substep_count: u8) !void {
            if (substep_count == maximum_bounded_recovery_substeps)
                return error.SoilHeatSolverStagnated;
            return error.InvalidSnowSurfaceExchangeTemperature;
        }
    };

    var fixture: Fixture = .{};
    var preferred: u8 = 64;
    var cooldown: u8 = 0;
    var freeze_flow_floor = false;
    try std.testing.expectError(
        error.SoilHeatSolverStagnated,
        recoverFixedExternalHourAdaptively(&fixture, &preferred, &cooldown, &freeze_flow_floor, false),
    );
}

test "fixed external hour recovery escalates through the full chain and stops on hard defects" {
    const RetryableFixture = struct {
        schedules: [4]u8 = @splat(0),
        attempts: usize = 0,
        scientific_pool: f64 = 5,

        fn run(self: *@This(), substep_count: u8) !void {
            if (self.scientific_pool != 5) return error.DirtyHourlyRecoveryEntry;
            self.schedules[self.attempts] = substep_count;
            self.attempts += 1;
            self.scientific_pool += 1;
            self.scientific_pool = 5;
            return error.SoluteReactionSolverDidNotConverge;
        }
    };
    var retryable: RetryableFixture = .{};
    try std.testing.expectError(
        error.SoluteReactionSolverDidNotConverge,
        recoverFixedExternalHour(&retryable),
    );
    try std.testing.expectEqualSlices(
        u8,
        &.{ 1, 20, 32, 64 },
        &retryable.schedules,
    );
    try std.testing.expectEqual(@as(usize, 4), retryable.attempts);
    try std.testing.expectEqual(@as(f64, 5), retryable.scientific_pool);
    inline for (.{
        error.LitterExchangeSolverDiverged,
        error.LitterExchangeSolverStagnated,
        error.LitterExchangeSolverDidNotConverge,
        error.RootSaltSolverDiverged,
        error.RootSaltSolverStagnated,
        error.RootSaltSolverDidNotConverge,
        error.CanopyAirSolverDidNotConverge,
    }) |late_nonlinear_failure|
        try std.testing.expect(isFixedHourRecoveryFailure(late_nonlinear_failure));

    const HardFailureFixture = struct {
        attempts: usize = 0,
        scientific_pool: f64 = 5,

        fn run(self: *@This(), substep_count: u8) !void {
            _ = substep_count;
            self.attempts += 1;
            self.scientific_pool += 1;
            self.scientific_pool = 5;
            return error.LitterSoluteWithoutWaterCarrier;
        }
    };
    var hard: HardFailureFixture = .{};
    try std.testing.expectError(
        error.LitterSoluteWithoutWaterCarrier,
        recoverFixedExternalHour(&hard),
    );
    try std.testing.expectEqual(@as(usize, 1), hard.attempts);
    try std.testing.expectEqual(@as(f64, 5), hard.scientific_pool);
    try std.testing.expect(!isFixedHourRecoveryFailure(error.LitterSoluteWithoutWaterCarrier));
    // WATSUB retains a broader private schedule policy for candidate assembly;
    // the whole-stage gate must not inherit its invalid-state retries.
    try std.testing.expect(ecosys.soil_water_heat_step.isRetryableSolverFailure(
        error.LitterSoluteWithoutWaterCarrier,
    ));
}

test "fixed external hour gives every dt-recoverable WATSUB candidate one bounded fallback" {
    const Fixture = struct {
        failure: anyerror,
        schedules: [2]u8 = @splat(0),
        attempts: usize = 0,
        scientific_pool: f64 = 5,

        fn run(self: *@This(), substep_count: u8) !void {
            if (self.scientific_pool != 5) return error.DirtyHourlyRecoveryEntry;
            self.schedules[self.attempts] = substep_count;
            self.attempts += 1;
            self.scientific_pool += 1;
            // Updated 2026-09-21 for the universal NFH=4 baseline: the
            // first attempt is now floored at 4, not 1.
            if (substep_count == 4) {
                // The production attempt transaction performs this rollback
                // before returning the rejected coarse-schedule error.
                self.scientific_pool = 5;
                return self.failure;
            }
        }
    };

    const dt_recoverable = [_]anyerror{
        error.InvalidSoilVaporCandidate,
        error.SoilPhaseCandidateExceedsPoreCapacity,
        error.SingularSnowHeatSystem,
        error.SingularSnowVaporDiffusionSystem,
        error.SoilEnthalpyTargetOutsideTemperatureBracket,
        error.InvalidSnowSurfaceExchangeCandidate,
        error.InvalidSnowSurfaceExchangeTemperature,
        error.NegativeGroundAirVaporStorage,
        error.SupersaturatedGroundAirVaporStorage,
        error.InvalidLitterSoilWaterCandidate,
        error.InvalidLitterSoilHeatCapacityCandidate,
        error.InvalidLitterSoilTemperatureCandidate,
    };
    for (dt_recoverable) |failure| {
        try std.testing.expect(
            ecosys.soil_water_heat_step.isFixedHourDtRecoveryFailure(failure),
        );
        try std.testing.expect(isFixedHourRecoveryFailure(failure));
        var fixture: Fixture = .{ .failure = failure };
        try recoverFixedExternalHour(&fixture);
        try std.testing.expectEqual(@as(usize, 2), fixture.attempts);
        // Updated 2026-09-21 for the universal NFH=4 baseline: the first
        // attempt is now floored at 4, not 1.
        try std.testing.expectEqualSlices(u8, &.{ 4, 20 }, &fixture.schedules);
        try std.testing.expectEqual(@as(f64, 6), fixture.scientific_pool);
    }

    // These conditions expose a conservation/representation defect rather
    // than excessive dt; fixed-hour refinement must not mask them.
    for ([_]anyerror{
        error.GroundAirSurfaceVaporTransferMismatch,
        error.LitterSoluteWithoutWaterCarrier,
        error.LitterMineralWithoutWaterCarrier,
        error.NegativeLitterSoilInterfaceCandidate,
        error.NegativeLitterSoilInterfaceRoundoff,
    }) |hard_failure| {
        try std.testing.expect(!ecosys.soil_water_heat_step.isFixedHourDtRecoveryFailure(hard_failure));
        try std.testing.expect(!isFixedHourRecoveryFailure(hard_failure));
    }
}

test "phenology aliases rebind after each forced recovery owner swap" {
    const Phenology = struct {
        active: []bool,
        emerged: []bool,
    };
    const Metadata = struct {
        species_names: []const u8,
        species_alive: []bool,
    };

    var old_active = [_]bool{ false, false, false, false };
    var old_emerged = [_]bool{ false, false, false, false };
    var development: []bool = old_emerged[0..];
    var harvest: ?[]bool = old_emerged[0..];
    const first_names = [_]u8{ 1, 2 };
    const second_names = [_]u8{1};
    var metadata = [_]Metadata{
        .{ .species_names = &first_names, .species_alive = old_active[0..2] },
        .{ .species_names = &second_names, .species_alive = old_active[2..3] },
    };

    var retry_active = [_]bool{ true, false, false, true };
    var retry_emerged = [_]bool{ true, true, false, true };
    const valid_second_alive = metadata[1].species_alive;
    metadata[1].species_alive = old_active[2..4];
    try std.testing.expectError(
        error.PhenologyAliasRebindDimensionMismatch,
        rebindPhenologyAliases(
            &Phenology{ .active = &retry_active, .emerged = &retry_emerged },
            &development,
            &harvest,
            &metadata,
            2,
        ),
    );
    try std.testing.expectEqual(@intFromPtr(old_emerged[0..].ptr), @intFromPtr(development.ptr));
    try std.testing.expectEqual(@intFromPtr(old_emerged[0..].ptr), @intFromPtr(harvest.?.ptr));
    try std.testing.expectEqual(@intFromPtr(old_active[0..].ptr), @intFromPtr(metadata[0].species_alive.ptr));
    metadata[1].species_alive = valid_second_alive;

    try rebindPhenologyAliases(
        &Phenology{ .active = &retry_active, .emerged = &retry_emerged },
        &development,
        &harvest,
        &metadata,
        2,
    );
    try std.testing.expectEqual(@intFromPtr(retry_emerged[0..].ptr), @intFromPtr(development.ptr));
    try std.testing.expectEqual(@intFromPtr(retry_emerged[0..].ptr), @intFromPtr(harvest.?.ptr));
    try std.testing.expectEqualSlices(bool, retry_active[0..2], metadata[0].species_alive);
    try std.testing.expectEqual(@intFromPtr(retry_active[2..].ptr), @intFromPtr(metadata[1].species_alive.ptr));

    // A second rejected attempt swaps in another checkpoint arena generation;
    // no consumer may retain the preceding retry generation's allocation.
    var finer_active = [_]bool{ false, true, true, false };
    var finer_emerged = [_]bool{ false, true, true, true };
    try rebindPhenologyAliases(
        &Phenology{ .active = &finer_active, .emerged = &finer_emerged },
        &development,
        &harvest,
        &metadata,
        2,
    );
    try std.testing.expectEqual(@intFromPtr(finer_emerged[0..].ptr), @intFromPtr(development.ptr));
    try std.testing.expectEqual(@intFromPtr(finer_emerged[0..].ptr), @intFromPtr(harvest.?.ptr));
    try std.testing.expectEqualSlices(bool, finer_active[0..2], metadata[0].species_alive);
    try std.testing.expectEqual(@intFromPtr(finer_active[2..].ptr), @intFromPtr(metadata[1].species_alive.ptr));
}

test "production preserves soil source order and same-hour biology transport coupling" {
    const allocator = std.testing.allocator;
    const stage_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_heat_water_solute.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(stage_source);
    const sediment_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_sediment.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(sediment_source);
    const runoff_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_gas_surface_water.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(runoff_source);
    const vegetation_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_vegetation.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(vegetation_source);
    const root_water_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/plant/root/plant_root_water_storage_state_update.zig", allocator, .limited(512 * 1024));
    defer allocator.free(root_water_source);
    const entry_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/ecosys_ng.zig", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(entry_source);
    const production_source_end = std.mem.indexOf(
        u8,
        stage_source,
        "test \"production preserves soil source order and same-hour biology transport coupling\"",
    ) orelse return error.MissingProductionSourceBoundary;
    const production_source = stage_source[0..production_source_end];

    const heat_workspace = std.mem.indexOf(u8, entry_source, "ecosys.soil_heat_solver.Workspace.init(") orelse return error.MissingSoilHeatWorkspace;
    const heat_workspace_dense_bound = std.mem.indexOfPos(u8, entry_source, heat_workspace, "hourly_heat_water_solute.production_dense_newton_max_components") orelse return error.MissingSoilHeatWorkspaceDenseNewtonBound;
    const heat_workspace_end = std.mem.indexOfPos(u8, entry_source, heat_workspace, ");") orelse return error.MissingSoilHeatWorkspaceEnd;
    try std.testing.expect(heat_workspace < heat_workspace_dense_bound and heat_workspace_dense_bound < heat_workspace_end);

    const recovery_owner = std.mem.indexOf(u8, stage_source, "fn recoverFixedExternalHour(") orelse return error.MissingHourlyRecoveryOwner;
    const retry_gate = std.mem.indexOfPos(u8, stage_source, recovery_owner, "isFixedHourRecoveryFailure(err)") orelse return error.MissingHourlyRecoveryRetryGate;
    const public_entry = std.mem.lastIndexOf(u8, stage_source, "pub fn solveSoilHeatWaterAndSoluteTransport(") orelse return error.MissingSoilHeatWaterSoluteStageEntry;
    const deep_begin = std.mem.indexOfPos(u8, stage_source, public_entry, "workspace.transaction.begin(") orelse return error.MissingHourlyRecoveryDeepTransaction;
    const stable_capture = std.mem.indexOfPos(u8, stage_source, deep_begin, "transaction.captureCurrentStableLayoutFrom(outer_transaction)") orelse return error.MissingHourlyRecoveryStableJournalReuse;
    const gas_rollback = std.mem.indexOfPos(u8, stage_source, stable_capture, "soil_gas_transaction.rollback()") orelse return error.MissingHourlyRecoverySoilGasRollback;
    const carbon_rollback = std.mem.indexOfPos(u8, stage_source, gas_rollback, "carbon_exchange_transaction.rollback()") orelse return error.MissingHourlyRecoveryCarbonRollback;
    const deep_rollback = std.mem.indexOfPos(u8, stage_source, carbon_rollback, "try transaction.rollback()") orelse return error.MissingHourlyRecoveryDeepRollback;
    const alias_rebind = std.mem.indexOfPos(u8, stage_source, deep_rollback, "try workspace.rebindAfterOwnerRollback()") orelse return error.MissingHourlyRecoveryAliasRebind;
    const successful_recovery_commit = std.mem.indexOfPos(u8, stage_source, alias_rebind, "soil_gas_transaction.commit()") orelse return error.MissingHourlyRecoverySuccessCommit;
    const recovery_dispatch = std.mem.indexOfPos(u8, stage_source, alias_rebind, "recoverFixedExternalHourAdaptively(") orelse return error.MissingHourlyRecoveryDispatch;
    try std.testing.expect(retry_gate < public_entry);
    try std.testing.expect(deep_begin < stable_capture and stable_capture < gas_rollback and gas_rollback < carbon_rollback and carbon_rollback < deep_rollback and deep_rollback < alias_rebind and alias_rebind < successful_recovery_commit and successful_recovery_commit < recovery_dispatch);
    const layer_roundoff_provenance = std.mem.indexOfPos(u8, stage_source, recovery_dispatch, "try coupled_substeps.publishWaterStorageUpdateProvenance(") orelse return error.MissingAcceptedLayerWaterUpdateArithmeticProvenance;
    const stage_success = std.mem.indexOfPos(u8, stage_source, layer_roundoff_provenance, "stage_succeeded = true") orelse return error.MissingCoupledStageSuccessPublication;
    try std.testing.expect(layer_roundoff_provenance < stage_success);
    const accept_hour = std.mem.indexOf(u8, entry_source, "noinline fn acceptHourAndPublish(") orelse return error.MissingAcceptHourPhase;
    const final_storage_reconstruction = std.mem.indexOfPos(u8, entry_source, accept_hour, "try diagnostics.reconstructLayerMassBalanceScopes(") orelse return error.MissingFinalConservationStorageReconstruction;
    const roundoff_provenance_consume = std.mem.indexOfPos(u8, entry_source, final_storage_reconstruction, "accumulateAcceptedWaterStorageUpdateRoundoff(") orelse return error.MissingAcceptedWaterUpdateArithmeticProvenanceConsumer;
    const hourly_cell_gate = std.mem.indexOfPos(u8, entry_source, roundoff_provenance_consume, "hourly_cell_conservation.evaluate(") orelse return error.MissingHourlyCellConservationGate;
    const hourly_layer_gate = std.mem.indexOfPos(u8, entry_source, hourly_cell_gate, "layer_local_conservation.evaluate(") orelse return error.MissingHourlyLayerConservationGate;
    try std.testing.expect(final_storage_reconstruction < roundoff_provenance_consume and roundoff_provenance_consume < hourly_cell_gate and hourly_cell_gate < hourly_layer_gate);
    const attempt_call = std.mem.indexOfPos(u8, stage_source, stable_capture, "solveSoilHeatWaterAndSoluteTransportAttempt(") orelse return error.MissingReportedRecoveryAttempt;
    const attempt_gas_report = std.mem.indexOfPos(u8, stage_source, attempt_call, "self.gas_failure_report,") orelse return error.MissingAttemptGasFailureReport;
    const attempt_solute_report = std.mem.indexOfPos(u8, stage_source, attempt_gas_report, "self.solute_failure_report,") orelse return error.MissingAttemptSoluteFailureReport;
    try std.testing.expect(attempt_call < attempt_gas_report and attempt_gas_report < attempt_solute_report and attempt_solute_report < gas_rollback);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, production_source, ".failure_report = self.gas_failure_report"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, production_source, ".failure_report = null"),
    );
    const phase_heat_owner = std.mem.indexOfPos(u8, stage_source, recovery_dispatch, "noinline fn publishPhaseAndBoundaryHeat(") orelse return error.MissingPhaseAndBoundaryHeatPublisher;
    const cell_ledger_owner = std.mem.indexOfPos(u8, stage_source, phase_heat_owner, "noinline fn publishHourlyCellTransportLedgers(") orelse return error.MissingHourlyCellTransportLedgerPublisher;
    const layer_surface_owner = std.mem.indexOfPos(u8, stage_source, cell_ledger_owner, "noinline fn publishHourlyLayerSurfaceHeatAndWater(") orelse return error.MissingHourlyLayerSurfaceHeatAndWaterPublisher;
    const layer_aqueous_gas_owner = std.mem.indexOfPos(u8, stage_source, layer_surface_owner, "noinline fn publishHourlyLayerAqueousGasAndBubble(") orelse return error.MissingHourlyLayerAqueousGasAndBubblePublisher;
    const layer_organic_mineral_owner = std.mem.indexOfPos(u8, stage_source, layer_aqueous_gas_owner, "noinline fn publishHourlyLayerOrganicMineralAndDissolvedGas(") orelse return error.MissingHourlyLayerOrganicMineralAndDissolvedGasPublisher;
    const layer_advective_heat_owner = std.mem.indexOfPos(u8, stage_source, layer_organic_mineral_owner, "noinline fn publishHourlyLayerExternalAdvectiveHeat(") orelse return error.MissingHourlyLayerExternalAdvectiveHeatPublisher;
    const layer_external_boundaries_owner = std.mem.indexOfPos(u8, stage_source, layer_advective_heat_owner, "noinline fn publishHourlyLayerExternalBoundaries(") orelse return error.MissingHourlyLayerExternalBoundariesPublisher;
    const layer_ledger_owner = std.mem.indexOfPos(u8, stage_source, layer_external_boundaries_owner, "noinline fn publishHourlyLayerTransportLedgers(") orelse return error.MissingHourlyLayerTransportLedgerPublisher;
    const entry = std.mem.indexOfPos(u8, stage_source, layer_ledger_owner, "fn solveSoilHeatWaterAndSoluteTransportAttempt(") orelse return error.MissingSoilHeatWaterSoluteAttempt;
    try std.testing.expect(phase_heat_owner < cell_ledger_owner and
        cell_ledger_owner < layer_surface_owner and
        layer_surface_owner < layer_aqueous_gas_owner and
        layer_aqueous_gas_owner < layer_organic_mineral_owner and
        layer_organic_mineral_owner < layer_advective_heat_owner and
        layer_advective_heat_owner < layer_external_boundaries_owner and
        layer_external_boundaries_owner < layer_ledger_owner and
        layer_ledger_owner < entry);
    const phase_heat_body = stage_source[phase_heat_owner..cell_ledger_owner];
    const cell_ledger_body = stage_source[cell_ledger_owner..layer_surface_owner];
    const layer_ledger_body = stage_source[layer_surface_owner..entry];
    const layer_ledger_wrapper = stage_source[layer_ledger_owner..entry];
    inline for (.{
        "accumulateAcceptedSignedInternalHeat(",
        "accumulateSignedInternalHeat(",
        "accumulateSoilLayerSignedInternalHeat(",
        "accumulateAcceptedSignedHeat(",
    }) |publication| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, phase_heat_body, publication));
    inline for (.{
        "accumulateSoilFaceTransfers(",
        "accumulateAqueousFaceTransfers(",
        "accumulateAqueousExternalBoundaries(",
        "accumulateGasFaceTransfers(",
        "accumulateOrganicTransport(",
        "accumulateMineralNitrogenTransport(",
        "accumulateDissolvedGasTransport(",
        "@memcpy(context.hourly_cell_boundary_ledger.cells, dedicated_candidate.cells);",
    }) |publication| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, cell_ledger_body, publication));
    inline for (.{
        "accumulateSurfaceTopsoilHeatTransfer(",
        "accumulateSoilWaterHeatFaces(",
        "accumulateAqueousFaces(",
        "accumulateGasFaces(",
        "accumulateSoilGasBubbleActivity(",
        "accumulateOrganicFaces(",
        "accumulateMineralNitrogenFaces(",
        "accumulateDissolvedGasFaces(",
        "accumulateSoilExternalAdvectiveHeat(",
        "accumulateSoilExternalBoundaries(",
        "@memcpy(context.hourly_layer_boundary_ledger.activity, layer_candidate.activity);",
    }) |publication| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, layer_ledger_body, publication));
    const layer_surface_publish = std.mem.indexOf(u8, layer_ledger_wrapper, "try publishHourlyLayerSurfaceHeatAndWater(") orelse return error.MissingHourlyLayerSurfaceHeatAndWaterPublication;
    const layer_aqueous_gas_publish = std.mem.indexOfPos(u8, layer_ledger_wrapper, layer_surface_publish, "try publishHourlyLayerAqueousGasAndBubble(") orelse return error.MissingHourlyLayerAqueousGasAndBubblePublication;
    const layer_organic_mineral_publish = std.mem.indexOfPos(u8, layer_ledger_wrapper, layer_aqueous_gas_publish, "try publishHourlyLayerOrganicMineralAndDissolvedGas(") orelse return error.MissingHourlyLayerOrganicMineralAndDissolvedGasPublication;
    const layer_advective_heat_publish = std.mem.indexOfPos(u8, layer_ledger_wrapper, layer_organic_mineral_publish, "try publishHourlyLayerExternalAdvectiveHeat(") orelse return error.MissingHourlyLayerExternalAdvectiveHeatPublication;
    const layer_external_boundaries_publish = std.mem.indexOfPos(u8, layer_ledger_wrapper, layer_advective_heat_publish, "try publishHourlyLayerExternalBoundaries(") orelse return error.MissingHourlyLayerExternalBoundariesPublication;
    const layer_atomic_publish = std.mem.indexOfPos(u8, layer_ledger_wrapper, layer_external_boundaries_publish, "@memcpy(context.hourly_layer_boundary_ledger.activity, layer_candidate.activity);") orelse return error.MissingHourlyLayerAtomicPublication;
    try std.testing.expect(layer_surface_publish < layer_aqueous_gas_publish and
        layer_aqueous_gas_publish < layer_organic_mineral_publish and
        layer_organic_mineral_publish < layer_advective_heat_publish and
        layer_advective_heat_publish < layer_external_boundaries_publish and
        layer_external_boundaries_publish < layer_atomic_publish);
    inline for (.{
        "try publishHourlyLayerSurfaceHeatAndWater(",
        "try publishHourlyLayerAqueousGasAndBubble(",
        "try publishHourlyLayerOrganicMineralAndDissolvedGas(",
        "try publishHourlyLayerExternalAdvectiveHeat(",
        "try publishHourlyLayerExternalBoundaries(",
        "const layer_candidate_values = try context.allocator.dupe(",
        "defer context.allocator.free(layer_candidate_values);",
        "@memcpy(context.hourly_layer_boundary_ledger.activity, layer_candidate.activity);",
    }) |publication| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, layer_ledger_wrapper, publication));
    const production = stage_source[entry..];
    const watsub = std.mem.indexOf(u8, production, "advanceMappedDeferred(") orelse return error.MissingWatsubBinding;
    const dense_newton_binding = std.mem.indexOfPos(u8, production, watsub, ".dense_newton_max_components = production_dense_newton_max_components") orelse return error.MissingLayerComponentDenseNewtonBinding;
    const exact_schedule = std.mem.indexOfPos(u8, production, watsub, ".exact_substep_count = exact_substep_count") orelse return error.MissingExactRecoveryScheduleBinding;
    const final_carriers = std.mem.indexOfPos(u8, production, watsub, "transport_replay.captureFinal()") orelse return error.MissingAcceptedWatsubCarrierCertificate;
    const nitro = std.mem.indexOfPos(u8, production, final_carriers, ".nitro,") orelse return error.MissingNitroPhase;
    const hfunc_uptake = std.mem.indexOfPos(u8, production, nitro, "post_watsub_biology.advance(") orelse return error.MissingPostWatsubBiology;
    const grosub_extract = std.mem.indexOfPos(u8, production, hfunc_uptake, "advanceUptakeGrowthAndExtract(") orelse return error.MissingGrosubExtractPhase;
    const canopy_standing_dead_fire = std.mem.indexOfPos(u8, production, grosub_extract, "produceCanopyStandingDeadFireBeforeSolute(") orelse return error.MissingPreSoluteCanopyStandingDeadFire;
    const solute = std.mem.indexOfPos(u8, production, canopy_standing_dead_fire, ".solute,") orelse return error.MissingSolutePhase;
    const trnsfr = std.mem.indexOfPos(u8, production, solute, "replayAcceptedTransport()") orelse return error.MissingTrnsfrReplay;
    const accepted_transport_ledgers = std.mem.indexOfPos(u8, production, trnsfr, "publishAcceptedLedgers()") orelse return error.MissingAcceptedTransportLedgerPublication;
    const surface_trnsfrs = std.mem.indexOfPos(u8, production, accepted_transport_ledgers, ".surface_gas,") orelse return error.MissingSurfaceGasTransport;
    const surface_call_end = std.mem.indexOfPos(u8, production, surface_trnsfrs, ");") orelse return error.MissingSurfaceGasTransportEnd;
    const surface_call = production[surface_trnsfrs..surface_call_end];
    _ = std.mem.indexOf(u8, surface_call, "gas_failure_report,") orelse return error.MissingSurfaceGasFailureReport;
    const phase_heat_publish = std.mem.indexOfPos(u8, production, surface_trnsfrs, "try publishPhaseAndBoundaryHeat(context, &accepted_soil_water_heat);") orelse return error.MissingPhaseAndBoundaryHeatPublication;
    const cell_ledger_publish = std.mem.indexOfPos(u8, production, phase_heat_publish, "try publishHourlyCellTransportLedgers(context, &coupled_substeps);") orelse return error.MissingHourlyCellTransportLedgerPublication;
    const layer_ledger_publish = std.mem.indexOfPos(u8, production, cell_ledger_publish, "try publishHourlyLayerTransportLedgers(") orelse return error.MissingHourlyLayerTransportLedgerPublication;
    const runoff = std.mem.indexOfPos(u8, production, layer_ledger_publish, "transportDissolvedGasAndSurfaceWater(") orelse return error.MissingRunoffErosionOwner;
    try std.testing.expect(watsub < dense_newton_binding and dense_newton_binding < exact_schedule and exact_schedule < final_carriers and final_carriers < nitro and nitro < hfunc_uptake and hfunc_uptake < grosub_extract and grosub_extract < canopy_standing_dead_fire and canopy_standing_dead_fire < solute and solute < trnsfr and trnsfr < accepted_transport_ledgers and accepted_transport_ledgers < surface_trnsfrs and surface_trnsfrs < phase_heat_publish and phase_heat_publish < cell_ledger_publish and cell_ledger_publish < layer_ledger_publish and layer_ledger_publish < runoff);
    const shoot_fire_owner = std.mem.indexOf(u8, vegetation_source, "pub noinline fn produceCanopyStandingDeadFireBeforeSolute(") orelse return error.MissingPreSoluteCanopyStandingDeadFireOwner;
    const shoot_fire_apply = std.mem.indexOfPos(u8, vegetation_source, shoot_fire_owner, "plant_shoot_fire.apply(") orelse return error.MissingCanopyStandingDeadFireProducer;
    const shoot_fire_solutes = std.mem.indexOfPos(u8, vegetation_source, shoot_fire_apply, ".publishCanopyFireSurfaceSolutes(") orelse return error.MissingCanopyStandingDeadFireSolutePublication;
    const shoot_fire_salt_ledger = std.mem.indexOfPos(u8, vegetation_source, shoot_fire_solutes, ".accumulateAcceptedLegacyPlantSaltInput(") orelse return error.MissingCanopyStandingDeadFireSaltPublication;
    try std.testing.expect(shoot_fire_owner < shoot_fire_apply and shoot_fire_apply < shoot_fire_solutes and shoot_fire_solutes < shoot_fire_salt_ledger);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, vegetation_source, "plant_shoot_fire.apply("));
    try std.testing.expect(std.mem.indexOf(u8, entry_source, "plant_shoot_fire.apply(") == null);
    try std.testing.expect(std.mem.indexOf(u8, entry_source, "convergeSurfaceLitterChemistry(") == null);
    try std.testing.expectEqual(@as(usize, 256), production_dense_newton_max_components);
    try std.testing.expect(std.mem.indexOf(u8, production, ".dense_newton_max_components = context.config.tile_cells") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, "replayAcceptedTransport()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, "publishAcceptedLedgers()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, ".nitro,"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, ".solute,"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, ".surface_gas,"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, "try publishPhaseAndBoundaryHeat(context, &accepted_soil_water_heat);"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, "try publishHourlyCellTransportLedgers(context, &coupled_substeps);"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, "try publishHourlyLayerTransportLedgers("));
    const runoff_call_end = std.mem.indexOfPos(u8, production, runoff, ");") orelse return error.MissingRunoffErosionOwnerEnd;
    const runoff_call = production[runoff..runoff_call_end];
    // The legacy wrapper still contains its pre-refactor gas owner behind
    // this explicit flag. Late replay is the sole TRNSFR producer.
    const old_gas_report = std.mem.indexOf(u8, runoff_call, "gas_failure_report,") orelse return error.MissingRunoffGasFailureReport;
    const solute_report = std.mem.indexOfPos(u8, runoff_call, old_gas_report, "solute_failure_report,") orelse return error.MissingRunoffSoluteFailureReport;
    const diagnostic_argument = std.mem.indexOfPos(u8, runoff_call, solute_report, "diagnostic_first_hour,") orelse return error.MissingRunoffDiagnosticArgument;
    const replay_owns_gas = std.mem.indexOfPos(u8, runoff_call, solute_report, "true,") orelse return error.MissingReplayOwnedGasGuard;
    try std.testing.expect(old_gas_report < solute_report and solute_report < replay_owns_gas and replay_owns_gas < diagnostic_argument);
    try std.testing.expect(std.mem.indexOf(
        u8,
        production,
        "solute_solid_carrier_rebase.rebaseFromAcceptedChange(",
    ) == null);

    // NITRO and SOLUTE must be real producers, and their same-hour products
    // must feed both aqueous/mineral and gas TRNSFR consumers.
    const nitro_owner = std.mem.indexOf(u8, sediment_source, "if (phase == .nitro)") orelse return error.MissingNitroOwner;
    const soil_biology = std.mem.indexOfPos(u8, sediment_source, nitro_owner, "runSoilBiogeochemistryBySerialTile(context)") orelse return error.MissingSoilBiogeochemistryProducer;
    const solute_owner = std.mem.indexOfPos(u8, sediment_source, soil_biology, "if (phase == .solute)") orelse return error.MissingSoluteOwner;
    const chemistry = std.mem.indexOfPos(u8, sediment_source, solute_owner, "convergeHourlySoilChemistry(") orelse return error.MissingSoilChemistryProducer;
    try std.testing.expect(nitro_owner < soil_biology and soil_biology < solute_owner and solute_owner < chemistry);
    const surface_gas_owner = std.mem.indexOf(u8, sediment_source, "if (phase == .surface_gas)") orelse return error.MissingSurfaceGasOwner;
    const surface_gas_advance = std.mem.indexOfPos(u8, sediment_source, surface_gas_owner, "advanceWithFailureReport(") orelse return error.MissingSurfaceGasReportedAdvance;
    const surface_gas_report = std.mem.indexOfPos(u8, sediment_source, surface_gas_advance, "gas_failure_report,") orelse return error.MissingSurfaceGasReportedAdvanceBinding;
    try std.testing.expect(surface_gas_owner < surface_gas_advance and surface_gas_advance < surface_gas_report);
    const transport_owner = std.mem.indexOf(u8, stage_source, "fn advanceTransport(") orelse return error.MissingTransportOwner;
    const transport_end = std.mem.indexOfPos(u8, stage_source, transport_owner, "fn replayAcceptedTransport(") orelse return error.MissingTransportOwnerEnd;
    const transport_body = stage_source[transport_owner..transport_end];
    const transport_dispatch_end = std.mem.indexOf(
        u8,
        transport_body,
        "noinline fn advanceTransportInterfaceAndDiffusivity(",
    ) orelse return error.MissingTransportInterfacePhase;
    const transport_dispatch = transport_body[0..transport_dispatch_end];
    var previous_phase_call: usize = 0;
    inline for (.{
        "advanceTransportInterfaceAndDiffusivity(",
        "advanceAqueousSoluteTransport(",
        "advanceOrganicTransport(",
        "advanceMineralNitrogenTransport(",
        "advanceDissolvedGasTransport(",
        "advanceSoilGasTransport(",
    }) |phase_call| {
        const position = std.mem.indexOfPos(u8, transport_dispatch, previous_phase_call, phase_call) orelse
            return error.MissingOrderedTransportPhase;
        try std.testing.expect(position >= previous_phase_call);
        previous_phase_call = position + phase_call.len;
    }
    inline for (.{
        "noinline fn advanceTransportInterfaceAndDiffusivity(",
        "noinline fn advanceAqueousSoluteTransport(",
        "noinline fn advanceOrganicTransport(",
        "noinline fn advanceMineralNitrogenTransport(",
        "noinline fn advanceDissolvedGasTransport(",
        "noinline fn advanceSoilGasTransport(",
    }) |phase_owner| try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, transport_body, phase_owner),
    );
    inline for (.{
        "transport_step.advanceSoilSolutes(",
        "mineral_nitrogen_transport.advance(",
        "soil_gas_transport.advance(",
    }) |consumer| try std.testing.expect(std.mem.indexOf(u8, transport_body, consumer) != null);
    // Every accepted recovery substep contributes to the hourly dry-gas
    // boundary owner; neither atmosphere nor subsurface may fall back to the
    // last solver substep that remains in the public workspace.
    try std.testing.expect(std.mem.indexOf(u8, transport_body, "addFiniteSlices(self.gas_atmospheric_total_g, context.soil_gas_transport.atmospheric_flux_g_per_h)") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport_body, "addFiniteSlices(self.gas_subsurface_total_g, context.soil_gas_transport.subsurface_flux_g_per_h)") != null);
    const accepted_ledger_owner = std.mem.indexOf(u8, stage_source, "fn publishAcceptedLedgers(") orelse return error.MissingAcceptedTransportLedgerOwner;
    const accepted_ledger_end = std.mem.indexOfPos(u8, stage_source, accepted_ledger_owner, "fn publishAcceptedSurfaceTemperature(") orelse return error.MissingAcceptedTransportLedgerOwnerEnd;
    const accepted_ledger_body = stage_source[accepted_ledger_owner..accepted_ledger_end];
    try std.testing.expect(std.mem.indexOf(u8, accepted_ledger_body, "@memcpy(self.context.soil_gas_transport.atmospheric_flux_g_per_h, self.gas_atmospheric_total_g)") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted_ledger_body, "@memcpy(self.context.soil_gas_transport.subsurface_flux_g_per_h, self.gas_subsurface_total_g)") != null);
    const replay_owner = std.mem.indexOf(u8, stage_source, "fn replayAcceptedTransport(") orelse return error.MissingTransportReplayOwner;
    const replay_end = std.mem.indexOfPos(u8, stage_source, replay_owner, "fn rebaseAllChemistryCarriers(") orelse return error.MissingTransportReplayOwnerEnd;
    const replay_body = stage_source[replay_owner..replay_end];
    const first_carrier_rebase = std.mem.indexOf(u8, replay_body, "try self.rebaseAllChemistryCarriers(") orelse return error.MissingFirstReplayCarrierRebase;
    const replay_loop = std.mem.indexOfPos(u8, replay_body, first_carrier_rebase, "for (0..self.transport_replay.count)") orelse return error.MissingSequentialTransportReplay;
    const advance = std.mem.indexOfPos(u8, replay_body, replay_loop, "try self.advanceTransport(") orelse return error.MissingReplayTransportAdvance;
    const exit_carrier_rebase = std.mem.indexOfPos(u8, replay_body, advance, "try self.rebaseAllChemistryCarriers(") orelse return error.MissingReplayExitCarrierRebase;
    const physical_restore = std.mem.indexOfPos(u8, replay_body, exit_carrier_rebase, "restoreFinal()") orelse return error.MissingTransportPhysicalRestore;
    try std.testing.expect(first_carrier_rebase < replay_loop and replay_loop < advance and advance < exit_carrier_rebase and exit_carrier_rebase < physical_restore);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, replay_body, "try self.rebaseAllChemistryCarriers("));
    const restore_owner = std.mem.indexOf(u8, production_source, "fn restoreFinal(self: *Self)") orelse return error.MissingTransportReplayRestoreOwner;
    const restore_end = std.mem.indexOfPos(u8, production_source, restore_owner, "fn deinit(self: *Self)") orelse return error.MissingTransportReplayRestoreEnd;
    const restore_body = production_source[restore_owner..restore_end];
    const accepted_carrier_restore = std.mem.indexOf(u8, restore_body, "try self.bindFrom(self.restore_values)") orelse return error.MissingAcceptedTransportCarrierRestore;
    const vapor_mirror_restore = std.mem.indexOfPos(u8, restore_body, accepted_carrier_restore, "synchronizeWaterVaporMolarMirror(") orelse return error.MissingAcceptedTransportVaporMirrorRestore;
    try std.testing.expect(accepted_carrier_restore < vapor_mirror_restore);

    const runoff_route = std.mem.indexOf(u8, runoff_source, "surface_runoff.routeWithSurfaceBoundary(") orelse return error.MissingSurfaceRunoffRouting;
    const erosion = std.mem.indexOfPos(u8, runoff_source, runoff_route, ".erosion_redist,") orelse return error.MissingErosionPhase;
    const erosion_owner = std.mem.indexOf(u8, sediment_source, "if (phase == .erosion_redist)") orelse return error.MissingErosionOwner;
    const redist_call = std.mem.indexOf(u8, sediment_source, "finalizeRedistAndLedgers(") orelse return error.MissingRedistFinalization;
    const redist_owner = std.mem.indexOf(u8, vegetation_source, "pub fn finalizeRedistAndLedgers(") orelse return error.MissingRedistOwner;
    try std.testing.expect(runoff_route < erosion);
    try std.testing.expect(erosion_owner < redist_call);
    try std.testing.expect(redist_owner < vegetation_source.len);

    const uptake_owner = std.mem.indexOf(u8, vegetation_source, "pub noinline fn advanceUptakeGrowthAndExtract(") orelse return error.MissingUptakeGrowthOwner;
    const redist_root_owner = std.mem.indexOfPos(u8, vegetation_source, uptake_owner, "fn applyRootWaterHeatAtRedistEntry(") orelse return error.MissingRedistRootWaterOwner;
    const uptake_body = vegetation_source[uptake_owner..redist_root_owner];
    const nitro_matrix_refresh = std.mem.indexOf(u8, uptake_body, "mineral_nitrogen_transport.refreshMatrixFromReactionState(") orelse return error.MissingSameHourNitroMatrixRefresh;
    const oxygen_uptake = std.mem.indexOfPos(u8, uptake_body, nitro_matrix_refresh, "plant_root_gas_transport.advanceOxygen(") orelse return error.MissingRootOxygenUptake;
    const ammonia_bind = std.mem.indexOfPos(u8, uptake_body, oxygen_uptake, "soil_ammonia_phase_bridge.refreshTransientFromMineral(") orelse return error.MissingSameHourNitroAmmoniaBinding;
    const passive_root_gas = std.mem.indexOfPos(u8, uptake_body, ammonia_bind, "plant_root_gas_transport.advance(") orelse return error.MissingPassiveRootGasUptake;
    const ammonia_publish = std.mem.indexOfPos(u8, uptake_body, ammonia_bind, "soil_ammonia_phase_bridge.publishTransientToMineral(") orelse return error.MissingSameHourRootAmmoniaPublication;
    const matrix_publish = std.mem.indexOfPos(u8, uptake_body, ammonia_publish, "mineral_nitrogen_transport.publishMatrix(") orelse return error.MissingSameHourRootMineralNitrogenPublication;
    const nutrient_uptake = std.mem.indexOfPos(u8, uptake_body, matrix_publish, "applyRootNutrientUptake(context.*)") orelse return error.MissingRootNutrientUptake;
    const grosub_remobilization = std.mem.indexOfPos(u8, uptake_body, nutrient_uptake, "applyPlantStorageRemobilization(context.*") orelse return error.MissingGrosubStorageRemobilization;
    const grosub_root = std.mem.indexOfPos(u8, uptake_body, grosub_remobilization, "applyRootMetabolism(context.*,") orelse return error.MissingGrosubRootMetabolism;
    try std.testing.expect(nitro_matrix_refresh < oxygen_uptake and oxygen_uptake < ammonia_bind and ammonia_bind < passive_root_gas and passive_root_gas < ammonia_publish and ammonia_publish < matrix_publish and matrix_publish < nutrient_uptake and nutrient_uptake < grosub_remobilization and grosub_remobilization < grosub_root);
    try std.testing.expect(std.mem.indexOf(u8, uptake_body, "plant_root_water_storage_state_update.state_update(") == null);

    const redist_root_end = std.mem.indexOfPos(u8, vegetation_source, redist_root_owner, "pub fn finalizeRedistAndLedgers(") orelse return error.MissingRedistOwner;
    const redist_root_body = vegetation_source[redist_root_owner..redist_root_end];
    const root_water = std.mem.indexOf(u8, redist_root_body, "plant_root_water_storage_state_update.state_update(") orelse return error.MissingRootWaterStateUpdate;
    const root_heat_landscape = std.mem.indexOfPos(u8, redist_root_body, root_water, ".accumulateAcceptedSubsurfaceCombustionAndRootHeat(") orelse return error.MissingSameHourRootHeatLandscapeBooking;
    const root_heat_cell = std.mem.indexOfPos(u8, redist_root_body, root_heat_landscape, "hourly_cell_conservation.accumulateSubsurfaceCombustionAndRootHeat(") orelse return error.MissingSameHourRootHeatCellBooking;
    const redist_apply = std.mem.indexOfPos(u8, vegetation_source, redist_root_end, "try applyRootWaterHeatAtRedistEntry(context)") orelse return error.MissingRedistRootWaterApplication;
    try std.testing.expect(root_water < root_heat_landscape and root_heat_landscape < root_heat_cell);
    try std.testing.expect(redist_root_end < redist_apply);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, vegetation_source, "plant_root_water_storage_state_update.state_update("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, vegetation_source, "try applyRootWaterHeatAtRedistEntry(context)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, vegetation_source, "soil_ammonia_phase_bridge.refreshTransientFromMineral("));
    inline for (.{
        "thermal.total_heat_capacity_megajoules_per_m3_k[soil] =",
        "convective_water_heat_megajoules[soil] =",
        "PlantRootWaterEnergyConservationFailure",
    }) |binding| try std.testing.expect(std.mem.indexOf(u8, root_water_source, binding) != null);
    try std.testing.expect(std.mem.indexOf(u8, vegetation_source, "delayed_root_uptake_heat_megajoules") == null);
    try std.testing.expect(std.mem.indexOf(u8, entry_source, "|*delayed, value| delayed.* += value") == null);
}

test "physical litter soil publication is single owned and deferred biology rollback is owner safe" {
    const allocator = std.testing.allocator;
    const stage_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_heat_water_solute.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(stage_source);
    const entry_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/ecosys_ng.zig", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(entry_source);
    const transaction_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/driver/outer_hour_transaction.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(transaction_source);
    const bundle_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/io/checkpoint/bundle_reader.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bundle_source);
    const vegetation_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_vegetation.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(vegetation_source);

    const watsub_carrier = std.mem.indexOf(u8, stage_source, "fn advanceAcceptedSoilChemistryCarrier(") orelse return error.MissingAcceptedWatsubSoilCarrierOwner;
    const watsub_carrier_end = std.mem.indexOfPos(u8, stage_source, watsub_carrier, "fn advanceSnowBeforeSoil(") orelse return error.MissingAcceptedWatsubSoilCarrierOwnerEnd;
    const watsub_carrier_body = stage_source[watsub_carrier..watsub_carrier_end];
    const all_layer_preflight = std.mem.indexOf(u8, watsub_carrier_body, "previewLayerRoundoff(") orelse return error.MissingAcceptedWatsubAllLayerCarrierCertificate;
    const all_layer_commit = std.mem.indexOfPos(u8, watsub_carrier_body, all_layer_preflight, "soil_chemistry_water_carrier_rebase.rebaseLayer(") orelse return error.MissingAcceptedWatsubAllLayerCarrierCommit;
    try std.testing.expect(all_layer_preflight < all_layer_commit);
    try std.testing.expect(std.mem.indexOf(u8, watsub_carrier_body, "validateLayerRebase(") == null);
    try std.testing.expect(std.mem.indexOf(u8, watsub_carrier_body, "rebaseLayerWithRoundoff(") == null);
    try std.testing.expect(std.mem.indexOf(u8, watsub_carrier_body, "grid.matrix_liquid_water_m3[layer] =") == null);

    const physical = std.mem.indexOf(u8, stage_source, "fn advanceAcceptedLitterSoilPhysical(") orelse return error.MissingAcceptedLitterSoilPhysicalOwner;
    const chemical = std.mem.indexOfPos(u8, stage_source, physical, "fn advanceLitterSoilInterface(") orelse return error.MissingChemicalLitterSoilOwner;
    const physical_body = stage_source[physical..chemical];
    const preflight = std.mem.indexOf(u8, physical_body, "for (self.litter_soil_physical_candidates, 0..)") orelse return error.MissingLitterSoilPhysicalPreflight;
    const commit = std.mem.indexOfPos(u8, physical_body, preflight + 1, "for (self.litter_soil_physical_candidates)") orelse return error.MissingLitterSoilPhysicalCommit;
    try std.testing.expect(preflight < commit);
    const preflight_body = physical_body[preflight..commit];
    inline for (.{
        "surface_litter_chemistry_carrier_rebase.validateCellForAcceptedWater(",
        "soil_chemistry_water_carrier_rebase.previewLayerRoundoff(",
    }) |carrier_preflight| try std.testing.expect(std.mem.indexOf(u8, preflight_body, carrier_preflight) != null);
    inline for (.{
        "context.surface_precipitation.litter_water_m3[cell] =",
        "context.grid.matrix_liquid_water_m3[top] =",
        "context.grid.surface_temperature_k[cell] =",
        "context.grid.soil_temperature_k[top] =",
    }) |publication| try std.testing.expect(std.mem.indexOf(u8, preflight_body, publication) == null);
    const commit_body = physical_body[commit..];
    inline for (.{
        "surface_litter_chemistry_carrier_rebase.rebaseCellForAcceptedWater(",
        "soil_chemistry_water_carrier_rebase.rebaseLayer(",
        "context.surface_precipitation.litter_water_m3[cell] = candidate.new_litter_water_m3",
        "context.grid.matrix_liquid_water_m3[top] = candidate.new_soil_water_m3",
        "context.grid.surface_temperature_k[cell] = candidate.new_surface_temperature_k",
        "context.grid.soil_temperature_k[top] = candidate.new_soil_temperature_k",
    }) |publication| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, commit_body, publication));
    try std.testing.expect(std.mem.indexOf(u8, commit_body, "soil_chemistry_water_carrier_rebase.rebaseLayerWithRoundoff(") == null);
    inline for (.{
        "@memcpy(context.micropore_solute_state.water_volume_m3, context.grid.matrix_liquid_water_m3)",
        "@memcpy(context.macropore_solute_state.water_volume_m3, context.grid.macropore_liquid_water_m3)",
        "@memcpy(context.mineral_nitrogen_transport.matrix.water_volume_m3, context.grid.matrix_liquid_water_m3)",
        "@memcpy(context.mineral_nitrogen_transport.macropore.water_volume_m3, context.grid.macropore_liquid_water_m3)",
        "@memcpy(context.gas_transport.temperature_k, context.grid.soil_temperature_k)",
        "@memcpy(context.gas_transport.air_volume_m3, context.grid.air_volume_m3)",
    }) |mirror| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, commit_body, mirror));

    const chemical_end = std.mem.indexOfPos(u8, stage_source, chemical, "fn publishAcceptedSurfaceTemperature(") orelse return error.MissingChemicalLitterSoilOwnerEnd;
    const chemical_body = stage_source[chemical..chemical_end];
    inline for (.{
        "context.surface_precipitation.litter_water_m3[cell] =",
        "context.surface_litter_geometry.air_volume_m3[cell] =",
        "context.grid.matrix_liquid_water_m3[top] =",
        "context.surface_heat_capacity_megajoules_per_k[cell] =",
        "context.grid.surface_temperature_k[cell] =",
        "context.grid.soil_temperature_k[top] =",
    }) |duplicate_publication| try std.testing.expect(std.mem.indexOf(u8, chemical_body, duplicate_publication) == null);
    try std.testing.expect(std.mem.indexOf(u8, chemical_body, ".litter_to_soil_water_flux_m3_per_step = water_flux") != null);
    const carbon_before = std.mem.indexOf(u8, chemical_body, "const litter_organic_carbon_before_g_c = try context.surface_organic.totalCarbon_g_c(cell)") orelse return error.MissingLitterSoilOrganicHeatEntryCensus;
    const interface_advance = std.mem.indexOfPos(u8, chemical_body, carbon_before, "const accepted_interface = try interface.advance(") orelse return error.MissingLitterSoilInterfaceAdvance;
    const carbon_after = std.mem.indexOfPos(u8, chemical_body, interface_advance, "const litter_organic_carbon_after_g_c = try context.surface_organic.totalCarbon_g_c(cell)") orelse return error.MissingLitterSoilOrganicHeatExitCensus;
    const heat_rebase = std.mem.indexOfPos(u8, chemical_body, carbon_after, "surface_litter_organic_heat_rebase.organicCarbonRebaseHeatMegajoules(") orelse return error.MissingLitterSoilOrganicHeatRebase;
    const heat_publication = std.mem.indexOfPos(u8, chemical_body, heat_rebase, "fn publishLitterSoilOrganicHeatRebase(") orelse return error.MissingLitterSoilOrganicHeatPublication;
    try std.testing.expect(carbon_before < interface_advance and interface_advance < carbon_after and carbon_after < heat_rebase and heat_rebase < heat_publication);
    inline for (.{
        "cell_candidate.accumulateSignedInternalHeat(",
        "layer_local_conservation.accumulateSurfaceOrganicHeatRebase(",
        "landscape_candidate.accumulateAcceptedSignedInternalHeat(",
    }) |binding| try std.testing.expect(std.mem.indexOfPos(u8, chemical_body, heat_publication, binding) != null);

    const stage_fields = std.mem.indexOf(u8, stage_source, "fn captureStageTransactionalFields(") orelse return error.MissingStageTransactionalFields;
    const stage_fields_end = std.mem.indexOfPos(u8, stage_source, stage_fields, "fn irrigationChemistryParameters(") orelse return error.MissingStageTransactionalFieldsEnd;
    const stage_field_body = stage_source[stage_fields..stage_fields_end];
    try std.testing.expect(std.mem.indexOf(u8, stage_field_body, "\"plant_roots\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, stage_field_body, "\"plant_water_workspace\"") == null);

    // Both the enclosing external-hour transaction and the stage recovery
    // transaction deep clone roots/canopy and owner-swap them after stable
    // restoration. The nested transaction reuses the outer transaction's
    // validated stable-region layout rather than reflecting the giant context
    // a second time. Byte-journaling old topology backing addresses is unsafe
    // because HFUNC/GROSUB can replace and deinitialize those allocations.
    const post_start = std.mem.indexOf(u8, entry_source, "noinline fn postScienceAccounting(") orelse return error.MissingPostSciencePhase;
    const management_start = std.mem.indexOfPos(u8, entry_source, post_start, "noinline fn postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingPhase;
    const canopy_wrapper_start = std.mem.indexOfPos(u8, entry_source, management_start, "noinline fn postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapper;
    const accept_start = std.mem.indexOfPos(u8, entry_source, canopy_wrapper_start, "noinline fn acceptHourAndPublish(") orelse return error.MissingAcceptHourPhase;
    const prepare_start = std.mem.indexOfPos(u8, entry_source, accept_start, "noinline fn prepareHourlyScience(") orelse return error.MissingPrepareHourlySciencePhase;
    const advance_start = std.mem.indexOfPos(u8, entry_source, prepare_start, "noinline fn advanceHour(") orelse return error.MissingAdvanceHourPhase;
    const timeline_start = std.mem.indexOfPos(u8, entry_source, advance_start, "noinline fn runTimeline(") orelse return error.MissingTimelinePhase;
    const post_phase = entry_source[post_start..management_start];
    const management_phase = entry_source[management_start..canopy_wrapper_start];
    const accept_phase = entry_source[accept_start..prepare_start];
    const advance_phase = entry_source[advance_start..timeline_start];
    const outer_targets = std.mem.indexOf(u8, advance_phase, "const outer_hour_targets:") orelse return error.MissingOuterHourTargets;
    const target_roots = std.mem.indexOfPos(u8, advance_phase, outer_targets, ".plant_roots = &driver_context.plant_root_state.*.?") orelse return error.MissingOuterRootOwner;
    const target_canopy = std.mem.indexOfPos(u8, advance_phase, target_roots, ".plant_canopy = .{") orelse return error.MissingOuterCanopyOwner;
    const execute = std.mem.indexOfPos(u8, advance_phase, target_canopy, "executeHourlyScience(") orelse return error.MissingOuterHourlyScience;
    const post_call = std.mem.indexOfPos(u8, advance_phase, execute, "try postScienceAccounting(driver_context,") orelse return error.MissingPostScienceCall;
    const accept_call = std.mem.indexOfPos(u8, advance_phase, post_call, "try acceptHourAndPublish(driver_context,") orelse return error.MissingAcceptHourCall;
    const management_call = std.mem.indexOf(u8, post_phase, "try postScienceManagementAndGasAccounting(") orelse return error.MissingManagementAccountingCall;
    const canopy_wrapper_call = std.mem.indexOfPos(u8, post_phase, management_call, "try postScienceCanopyFireAndCloseout(") orelse return error.MissingCanopyFireWrapperCall;
    const late_failure = std.mem.indexOf(u8, management_phase, "injectFailureForTest(.after_soil_solve)") orelse return error.MissingLateOuterFailureGuard;
    const commit_hour = std.mem.indexOf(u8, accept_phase, "outer_hour_transaction.*.commit()") orelse return error.MissingOuterHourCommit;
    try std.testing.expect(target_roots < target_canopy and target_canopy < execute and execute < post_call and post_call < accept_call);
    try std.testing.expect(management_call < canopy_wrapper_call);
    _ = late_failure;
    _ = commit_hour;
    const rollback = std.mem.indexOf(u8, transaction_source, "self.stable.restore();") orelse return error.MissingStableRollback;
    const owner_swap = std.mem.indexOfPos(u8, transaction_source, rollback, "swapIntoLiveForRollback") orelse return error.MissingOwnerSwapRollback;
    try std.testing.expect(rollback < owner_swap);
    const root_swap = std.mem.indexOf(u8, bundle_source, "std.mem.swap(RootState, &bundle.plant_roots, targets.plant_roots)") orelse return error.MissingRootOwnerSwap;
    const canopy_swap = std.mem.indexOfPos(u8, bundle_source, root_swap, "bundle.plant_canopy.canopy") orelse return error.MissingCanopyOwnerSwap;
    try std.testing.expect(root_swap < canopy_swap);

    const recovery_workspace = std.mem.indexOf(u8, entry_source, "FixedHourRecoveryWorkspace.init(allocator)") orelse return error.MissingFixedHourRecoveryWorkspace;
    const recovery_context_binding = std.mem.indexOfPos(u8, entry_source, recovery_workspace, ".fixed_hour_recovery_workspace = &fixed_hour_recovery_workspace") orelse return error.MissingFixedHourRecoveryContextBinding;
    const timeline_call = std.mem.indexOf(u8, entry_source, "try runTimeline(&timeline_context,") orelse return error.MissingTimelineCall;
    const recovery_targets = std.mem.indexOfPos(u8, advance_phase, target_canopy, "driver_context.fixed_hour_recovery_workspace.*.configure(outer_hour_targets)") orelse return error.MissingFixedHourRecoveryTargets;
    const outer_transient_capture = std.mem.indexOfPos(u8, advance_phase, recovery_targets, "outer_hour_transaction.captureStable(&outer_hour_transients") orelse return error.MissingOuterTransientStableCapture;
    const recovery_entry = std.mem.lastIndexOf(u8, stage_source, "pub fn solveSoilHeatWaterAndSoluteTransport(") orelse return error.MissingSoilHeatWaterSoluteStageEntry;
    const nested_begin = std.mem.indexOfPos(u8, stage_source, recovery_entry, "workspace.transaction.begin(") orelse return error.MissingFixedHourRecoveryDeepTransaction;
    const outer_binding = std.mem.indexOfPos(u8, advance_phase, outer_transient_capture, "driver_context.fixed_hour_recovery_workspace.*.bindOuterTransaction(") orelse return error.MissingFixedHourRecoveryOuterTransactionBinding;
    const outer_unbinding = std.mem.indexOfPos(u8, advance_phase, outer_binding, "driver_context.fixed_hour_recovery_workspace.*.unbindOuterTransaction(&outer_hour_transaction)") orelse return error.MissingFixedHourRecoveryOuterTransactionUnbinding;
    const nested_stable = std.mem.indexOfPos(u8, stage_source, nested_begin, "transaction.captureCurrentStableLayoutFrom(outer_transaction)") orelse return error.MissingFixedHourRecoveryStableLayoutReuse;
    const nested_gas = std.mem.indexOfPos(u8, stage_source, nested_stable, "soil_gas_transaction.rollback()") orelse return error.MissingFixedHourRecoverySoilGasRollback;
    const nested_carbon = std.mem.indexOfPos(u8, stage_source, nested_gas, "carbon_exchange_transaction.rollback()") orelse return error.MissingFixedHourRecoveryCarbonRollback;
    const nested_owners = std.mem.indexOfPos(u8, stage_source, nested_carbon, "try transaction.rollback()") orelse return error.MissingFixedHourRecoveryPersistentRollback;
    const nested_rebind = std.mem.indexOfPos(u8, stage_source, nested_owners, "try workspace.rebindAfterOwnerRollback()") orelse return error.MissingFixedHourRecoveryAliasRebind;
    // Workspace ownership remains in main. The explicit context binding and
    // noinline timeline call connect it to the recovery sequence below.
    try std.testing.expect(recovery_workspace < recovery_context_binding and recovery_context_binding < timeline_call);
    try std.testing.expect(recovery_targets < outer_transient_capture and outer_transient_capture < outer_binding and outer_binding < outer_unbinding and nested_begin < nested_stable and nested_stable < nested_gas and nested_gas < nested_carbon and nested_carbon < nested_owners and nested_owners < nested_rebind);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, entry_source, "hourly_heat_water_solute.rebindPhenologyAliases("));
    try std.testing.expect(std.mem.indexOf(u8, stage_source[nested_begin..], "transaction.captureStable(&self.context") == null);
    try std.testing.expect(std.mem.indexOf(u8, transaction_source, "Newly allocated or tag-activated owned payloads") != null);

    const phenology_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_phenology_preparation.zig", allocator, .limited(512 * 1024));
    defer allocator.free(phenology_source);
    const root_metabolism_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/root_processes_metabolism.zig", allocator, .limited(512 * 1024));
    defer allocator.free(root_metabolism_source);
    // Checkpoint rollback swaps the phenology owner. Production consumers must
    // follow its live optional owner rather than a borrowed pre-swap slice.
    try std.testing.expect(std.mem.indexOf(u8, phenology_source, "context.development_emerged") == null);
    try std.testing.expect(std.mem.indexOf(u8, vegetation_source, "context.development_emerged") == null);
    try std.testing.expect(std.mem.indexOf(u8, root_metabolism_source, "context.development_emerged") == null);

    const stage_entry = std.mem.lastIndexOf(u8, stage_source, "pub fn solveSoilHeatWaterAndSoluteTransport(") orelse return error.MissingSoilHeatWaterSoluteStageEntry;
    const production = stage_source[stage_entry..];
    const solve = std.mem.indexOf(u8, production, "advanceMappedDeferred(") orelse return error.MissingWatsubBinding;
    const biology = std.mem.indexOfPos(u8, production, solve, "post_watsub_biology.advance(") orelse return error.MissingDeferredBiology;
    const replay = std.mem.indexOfPos(u8, production, biology, "replayAcceptedTransport()") orelse return error.MissingDeferredTransportReplay;
    try std.testing.expect(std.mem.indexOf(u8, production[0..solve], "post_watsub_biology.advance(") == null);
    try std.testing.expect(solve < biology and biology < replay);
}

test "direct precipitation heat is bound once at the current substep recipient" {
    const source = @embedFile("hourly_heat_water_solute.zig");
    const coupled = std.mem.indexOf(u8, source, "fn CoupledSubstepTransaction(") orelse return error.MissingCoupledSubstepTransaction;
    const prepare = std.mem.indexOfPos(u8, source, coupled, "noinline fn prepareSubstep(raw: *anyopaque") orelse return error.MissingCoupledPrepareSubstep;
    const accept = std.mem.indexOfPos(u8, source, prepare, "noinline fn acceptSubstep(raw: *anyopaque") orelse return error.MissingCoupledAcceptSubstep;
    const body = source[prepare..accept];
    const forcing = std.mem.indexOf(u8, body, "try Forcing.prepareSubstep(") orelse return error.MissingSoilForcingPrepare;
    const binding = std.mem.indexOf(u8, body, "try ecosys.surface_precipitation.bindSoilHeatIngress(") orelse return error.MissingDirectPrecipitationHeatBinding;
    const litter_binding = std.mem.indexOf(u8, body, "try ecosys.surface_precipitation.state_updateLitterHeatIngress(") orelse return error.MissingDirectLitterHeatBinding;
    const snow = std.mem.indexOf(u8, body, "try self.applySnowDischargeRecipientHeat(") orelse return error.MissingSnowRecipientHeatBinding;
    try std.testing.expect(forcing < binding and binding < snow);
    try std.testing.expect(binding < litter_binding and litter_binding < snow);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "try ecosys.surface_precipitation.state_updateLitterHeatIngress("));
    try std.testing.expect(std.mem.indexOf(u8, body[litter_binding..snow], "self.base_water_to_litter_m3_per_h") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "try ecosys.surface_precipitation.bindSoilHeatIngress("));
    try std.testing.expect(std.mem.indexOf(u8, body[forcing..binding], "direct_precipitation.water_to_matrix_m3_per_h = self.base_water_to_matrix_m3_per_h") != null);
    try std.testing.expect(std.mem.indexOf(u8, body[forcing..binding], "direct_precipitation.water_to_macropore_m3_per_h = self.base_water_to_macropore_m3_per_h") != null);
    const outer = std.mem.indexOf(u8, source, "\npub fn solveSoilHeatWaterAndSoluteTransport(") orelse return error.MissingSoilTransportOwner;
    try std.testing.expect(std.mem.indexOf(u8, source[outer..], "try ecosys.surface_precipitation.bindSoilHeatIngress(") == null);
}

test "production consumes legacy delayed heat once after accepted publication" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_heat_water_solute.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(source);
    // The public stage entry point is intentionally declared after the local
    // regression tests. Slice from its declaration so test string literals
    // cannot satisfy or hide the exact legacy delayed-source bindings.
    // The audit above necessarily contains this declaration as a string;
    // the executable declaration is the final occurrence in the file.
    const stage_entry = std.mem.lastIndexOf(u8, source, "pub fn solveSoilHeatWaterAndSoluteTransport(") orelse return error.MissingSoilHeatWaterSoluteStageEntry;
    const stage_end = std.mem.indexOfPos(u8, source, stage_entry, "\ntest \"") orelse source.len;
    const stage_production = source[stage_entry..stage_end];

    // Slice the executable helper itself. Helpers and regression tests are
    // interleaved in this file, so a prefix ending at the first test is not a
    // valid production boundary.
    const surface_owner_start = std.mem.indexOf(u8, source, "noinline fn publishAcceptedSurfaceTemperature(") orelse return error.MissingAcceptedSurfaceTemperaturePublication;
    const surface_owner_end = std.mem.indexOfPos(u8, source, surface_owner_start, "noinline fn publishAcceptedGroundAir(") orelse return error.MissingAcceptedGroundAirPublication;
    const surface_owner = source[surface_owner_start..surface_owner_end];
    const surface_publish: usize = 0;
    const surface_landscape = std.mem.indexOf(u8, surface_owner, ".accumulateAcceptedSurfaceCombustionHeat(") orelse return error.MissingLandscapeSurfaceCombustionHeatBooking;
    const surface_cell = std.mem.indexOfPos(u8, surface_owner, surface_landscape, ".accumulateSignedInternalHeat(") orelse return error.MissingCellSurfaceCombustionHeatBooking;
    const surface_zero = std.mem.indexOfPos(u8, surface_owner, surface_cell, "@memset(context.delayed_surface_combustion_heat_megajoules, 0)") orelse return error.MissingAcceptedSurfaceCombustionHeatRelease;
    try std.testing.expect(surface_publish < surface_landscape and surface_landscape < surface_cell and surface_cell < surface_zero);

    const fold_fire = std.mem.indexOf(u8, stage_production, "foldDelayedHeatSource(context.delayed_subsurface_combustion_heat_megajoules") orelse return error.MissingSubsurfaceCombustionHeatFold;
    const fold_root = std.mem.indexOfPos(u8, stage_production, fold_fire, "foldDelayedHeatSource(context.delayed_root_uptake_heat_megajoules") orelse return error.MissingRootUptakeHeatFold;
    const solve = std.mem.indexOfPos(u8, stage_production, fold_root, "advanceMappedDeferred(") orelse return error.MissingAcceptedSoilSolve;
    const state_publish = std.mem.indexOfPos(u8, stage_production, solve, "state_updateHourlyWaterHeatStateGeneration(") orelse return error.MissingAcceptedSoilStatePublication;
    const soil_landscape = std.mem.indexOfPos(u8, stage_production, state_publish, ".accumulateAcceptedSubsurfaceCombustionAndRootHeat(") orelse return error.MissingLandscapeSubsurfaceHeatBooking;
    const soil_cell = std.mem.indexOfPos(u8, stage_production, soil_landscape, "hourly_cell_conservation.accumulateSubsurfaceCombustionAndRootHeat(") orelse return error.MissingCellSubsurfaceHeatBooking;
    const soil_zero = std.mem.indexOfPos(u8, stage_production, soil_cell, "@memset(context.delayed_subsurface_combustion_heat_megajoules, 0)") orelse return error.MissingAcceptedSubsurfaceHeatRelease;
    const root_zero = std.mem.indexOfPos(u8, stage_production, soil_zero, "@memset(context.delayed_root_uptake_heat_megajoules, 0)") orelse return error.MissingAcceptedRootHeatRelease;
    try std.testing.expect(fold_fire < fold_root and fold_root < solve and solve < state_publish and state_publish < soil_landscape and soil_landscape < soil_cell and soil_cell < soil_zero and soil_zero < root_zero);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, surface_owner, ".accumulateAcceptedSurfaceCombustionHeat("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stage_production, ".accumulateAcceptedSubsurfaceCombustionAndRootHeat("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, stage_production, "hourly_cell_conservation.accumulateSubsurfaceCombustionAndRootHeat("));

    const snapshot_fields = std.mem.indexOf(u8, source, "fn captureStageTransactionalFields(") orelse return error.MissingStageTransactionFieldOwner;
    const snapshot_fields_end = std.mem.indexOfPos(u8, source, snapshot_fields, "fn irrigationChemistryParameters(") orelse return error.MissingStageTransactionFieldOwnerEnd;
    const captured = source[snapshot_fields..snapshot_fields_end];
    inline for (.{
        "\"landscape_boundary_ledger\"",
        "\"hourly_cell_boundary_ledger\"",
        "\"delayed_surface_combustion_heat_megajoules\"",
        "\"delayed_subsurface_combustion_heat_megajoules\"",
        "\"delayed_root_uptake_heat_megajoules\"",
    }) |field| try std.testing.expect(std.mem.indexOf(u8, captured, field) != null);
}

test "live surface albedo is source ordered and publishes only after accepted schedule" {
    const allocator = std.testing.allocator;
    const stage_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_heat_water_solute.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(stage_source);
    const solver_source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/surface/temperature_solver.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(solver_source);

    const surface_owner = std.mem.indexOf(u8, stage_source, "fn advanceSurfaceTemperature(") orelse return error.MissingAcceptedSubstepSurfaceTemperatureOwner;
    const surface_owner_end = std.mem.indexOfPos(u8, stage_source, surface_owner, "fn advanceGroundAir(") orelse return error.MissingAcceptedSubstepGroundAirOwner;
    const surface_body = stage_source[surface_owner..surface_owner_end];
    const dry_litter = std.mem.indexOf(u8, surface_body, "ground_radiation.dryLitterAlbedo(") orelse return error.MissingLiveDryLitterAlbedo;
    const current_excess = std.mem.indexOfPos(u8, surface_body, dry_litter, "const current_litter_excess_m3") orelse return error.MissingCurrentLitterExcessForAlbedo;
    const cover = std.mem.indexOfPos(u8, surface_body, current_excess, "ground_radiation.liveLitterCoverFraction(") orelse return error.MissingLiveLitterCover;
    const binding = std.mem.indexOfPos(u8, surface_body, cover, ".surface_albedo = .{") orelse return error.MissingLiveSurfaceAlbedoBinding;
    const physical_ceiling = std.mem.indexOfPos(u8, surface_body, binding, ".accept_physically_conserved_ceiling = true") orelse return error.MissingProductionSurfaceTemperaturePhysicalCeiling;
    const representable_root = std.mem.indexOfPos(u8, surface_body, physical_ceiling, ".accept_nearest_representable_root = true") orelse return error.MissingProductionSurfaceTemperatureRepresentableRoot;
    const validation = std.mem.indexOfPos(u8, surface_body, binding, "surface_temperature_solver.validateApplyContext") orelse return error.MissingLiveSurfaceTemperatureValidation;
    const solve = std.mem.indexOfPos(u8, surface_body, validation, "surface_temperature_solver.applyValidatedTile") orelse return error.MissingLiveSurfaceTemperatureSolve;
    const accepted_copy = std.mem.indexOfPos(u8, surface_body, solve, "surface_temperature_total.snow_free_surface_albedo[cell]") orelse return error.MissingAcceptedSurfaceAlbedoAccumulation;
    try std.testing.expect(dry_litter < current_excess and current_excess < cover and cover < binding and binding < physical_ceiling and physical_ceiling < representable_root and representable_root < validation and validation < solve and solve < accepted_copy);
    try std.testing.expect(std.mem.indexOf(u8, surface_body, "surface_precipitation.litter_water_m3[cell]") != null);
    try std.testing.expect(std.mem.indexOf(u8, surface_body, "surface_litter_ice_m3[cell]") != null);
    try std.testing.expect(std.mem.indexOf(u8, surface_body, "surface_precipitation.litter_water_capacity_m3[cell]") != null);
    try std.testing.expect(std.mem.indexOf(u8, surface_body, "surface_runoff.excess_surface_") == null);
    try std.testing.expect(std.mem.indexOf(u8, surface_body, "context.ground_radiation.surface_albedo") == null);
    try std.testing.expect(std.mem.indexOf(u8, surface_body, "context.surface_temperature.snow_free_surface_albedo") == null);

    const apply = std.mem.indexOf(u8, solver_source, "pub fn applyValidatedTile(") orelse return error.MissingSurfaceTemperatureApply;
    const live = std.mem.indexOfPos(u8, solver_source, apply, "const live_snow_free_albedo") orelse return error.MissingLiveSurfaceAlbedoCalculation;
    const atmospheric = std.mem.indexOfPos(u8, solver_source, live, "snowFreeAtmosphericTerms(.{") orelse return error.MissingSurfaceAtmosphericTerms;
    const residual = std.mem.indexOfPos(u8, solver_source, atmospheric, "const residual_context: ResidualContext") orelse return error.MissingSurfaceEnergyResidual;
    const nonlinear = std.mem.indexOfPos(u8, solver_source, residual, "solveWithConservationRefinement(") orelse return error.MissingSurfaceTemperatureNonlinearSolve;
    const publish = std.mem.indexOfPos(u8, solver_source, nonlinear, "result.snow_free_surface_albedo[cell] = live_snow_free_albedo") orelse return error.MissingConvergedSurfaceAlbedoPublication;
    try std.testing.expect(live < atmospheric and atmospheric < residual and residual < nonlinear and nonlinear < publish);
    const refinement_owner = std.mem.indexOf(u8, solver_source, "fn solveWithConservationRefinement(") orelse return error.MissingSurfaceConservationRefinement;
    const refinement_end = std.mem.indexOfPos(u8, solver_source, refinement_owner, "fn validateSettings(") orelse return error.MissingSurfaceConservationRefinementEnd;
    const refinement_body = solver_source[refinement_owner..refinement_end];
    try std.testing.expect(std.mem.indexOf(u8, refinement_body, "numerics.newtonPicard(") != null);
    try std.testing.expect(std.mem.indexOf(u8, refinement_body, "shared_budget") != null);

    const deferred = std.mem.lastIndexOf(u8, stage_source, "advanceMappedDeferred(") orelse return error.MissingCoupledDeferredSolve;
    const accepted_publication = std.mem.indexOfPos(u8, stage_source, deferred, "publishAcceptedSurfaceTemperature()") orelse return error.MissingAcceptedSurfaceTemperaturePublication;
    try std.testing.expect(deferred < accepted_publication);
    const publisher = std.mem.indexOf(u8, stage_source, "fn publishAcceptedSurfaceTemperature(") orelse return error.MissingAcceptedSurfaceTemperaturePublication;
    const publisher_end = std.mem.indexOfPos(u8, stage_source, publisher, "fn publishAcceptedGroundAir(") orelse return error.MissingAcceptedGroundAirPublication;
    const cover_publish = std.mem.indexOfPos(u8, stage_source, publisher, "context.surface_precipitation.litter_cover_fraction") orelse return error.MissingAcceptedLitterCoverPublication;
    try std.testing.expect(cover_publish < publisher_end);
}

test "live litter excess converts ice WE before both conductance refreshes" {
    const allocator = std.testing.allocator;
    const gas_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_gas_surface_water.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(gas_source);
    const heat_source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(heat_source);

    const helper = std.mem.indexOf(
        u8,
        gas_source,
        "pub fn litterLiquidAndPhysicalIceVolumeM3(",
    ) orelse return error.MissingPhysicalLitterIceVolumeHelper;
    const helper_end = std.mem.indexOfPos(
        u8,
        gas_source,
        helper,
        "test \"litter phase geometry converts ice water equivalent",
    ) orelse return error.MissingPhysicalLitterIceVolumeHelperEnd;
    const helper_body = gas_source[helper..helper_end];
    try std.testing.expect(std.mem.indexOf(
        u8,
        helper_body,
        "ecosys.ice_units.physicalVolumeM3FromWaterEquivalent(",
    ) != null);

    const gas_owner = std.mem.indexOf(
        u8,
        gas_source,
        "fn refreshSoilSurfaceGasConductanceCell(",
    ) orelse return error.MissingGasSurfaceConductanceOwner;
    const gas_owner_end = std.mem.indexOfPos(
        u8,
        gas_source,
        gas_owner,
        "pub fn transportDissolvedGasAndSurfaceWater(",
    ) orelse return error.MissingGasSurfaceConductanceOwnerEnd;
    const gas_body = gas_source[gas_owner..gas_owner_end];
    const gas_conversion = std.mem.indexOf(
        u8,
        gas_body,
        "const current_litter_phase_volume_m3 = try litterLiquidAndPhysicalIceVolumeM3(",
    ) orelse return error.MissingGasPhysicalLitterIceConversion;
    const gas_density = std.mem.indexOfPos(
        u8,
        gas_body,
        gas_conversion,
        "freeze_thaw.ice_density_megagrams_per_m3",
    ) orelse return error.MissingGasLitterIceDensity;
    const gas_excess = std.mem.indexOfPos(
        u8,
        gas_body,
        gas_density,
        "const current_litter_excess_m3",
    ) orelse return error.MissingGasPhysicalLitterExcess;
    const gas_cover = std.mem.indexOfPos(
        u8,
        gas_body,
        gas_excess,
        "ground_radiation.liveLitterCoverFraction(",
    ) orelse return error.MissingGasLiveLitterCover;
    try std.testing.expect(gas_conversion < gas_density and gas_density < gas_excess and gas_excess < gas_cover);

    const heat_owner = std.mem.indexOf(
        u8,
        heat_source,
        "fn advanceSurfaceTemperature(",
    ) orelse return error.MissingAcceptedSubstepSurfaceTemperatureOwner;
    const heat_owner_end = std.mem.indexOfPos(
        u8,
        heat_source,
        heat_owner,
        "fn advanceGroundAir(",
    ) orelse return error.MissingAcceptedSubstepSurfaceTemperatureOwnerEnd;
    const heat_body = heat_source[heat_owner..heat_owner_end];
    const heat_conversion = std.mem.indexOf(
        u8,
        heat_body,
        "try group_gas_surface_water.litterLiquidAndPhysicalIceVolumeM3(",
    ) orelse return error.MissingSubstepPhysicalLitterIceConversion;
    const heat_density = std.mem.indexOfPos(
        u8,
        heat_body,
        heat_conversion,
        "freeze_thaw.ice_density_megagrams_per_m3",
    ) orelse return error.MissingSubstepLitterIceDensity;
    const heat_excess = std.mem.indexOfPos(
        u8,
        heat_body,
        heat_density,
        "const current_litter_excess_m3",
    ) orelse return error.MissingSubstepPhysicalLitterExcess;
    const heat_cover = std.mem.indexOfPos(
        u8,
        heat_body,
        heat_excess,
        "ground_radiation.liveLitterCoverFraction(",
    ) orelse return error.MissingSubstepLiveLitterCover;
    try std.testing.expect(heat_conversion < heat_density and heat_density < heat_excess and heat_excess < heat_cover);
}

test "snow surface ledger publishes the frozen reference remainder exactly once" {
    const radiative: f64 = 4;
    const latent: f64 = -3;
    const carrier: f64 = -2;
    const sensible: f64 = 1;
    const frozen_reference: f64 = 7.5;
    const boundary = radiative + latent + carrier + sensible + frozen_reference;
    try std.testing.expectEqual(
        frozen_reference,
        try snowReferenceStateHeatMegajoules(boundary, radiative, latent, carrier, sensible),
    );
}

test "ground vapor gross local owners survive accepted substeps and retry reset" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(source);
    const forcing = std.mem.indexOf(u8, source, "fn SoilForcingSubstepHooks(") orelse
        return error.MissingSoilForcingSubstepHooks;
    const forcing_end = std.mem.indexOfPos(u8, source, forcing, "fn addFiniteSlices(") orelse
        return error.MissingSoilForcingSubstepHooksEnd;
    const body = source[forcing..forcing_end];
    inline for (.{
        "litter_evaporation_total_m3",
        "topsoil_evaporation_total_m3",
        "litter_condensation_total_m3",
        "topsoil_condensation_total_m3",
    }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, body, field ++ ": []f64") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "@memset(self." ++ field ++ ", 0)") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "addFiniteSlices(self." ++ field) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, body, ".litter_evaporation_m3 = self.litter_evaporation_step_m3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ".topsoil_evaporation_m3 = self.topsoil_evaporation_step_m3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ".litter_condensation_m3 = self.litter_condensation_step_m3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ".topsoil_condensation_m3 = self.topsoil_condensation_step_m3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "state_updateAcceptedLanes(.{") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "state_update(.{") == null);
}

test "dual ground vapor producers bind water heat ground air and rollback owners" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(source);
    const surface = std.mem.indexOf(u8, source, "fn advanceSurfaceTemperature(") orelse return error.MissingAcceptedSubstepSurfaceTemperatureOwner;
    const post_phase = std.mem.indexOfPos(u8, source, surface, "fn postPhasePreHeat(") orelse return error.MissingPostPhaseTopsoilBoundaryOwner;
    const ground = std.mem.indexOfPos(u8, source, post_phase, "fn advanceGroundAir(") orelse return error.MissingAcceptedSubstepGroundAirOwner;
    const surface_body = source[surface..post_phase];
    const post_phase_body = source[post_phase..ground];
    const potential_refresh = std.mem.indexOf(
        u8,
        surface_body,
        "surface_litter_water_environment.applyTile",
    ) orelse return error.MissingAcceptedSubstepSurfaceWaterPotentialRefresh;
    const potential_binding = std.mem.indexOf(
        u8,
        surface_body,
        ".surface_water_potential_megapascal = context.surface_litter_water_environment.matric_plus_osmotic_water_potential_megapascal",
    ) orelse return error.MissingAcceptedSurfaceWaterPotentialBinding;
    try std.testing.expect(potential_refresh < potential_binding);
    inline for (.{
        ".surface_water_potential_megapascal = context.surface_litter_water_environment.matric_plus_osmotic_water_potential_megapascal",
        "surface_temperature_work.vapor_liquid_water_change_m3[cell]",
    }) |binding| try std.testing.expect(std.mem.indexOf(u8, surface_body, binding) != null);
    try std.testing.expect(std.mem.indexOf(u8, surface_body, "ground_vapor_exchange.accepted(.{") == null);
    inline for (.{
        "ground_vapor_exchange.accepted(.{",
        ".owner_water_potential_megapascal = matric_plus_osmotic",
        "external_water_change_m3_by_layer[top] = topsoil_vapor.water_change_m3",
        "topsoil_vapor.total_heat_megajoules - represented_storage_heat",
        "try self.advanceGroundAir(time_step_hours)",
    }) |binding| try std.testing.expect(std.mem.indexOf(u8, post_phase_body, binding) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        post_phase_body,
        "soil_chemistry_water_carrier_rebase.rebaseLayer(",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        post_phase_body,
        "soil_chemistry_water_carrier_rebase.rebaseLayerWithRoundoff(",
    ) == null);
    const production_end = std.mem.indexOf(u8, source, "\ntest \"transport replay keeps pending retries private") orelse
        return error.MissingHourlyHeatWaterSoluteProductionEnd;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source[0..production_end], "try self.advanceGroundAir(time_step_hours)"));

    const snow = std.mem.indexOfPos(u8, source, ground, "fn advanceSnowSurfaceEquilibrium(") orelse return error.MissingAcceptedSubstepSnowSurfaceOwner;
    const ground_body = source[ground..snow];
    try std.testing.expect(std.mem.indexOf(u8, ground_body, "const expected_time_step_hours = 1.0 /") != null);
    try std.testing.expect(std.mem.indexOf(u8, ground_body, "if (time_step_hours != expected_time_step_hours)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ground_body, "-(self.forcing.accepted_litter_vapor_change_m3[cell]") != null);
    try std.testing.expect(std.mem.indexOf(u8, ground_body, "self.ground_air_combined_surface_vapor_conductance[cell] = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, ground_body, "snow_to_air_water_rate") != null);
    try std.testing.expect(std.mem.indexOf(u8, ground_body, "snow_free_fraction * context.ground_air_surface_vapor_fraction[cell]") == null);

    const forcing = std.mem.indexOf(u8, source, "fn SoilForcingSubstepHooks(") orelse return error.MissingSoilForcingSubstepHooks;
    const forcing_end = std.mem.indexOfPos(u8, source, forcing, "fn addFiniteSlices(") orelse return error.MissingSoilForcingSubstepHooksEnd;
    const forcing_body = source[forcing..forcing_end];
    inline for (.{
        "@memset(self.accepted_litter_vapor_change_m3, 0)",
        "@memset(self.accepted_topsoil_vapor_change_m3, 0)",
        "@memset(self.accepted_topsoil_liquid_change_m3, 0)",
        "@memset(self.topsoil_vapor_heat_total_megajoules, 0)",
    }) |rollback_binding| try std.testing.expect(std.mem.indexOf(u8, forcing_body, rollback_binding) != null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, forcing_body, "soil_chemistry_water_carrier_rebase.rebaseLayer("),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        forcing_body,
        "surface_litter_chemistry_carrier_rebase.rebaseCellForAcceptedWater(",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        forcing_body,
        "surface_litter_chemistry_carrier_rebase.rebaseFromAcceptedLiquidWaterChange(",
    ) == null);

    const coupled = std.mem.indexOf(u8, source, "fn CoupledSubstepTransaction(") orelse return error.MissingCoupledSubstepTransaction;
    const prepare = std.mem.indexOfPos(u8, source, coupled, "noinline fn prepareSubstep(raw: *anyopaque") orelse return error.MissingCoupledPrepareSubstep;
    const accept = std.mem.indexOfPos(u8, source, prepare, "noinline fn acceptSubstep(raw: *anyopaque") orelse return error.MissingCoupledAcceptSubstep;
    const prepare_body = source[prepare..accept];
    const reserve_entry = std.mem.indexOf(u8, prepare_body, "transport_replay.beginSubstep(time_step_hours)") orelse return error.MissingTransportReplayEntryReservation;
    const chemistry_entry = std.mem.indexOfPos(u8, prepare_body, reserve_entry, "entry_topsoil_chemistry.capture(") orelse return error.MissingTopsoilChemistryEntryCapture;
    const forcing_prepare = std.mem.indexOfPos(u8, prepare_body, chemistry_entry, "Forcing.prepareSubstep(") orelse return error.MissingSoilForcingPrepare;
    try std.testing.expect(reserve_entry < chemistry_entry and chemistry_entry < forcing_prepare);
    const accept_end = std.mem.indexOfPos(u8, source, accept, "noinline fn acceptPhaseDisplacement(") orelse return error.MissingCoupledAcceptSubstepEnd;
    const accept_body = source[accept..accept_end];
    const chemistry_restore = std.mem.indexOf(u8, accept_body, "entry_topsoil_chemistry.restoreAndDisarm(") orelse return error.MissingTopsoilChemistryEntryRestore;
    const accepted_rebase = std.mem.indexOfPos(u8, accept_body, chemistry_restore, "advanceAcceptedSoilChemistryCarrier()") orelse return error.MissingAcceptedSoilChemistryCarrierRebase;
    try std.testing.expect(chemistry_restore < accepted_rebase);

    const transaction_fields = std.mem.indexOf(u8, source, "fn captureStageTransactionalFields(") orelse return error.MissingStageTransactionFieldOwner;
    const transaction_fields_end = std.mem.indexOfPos(u8, source, transaction_fields, "fn irrigationChemistryParameters(") orelse return error.MissingStageTransactionFieldOwnerEnd;
    const captured = source[transaction_fields..transaction_fields_end];
    inline for (.{
        "\"grid\"",
        "\"ground_air\"",
        "\"surface_precipitation\"",
        "\"soil_hourly_workspace\"",
        "\"hourly_layer_boundary_ledger\"",
    }) |owner| try std.testing.expect(std.mem.indexOf(u8, captured, owner) != null);
    // The needle is also present below in this source-inspection test. Select
    // the production declaration, not the test's own string literal.
    const rollback = std.mem.indexOf(u8, source, "noinline fn rollbackFailure(raw: *anyopaque)") orelse return error.MissingCoupledRollback;
    const rollback_end = std.mem.indexOfPos(u8, source, rollback, "noinline fn prepareSubstep(") orelse return error.MissingCoupledRollbackEnd;
    const rollback_body = source[rollback..rollback_end];
    const snapshot_restore = std.mem.indexOf(u8, rollback_body, "self.schedule_snapshot.restore()") orelse return error.MissingCoupledSnapshotRollback;
    const forcing_restore = std.mem.indexOfPos(u8, rollback_body, snapshot_restore, "Forcing.rollbackFailure(@ptrCast(&self.forcing))") orelse return error.MissingCoupledForcingRollback;
    const totals_reset = std.mem.indexOfPos(u8, rollback_body, forcing_restore, "self.zeroTotals()") orelse return error.MissingCoupledTotalRollback;
    try std.testing.expect(snapshot_restore < forcing_restore and forcing_restore < totals_reset);
    const zero_totals = std.mem.indexOf(u8, source, "noinline fn zeroTotals(self: *Self)") orelse return error.MissingCoupledTotalResetOwner;
    const zero_totals_end = std.mem.indexOfPos(u8, source, zero_totals, "fn incrementWaterStorageUpdate(") orelse return error.MissingCoupledTotalResetOwnerEnd;
    try std.testing.expect(std.mem.indexOf(
        u8,
        source[zero_totals..zero_totals_end],
        "@memset(self.water_storage_update_operation_count_by_scope, 0)",
    ) != null);
    inline for (.{
        "@memset(self.ground_air_sensible_heat_closure_absolute_total_megajoules, 0)",
        "@memset(self.ground_air_sensible_heat_storage_activity_total_megajoules, 0)",
        "for (self.ground_air_sensible_heat_transfer_activity_total_megajoules, self.ground_air_geometry_balance)",
        "self.ground_air_accepted_substep_count = 0",
        "self.ground_air_accepted_duration_hours = 0",
    }) |reset| try std.testing.expect(std.mem.indexOf(
        u8,
        source[zero_totals..zero_totals_end],
        reset,
    ) != null);

    const publisher = std.mem.indexOf(u8, source, "fn publishAcceptedAtmosphericLocalActivity(") orelse return error.MissingAcceptedAtmosphericLocalPublication;
    const publisher_end = std.mem.indexOfPos(u8, source, publisher, "fn publishAcceptedSnowSchedule(") orelse return error.MissingAcceptedSnowSchedulePublication;
    const publisher_body = source[publisher..publisher_end];
    try std.testing.expect(std.mem.indexOf(u8, publisher_body, ".topsoil_condensation_m3 = self.forcing.topsoil_condensation_total_m3[cell]") != null);
    try std.testing.expect(std.mem.indexOf(u8, publisher_body, "self.topsoil_sensible_heat_total_megajoules[cell]") != null);
}

test "snow canopy longwave binding reads accepted temperatures and source view factors before ledger publication" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/stages/hourly_heat_water_solute.zig",
        allocator,
        .limited(2 * 1024 * 1024),
    );
    defer allocator.free(source);
    const owner = std.mem.indexOf(u8, source, "fn advanceSnowSurface(") orelse
        return error.MissingAcceptedSubstepSnowSurfaceOwner;
    const owner_end = std.mem.indexOfPos(u8, source, owner, "fn validateGroundAirSurfaceVaporTransfer(") orelse
        return error.MissingAcceptedSubstepSnowSurfaceOwnerEnd;
    const body = source[owner..owner_end];
    const living_temperature = std.mem.indexOf(u8, body, "context.plants.canopy_temperature_k[first..last]") orelse
        return error.MissingAcceptedLivingCanopyTemperatureBinding;
    const dead_temperature = std.mem.indexOf(u8, body, "canopy.plant_standing_dead_surface_temperature_k[first..last]") orelse
        return error.MissingAcceptedStandingDeadTemperatureBinding;
    const living_fraction = std.mem.indexOf(u8, body, "retention.living_radiation_fraction[first..last]") orelse
        return error.MissingLivingCanopyRadiationFractionBinding;
    const dead_fraction = std.mem.indexOf(u8, body, "retention.standing_dead_radiation_fraction[first..last]") orelse
        return error.MissingStandingDeadRadiationFractionBinding;
    const radiation = std.mem.indexOf(u8, body, "snow_surface_atmosphere_exchange.calculateNetRadiation") orelse
        return error.MissingAcceptedSnowRadiationCalculation;
    const living_temperature_input = std.mem.indexOfPos(u8, body, radiation, ".living_canopy_temperature_k = living_canopy_temperature_k") orelse
        return error.MissingAcceptedLivingCanopyTemperatureRadiationInput;
    const dead_temperature_input = std.mem.indexOfPos(u8, body, radiation, ".standing_dead_temperature_k = standing_dead_temperature_k") orelse
        return error.MissingAcceptedStandingDeadTemperatureRadiationInput;
    const living_fraction_input = std.mem.indexOfPos(u8, body, radiation, ".living_canopy_radiation_fraction = living_canopy_radiation_fraction") orelse
        return error.MissingLivingCanopyRadiationFractionInput;
    const dead_fraction_input = std.mem.indexOfPos(u8, body, radiation, ".standing_dead_radiation_fraction = standing_dead_radiation_fraction") orelse
        return error.MissingStandingDeadRadiationFractionInput;
    const rate = std.mem.indexOfPos(u8, body, radiation, "radiation.net_radiation_megajoules_per_h") orelse
        return error.MissingAcceptedSnowRadiationRate;
    const accepted = std.mem.indexOfPos(u8, body, rate, "snow_surface_atmosphere_exchange.applyAccepted") orelse
        return error.MissingAcceptedSnowSurfaceExchange;
    const ledger = std.mem.indexOfPos(u8, body, accepted, "surface_energy_total.net_radiation_megajoules_per_m2[cell]") orelse
        return error.MissingAcceptedSnowRadiationLedger;
    try std.testing.expect(living_temperature < radiation and dead_temperature < radiation);
    try std.testing.expect(living_fraction < radiation and dead_fraction < radiation);
    try std.testing.expect(radiation < living_temperature_input and living_temperature_input < rate);
    try std.testing.expect(radiation < dead_temperature_input and dead_temperature_input < rate);
    try std.testing.expect(radiation < living_fraction_input and living_fraction_input < rate);
    try std.testing.expect(radiation < dead_fraction_input and dead_fraction_input < rate);
    try std.testing.expect(rate < accepted and accepted < ledger);
}

test "all mutating snow physics are schedule-owned in source order with no one-shot owner" {
    const allocator = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_heat_water_solute.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(source);
    const old_owner = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_snow_energy.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(old_owner);
    const driver = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/stages/hourly_process_driver.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(driver);
    const prepare_hook = std.mem.indexOf(u8, source, "fn prepareSubstep(raw:") orelse return error.MissingAcceptedSubstepPrepareHook;
    const reserve_replay = std.mem.indexOfPos(u8, source, prepare_hook, "transport_replay.beginSubstep(time_step_hours)") orelse return error.MissingTransportReplayReservation;
    const prepare_call = std.mem.indexOfPos(u8, source, reserve_replay, "advanceSnowBeforeSoil(time_step_hours)") orelse return error.MissingSnowSchedulePreparationCall;
    const soil_forcing = std.mem.indexOfPos(u8, source, prepare_call, "Forcing.prepareSubstep") orelse return error.MissingAcceptedSubstepSoilForcing;
    try std.testing.expect(prepare_hook < reserve_replay and reserve_replay < prepare_call and prepare_call < soil_forcing);
    const prepare = std.mem.indexOf(u8, source, "fn advanceSnowBeforeSoil(") orelse return error.MissingSnowSchedulePreparation;
    const surface_temperature = std.mem.indexOfPos(u8, source, prepare, "advanceSurfaceTemperature(time_step_hours)") orelse return error.MissingAcceptedSubstepSurfaceTemperature;
    const surface_equilibrium = std.mem.indexOfPos(u8, source, surface_temperature, "advanceSnowSurfaceEquilibrium(time_step_hours)") orelse return error.MissingAcceptedSubstepSnowSurfaceEquilibrium;
    const boundary = std.mem.indexOfPos(u8, source, surface_equilibrium, "advanceSnowSurface(time_step_hours)") orelse return error.MissingAcceptedSubstepSnowBoundary;
    const injection = std.mem.indexOfPos(u8, source, boundary, "state_updateAtmosphericWater(") orelse return error.MissingAcceptedSubstepSnowInjection;
    const fused_call = std.mem.indexOfPos(u8, source, injection, "advanceSourceOrderedSnowPhysics(time_step_hours, thermodynamics)") orelse return error.MissingAcceptedSourceOrderedSnowPhysics;
    const chemistry = std.mem.indexOfPos(u8, source, fused_call, "snow_transport_solver.solve") orelse return error.MissingAcceptedSubstepSnowChemistry;
    try std.testing.expect(surface_temperature < surface_equilibrium and surface_equilibrium < boundary and boundary < injection and injection < fused_call and fused_call < chemistry);
    try std.testing.expect(std.mem.indexOf(u8, source[prepare..chemistry], "advanceGroundAir(time_step_hours)") == null);
    const post_phase_hook = std.mem.indexOf(u8, source, "fn postPhasePreHeat(") orelse return error.MissingPostPhaseTopsoilBoundaryOwner;
    const deferred_ground_air = std.mem.indexOfPos(u8, source, post_phase_hook, "advanceGroundAir(time_step_hours)") orelse return error.MissingAcceptedSubstepGroundAir;
    try std.testing.expect(post_phase_hook < deferred_ground_air);
    const fused = std.mem.indexOf(u8, source, "fn advanceSourceOrderedSnowPhysics(") orelse return error.MissingAcceptedSourceOrderedSnowPhysicsOwner;
    const fused_end = std.mem.indexOfPos(u8, source, fused, "fn advanceSnowBeforeSoil(") orelse return error.MissingAcceptedSourceOrderedSnowPhysicsOwnerEnd;
    const fused_body = source[fused..fused_end];
    const melt = std.mem.indexOf(u8, fused_body, "snow_melt_water_routing.calculate") orelse return error.MissingAcceptedSubstepSnowMelt;
    const conduction = std.mem.indexOfPos(u8, fused_body, melt, "snow_heat_conduction.solve") orelse return error.MissingAcceptedSubstepSnowConduction;
    const diffusion = std.mem.indexOfPos(u8, fused_body, conduction, "snow_vapor_diffusion.solve") orelse return error.MissingAcceptedSubstepSnowVaporDiffusion;
    const equilibrium = std.mem.indexOfPos(u8, fused_body, diffusion, "snow_vapor_equilibrium.explicitTransfer") orelse return error.MissingAcceptedSubstepSnowVaporEquilibrium;
    const phase = std.mem.indexOfPos(u8, fused_body, equilibrium, "snow_phase_change.solve") orelse return error.MissingAcceptedSubstepSnowPhaseChange;
    const replay = std.mem.indexOfPos(u8, fused_body, phase, "snow_source_order_energy.apply") orelse return error.MissingAcceptedSourceOrderReplay;
    try std.testing.expect(melt < conduction and conduction < diffusion and diffusion < equilibrium and equilibrium < phase and phase < replay);
    try std.testing.expect(std.mem.indexOf(u8, source[prepare..chemistry], "state_updateMeltWater(") == null);
    try std.testing.expect(std.mem.indexOf(u8, old_owner, "surface_temperature_solver.applyValidatedTile") == null);
    try std.testing.expect(std.mem.indexOf(u8, driver, "surface_temperature_solver.applyValidatedTile") == null);
    const surface_owner = std.mem.indexOf(u8, source, "fn advanceSurfaceTemperature(") orelse return error.MissingAcceptedSubstepSurfaceTemperatureOwner;
    const surface_owner_end = std.mem.indexOfPos(u8, source, surface_owner, "fn advanceGroundAir(") orelse return error.MissingAcceptedSubstepGroundAirOwner;
    const surface_body = source[surface_owner..surface_owner_end];
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, surface_body, "surface_temperature_solver.applyTile"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, surface_body, "surface_temperature_solver.validateApplyContext"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, surface_body, "surface_temperature_solver.applyValidatedTile"));
    try std.testing.expect(std.mem.indexOf(u8, surface_body, ".timestep_hours = time_step_hours") != null);
    inline for (.{
        "canopy_air.temperature_k[plant] =",
        "canopy_air.vapor_fraction[plant] =",
        "dead_air.temperature_k[plant] =",
        "dead_air.vapor_fraction[plant] =",
        "context.ground_radiation.* =",
        "context.atmosphere.* =",
        "context.canopy_exposure.* =",
    }) |forbidden_write| try std.testing.expect(std.mem.indexOf(u8, surface_body, forbidden_write) == null);
    try std.testing.expect(std.mem.indexOf(u8, old_owner, "ground_air_exchange.solve(") == null);
    try std.testing.expect(std.mem.indexOf(u8, driver, "ground_air_exchange.solve(") == null);
    const ground_air_owner = std.mem.indexOf(u8, source, "fn advanceGroundAir(") orelse return error.MissingAcceptedSubstepGroundAirOwner;
    const ground_air_end = std.mem.indexOfPos(u8, source, ground_air_owner, "fn advanceSnowSurface(") orelse return error.MissingAcceptedSubstepSnowBoundaryOwner;
    const ground_air_body = source[ground_air_owner..ground_air_end];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ground_air_body, "ground_air_exchange.solve("));
    try std.testing.expect(std.mem.indexOf(u8, ground_air_body, "canopy_air.temperature_k[plant] =") == null);
    try std.testing.expect(std.mem.indexOf(u8, ground_air_body, "canopy_air.vapor_fraction[plant] =") == null);
    try std.testing.expect(std.mem.indexOf(u8, ground_air_body, "dead_air.temperature_k[plant] =") == null);
    try std.testing.expect(std.mem.indexOf(u8, ground_air_body, "dead_air.vapor_fraction[plant] =") == null);
    const snapshot_fields = std.mem.indexOf(u8, source, "fn captureStageTransactionalFields(") orelse return error.MissingStageTransactionFieldOwner;
    const snapshot_fields_end = std.mem.indexOfPos(u8, source, snapshot_fields, "fn irrigationChemistryParameters(") orelse return error.MissingStageTransactionFieldOwnerEnd;
    try std.testing.expect(std.mem.indexOf(u8, source[snapshot_fields..snapshot_fields_end], "\"ground_air\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source[snapshot_fields..snapshot_fields_end], "\"surface_temperature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source[snapshot_fields..snapshot_fields_end], "\"surface_energy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source[snapshot_fields..snapshot_fields_end], "\"surface_litter_ice_m3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source[snapshot_fields..snapshot_fields_end], "\"surface_litter_chemistry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source[snapshot_fields..snapshot_fields_end], "\"delayed_surface_combustion_heat_megajoules\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source[snapshot_fields..snapshot_fields_end], "\"surface_combustion_heat_megajoules_per_m2\"") != null);
    const deferred_solve = std.mem.indexOf(u8, source, "advanceMappedDeferred(") orelse return error.MissingCoupledDeferredSolve;
    const publish_surface = std.mem.indexOfPos(u8, source, deferred_solve, "publishAcceptedSurfaceTemperature()") orelse return error.MissingAcceptedSurfaceTemperaturePublication;
    const publish_ground_air = std.mem.indexOfPos(u8, source, deferred_solve, "publishAcceptedGroundAir()") orelse return error.MissingAcceptedGroundAirPublication;
    try std.testing.expect(deferred_solve < publish_surface and publish_surface < publish_ground_air);
    const accept = std.mem.indexOf(u8, source, "fn acceptSubstep(") orelse return error.MissingAcceptedSubstepHook;
    const accepted_soil_carrier = std.mem.indexOfPos(u8, source, accept, "advanceAcceptedSoilChemistryCarrier()") orelse return error.MissingAcceptedWatsubSoilCarrierRebase;
    const arm = std.mem.indexOfPos(u8, source, accepted_soil_carrier, "armSnowDisappearance()") orelse return error.MissingPreDriftSnowDisappearanceProducer;
    const drift = std.mem.indexOfPos(u8, source, arm, "advanceSnowDrift(time_step_hours)") orelse return error.MissingAcceptedSubstepSnowDrift;
    const disappearance = std.mem.indexOfPos(u8, source, drift, "consumeSnowDisappearance(&disappearance)") orelse return error.MissingPostDriftSnowDisappearanceConsumer;
    const snow_solutes = std.mem.indexOfPos(u8, source, disappearance, "applyAcceptedSurfaceDischarge(time_step_hours)") orelse return error.MissingAcceptedSnowSoluteDeposition;
    const accepted_flux = std.mem.indexOfPos(u8, source, snow_solutes, "transport_replay.stageAcceptedFluxes()") orelse return error.MissingAcceptedSubstepFluxStaging;
    const physical = std.mem.indexOfPos(u8, source, accepted_flux, "advanceAcceptedLitterSoilPhysical(time_step_hours)") orelse return error.MissingAcceptedLitterSoilPhysicalOwner;
    const schedule_commit = std.mem.indexOfPos(u8, source, physical, "transport_replay.acceptSubstep(self.litter_soil_water_flux_m3)") orelse return error.MissingTransportReplayScheduleCommit;
    const compaction = std.mem.indexOfPos(u8, source, schedule_commit, "advanceSnowCompactionAndRelayering(time_step_hours)") orelse return error.MissingAcceptedSubstepSnowCompaction;
    const accept_end = std.mem.indexOfPos(u8, source, accept, "fn advanceSnowBeforeSoil(") orelse return error.MissingAcceptedSubstepHookEnd;
    try std.testing.expect(accept < accepted_soil_carrier and accepted_soil_carrier < arm and arm < drift and drift < disappearance and disappearance < snow_solutes and snow_solutes < accepted_flux and accepted_flux < physical and physical < schedule_commit and schedule_commit < compaction);
    try std.testing.expect(std.mem.indexOf(u8, source[accept..accept_end], "advanceTransport(") == null);
    const disappearance_owner = std.mem.indexOf(u8, source, "fn armSnowDisappearance(") orelse return error.MissingAcceptedSubstepSnowDisappearanceOwner;
    const disappearance_owner_end = std.mem.indexOfPos(u8, source, disappearance_owner, "fn advanceSnowCompactionAndRelayering(") orelse return error.MissingAcceptedSubstepSnowDisappearanceOwnerEnd;
    const disappearance_body = source[disappearance_owner..disappearance_owner_end];
    const live_transfer = std.mem.indexOf(u8, disappearance_body, "armWarmThinPack(") orelse return error.MissingLiveSnowDisappearanceProducer;
    const live_consume = std.mem.indexOfPos(u8, disappearance_body, live_transfer, "disappearance.consume()") orelse return error.MissingLiveSnowDisappearanceConsumer;
    const chemistry_rebase = std.mem.indexOfPos(u8, disappearance_body, live_consume, "rebaseFromAcceptedLiquidWaterChange(") orelse return error.MissingSnowDisappearanceLitterCarrierRebase;
    const geometry_refresh = std.mem.indexOfPos(u8, disappearance_body, chemistry_rebase, "surface_litter_geometry_step.applyTile") orelse return error.MissingSnowDisappearanceLitterGeometryRefresh;
    try std.testing.expect(live_transfer < live_consume and live_consume < chemistry_rebase and chemistry_rebase < geometry_refresh);
    inline for (.{
        ".accepted_litter_discharge = self.snow_surface_discharge_total",
        "destination.litter_dry_reference_carrier_m3 = try checkedAddFiniteValue(",
        ".snow_latent_heat_of_fusion_megajoules_per_m3 = context.runscript.snow_latent_heat_of_fusion_megajoules_per_m3",
        ".surface_latent_heat_of_fusion_megajoules_per_m3 = context.runscript.soil_phase_heat_parameters.freeze_thaw.latent_heat_of_fusion_megajoules_per_m3",
        ".water_depth_m = absolute.water_m",
        ".heat_megajoules_per_m2 = absolute.heat_megajoules_m2",
        ".relative = context.config.mass_balance_relative_tolerance",
    }) |binding| try std.testing.expect(std.mem.indexOf(u8, source, binding) != null);
    try std.testing.expect(std.mem.indexOf(u8, old_owner, "snow_drift_routing.produceAndRoute") == null);
    try std.testing.expect(std.mem.indexOf(u8, old_owner, "snow_compaction.apply") == null);
    try std.testing.expect(std.mem.indexOf(u8, old_owner, "snow_relayering.apply") == null);
    inline for (.{
        "state_updateAtmosphericWater(",
        "snow_heat_conduction.solve",
        "snow_vapor_diffusion.solve",
        "snow_vapor_equilibrium.solve",
        "snow_phase_change.solve",
        "snow_melt_water_routing.calculate",
        "snow_transport_solver.solve",
        "state_updateMeltWater(",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, driver, needle) == null);
        try std.testing.expect(std.mem.indexOf(u8, old_owner, needle) == null);
    }
}

/// Classifies failures eligible for the single bounded fixed-hour fallback.
/// The attempt owns the complete source-ordered continuation
/// (NITRO -> HFUNC -> UPTAKE/GROSUB -> SOLUTE), so a late chemistry failure
/// invalidates that entire attempt. `run` is transactional: on error it must
/// restore every scientific owner and ledger before returning to the controller.
fn isFixedHourRecoveryFailure(err: anyerror) bool {
    if (ecosys.soil_water_heat_step.isFixedHourDtRecoveryFailure(err))
        return true;
    return switch (err) {
        error.CanopyAirSolverDidNotConverge,
        error.LitterExchangeSolverDiverged,
        error.LitterExchangeSolverStagnated,
        error.LitterExchangeSolverDidNotConverge,
        error.RootSaltSolverDiverged,
        error.RootSaltSolverStagnated,
        error.RootSaltSolverDidNotConverge,
        => true,
        else => false,
    };
}

fn recoverFixedExternalHour(attempt: anytype) !void {
    var preferred_substep_count: u8 = 1;
    var obsolete_cooldown: u8 = 0;
    var freeze_flow_coupling_floor_active = false;
    return recoverFixedExternalHourAdaptively(
        attempt,
        &preferred_substep_count,
        &obsolete_cooldown,
        &freeze_flow_coupling_floor_active,
        false,
    );
}

const stiff_heat_direct_recovery_substeps: u8 = 20;
/// Derived from `recovery_substep_counts` (heat_step.zig), not hardcoded,
/// so this stage's escalation ceiling can never drift from the ladder's
/// own true maximum. Fixes the design gap documented in issue-058 and
/// SOLUTE-HYDROGEN-ROW-RECURRING-NONCONVERGENCE-001 (hours 2,571 and
/// 2,604), where this same ceiling was previously a hand-maintained
/// literal that twice lagged the array's actual contents.
const maximum_bounded_recovery_substeps: u8 =
    ecosys.soil_water_heat_step.recovery_substep_counts[
        ecosys.soil_water_heat_step.recovery_substep_counts.len - 1
    ];
const coarsening_probe_cooldown_hours: u8 = 3;
const gas_coarsening_probe_cooldown_hours: u8 = 23;

/// Fortran's `wthr.f:589-601` fixes `NFH=4` as a universal, unconditional
/// substep baseline for every non-fire hour, for every layer -- an outer
/// `DO 9990 NFZ=1,NFH` loop (`soil.f:145`) that calls `HOUR1`+`WATSUB` four
/// times per external hour regardless of whether the hour "needs" it, with
/// `ICHKV`'s escalation to `NPH>=20` (`wthr.f:568-571`) layered ON TOP of
/// this baseline, not a replacement for it. Zig's `boundedInitialRecoverySubstepCount`
/// previously defaulted every hour's first attempt to `1` (the whole hour,
/// no subdivision at all) and only floored to a finer schedule reactively,
/// after a detected failure, or proactively but only for the narrow
/// already-thin-at-the-hour-start `ICHKV` case -- missing this universal
/// baseline entirely. issue-024's 2026-09-21 diagnostic experiment
/// (documented in that issue's file) confirmed applying this floor
/// unconditionally prevents hour 2,894's layer-0 collapse, clears hour
/// 2,895, and reaches hour 3,252 (358 hours further than any prior
/// attempt) before a new, distinct failure -- and was measurably faster,
/// not slower, because it eliminates most of the costly reactive
/// escalation-ladder retries. Authorized for implementation per
/// `HANDOFF-SUMMARY-2026-09-20.md` Section 3's human-reviewer decision.
const universal_nfh_baseline_substeps: u8 = 4;

comptime {
    // `stiff_heat_direct_recovery_substeps` names the first rung of this
    // stage's error-aware rescue chain (the established three-minute
    // schedule, which also exceeds the quarter-hour freeze-flow floor).
    // It must actually be a rung of the authoritative ladder, not merely
    // some value below the ladder's true maximum -- see issue-058. Uses
    // the shared membership check in heat_step.zig rather than a local
    // re-derivation, so both files agree on what "a rung" means.
    if (!ecosys.soil_water_heat_step.isRecoverySubstepCountMember(stiff_heat_direct_recovery_substeps))
        @compileError(
            "stiff_heat_direct_recovery_substeps must be a member of soil_water_heat_step.recovery_substep_counts (see issue-058)",
        );
    // `universal_nfh_baseline_substeps` (Fortran's `NFH=4`) must likewise
    // actually be a rung of the authoritative ladder.
    if (!ecosys.soil_water_heat_step.isRecoverySubstepCountMember(universal_nfh_baseline_substeps))
        @compileError(
            "universal_nfh_baseline_substeps must be a member of soil_water_heat_step.recovery_substep_counts (see issue-024)",
        );
}

/// Ladder-parameterized core of the escalation-on-failure chain
/// (issue-058). The next rung is the smallest `ladder` member that is
/// both a designated rescue-chain rung (at or above `floor`) and
/// strictly finer (a larger substep count) than the attempted schedule.
/// Factored out from `boundedRecoveryFallback` so the identical logic
/// production uses can be exercised in a test against a ladder that
/// extends past today's committed maximum, without ever touching the
/// real `recovery_substep_counts` array.
fn fallbackWithinLadder(ladder: []const u8, floor: u8, attempted_substep_count: u8) ?u8 {
    for (ladder) |candidate| {
        if (candidate < floor) continue;
        if (candidate > attempted_substep_count) return candidate;
    }
    return null;
}

/// Escalation-on-failure chain for the stage-level bounded recovery
/// controller. Genuinely array-driven (issue-058): delegates to
/// `fallbackWithinLadder` over the authoritative `recovery_substep_counts`
/// ladder, floored at `stiff_heat_direct_recovery_substeps`. Extending
/// `recovery_substep_counts` past its current maximum therefore extends
/// this chain automatically and correctly, instead of silently no-op'ing
/// or crashing the way the previous hardcoded 20/32/64 chain did when
/// pushed out of sync with the array (issue-058's `STATUS_ACCESS_VIOLATION`
/// reproduction, issue-024 round 7).
fn boundedRecoveryFallback(attempted_substep_count: u8) ?u8 {
    return fallbackWithinLadder(
        &ecosys.soil_water_heat_step.recovery_substep_counts,
        stiff_heat_direct_recovery_substeps,
        attempted_substep_count,
    );
}

fn boundedInitialRecoverySubstepCount(
    preferred_substep_count: u8,
    freeze_flow_coupling_floor_active: bool,
    ichkv_proactive_floor_active: bool,
) !u8 {
    var requested = @min(preferred_substep_count, maximum_bounded_recovery_substeps);
    // issue-024 (2026-09-21, universal NFH=4 baseline, see
    // `universal_nfh_baseline_substeps`'s doc comment): Fortran
    // unconditionally subdivides EVERY non-fire hour into at least
    // `NFH=4` substeps before ever attempting WATSUB, regardless of
    // whether the hour would have converged fine at `substep_count=1`.
    // This floor applies to every hour's first attempt, not only the
    // narrower freeze-flow/`ICHKV` cases floored below.
    requested = @max(requested, universal_nfh_baseline_substeps);
    if (freeze_flow_coupling_floor_active)
        requested = @max(
            requested,
            ecosys.soil_water_heat_step.minimum_freeze_flow_coupling_substeps,
        );
    // issue-024/issue-068/issue-077: `wthr.f:568-571`'s `ICHKV` check is
    // PROACTIVE -- Fortran forces `NPH=MAX(20,NPX)` for the whole hour
    // before ever attempting WATSUB, whenever the top active layer's heat
    // capacity is already below the area-scaled threshold at the START of
    // the hour. This floors the FIRST attempt only, at the ladder's own
    // `stiff_heat_direct_recovery_substeps` (20) rung -- a different
    // starting point already inside the existing, already-tested ladder,
    // not a new ceiling, damping variant, or Newton/Anderson change. Every
    // hour where no layer trips the underlying check leaves `requested`
    // (and therefore the returned substep count) untouched.
    if (ichkv_proactive_floor_active)
        requested = @max(requested, stiff_heat_direct_recovery_substeps);
    for (ecosys.soil_water_heat_step.recovery_substep_counts) |supported|
        if (supported == requested) return requested;
    return error.InvalidPreferredHourlyRecoverySubstepCount;
}

fn nextCoarserRecoverySubstepCount(substep_count: u8) !u8 {
    const schedules = &ecosys.soil_water_heat_step.recovery_substep_counts;
    for (schedules, 0..) |candidate, index| {
        if (candidate != substep_count) continue;
        return if (index == 0) candidate else schedules[index - 1];
    }
    return error.InvalidPreferredHourlyRecoverySubstepCount;
}

fn isCoupledGasRecoveryFailure(err: anyerror) bool {
    return switch (err) {
        error.CoupledGasSolverDiverged,
        error.CoupledGasSolverStagnated,
        error.CoupledGasSolverDidNotConverge,
        => true,
        else => false,
    };
}

fn coarseningProbeCooldownFor(recovery_error: anyerror) u8 {
    return if (isCoupledGasRecoveryFailure(recovery_error))
        gas_coarsening_probe_cooldown_hours
    else
        coarsening_probe_cooldown_hours;
}

fn updateAcceptedRecoveryPreference(
    preferred_substep_count: *u8,
    coarsening_probe_cooldown: *u8,
    accepted_substep_count: u8,
    recovery_error: ?anyerror,
    freeze_flow_coupling_floor_active: bool,
) !void {
    if (recovery_error) |err| {
        preferred_substep_count.* = accepted_substep_count;
        coarsening_probe_cooldown.* = coarseningProbeCooldownFor(err);
    } else if (coarsening_probe_cooldown.* > 0) {
        coarsening_probe_cooldown.* -= 1;
        preferred_substep_count.* = if (coarsening_probe_cooldown.* == 0)
            try nextCoarserRecoverySubstepCount(accepted_substep_count)
        else
            accepted_substep_count;
    } else {
        preferred_substep_count.* = try nextCoarserRecoverySubstepCount(
            accepted_substep_count,
        );
    }
    if (freeze_flow_coupling_floor_active)
        preferred_substep_count.* = @max(
            preferred_substep_count.*,
            ecosys.soil_water_heat_step.minimum_freeze_flow_coupling_substeps,
        );
}

fn logBoundedRecoveryRejection(substep_count: u8, err: anyerror) void {
    if (!builtin.is_test) std.log.warn(
        "bounded fixed external hour recovery rejected: exact_substep_count={d} error={s}",
        .{ substep_count, @errorName(err) },
    );
}

fn recordFreezeFlowRequirement(
    freeze_flow_coupling_floor_active: *bool,
    recovery_error: anyerror,
) void {
    if (recovery_error == error.HeatInducedPhaseChangeRequiresQuarterHourSubsteps)
        freeze_flow_coupling_floor_active.* = true;
}

fn runBoundedRecoveryAttempt(attempt: anytype, substep_count: u8) !?anyerror {
    attempt.run(substep_count) catch |err| {
        if (!isFixedHourRecoveryFailure(err)) return err;
        logBoundedRecoveryRejection(substep_count, err);
        return @as(?anyerror, err);
    };
    return null;
}

fn acceptedAttemptHadSignificantHeatInducedPhaseChange(attempt: anytype) bool {
    if (comptime @hasField(
        @TypeOf(attempt.*),
        "accepted_had_significant_heat_induced_phase_change",
    ))
        return attempt.accepted_had_significant_heat_induced_phase_change;
    return false;
}

/// Production schedule controller. It makes one preferred attempt and then
/// escalates through `boundedRecoveryFallback`'s chain of error-aware
/// fallbacks (the established three-minute schedule, which also exceeds the
/// quarter-hour freeze-flow floor, then the ladder's documented 32-step and
/// 64-step rescues) until an attempt is accepted or the chain is exhausted.
/// The chain is short and strictly increasing (`boundedRecoveryFallback`
/// returns null at the ladder maximum), so this terminates in at most a few
/// attempts; it is not a full refinement-ladder walk. Reaching the 32- and
/// 64-step rescues no longer depends on the initial attempt happening to
/// already be exactly one rung below -- escalating there is measured to
/// actually converge cases a shorter cutoff gave up on (see
/// SOLUTE-HYDROGEN-ROW-RECURRING-NONCONVERGENCE-001; the 32-step ceiling
/// itself reproduced the same defect one rung later at hour 2,604).
/// The accepted schedule is retained briefly as a prior-timestep predictor,
/// then clean hours probe one coarser supported schedule; a physical
/// freeze-flow floor prevents invalid probes. Every rejected attempt remains
/// transactional.
fn recoverFixedExternalHourAdaptively(
    attempt: anytype,
    preferred_substep_count: *u8,
    coarsening_probe_cooldown: *u8,
    freeze_flow_coupling_floor_active: *bool,
    ichkv_proactive_floor_active: bool,
) !void {
    var substep_count = try boundedInitialRecoverySubstepCount(
        preferred_substep_count.*,
        freeze_flow_coupling_floor_active.*,
        ichkv_proactive_floor_active,
    );
    var previous_error: ?anyerror = null;
    while (true) {
        const attempt_error = (try runBoundedRecoveryAttempt(
            attempt,
            substep_count,
        )) orelse {
            freeze_flow_coupling_floor_active.* =
                acceptedAttemptHadSignificantHeatInducedPhaseChange(attempt);
            try updateAcceptedRecoveryPreference(
                preferred_substep_count,
                coarsening_probe_cooldown,
                substep_count,
                previous_error,
                freeze_flow_coupling_floor_active.*,
            );
            if (previous_error != null and !builtin.is_test) std.log.info(
                "bounded fixed external hour recovery accepted: exact_substep_count={d} next_preferred_substep_count={d}",
                .{ substep_count, preferred_substep_count.* },
            );
            return;
        };
        recordFreezeFlowRequirement(freeze_flow_coupling_floor_active, attempt_error);
        var next_substep_count = boundedRecoveryFallback(substep_count) orelse
            return attempt_error;
        if (freeze_flow_coupling_floor_active.*)
            next_substep_count = @max(
                next_substep_count,
                ecosys.soil_water_heat_step.minimum_freeze_flow_coupling_substeps,
            );
        substep_count = next_substep_count;
        previous_error = attempt_error;
    }
}

pub fn solveSoilHeatWaterAndSoluteTransport(
    context: anytype,
    hour_of_day: u8,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar_by_cell: []const ecosys.plant_development.Calendar,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
    gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
    solute_failure_report: ?ecosys.solute_failure_reporter.Request,
    diagnostic_first_hour: anytype,
    diagnostic_mineral_before_mol: anytype,
    diagnostic_relayer_phosphate_before: anytype,
    diagnostic_transport_ammonium_before: anytype,
    diagnostic_transport_before: anytype,
    plant_calendar: anytype,
    post_watsub_biology: PostWatsubBiologyHook,
    ground_air_geometry_balance: []const ecosys.ground_air_exchange.GeometryBalance,
    snow_phase_change_report: anytype,
    snow_vapor_equilibrium_report: anytype,
    diagnostic_previous_heat_megajoules_ptr: anytype,
    diagnostic_previous_n_g_ptr: anytype,
    diagnostic_previous_p_g_ptr: anytype,
    diagnostic_previous_p_owners_ptr: anytype,
) !void {
    const RecoveryAttempt = struct {
        context: @TypeOf(context),
        hour_of_day: u8,
        weather_header_by_cell: @TypeOf(weather_header_by_cell),
        plant_calendar_by_cell: @TypeOf(plant_calendar_by_cell),
        fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
        gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
        solute_failure_report: ?ecosys.solute_failure_reporter.Request,
        diagnostic_first_hour: @TypeOf(diagnostic_first_hour),
        diagnostic_mineral_before_mol: @TypeOf(diagnostic_mineral_before_mol),
        diagnostic_relayer_phosphate_before: @TypeOf(diagnostic_relayer_phosphate_before),
        diagnostic_transport_ammonium_before: @TypeOf(diagnostic_transport_ammonium_before),
        diagnostic_transport_before: @TypeOf(diagnostic_transport_before),
        plant_calendar: @TypeOf(plant_calendar),
        post_watsub_biology: PostWatsubBiologyHook,
        ground_air_geometry_balance: []const ecosys.ground_air_exchange.GeometryBalance,
        snow_phase_change_report: @TypeOf(snow_phase_change_report),
        snow_vapor_equilibrium_report: @TypeOf(snow_vapor_equilibrium_report),
        diagnostic_previous_heat_megajoules_ptr: @TypeOf(diagnostic_previous_heat_megajoules_ptr),
        diagnostic_previous_n_g_ptr: @TypeOf(diagnostic_previous_n_g_ptr),
        diagnostic_previous_p_g_ptr: @TypeOf(diagnostic_previous_p_g_ptr),
        diagnostic_previous_p_owners_ptr: @TypeOf(diagnostic_previous_p_owners_ptr),
        accepted_had_significant_heat_induced_phase_change: bool = false,

        noinline fn run(self: *@This(), exact_substep_count: u8) !void {
            self.accepted_had_significant_heat_induced_phase_change = false;
            const profile_rollback = !builtin.is_test and
                self.context.executed_weather_hours.* >= 48 and
                self.context.executed_weather_hours.* < 56;
            const surface_snow_before = if (profile_rollback)
                self.context.surface_precipitation.solid_snow_water_equivalent_m3[0]
            else
                0;
            const surface_ice_before = if (profile_rollback)
                self.context.surface_litter_ice_m3[0]
            else
                0;
            const surface_liquid_before = if (profile_rollback)
                self.context.surface_precipitation.litter_water_m3[0]
            else
                0;
            const snow_depth_before = if (profile_rollback)
                self.context.snow_depth_m[0]
            else
                0;
            var snow_solid_before: f64 = 0;
            var snow_liquid_before: f64 = 0;
            var snow_ice_before: f64 = 0;
            if (profile_rollback) {
                for (self.context.snow_transport.solid_snow_water_equivalent_m3) |value|
                    snow_solid_before += value;
                for (self.context.snow_transport.liquid_water_volume_m3) |value|
                    snow_liquid_before += value;
                for (self.context.snow_transport.ice_volume_m3) |value|
                    snow_ice_before += value;
            }
            for (self.context.hourly_layer_boundary_ledger.water_storage_update_operation_count_by_scope) |count|
                if (count != 0) return error.DuplicateWaterStorageUpdateArithmeticProvenance;
            const workspace: *FixedHourRecoveryWorkspace =
                @ptrCast(@alignCast(self.context.fixed_hour_recovery_workspace));
            const targets = workspace.targets orelse
                return error.FixedHourRecoveryTargetsNotConfigured;
            const outer_transaction = workspace.outer_transaction orelse
                return error.FixedHourRecoveryOuterTransactionNotBound;
            const carbon_exchange = if (self.context.canopy_carbon_exchange.*) |*value|
                value
            else
                return error.FixedHourRecoveryRequiresCanopyCarbonExchange;
            var transaction = try workspace.transaction.begin(
                self.context.config,
                targets,
            );
            defer transaction.deinit();

            var carbon_exchange_transaction = blk: {
                // A setup failure precedes all science and must leave live
                // allocation identities unchanged rather than promoting an
                // otherwise equivalent checkpoint clone.
                errdefer transaction.commit();
                break :blk try workspace.canopy_carbon_exchange.begin(
                    carbon_exchange,
                    ecosys.canopy_carbon_exchange.State.clone,
                );
            };
            defer carbon_exchange_transaction.deinit();
            var soil_gas_transaction = blk: {
                errdefer {
                    carbon_exchange_transaction.commit();
                    transaction.commit();
                }
                break :blk try workspace.soil_gas_transport.begin(
                    self.context.soil_gas_transport,
                    ecosys.soil_gas_transport_step.State.clone,
                );
            };
            defer soil_gas_transaction.deinit();

            // The enclosing hour has already reflected and validated every
            // stable destination while excluding checkpoint and dedicated
            // reallocating owners. Reuse that concrete layout and snapshot its
            // current bytes, which are this stage attempt's entry state.
            transaction.captureCurrentStableLayoutFrom(outer_transaction) catch |err| {
                // No science has run, so release snapshots without replacing
                // any live owner or invalidating borrowed context aliases.
                soil_gas_transaction.commit();
                carbon_exchange_transaction.commit();
                transaction.commit();
                return err;
            };

            // Capture each rejected solve before transaction rollback. The
            // bounded controller can terminate at 1, 20 or 32 substeps; gating
            // reports on the old 64-step ladder silently lost failures. A
            // fallback atomically replaces the preceding attempt's snapshot.
            const accepted_had_significant_heat_induced_phase_change =
                solveSoilHeatWaterAndSoluteTransportAttempt(
                    self.context,
                    self.hour_of_day,
                    self.weather_header_by_cell,
                    self.plant_calendar_by_cell,
                    self.fertilizer_band_hour,
                    self.gas_failure_report,
                    self.solute_failure_report,
                    self.diagnostic_first_hour,
                    self.diagnostic_mineral_before_mol,
                    self.diagnostic_relayer_phosphate_before,
                    self.diagnostic_transport_ammonium_before,
                    self.diagnostic_transport_before,
                    self.plant_calendar,
                    self.post_watsub_biology,
                    self.ground_air_geometry_balance,
                    self.snow_phase_change_report,
                    self.snow_vapor_equilibrium_report,
                    self.diagnostic_previous_heat_megajoules_ptr,
                    self.diagnostic_previous_n_g_ptr,
                    self.diagnostic_previous_p_g_ptr,
                    self.diagnostic_previous_p_owners_ptr,
                    exact_substep_count,
                ) catch |err| {
                    if (!builtin.is_test and err == error.CoupledGasSolverDidNotConverge)
                        std.log.warn(
                            "TEMP_DIAGNOSTIC coupled-gas fixed-hour attempt failed: exact_substep_count={d} failure_report_bound={}",
                            .{
                                exact_substep_count,
                                self.gas_failure_report != null,
                            },
                        );
                    if (!builtin.is_test and switch (err) {
                        error.SoluteReactionSolverDiverged,
                        error.SoluteReactionSolverStagnated,
                        error.SoluteReactionSolverDidNotConverge,
                        error.SoluteReactionPhysicalBalanceFailure,
                        => true,
                        else => false,
                    }) std.log.warn(
                        "SOLUTE fixed-hour recovery attempt failed: exact_substep_count={d} failure_report_bound={} error={s}",
                        .{
                            exact_substep_count,
                            self.solute_failure_report != null,
                            @errorName(err),
                        },
                    );
                    // Restore extra owners before the checkpoint topology, then
                    // restore the stable journal and persistent owner bundle.
                    // Returning from `run` is therefore proof that a rejected
                    // attempt has left zero scientific/accounting side effects.
                    soil_gas_transaction.rollback();
                    carbon_exchange_transaction.rollback();
                    try transaction.rollback();
                    try workspace.rebindAfterOwnerRollback();
                    if (profile_rollback) {
                        var snow_solid_after: f64 = 0;
                        var snow_liquid_after: f64 = 0;
                        var snow_ice_after: f64 = 0;
                        for (self.context.snow_transport.solid_snow_water_equivalent_m3) |value|
                            snow_solid_after += value;
                        for (self.context.snow_transport.liquid_water_volume_m3) |value|
                            snow_liquid_after += value;
                        for (self.context.snow_transport.ice_volume_m3) |value|
                            snow_ice_after += value;
                        std.log.warn(
                            "TEMP_ROLLBACK surface_snow_before={e} after={e} surface_ice_before={e} after={e} surface_liquid_before={e} after={e} snow_depth_before={e} after={e} snow_solid_before={e} after={e} snow_liquid_before={e} after={e} snow_ice_before={e} after={e}",
                            .{
                                surface_snow_before,
                                self.context.surface_precipitation.solid_snow_water_equivalent_m3[0],
                                surface_ice_before,
                                self.context.surface_litter_ice_m3[0],
                                surface_liquid_before,
                                self.context.surface_precipitation.litter_water_m3[0],
                                snow_depth_before,
                                self.context.snow_depth_m[0],
                                snow_solid_before,
                                snow_solid_after,
                                snow_liquid_before,
                                snow_liquid_after,
                                snow_ice_before,
                                snow_ice_after,
                            },
                        );
                    }
                    return err;
                };

            soil_gas_transaction.commit();
            carbon_exchange_transaction.commit();
            transaction.commit();
            self.accepted_had_significant_heat_induced_phase_change =
                accepted_had_significant_heat_induced_phase_change;
        }
    };
    var recovery_attempt: RecoveryAttempt = .{
        .context = context,
        .hour_of_day = hour_of_day,
        .weather_header_by_cell = weather_header_by_cell,
        .plant_calendar_by_cell = plant_calendar_by_cell,
        .fertilizer_band_hour = fertilizer_band_hour,
        .gas_failure_report = gas_failure_report,
        .solute_failure_report = solute_failure_report,
        .diagnostic_first_hour = diagnostic_first_hour,
        .diagnostic_mineral_before_mol = diagnostic_mineral_before_mol,
        .diagnostic_relayer_phosphate_before = diagnostic_relayer_phosphate_before,
        .diagnostic_transport_ammonium_before = diagnostic_transport_ammonium_before,
        .diagnostic_transport_before = diagnostic_transport_before,
        .plant_calendar = plant_calendar,
        .post_watsub_biology = post_watsub_biology,
        .ground_air_geometry_balance = ground_air_geometry_balance,
        .snow_phase_change_report = snow_phase_change_report,
        .snow_vapor_equilibrium_report = snow_vapor_equilibrium_report,
        .diagnostic_previous_heat_megajoules_ptr = diagnostic_previous_heat_megajoules_ptr,
        .diagnostic_previous_n_g_ptr = diagnostic_previous_n_g_ptr,
        .diagnostic_previous_p_g_ptr = diagnostic_previous_p_g_ptr,
        .diagnostic_previous_p_owners_ptr = diagnostic_previous_p_owners_ptr,
    };
    const fixed_hour_workspace: *FixedHourRecoveryWorkspace =
        @ptrCast(@alignCast(context.fixed_hour_recovery_workspace));
    const adaptive_schedule = &fixed_hour_workspace.adaptive_hour_schedule;
    // issue-024/issue-068/issue-077 (`wthr.f:568-571`'s `ICHKV`): evaluated
    // against the hour's TRUE starting state -- `context.grid`'s water/ice
    // volumes are always current (never mid-hour-stale), and
    // `context.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k`/
    // `context.soil_solver_properties.layer_volume_m3` are the slow-changing
    // (erosion/relayering-only) material/geometry properties
    // `runtime_material_refresh.refreshAcceptedHour` already keeps current
    // as of the end of the previous accepted hour, not values this
    // function's own per-attempt `soil_hourly_workspace.refresh` happens to
    // have cached from a still-earlier attempt. This is a pure query with
    // no side effect; it only decides the FIRST attempt's starting point.
    const ichkv_proactive_floor_active = try ecosys.soil_water_heat_step.ichkvTopLayerHeatCapacityBelowThreshold(
        context.grid,
        context.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k,
        context.soil_solver_properties.layer_volume_m3,
        context.runscript.soil_phase_heat_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
        context.runscript.soil_phase_heat_parameters.ice_heat_capacity_megajoules_per_m3_k,
        context.soil_hourly_workspace.plan_area_m2,
        context.soil_hourly_workspace.is_top_soil_layer,
    );
    try recoverFixedExternalHourAdaptively(
        &recovery_attempt,
        &adaptive_schedule.preferred_substep_count,
        &adaptive_schedule.coarsening_probe_cooldown_hours,
        &adaptive_schedule.freeze_flow_coupling_floor_active,
        ichkv_proactive_floor_active,
    );
}

noinline fn publishPhaseAndBoundaryHeat(
    context: anytype,
    accepted_soil_water_heat: anytype,
) !void {
    // WATSUB's local phase endpoint evolves the legacy `C*T` coordinate,
    // while every production heat census uses the continuous frozen-water
    // enthalpy branch. The solver publishes their exact source-derived
    // difference per accepted layer and substep. Treat it as an internal
    // reference-state transformation at every conservation scope; it is not a
    // boundary flux and it is not another application of phase latent heat.
    // issue-068 (fourth round, 2026-09-20): `temperatureForCellEnthalpy`
    // (`heat_step.zig`) books the same kind of internal reference-state
    // energy discrepancy into a dedicated
    // `renormalization_floor_discard_megajoules_by_layer` ledger whenever it
    // holds a chronically near-zero-heat-capacity layer's prior temperature
    // instead of dividing. It is netted into
    // `validatePerLayerSpatialHeatClosure`'s per-layer check already; fold it
    // into this SAME "signed internal heat" publication too so the
    // withheld/discarded energy is accounted for at the cell, landscape, and
    // per-layer conservation scopes as well, instead of silently vanishing
    // from the whole-model census.
    const soil_phase_reference_and_floor_discard_heat_by_layer = try context.allocator.alloc(
        f64,
        accepted_soil_water_heat.phase_endpoint_reference_heat_megajoules_by_layer.len,
    );
    defer context.allocator.free(soil_phase_reference_and_floor_discard_heat_by_layer);
    for (
        soil_phase_reference_and_floor_discard_heat_by_layer,
        accepted_soil_water_heat.phase_endpoint_reference_heat_megajoules_by_layer,
        accepted_soil_water_heat.renormalization_floor_discard_megajoules_by_layer,
    ) |*combined, phase_endpoint_heat_megajoules, floor_discard_megajoules| {
        if (!std.math.isFinite(floor_discard_megajoules))
            return error.NonFiniteSoilRenormalizationFloorDiscard;
        combined.* = try checkedAddFiniteValue(phase_endpoint_heat_megajoules, floor_discard_megajoules);
    }
    const soil_phase_reference_heat_by_cell = try context.allocator.alloc(
        f64,
        context.grid.cell_count,
    );
    defer context.allocator.free(soil_phase_reference_heat_by_cell);
    @memset(soil_phase_reference_heat_by_cell, 0);
    var soil_phase_reference_heat_total: f64 = 0;
    for (
        soil_phase_reference_and_floor_discard_heat_by_layer,
        0..,
    ) |heat_megajoules, layer| {
        if (!std.math.isFinite(heat_megajoules))
            return error.NonFiniteSoilPhaseReferenceHeat;
        const cell = layer / context.grid.soil_layer_capacity;
        soil_phase_reference_heat_by_cell[cell] = try checkedAddFiniteValue(
            soil_phase_reference_heat_by_cell[cell],
            heat_megajoules,
        );
        soil_phase_reference_heat_total = try checkedAddFiniteValue(
            soil_phase_reference_heat_total,
            heat_megajoules,
        );
    }
    try context.landscape_boundary_ledger.accumulateAcceptedSignedInternalHeat(
        soil_phase_reference_heat_total,
    );
    try context.hourly_cell_boundary_ledger.accumulateSignedInternalHeat(
        soil_phase_reference_heat_by_cell,
    );
    try ecosys.layer_local_conservation.accumulateSoilLayerSignedInternalHeat(
        context.hourly_layer_boundary_ledger,
        context.grid.active_soil_layer_count,
        soil_phase_reference_and_floor_discard_heat_by_layer,
    );
    try context.landscape_boundary_ledger.accumulateAccepted(.{
        .heat_input_megajoules = accepted_soil_water_heat.solver.heat.boundary_heat_input_megajoules,
        .heat_output_megajoules = accepted_soil_water_heat.solver.heat.boundary_heat_output_megajoules,
    });
    try context.hourly_cell_boundary_ledger.accumulateHeat(
        accepted_soil_water_heat.boundary_heat_input_megajoules_by_cell,
        accepted_soil_water_heat.boundary_heat_output_megajoules_by_cell,
    );
    // Convective enthalpy carried by water crossing the soil's external
    // (lateral/drainage) boundary, valued INSIDE the transaction at the
    // temperature resident when the water actually left. Booking it here,
    // from the solver's own published diagnostic, keeps it commensurable with
    // the interior enthalpy census. Recomputing it later from
    // `state.soil_temperature_k` values the departure at the end-of-hour
    // temperature instead and leaves a `C_l * Q_ext * dT_hour` residual.
    if (accepted_soil_water_heat.solver.energy) |energy|
        try context.landscape_boundary_ledger.accumulateAcceptedSignedHeat(
            -energy.external_water_advective_enthalpy_outward_megajoules,
        );
    for (accepted_soil_water_heat.external_water_advective_enthalpy_outward_megajoules_by_cell, 0..) |outward, cell|
        try context.hourly_cell_boundary_ledger.accumulate(cell, if (outward >= 0)
            .{ .heat_output_megajoules = outward }
        else
            .{ .heat_input_megajoules = -outward });
}

noinline fn publishHourlyCellTransportLedgers(
    context: anytype,
    coupled_substeps: anytype,
) !void {
    try ecosys.hourly_cell_conservation.accumulateSoilFaceTransfers(
        context.hourly_cell_boundary_ledger,
        context.soil_transport_faces,
        context.grid.soil_layer_capacity,
    );
    try ecosys.hourly_cell_conservation.accumulateAqueousFaceTransfers(
        context.hourly_cell_boundary_ledger,
        context.soil_transport_faces,
        context.micropore_solute_face_flux_mol,
        context.macropore_solute_face_flux_mol,
        context.grid.soil_layer_capacity,
        12,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
    );
    try ecosys.hourly_cell_conservation.accumulateAqueousExternalBoundaries(
        context.hourly_cell_boundary_ledger,
        context.soil_solute_boundary_net_flux_mol,
        context.soil_transport_faces.active_by_layer,
        context.grid.soil_layer_capacity,
        12,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
    );
    try ecosys.hourly_cell_conservation.accumulateGasFaceTransfers(
        context.hourly_cell_boundary_ledger,
        context.soil_gas_transport,
        context.grid.soil_layer_capacity,
    );
    // Publish the three dedicated aqueous transports as one ledger
    // transaction. Every producer output is already an accepted substep sum;
    // this private clone prevents a late malformed producer from retaining
    // earlier category bookings.
    const dedicated_candidate_values = try context.allocator.dupe(
        ecosys.hourly_cell_conservation.BoundaryActivity,
        context.hourly_cell_boundary_ledger.cells,
    );
    defer context.allocator.free(dedicated_candidate_values);
    var dedicated_candidate: ecosys.hourly_cell_conservation.BoundaryLedger = .{
        .allocator = context.allocator,
        .cells = dedicated_candidate_values,
    };
    try ecosys.hourly_cell_conservation.accumulateOrganicTransport(
        &dedicated_candidate,
        context.soil_transport_faces,
        coupled_substeps.organic_boundary_total_g,
        coupled_substeps.organic_micropore_face_total_g,
        coupled_substeps.organic_macropore_face_total_g,
        context.grid.soil_layer_capacity,
    );
    try ecosys.hourly_cell_conservation.accumulateMineralNitrogenTransport(
        &dedicated_candidate,
        context.soil_transport_faces,
        coupled_substeps.mineral_boundary_total_g_n,
        coupled_substeps.mineral_micropore_face_total_mol,
        coupled_substeps.mineral_macropore_face_total_mol,
        context.grid.soil_layer_capacity,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
    );
    try ecosys.hourly_cell_conservation.accumulateDissolvedGasTransport(
        &dedicated_candidate,
        context.soil_transport_faces,
        coupled_substeps.dissolved_gas_boundary_total_g,
        coupled_substeps.dissolved_gas_micropore_face_total_g,
        coupled_substeps.dissolved_gas_macropore_face_total_g,
        context.grid.soil_layer_capacity,
    );
    try context.landscape_boundary_ledger.accumulateAcceptedDissolvedGasExternalBoundaries(
        context.soil_transport_faces.active_by_layer,
        coupled_substeps.dissolved_gas_boundary_total_g,
    );
    @memcpy(context.hourly_cell_boundary_ledger.cells, dedicated_candidate.cells);
}

noinline fn publishHourlyLayerSurfaceHeatAndWater(
    layer_candidate: *ecosys.layer_local_conservation.Ledger,
    context: anytype,
    coupled_substeps: anytype,
) !void {
    try ecosys.layer_local_conservation.accumulateSurfaceTopsoilHeatTransfer(
        layer_candidate,
        context.grid.active_soil_layer_count,
        coupled_substeps.surface_conduction_total_megajoules,
    );
    try ecosys.layer_local_conservation.accumulateSoilWaterHeatFaces(
        layer_candidate,
        context.soil_transport_faces,
    );
}

noinline fn publishHourlyLayerAqueousGasAndBubble(
    layer_candidate: *ecosys.layer_local_conservation.Ledger,
    context: anytype,
    coupled_substeps: anytype,
) !void {
    try ecosys.layer_local_conservation.accumulateAqueousFaces(
        layer_candidate,
        context.soil_transport_faces,
        context.micropore_solute_face_flux_mol,
        context.macropore_solute_face_flux_mol,
        12,
        context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
    );
    try ecosys.layer_local_conservation.accumulateGasFaces(
        layer_candidate,
        context.soil_gas_transport,
    );
    try ecosys.layer_local_conservation.accumulateSoilGasBubbleActivity(
        layer_candidate,
        context.grid.active_soil_layer_count,
        coupled_substeps.gas_bubble_input_total,
        coupled_substeps.gas_bubble_output_total,
    );
}

noinline fn publishHourlyLayerOrganicMineralAndDissolvedGas(
    layer_candidate: *ecosys.layer_local_conservation.Ledger,
    context: anytype,
    coupled_substeps: anytype,
) !void {
    try ecosys.layer_local_conservation.accumulateOrganicFaces(
        layer_candidate,
        context.soil_transport_faces,
        coupled_substeps.organic_micropore_face_total_g,
        coupled_substeps.organic_macropore_face_total_g,
    );
    try ecosys.layer_local_conservation.accumulateMineralNitrogenFaces(
        layer_candidate,
        context.soil_transport_faces,
        coupled_substeps.mineral_micropore_face_total_mol,
        coupled_substeps.mineral_macropore_face_total_mol,
        context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
    );
    try ecosys.layer_local_conservation.accumulateDissolvedGasFaces(
        layer_candidate,
        context.soil_transport_faces,
        coupled_substeps.dissolved_gas_micropore_face_total_g,
        coupled_substeps.dissolved_gas_macropore_face_total_g,
    );
}

noinline fn publishHourlyLayerExternalAdvectiveHeat(
    layer_candidate: *ecosys.layer_local_conservation.Ledger,
    context: anytype,
    accepted_soil_water_heat: anytype,
) !void {
    // Richards carrier heat is a distinct gross boundary stream valued at the
    // accepted source-layer temperature. Publish it separately so an opposing
    // conductive/geothermal boundary flux cannot disappear through netting.
    try ecosys.layer_local_conservation.accumulateSoilExternalAdvectiveHeat(
        layer_candidate,
        context.soil_transport_faces.active_by_layer,
        accepted_soil_water_heat.external_water_advective_enthalpy_outward_megajoules_by_layer,
    );
}

noinline fn publishHourlyLayerExternalBoundaries(
    layer_candidate: *ecosys.layer_local_conservation.Ledger,
    context: anytype,
    coupled_substeps: anytype,
) !void {
    try ecosys.layer_local_conservation.accumulateSoilExternalBoundaries(
        layer_candidate,
        .{
            .active_by_layer = context.soil_transport_faces.active_by_layer,
            .boundary_water_gain_m3 = context.transport_hydrology.boundary_water_exchange_m3_per_layer_per_step,
            .boundary_heat_gain_megajoules = context.transport_hydrology.boundary_heat_exchange_megajoules_per_layer_per_step,
            .aqueous_boundary_net_input_mol = context.soil_solute_boundary_net_flux_mol,
            .organic_boundary_net_input_g = coupled_substeps.organic_boundary_total_g,
            .mineral_nitrogen_boundary_export_g = coupled_substeps.mineral_boundary_total_g_n,
            .dissolved_gas_boundary_net_input_g = coupled_substeps.dissolved_gas_boundary_total_g,
            .carbon_g_per_mol = 12,
            .phosphorus_g_per_mol = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol,
        },
    );
}

noinline fn publishHourlyLayerTransportLedgers(
    context: anytype,
    coupled_substeps: anytype,
    accepted_soil_water_heat: anytype,
) !void {
    // Publish every accepted soil face into the independent `(cell, layer)`
    // ledger as one transaction. Each species is direction-separated before
    // element reduction, so opposing within-column fluxes cannot disappear.
    const layer_candidate_values = try context.allocator.dupe(
        ecosys.hourly_cell_conservation.BoundaryActivity,
        context.hourly_layer_boundary_ledger.activity,
    );
    defer context.allocator.free(layer_candidate_values);
    var layer_candidate: ecosys.layer_local_conservation.Ledger = .{
        .allocator = context.allocator,
        .layout = context.hourly_layer_boundary_ledger.layout,
        .activity = layer_candidate_values,
    };
    try publishHourlyLayerSurfaceHeatAndWater(
        &layer_candidate,
        context,
        coupled_substeps,
    );
    try publishHourlyLayerAqueousGasAndBubble(
        &layer_candidate,
        context,
        coupled_substeps,
    );
    try publishHourlyLayerOrganicMineralAndDissolvedGas(
        &layer_candidate,
        context,
        coupled_substeps,
    );
    try publishHourlyLayerExternalAdvectiveHeat(
        &layer_candidate,
        context,
        accepted_soil_water_heat,
    );
    try publishHourlyLayerExternalBoundaries(
        &layer_candidate,
        context,
        coupled_substeps,
    );
    // ISSUE-065 (seventeenth pass): direct trace of the LEDGER side of the
    // sixteenth addendum's handoff question -- does the cumulative
    // `hourly_layer_boundary_ledger` entry this transaction is about to
    // commit for cell 0/layer 0 match the layer's own authoritative
    // mineral-N storage read (`aggregateProfileMineralNitrogenLayer`, the
    // same aggregator the census gate itself uses) at the same instant?
    // Logged once per hour, immediately before the candidate is committed,
    // so a rerun can compare this cumulative booked total directly against
    // the per-call `mineral_nitrogen_advance_call` trace's own totals.
    if (!builtin.is_test and
        context.executed_weather_hours.* >= 2888 and context.executed_weather_hours.* < 2896)
    {
        const layer0_index = try context.hourly_layer_boundary_ledger.layout.index(.{ .kind = .soil_layer, .cell = 0, .layer = 0 });
        const booked = layer_candidate.activity[layer0_index];
        try ecosys.landscape_mass_balance_runtime.deriveSoilMass(
            context.soil_solver_properties.matrix_bulk_volume_m3,
            context.soil_solver_properties.bulk_density_megagrams_per_m3,
            context.landscape_soil_mass_megagrams_scratch,
        );
        const storage = try ecosys.landscape_mass_inventory.aggregateProfileMineralNitrogenLayer(
            context.grid,
            context.mineral_nitrogen_transport,
            context.soil_chemistry,
            context.soil_fertilizer_inventory,
            context.landscape_soil_mass_megagrams_scratch,
            context.fertilizer_band,
            context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol,
            0,
            0,
        );
        std.log.info(
            "DRY_CARRIER_TRACE site=mineral_nitrogen_layer_ledger_commit hour={d} cell=0 layer=0 booked_nitrogen_input_g={e} booked_nitrogen_output_g={e} booked_net_g={e} storage_ammonium_nitrogen_g={e} storage_nitrate_nitrogen_g={e} storage_mineral_nitrogen_total_g={e}",
            .{
                context.executed_weather_hours.* + 1,
                booked.nitrogen_input_g,
                booked.nitrogen_output_g,
                booked.nitrogen_input_g - booked.nitrogen_output_g,
                storage.ammonium_nitrogen_g,
                storage.nitrate_nitrogen_g,
                storage.ammonium_nitrogen_g + storage.nitrate_nitrogen_g,
            },
        );
    }
    @memcpy(context.hourly_layer_boundary_ledger.activity, layer_candidate.activity);
}

noinline fn solveSoilHeatWaterAndSoluteTransportAttempt(
    context: anytype,
    hour_of_day: u8,
    weather_header_by_cell: []const ecosys.weather.Header,
    plant_calendar_by_cell: []const ecosys.plant_development.Calendar,
    fertilizer_band_hour: ecosys.fertilizer_band_phase_coordinator.HourToken,
    gas_failure_report: ?ecosys.soil_gas_transport_step.FailureReportRequest,
    solute_failure_report: ?ecosys.solute_failure_reporter.Request,
    diagnostic_first_hour: anytype,
    diagnostic_mineral_before_mol: anytype,
    diagnostic_relayer_phosphate_before: anytype,
    diagnostic_transport_ammonium_before: anytype,
    diagnostic_transport_before: anytype,
    plant_calendar: anytype,
    post_watsub_biology: PostWatsubBiologyHook,
    ground_air_geometry_balance: []const ecosys.ground_air_exchange.GeometryBalance,
    snow_phase_change_report: anytype,
    snow_vapor_equilibrium_report: anytype,
    diagnostic_previous_heat_megajoules_ptr: anytype,
    diagnostic_previous_n_g_ptr: anytype,
    diagnostic_previous_p_g_ptr: anytype,
    diagnostic_previous_p_owners_ptr: anytype,
    exact_substep_count: u8,
) !bool {
    var stage_succeeded = false;
    // Temporary diagnosis of the first post-tillage top-layer heat failure.
    // This changes logging only; the accepted substep schedule and all
    // scientific tolerances remain untouched. Include the two accepted
    // predecessor hours so a new state transition can be distinguished from
    // a pre-existing defect. Remove the frontier window before release freeze.
    const thermal_frontier_trace = context.executed_weather_hours.* >= 2531 and
        context.executed_weather_hours.* < 2534;
    const thermal_trace_active = !builtin.is_test and run_support.verbose_diagnostics_enabled and
        (context.executed_weather_hours.* < 8 or thermal_frontier_trace);
    if (!builtin.is_test and run_support.verbose_diagnostics_enabled and thermal_frontier_trace)
        std.log.info("THERMAL_FRONTIER hour={d} exact_substep_count={d}", .{
            context.executed_weather_hours.* + 1,
            exact_substep_count,
        });
    const temporary_profile_active = !builtin.is_test and
        context.executed_weather_hours.* >= 48 and
        context.executed_weather_hours.* < 56;
    const temporary_profile_start = std.Io.Clock.now(.boot, context.io);
    var diagnostic_previous_heat_megajoules = diagnostic_previous_heat_megajoules_ptr.*;
    defer {
        if (stage_succeeded) diagnostic_previous_heat_megajoules_ptr.* = diagnostic_previous_heat_megajoules;
    }
    var diagnostic_previous_n_g = diagnostic_previous_n_g_ptr.*;
    defer {
        if (stage_succeeded) diagnostic_previous_n_g_ptr.* = diagnostic_previous_n_g;
    }
    var diagnostic_previous_p_g = diagnostic_previous_p_g_ptr.*;
    defer {
        if (stage_succeeded) diagnostic_previous_p_g_ptr.* = diagnostic_previous_p_g;
    }
    var diagnostic_previous_p_owners = diagnostic_previous_p_owners_ptr.*;
    defer {
        if (stage_succeeded) diagnostic_previous_p_owners_ptr.* = diagnostic_previous_p_owners;
    }
    // Atmosphere and aerodynamic resistance are immutable hourly forcing.
    // Ground-air storage and all state-dependent canopy/dead/surface exchange
    // are recomputed by CoupledSubstepTransaction after each snow injection.
    for (0..context.grid.cell_count) |cell| {
        context.atmospheric_vapor_fraction[cell] = try ecosys.ground_air_exchange.vaporVolumeFraction(context.atmosphere.vapor_pressure_kpa[cell], context.atmosphere.air_temperature_k[cell], context.runscript.ground_air_parameters);
        context.ground_air_canopy_resistance_h_per_m[cell] = if (context.canopy_airflow.*) |*airflow| airflow.neutral_resistance_below_biome_h_per_m[cell] else 0;
    }
    try group_gas_surface_water.refreshSoilSurfaceGasConductances(context);
    try tile_kernels.runKernelAcrossSerialTiles(context, context.soil_thermal_context, ecosys.soil_thermal.updateTile);
    // PSISO/CION uses the live layer-specific band geometry. Preserve a
    // stable snapshot for every internal recovery substep in this solve.
    const soil_osmotic_zone_fractions = try context.allocator.alloc(
        ecosys.solute_charge_classification.ZoneFractions,
        context.grid.layer_count,
    );
    defer context.allocator.free(soil_osmotic_zone_fractions);
    for (soil_osmotic_zone_fractions, 0..) |*fractions, layer|
        fractions.* = try context.fertilizer_band.scienceZoneFractionsForFlatIndex(layer);
    try context.soil_hourly_workspace.refresh(context.grid, context.soil_solver_properties, context.soil_thermal, context.terrain_hydrology, context.runscript.soil_process_parameters, context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3, context.soil_chemistry, soil_osmotic_zone_fractions);
    var fertilizer_band_workspace = try ecosys.fertilizer_band_production.Workspace.init(context.allocator, context.grid.soil_layer_capacity);
    defer fertilizer_band_workspace.deinit();
    // Surface conduction is recomputed and bound from the current accepted
    // surface state in every internal retry step. Start the hourly source-rate
    // owner empty, then add the other immutable hourly heat sources below.
    @memset(context.soil_hourly_workspace.cell_heat_source_megajoules, 0);
    @memset(context.soil_hourly_workspace.published_surface_conduction_heat_megajoules, 0);
    // Direct precipitation heat depends on the current recipient temperature;
    // CoupledHooks.prepareSubstep binds its remainder afresh, not into this
    // immutable hourly base. Snow donor heat retains its separate owner.
    _ = try ecosys.subsurface_irrigation_heat.addToLayerHeatSources(
        context.soil_hourly_workspace.cell_heat_source_megajoules,
        context.subsurface_irrigation_water_m3,
        context.atmosphere.air_temperature_k,
        context.grid.soil_layer_capacity,
        context.runscript.canopy_surface_exchange_parameters.liquid_water_heat_capacity_megajoules_per_m3_k,
    );
    const diagnostic_irrigation_source_megajoules = context.soil_hourly_workspace.cell_heat_source_megajoules[0];
    try foldDelayedHeatSource(context.delayed_subsurface_combustion_heat_megajoules, context.soil_hourly_workspace.cell_heat_source_megajoules);
    const diagnostic_after_combustion_megajoules = context.soil_hourly_workspace.cell_heat_source_megajoules[0];
    try foldDelayedHeatSource(context.delayed_root_uptake_heat_megajoules, context.soil_hourly_workspace.cell_heat_source_megajoules);
    // `DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001`. The per-layer heat census
    // rejects hour 2,705 with `source_mj = -1.5816727759048629e1` on the top
    // layer, and a magnitude-gated probe on the surface conductive flux itself
    // never fired -- so the demand is not surface conduction, and this immutable
    // hourly base is assembled from three other contributors. Attribute it here
    // rather than inferring: `cell_heat_source_megajoules[top]` has several
    // writers (`:5565`, `:5595`, `:6385`, `boundary.zig:212`) and guessing which
    // one dominates has already cost two wrong answers in this investigation.
    //
    // Gated on a magnitude no physical hourly source reaches for one 1 m2 cell,
    // so an ordinary hour logs nothing.
    // Lowered from 5 MJ to 0.05 MJ after the 5 MJ version reported zero hits:
    // this base is an hourly quantity, but the layer's own heat capacity is only
    // ~5e-5 MJ/K, so anything above ~0.05 MJ is already hundreds of kelvin for
    // this layer and worth seeing. The point is to bound the base's contribution
    // to the census's -1.5816727759048629e1 MJ, not to catch only absurd values.
    if (!builtin.is_test and
        @abs(context.soil_hourly_workspace.cell_heat_source_megajoules[0]) > 0.05) std.log.err(
        "implausible hourly base heat source: hour={d} top_layer_total_megajoules={e} irrigation_megajoules={e} delayed_subsurface_combustion_megajoules={e} delayed_root_uptake_megajoules={e} plan_area_m2={e} heat_capacity_megajoules_per_k={e}",
        .{
            context.executed_weather_hours.* + 1,
            context.soil_hourly_workspace.cell_heat_source_megajoules[0],
            diagnostic_irrigation_source_megajoules,
            diagnostic_after_combustion_megajoules - diagnostic_irrigation_source_megajoules,
            context.soil_hourly_workspace.cell_heat_source_megajoules[0] - diagnostic_after_combustion_megajoules,
            context.soil_hourly_workspace.plan_area_m2[0],
            context.soil_hourly_workspace.heat_capacity_megajoules_per_k[0],
        },
    );
    const water_heat_solute_max_iterations = try ecosys.iteration_control.waterHeatSoluteCeilingForCurrentState(context.iteration_limits.water_heat_solute_max_iterations, context.config.max_nonlinear_iterations, context.soil_hourly_workspace.heat_capacity_megajoules_per_k, context.soil_hourly_workspace.plan_area_m2, context.soil_hourly_workspace.is_top_soil_layer);
    const CoupledHooks = CoupledSubstepTransaction(
        @TypeOf(context),
        @TypeOf(context.soil_chemistry.*),
        @TypeOf(context.surface_litter_chemistry.*),
    );
    var coupled_substeps = try CoupledHooks.init(
        context,
        water_heat_solute_max_iterations,
        exact_substep_count,
        ground_air_geometry_balance,
        gas_failure_report,
    );
    defer coupled_substeps.deinit();
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE attempt setup elapsed_ms={d} substeps={d}",
        .{ temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(), exact_substep_count },
    );
    const accepted_phase_displacement = try context.allocator.alloc(
        ecosys.soil_water_heat_step.PhaseDisplacement,
        context.grid.layer_count,
    );
    defer context.allocator.free(accepted_phase_displacement);
    @memset(accepted_phase_displacement, .{});
    var temporary_profile_watsub_counters: ecosys.soil_water_heat_step.TemporaryProfileCounters = .{};
    if (context.diagnostic_watsub_heat_trace_megajoules.len != 39)
        return error.HourlyFailureTraceDimensionMismatch;
    // This buffer is failure diagnostics, not scientific state. Refresh it for
    // every candidate hour so a later conservation failure cannot print the
    // first accepted hour's stale trace. Schedule rollback remains unchanged.
    @memset(context.diagnostic_watsub_heat_trace_megajoules, 0);
    const pre_solve_trace_totals = try diagnostics.reconstructLandscapeMassBalance(context);
    context.diagnostic_watsub_heat_trace_megajoules[0] = pre_solve_trace_totals.heat_storage_megajoules;
    context.diagnostic_watsub_heat_trace_megajoules[1] =
        pre_solve_trace_totals.heat_storage_megajoules - pre_solve_trace_totals.cumulative_heat_input_megajoules +
        pre_solve_trace_totals.cumulative_heat_output_megajoules -
        pre_solve_trace_totals.cumulative_internal_heat_production_megajoules +
        pre_solve_trace_totals.cumulative_internal_heat_consumption_megajoules;
    // TEMP_DIAGNOSTIC (issue-067): trace the vapor solver's own accepted
    // per-cell residual for cell 0/layer 0 across the hour-2895 near-total
    // water-fraction closure frontier. Logging only; no tolerance or
    // scientific behavior changes. Deliberately NOT gated behind
    // `run_support.verbose_diagnostics_enabled`: that flag also re-enables a
    // large volume of unrelated high-frequency debug logging elsewhere in
    // this stage (see its doc comment and
    // `audit/runs/run-004-logging-overhead-fix-and-remeasurement-2026-09-18.md`),
    // which made a plain hour-window trace prohibitively slow to reach this
    // frontier. The three-hour window here is already narrow enough to be
    // safe unconditionally. Remove this window once issue-067 is resolved.
    const vapor_frontier_trace = !builtin.is_test and
        context.executed_weather_hours.* >= 2893 and context.executed_weather_hours.* < 2896;
    const vapor_diagnostic_layer_index: ?usize = if (vapor_frontier_trace)
        (context.grid.layerIndex(0, 0) catch null)
    else
        null;
    // TEMP_DIAGNOSTIC (issue-078): trace the WATSUB vertical-displacement
    // mechanical prepass's own relief of cell 0/layer 0's hour-entry pore
    // overfill across the hour-3253 `RuntimeSoilPoreCapacityExceeded`
    // frontier (`audit/issues/issue-078-...md`). Same narrow-hour-window,
    // logging-only, no-tolerance-change discipline as the issue-067 vapor
    // trace immediately above; a distinct window/index variable so this
    // issue's trace can be removed independently once resolved.
    const issue078_frontier_trace = !builtin.is_test and
        context.executed_weather_hours.* >= 3247 and context.executed_weather_hours.* < 3254;
    const water_diagnostic_layer_index: ?usize = if (issue078_frontier_trace)
        (context.grid.layerIndex(0, 0) catch null)
    else
        null;
    const temporary_profile_watsub_start = std.Io.Clock.now(.boot, context.io);
    var accepted_soil_water_heat = try ecosys.soil_water_heat_step.advanceMappedDeferred(context.allocator, context.grid, context.transport_hydrology, context.soil_transport_faces, context.soil_face_geometry, context.soil_solver_properties, context.soil_hourly_workspace, context.soil_thermal, context.soil_heat_solver_workspace, context.runscript.soil_phase_heat_parameters, .{ .heat_failure_report_io = context.io, .max_iterations = water_heat_solute_max_iterations, .picard_relaxation = context.config.picard_relaxation, .vapor_pore_tortuosity = context.runscript.soil_process_parameters.vapor_pore_tortuosity, .osmotic_reflection_coefficient = context.runscript.soil_process_parameters.osmotic_reflection_coefficient, .water_absolute_tolerance_m3 = context.config.nonlinear_tolerance.water_volume_m3, .temperature_absolute_tolerance_k = context.config.nonlinear_tolerance.temperature_k, .enthalpy_absolute_tolerance_megajoules = context.config.nonlinear_tolerance.heat_megajoules, .nonlinear_relative_tolerance = context.config.nonlinear_tolerance.relative, .water_conservation_absolute_tolerance_m = context.config.mass_balance_absolute_tolerance.water_m, .water_conservation_relative_tolerance = context.config.mass_balance_relative_tolerance, .heat_conservation_absolute_tolerance_megajoules_per_m2 = context.config.mass_balance_absolute_tolerance.heat_megajoules_m2, .heat_conservation_relative_tolerance = context.config.mass_balance_relative_tolerance / heat_layer_conservation_tolerance_divisor, .boundary_topology = context.soil_boundary_topology, .geothermal_enabled_by_cell = context.geothermal_enabled_by_cell, .mean_annual_temperature_k_by_cell = context.mean_annual_temperature_k_by_cell, .geothermal_minimum_source_depth_m = context.runscript.geothermal_controls.minimum_source_depth_m, .geothermal_source_depth_below_profile_m = context.runscript.geothermal_controls.source_depth_below_profile_m, .geothermal_conductivity_m_megajoules_per_h_k = context.runscript.geothermal_controls.conductivity_m_megajoules_per_h_k, .geothermal_flux_megajoules_per_m2_h = context.runscript.geothermal_controls.geothermal_flux_megajoules_per_m2_h, .water_table_air_fraction_threshold = context.runscript.water_table_air_fraction_threshold, .active_layer_ice_fraction_threshold = context.runscript.active_layer_ice_fraction_threshold, .dense_newton_max_components = production_dense_newton_max_components, .matrix_external_water_source_m3_per_step = context.subsurface_irrigation_water_m3, .surface_litter_liquid_water_m3 = context.surface_precipitation.litter_water_m3, .surface_litter_water_retention_capacity_m3 = context.surface_precipitation.litter_water_capacity_m3, .cell_area_m2 = context.canopy_cell_area_m2, .phase_displacement_by_layer = accepted_phase_displacement, .substep_refresh = .{ .terrain = context.terrain_hydrology, .chemistry = context.soil_chemistry, .runtime_parameters = context.runscript.soil_process_parameters, .zone_fractions_by_layer = soil_osmotic_zone_fractions }, .substep_transaction_hooks = .{ .context = @ptrCast(&coupled_substeps), .restore_schedule = CoupledHooks.restoreSchedule, .rollback_failure = CoupledHooks.rollbackFailure, .prepare_substep = CoupledHooks.prepareSubstep, .post_phase_pre_heat = CoupledHooks.postPhasePreHeat, .accept_substep = CoupledHooks.acceptSubstep, .accept_phase_displacement = CoupledHooks.acceptPhaseDisplacement }, .exact_substep_count = exact_substep_count, .temporary_profile = if (temporary_profile_active or thermal_trace_active) .{ .io = context.io, .counters = &temporary_profile_watsub_counters, .trace_thermal_stages = thermal_trace_active } else null, .diagnostic_vapor_layer_index = vapor_diagnostic_layer_index, .diagnostic_heat_layer_index = vapor_diagnostic_layer_index, .diagnostic_water_layer_index = water_diagnostic_layer_index });
    defer accepted_soil_water_heat.deinit();
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE attempt watsub elapsed_ms={d} substeps={d}",
        .{ temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(), exact_substep_count },
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE watsub_detail elapsed_ns={d} prepare_ns={d} prepare_snow_ns={d} prepare_forcing_ns={d} post_phase_ns={d} accept_ns={d} accept_carrier_ns={d} accept_snow_ns={d} accept_transport_ns={d} accept_litter_soil_ns={d} accept_compaction_ns={d}",
        .{
            temporary_profile_watsub_start.durationTo(std.Io.Clock.now(.boot, context.io)).nanoseconds,
            coupled_substeps.temporary_profile_prepare_ns,
            coupled_substeps.temporary_profile_prepare_snow_ns,
            coupled_substeps.temporary_profile_prepare_forcing_ns,
            coupled_substeps.temporary_profile_post_phase_ns,
            coupled_substeps.temporary_profile_accept_ns,
            coupled_substeps.temporary_profile_accept_carrier_ns,
            coupled_substeps.temporary_profile_accept_snow_ns,
            coupled_substeps.temporary_profile_accept_transport_ns,
            coupled_substeps.temporary_profile_accept_litter_soil_ns,
            coupled_substeps.temporary_profile_accept_compaction_ns,
        },
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE watsub_core setup_ns={d} water_solver_ns={d} richards_post_ns={d} vapor_solver_ns={d} vapor_post_ns={d} phase_solver_ns={d} phase_post_ns={d} heat_solver_ns={d} final_validation_ns={d} water_work_iterations={d} water_dense_jacobian_assemblies={d} water_dense_jacobian_reuses={d} water_face_flux_cache_hits={d} water_face_flux_cache_misses={d} vapor_work_iterations={d} phase_work_iterations={d} heat_work_iterations={d}",
        .{
            temporary_profile_watsub_counters.setup_ns,
            temporary_profile_watsub_counters.water_solver_ns,
            temporary_profile_watsub_counters.richards_post_ns,
            temporary_profile_watsub_counters.vapor_solver_ns,
            temporary_profile_watsub_counters.vapor_post_ns,
            temporary_profile_watsub_counters.phase_solver_ns,
            temporary_profile_watsub_counters.phase_post_ns,
            temporary_profile_watsub_counters.heat_solver_ns,
            temporary_profile_watsub_counters.final_validation_ns,
            accepted_soil_water_heat.work.total_water_iterations,
            accepted_soil_water_heat.work.total_water_dense_jacobian_assemblies,
            accepted_soil_water_heat.work.total_water_dense_jacobian_reuses,
            accepted_soil_water_heat.work.total_water_face_flux_cache_hits,
            accepted_soil_water_heat.work.total_water_face_flux_cache_misses,
            accepted_soil_water_heat.work.total_vapor_iterations,
            accepted_soil_water_heat.work.total_phase_iterations,
            accepted_soil_water_heat.work.total_heat_iterations,
        },
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE water_jacobian_cache supplied={d} loaded={d} ready_at_publication={d} conservative_map_publications={d} published={d}",
        .{
            accepted_soil_water_heat.work.total_water_dense_jacobian_cache_supplied,
            accepted_soil_water_heat.work.total_water_dense_jacobian_cache_loaded,
            accepted_soil_water_heat.work.total_water_dense_jacobian_ready_at_publication,
            accepted_soil_water_heat.work.total_water_conservative_map_publications,
            accepted_soil_water_heat.work.total_water_dense_jacobian_cache_published,
        },
    );
    if (accepted_soil_water_heat.accepted_substeps != exact_substep_count)
        return error.AcceptedSoilSubstepScheduleMismatch;
    {
        const trace = context.diagnostic_watsub_heat_trace_megajoules;
        const totals = try diagnostics.reconstructLandscapeMassBalance(context);
        trace[2] = totals.heat_storage_megajoules;
        trace[3] = totals.heat_storage_megajoules - totals.cumulative_heat_input_megajoules +
            totals.cumulative_heat_output_megajoules -
            totals.cumulative_internal_heat_production_megajoules +
            totals.cumulative_internal_heat_consumption_megajoules;
        for (coupled_substeps.ground_air_vapor_balance_total) |balance| {
            trace[7] += balance.sensible_heat_storage_change_megajoules;
            trace[8] += balance.atmospheric_sensible_heat_transfer_megajoules;
            trace[9] += balance.prescribed_non_atmospheric_sensible_heat_transfer_megajoules;
            trace[10] += balance.implicit_non_atmospheric_sensible_heat_transfer_megajoules;
        }
        for (0..context.grid.cell_count) |cell| {
            const area = context.canopy_cell_area_m2[cell];
            const radiation = coupled_substeps.surface_energy_total.net_radiation_megajoules_per_m2[cell] * area;
            const sensible = coupled_substeps.surface_temperature_total.sensible_heat_flux_megajoules_per_m2[cell] * area;
            const latent = coupled_substeps.surface_temperature_total.latent_heat_flux_megajoules_per_m2[cell] * area;
            const vapor_sensible = coupled_substeps.surface_temperature_total.vapor_sensible_heat_flux_megajoules_per_m2[cell] * area;
            trace[11] += radiation;
            trace[12] += sensible;
            trace[13] += latent;
            trace[14] += vapor_sensible;
            trace[15] += radiation + sensible + latent + vapor_sensible;
            trace[16] += coupled_substeps.snow_boundary_heat_total_megajoules[cell] -
                coupled_substeps.snow_reference_state_heat_megajoules_by_cell[cell];
            trace[17] += radiation + sensible + latent + vapor_sensible -
                (coupled_substeps.snow_boundary_heat_total_megajoules[cell] -
                    coupled_substeps.snow_reference_state_heat_megajoules_by_cell[cell]);
            trace[18] += coupled_substeps.forcing.topsoil_vapor_heat_total_megajoules[cell];
            trace[19] += coupled_substeps.topsoil_sensible_heat_total_megajoules[cell];
            trace[20] += coupled_substeps.surface_temperature_total.phase_heat_flux_megajoules_per_m2[cell] * area;
            trace[21] += coupled_substeps.surface_temperature_total.storage_heat_flux_megajoules_per_m2[cell] * area;
            trace[22] += coupled_substeps.surface_temperature_total.conductive_heat_flux_megajoules_per_m2[cell] * area;
            trace[28] += coupled_substeps.snow_reference_state_heat_megajoules_by_cell[cell];
        }
        trace[23] = accepted_soil_water_heat.solver.heat.boundary_heat_input_megajoules;
        trace[24] = accepted_soil_water_heat.solver.heat.boundary_heat_output_megajoules;
        if (accepted_soil_water_heat.solver.energy) |energy|
            trace[25] = energy.external_water_advective_enthalpy_outward_megajoules;
        for (context.soil_hourly_workspace.cell_heat_source_megajoules) |value| trace[26] += value;
        for (coupled_substeps.surface_conduction_total_megajoules) |value| trace[27] += value;
        for (coupled_substeps.surface_phase_sensible_adjustment_total_megajoules_by_cell) |value| trace[29] += value;
        const energy = accepted_soil_water_heat.solver.energy orelse
            return error.MissingHourlySoilEnergyDiagnostics;
        trace[30] = energy.richards_enthalpy_change_megajoules;
        trace[31] = energy.vapor_transport_enthalpy_change_megajoules;
        trace[32] = energy.phase_enthalpy_change_megajoules;
        trace[33] = energy.phase_absolute_enthalpy_change_megajoules;
        trace[34] = energy.spatial_heat_enthalpy_change_megajoules;
        trace[35] = energy.phase_latent_heat_megajoules;
        trace[36] = energy.heat_solver_freeze_thaw_latent_megajoules;
        for (coupled_substeps.surface_internal_vapor_latent_heat_total_megajoules_by_cell) |value| trace[37] += value;
        for (coupled_substeps.surface_atmospheric_water_thermalization_total_megajoules_by_cell) |value| trace[38] += value;
        for (trace.*) |value| if (!std.math.isFinite(value))
            return error.NonFiniteHourlyFailureTrace;
    }
    // Bisection of the front end. `prepareHour` was exonerated by measurement
    // (phosphate bit-identical across it), so the 1.1027623258996755e-10 g P
    // creation lies between the hour-start bracket and line 12058. These five
    // prints split that region at its coarse boundaries in a single run rather
    // than testing one call per run: the accepted-solver publishes, the water/heat
    // state-update generation, the combustion/root-heat accumulations, the soil
    // thermal tile update, and the hourly workspace refresh (which takes
    // `soil_chemistry` and the osmotic zone fractions, so it can touch chemistry).
    // If the jump is already present at the first print, the locus is the coupled
    // substep loop above -- where the per-M TRNSFR solute replay runs and phosphate
    // amounts actually move.
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "front_end_after_substep_loop");
    try coupled_substeps.publishAcceptedSurfaceTemperature();
    try coupled_substeps.publishAcceptedGroundAir();
    try coupled_substeps.publishAcceptedAtmosphericLocalActivity();
    {
        const totals = try diagnostics.reconstructLandscapeMassBalance(context);
        context.diagnostic_watsub_heat_trace_megajoules[4] =
            totals.heat_storage_megajoules - totals.cumulative_heat_input_megajoules +
            totals.cumulative_heat_output_megajoules -
            totals.cumulative_internal_heat_production_megajoules +
            totals.cumulative_internal_heat_consumption_megajoules;
    }
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "front_end_after_accepted_publishes");
    try coupled_substeps.publishAcceptedSnowSchedule();
    try coupled_substeps.publishAcceptedSnowDrift();
    try coupled_substeps.publishSnowReferenceStateHeat();
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "front_end_after_snow_publishes");
    // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. `heat_step.zig:905-915`
    // computes `delta = live - base` and then restores the grid to `base`, so the
    // grid here holds `base` and the write below produces `base + delta`. Both
    // `live - base` (Sterbenz, since they differ by ~4e-5 relative) and the
    // subsequent addition should be exact, which would make the write land exactly
    // on `live` -- the carrier the chemistry was rebased onto during the solve.
    //
    // If it does, the two legs of the +/-0.07032 excursion must cancel exactly and
    // the residual has to come from a carrier the chemistry is NOT consistent with.
    // Print the per-layer base, the applied delta and the written value so the
    // exactness is measured rather than assumed.
    // Capture every grid carrier for every layer, not just the matrix water of the
    // first three: "exact for layers 0-2" is not evidence about layers 3-11, and a
    // single inexact element anywhere would be the defect.
    const diagnostic_base_all_carriers: []f64 = if (diagnostic_first_hour)
        try context.allocator.dupe(f64, context.grid.matrix_liquid_water_m3)
    else
        &.{};
    defer if (diagnostic_first_hour) context.allocator.free(diagnostic_base_all_carriers);
    // Final bracket of the surviving window. The +1.102e-10 g P appears between
    // `ingress_after_soil_ingress_rebase` and `front_end_after_heat_accumulations`,
    // coincident with a -4.5396e-5 m3 water change, with every concentration-basis
    // total bit-identical across it -- so the whole change is in the transport
    // extensive amounts. This call applies the accepted water, which is the change
    // the residual tracks, so it is the last unbracketed candidate in the window.
    try group_timestep_finalize.state_updateHourlyWaterHeatStateGeneration(
        context,
        &accepted_soil_water_heat,
    );
    if (diagnostic_first_hour) {
        try diagnostics.logPhosphorusRepresentation(context, "front_end_after_water_heat_state_generation");
        // The matching half of the confirmation: the carrier this call actually
        // wrote, per layer, against which the already-rebased concentrations are
        // now integrated. Compare with `phosphorus rebase carrier: live_m3` -- the
        // rebase target. Any difference is integrated against a 1192.8 g P
        // solid-phase pool, so a 415-eps gap is a 1.1e-10 g P mass change.
        // Measured: only layer 0 differs between the rebase target and the written
        // carrier, by 1.5358e-3 relative; layers 1 and 2 are bit-identical. That
        // refutes the "1192.8 g P precipitated pool" amplifier -- the deep layers
        // holding that pool have consistent carriers. The amplifier can only be
        // layer 0's own water-scaled phosphate, so the chain requires
        //     layer0_water_scaled_phosphate_g * 1.5358e-3 == 1.1027623258996755e-10
        // i.e. 7.17e-8 g P. Both factors are measured, so the product is a
        // zero-parameter test that can fail. Print the actual value.
        const carrier_count = ecosys.soil_water_heat_step.deferred_grid_carrier_count;
        var inexact_layers: usize = 0;
        for (0..context.grid.layer_count) |layer| {
            const base_m3 = diagnostic_base_all_carriers[layer];
            const applied_delta_m3 = accepted_soil_water_heat.grid_delta_by_layer_carrier[layer * carrier_count];
            const written_m3 = context.grid.matrix_liquid_water_m3[layer];
            if (written_m3 == base_m3 + applied_delta_m3) continue;
            inexact_layers += 1;
            std.log.info(
                "phosphorus write INEXACT: layer={d} base_m3={e} delta_m3={e} written_m3={e} base_plus_delta_m3={e} gap_m3={e}",
                .{ layer, base_m3, applied_delta_m3, written_m3, base_m3 + applied_delta_m3, written_m3 - (base_m3 + applied_delta_m3) },
            );
        }
        std.log.info("phosphorus write exactness: layers={d} inexact={d}", .{ context.grid.layer_count, inexact_layers });
        for (0..@min(3, context.grid.layer_count)) |layer| {
            const fractions = try context.fertilizer_band.scienceZoneFractionsForFlatIndex(layer);
            const water_m3 = context.grid.matrix_liquid_water_m3[layer];
            const p_mass = context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol;
            var water_scaled_g: f64 = 0;
            const zones = [2]@TypeOf(context.soil_chemistry.non_band_phosphate[0]){
                context.soil_chemistry.non_band_phosphate[layer],
                context.soil_chemistry.band_phosphate[layer],
            };
            for (zones, [2]f64{ fractions.phosphate_non_band, fractions.phosphate_band }) |zone, fraction|
                water_scaled_g += fraction * water_m3 * p_mass *
                    (zone.dissolved_hpo4_mol_p_per_m3 + zone.dissolved_h2po4_mol_p_per_m3 +
                        zone.aluminum_phosphate_solid_mol_per_m3 + zone.iron_phosphate_solid_mol_per_m3 +
                        zone.dicalcium_phosphate_solid_mol_per_m3 + 3 * zone.hydroxyapatite_solid_mol_per_m3 +
                        2 * zone.monocalcium_phosphate_solid_mol_per_m3);
            std.log.info(
                "phosphorus written carrier: layer={d} written_m3={e} water_scaled_phosphate_g={e}",
                .{ layer, water_m3, water_scaled_g },
            );
        }
    }
    {
        const totals = try diagnostics.reconstructLandscapeMassBalance(context);
        context.diagnostic_watsub_heat_trace_megajoules[5] = totals.heat_storage_megajoules;
        context.diagnostic_watsub_heat_trace_megajoules[6] =
            totals.heat_storage_megajoules - totals.cumulative_heat_input_megajoules +
            totals.cumulative_heat_output_megajoules -
            totals.cumulative_internal_heat_production_megajoules +
            totals.cumulative_internal_heat_consumption_megajoules;
    }
    // `acceptedBoundaryHeat` intentionally excludes the mixed cell source,
    // so publish the exact delayed producers once after their accepted state
    // has committed and before relinquishing their rollback-owned carriers.
    try ecosys.layer_local_conservation.accumulateSoilCombustionHeat(
        context.hourly_layer_boundary_ledger,
        context.grid.active_soil_layer_count,
        context.delayed_subsurface_combustion_heat_megajoules,
    );
    try context.landscape_boundary_ledger.accumulateAcceptedSubsurfaceCombustionAndRootHeat(
        context.grid.active_soil_layer_count,
        context.grid.soil_layer_capacity,
        context.delayed_subsurface_combustion_heat_megajoules,
        context.delayed_root_uptake_heat_megajoules,
    );
    try ecosys.hourly_cell_conservation.accumulateSubsurfaceCombustionAndRootHeat(
        context.hourly_cell_boundary_ledger,
        context.grid.active_soil_layer_count,
        context.grid.soil_layer_capacity,
        context.delayed_subsurface_combustion_heat_megajoules,
        context.delayed_root_uptake_heat_megajoules,
    );
    @memset(context.delayed_subsurface_combustion_heat_megajoules, 0);
    @memset(context.delayed_root_uptake_heat_megajoules, 0);
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "front_end_after_heat_accumulations");
    try tile_kernels.runKernelAcrossSerialTiles(context, context.soil_thermal_context, ecosys.soil_thermal.updateTile);
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "front_end_after_soil_thermal_tile");
    try context.soil_hourly_workspace.refresh(context.grid, context.soil_solver_properties, context.soil_thermal, context.terrain_hydrology, context.runscript.soil_process_parameters, context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3, context.soil_chemistry, soil_osmotic_zone_fractions);
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "front_end_after_hourly_workspace_refresh");
    // DRY-LAYER-UNPHYSICAL-HEAT-SINK-HOUR-2726-001. The heat solver is handed
    // `heat_capacity_megajoules_per_k = 5.051462339142763e-5` for cell 0, which over
    // a `9.900010756880346e-3` m3 layer is `5.10e-3` MJ m-3 K-1 -- air-like, ~370x
    // below mineral soil, and the reason a normal energy imbalance divides into a
    // `-3.05e5` K residual.
    //
    // The capacity is stored per-m3 and round-tripped through a layer volume
    // (`:8061` multiplies, `:8157` divides), but TWO volume owners exist:
    // `soil_thermal.layer_volume_m3`, which `surface/pond_water_heat_transfer.zig:81`
    // writes, and `soil_solver_properties.layer_volume_m3`, which the round-trip
    // uses. If they disagree the capacity is scaled by their ratio -- the same
    // two-copies-of-one-quantity shape as the phosphorus carrier defect fixed
    // earlier this session.
    //
    // Print both volumes and both capacity arrays so the ratio is measured instead
    // of assumed.
    if (!builtin.is_test and context.executed_weather_hours.* >= 2724 and
        context.executed_weather_hours.* < 2727)
    {
        for (0..@min(3, context.grid.layer_count)) |layer| std.log.info(
            "dry layer capacity probe: hour={d} layer={d} thermal_volume_m3={e} solver_volume_m3={e} total_capacity_per_m3_k={e} dry_capacity_per_m3_k={e} implied_total_per_k={e} matrix_liquid_m3={e} matrix_ice_m3={e} porosity={e} micropore_fraction={e} bulk_density={e} texture_fraction_sum={e} texture_mass_mg={e} layer_solid_mass_mg={e}",
            .{
                context.executed_weather_hours.* + 1,
                layer,
                context.soil_thermal.layer_volume_m3[layer],
                context.soil_solver_properties.layer_volume_m3[layer],
                context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[layer],
                context.soil_thermal.dry_solid_heat_capacity_megajoules_per_m3_k[layer],
                context.soil_thermal.total_heat_capacity_megajoules_per_m3_k[layer] *
                    context.soil_solver_properties.layer_volume_m3[layer],
                context.grid.matrix_liquid_water_m3[layer],
                context.grid.matrix_ice_water_m3[layer],
                context.soil_thermal.porosity_fraction[layer],
                context.soil_solver_properties.micropore_fraction[layer],
                context.soil_solver_properties.bulk_density_megagrams_per_m3[layer],
                context.soil_solver_properties.sand_mass_fraction[layer] +
                    context.soil_solver_properties.silt_mass_fraction[layer] +
                    context.soil_solver_properties.clay_mass_fraction[layer],
                context.soil_solver_properties.sand_mass_megagrams[layer] +
                    context.soil_solver_properties.silt_mass_megagrams[layer] +
                    context.soil_solver_properties.clay_mass_megagrams[layer],
                context.soil_solver_properties.bulk_density_megagrams_per_m3[layer] *
                    context.soil_solver_properties.layer_volume_m3[layer],
            },
        );
    }
    try context.soil_boundary_topology.refreshInternalWaterTableWithIceDensity(context.grid, context.soil_solver_properties.matrix_bulk_volume_m3, context.soil_solver_properties.mualem_van_genuchten_parameters, context.soil_solver_properties.layer_thickness_m, context.soil_solver_properties.layer_midpoint_depth_m, context.soil_solver_properties.layer_bottom_depth_m, context.runscript.water_table_air_fraction_threshold, context.runscript.active_layer_ice_fraction_threshold, context.surface_precipitation.litter_water_m3, context.surface_precipitation.litter_water_capacity_m3, context.canopy_cell_area_m2, context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3);
    // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. The residual is created
    // in this front end: the ledger's phosphate owner gains 1.1027623258996755e-10
    // g P between the hour-start bracket and the `.nitro` phase with nothing
    // booked, and it is NOT a roundoff floor -- the same gap is 1.59e-12 (6 eps)
    // one hour earlier and 1.10e-10 (404 eps) at the failing hour, a 69x jump while
    // the driving water movement halved.
    //
    // `prepareHour` is the prime suspect because it advances the fertilizer-band
    // coordinator's phase, and `fertilizer_band_state.scienceZoneFractions` returns
    // the RAW stored fractions while that phase is `.idle` but
    // `preConsumptionPair`-adjusted fractions afterwards. Every fraction-weighted
    // phosphate inventory therefore re-bases across this call with no mass
    // transfer: `phosphateImmobileInventory` scales adsorbed by
    // `soil_mass * zone_fraction` and precipitated by `water_m3 * zone_fraction`.
    // Fertilizer was applied at hour 2,508, so the band's relative changes are live
    // and evolving, which fits the hour-to-hour jump.
    //
    // Bracketed rather than assumed: four mechanisms in this investigation were
    // named from code structure and every one was refuted by measurement.
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "before_fertilizer_band_prepare_hour");
    try ecosys.fertilizer_band_production.prepareHour(
        context.fertilizer_band,
        fertilizer_band_hour,
        context.soil_solver_properties.layer_thickness_m,
        context.grid.matrix_liquid_water_m3,
        context.grid.matrix_pore_capacity_m3,
        context.grid.soil_temperature_k,
        context.grid.active_soil_layer_count,
        context.runscript.soil_geometry_parameters.minimum_layer_thickness_m,
        context.runscript.root_nutrient_parameters,
        &fertilizer_band_workspace,
    );
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "after_fertilizer_band_prepare_hour");
    // Certificate the exact accepted WATSUB physical carriers and accumulated
    // face/boundary flux buffers before NITRO/HFUNC/UPTAKE/SOLUTE mutate any
    // downstream scientific owner. Late per-M TRNSFR replay temporarily
    // rebinds step-entry carriers and restores this vector on every exit.
    try coupled_substeps.transport_replay.captureFinal();
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE attempt publish elapsed_ms={d} substeps={d}",
        .{ temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(), exact_substep_count },
    );
    // soil.f:157--207. WATSUB has accepted and its per-substep carriers are
    // private in `transport_replay`; authoritative transported inventories are
    // still untouched. Publish biological sources before any TRNSFR consumer.
    // HOUR1/NITRO consume the accepted physical air/temperature and amount-
    // owner carrier mirrors published atomically by each WATSUB acceptance.
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "before_nitro");
    // ISSUE-065 (eighteenth pass): directly test the seventeenth addendum's
    // timing-gap hypothesis by tracing the IMPLIED aqueous phosphate export
    // (concentration/carrier/zone-fraction recompute, independent of the
    // stale `transport_state.amount_mol`) at every stage boundary bracketing
    // WATSUB's accepted final carrier through TRNSFR's replay.
    try diagnostics.traceImpliedPhosphateExportLayer0(context, "before_nitro");
    try group_sediment.routeSedimentAndErosion(
        context,
        .nitro,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar_by_cell,
        fertilizer_band_hour,
        gas_failure_report,
        solute_failure_report,
        diagnostic_first_hour,
        plant_calendar,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        irrigationChemistryParameters(context),
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE attempt nitro elapsed_ms={d} substeps={d}",
        .{ temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(), exact_substep_count },
    );
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_nitro");
    try diagnostics.traceImpliedPhosphateExportLayer0(context, "after_nitro");
    try captureFailureConservationTrace(context, 0);
    // PHOSPHORUS-SOIL-SURFACE-BIOGEOCHEMISTRY-HALVES-001. Measurement showed the
    // topsoil dissolved phosphate moves the CONCENTRATION basis in the `.nitro`
    // phase but the TRANSPORT basis only after it, and the transport-basis jump
    // (+8.442423804e-4 g P) lands in this gap between the `.nitro` and `.solute`
    // calls -- not in the `pre_chemistry_matrix_refresh` label that was booking
    // it, whose body is `mineral_nitrogen_transport.refreshMatrixFromReactionState`
    // and cannot move phosphorus at all.
    //
    // Three operations sit in this gap, and one of them owns the publish:
    // `post_watsub_biology.advance`, `advanceUptakeGrowthAndExtract` (which
    // contains the `synchronizeCellAfterCarrierChange` loop over the four
    // phosphate species at `hourly_vegetation.zig:272-290`), and
    // `produceCanopyStandingDeadFireBeforeSolute`. Bracket all three rather than
    // infer which -- four mechanisms in this investigation were named from code
    // structure and all four were wrong.
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "before_post_watsub_biology");
    try post_watsub_biology.advance(post_watsub_biology.context);
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "after_post_watsub_biology");
    try captureFailureConservationTrace(context, 1);
    try group_vegetation.advanceUptakeGrowthAndExtract(
        context,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar,
    );
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "after_uptake_growth_extract");
    try group_vegetation.produceCanopyStandingDeadFireBeforeSolute(context);
    if (diagnostic_first_hour) try diagnostics.logPhosphorusRepresentation(context, "after_canopy_standing_dead");
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE attempt biology elapsed_ms={d} substeps={d}",
        .{ temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(), exact_substep_count },
    );
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_uptake_growth_extract");
    try diagnostics.traceImpliedPhosphateExportLayer0(context, "after_uptake_growth_extract");
    try captureFailureConservationTrace(context, 2);
    try group_sediment.routeSedimentAndErosion(
        context,
        .solute,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar_by_cell,
        fertilizer_band_hour,
        gas_failure_report,
        solute_failure_report,
        diagnostic_first_hour,
        plant_calendar,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        irrigationChemistryParameters(context),
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE attempt solute elapsed_ms={d} substeps={d}",
        .{ temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(), exact_substep_count },
    );
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_solute_phase");
    try diagnostics.traceImpliedPhosphateExportLayer0(context, "after_solute_phase");
    try captureFailureConservationTrace(context, 3);
    try coupled_substeps.replayAcceptedTransport();
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_transport_replay");
    try diagnostics.traceImpliedPhosphateExportLayer0(context, "after_transport_replay");
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE attempt replay elapsed_ms={d} substeps={d}",
        .{ temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(), exact_substep_count },
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE replay_detail setup_ns={d} bind_ns={d} rebase_ns={d} interface_ns={d} aqueous_ns={d} organic_ns={d} mineral_ns={d} dissolved_gas_ns={d} soil_gas_ns={d} restore_ns={d}",
        .{
            coupled_substeps.temporary_profile_replay_setup_ns,
            coupled_substeps.temporary_profile_replay_bind_ns,
            coupled_substeps.temporary_profile_replay_rebase_ns,
            coupled_substeps.temporary_profile_replay_interface_ns,
            coupled_substeps.temporary_profile_replay_aqueous_ns,
            coupled_substeps.temporary_profile_replay_organic_ns,
            coupled_substeps.temporary_profile_replay_mineral_ns,
            coupled_substeps.temporary_profile_replay_dissolved_gas_ns,
            coupled_substeps.temporary_profile_replay_soil_gas_ns,
            coupled_substeps.temporary_profile_replay_restore_ns,
        },
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE replay_iterations aqueous_micro_iterations={d} aqueous_macro_iterations={d} aqueous_micro_newton={d} aqueous_macro_newton={d} soil_gas_iterations={d} soil_gas_newton={d} soil_gas_anderson={d} soil_gas_dense_jacobian_assemblies={d} soil_gas_dense_jacobian_reuses={d} soil_gas_krylov_direction_calls={d} soil_gas_krylov_iterations={d}",
        .{
            coupled_substeps.temporary_profile_aqueous_micropore_iterations,
            coupled_substeps.temporary_profile_aqueous_macropore_iterations,
            coupled_substeps.temporary_profile_aqueous_micropore_newton_steps,
            coupled_substeps.temporary_profile_aqueous_macropore_newton_steps,
            coupled_substeps.temporary_profile_soil_gas_iterations,
            coupled_substeps.temporary_profile_soil_gas_newton_steps,
            coupled_substeps.temporary_profile_soil_gas_anderson_steps,
            coupled_substeps.temporary_profile_soil_gas_dense_jacobian_assemblies,
            coupled_substeps.temporary_profile_soil_gas_dense_jacobian_reuses,
            coupled_substeps.temporary_profile_soil_gas_krylov_direction_calls,
            coupled_substeps.temporary_profile_soil_gas_krylov_iterations,
        },
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE soil_gas_detail setup_ns={d} faces_ns={d} boundaries_ns={d} solver_ns={d} publication_ns={d} stage_post_ns={d}",
        .{
            coupled_substeps.temporary_profile_soil_gas_step.setup_ns,
            coupled_substeps.temporary_profile_soil_gas_step.faces_ns,
            coupled_substeps.temporary_profile_soil_gas_step.boundaries_ns,
            coupled_substeps.temporary_profile_soil_gas_step.solver_ns,
            coupled_substeps.temporary_profile_soil_gas_step.publication_ns,
            coupled_substeps.temporary_profile_soil_gas_stage_post_ns,
        },
    );
    try captureFailureConservationTrace(context, 4);
    try coupled_substeps.publishLitterSoilOrganicHeatRebase();
    var diagnostic_litter_soil_rebase_megajoules: f64 = 0;
    for (coupled_substeps.litter_soil_organic_heat_rebase_total_megajoules_by_cell) |heat_megajoules|
        diagnostic_litter_soil_rebase_megajoules += heat_megajoules;
    if (!std.math.isFinite(diagnostic_litter_soil_rebase_megajoules))
        return error.NonFiniteHourlyFailureTrace;
    context.diagnostic_litter_soil_organic_heat_rebase_megajoules.* =
        diagnostic_litter_soil_rebase_megajoules;
    try captureFailureConservationTrace(context, 5);
    // TRNSFR is the producer of the accepted aqueous/dry-gas transport
    // totals. Publish only after every accepted M-substep has been replayed;
    // publishing before replay left the public dry-gas boundary arrays holding
    // only `advance`'s final substep, while storage reflected every substep.
    coupled_substeps.publishAcceptedLedgers();
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_publish_accepted_ledgers");
    // Surface NITRO has now completed, so the litter-atmosphere gas owner is
    // part of the same late TRNSFR phase instead of consuming prior-hour gas.
    try group_sediment.routeSedimentAndErosion(
        context,
        .surface_gas,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar_by_cell,
        fertilizer_band_hour,
        gas_failure_report,
        solute_failure_report,
        diagnostic_first_hour,
        plant_calendar,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        irrigationChemistryParameters(context),
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
    );
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_surface_gas_phase");
    try captureFailureConservationTrace(context, 6);
    try publishPhaseAndBoundaryHeat(context, &accepted_soil_water_heat);
    try publishHourlyCellTransportLedgers(context, &coupled_substeps);
    try publishHourlyLayerTransportLedgers(
        context,
        &coupled_substeps,
        &accepted_soil_water_heat,
    );
    if (temporary_profile_active) std.log.info(
        "TEMP_PROFILE attempt complete elapsed_ms={d} substeps={d}",
        .{ temporary_profile_start.durationTo(std.Io.Clock.now(.boot, context.io)).toMilliseconds(), exact_substep_count },
    );
    if (diagnostic_first_hour) {
        const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
        std.log.debug("heat stage: soil_water_heat_state_update hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
        // EXEC-002: hours 5--16 inject a smoothly decaying POSITIVE error with
        // this stage dominant, which means the storage this stage moves and the
        // boundary heat it books disagree systematically. Report both, plus the
        // solver's own convergence state, so the discrepancy can be attributed.
        std.log.debug("soil heat boundary detail: hour={d} stage_delta_megajoules={e} boundary_input_megajoules={e} boundary_output_megajoules={e} net_boundary_megajoules={e} iterations={d} max_scaled_residual={e}", .{
            context.executed_weather_hours.* + 1,
            heat_megajoules - diagnostic_previous_heat_megajoules,
            accepted_soil_water_heat.solver.heat.boundary_heat_input_megajoules,
            accepted_soil_water_heat.solver.heat.boundary_heat_output_megajoules,
            accepted_soil_water_heat.solver.heat.boundary_heat_input_megajoules -
                accepted_soil_water_heat.solver.heat.boundary_heat_output_megajoules,
            accepted_soil_water_heat.solver.heat.iterations,
            accepted_soil_water_heat.solver.heat.maximum_scaled_residual,
        });
        // EXEC-002: the surface solver's conductive flux is an INTERNAL
        // surface<->soil transfer, so it is correctly absent from the boundary
        // ledger, but only if the soil actually receives what the surface gives.
        // Report both halves of the pairing.
        var diagnostic_surface_conduction_megajoules: f64 = 0;
        var diagnostic_soil_heat_source_megajoules: f64 = 0;
        for (0..context.grid.cell_count) |cell| {
            const top = cell * context.grid.soil_layer_capacity;
            // HEAT-001: `bindSurfaceHeatFlux` multiplies by
            // `plan_area_m2[top]`, so the instrument must use the
            // same area. Using `canopy_cell_area_m2` compared two different
            // areas and reported the difference as a mismatch.
            diagnostic_surface_conduction_megajoules +=
                context.surface_temperature.conductive_heat_flux_megajoules_per_m2[cell] *
                context.canopy_cell_area_m2[cell];
            // HEAT-001: read the published conduction slot, not
            // `cell_heat_source_megajoules[top]`, which by this point also
            // carries precipitation ingress, subsurface irrigation and
            // delayed combustion heat and so fabricates a mismatch.
            diagnostic_soil_heat_source_megajoules +=
                context.soil_hourly_workspace.published_surface_conduction_heat_megajoules[top];
        }
        std.log.debug("surface soil conduction pairing: hour={d} surface_gives_megajoules={e} soil_receives_megajoules={e} mismatch_megajoules={e}", .{ context.executed_weather_hours.* + 1, -diagnostic_surface_conduction_megajoules, diagnostic_soil_heat_source_megajoules, -diagnostic_surface_conduction_megajoules - diagnostic_soil_heat_source_megajoules });
        diagnostic_previous_heat_megajoules = heat_megajoules;
    }
    if (context.executed_weather_hours.* < 24) std.log.debug("current soil heat boundary: input_megajoules={e} output_megajoules={e}", .{ accepted_soil_water_heat.solver.heat.boundary_heat_input_megajoules, accepted_soil_water_heat.solver.heat.boundary_heat_output_megajoules });
    if (context.executed_weather_hours.* < 24) {
        if (accepted_soil_water_heat.solver.energy) |energy| std.log.debug(
            "soil transaction energy: richards_megajoules={e} vapor_megajoules={e} phase_sensible_megajoules={e} phase_absolute_megajoules={e} spatial_heat_megajoules={e} vapor_latent_megajoules={e} freeze_thaw_latent_megajoules={e}",
            .{
                energy.richards_enthalpy_change_megajoules,
                energy.vapor_transport_enthalpy_change_megajoules,
                energy.phase_enthalpy_change_megajoules,
                energy.phase_absolute_enthalpy_change_megajoules,
                energy.spatial_heat_enthalpy_change_megajoules,
                energy.phase_latent_heat_megajoules,
                energy.heat_solver_freeze_thaw_latent_megajoules,
            },
        );
    }
    // REDIST DVOLI producer. Preserve the accepted signed ice-volume change,
    // but defer all geometry and pool remapping until erosion and SOC producers
    // have finished at the single end-of-hour owner.
    {
        const carrier_count = ecosys.soil_water_heat_step.deferred_grid_carrier_count;
        const ws = context.soil_profile_relayering_workspace;
        // Every accepted WATSUB/replay carrier transition has already rebased
        // aqueous, phosphate and geochemistry-solid concentrations at the
        // exact transition point. Root TUPWTR is applied later by REDIST's
        // single owner. A final accepted-hour delta rebase here would
        // double-scale persistent minerals.
        // FROST-HEAVE-SIGN-001: retain accepted DVOLI until the single
        // end-of-hour geometry transaction. `grid_delta_by_layer_carrier` is accepted
        // minus base (final minus initial matrix ice volume), positive when
        // ice increases during freezing. The oracle's DVOLI (redist.f:5965-
        // 5966) is the opposite convention -- old minus new, i.e. NEGATIVE
        // when ice increases -- because DDLYXF=DVOLI*DENSJ/(FMPR*AREA) must
        // come out negative during freezing so the CDPTH cumulative
        // construction shrinks (frost heave lifts ALTG). Negate here so
        // the end-of-hour assembler receives the true DVOLI sign
        // instead of its inverse.
        for (0..context.grid.layer_count) |l| {
            ws.ice_volume_delta_m3[l] =
                -accepted_soil_water_heat.grid_delta_by_layer_carrier[l * carrier_count + 7] /
                context.runscript.soil_phase_heat_parameters.freeze_thaw.ice_density_megagrams_per_m3;
        }
    }
    if (diagnostic_first_hour) {
        const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
        std.log.info("phosphorus stage: after_dvoli_capture delta_g={e}", .{current_p_g - diagnostic_previous_p_g});
        const owners = try diagnostics.diagnosticPhosphorusOwners_g(context);
        std.log.debug("phosphorus dvoli-capture owners: residue_g={e} organic_g={e} phosphate_g={e}", .{ owners[0] - diagnostic_previous_p_owners[0], owners[1] - diagnostic_previous_p_owners[1], owners[2] - diagnostic_previous_p_owners[2] });
        const phosphate_owners = try diagnostics.diagnosticRelayerPhosphateOwners_g(context);
        std.log.debug("phosphorus dvoli-capture chemistry: dissolved_g={e} adsorbed_g={e} precipitate_g={e}", .{ phosphate_owners[0] - diagnostic_relayer_phosphate_before[0], phosphate_owners[1] - diagnostic_relayer_phosphate_before[1], phosphate_owners[2] - diagnostic_relayer_phosphate_before[2] });
        diagnostic_previous_p_owners = owners;
        diagnostic_previous_p_g = current_p_g;
        const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
        std.log.debug("heat stage: dvoli_capture hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
        diagnostic_previous_heat_megajoules = heat_megajoules;
    }
    const subsurface_irrigation_chemistry_parameters = irrigationChemistryParameters(context);
    // The accepted substeps already applied face, boundary, and pore-exchange
    // changes directly. Publish their checked hourly face-ledger sums for
    // lateral diagnostics without applying the same contribution a second time.
    if (diagnostic_first_hour) {
        const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
        var boundary_p_g: f64 = 0;
        for (context.soil_solute_boundary_net_flux_mol, 0..) |flux_mol, component| {
            const species: ecosys.solute_transport_species.AqueousSpecies = @enumFromInt(component % ecosys.solute_transport_species.AqueousSpecies.count);
            if (ecosys.solute_transport_species.diffusivityClass(species) == .phosphate)
                boundary_p_g += flux_mol * context.runscript.root_nutrient_parameters.phosphorus_molar_mass_g_per_mol;
        }
        std.log.info("phosphorus stage: aqueous_transport delta_g={e} boundary_net_input_g={e} residual_g={e}", .{ current_p_g - diagnostic_previous_p_g, boundary_p_g, current_p_g - diagnostic_previous_p_g - boundary_p_g });
        try diagnostics.logPhosphorusRepresentation(context, "after_aqueous_transport");
        diagnostic_previous_p_g = current_p_g;
    }
    if (diagnostic_first_hour) {
        const current_n_g = try diagnostics.diagnosticStoredNitrogen_g(context);
        std.log.debug("nitrogen stage: through_mineral_transport delta_g={e}", .{current_n_g - diagnostic_previous_n_g});
        const current_p_g = try diagnostics.diagnosticStoredPhosphorus_g(context);
        const diagnostic_boundary_p_g: f64 = 0;
        std.log.info("phosphorus stage: through_mineral_transport delta_g={e} boundary_g={e} residual_g={e}", .{ current_p_g - diagnostic_previous_p_g, diagnostic_boundary_p_g, current_p_g - diagnostic_previous_p_g - diagnostic_boundary_p_g });
        try diagnostics.logPhosphorusRepresentation(context, "after_through_mineral_transport");
        diagnostic_previous_p_g = current_p_g;
        const heat_megajoules = (try diagnostics.reconstructLandscapeMassBalance(context)).heat_storage_megajoules;
        std.log.debug("heat stage: mineral_transport hour={d} delta_megajoules={e}", .{ context.executed_weather_hours.* + 1, heat_megajoules - diagnostic_previous_heat_megajoules });
        diagnostic_previous_heat_megajoules = heat_megajoules;
        var diagnostic_mineral_after_mol: f64 = 0;
        for (context.mineral_nitrogen_transport.matrix.amount_mol) |amount| diagnostic_mineral_after_mol += amount;
        for (context.mineral_nitrogen_transport.macropore.amount_mol) |amount| diagnostic_mineral_after_mol += amount;
        var diagnostic_mineral_export_g_n: f64 = 0;
        for (context.mineral_nitrogen_transport.boundary_export_g_n_per_step) |amount| diagnostic_mineral_export_g_n += amount;
        std.log.debug("mineral nitrogen transaction: inventory_delta_g_n={e} boundary_export_g_n={e} residual_g_n={e}", .{ (diagnostic_mineral_after_mol - diagnostic_mineral_before_mol) * context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol, diagnostic_mineral_export_g_n, (diagnostic_mineral_after_mol - diagnostic_mineral_before_mol) * context.runscript.fertilizer_nitrogen_molar_mass_g_per_mol + diagnostic_mineral_export_g_n });
        const components_n = try diagnostics.reconstructLandscapeMassBalance(context);
        std.log.debug("transport nitrogen components: residue={e} organic={e} n2={e} nh4={e} no3={e}", .{ components_n.residue_nitrogen_g - diagnostic_transport_before.residue_nitrogen_g, components_n.organic_nitrogen_g - diagnostic_transport_before.organic_nitrogen_g, components_n.dinitrogen_nitrogen_g - diagnostic_transport_before.dinitrogen_nitrogen_g, components_n.ammonium_nitrogen_g - diagnostic_transport_before.ammonium_nitrogen_g, components_n.nitrate_nitrogen_g - diagnostic_transport_before.nitrate_nitrogen_g });
        std.log.debug("transport phosphorus components: residue={e} organic={e} phosphate={e}", .{ components_n.residue_phosphorus_g - diagnostic_transport_before.residue_phosphorus_g, components_n.organic_phosphorus_g - diagnostic_transport_before.organic_phosphorus_g, components_n.phosphate_phosphorus_g - diagnostic_transport_before.phosphate_phosphorus_g });
        const owners = try diagnostics.diagnosticAmmoniumOwners_g_n(context);
        std.log.debug("transport ammonium owners delta: surface_aq={e} surface_exchange={e} surface_fertilizer={e} soil_aq={e} soil_exchange={e} soil_fertilizer={e}", .{ owners[0] - diagnostic_transport_ammonium_before[0], owners[1] - diagnostic_transport_ammonium_before[1], owners[2] - diagnostic_transport_ammonium_before[2], owners[3] - diagnostic_transport_ammonium_before[3], owners[4] - diagnostic_transport_ammonium_before[4], owners[5] - diagnostic_transport_ammonium_before[5] });
        diagnostic_previous_n_g = current_n_g;
    }
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "before_erosion_redist_transport");
    try group_gas_surface_water.transportDissolvedGasAndSurfaceWater(
        context,
        hour_of_day,
        weather_header_by_cell,
        plant_calendar_by_cell,
        fertilizer_band_hour,
        gas_failure_report,
        solute_failure_report,
        true,
        diagnostic_first_hour,
        plant_calendar,
        snow_phase_change_report,
        snow_vapor_equilibrium_report,
        subsurface_irrigation_chemistry_parameters,
        &diagnostic_previous_heat_megajoules,
        &diagnostic_previous_n_g,
        &diagnostic_previous_p_g,
    );
    try diagnostics.traceStageBoundaryLayer0Carbon(context, "after_erosion_redist_transport");
    // Generation publication is delayed until all mutating science has
    // succeeded, so a later stage failure cannot leave accepted retry files
    // behind while memory is rolled back.
    try group_timestep_finalize.publishHourlySoilSoluteContributionGenerations(context);
    try coupled_substeps.publishGasGeneration();
    // Arithmetic provenance remains private through every rejected schedule
    // and downstream failure. Both adapters preflight complete destinations,
    // so this paired accepted-attempt publication is atomic per adapter.
    try coupled_substeps.publishWaterStorageUpdateProvenance(
        accepted_soil_water_heat.water_storage_roundoff_allowance_m3_by_layer,
    );
    try coupled_substeps.publishHeatStorageUpdateProvenance(
        accepted_soil_water_heat.heat_storage_roundoff_allowance_megajoules_by_layer,
    );
    try coupled_substeps.publishChemistryRebaseRoundoff();
    stage_succeeded = true;
    return accepted_soil_water_heat.had_significant_heat_induced_phase_change;
}
